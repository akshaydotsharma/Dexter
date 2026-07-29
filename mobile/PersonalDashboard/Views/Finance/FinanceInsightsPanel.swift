import SwiftUI

/// Column widths and bar geometry shared by every category bar row (#389).
///
/// Tokenised rather than inlined because the collapsed band and the expanded
/// panel draw the SAME row: if the two drifted, the bars would start at
/// different x positions and expanding the card would visibly shift them.
enum FinanceBarRowMetrics {
    static let icon: CGFloat = 18

    /// Category-name column. macOS only — the iPhone row is two-line and lets
    /// the name size itself, because a fixed column at 326pt content width was
    /// forcing `minimumScaleFactor` on half the category names.
    static let name: CGFloat = 150

    /// Share-of-period column.
    static var share: CGFloat {
        #if os(macOS)
        34
        #else
        30
        #endif
    }

    static var amount: CGFloat {
        #if os(macOS)
        116
        #else
        104
        #endif
    }

    static let barHeight: CGFloat = 8

    /// Where the iPhone row's second line (the bar) starts, so it lines up with
    /// the category name above it rather than the icon.
    static var barLeadingInset: CGFloat { icon + Space.sm }
}

/// Layout metrics for the expanded panel (#389).
enum FinancePanelMetrics {
    /// Content width at which the panel goes from one column to two.
    ///
    /// A measure cap was tried first and was wrong: the card grew with the
    /// window while its content stopped short, so full-screening the app left
    /// dead space to the right and read as "the dashboard doesn't expand".
    /// Two columns spend the width instead of ignoring it, and keep each
    /// element at a sane size rather than drawing an 1100pt bar.
    ///
    /// 980 sits clear of both real cases: a 1050pt window gives ~736pt of card
    /// content (one column, unchanged), a full-screen 1512pt window ~1240pt
    /// (two columns). The iPhone is nowhere near it.
    static let twoColumnThreshold: CGFloat = 980

    /// Gap between section tiles, in both directions.
    static let tileGap: CGFloat = Space.md

    /// Padding inside a section tile. Tighter than the card's own `Space.lg` so
    /// one level of nesting doesn't read as bloat.
    static let tilePadding: CGFloat = Space.md

    /// Categories shown before the "Show all" row. Everything past this is
    /// rounding error in practice, and 13 rows is what made the card unwieldy.
    static let categoryPreviewCount = 8

    static var chartHeight: CGFloat {
        #if os(macOS)
        112
        #else
        120
        #endif
    }

    /// Chart height in two-column mode, where the chart sits beside a taller
    /// category list.
    static let wideChartHeight: CGFloat = 168

    /// Widest a single bar may draw, regardless of how much room its cell has.
    static var maxBarWidth: CGFloat {
        #if os(macOS)
        52
        #else
        32
        #endif
    }

    /// Top-corner radius of a chart bar. Top-only: a uniform radius this round
    /// would visibly detach short bars from the baseline rule.
    static var barCornerRadius: CGFloat {
        #if os(macOS)
        8
        #else
        6
        #endif
    }

    static var showAllRowHeight: CGFloat {
        #if os(macOS)
        24
        #else
        32
        #endif
    }
}

/// One category row: icon, name, proportional bar, share of period, amount.
/// Used by the collapsed band (top three) and the expanded panel (the rest).
///
/// Single-line table on macOS, two-line on iOS. Both keep every bar starting at
/// a fixed x and scaled to the same `maxTotal`, which is what makes the list
/// comparable down the column.
struct FinanceCategoryBarRow: View {
    let slice: FinanceCategorySlice
    /// Largest total in the set being drawn, so bars are proportional to the
    /// biggest category rather than to the period total.
    let maxTotal: Double

