import SwiftUI

/// A small state pill: suspect, needs detail, possible duplicate, confidence
/// (#543).
///
/// One component for all four so they share a height and a corner and cannot
/// drift apart as more are added.
struct MealFlagChip: View {
    let text: String
    let systemImage: String?
    let tint: Color

    init(_ text: String, systemImage: String? = nil, tint: Color = Tokens.muted) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.edCaption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// One logged meal in the day's list (#543, breakdown added in #560).
///
/// The row carries the description, the time, the calories, the full nutrient
/// breakdown, and whatever is wrong with it.
///
/// ### Why the eight numbers are here now
///
/// They were held back because eight bare figures per row would make the day
/// unreadable at exactly the moment there was enough in it to be worth reading.
/// That reason holds for eight bare figures and not for the pill treatment the
/// day card already uses: a pill reads at the size of the whole pill rather
/// than at the size of the number inside it, so a rung of seven scans as one
/// band. Without them, a day that lands over on sodium or short on protein
/// names no culprit, and the only way to find one is to open every meal.
///
/// ### The pills are neutral, always
///
/// A verdict is a reading of a day against a target. A single meal has no
/// target of its own, so no pill here may be tinted: `MealStatPill` is built
/// with the plain `label:value:` initialiser and never with
/// `init(nutrient:value:target:)` carrying a real target. Tinting would also
/// put verdict hue on ten rows at once, which is the reading the day card
/// exists to give, and one this list cannot support.
///
/// ### The meal type, and why it wears no box (#570)
///
/// The type now leads line 1 with the description, in its own colour, and the
/// gutter icon carries the same colour on any row that is not flagged. What it
/// deliberately does NOT have is a container.
///
/// `MealStatPill`'s note records that Meals draws two pill species and that
/// SHAPE is what tells them apart: a `Capsule` carries a word about the RECORD
/// — "Needs detail", "Check this", "Possible duplicate", the confidence band —
/// and a rounded rectangle carries a QUANTITY. A meal type is neither. It is
/// not a judgement about the record and it is not a number, so putting it in
/// either shape would make it read as a third instance of a meaning it does
/// not have. On a suspect row, where a red "Check this" capsule sits two
/// millimetres below it, a tinted capsule saying "DINNER" would be read as one
/// more flag before it was read as an identity.
///
/// So the mark is bare type: the same uppercase tracked eyebrow the row
/// already used, in the type's colour instead of grey. No fill, no stroke, no
/// corner radius. It cannot be confused with a chip because it is not a chip,
/// and the distinction survives on the warning ground where the risk is
/// highest.
struct MealRow: View {
    let meal: LocalMeal

    /// Derived on every read from the day's rows rather than stored, so
    /// deleting one half of a pair clears the flag on the other.
    let isDuplicate: Bool

    let onTap: () -> Void

    /// True for the ~600 ms after a deep-link lands on this row (#547). Drawn
    /// in the section accent, not in a verdict hue: the pulse says "this is the
    /// one you tapped", which is a fact about the navigation and not about the
    /// meal. Declared last so the existing three-argument call sites keep
    /// compiling.
    var isFocused: Bool = false

    private var needsAttention: Bool {
        meal.isSuspect || meal.needsDetail || isDuplicate
    }

    /// How much closer the meal type sits to the description than the other
    /// rungs sit to each other (#574).
    ///
    /// The row is six rungs now — type, description, time, flag chips,
    /// breakdown, note — and six evenly spaced lines read as a list of
    /// unrelated facts rather than as one record. The type is not a peer of
    /// the rungs under it; it is a label on the record, so it is set closer to
    /// the description than anything else in the stack.
    ///
    /// Stated as a NEGATIVE padding against the enclosing stack's `Space.xs`
    /// rather than by nesting another `VStack`, so the one number here is the
    /// difference itself and cannot drift away from the gap it is measured
    /// against. `Space.xs` minus this is the type-to-description gap;
    /// everything else in the stack keeps the full `Space.xs`.
    static let typeToDescriptionGap: CGFloat = -Space.xxs

