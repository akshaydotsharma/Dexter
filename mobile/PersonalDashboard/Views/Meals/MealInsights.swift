import SwiftUI

// MARK: - Bands

/// How a nutrient's AVERAGE over a window reads against its target (#545).
///
/// Four bands, not the three `MealVerdict` uses for one day. The fourth exists
/// for ceilings only: a day that goes 10% over a sodium limit is an ordinary
/// day, and a fortnight that averages 10% over is a habit. `watch` is what lets
/// the tab say the second without using the same word it would use for 40%
/// over, which is the word that would then mean nothing.
///
/// `MealVerdict` stays as it is and keeps its job: one day, three states, on the
/// day card. This type never appears there.
enum MealTrendBand: String, CaseIterable, Hashable, Sendable {
    /// Short of a floor, or below a range. Ceilings can never be `under`:
    /// there is no such thing as too little sugar to be told about.
    case under
    /// Inside a range, at or above a floor, at or under a ceiling.
    case onTrack
    /// Past a ceiling, but not far past. Ceilings only.
    case watch
    /// Far past a ceiling, or above a range, or far above a floor.
    case over

    /// The word printed beside the bar. One word, because the percent next to
    /// it already says how far.
    var label: String {
        switch self {
        case .under:   return "Under"
        case .onTrack: return "On track"
        case .watch:   return "Watch"
        case .over:    return "Over"
        }
    }

    /// `warning` for both `under` and `watch` on purpose: neither is a failure,
    /// both are a thing to look at. `danger` is reserved for `over`, so the one
    /// red thing on the screen is the one worth acting on.
    var tint: Color {
        switch self {
        case .under:   return Tokens.warning
        case .onTrack: return Tokens.success
        case .watch:   return Tokens.warning
        case .over:    return Tokens.danger
        }
    }

    /// Whether this band is worth a callout at all.
    var isFlagged: Bool { self != .onTrack }

    /// Which side of the target this band sits on. Drives the callout wording
    /// and the day count beside it.
    var isAbove: Bool {
        switch self {
        case .watch, .over: return true
        case .under, .onTrack: return false
        }
    }
}

extension Nutrient {

    /// Read an average against its target, by goal kind (#545).
    ///
    /// ### Why the three kinds get three different bands
    ///
    /// The asymmetry is the whole feature. A floor at 130% of target is a good
    /// fortnight and must not be flagged; a ceiling at 130% is exactly the fact
    /// worth being told. One symmetric band would generate noise on five of the
    /// eight nutrients, and a screen that flags five things flags nothing.
    ///
    /// | Kind    | Under   | On track  | Watch    | Over   |
    /// |---------|---------|-----------|----------|--------|
    /// | floor   | < 85%   | 85–150%   | n/a      | > 150% |
    /// | ceiling | n/a     | ≤ 100%    | 100–125% | > 125% |
    /// | range   | < 90%   | 90–110%   | n/a      | > 110% |
    ///
    /// A floor's `over` band exists and sits at 150% because a protein average
    /// half again over target is worth knowing about even though it is not a
    /// problem — but nothing below that is.
    ///
    /// Returns nil when there is no target to read against. Over and under are
    /// undefined without one, and a made-up band is worse than a blank.
    func trendBand(value: Double, target: Double) -> MealTrendBand? {
        guard target > 0 else { return nil }
        let ratio = value / target
        switch goalKind {
        case .floor:
            if ratio < 0.85 { return .under }
            if ratio > 1.50 { return .over }
            return .onTrack
        case .ceiling:
            if ratio <= 1.00 { return .onTrack }
            if ratio <= 1.25 { return .watch }
            return .over
        case .range:
            if ratio < 0.90 { return .under }
            if ratio > 1.10 { return .over }
            return .onTrack
        }
    }

    /// Every nutrient, in the ONE order the balance table prints them (#545).
    ///
    /// Fixed in code and never sorted by deviation. The table is read down the
    /// column across periods, so a row that moved would make two screenshots of
    /// the same eight numbers impossible to compare. The ranking that DOES
    /// matter lives in the callouts, where there are at most three of them and
    /// each one names itself.
    static let balanceTableOrder: [Nutrient] = [
        .calories, .protein, .carbs, .fat, .fibre, .sugar, .sodium, .saturatedFat
    ]