    var body: some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HStack(spacing: Space.sm) {
            icon
            name.frame(width: FinanceBarRowMetrics.name, alignment: .leading)
            bar
            share
            amount
        }
        #else
        // Two lines on the phone: the bar gets the full row width instead of
        // the ~58pt left over after four fixed columns, which is the difference
        // between a readable proportion and a nub.
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                icon
                name
                Spacer(minLength: Space.sm)
                share
                amount
            }
            bar.padding(.leading, FinanceBarRowMetrics.barLeadingInset)
        }
        #endif
    }

    private var icon: some View {
        Image(systemName: slice.category.sfSymbol)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Tokens.accentFinance)
            .frame(width: FinanceBarRowMetrics.icon)
    }

    private var name: some View {
        Text(slice.category.displayName)
            .font(.edFootnote)
            .foregroundStyle(Tokens.inkSoft)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var bar: some View {
        // A net-negative category (refunds outweighed spend, #206) would give a
        // negative ratio; clamp to 0 so the bar just empties rather than drawing
        // a negative width. The trailing amount still shows the true net.
        let ratio = maxTotal > 0 ? Swift.max(0, slice.total / maxTotal) : 0
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Tokens.paper2)
                if ratio > 0 {
                    Capsule()
                        .fill(Tokens.accentFinance.opacity(0.85))
                        // Floor at the bar's own height so a sub-1% category
                        // renders as a round dot instead of a 1pt sliver.
                        .frame(
                            width: Swift.max(
                                FinanceBarRowMetrics.barHeight,
                                proxy.size.width * CGFloat(ratio)
                            )
                        )
                }
            }
        }
        .frame(height: FinanceBarRowMetrics.barHeight)
    }

    private var share: some View {
        Text(shareText)
            .font(.edCaption)
            .monospacedDigit()
            .foregroundStyle(Tokens.mutedSoft)
            .frame(width: FinanceBarRowMetrics.share, alignment: .trailing)
    }

    private var amount: some View {
        Text(amountText)
            .font(.edFootnote)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(isCredit ? Tokens.success : Tokens.inkSoft)
            .frame(width: FinanceBarRowMetrics.amount, alignment: .trailing)
    }

    /// A category whose refunds outweighed its spend. Same money as a refunded
    /// expense row, so it gets the same house treatment: "+" and the success
    /// colour (#206), rather than a bare minus against an empty bar.
    private var isCredit: Bool { slice.total < 0 }

    private var amountText: String {
        let formatted = FinanceDashboardBand.formatMoney(abs(slice.total))
        return isCredit ? "+\(formatted)" : formatted
    }

    /// Empty (not "0%") when the period nets to zero or less, or when this
    /// slice is itself a credit — a negative percentage of spend reads as
    /// broken. The column keeps its width either way so rows stay aligned.
    private var shareText: String {
        guard !isCredit, let share = slice.share else { return "" }
        let percent = share * 100
        if percent > 0 && percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }

    private var accessibilityText: String {
        var parts = [slice.category.displayName, amountText]
        if isCredit { parts[1] = "\(amountText) refunded" }
        if let share = slice.share, !isCredit {
            parts.append("\(Int((share * 100).rounded())) percent of the period")
        }
        return parts.joined(separator: ", ")
    }
}

/// The expanded half of the Finance dashboard card (#389): a spend-over-time
/// bar chart at a granularity picked from the selected period, the category
/// breakdown, top merchants, and a summary strip.
///
/// Four blocks separated by hairline rules with stepped-up `edHeading` titles,
/// rather than nested cards. On this palette `surface2` sits 6/255 from
/// `surface`, so a nested block would only read via a second border ring inside
/// the card's own — box-in-box. Every other section separation in the app is a
/// rule plus a header, and the flat read here was a type-hierarchy problem
/// (10pt heading over 11pt rows), not a container problem.
///
/// Every number comes from the same `FinanceInsights` the collapsed band reads,
/// which is built from the same filtered rows as the expense list.
struct FinanceInsightsPanel: View {
    let insights: FinanceInsights

    /// Bar the user tapped (iOS) or is hovering (macOS). `nil` falls back to
    /// reading out the peak bucket.
    @State private var selectedBucket: Int?

    /// Whether the category list is showing past `categoryPreviewCount`.
    @State private var showAllCategories: Bool = false

    /// The panel's own width, measured without affecting layout, so the column
    /// count follows the window instead of a hardcoded breakpoint guess.
    @State private var panelWidth: CGFloat = 0

    private var isWide: Bool { panelWidth >= FinancePanelMetrics.twoColumnThreshold }

