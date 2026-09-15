import SwiftUI

/// Layout metrics for the expanded Trends panel (#545). Mirrors
/// `FinancePanelMetrics` so the two expanded dashboards read as one app.
enum MealTrendsPanelMetrics {
    /// Content width at which the panel goes from one column to two.
    static let twoColumnThreshold: CGFloat = 980

    static let tileGap: CGFloat = Space.md
    static let tilePadding: CGFloat = Space.md

    static var chartHeight: CGFloat {
        #if os(macOS)
        112
        #else
        120
        #endif
    }

    static let wideChartHeight: CGFloat = 168

    static var maxBarWidth: CGFloat {
        #if os(macOS)
        52
        #else
        32
        #endif
    }

    static var barCornerRadius: CGFloat {
        #if os(macOS)
        8
        #else
        6
        #endif
    }

    /// Height of one consistency cell.
    static let stripHeight: CGFloat = 16
}

/// The expanded half of the Trends card (#545): the calories chart with its
/// target rule, the balance table, the callouts and their consistency strips,
/// the meal-type split, and the logging-health strip.
///
/// Every number here comes from the same `MealInsights` the collapsed band
/// reads. There is one computation and two readers, which is the only
/// construction under which the band and the panel cannot disagree.
struct MealTrendsPanel: View {
    let insights: MealInsights
    /// The window's own name, e.g. "Last 7 days". Printed on the logging tile so
    /// the counts under it are never read against the wrong period.
    let periodLabel: String

    /// Fold under-logged days back into the averages. Owned by the tab so the
    /// choice survives the panel being rebuilt.
    @Binding var includePartialDays: Bool

    /// Hands the computed insights to chat. Exactly one API call, and only when
    /// this is pressed.
    let onAskDexter: () -> Void

    @State private var selectedBucket: Int?
    @State private var panelWidth: CGFloat = 0

    private var isWide: Bool { panelWidth >= MealTrendsPanelMetrics.twoColumnThreshold }

    var body: some View {
        layout
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MealPanelWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(MealPanelWidthKey.self) { panelWidth = $0 }
    }

    @ViewBuilder
    private var layout: some View {
        // Lazy on purpose (#442). Eight balance rows and four meal types are
        // cheap, but a 90-cell strip per callout plus up to 400 chart bars is
        // not, and an eager VStack builds every one of them before the first
        // frame whether the reader scrolls that far or not.
        LazyVStack(alignment: .leading, spacing: MealTrendsPanelMetrics.tileGap) {
            if isWide {
                columns(
                    left: { chartBlock(stretch: true) },
                    right: { balanceOrEmpty(stretch: true) }
                )
                if !insights.callouts.isEmpty {
                    calloutsBlock(stretch: false)
                }
                columns(
                    left: { mealTypeBlock(stretch: true) },
                    right: { healthBlock(stretch: true) }
                )
            } else {
                chartBlock(stretch: false)
                balanceOrEmpty(stretch: false)
                if !insights.callouts.isEmpty {
                    calloutsBlock(stretch: false)
                }
                mealTypeBlock(stretch: false)
                healthBlock(stretch: false)
            }
            askRow
        }
    }

    private func columns<L: View, R: View>(
        @ViewBuilder left: () -> L,
        @ViewBuilder right: () -> R
    ) -> some View {
        HStack(alignment: .top, spacing: MealTrendsPanelMetrics.tileGap) {
            left().frame(maxWidth: .infinity, alignment: .leading)
            right().frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A raised tile with a hairline, one radius step tighter than the card.
    /// The border is not optional: `surface2` sits 6/255 from `surface` in dark
    /// mode, and it is the border that makes the fill an object.
    private func sectionTile<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        stretch: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
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
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
        .padding(MealTrendsPanelMetrics.tilePadding)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    // MARK: - Calories chart

    private func chartBlock(stretch: Bool) -> some View {
        sectionTile(chartTitle, subtitle: chartReadout ?? " ", stretch: stretch) {
            if insights.buckets.contains(where: { $0.countedDays > 0 }) {
                chart
            } else {
                Text("No logged days in this period")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: chartHeight / 2)
            }
        }
    }

    private var chartTitle: String {
        switch insights.granularity {
        case .daily:   return "Calories a day"
        case .weekly:  return "Calories a day, by week"
        case .monthly: return "Calories a day, by month"
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

                targetLine
            }
            .frame(height: chartHeight)
            axisRow
        }
    }

