import SwiftUI

/// The card pinned above Today when no targets exist (#544).
///
/// ### Why it is a card and not an empty state
///
/// Logging is never blocked on setup. The day card below this one already adds
/// up, and a meal logged before targets are set counts exactly as much as one
/// logged after. So this cannot be a wall; it has to be an offer sitting above
/// a surface that already works.
///
/// ### No hue
///
/// On this surface hue means verdict and nothing else. A tinted setup card
/// would be the only coloured thing on a screen where colour is a reading about
/// the day, which is the one association the section cannot afford to blur.
struct MealTargetsSetupCard: View {
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Targets").eyebrow()

            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Set your daily targets")
                    .font(.edHeading)
                    .foregroundStyle(Tokens.ink)
                // The sentence the user has to read before acting, so it sits
                // at the reading rung rather than as a footnote.
                Text("Six questions about your body and your goal, and Dexter works out the eight numbers a day is read against. You can change any of them before anything is saved.")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.sm) {
                Button("Set targets", action: onStart)
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                Spacer(minLength: Space.sm)
                Text("One request. Nothing is stored until you save.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }
}


/// The Targets tab's content once targets exist (#544, rewritten in #559).
///
/// ### Why this now repeats the numbers, when the row it replaces would not
///
/// This was `MealTargetsRow`, a quiet strip at the foot of Today. Its reasoning
/// was sound for where it sat: the eight numbers were already on the day card two
/// blocks up, drawn as bars against the day, and printing them again a few
/// hundred points lower would have put one fact on screen twice and made the
/// second copy look like a different fact. So the row stated only what the day
/// card could not — what the targets were derived FOR, and when.
///
/// #559 moves targets to a tab of their own, and that inverts the reasoning
/// completely. There is no day card on this tab and no bars, because there is no
/// day: a target is not a reading about anything until a day is put against it.
/// The eight numbers are the tab's entire subject, so withholding them would
/// leave a screen called Targets that never says what the targets are. The
/// duplication the row was avoiding is gone with it; Today no longer shows this
/// at all.
///
/// ### Still no hue
///
/// The pills are `.neutral` throughout, and not because a colour was unavailable.
/// On this surface hue means a verdict, and a verdict needs a day to be about.
/// These are the targets themselves, so there is nothing here to be over or
/// under, and tinting them would put the section's one colour meaning on numbers
/// that cannot carry it.
///
/// ### Why the hand-edited count moved onto the pills
///
/// The row's subtitle ended with "2 changed by you", and that was honest there
/// because the row printed no numbers: a count was the only thing it COULD say.
/// Carried onto a card showing all eight it becomes a promise the card then
/// breaks. It states a fact about two of the rows in front of you and gives you
/// no way to tell which two, so the reader searches eight identical pills for a
/// mark that is not on any of them.
///
/// So the count is gone from the sentence and the mark is on the pill. The
/// wording is the sheet's — "You changed this" — because the two surfaces are
/// describing the same fact and a second phrasing would read as a second fact.
/// The line is drawn only where it is true, and `fillsHeight` matches the two
/// boxes inside whichever row carries one. A derivation accepted as it came has
/// no marks and no rows grown to hold them.
struct MealTargetsSummaryCard: View {
    let targets: MealTargets
    /// Opens `MealTargetsSheet`, which is still the only edit flow.
    let onOpen: () -> Void

    /// Two columns at phone width, more on a wide Mac pane. Two rather than four
    /// because "Saturated fat" is the longest label in the app's eyebrow style and
    /// a four-up row truncates it on a 390 pt screen.
    private let columns = [GridItem(.adaptive(minimum: 148), spacing: Space.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header

            LazyVGrid(columns: columns, spacing: Space.sm) {
                ForEach(Nutrient.allCases) { nutrient in
                    let value = MealFormat.value(targets.target(for: nutrient), for: nutrient)
                    let edited = targets.isHandEdited(nutrient)
                    MealStatPill(
                        label: nutrient.displayName,
                        value: value,
                        variant: .neutral,
                        fillsWidth: true,
                        // Matches the two boxes inside a row when one of them
                        // carries the note. A row where neither does stays short,
                        // so a card with nothing overridden is no taller than it
                        // was before the note existed.
                        fillsHeight: true,
                        accessibilityText: "\(nutrient.displayName) target, \(value)"
                            + (edited ? ", you changed this" : ""),
                        note: edited ? Self.handEditedNote : nil
                    )
                }
            }

            if !targets.rationale.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("How these were worked out").eyebrow()
                    Text(targets.rationale)
                        .font(.edSubheadline)
                        .foregroundStyle(Tokens.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)
            }

            HStack(spacing: Space.sm) {
                Button("Re-derive targets", action: onOpen)
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                Spacer(minLength: Space.sm)
                Text("Past days are read against whichever targets are current.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Daily targets").eyebrow()
            // The sentence the row used to be. It says what the day card still
            // cannot: what these were derived for, and when.
            Text(subtitle)
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Daily targets, \(subtitle)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let goal = MealGoal(rawValue: targets.goal) {
            parts.append(goal.displayName)
        }
        if let level = ActivityLevel(rawValue: targets.activityLevel) {
            parts.append(level.displayName.lowercased())
        }
        if targets.weightKg > 0 {
            parts.append("\(String(format: "%.0f", targets.weightKg.rounded())) kg")
        }
        // No hand-edited count here. It used to be the fourth item in this list,
        // which made it read as a fourth property of the derivation and sent the
        // reader looking through eight identical pills for the two it meant. The
        // pills carry it now; see the type's doc comment.
        let head = parts.isEmpty ? "Derived from your body and goal" : parts.joined(separator: " · ")
        return "\(head). Set \(Self.dayFormatter.string(from: targets.updatedAt))."
    }

    /// The sheet's wording, verbatim. `MealTargetsSheet` prints "You changed
    /// this. Derived <figure>." next to the field being edited; this card has no
    /// derived figure to fall back on, because only the final value is stored, so
    /// it keeps the first sentence and drops the second.
    private static let handEditedNote = "You changed this"

    /// `updatedAt` is a real instant rather than a stored day anchor, so a
    /// device-local formatter is correct here.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}