    /// How much a miss on this nutrient is worth relative to a miss on another,
    /// when only three callouts fit.
    ///
    /// Protein and fibre first: they are the two floors, they are the two most
    /// people actually miss, and a shortfall on either is answerable by eating
    /// something specific. Sodium and sugar next: ceilings with a real health
    /// argument behind them. Calories, carbs, fat and saturated fat last, not
    /// because they matter less but because a calorie miss is usually the SUM
    /// of the others and saying it as well spends a slot on a restatement.
    var calloutPriority: Double {
        switch self {
        case .protein, .fibre:       return 3
        case .sodium, .sugar:        return 2
        case .calories, .carbs, .fat, .saturatedFat: return 1
        }
    }

    /// The verb a callout sentence needs after this nutrient's name.
    /// "Calories are", "Carbs are", "Protein is".
    var trendVerb: String {
        switch self {
        case .calories, .carbs: return "are"
        default:                return "is"
        }
    }
}

// MARK: - One day

/// What one calendar day in the window contributed (#545).
struct MealTrendDay: Identifiable, Hashable, Sendable {
    /// Device-local midnight. The value a formatter or a picker takes.
    let day: Date
    /// Totals over this day's COUNTED meals only: suspect and needs-detail
    /// meals are excluded here exactly as they are on the day card, so the
    /// Trends tab and the Tracking tab cannot disagree about a day.
    let totals: MealNutrients
    /// Calories per meal type, counted meals only.
    let caloriesByType: [MealType: Double]
    let state: State
    /// Counted meals logged on this day.
    let countedMealCount: Int

    var id: Date { day }

    /// What kind of day this is for the purposes of an average.
    enum State: String, Hashable, Sendable {
        /// Nothing at all was logged. Not a day of eating nothing.
        case unlogged
        /// Something was logged, but too little to be a day's eating: below
        /// half the calorie target, or logged entirely as meals held out of the
        /// totals. A logging artefact, not a dietary fact.
        case partial
        /// A day whose numbers stand.
        case counted
    }
}

// MARK: - Rows, callouts, strips

/// One row of the balance table: what the average was, what it was aimed at,
/// and how that reads.
struct MealBalanceRow: Identifiable, Hashable, Sendable {
    let nutrient: Nutrient
    /// Average per counted day.
    let average: Double
    /// The target in force. Always > 0 here; a nutrient with no target still
    /// gets a row, with `band` nil, so the table keeps all eight.
    let target: Double
    /// `average / target`. Nil when there is no target.
    let ratio: Double?
    let band: MealTrendBand?

    var id: Nutrient { nutrient }

    /// Signed distance from target in the nutrient's own unit. Positive means
    /// over.
    var delta: Double { average - target }
}

/// One sentence the tab says about the window, written in Swift (#545).
///
/// ### Why no model writes this
///
/// It costs nothing on render, so the panel can recompute on every frame and no
/// two numbers on the screen can drift apart. It is identical across sessions,
/// so a screenshot from last week is comparable. And it can never contradict
/// the table directly above it, because it is derived from the same row.
struct MealCallout: Identifiable, Hashable, Sendable {
    let nutrient: Nutrient
    let band: MealTrendBand
    /// The whole sentence, ready to print.
    let text: String
    /// How many counted days sat on the same side of the target as the average.
    let matchingDays: Int
    /// How many counted days there were to be on a side of.
    let consideredDays: Int
    /// Ranking score: absolute deviation weighted by `calloutPriority`.
    let score: Double

    var id: Nutrient { nutrient }
}

/// One cell of a consistency strip: a day, and how that single day read.
struct MealConsistencyCell: Identifiable, Hashable, Sendable {
    let day: Date
    /// Nil on an unlogged or partial day, and on any day with no target. A
    /// blank cell is the honest mark for a day that has no verdict.
    let band: MealTrendBand?
    var id: Date { day }
}

/// One flagged nutrient's day-by-day read.
struct MealConsistencyStrip: Identifiable, Hashable, Sendable {
    let nutrient: Nutrient
    let cells: [MealConsistencyCell]
    /// True when the window is longer than the strip draws, so the panel can
    /// say so rather than let the reader assume they are seeing all of it.
    let isClipped: Bool

