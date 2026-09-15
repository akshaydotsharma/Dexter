import SwiftUI

/// A number in a box (#543).
///
/// ### Two pill species, and shape is what tells them apart
///
/// Meals draws two kinds of pill and they must never be confused for each
/// other. A `Capsule` — `MealFlagChip`, `TagPill` — carries a word about the
/// RECORD: confidence, needs detail, suspect, possible duplicate. A rounded
/// rectangle carries a QUANTITY. So red on a capsule means the record is wrong,
/// and red on a stat pill means the day is past a ceiling. Two different
/// sentences, told apart without reading either one.
///
/// ### Why it is tinted throughout
///
/// The day card's Watch chips used to tint only the value and leave the label
/// and the box grey, which is why a row of three did not scan: the eye had to
/// land on three small numbers to find the one that had gone red. A verdict
/// pill tints its label, its value, its fill and its stroke, so the reading is
/// available at the size of the whole pill.
///
/// ### Where the hue comes from
///
/// Never from here. A verdict is `Nutrient.verdict(value:target:)`, and the
/// colour is `MealVerdict.tint`. No view on this surface decides whether a
/// number is good — a view that did could paint a protein bar red for being
/// over, which is the one thing `NutrientGoalKind` exists to prevent.
struct MealStatPill: View {

    /// Which of the three readings this pill is giving.
    enum Variant: Equatable {
        /// No target to read the number against: a grey box with an ink value.
        /// Every macro pill in the estimate preview, and any day pill when
        /// `MealTargets` is nil.
        case neutral
        /// A number read against a target. Tinted throughout.
        case verdict(MealVerdict)
        /// The one headline figure on a surface. Exactly one per surface: the
        /// kcal total in the estimate preview.
        case accent
    }

    /// Rendered as an eyebrow, so it reads as a label without taking size
    /// budget from the figure under it. Uppercased by the modifier.
    let label: String
    let value: String
    var variant: Variant = .neutral

    /// True in a fixed row whose pills share the width evenly (the Watch row).
    /// False in a flowing row that wraps (the preview's macros), where a pill
    /// has to measure at its natural size or the layout cannot place it.
    var fillsWidth: Bool = false

    /// Overrides the spoken reading. The visible text is shorthand — "1,900 mg"
    /// says nothing about the target it is under — so a caller that knows the
    /// target passes the full sentence here.
    var accessibilityText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .eyebrow(labelInk)
                .lineLimit(1)
            Text(value)
                .font(valueFont)
                .foregroundStyle(valueInk)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.sm)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(stroke, lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? "\(label), \(value)")
    }

    /// One rung larger for the headline, the shared footnote for everything
    /// else, so a row of pills has one height by construction.
    private var valueFont: Font {
        switch variant {
        case .accent: return .edTitle
        default:      return .edFootnoteStrong
        }
    }

    /// 0.14 fill and 0.35 stroke are `TagPill`'s, shipped and proven in both
    /// themes. A near-duplicate pair would drift.
    private var fill: Color {
        switch variant {
        case .neutral:         return Tokens.surface2
        case .verdict(let v):  return v.tint.opacity(0.14)
        case .accent:          return Tokens.accentMeals
        }
    }

    /// Not optional on the neutral variant: `surface2` sits a few values from
    /// `surface` in dark mode, and the border is what makes the fill an object
    /// rather than a smudge.
    private var stroke: Color {
        switch variant {
        case .neutral:         return Tokens.border
        case .verdict(let v):  return v.tint.opacity(0.35)
        case .accent:          return .clear
        }
    }

    private var labelInk: Color {
        switch variant {
        case .neutral:         return Tokens.muted
        case .verdict(let v):  return v.tint
        case .accent:          return Tokens.accentFg.opacity(0.75)
        }
    }

    private var valueInk: Color {
        switch variant {
        case .neutral:         return Tokens.ink
        case .verdict(let v):  return v.tint
        case .accent:          return Tokens.accentFg
        }
    }
}

extension MealStatPill {

    /// One nutrient read against its target.
    ///
    /// The verdict is asked of the nutrient, never worked out here, and a nil
    /// target gives a neutral pill rather than an implied "fine".
    init(nutrient: Nutrient, value: Double, target: Double?, fillsWidth: Bool = false) {
        let verdict = target.flatMap { nutrient.verdict(value: value, target: $0) }
        let reading = "\(nutrient.displayName), \(MealFormat.value(value, for: nutrient))"
        let spoken: String
        if let target, let verdict {
            spoken = "\(reading) of \(MealFormat.value(target, for: nutrient)), \(verdict.label)"
        } else {
            spoken = reading
        }
        self.init(
            label: nutrient.displayName,
            value: MealFormat.value(value, for: nutrient),
            variant: verdict.map(Variant.verdict) ?? .neutral,
            fillsWidth: fillsWidth,
            accessibilityText: spoken
        )
    }
}

extension Nutrient {

    /// The four the day is steered by, in the order every Meals surface prints
    /// them (#543).
    ///
    /// Fixed in code and never sorted by value. Hue on this surface means
    /// verdict and nothing else, so nutrient identity has to be carried by
    /// things that survive greyscale: the position, the label, and the shape of
    /// the mark. A row that re-ordered itself as the day changed would take the
    /// first of those away.
    static let macrosInOrder: [Nutrient] = [.protein, .carbs, .fat, .fibre]

    /// The three ceilings, in the Watch row.
    static let ceilingsInOrder: [Nutrient] = [.sugar, .sodium, .saturatedFat]
}