    var body: some View {
        layout
            // Measuring in a background overlay rather than wrapping in a
            // GeometryReader: a GeometryReader would claim all available height
            // and break the card's vertical sizing inside the ScrollView. The
            // measured width is set by the parent card and never by the layout
            // choice below it, so there is no feedback loop.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: PanelWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(PanelWidthKey.self) { width in
                panelWidth = width
            }
    }

    @ViewBuilder
    private var layout: some View {
        if isWide {
            // Chart beside categories, merchants beside the summary. Halves the
            // card's height on a wide window and keeps bars and bar charts at a
            // size that still reads. Tiles in a row stretch to the taller of the
            // pair so their bottom edges line up.
            VStack(alignment: .leading, spacing: FinancePanelMetrics.tileGap) {
                columns(
                    left: { chartBlock(stretch: true) },
                    right: { categoriesBlock(stretch: true) }
                )
                if insights.merchants.isEmpty {
                    summaryBlock(stretch: false)
                } else {
                    columns(
                        left: { merchantsBlock(stretch: true) },
                        right: { summaryBlock(stretch: true) }
                    )
                }
            }
        } else {
            VStack(alignment: .leading, spacing: FinancePanelMetrics.tileGap) {
                chartBlock(stretch: false)
                categoriesBlock(stretch: false)
                if !insights.merchants.isEmpty {
                    merchantsBlock(stretch: false)
                }
                summaryBlock(stretch: false)
            }
        }
    }

    /// Two equal-width columns, top-aligned. No rule between them: the tile
    /// edges do the separating now.
    private func columns<L: View, R: View>(
        @ViewBuilder left: () -> L,
        @ViewBuilder right: () -> R
    ) -> some View {
        HStack(alignment: .top, spacing: FinancePanelMetrics.tileGap) {
            left()
                .frame(maxWidth: .infinity, alignment: .leading)
            right()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One section, as a tile.
    ///
    /// A raised `surface2` fill plus a hairline, one radius step tighter than
    /// the card that holds it. The 6/255 dark-mode gap between `surface2` and
    /// `surface` is why the border is not optional — it is what makes the tile
    /// an object rather than a smudge.
    ///
    /// - Parameter stretch: fill the height offered, for a tile paired
    ///   side-by-side with a taller one. Content stays pinned to the top.
    private func sectionTile<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        stretch: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            sectionHeader(title, subtitle: subtitle)
            content()
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: stretch ? .infinity : nil,
            alignment: .topLeading
        )
        .padding(FinancePanelMetrics.tilePadding)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    /// Section title, one step up the ramp from the rows it labels, with an
    /// optional live subtitle beneath it.
    private func sectionHeader(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.edCaption)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Spend over time

    private func chartBlock(stretch: Bool) -> some View {
        // `readout ?? " "` reserves the line so selecting a bar doesn't reflow
        // the chart under the user's finger.
        sectionTile(
            insights.granularity.chartTitle,
            subtitle: readout ?? " ",
            stretch: stretch
        ) {
            if maxBucketTotal > 0 {
                chart
            } else {
                Text("No spending in this period")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: chartHeight / 2)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(insights.buckets) { bucket in
                        bar(bucket)
                    }
                }
                .frame(height: chartHeight)

                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)

                averageLine
            }
            .frame(height: chartHeight)
            axisRow
        }
    }

    private func bar(_ bucket: FinanceSpendBucket) -> some View {
        let ratio = maxBucketTotal > 0 ? Swift.max(0, bucket.total / maxBucketTotal) : 0
        let isSelected = selectedBucket == bucket.id
        let dimmed = selectedBucket != nil && !isSelected
        // 1.5pt keeps an empty bucket visible as a stub on the baseline rather
        // than vanishing, so gaps in spending still read as periods.
        let height = Swift.max(1.5, CGFloat(ratio) * chartHeight)
        let opacity: Double = dimmed ? 0.28 : (isSelected ? 1.0 : 0.8)
        // Clamped so the empty-bucket stub doesn't render as a lozenge.
        let radius = Swift.min(FinancePanelMetrics.barCornerRadius, height / 2)

        return ZStack(alignment: .bottom) {
            Color.clear
            UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: radius,
                style: .continuous
            )
            .fill(Tokens.accentFinance.opacity(bucket.total > 0 ? opacity : 0.22))
            // Capped so a five-bar month reads as a bar chart rather than five
            // blocks filling the card. Dense series stay under the cap and keep
            // dividing the width evenly, and the cell itself still takes an
            // equal share either way — which is what keeps the axis labels
            // under their own bars.
            .frame(maxWidth: FinancePanelMetrics.maxBarWidth)
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
            let y = CGFloat(ratio) * chartHeight
            FinanceChartRule()
                .stroke(Tokens.borderStrong, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .frame(height: 1)
                .overlay(alignment: .trailing) {
                    Text("avg")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                        .padding(.horizontal, 2)
                        // Knocks out the dashed rule behind it, so it has to
                        // match the TILE's fill, not the card's.
                        .background(Tokens.surface2)
                        .offset(y: -7)
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
                        .font(.edCaption)
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
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
                .lineLimit(1)
        }
    }

    // MARK: - Categories

    private func categoriesBlock(stretch: Bool) -> some View {
        sectionTile("Categories", stretch: stretch) {
            if insights.categories.isEmpty {
                Text("Nothing to break down yet")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            } else {
                // Proportional to the largest category overall, not to the
                // largest VISIBLE one, so revealing the tail doesn't rescale
                // every bar above it.
                let maxTotal = insights.categories.map(\.total).max() ?? 1
                VStack(alignment: .leading, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: Space.md) {
                        ForEach(visibleCategories) { slice in
                            FinanceCategoryBarRow(slice: slice, maxTotal: maxTotal)
                        }
                    }
                    if insights.categories.count > FinancePanelMetrics.categoryPreviewCount {
                        showAllCategoriesRow
                    }
                }
            }
        }
    }

    private var visibleCategories: [FinanceCategorySlice] {
        guard !showAllCategories else { return insights.categories }
        return Array(insights.categories.prefix(FinancePanelMetrics.categoryPreviewCount))
    }

    private var showAllCategoriesRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                showAllCategories.toggle()
            }
        } label: {
            HStack(spacing: Space.xs) {
                Text(showAllCategories ? "Show fewer" : "Show all \(insights.categories.count) categories")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.muted)
                    .rotationEffect(.degrees(showAllCategories ? 180 : 0))
                Spacer(minLength: 0)
            }
            // Lands on the name column, not the icon column.
            .padding(.leading, FinanceBarRowMetrics.barLeadingInset)
            .frame(minHeight: FinancePanelMetrics.showAllRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Merchants

    /// Name and amount only. No bar and no expense count: a second green bar
    /// chart directly under the first makes the two blocks interchangeable, and
    /// a merchant "share" would be relative to the top six rather than to any
    /// real whole. Sort order plus the amount already answer the question.
    private func merchantsBlock(stretch: Bool) -> some View {
        sectionTile("Top merchants", stretch: stretch) {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(insights.merchants) { merchant in
                    HStack(spacing: Space.sm) {
                        Text(merchant.name)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: Space.sm)
                        Text(FinanceDashboardBand.formatMoney(merchant.total))
                            .font(.edFootnote)
                            .monospacedDigit()
                            .foregroundStyle(Tokens.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Summary

    /// The three period stats, as plain columns inside the section tile.
    ///
    /// They were individually tiled before every section became a tile; tiles
    /// inside a tile is one nesting level too many, so the hairlines carry the
    /// separation here and the tile edge carries the block.
    private func summaryBlock(stretch: Bool) -> some View {
        sectionTile("Summary", stretch: stretch) {
            if stretch {
                // Paired with the taller merchants tile, so the stats sit
                // optically centred in the leftover height instead of leaving a
                // third of the tile visibly empty under them.
                VStack(spacing: 0) {
                    Spacer(minLength: Space.sm)
                    summaryStats
                    Spacer(minLength: Space.sm)
                }
            } else {
                summaryStats
            }
        }
    }

    private var summaryStats: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            summaryStat(
                label: "Expenses",
                value: "\(insights.transactionCount)",
                caption: nil
            )
            summaryStatDivider
            summaryStat(
                label: "Per day",
                value: FinanceDashboardBand.formatMoneyRounded(insights.averagePerDay),
                caption: nil
            )
            summaryStatDivider
            summaryStat(
                label: "Largest",
                value: insights.largestExpense.map { FinanceDashboardBand.formatMoneyRounded($0.amount) } ?? "–",
                caption: insights.largestExpense?.label
            )
        }
    }

    private func summaryStat(label: String, value: String, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(label).eyebrow()
            Text(value)
                .font(.edHeading)
                .monospacedDigit()
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            // Always rendered, blank when absent: only "Largest" has a caption,
            // and reserving the line keeps the three columns the same height.
            Text(caption ?? " ")
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    /// `border`, not `divider`: the tile's `surface2` fill is close enough to
    /// `divider` in light mode that the rule would disappear.
    private var summaryStatDivider: some View {
        Rectangle()
            .fill(Tokens.border)
            .frame(width: 0.5, height: 34)
    }

    // MARK: - Derived values

    /// Chart height. Taller in two-column mode, where the chart sits beside a
    /// taller category list and a short chart leaves the row looking unfinished.
    private var chartHeight: CGFloat {
        isWide ? FinancePanelMetrics.wideChartHeight : FinancePanelMetrics.chartHeight
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

/// Carries the panel's measured width up to `FinanceInsightsPanel`, which uses
/// it to pick a column count.
private struct PanelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