    /// What the left-gutter icon is drawn in.
    ///
    /// A flag outranks an identity, so a row that needs attention keeps the
    /// warning tint it has always had and the meal type is left to the word on
    /// line 1. Lifted out of the body so the precedence is assertable rather
    /// than only visible.
    var gutterTint: Color {
        needsAttention ? Tokens.warning : meal.mealTypeEnum.tint
    }

    /// One accessibility element, with the numbers behind the More Content
    /// rotor (#560).
    ///
    /// The pills are NOT individually addressable. Seven of them in a list of
    /// ten meals is seventy extra stops between a reader and the next meal, to
    /// give a figure the row's own label can give in a clause. So the row stays
    /// the single element it has always been.
    ///
    /// Dropping the numbers from the spoken row instead would make them
    /// sighted-only, so they are attached as custom content: two entries,
    /// Macros and Watch, at default importance. VoiceOver reads the label —
    /// meal, description, calories, flags — and speaks the breakdown only when
    /// the reader asks for it. That is the one mechanism on the platform that
    /// adds detail without adding either noise or a stop.
    @ViewBuilder
    var body: some View {
        if let macros = Self.spokenReadings(Nutrient.macrosInOrder, of: meal),
           let ceilings = Self.spokenReadings(Nutrient.ceilingsInOrder, of: meal) {
            rowButton
                .accessibilityCustomContent(Text("Macros"), Text(macros))
                .accessibilityCustomContent(Text("Watch"), Text(ceilings))
        } else {
            rowButton
        }
    }

    private var rowButton: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Space.md) {
                // The second carrier of the meal-type colour, and the only
                // one that survives the description being read rather than
                // scanned. A flag OUTRANKS an identity: on a row that needs
                // attention the icon goes to `warning` as it always has, and
                // the word on line 1 is left holding the type on its own.
                Image(systemName: meal.mealTypeEnum.sfSymbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(gutterTint)
                    .frame(width: 22, height: 22)

                // Everything but the icon hangs off one gutter, so the rungs
                // under the description share its left edge rather than each
                // finding its own.
                VStack(alignment: .leading, spacing: Space.xs) {
                    // Rung 0: which meal this was (#574).
                    //
                    // A kicker on its own line, not a prefix on the
                    // description's. #570 put it inline and the description
                    // paid about 70 pt of its first line for it, then wrapped
                    // under itself with a hanging indent. A kicker costs one
                    // short line and gives every line of the description the
                    // full width.
                    //
                    // OUTSIDE the HStack below, which is what keeps the
                    // calorie figure aligned to the description rather than to
                    // this word. See the note on `typeToDescriptionGap`.
                    Text(meal.mealTypeEnum.displayName)
                        .eyebrow(meal.mealTypeEnum.tint)
                        .padding(.bottom, Self.typeToDescriptionGap)

                    // Rung 1: what the meal is, and what it cost.
                    HStack(alignment: .top, spacing: Space.md) {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            // The dish, not the sentence (#603). A day holds
                            // five of these, and five verbatim descriptions
                            // stacked is a paragraph with times down the side.
                            // The whole text is one tap away, on the sheet this
                            // row opens, which is where it can be read rather
                            // than scanned. `MealDisplayName` decides what the
                            // name is, so this row and the plan block and the
                            // activity feed cannot name one meal three ways.
                            Text(MealDisplayName.short(for: meal))
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                        }

                        Spacer(minLength: Space.sm)

                        // The row's anchor, and still the only figure at
                        // heading size. No pill here: ten accent-filled pills
                        // down a list would be ten competing anchors, and the
                        // breakdown under it is a second rung rather than a
                        // replacement.
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(
                                meal.needsDetail
                                    ? "—"
                                    : MealFormat.calories(meal.calories, Self.precision(of: meal))
                            )
                                .font(.edHeading)
                                .foregroundStyle(meal.isSuspect || meal.needsDetail ? Tokens.muted : Tokens.ink)
                                .monospacedDigit()
                            Text("kcal").eyebrow()
                        }
                    }

                    // Rung 2: whether the numbers under it can be trusted at
                    // all. Above the breakdown and not below it: "Needs
                    // detail", "Check this" and "Possible duplicate" are the
                    // conditions the figures are read under, and a condition
                    // met after the fact is not a condition.
                    //
                    // Wraps rather than clipping: on a phone three chips do not
                    // fit one line.
                    if !chips.isEmpty {
                        WrappingChipRow(chips: chips)
                    }

                    // Rung 3: the seven, in the fixed order. Empty on a
                    // needs-detail meal, which has no numbers to give.
                    if !breakdown.isEmpty {
                        breakdownRow
                    }

                    // The reason the row is flagged, and the only prose left on
                    // it (#609).
                    //
                    // The assumptions note used to share this slot when there
                    // was no warning to show. It is a paragraph — what the
                    // estimate assumed about portions, oil, a default serving —
                    // and on a row it could only ever be one truncated line,
                    // which is a sentence nobody can finish reading and the
                    // widest thing on the card. It is in full on the sheet this
                    // row opens, which is where a reader goes to argue with an
                    // estimate.
                    //
                    // A WARNING is not a footnote and stays: it is the condition
                    // the figures above are read under.
                    if let reason = meal.suspectReason {
                        Text(reason)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, Space.md)
            .padding(.horizontal, Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                needsAttention ? Tokens.warningSoft.opacity(0.45) : Tokens.surface,
                in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            )
            .paperBorder(needsAttention ? Tokens.warning.opacity(0.35) : Tokens.border, radius: Radius.lg)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(Tokens.accentMeals.opacity(isFocused ? 0.12 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .stroke(Tokens.accentMeals.opacity(isFocused ? 0.85 : 0), lineWidth: 1.5)
                    )
                    .allowsHitTesting(false)
            )
            .animation(.easeOut(duration: 0.25), value: isFocused)
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the meal to correct or repeat it")
    }

