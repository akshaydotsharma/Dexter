import SwiftUI

/// Column widths shared by every category bar row (#389).
///
/// Tokenised rather than inlined because the collapsed band and the expanded
/// panel draw the SAME row: if the two drifted, the bars would start at
/// different x positions and expanding the card would visibly shift them.
enum FinanceBarRowMetrics {
    static let icon: CGFloat = 18
    static var name: CGFloat {
        #if os(macOS)
        140
        #else
        96
        #endif
    }
    /// Share-of-period column. Narrow on purpose: on an iPhone every point here
    /// comes straight out of the bar, which is the part that communicates.
    static var share: CGFloat {
        #if os(macOS)
        32
        #else
        30
        #endif
    }
    static var amount: CGFloat {
        #if os(macOS)
        104
        #else
        92
        #endif
    }
    static let barHeight: CGFloat = 6
}

/// One category row: icon, name, proportional bar, share of period, amount.
/// Used by the collapsed band (top three) and the expanded panel (all).
struct FinanceCategoryBarRow: View {
    let slice: FinanceCategorySlice
    /// Largest total in the set being drawn, so bars are proportional to the
    /// biggest category rather than to the period total.
    let maxTotal: Double

    var body: some View {
        // A net-negative category (refunds outweighed spend, #206) would give a
        // negative ratio; clamp to 0 so the bar just empties rather than drawing
        // a negative width. The trailing amount still shows the true net.
        let ratio = maxTotal > 0 ? Swift.max(0, slice.total / maxTotal) : 0
        return HStack(spacing: Space.sm) {
            Image(systemName: slice.category.sfSymbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Tokens.accentFinance)
                .frame(width: FinanceBarRowMetrics.icon)
            Text(slice.category.displayName)
                .font(.edFootnote)
                .foregroundStyle(Tokens.inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: FinanceBarRowMetrics.name, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Tokens.paper2)
                    Capsule()
                        .fill(Tokens.accentFinance.opacity(0.85))
                        .frame(width: proxy.size.width * CGFloat(ratio))
                }
            }
            .frame(height: FinanceBarRowMetrics.barHeight)
            Text(shareText)
                .font(.edCaption)
                .monospacedDigit()
                .foregroundStyle(Tokens.mutedSoft)
                .frame(width: FinanceBarRowMetrics.share, alignment: .trailing)
            Text(FinanceDashboardBand.formatMoney(slice.total))
                .font(.edFootnote)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Tokens.inkSoft)
                .frame(width: FinanceBarRowMetrics.amount, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(slice.category.displayName), \(FinanceDashboardBand.formatMoney(slice.total))"
            + (slice.share.map { ", \(Int(($0 * 100).rounded())) percent of the period" } ?? "")
        )
    }

    /// Empty (not "0%") when the period nets to zero or less, where a share
    /// carries no meaning. The column keeps its width either way so rows align.
    private var shareText: String {
        guard let share = slice.share else { return "" }
        let percent = share * 100
        if percent > 0 && percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }
}

/// The expanded half of the Finance dashboard card (#389): a spend-over-time
/// bar chart at a granularity picked from the selected period, the full
/// category breakdown, top merchants, and a summary strip.
///
/// Every number here comes from the same `FinanceInsights` the collapsed band
/// reads, which is built from the same filtered rows as the expense list.
struct FinanceInsightsPanel: View {
    let insights: FinanceInsights

