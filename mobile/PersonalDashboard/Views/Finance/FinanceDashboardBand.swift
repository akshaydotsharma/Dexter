import SwiftUI

/// Snapshot stats shown at the top of the Finance surface. Computed once
/// per render from the live `expenses` array. Recomputing in-place keeps
/// the data path simple: no service-layer caching for Phase A.
///
/// The breakdown cuts (categories, chart buckets, merchants) moved to
/// `FinanceInsights` in #389 — this holds only the headline figures.
struct FinanceDashboardStats {
    let monthTotal: Double
    let previousMonthTotal: Double
    /// Period total normalised to a 30.44-day month (#255), so "This year"
    /// or a custom range both read as a comparable monthly run-rate.
    let averagePerMonth: Double

    var deltaPercent: Double? {
        guard previousMonthTotal > 0 else { return nil }
        return (monthTotal - previousMonthTotal) / previousMonthTotal
    }
}

/// Dashboard band: period total, delta vs the prior period, top-3 category
/// bars, and an expand control that reveals the fuller `FinanceInsightsPanel`
/// (#389). Card-shaped, uses the Finance accent for the secondary indicators.
///
/// The 30-day sparkline it used to carry was removed in #389: an unaxised line
/// over spiky daily spend answered neither "which weeks were expensive" nor
/// "where did the money go". The expanded panel answers both.
struct FinanceDashboardBand: View {
    let stats: FinanceDashboardStats

    /// Every breakdown cut over the same filtered rows as the headline. The
    /// collapsed band reads `topCategories` from it; expanding hands the whole
    /// thing to `FinanceInsightsPanel`.
    let insights: FinanceInsights

    /// Header eyebrow reflecting the selected date-range preset (#187),
    /// e.g. "This month", "Last 30 days", or a custom span like "3 – 18 Jun".
    let headerLabel: String

    /// Wording appended to the delta chip's accessibility label (#187),
    /// e.g. "vs last month" / "vs previous period". Purely for VoiceOver;
    /// the on-screen chip stays a compact percentage.
    let deltaComparisonLabel: String

    /// Owned by `FinanceView` so the expanded state survives the band being
    /// rebuilt on every filter / search keystroke.
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header
            Text(Self.formatMoney(stats.monthTotal))
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .tracking(-0.6)

            Text("\(Self.formatMoneyRounded(stats.averagePerMonth)) / month")
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .monospacedDigit()