    var id: Nutrient { nutrient }

    /// Longest run of days ending at the most recent cell that all read the
    /// same as the most recent cell. What a strip is actually read for.
    var currentStreak: Int {
        guard let last = cells.last?.band else { return 0 }
        var count = 0
        for cell in cells.reversed() {
            guard cell.band == last else { break }
            count += 1
        }
        return count
    }
}

/// One bar of the calories chart.
struct MealCalorieBucket: Identifiable, Hashable, Sendable {
    let id: Int
    let start: Date
    let end: Date
    /// Average calories per COUNTED day inside the bucket, not the sum.
    ///
    /// A sum would make the target line meaningless the moment the bucket stops
    /// being one day, and that line is the reason this chart is worth drawing.
    /// An average keeps every bar on the same scale as the rule across it.
    let averageCalories: Double
    /// Counted days inside the bucket. Zero means the bar is a gap, not a zero.
    let countedDays: Int
    let axisLabel: String
    let readoutLabel: String
}

/// Average calories contributed by one part of the day.
struct MealTypeAverage: Identifiable, Hashable, Sendable {
    let mealType: MealType
    /// Average calories per counted day from this meal type.
    let averageCalories: Double
    /// Share of the average day, 0...1. Nil when the day averages nothing.
    let share: Double?

    var id: MealType { mealType }
}

/// How well the log itself was kept over the window (#545).
///
/// Makes the feature's own reliability visible without a single extra tool. An
/// average is only as good as the days under it, and this strip is what lets
/// the reader decide whether to believe the panel above it.
struct MealLoggingHealth: Hashable, Sendable {
    let totalDays: Int
    /// Days whose numbers were used.
    let daysLogged: Int
    /// Days with something on them, held out of the averages.
    let partialDays: Int
    /// Days with nothing on them at all.
    let unloggedDays: Int
    /// Meals in the window still waiting on an answer from the user.
    let needsDetailCount: Int
    /// Meals in the window whose estimate flagged itself as implausible.
    let suspectCount: Int
    /// Meals whose totals the user typed over. The feature working, not failing.
    let correctedCount: Int
    /// Meals logged through the Meals composer (including Repeat).
    let composerCount: Int
    /// Meals logged through chat.
    let chatCount: Int
    /// Meals logged hands-free through the Shortcut.
    let captureCount: Int

    static let empty = MealLoggingHealth(
        totalDays: 0, daysLogged: 0, partialDays: 0, unloggedDays: 0,
        needsDetailCount: 0, suspectCount: 0, correctedCount: 0,
        composerCount: 0, chatCount: 0, captureCount: 0
    )
}

// MARK: - The insights

/// Every cut the Trends tab renders, computed in ONE pass over the meals in the
/// window (#545).
///
/// ### No API call, ever, on render
///
/// Every number and every sentence here is arithmetic over stored rows against
/// stored targets. That is what lets the tab recompute on a period change, on a
/// meal edit, on any frame — and it is what makes it impossible for two numbers
/// on one screen to disagree, because there is only one computation and both the
/// collapsed band and the expanded panel read its result.
///
/// The one API call in the tab is "Ask Dexter about this", and it happens when
/// the button is pressed and at no other time.
///
/// Deliberately the same shape as `FinanceInsights`: a pure value type built by
/// a static `build`, holding no `LocalMeal` references, so it can outlive a row
/// being deleted mid-render.
struct MealInsights: Hashable, Sendable {

    /// Device-local day bounds this was built over.
    let rangeStart: Date
    let rangeEnd: Date

    /// Every day in the window, oldest first, whether logged or not.
    let days: [MealTrendDay]

    /// Average per counted day, for all eight nutrients.
    let averages: MealNutrients

    /// The targets in force, or nil when none are set.
    let targets: MealNutrients?

    /// Eight rows, in `Nutrient.balanceTableOrder`. EMPTY when no targets are
    /// set: over and under are undefined without a target, and an empty verdict
    /// column is worse than no table.
    let balance: [MealBalanceRow]

