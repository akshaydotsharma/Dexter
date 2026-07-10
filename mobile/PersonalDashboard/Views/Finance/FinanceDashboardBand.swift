import SwiftUI

/// Snapshot stats shown at the top of the Finance surface. Computed once
/// per render from the live `expenses` array. Recomputing in-place keeps
/// the data path simple: no service-layer caching for Phase A.
struct FinanceDashboardStats {
    let monthTotal: Double
    let previousMonthTotal: Double
    let topCategories: [(category: ExpenseCategory, total: Double)]
    let dailyTotals: [(date: Date, total: Double)]
    /// Period total normalised to a 30.44-day month (#255), so "This year"
    /// or a custom range both read as a comparable monthly run-rate.
    let averagePerMonth: Double

    var deltaPercent: Double? {
        guard previousMonthTotal > 0 else { return nil }
        return (monthTotal - previousMonthTotal) / previousMonthTotal
    }
}

/// Dashboard band: month total, delta vs prior month, top-3 categories,
/// last-30-days sparkline. Card-shaped, uses the Finance accent for the
/// secondary indicators.
struct FinanceDashboardBand: View {
    let stats: FinanceDashboardStats

    /// Header eyebrow reflecting the selected date-range preset (#187),
    /// e.g. "This month", "Last 30 days", or a custom span like "3 – 18 Jun".
    let headerLabel: String

    /// Wording appended to the delta chip's accessibility label (#187),
    /// e.g. "vs last month" / "vs previous period". Purely for VoiceOver;
    /// the on-screen chip stays a compact percentage.
    let deltaComparisonLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(headerLabel).eyebrow()
                Spacer()
                deltaChip
            }
            Text(Self.formatMoney(stats.monthTotal))
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .tracking(-0.6)

            Text("\(Self.formatMoneyRounded(stats.averagePerMonth)) / month")
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .monospacedDigit()

            if !stats.topCategories.isEmpty {
                categoryBars
                    .padding(.top, Space.xs)
            }

            sparkline
                .frame(height: 36)
                .padding(.top, Space.xs)
                .accessibilityLabel("Spending over \(headerLabel.lowercased())")
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
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

    private var categoryBars: some View {
        let maxValue = stats.topCategories.map { $0.total }.max() ?? 1
        return VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(stats.topCategories, id: \.category) { entry in
                categoryBar(entry: entry, max: maxValue)
            }
        }
    }

    private func categoryBar(entry: (category: ExpenseCategory, total: Double), max: Double) -> some View {
        // A net-negative category (refunds outweighed spend, #206) would give a
        // negative ratio; clamp to 0 so the bar just empties rather than drawing
        // a negative width. The trailing SGD label still shows the true net.
        let ratio = max > 0 ? Swift.max(0, entry.total / max) : 0
        return HStack(spacing: Space.sm) {
            Image(systemName: entry.category.sfSymbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Tokens.accentFinance)
                .frame(width: 18)
            Text(entry.category.displayName)
                .font(.edFootnote)
                .foregroundStyle(Tokens.inkSoft)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Tokens.paper2)
                    Capsule()
                        .fill(Tokens.accentFinance.opacity(0.85))
                        .frame(width: proxy.size.width * CGFloat(ratio))
                }
            }
            .frame(height: 6)
            Text(Self.formatMoney(entry.total))
                .font(.edFootnote)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Tokens.inkSoft)
                .frame(width: 108, alignment: .trailing)
        }
    }

    // MARK: - Sparkline

    private var sparkline: some View {
        GeometryReader { proxy in
            let values = stats.dailyTotals.map { $0.total }
            let maxValue = (values.max() ?? 0)
            ZStack(alignment: .bottom) {
                // Baseline.
                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
                if maxValue > 0, values.count > 1 {
                    sparklinePath(values: values, size: proxy.size, maxValue: maxValue)
                        .stroke(
                            Tokens.accentFinance,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                    sparklineFill(values: values, size: proxy.size, maxValue: maxValue)
                        .fill(Tokens.accentFinance.opacity(0.08))
                } else {
                    Text("No spending in the last 30 days")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func sparklinePath(values: [Double], size: CGSize, maxValue: Double) -> Path {
        Path { path in
            let count = values.count
            let step = size.width / CGFloat(count - 1)
            for (idx, value) in values.enumerated() {
                let x = CGFloat(idx) * step
                // Clamp to >= 0 so a net-negative (refund) day rests on the
                // baseline instead of drawing below the frame (#206).
                let normalised = maxValue > 0 ? Swift.max(0, CGFloat(value / maxValue)) : 0
                let y = size.height - (normalised * (size.height - 2)) - 1
                if idx == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }

    private func sparklineFill(values: [Double], size: CGSize, maxValue: Double) -> Path {
        Path { path in
            let count = values.count
            let step = size.width / CGFloat(count - 1)
            path.move(to: CGPoint(x: 0, y: size.height))
            for (idx, value) in values.enumerated() {
                let x = CGFloat(idx) * step
                let normalised = maxValue > 0 ? Swift.max(0, CGFloat(value / maxValue)) : 0
                let y = size.height - (normalised * (size.height - 2)) - 1
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
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