    private func bar(_ bucket: MealCalorieBucket) -> some View {
        let ratio = chartMax > 0 ? max(0, bucket.averageCalories / chartMax) : 0
        let isSelected = selectedBucket == bucket.id
        let dimmed = selectedBucket != nil && !isSelected
        let height = max(1.5, CGFloat(ratio) * chartHeight)
        let opacity: Double = dimmed ? 0.28 : (isSelected ? 1.0 : 0.8)
        let radius = min(MealTrendsPanelMetrics.barCornerRadius, height / 2)
        // A bucket with no counted day is a gap in the log, not a day of no
        // eating. It draws as the faint stub an empty Finance bucket does, and
        // the readout says how many days stood behind the bar.
        let hasData = bucket.countedDays > 0

        return ZStack(alignment: .bottom) {
            Color.clear
            UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: radius,
                style: .continuous
            )
            .fill(Tokens.accentMeals.opacity(hasData ? opacity : 0.22))
            .frame(maxWidth: MealTrendsPanelMetrics.maxBarWidth)
            .frame(height: hasData ? height : 1.5)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { selectedBucket = isSelected ? nil : bucket.id }
        #if os(macOS)
        .onHover { hovering in
            if hovering { selectedBucket = bucket.id }
            else if selectedBucket == bucket.id { selectedBucket = nil }
        }
        #endif
        .accessibilityElement()
        .accessibilityLabel(
            hasData
                ? "\(bucket.readoutLabel), \(MealFormat.calories(bucket.averageCalories)) kilocalories a day"
                : "\(bucket.readoutLabel), not logged"
        )
    }

    /// The target, drawn straight across the chart.
    ///
    /// This rule is the reason the chart is worth drawing at all. A row of bars
    /// answers "were some days bigger than others", which nobody needed a chart
    /// for. The rule turns it into "which days went over", which is the
    /// question, and it reads without a single label being consulted.
    @ViewBuilder
    private var targetLine: some View {
        if let target = insights.calorieTarget, chartMax > 0 {
            let ratio = target / chartMax
            let y = CGFloat(min(ratio, 1)) * chartHeight
            MealChartRule()
                .stroke(Tokens.borderStrong, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .frame(height: 1)
                .overlay(alignment: .trailing) {
                    Text("target")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                        .padding(.horizontal, 2)
                        // Knocks out the dashed rule behind it, so it has to
                        // match the TILE's fill, not the card's.
                        .background(Tokens.surface2)
                        .offset(y: -7)
                }
                .offset(y: -y)
                .accessibilityLabel("Calorie target \(MealFormat.calories(target)) kilocalories")
        }
    }

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
    private func edgeLabel(_ bucket: MealCalorieBucket?) -> some View {
        if let bucket {
            Text(bucket.axisLabel)
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
                .lineLimit(1)
        }
    }

    // MARK: - Balance table

    @ViewBuilder
    private func balanceOrEmpty(stretch: Bool) -> some View {
        if insights.balance.isEmpty {
            // Absent, not empty. Over and under are undefined with no target,
            // and a table of eight blank verdicts says less than one sentence
            // saying why there is no table.
            sectionTile("Balance", stretch: stretch) {
                Text("No targets are set, so there is nothing to read these averages against. Set your targets and this becomes a table of eight verdicts.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            sectionTile("Balance", subtitle: balanceSubtitle, stretch: stretch) {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(insights.balance) { row in
                        MealBalanceBarRow(row: row)
                    }
                }
            }
        }
    }