    /// At most three, ranked. Empty when nothing is flagged, or when there are
    /// no targets to flag against.
    let callouts: [MealCallout]

    /// One strip per callout, in the same order.
    let consistency: [MealConsistencyStrip]

    let buckets: [MealCalorieBucket]
    let granularity: FinanceChartGranularity

    /// The four parts of the day, always in serving order.
    let byMealType: [MealTypeAverage]

    let health: MealLoggingHealth

    /// Whether partial days were folded into the averages.
    let includesPartialDays: Bool

    /// The calorie target, or nil. The chart's horizontal rule.
    var calorieTarget: Double? {
        guard let targets, targets.calories > 0 else { return nil }
        return targets.calories
    }

    /// Average calories per counted day. The band's headline.
    var averageCalories: Double { averages.calories }

    /// Nothing usable was logged in the window.
    var isEmpty: Bool { health.daysLogged == 0 }

    /// Whether there is anything to compare against.
    var hasTargets: Bool { targets != nil }

    /// The rows the collapsed band shows, capped at three. Taken from the SAME
    /// `balance` array the panel prints, in the SAME order, so expanding the
    /// card cannot reorder or restate a row.
    var flaggedBalance: [MealBalanceRow] {
        Array(balance.filter { $0.band?.isFlagged == true }.prefix(3))
    }

    static let empty = MealInsights(
        rangeStart: Date(),
        rangeEnd: Date(),
        days: [],
        averages: .zero,
        targets: nil,
        balance: [],
        callouts: [],
        consistency: [],
        buckets: [],
        granularity: .daily,
        byMealType: [],
        health: .empty,
        includesPartialDays: false
    )

    // MARK: - Build

    /// Longest consistency strip drawn, in days.
    ///
    /// A cell per day across a year is 0.9 pt wide at phone width, which is not
    /// a strip, it is a smear. The strip is read for a streak or a run, and both
    /// live at the recent end, so a long window shows its most recent 90 days
    /// and the panel says that it is doing so.
    static let consistencyCellLimit = 90

    /// Hard cap on the days enumerated, so a mis-typed custom range of ten years
    /// cannot turn one render into a hundred thousand iterations.
    static let maxDays = 400

