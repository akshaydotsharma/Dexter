import Foundation

/// Bucket width for the spend-over-time chart in the expanded dashboard (#389).
enum FinanceChartGranularity {
    case daily
    case weekly
    case monthly

    /// Chosen from the length of the selected window so the chart always holds
    /// a readable number of bars: a fortnight or less reads day by day, a month
    /// or a quarter reads week by week, anything longer reads month by month.
    ///
    /// That mapping is what makes the presets behave as expected without any
    /// per-preset special casing — "This month" (28-31 days) lands on weekly,
    /// "Last 90 days" on weekly (13 bars), "This year" on monthly (12 bars),
    /// and a hand-picked fortnight on daily.
    static func forRange(_ range: ClosedRange<Date>, calendar: Calendar) -> FinanceChartGranularity {
        let start = calendar.startOfDay(for: range.lowerBound)
        let end = calendar.startOfDay(for: range.upperBound)
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        if days <= 14 { return .daily }
        if days <= 100 { return .weekly }
        return .monthly
    }

    /// Eyebrow above the chart, so the granularity is never something the user
    /// has to infer from bar count.
    var chartTitle: String {
        switch self {
        case .daily:   return "Daily spend"
        case .weekly:  return "Weekly spend"
        case .monthly: return "Monthly spend"
        }
    }
}

/// One bar of the spend-over-time chart.
struct FinanceSpendBucket: Identifiable {
    /// Position in the series. Stable for the life of one `FinanceInsights`,
    /// which is all the chart's selection state needs.
    let id: Int
    let start: Date
    /// Where the bucket stops: the next (exclusive) edge, or the range's own
    /// last instant when the bucket is clipped by it, so a partial trailing
    /// bucket reads honestly ("29 – 31 Jul").
    let end: Date
    let total: Double
    /// Terse label for the axis ("14", "1 Jul", "Jul").
    let axisLabel: String
    /// Full label for the readout line and VoiceOver ("Mon 14 Jul", "1 – 7 Jul").
    let readoutLabel: String
}

/// One row of the category breakdown.
struct FinanceCategorySlice: Identifiable {
    var id: ExpenseCategory { category }
    let category: ExpenseCategory
    let total: Double
    let count: Int
    /// Share of the period total, 0...1. `nil` when the period nets to zero or
    /// less (all refunds), where a percentage would be meaningless.
    let share: Double?
}

/// One row of the merchant breakdown.
struct FinanceMerchantSlice: Identifiable {
    var id: String { name }
    let name: String
    let total: Double
    let count: Int
}

/// Every cut the expanded dashboard renders, computed in ONE pass over the
/// already-filtered rows (#389).
///
/// This is deliberately a value type built from the same `rangeRows` the
/// collapsed band totals, not a second query. The band and the panel therefore
/// cannot disagree: refunds are netted, split trip expenses count only the
/// user's share (`myShareSGD`), and rows hidden from Finance were dropped
/// upstream by `FinanceView.matches`.
struct FinanceInsights {
    let granularity: FinanceChartGranularity
    let buckets: [FinanceSpendBucket]
    /// Every category with non-zero spend, highest first.
    let categories: [FinanceCategorySlice]
    /// Highest-spend merchants, capped by `merchantLimit`.
    let merchants: [FinanceMerchantSlice]
    let transactionCount: Int
    /// Period total spread over elapsed days (not the full window), so an
    /// in-progress month isn't divided by days that haven't happened.
    let averagePerDay: Double
    /// Single biggest expense in the window, by the user's share.
    let largestExpense: (label: String, amount: Double)?

    /// The three bars the collapsed band shows. Derived here rather than
    /// computed separately so collapsed and expanded can never disagree on
    /// ordering.
    var topCategories: [FinanceCategorySlice] { Array(categories.prefix(3)) }

    /// Highest bar, used as the default chart readout before the user picks one.
    var peakBucket: FinanceSpendBucket? {
        buckets.max { $0.total < $1.total }
    }

    static let empty = FinanceInsights(
        granularity: .daily,
        buckets: [],
        categories: [],
        merchants: [],
        transactionCount: 0,
        averagePerDay: 0,
        largestExpense: nil
    )

    // MARK: - Build

