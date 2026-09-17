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

    /// How large the figure is set. See `size`.
    enum Size: Equatable {
        /// `.edFootnoteStrong`, so a row of pills sits under a meal without
        /// competing with it.
        case regular
        /// One semibold rung up, `.edHeading`. For a surface whose subject IS
        /// the numbers.
        case large
    }

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

    /// True in a grid whose pills must match the tallest in their OWN row.
    ///
    /// The companion to `fillsWidth`, and it exists for `note`. A grid row sizes
    /// to its tallest cell, so one pill carrying a note makes its neighbour's box
    /// end short of the row while the row keeps the height anyway — two boxes at
    /// two heights side by side, which reads as a layout fault rather than as a
    /// mark. Filling the height makes the shorter pill's box take the row it was
    /// already given.
    ///
    /// Deliberately per ROW and not per grid. A row with no note stays short, so
    /// a card whose values were all accepted as derived is exactly as tall as it
    /// would be with no note feature at all. Reserving on every pill instead
    /// would make the common case pay for the rare one.
    var fillsHeight: Bool = false

    /// Overrides the spoken reading. The visible text is shorthand — "1,900 mg"
    /// says nothing about the target it is under — so a caller that knows the
    /// target passes the full sentence here.
    var accessibilityText: String? = nil

    /// A short line under the value, saying where the figure came from rather
    /// than what it is (#559). Nil draws no line at all, which is every caller
    /// that predates it and every pill the fact is not true of.
    ///
    /// Never tinted, and never a verdict. Hue on this surface means a reading
    /// about a day, and where a number came from is not one.
    ///
    /// A caller putting a note on SOME pills of a grid sets `fillsHeight` on all
    /// of them, so the boxes inside a row match. See that flag.
    ///
    /// Not spoken from here. The pill is one accessibility element with one
    /// label, so a caller passing a note folds it into `accessibilityText` too.
    var note: String? = nil

    /// How large the figure is set (#623).
    ///
    /// Additive, and `.regular` is exactly what every pill did before this
    /// existed: the day card, the estimate preview, the meal row and the plan
    /// board all keep `.edFootnoteStrong` without naming a size. Only the
    /// Targets page asks for `.large`, because there the eight numbers are the
    /// page's whole subject rather than a reading printed beside a meal.
    ///
    /// The LABEL does not move with it. An eyebrow is a species, not a rung —
    /// growing it would make the pill's two lines compete for the same job —
    /// and the label is what sets a pill's width, which a four-across row at
    /// phone width has none of to spare (#610).
    ///
    /// Ignored by `.accent`, which is already the one headline figure on its
    /// surface and is set at `.edTitle` for that reason. A size knob that could
    /// shrink it would make "the largest number here" a caller's decision.
    var size: Size = .regular

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
            if let note {
                Text(note)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        // Top-aligned only when filling the height, so the pill without the note
        // keeps its label and figure level with its neighbour's and lets the
        // spare room fall below, where that neighbour's note is.
        .frame(
            maxWidth: fillsWidth ? .infinity : nil,
            maxHeight: fillsHeight ? .infinity : nil,
            alignment: fillsHeight ? .topLeading : .leading
        )
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

    /// One rung larger for the headline, and otherwise whatever the caller's
    /// `size` asks for, so a row of pills has one height by construction.
    private var valueFont: Font {
        switch variant {
        case .accent: return .edTitle
        default:      return size == .large ? .edHeading : .edFootnoteStrong
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
            // The SHORT label, so the pills of a row can share the line evenly
            // (#610). The spoken reading above is built from `displayName`, so
            // a reader still hears "Saturated fat" in full.
            label: nutrient.shortLabel,
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