    /// Build every cut from the meals in the window.
    ///
    /// - Parameters:
    ///   - meals: every meal held. Filtered to the window here, by DAY, through
    ///     `WallClock` — a stored day is a UTC anchor and is never compared as
    ///     an instant (#506).
    ///   - targets: the targets in force, or nil.
    ///   - range: device-local day bounds.
    ///   - includePartialDays: fold under-logged days into the averages.
    static func build(
        meals: [LocalMeal],
        targets: MealTargets?,
        range: ClosedRange<Date>,
        includePartialDays: Bool = false,
        calendar: Calendar = .current
    ) -> MealInsights {
        let firstDay = calendar.startOfDay(for: range.lowerBound)
        let lastDay = calendar.startOfDay(for: range.upperBound)
        let spanDays = min(
            max((calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1, 1),
            maxDays
        )

        // Day cells, oldest first, keyed by the STORED anchor so a meal lands in
        // one lookup rather than a scan.
        var dayOrder: [Date] = []
        var anchorIndex: [Date: Int] = [:]
        dayOrder.reserveCapacity(spanDays)
        for offset in 0..<spanDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { break }
            dayOrder.append(day)
            anchorIndex[WallClock.dayAnchor(from: day)] = dayOrder.count - 1
        }

        var totals = [MealNutrients](repeating: .zero, count: dayOrder.count)
        var typeCalories = [[MealType: Double]](repeating: [:], count: dayOrder.count)
        var countedMeals = [Int](repeating: 0, count: dayOrder.count)
        var anyMeals = [Int](repeating: 0, count: dayOrder.count)

        var needsDetailCount = 0
        var suspectCount = 0
        var correctedCount = 0
        var composerCount = 0
        var chatCount = 0
        var captureCount = 0

        // THE one pass over the rows. Everything after this loop walks days
        // (at most 400) or nutrients (eight), never meals again.
        for meal in meals {
            guard let index = anchorIndex[WallClock.startOfStoredDay(meal.date)] else { continue }
            anyMeals[index] += 1

            // Health counts cover every meal in the window, including the ones
            // held out of the totals: their whole point is to say how much was
            // held out.
            if meal.needsDetail { needsDetailCount += 1 }
            if meal.isSuspect { suspectCount += 1 }
            switch meal.source {
            case MealSource.user:      correctedCount += 1
            case MealSource.chat:      chatCount += 1
            case MealSource.capture:   captureCount += 1
            default:                   composerCount += 1
            }

            // Same exclusions as `MealDaySummary`, for the same reason: a total
            // that quietly folds in a provably wrong number is worse than one
            // that says it is incomplete.
            guard !meal.isSuspect, !meal.needsDetail else { continue }
            countedMeals[index] += 1
            totals[index] = totals[index] + meal.nutrients
            typeCalories[index][meal.mealTypeEnum, default: 0] += meal.calories
        }

        let calorieTarget = (targets?.calories ?? 0) > 0 ? targets!.calories : nil

        var days: [MealTrendDay] = []
        days.reserveCapacity(dayOrder.count)
        for (index, day) in dayOrder.enumerated() {
            let state: MealTrendDay.State
            if anyMeals[index] == 0 {
                state = .unlogged
            } else if countedMeals[index] == 0 {
                // Logged, but every meal on it is held out. No numbers to stand
                // on, so it is a logging artefact whether or not a target exists.
                state = .partial
            } else if let calorieTarget, totals[index].calories < calorieTarget * 0.5 {
                state = .partial
            } else {
                state = .counted
            }
            days.append(
                MealTrendDay(
                    day: day,
                    totals: totals[index],
                    caloriesByType: typeCalories[index],
                    state: state,
                    countedMealCount: countedMeals[index]
                )
            )
        }

        let countedDays = days.filter {
            $0.state == .counted || (includePartialDays && $0.state == .partial)
        }
        let divisor = Double(max(countedDays.count, 1))

        var averages = MealNutrients.zero
        var typeTotals: [MealType: Double] = [:]
        for day in countedDays {
            averages = averages + day.totals
            for (type, calories) in day.caloriesByType {
                typeTotals[type, default: 0] += calories
            }
        }
        if !countedDays.isEmpty {
            for nutrient in Nutrient.allCases { averages[nutrient] = averages[nutrient] / divisor }
        } else {
            averages = .zero
        }

        let targetValues: MealNutrients? = targets.map(\.targets)

        // The balance table. Absent, not empty, when there is nothing to
        // compare against.
        var balance: [MealBalanceRow] = []
        if let targetValues, Nutrient.allCases.contains(where: { targetValues[$0] > 0 }) {
            for nutrient in Nutrient.balanceTableOrder {
                let target = targetValues[nutrient]
                let average = averages[nutrient]
                balance.append(
                    MealBalanceRow(
                        nutrient: nutrient,
                        average: average,
                        target: target,
                        ratio: target > 0 ? average / target : nil,
                        band: nutrient.trendBand(value: average, target: target)
                    )
                )
            }
        }

        let callouts = buildCallouts(
            balance: balance,
            days: countedDays,
            targets: targetValues
        )

        let consistency = callouts.map { callout in
            strip(for: callout.nutrient, days: days, targets: targetValues)
        }

        let granularity = FinanceChartGranularity.forRange(
            firstDay...max(lastDay, firstDay),
            calendar: calendar
        )
        let buckets = buildBuckets(
            days: days,
            counted: Set(countedDays.map(\.day)),
            granularity: granularity,
            calendar: calendar
        )

        let dayAverage = averages.calories
        let byMealType = MealDaySummary.typeOrder.map { type -> MealTypeAverage in
            let average = countedDays.isEmpty ? 0 : (typeTotals[type] ?? 0) / divisor
            return MealTypeAverage(
                mealType: type,
                averageCalories: average,
                share: dayAverage > 0 ? average / dayAverage : nil
            )
        }

        let health = MealLoggingHealth(
            totalDays: days.count,
            daysLogged: days.filter { $0.state == .counted }.count,
            partialDays: days.filter { $0.state == .partial }.count,
            unloggedDays: days.filter { $0.state == .unlogged }.count,
            needsDetailCount: needsDetailCount,
            suspectCount: suspectCount,
            correctedCount: correctedCount,
            composerCount: composerCount,
            chatCount: chatCount,
            captureCount: captureCount
        )

        return MealInsights(
            rangeStart: firstDay,
            rangeEnd: lastDay,
            days: days,
            averages: averages,
            targets: balance.isEmpty ? nil : targetValues,
            balance: balance,
            callouts: callouts,
            consistency: consistency,
            buckets: buckets,
            granularity: granularity,
            byMealType: byMealType,
            health: health,
            includesPartialDays: includePartialDays
        )
    }