    /// The breakdown itself: the four macros on one line, the three ceilings on
    /// the next.
    ///
    /// ### Why two fixed lines and not a flow
    ///
    /// A flow breaks where the width runs out, which on a phone lands inside
    /// the macros and puts Sugar — a ceiling — at the end of the macro line.
    /// The macro/ceiling split is the whole structure of the day card above,
    /// and a row that loses it is seven numbers in a heap. Two fixed `HStack`s
    /// carry the grouping by construction, in the same
    /// order and with the same break as the card, so the eye reads one column
    /// down the screen. See `pillLine` for why the pills are at their natural
    /// width rather than sharing the line evenly.
    ///
    /// ### And no "Macros" / "Watch" eyebrows
    ///
    /// On the card those labels earn their line, because the two groups sit far
    /// apart and are drawn differently. On a row repeated ten times they are
    /// ten pairs of redundant words. Four then three, in the fixed order, under
    /// a card that already named the groups, says it without them.
    ///
    /// ### And no dimming when the meal is suspect
    ///
    /// A suspect meal's pills are drawn exactly like any other row's, at full
    /// ink. The row already says the meal is held back — the warning ground,
    /// the "Check this" chip and the reason under it — and greying the numbers
    /// as well would read as "unavailable", when the whole point of showing a
    /// suspect meal's numbers is that they are what the user has to read to
    /// judge it.
    private var breakdownRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            pillLine(Nutrient.macrosInOrder)
            pillLine(Nutrient.ceilingsInOrder)
        }
        .padding(.top, 2)
    }

    /// One group on one line, the pills sharing it evenly (#610).
    ///
    /// They were at their natural width from #561, which left a ragged right
    /// edge on both lines and three different widths inside one group. That was
    /// a workaround for a label: an even three-across share of this column is
    /// 103pt and a pill labelled "Saturated fat" wants 123pt, so the even grid
    /// truncated it at 390pt.
    ///
    /// `Nutrient.shortLabel` prints "Sat fat" instead, which fits the even
    /// share, so the grid is available again. Four across and three across are
    /// different widths BETWEEN the two lines, and that is the grouping doing
    /// its job: the macros and the ceilings are two readings, not seven numbers
    /// in a heap. `testEveryPillFitsItsLineAtPhoneWidth` pins the measurement.
    private func pillLine(_ group: [Nutrient]) -> some View {
        HStack(spacing: Space.sm) {
            ForEach(group) { nutrient in
                MealStatPill(
                    label: nutrient.shortLabel,
                    value: Self.reading(nutrient, of: meal),
                    fillsWidth: true
                )
            }
        }
    }

    private var breakdown: [Nutrient] { Self.breakdown(for: meal) }

    /// The nutrients a row prints, in the fixed order every Meals surface uses:
    /// the four macros, then the three ceilings.
    ///
    /// Empty for a needs-detail meal. That meal has no numbers — its stored
    /// eight are all zero because nothing was identified — and a rung of zero
    /// pills would state as fact what the em dash in the calorie column exists
    /// to say is unknown.
    static func breakdown(for meal: LocalMeal) -> [Nutrient] {
        guard !meal.needsDetail else { return [] }
        return Nutrient.macrosInOrder + Nutrient.ceilingsInOrder
    }

    /// One nutrient's value with its unit, formatted the one way Meals formats
    /// numbers.
    static func reading(_ nutrient: Nutrient, of meal: LocalMeal) -> String {
        MealFormat.value(
            meal.value(for: nutrient),
            for: nutrient,
            precision: precision(of: meal)
        )
    }

    /// How this meal's figures are printed on the row, decided the one way
    /// every Meals surface decides it (#594).
    static func precision(of meal: LocalMeal) -> MealFormat.Precision {
        MealGrounding.precision(
            isGrounded: meal.isGrounded,
            totalsWereOverridden: meal.totalsWereOverridden
        )
    }

    /// One group of nutrients as a spoken clause, or nil when the meal has no
    /// numbers to speak.
    static func spokenReadings(_ group: [Nutrient], of meal: LocalMeal) -> String? {
        guard !meal.needsDetail else { return nil }
        return group
            .map { "\($0.displayName) \(reading($0, of: meal))" }
            .joined(separator: ", ")
    }

    private var chips: [MealFlagChip] {
        var out: [MealFlagChip] = []
        if meal.needsDetail {
            out.append(MealFlagChip("Needs detail", systemImage: "questionmark.circle", tint: Tokens.warning))
        }
        if meal.isSuspect {
            out.append(MealFlagChip("Check this", systemImage: "exclamationmark.triangle", tint: Tokens.danger))
        }
        if isDuplicate {
            out.append(MealFlagChip("Possible duplicate", systemImage: "doc.on.doc", tint: Tokens.info))
        }
        // Ahead of the confidence band, which it qualifies rather than replaces:
        // the figures are published, the portion they were scaled to is still
        // assumed (#594). One more chip on a row that already flows them, so it
        // costs the layout nothing.
        if meal.isGrounded {
            out.append(MealGrounding.chip())
        }
        if !meal.needsDetail {
            out.append(
                MealFlagChip(
                    MealFormat.confidenceBand(meal.confidence),
                    tint: meal.totalsWereOverridden ? Tokens.success : Tokens.muted
                )
            )
        }
        return out
    }

    /// What the row says when it is read aloud. Deliberately unchanged in shape
    /// by #560: the meal, its description and its calories, then what is wrong
    /// with it. The seven nutrients are custom content, not part of this
    /// sentence — see the note on `body`.
    /// #603 deliberately did NOT shorten this. The name on screen exists
    /// because five sentences do not scan; a reader hearing one row at a time
    /// has no such problem, and the full description says more.
    var accessibilityText: String {
        var parts = [meal.mealTypeEnum.displayName, meal.mealDescription]
        if meal.needsDetail {
            parts.append("needs detail, no numbers yet")
        } else {
            parts.append("\(MealFormat.calories(meal.calories, Self.precision(of: meal))) kilocalories")
        }
        if meal.isSuspect, let reason = meal.suspectReason { parts.append(reason) }
        if isDuplicate { parts.append("possible duplicate") }
        return parts.joined(separator: ", ")
    }

    /// Times read in the device zone: `loggedAt` is a true instant, unlike the
    /// meal's day, which is a UTC anchor and must never reach a device-local
    /// formatter (#506).
    ///
    /// Kept here, and read by `MealDetailSheet` alone since #609 took the time
    /// off the row. It stays on this type because the rule above is about how
    /// a MEAL's time is formatted, wherever it is drawn.
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