    /// Aggregate `rows` (already date- and filter-matched) into every cut.
    ///
    /// - Parameters:
    ///   - rows: the expenses inside `range` that pass the active filters.
    ///   - range: the dashboard window, which also sets the chart's bucket edges
    ///     so empty leading / trailing periods still draw as empty bars.
    ///   - now: injected for testability; clamps the "per day" divisor.
    static func build(
        rows: [LocalExpense],
        range: ClosedRange<Date>,
        now: Date = Date(),
        calendar: Calendar = .current,
        merchantLimit: Int = 6
    ) -> FinanceInsights {
        let granularity = FinanceChartGranularity.forRange(range, calendar: calendar)
        let edges = bucketEdges(range: range, granularity: granularity, calendar: calendar)

        var bucketTotals = [Double](repeating: 0, count: max(edges.count - 1, 0))
        var byCategory: [ExpenseCategory: (total: Double, count: Int)] = [:]
        var byMerchant: [String: (total: Double, count: Int)] = [:]
        var total: Double = 0
        var largest: (label: String, amount: Double)?

        for row in rows {
            let share = row.myShareSGD
            total += share

            if let index = bucketIndex(
                for: row.date,
                range: range,
                granularity: granularity,
                bucketCount: bucketTotals.count,
                calendar: calendar
            ) {
                bucketTotals[index] += share
            }

            let existingCategory = byCategory[row.categoryEnum] ?? (0, 0)
            byCategory[row.categoryEnum] = (existingCategory.total + share, existingCategory.count + 1)

            if let name = merchantName(for: row) {
                let existing = byMerchant[name] ?? (0, 0)
                byMerchant[name] = (existing.total + share, existing.count + 1)
            }

            if share > (largest?.amount ?? 0) {
                largest = (label: displayLabel(for: row), amount: share)
            }
        }

        var buckets: [FinanceSpendBucket] = []
        for index in bucketTotals.indices {
            let bucketStart = edges[index]
            let bucketEnd = min(edges[index + 1], range.upperBound)
            buckets.append(
                FinanceSpendBucket(
                    id: index,
                    start: bucketStart,
                    end: bucketEnd,
                    total: bucketTotals[index],
                    axisLabel: axisLabel(start: bucketStart, granularity: granularity),
                    readoutLabel: readoutLabel(
                        start: bucketStart,
                        end: bucketEnd,
                        granularity: granularity,
                        calendar: calendar
                    )
                )
            )
        }

        // A net-negative period (refunds outweighed spend) makes a share
        // meaningless, so drop it rather than print a negative percentage.
        let shareBase: Double? = total > 0 ? total : nil
        var categories: [FinanceCategorySlice] = []
        for (category, entry) in byCategory {
            // Categories that net exactly zero carry no information; a negative
            // one (a refunded category) still does, so it stays.
            guard entry.total != 0 else { continue }
            var share: Double?
            if let shareBase {
                share = entry.total / shareBase
            }
            categories.append(
                FinanceCategorySlice(
                    category: category,
                    total: entry.total,
                    count: entry.count,
                    share: share
                )
            )
        }
        categories.sort { $0.total > $1.total }

        var merchants: [FinanceMerchantSlice] = []
        for (name, entry) in byMerchant where entry.total > 0 {
            merchants.append(FinanceMerchantSlice(name: name, total: entry.total, count: entry.count))
        }
        merchants.sort { $0.total > $1.total }
        merchants = Array(merchants.prefix(merchantLimit))

        let effectiveEnd = min(range.upperBound, now)
        let elapsedDays = max(1.0, effectiveEnd.timeIntervalSince(range.lowerBound) / 86_400.0)

        return FinanceInsights(
            granularity: granularity,
            buckets: buckets,
            categories: categories,
            merchants: Array(merchants),
            transactionCount: rows.count,
            averagePerDay: total / elapsedDays,
            largestExpense: largest
        )
    }

    // MARK: - Bucketing