    // MARK: - Callouts

    /// Rank the flagged rows and write at most three sentences.
    ///
    /// Three is a CAP, not a target. A list of eight problems is a list of zero,
    /// and a window where two things are wrong should say two things.
    static func buildCallouts(
        balance: [MealBalanceRow],
        days: [MealTrendDay],
        targets: MealNutrients?
    ) -> [MealCallout] {
        guard let targets else { return [] }

        var ranked: [MealCallout] = []
        for row in balance {
            guard let band = row.band, band.isFlagged, let ratio = row.ratio else { continue }
            let deviation = abs(ratio - 1)
            let score = deviation * row.nutrient.calloutPriority

            // A day counts towards the streak when it sits on the SAME side of
            // the target as the average does. An average alone cannot tell a
            // steady 15% shortfall from a fine fortnight with two bad days, and
            // those two want opposite responses.
            let matching = days.filter { day in
                guard let dayBand = row.nutrient.trendBand(
                    value: day.totals[row.nutrient],
                    target: targets[row.nutrient]
                ) else { return false }
                return dayBand.isFlagged && dayBand.isAbove == band.isAbove
            }.count

            ranked.append(
                MealCallout(
                    nutrient: row.nutrient,
                    band: band,
                    text: sentence(row: row, band: band, matching: matching, considered: days.count),
                    matchingDays: matching,
                    consideredDays: days.count,
                    score: score
                )
            )
        }

        // Deterministic: score first, then the fixed table order, so two runs
        // over the same rows can never produce two different lists.
        let order = Nutrient.balanceTableOrder
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let l = order.firstIndex(of: lhs.nutrient) ?? 0
            let r = order.firstIndex(of: rhs.nutrient) ?? 0
            return l < r
        }
        return Array(ranked.prefix(3))
    }

    /// One callout sentence, built from the computed band. No model writes any
    /// part of this.
    static func sentence(
        row: MealBalanceRow,
        band: MealTrendBand,
        matching: Int,
        considered: Int
    ) -> String {
        let name = row.nutrient.displayName
        let amount = MealFormat.value(abs(row.delta), for: row.nutrient)
        let side = band.isAbove ? "over target" : "under target"
        let head = "\(name) \(row.nutrient.trendVerb) \(amount) a day \(side)"

        guard considered > 0 else { return head + "." }
        let dayWord = band.isAbove ? "above target" : "below target"
        let dayNoun = considered == 1 ? "logged day" : "logged days"
        return "\(head), and \(matching) of the last \(considered) \(dayNoun) \(considered == 1 ? "was" : "were") \(dayWord)."
    }

    // MARK: - Consistency

    static func strip(
        for nutrient: Nutrient,
        days: [MealTrendDay],
        targets: MealNutrients?
    ) -> MealConsistencyStrip {
        let clipped = days.count > consistencyCellLimit
        let visible = clipped ? Array(days.suffix(consistencyCellLimit)) : days
        let cells = visible.map { day -> MealConsistencyCell in
            guard day.state == .counted, let targets else {
                return MealConsistencyCell(day: day.day, band: nil)
            }
            return MealConsistencyCell(
                day: day.day,
                band: nutrient.trendBand(value: day.totals[nutrient], target: targets[nutrient])
            )
        }
        return MealConsistencyStrip(nutrient: nutrient, cells: cells, isClipped: clipped)
    }

    // MARK: - Chart

    /// Bars across the window, at the granularity `FinanceChartGranularity`
    /// picks from its length: a fortnight or less reads day by day, a month or a
    /// quarter week by week, longer month by month.
    ///
    /// Each bar is the AVERAGE calories of the counted days inside it, so the
    /// target rule drawn across the chart means the same thing at every
    /// granularity. A bucket holding no counted day draws as a gap.
    static func buildBuckets(
        days: [MealTrendDay],
        counted: Set<Date>,
        granularity: FinanceChartGranularity,
        calendar: Calendar
    ) -> [MealCalorieBucket] {
        guard !days.isEmpty else { return [] }

        var groups: [(start: Date, end: Date, sum: Double, countedDays: Int)] = []
        var currentKey: Date?

        for day in days {
            let key: Date
            switch granularity {
            case .daily:
                key = day.day
            case .weekly:
                let offset = calendar.dateComponents([.day], from: days[0].day, to: day.day).day ?? 0
                key = calendar.date(byAdding: .day, value: (offset / 7) * 7, to: days[0].day) ?? day.day
            case .monthly:
                let comps = calendar.dateComponents([.year, .month], from: day.day)
                key = calendar.date(from: comps) ?? day.day
            }

            if key != currentKey {
                groups.append((start: key, end: day.day, sum: 0, countedDays: 0))
                currentKey = key
            }
            groups[groups.count - 1].end = day.day
            if counted.contains(day.day) {
                groups[groups.count - 1].sum += day.totals.calories
                groups[groups.count - 1].countedDays += 1
            }
        }

        return groups.enumerated().map { index, group in
            MealCalorieBucket(
                id: index,
                start: group.start,
                end: group.end,
                averageCalories: group.countedDays > 0 ? group.sum / Double(group.countedDays) : 0,
                countedDays: group.countedDays,
                axisLabel: axisLabel(group.start, granularity: granularity),
                readoutLabel: readoutLabel(
                    start: group.start,
                    end: group.end,
                    granularity: granularity,
                    calendar: calendar
                )
            )
        }
    }

    private static func axisLabel(_ start: Date, granularity: FinanceChartGranularity) -> String {
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
            let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
                && calendar.component(.year, from: start) == calendar.component(.year, from: end)
            let head = DateFormatter()
            head.dateFormat = sameMonth ? "d" : "d MMM"
            formatter.dateFormat = "d MMM"
            return "\(head.string(from: start)) to \(formatter.string(from: end))"
        }
    }
}