/// Chips laid out left to right, wrapping when they run out of width (#543).
///
/// A `Layout` rather than a nest of `HStack`s guessing at a break point: three
/// chips plus a calorie column do not fit one line on a phone, and the set of
/// chips is data-dependent, so where the line breaks cannot be decided here.
struct WrappingChipRow: View {
    let chips: [MealFlagChip]

    var body: some View {
        ChipFlowLayout {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                chip
            }
        }
    }
}

/// The flow itself. Measures each child at its natural size, wraps when the next
/// one would cross the right edge.
///
/// ### Why one solver and not two loops (#571)
///
/// The two passes used to carry their own copy of the arithmetic, and they
/// wrapped against two different widths: `sizeThatFits` against
/// `proposal.width`, `placeSubviews` against `bounds.width`. On a suspect meal
/// row those were measured at 292 pt and placed into 232 pt, so the layout
/// reported the height of two lines and then laid out three. The row reserved
/// 46 pt for a 71 pt block and the nutrient pills under it were drawn straight
/// over the third chip.
///
/// So the arithmetic is now stated exactly once, in `solve`, and both passes
/// call it. Two loops that must agree are two loops that will not.
///
/// ### And why the reported width is the width it wrapped against
///
/// Stating one solver is necessary but not sufficient: both passes still have
/// to feed it the same width. `placeSubviews` can only honestly use
/// `bounds.width`, which is the space it was actually handed, so the fix is to
/// make `bounds.width` equal the width `sizeThatFits` measured at.
///
/// That is what reporting `proposal.width` does. The old code reported
/// `min(widest, maxWidth)` — the width its longest LINE happened to reach —
/// which told the parent the flow was narrower than the space it had been
/// offered. The parent believed it, gave the enclosing column less, and then
/// placed into that smaller box without measuring again. A flow that claims
/// the full width it wrapped against is given the full width it wrapped
/// against, and the disagreement has nowhere left to live. The chips are still
/// placed from the leading edge, so nothing moves on a row that already fitted.
///
/// An unspecified proposal is the one case with no width to claim. It reports
/// the longest line, as it always did.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = Space.xs

    /// Where every child goes, and the box they need.
    struct Solution: Equatable {
        /// One offset per child, in order, from the top-leading corner.
        var offsets: [CGPoint]
        /// The box the offsets need. The width is the width the flow WRAPPED
        /// against, not the width its longest line reaches — see the note on
        /// the type.
        var size: CGSize

        /// The height the offsets actually occupy, worked out from the
        /// placements rather than from the measuring loop.
        ///
        /// This is the assertion `size.height` exists to match, and the whole
        /// bug was the two drifting apart. Kept on the solution so a test can
        /// state the invariant in the same terms the layout does.
        func placedHeight(of sizes: [CGSize]) -> CGFloat {
            zip(offsets, sizes).reduce(0) { max($0, $1.0.y + $1.1.height) }
        }
    }

    /// The one piece of arithmetic in this type.
    ///
    /// A child wider than the whole line is placed anyway rather than dropped,
    /// and takes a line of its own. Clipping one chip is better than losing it,
    /// and the case only arises at widths no phone gives this row.
    static func solve(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> Solution {
        guard !sizes.isEmpty else { return Solution(offsets: [], size: .zero) }

        var offsets: [CGPoint] = []
        offsets.reserveCapacity(sizes.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for size in sizes {
            if x > 0 && x + size.width > width {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)

        return Solution(
            offsets: offsets,
            size: CGSize(width: width.isFinite ? width : widest, height: y + rowHeight)
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.solve(
            subviews.map { $0.sizeThatFits(.unspecified) },
            width: proposal.width ?? .infinity,
            spacing: spacing
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let solution = Self.solve(sizes, width: bounds.width, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let offset = solution.offsets[index]
            subview.place(
                at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }
}