            if isExpanded {
                // The full breakdown replaces the top-3 bars rather than
                // repeating them: the panel's category block IS the same list,
                // unclipped.
                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
                    .padding(.top, Space.xs)
                FinanceInsightsPanel(insights: insights)
                    // With the VStack's own `Space.md`, this puts 16 above and
                    // below the seam — the same rhythm the panel uses between
                    // its own blocks.
                    .padding(.top, Space.xs)
            } else if !insights.topCategories.isEmpty {
                categoryBars
                    .padding(.top, Space.xs)
            }
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(headerLabel).eyebrow()
            Spacer(minLength: Space.sm)
            deltaChip
            expandButton
        }
        // The whole header row toggles, not just the 24pt chevron — the chip
        // and the label are the obvious things to reach for.
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    private var expandButton: some View {
        Button {
            toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.muted)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide spending breakdown" : "Show spending breakdown")
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.22)) {
            isExpanded.toggle()
        }
    }

    // MARK: - Delta chip

    @ViewBuilder
    private var deltaChip: some View {
        if let delta = stats.deltaPercent {
            let isUp = delta >= 0
            let symbol = isUp ? "arrow.up.right" : "arrow.down.right"
            let chipColor: Color = isUp ? Tokens.danger : Tokens.success
            let chipBg: Color = isUp ? Tokens.dangerSoft : Tokens.successSoft
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(formatDelta(delta))
                    .font(.edFootnote)
            }
            .foregroundStyle(chipColor)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 4)
            .background(chipBg, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(isUp ? "Up" : "Down") \(formatDelta(delta)) \(deltaComparisonLabel)")
        } else if stats.previousMonthTotal == 0 && stats.monthTotal > 0 {
            Text("First month")
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 4)
                .background(Tokens.paper2, in: Capsule())
        }
    }

    private func formatDelta(_ value: Double) -> String {
        let percent = abs(value) * 100
        return String(format: "%.0f%%", percent)
    }

    // MARK: - Category bars

    /// Top three categories in the collapsed state. Same row construction as
    /// the expanded panel's full list (`FinanceCategoryBarRow`), so the bars sit
    /// at identical x positions before and after expanding.
    private var categoryBars: some View {
        let maxValue = insights.topCategories.map(\.total).max() ?? 1
        return VStack(alignment: .leading, spacing: Space.md) {
            ForEach(insights.topCategories) { slice in
                FinanceCategoryBarRow(slice: slice, maxTotal: maxValue)
            }
        }
        // Same measure cap the expanded panel uses, so the bars don't jump
        // width when the card opens.
        .frame(maxWidth: FinancePanelMetrics.contentMeasure, alignment: .leading)
    }

    // MARK: - Formatting

    /// Format an SGD-base value in the user's chosen display currency.
    ///
    /// Finance stores everything in SGD (`LocalExpense.sgdAmount`); this is a
    /// display-only conversion applied at render time. Reads the chosen
    /// currency + cached factor from `FinanceSettings` and computes
    /// `displayValue = sgdValue / factor` (the factor is "1 display unit =
    /// N SGD"). Falls back to the original SGD formatting when the display
    /// currency IS SGD or no usable cached factor exists, so the app behaves
    /// exactly as before until a foreign currency is picked and warmed.
    static func formatMoney(_ sgdValue: Double) -> String {
        let code = FinanceSettings.displayCurrencyCode.uppercased()
        let factor = FinanceSettings.displayRateToSGD

        // SGD, or a missing/invalid cached factor → keep the original SGD
        // styling ("SGD 1,247.50" reads cleaner than "$1,247.50 SGD").
        guard code != "SGD", factor.isFinite, factor > 0 else {
            return formatSGD(sgdValue)
        }

        let displayValue = sgdValue / factor
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        // Prefix "<CODE> " for a consistent, locale-independent read that
        // matches the SGD styling (e.g. "USD 927.31", "EUR 812.40").
        formatter.currencySymbol = "\(code) "
        return formatter.string(from: NSNumber(value: displayValue)) ?? "\(code) 0.00"
    }

    /// Same conversion as `formatMoney` but with 0 fraction digits (e.g.
    /// "SGD 5,293"), used for the secondary "average / month" line (#255)
    /// where cents are noise.
    static func formatMoneyRounded(_ sgdValue: Double) -> String {
        let code = FinanceSettings.displayCurrencyCode.uppercased()
        let factor = FinanceSettings.displayRateToSGD

        guard code != "SGD", factor.isFinite, factor > 0 else {
            return formatSGDRounded(sgdValue)
        }

        let displayValue = sgdValue / factor
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        formatter.currencySymbol = "\(code) "
        return formatter.string(from: NSNumber(value: displayValue)) ?? "\(code) 0"
    }

    /// SGD-only, 0-fraction-digit variant of `formatSGD`.
    private static func formatSGDRounded(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "SGD"
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        formatter.currencySymbol = "SGD "
        return formatter.string(from: NSNumber(value: value)) ?? "SGD 0"
    }

    /// SGD-only formatter (the base-currency fast path used by `formatMoney`).
    private static func formatSGD(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "SGD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        // "SGD 1,247.50" reads cleaner than "$1,247.50 SGD".
        formatter.currencySymbol = "SGD "
        return formatter.string(from: NSNumber(value: value)) ?? "SGD 0.00"
    }
}