// MARK: - Handing the analysis to chat

extension MealInsights {

    /// The whole analysis as plain text, for the one call "Ask Dexter about
    /// this" makes (#545).
    ///
    /// Built from the SAME computed values the panel prints, so the question
    /// the model is asked cannot disagree with the screen the user is looking
    /// at while it answers.
    func chatPrompt(periodLabel: String) -> String {
        var lines: [String] = []
        lines.append("Here is my meal analysis for \(periodLabel.lowercased()). Tell me what to change, and be specific about food.")
        lines.append("")
        lines.append("Days: \(health.daysLogged) logged, \(health.partialDays) partial, \(health.unloggedDays) not logged.")
        lines.append("Average per logged day: \(MealFormat.calories(averages.calories)) kcal.")

        if !balance.isEmpty {
            lines.append("")
            lines.append("Averages against target:")
            for row in balance {
                let value = MealFormat.value(row.average, for: row.nutrient)
                let target = MealFormat.value(row.target, for: row.nutrient)
                let percent = row.ratio.map { " (\(Int(($0 * 100).rounded()))% of target, \(row.band?.label ?? "no target"))" } ?? ""
                lines.append("- \(row.nutrient.displayName): \(value) of \(target)\(percent)")
            }
        } else {
            lines.append("")
            lines.append("No targets are set, so these are totals only.")
        }

        if !callouts.isEmpty {
            lines.append("")
            lines.append("What stands out:")
            for callout in callouts { lines.append("- \(callout.text)") }
        }

        let types = byMealType.filter { $0.averageCalories > 0 }
        if !types.isEmpty {
            lines.append("")
            lines.append("Average calories by meal type:")
            for type in types {
                let share = type.share.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""
                lines.append("- \(type.mealType.displayName): \(MealFormat.calories(type.averageCalories)) kcal\(share)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