    private var balanceSubtitle: String {
        let noun = insights.health.daysLogged == 1 ? "day" : "days"
        return "Average of \(insights.health.daysLogged) logged \(noun), against target"
    }

    // MARK: - Callouts

    private func calloutsBlock(stretch: Bool) -> some View {
        sectionTile("What stands out", stretch: stretch) {
            VStack(alignment: .leading, spacing: Space.lg) {
                ForEach(insights.callouts) { callout in
                    calloutRow(callout)
                }
            }
        }
    }

    @ViewBuilder
    private func calloutRow(_ callout: MealCallout) -> some View {
        let strip = insights.consistency.first { $0.nutrient == callout.nutrient }
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.sm) {
                Circle()
                    .fill(callout.band.tint)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                Text(callout.text)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let strip {
                consistencyStrip(strip)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// One cell per day, coloured by that day's own band.
    ///
    /// The most readable thing in the panel: a run or a streak lands in half a
    /// second, and a steady miss looks nothing like a fortnight with two bad
    /// evenings even though the two can share an average.
    private func consistencyStrip(_ strip: MealConsistencyStrip) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: strip.cells.count > 45 ? 1 : 2) {
                ForEach(strip.cells) { cell in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(cell.band?.tint.opacity(0.85) ?? Tokens.paper2)
                        .frame(maxWidth: .infinity)
                        .frame(height: MealTrendsPanelMetrics.stripHeight)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(stripAccessibility(strip))
            if strip.isClipped {
                Text("Most recent \(strip.cells.count) days of the period")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
        }
    }

    private func stripAccessibility(_ strip: MealConsistencyStrip) -> String {
        let read = strip.cells.filter { $0.band != nil }.count
        let flagged = strip.cells.filter { $0.band?.isFlagged == true }.count
        return "\(strip.nutrient.displayName) day by day. \(flagged) of \(read) logged days off target."
    }

    // MARK: - Meal types

    /// Average calories by part of the day.
    ///
    /// Usually where the actionable fact is hiding. "Snacks are 40% of your
    /// intake" is a thing to do something about, and no per-nutrient row will
    /// ever surface it.
    private func mealTypeBlock(stretch: Bool) -> some View {
        sectionTile("Where the calories come from", stretch: stretch) {
            if insights.averageCalories <= 0 {
                Text("Nothing logged to break down yet")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            } else {
                let maxValue = insights.byMealType.map(\.averageCalories).max() ?? 1
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(insights.byMealType) { slice in
                        mealTypeRow(slice, maxValue: maxValue)
                    }
                }
            }
        }
    }

    private func mealTypeRow(_ slice: MealTypeAverage, maxValue: Double) -> some View {
        let ratio = maxValue > 0 ? max(0, slice.averageCalories / maxValue) : 0
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Image(systemName: slice.mealType.sfSymbol)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Tokens.accentMeals)
                    .frame(width: 18)
                Text(slice.mealType.displayName)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                Spacer(minLength: Space.sm)
                Text(slice.share.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
                    .font(.edCaption)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.mutedSoft)
                Text("\(MealFormat.calories(slice.averageCalories)) kcal")
                    .font(.edFootnote)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.paper2)
                    if ratio > 0 {
                        Capsule()
                            .fill(Tokens.accentMeals.opacity(0.85))
                            .frame(width: max(8, geo.size.width * CGFloat(ratio)))
                    }
                }
            }
            .frame(height: 8)
            .padding(.leading, 18 + Space.sm)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Logging health

    /// How well the log itself was kept. Makes the feature's own reliability
    /// visible without a single extra tool.
    private func healthBlock(stretch: Bool) -> some View {
        sectionTile(
            "Logging",
            subtitle: "\(periodLabel), \(insights.health.totalDays) days",
            stretch: stretch
        ) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top, spacing: Space.sm) {
                    stat("Logged", "\(insights.health.daysLogged)")
                    statDivider
                    stat("Partial", "\(insights.health.partialDays)")
                    statDivider
                    stat("Not logged", "\(insights.health.unloggedDays)")
                }

                Rectangle().fill(Tokens.border).frame(height: 0.5)

                HStack(alignment: .top, spacing: Space.sm) {
                    stat("Needs detail", "\(insights.health.needsDetailCount)")
                    statDivider
                    stat("Suspect", "\(insights.health.suspectCount)")
                    statDivider
                    stat("Corrected", "\(insights.health.correctedCount)")
                }

                Rectangle().fill(Tokens.border).frame(height: 0.5)

                HStack(alignment: .top, spacing: Space.sm) {
                    stat("Composer", "\(insights.health.composerCount)")
                    statDivider
                    stat("Chat", "\(insights.health.chatCount)")
                    statDivider
                    stat("Shortcut", "\(insights.health.captureCount)")
                }

                partialToggle
            }
        }
    }

    /// A day below half the calorie target is under-LOGGED, not under-eaten,
    /// and folding it into an average reads as the second when it is the first.
    /// Out by default, and the toggle is here rather than in the filter bar
    /// because this is the block that says how many days it is about.
    private var partialToggle: some View {
        Toggle(isOn: $includePartialDays) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Count partial days")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                Text("A day under half the calorie target is treated as under-logged, not as under-eaten.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Tokens.accentMeals)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(label).eyebrow()
            Text(value)
                .font(.edHeading)
                .monospacedDigit()
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    /// `border`, not `divider`: the tile's `surface2` fill is close enough to
    /// `divider` in light mode that the rule would disappear.
    private var statDivider: some View {
        Rectangle().fill(Tokens.border).frame(width: 0.5, height: 30)
    }

    // MARK: - Ask Dexter

    private var askRow: some View {
        Button(action: onAskDexter) {
            HStack(spacing: Space.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Text("Ask Dexter about this")
                    .font(.edFootnote)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.mutedSoft)
            }
            .foregroundStyle(Tokens.accentMeals)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity)
            .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask Dexter about this analysis")
    }

    // MARK: - Derived

    private var chartHeight: CGFloat {
        isWide ? MealTrendsPanelMetrics.wideChartHeight : MealTrendsPanelMetrics.chartHeight
    }

    /// Top of the chart. Always leaves the target rule on screen, and gives it
    /// 5% of headroom so it never sits exactly on the top edge where it would
    /// read as the frame rather than as a value.
    private var chartMax: Double {
        let peak = insights.buckets.map(\.averageCalories).max() ?? 0
        let target = insights.calorieTarget ?? 0
        return max(peak, target * 1.05, 1)
    }

    private var barSpacing: CGFloat {
        let count = insights.buckets.count
        if count > 20 { return 2 }
        if count > 10 { return 3 }
        return 5
    }

    private var showsPerBarLabels: Bool {
        switch insights.granularity {
        case .daily:   return insights.buckets.count <= 10
        case .weekly:  return insights.buckets.count <= 6
        case .monthly: return insights.buckets.count <= 12
        }
    }

    private var chartReadout: String? {
        if let selectedBucket,
           let bucket = insights.buckets.first(where: { $0.id == selectedBucket }) {
            guard bucket.countedDays > 0 else { return "\(bucket.readoutLabel) · not logged" }
            return "\(bucket.readoutLabel) · \(MealFormat.calories(bucket.averageCalories)) kcal a day"
        }
        guard let target = insights.calorieTarget else {
            guard insights.averageCalories > 0 else { return nil }
            return "\(MealFormat.calories(insights.averageCalories)) kcal a day on average"
        }
        return "Target \(MealFormat.calories(target)) kcal a day"
    }
}

/// Carries the panel's measured width up so the column count follows the window.
private struct MealPanelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Horizontal rule through the middle of its frame, for the dashed target line.
/// `Rectangle` cannot be dashed.
private struct MealChartRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
