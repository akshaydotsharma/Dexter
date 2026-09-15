import SwiftUI

/// Geometry shared by every balance row, so the collapsed band and the expanded
/// table draw the SAME row (#545).
///
/// Tokenised for the reason `FinanceBarRowMetrics` is: if the two drifted, the
/// bars would start at different x positions and expanding the card would
/// visibly shift them.
enum MealBalanceMetrics {
    static let barHeight: CGFloat = 10

    /// Percent-of-target column.
    static var percent: CGFloat {
        #if os(macOS)
        44
        #else
        40
        #endif
    }

    /// Verdict-word column. Wide enough for "On track" at footnote size.
    static var verdict: CGFloat {
        #if os(macOS)
        66
        #else
        60
        #endif
    }

    /// Nutrient-name column. macOS only; the phone row is two-line and lets the
    /// name size itself.
    static let name: CGFloat = 104

    /// Value column ("1,940 / 2,100 kcal").
    static var value: CGFloat {
        #if os(macOS)
        140
        #else
        128
        #endif
    }
}

/// One nutrient's average against its target, with a bar that DIVERGES from a
/// centre line at 100% (#545).
///
/// ### Why not a fill-to-target bar
///
/// The day card uses one, and it is right there: a day is in progress, and the
/// question is how much is left. Here the day is over, many days are over, and
/// half of what this view exists to say is "you are systematically past this
/// one". A fill bar clamps at the target and cannot say it. Two nutrients both
/// pegged at a full bar, one at 101% and one at 190%, would read identically.
///
/// So the centre of the track is 100%, left is short and right is past, and the
/// track ends at 0% and 200%. A row beyond 200% pins at the edge and says its
/// real percent in the column beside it.
struct MealBalanceBarRow: View {
    let row: MealBalanceRow

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HStack(spacing: Space.sm) {
            name.frame(width: MealBalanceMetrics.name, alignment: .leading)
            value.frame(width: MealBalanceMetrics.value, alignment: .trailing)
            bar
            percent
            verdict
        }
        #else
        // Two lines on the phone. Four fixed columns leave the bar about 50 pt,
        // which is not enough for a diverging bar to diverge in.
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                name
                Spacer(minLength: Space.sm)
                value
            }
            HStack(spacing: Space.sm) {
                bar
                percent
                verdict
            }
        }
        #endif
    }

    private var name: some View {
        Text(row.nutrient.displayName)
            .font(.edFootnote)
            .foregroundStyle(Tokens.inkSoft)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var value: some View {
        Text(valueText)
            .font(.edFootnote)
            .monospacedDigit()
            .foregroundStyle(Tokens.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private var percent: some View {
        Text(percentText)
            .font(.edCaption)
            .monospacedDigit()
            .foregroundStyle(Tokens.mutedSoft)
            .frame(width: MealBalanceMetrics.percent, alignment: .trailing)
    }

    private var verdict: some View {
        Text(row.band?.label ?? "–")
            .font(.edCaption)
            .foregroundStyle(row.band?.tint ?? Tokens.mutedSoft)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: MealBalanceMetrics.verdict, alignment: .leading)
    }

    /// The diverging track.
    private var bar: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let magnitude = CGFloat(min(abs(offsetFromTarget), 1))
            // Floor at the bar's own height so a 2% miss is a visible nub on the
            // correct side rather than a hairline nobody can place.
            let width = magnitude > 0
                ? max(MealBalanceMetrics.barHeight, half * magnitude)
                : 0

            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.paper2)

                if width > 0, let tint = row.band?.tint {
                    Capsule()
                        .fill(tint.opacity(0.9))
                        .frame(width: width)
                        .offset(x: offsetFromTarget >= 0 ? half : half - width)
                }

                // The 100% mark. `borderStrong`, not `divider`: this rule sits
                // on a raised tile in the panel, where `divider` disappears in
                // light mode.
                Rectangle()
                    .fill(Tokens.borderStrong)
                    .frame(width: 1, height: MealBalanceMetrics.barHeight + 4)
                    .offset(x: half - 0.5)
            }
        }
        .frame(height: MealBalanceMetrics.barHeight + 4)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    // MARK: - Derived

    /// Signed distance from target as a fraction of it: 0 at target, -1 at
    /// nothing, +1 at double. Clamped by the caller at the track edges.
    private var offsetFromTarget: Double {
        guard let ratio = row.ratio else { return 0 }
        return ratio - 1
    }

    private var valueText: String {
        guard row.target > 0 else { return MealFormat.value(row.average, for: row.nutrient) }
        return "\(MealFormat.grams(row.average)) / \(MealFormat.grams(row.target)) \(row.nutrient.unit)"
    }

    private var percentText: String {
        guard let ratio = row.ratio else { return "" }
        let percent = ratio * 100
        if percent > 0 && percent < 1 { return "<1%" }
        return "\(Int(percent.rounded()))%"
    }

    private var accessibilityText: String {
        guard let ratio = row.ratio, let band = row.band else {
            return "\(row.nutrient.displayName), \(MealFormat.value(row.average, for: row.nutrient)) a day, no target"
        }
        return "\(row.nutrient.displayName), \(MealFormat.value(row.average, for: row.nutrient)) a day "
            + "of \(MealFormat.value(row.target, for: row.nutrient)), "
            + "\(Int((ratio * 100).rounded())) percent of target, \(band.label)"
    }
}