    /// Bucket boundaries across `range`, ascending, with one trailing edge so
    /// bucket `i` spans `edges[i] ..< edges[i + 1]`.
    ///
    /// Weekly buckets are anchored to the RANGE START rather than to the
    /// calendar week. Anchoring to the calendar would make the first bar of a
    /// month view start in the previous month, so its label would sit outside
    /// the window the user selected; 7-day bins from the range start always
    /// label inside it ("1 – 7 Jul").
    private static func bucketEdges(
        range: ClosedRange<Date>,
        granularity: FinanceChartGranularity,
        calendar: Calendar
    ) -> [Date] {
        let start: Date
        switch granularity {
        case .daily, .weekly:
            start = calendar.startOfDay(for: range.lowerBound)
        case .monthly:
            let comps = calendar.dateComponents([.year, .month], from: range.lowerBound)
            start = calendar.date(from: comps) ?? calendar.startOfDay(for: range.lowerBound)
        }

        var edges: [Date] = [start]
        var cursor = start
        // Hard cap: even a decade-long custom range can't run away here, and a
        // failed component add breaks the loop rather than spinning.
        while edges.count < 400 {
            let next: Date?
            switch granularity {
            case .daily:   next = calendar.date(byAdding: .day, value: 1, to: cursor)
            case .weekly:  next = calendar.date(byAdding: .day, value: 7, to: cursor)
            case .monthly: next = calendar.date(byAdding: .month, value: 1, to: cursor)
            }
            guard let next else { break }
            edges.append(next)
            if next > range.upperBound { break }
            cursor = next
        }
        return edges
    }

    private static func bucketIndex(
        for date: Date,
        range: ClosedRange<Date>,
        granularity: FinanceChartGranularity,
        bucketCount: Int,
        calendar: Calendar
    ) -> Int? {
        guard bucketCount > 0 else { return nil }
        let index: Int
        switch granularity {
        case .daily, .weekly:
            let anchor = calendar.startOfDay(for: range.lowerBound)
            let day = calendar.startOfDay(for: date)
            let offset = calendar.dateComponents([.day], from: anchor, to: day).day ?? 0
            index = granularity == .daily ? offset : offset / 7
        case .monthly:
            let anchorComps = calendar.dateComponents([.year, .month], from: range.lowerBound)
            let dateComps = calendar.dateComponents([.year, .month], from: date)
            guard
                let anchor = calendar.date(from: anchorComps),
                let month = calendar.date(from: dateComps)
            else { return nil }
            index = calendar.dateComponents([.month], from: anchor, to: month).month ?? 0
        }
        guard index >= 0, index < bucketCount else { return nil }
        return index
    }

    // MARK: - Labels

    private static func axisLabel(
        start: Date,
        granularity: FinanceChartGranularity
    ) -> String {
        let formatter = DateFormatter()
        switch granularity {
        case .daily:   formatter.dateFormat = "d"
        case .weekly:  formatter.dateFormat = "d MMM"
        case .monthly: formatter.dateFormat = "MMM"
        }
        return formatter.string(from: start)
    }

    private static func readoutLabel(
        start: Date,
        end: Date,
        granularity: FinanceChartGranularity,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        switch granularity {
        case .daily:
            formatter.dateFormat = "EEE d MMM"
            return formatter.string(from: start)
        case .monthly:
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: start)
        case .weekly:
            // `end` is either the next (exclusive) edge or the range's inclusive
            // last instant. Backing off one second then flooring to the day
            // resolves to the bucket's real last day in both cases.
            let last = calendar.startOfDay(for: end.addingTimeInterval(-1))
            let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: last)
                && calendar.component(.year, from: start) == calendar.component(.year, from: last)
            let startFormatter = DateFormatter()
            startFormatter.dateFormat = sameMonth ? "d" : "d MMM"
            formatter.dateFormat = "d MMM"
            return "\(startFormatter.string(from: start)) – \(formatter.string(from: last))"
        }
    }

    /// Merchant key for the merchant cut. Falls back to the description so a
    /// row logged as "lunch with no merchant" still lands somewhere; rows with
    /// neither are left out entirely rather than bucketed under a placeholder.
    private static func merchantName(for row: LocalExpense) -> String? {
        if let merchant = row.merchant?.trimmingCharacters(in: .whitespacesAndNewlines), !merchant.isEmpty {
            return merchant
        }
        if let description = row.expenseDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            return description
        }
        return nil
    }

    /// Human label for a single row, used by the "largest expense" stat.
    private static func displayLabel(for row: LocalExpense) -> String {
        merchantName(for: row) ?? row.categoryEnum.displayName
    }
}
