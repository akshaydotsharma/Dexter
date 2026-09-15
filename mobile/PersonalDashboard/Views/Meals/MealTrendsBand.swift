import SwiftUI

/// The collapsed head of the Trends card, and the host of the expanded panel
/// (#545).
///
/// Same construction as `FinanceDashboardBand`: one headline figure, a chip, an
/// expander, and either a short preview or the whole panel. The preview rows and
/// the panel's table rows are the SAME `MealBalanceBarRow` over the SAME
/// `MealInsights.balance` array, so expanding the card cannot change a number,
/// a verdict or a bar position.
struct MealTrendsBand: View {
    let insights: MealInsights
    /// Eyebrow naming the window, e.g. "Last 7 days".
    let headerLabel: String

    @Binding var isExpanded: Bool
    @Binding var includePartialDays: Bool

    let onAskDexter: () -> Void

    /// True while the figures on screen are the previous window's and a fresh
    /// aggregation is still running. The band keeps the last known numbers
    /// rather than blanking, which keeps the layout still.
    var isRecomputing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header

            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(MealFormat.calories(insights.averageCalories))
                    .font(.edDisplay)
                    .foregroundStyle(Tokens.ink)
                    .tracking(-0.6)
                    .monospacedDigit()
                Text("kcal / day").eyebrow()
            }

            Text(secondaryLine)
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)

            if isExpanded {
                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
                    .padding(.top, Space.xs)
                MealTrendsPanel(
                    insights: insights,
                    periodLabel: headerLabel,
                    includePartialDays: $includePartialDays,
                    onAskDexter: onAskDexter
                )
                .padding(.top, Space.xs)
            } else {
                preview.padding(.top, Space.xs)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(headerLabel).eyebrow()
            if isRecomputing {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #else
                    .scaleEffect(0.6)
                    #endif
                    .accessibilityLabel("Updating averages")
            }
            Spacer(minLength: Space.sm)
            calorieChip
            expandButton
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    private var expandButton: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.muted)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide the breakdown" : "Show the breakdown")
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
    }

    /// The calorie verdict, read off the SAME balance row the table prints, so
    /// the chip and the table's calorie line cannot disagree.
    @ViewBuilder
    private var calorieChip: some View {
        if let row = insights.balance.first(where: { $0.nutrient == .calories }),
           let band = row.band,
           let ratio = row.ratio {
            HStack(spacing: 4) {
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(.edFootnote)
                    .monospacedDigit()
                Text(band.label)
                    .font(.edFootnote)
            }
            .foregroundStyle(band.tint)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 4)
            .background(chipBackground(band), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Calories \(Int((ratio * 100).rounded())) percent of target, \(band.label)")
        }
    }

    private func chipBackground(_ band: MealTrendBand) -> Color {
        switch band {
        case .onTrack: return Tokens.successSoft
        case .under, .watch: return Tokens.warningSoft
        case .over: return Tokens.dangerSoft
        }
    }

    // MARK: - Secondary line

    /// The divisor, stated. An average whose divisor is invisible is the one
    /// number on this screen that can be quietly wrong.
    private var secondaryLine: String {
        let health = insights.health
        guard health.daysLogged > 0 || health.partialDays > 0 else {
            return "Nothing logged in this period."
        }
        let dayNoun = health.daysLogged == 1 ? "day" : "days"
        var line = "Average of \(health.daysLogged) logged \(dayNoun)"
        if let target = insights.calorieTarget {
            line += ", against \(MealFormat.calories(target)) kcal"
        }
        if health.partialDays > 0 {
            let partialNoun = health.partialDays == 1 ? "partial day" : "partial days"
            line += insights.includesPartialDays
                ? ". \(health.partialDays) \(partialNoun) counted in."
                : ". \(health.partialDays) \(partialNoun) held out."
        } else {
            line += "."
        }
        return line
    }

    // MARK: - Collapsed preview

    /// Up to three flagged rows, or one sentence saying there are none.
    @ViewBuilder
    private var preview: some View {
        if insights.balance.isEmpty {
            Text("No targets are set, so this is an average and not a verdict. Open the breakdown for the chart and the logging split.")
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else if insights.flaggedBalance.isEmpty {
            Text("All eight nutrients averaged on track over this period.")
                .font(.edFootnote)
                .foregroundStyle(Tokens.success)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(insights.flaggedBalance) { row in
                    MealBalanceBarRow(row: row)
                }
            }
        }
    }
}

/// The band's shape, shown for the single frame between the tab appearing and
/// its first aggregation landing.
///
/// Without it the band would render a real zero on that frame, which reads as
/// "you ate nothing" rather than "still working".
struct MealTrendsBandPlaceholder: View {
    let headerLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(headerLabel).eyebrow()
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #else
                    .scaleEffect(0.6)
                    #endif
                Spacer(minLength: Space.sm)
            }
            bar(width: 180, height: 34)
            bar(width: 210, height: 12)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
        .accessibilityLabel("Working out \(headerLabel)")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(Tokens.paper2)
            .frame(width: width, height: height)
    }
}