    /// Bar the user tapped (iOS) or is hovering (macOS). `nil` falls back to
    /// reading out the peak bucket.
    @State private var selectedBucket: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            chartBlock
            categoriesBlock
            if !insights.merchants.isEmpty {
                merchantsBlock
            }
            summaryStrip
        }
    }

    // MARK: - Spend over time

    private var chartBlock: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(insights.granularity.chartTitle).eyebrow()
                Spacer(minLength: Space.sm)
                if let readout {
                    Text(readout)
                        .font(.edCaption)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            if maxBucketTotal > 0 {
                chart
            } else {
                Text("No spending in this period")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: Self.chartHeight / 2)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(insights.buckets) { bucket in
                        bar(bucket)
                    }
                }
                .frame(height: Self.chartHeight)

                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)

                averageLine
            }
            .frame(height: Self.chartHeight)
            axisRow
        }
    }

    private func bar(_ bucket: FinanceSpendBucket) -> some View {
        let ratio = maxBucketTotal > 0 ? Swift.max(0, bucket.total / maxBucketTotal) : 0
        let isSelected = selectedBucket == bucket.id
        let dimmed = selectedBucket != nil && !isSelected
        // 1.5pt keeps an empty bucket visible as a stub on the baseline rather
        // than vanishing, so gaps in spending still read as periods.
        let height = Swift.max(1.5, CGFloat(ratio) * Self.chartHeight)
        let opacity: Double = dimmed ? 0.28 : (isSelected ? 1.0 : 0.8)

        return ZStack(alignment: .bottom) {
            Color.clear
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Tokens.accentFinance.opacity(bucket.total > 0 ? opacity : 0.22))
                // Capped so a five-bar month reads as a bar chart rather than
                // five blocks filling the card. Dense series stay under the cap
                // and keep dividing the width evenly, and the cell itself still
                // takes an equal share either way — which is what keeps the
                // axis labels under their own bars.
                .frame(maxWidth: Self.maxBarWidth)
                .frame(height: height)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedBucket = isSelected ? nil : bucket.id
        }
        #if os(macOS)
        .onHover { hovering in
            if hovering {
                selectedBucket = bucket.id
            } else if selectedBucket == bucket.id {
                selectedBucket = nil
            }
        }
        #endif
        .accessibilityElement()
        .accessibilityLabel("\(bucket.readoutLabel), \(FinanceDashboardBand.formatMoney(bucket.total))")
    }

    /// Dashed rule at the mean bucket value, so above/below average reads at a
    /// glance. Drawn only when it would sit clear of the baseline and the top.
    @ViewBuilder
    private var averageLine: some View {
        let average = averageBucketTotal
        let ratio = maxBucketTotal > 0 ? average / maxBucketTotal : 0
        if average > 0, ratio > 0.08, ratio < 0.96 {
            let y = CGFloat(ratio) * Self.chartHeight
            FinanceChartRule()
                .stroke(Tokens.borderStrong, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .frame(height: 1)
                .overlay(alignment: .trailing) {
                    Text("avg")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Tokens.mutedSoft)
                        .padding(.horizontal, 2)
                        .background(Tokens.surface)
                        .offset(y: -5)
                }
                .offset(y: -y)
                .accessibilityLabel("Average \(insights.granularity.chartTitle.lowercased()) \(FinanceDashboardBand.formatMoneyRounded(average))")
        }
    }

    /// Axis labels. Per-bar when they demonstrably fit, otherwise just the ends
    /// (and the midpoint), which is enough to orient a dense series — the exact
    /// period of any bar is one tap away in the readout above.
    @ViewBuilder
    private var axisRow: some View {
        if showsPerBarLabels {
            HStack(alignment: .top, spacing: barSpacing) {
                ForEach(insights.buckets) { bucket in
                    Text(bucket.axisLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(selectedBucket == bucket.id ? Tokens.inkSoft : Tokens.mutedSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            HStack(spacing: Space.sm) {
                edgeLabel(insights.buckets.first)
                Spacer(minLength: 0)
                if insights.buckets.count >= 5 {
                    edgeLabel(insights.buckets[insights.buckets.count / 2])
                    Spacer(minLength: 0)
                }
                edgeLabel(insights.buckets.last)
            }
        }
    }

    @ViewBuilder
    private func edgeLabel(_ bucket: FinanceSpendBucket?) -> some View {
        if let bucket {
            Text(bucket.axisLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Tokens.mutedSoft)
                .lineLimit(1)
        }
    }

    // MARK: - Categories

    private var categoriesBlock: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("All categories").eyebrow()
                Spacer()
                Text("\(insights.categories.count)")
                    .font(.edCaption)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.muted)
            }
            if insights.categories.isEmpty {
                Text("Nothing to break down yet")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            } else {
                let maxTotal = insights.categories.map(\.total).max() ?? 1
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(insights.categories) { slice in
                        FinanceCategoryBarRow(slice: slice, maxTotal: maxTotal)
                    }
                }
            }
        }
    }

    // MARK: - Merchants

    private var merchantsBlock: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Top merchants").eyebrow()
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(insights.merchants) { merchant in
                    HStack(spacing: Space.sm) {
                        Text(merchant.name)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(merchant.count == 1 ? "1 expense" : "\(merchant.count) expenses")
                            .font(.edCaption)
                            .monospacedDigit()
                            .foregroundStyle(Tokens.mutedSoft)
                            .lineLimit(1)
                        Spacer(minLength: Space.sm)
                        Text(FinanceDashboardBand.formatMoney(merchant.total))
                            .font(.edFootnote)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(Tokens.inkSoft)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Summary

    private var summaryStrip: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            summaryStat(
                label: "Expenses",
                value: "\(insights.transactionCount)",
                caption: nil
            )
            summaryDivider
            summaryStat(
                label: "Per day",
                value: FinanceDashboardBand.formatMoneyRounded(insights.averagePerDay),
                caption: nil
            )
            summaryDivider
            summaryStat(
                label: "Largest",
                value: insights.largestExpense.map { FinanceDashboardBand.formatMoneyRounded($0.amount) } ?? "–",
                caption: insights.largestExpense?.label
            )
        }
        .padding(.top, Space.xxs)
    }

    private func summaryStat(label: String, value: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).eyebrow()
            Text(value)
                .font(.edFootnote)
                .monospacedDigit()
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let caption {
                Text(caption)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(Tokens.divider)
            .frame(width: 0.5, height: 28)
    }

    // MARK: - Derived values

    private static var chartHeight: CGFloat {
        #if os(macOS)
        88
        #else
        104
        #endif
    }

    /// Widest a single bar may draw, regardless of how much room its cell has.
    private static var maxBarWidth: CGFloat {
        #if os(macOS)
        44
        #else
        30
        #endif
    }

    private var maxBucketTotal: Double {
        Swift.max(0, insights.buckets.map(\.total).max() ?? 0)
    }

    /// Mean across buckets that actually hold spend. Averaging over empty
    /// buckets too would drag the line down and make almost everything look
    /// above average.
    private var averageBucketTotal: Double {
        let spending = insights.buckets.map(\.total).filter { $0 > 0 }
        guard !spending.isEmpty else { return 0 }
        return spending.reduce(0, +) / Double(spending.count)
    }

    private var barSpacing: CGFloat {
        let count = insights.buckets.count
        if count > 20 { return 2 }
        if count > 10 { return 3 }
        return 5
    }

    /// Per-bar axis labels only where the label text is short enough to fit the
    /// cell at this bar count. Day numbers are 1-2 characters, month names 3,
    /// week starts ("1 Jul") 5-6 — hence the different ceilings.
    private var showsPerBarLabels: Bool {
        switch insights.granularity {
        case .daily:   return insights.buckets.count <= 10
        case .weekly:  return insights.buckets.count <= 6
        case .monthly: return insights.buckets.count <= 12
        }
    }

    private var readout: String? {
        if let selectedBucket, let bucket = insights.buckets.first(where: { $0.id == selectedBucket }) {
            return "\(bucket.readoutLabel) · \(FinanceDashboardBand.formatMoney(bucket.total))"
        }
        if let peak = insights.peakBucket, peak.total > 0 {
            return "Peak \(peak.readoutLabel) · \(FinanceDashboardBand.formatMoney(peak.total))"
        }
        return nil
    }
}

/// Horizontal rule through the middle of its frame. Used for the chart's dashed
/// average line, which `Rectangle` can't dash.
private struct FinanceChartRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
