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


/// The Targets tab, once targets exist (#544, rewritten in #559, made the edit
/// surface in #623).
///
/// ### Why this now repeats the numbers, when the row it replaced would not
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
/// ### Why the page edits, when the sheet already could (#623)
///
/// The six vitals the eight numbers come out of were nowhere on this tab, and
/// exactly one of them changes month to month. Weighing yourself and then
/// opening a sheet to tell the app about it is three taps of ceremony around one
/// number, on a page that had the room for the field and was showing a paragraph
/// instead.
///
/// So the page carries the six, and one action saves them and re-derives the
/// eight against them. The sheet stays, and stays reachable from here, because
/// it answers a different question: not "my weight changed" but "this one number
/// is wrong". Hand-editing an individual target is a rarer, more deliberate act
/// than restating a vital, and giving it its own surface is what keeps the page's
/// one action unambiguous.
///
/// Nothing is written unless the derivation answers. A failed call leaves the
/// stored record exactly as it was, so a dead network cannot half-save a body.
///
/// ### Three labelled rows, not eight pills in a grid
///
/// The adaptive grid this replaced flowed the eight in whatever order the width
/// allowed, so calories, the four macros and the three ceilings read as one
/// undifferentiated set. They are three different kinds of number: one the day
/// is steered by, four that make it up, three that are limits. The rows are the
/// same grammar `MealDayCard` uses for Macros and Watch, so the two surfaces
/// group the same eight the same way, and a row spread evenly across the card
/// says "these belong together" without a word.
///
/// ### Still no hue
///
/// The pills are `.neutral` throughout, and not because a colour was unavailable.
/// On this surface hue means a verdict, and a verdict needs a day to be about.
/// These are the targets themselves, so there is nothing here to be over or
/// under, and tinting them would put the section's one colour meaning on numbers
/// that cannot carry it.
///
/// ### Why the hand-edited mark is on the pill
///
/// The row's subtitle ended with "2 changed by you", and that was honest there
/// because the row printed no numbers: a count was the only thing it COULD say.
/// Carried onto a card showing all eight it becomes a promise the card then
/// breaks. It states a fact about two of the rows in front of you and gives you
/// no way to tell which two, so the reader searches eight identical pills for a
/// mark that is not on any of them.
///
/// So the count is gone from the sentence and the mark is on the pill. The line
/// is drawn only where it is true, and `fillsHeight` is set per ROW rather than
/// per card, so a row carrying no mark stays short and a derivation accepted as
/// it came is no taller than it was before the mark existed.
///
/// The wording is "Edited", where the sheet says "You changed this. Derived
/// 2,150 kcal." Not a second phrasing of the same fact by choice: a macro pill
/// is a quarter of the card's inner column, about 75pt at phone width, and a
/// sixteen-character sentence in that box is the truncation #561 and #610 were
/// both about. A reader still hears the whole sentence — it is in the pill's
/// spoken label — and still sees it beside the field in the sheet, which has the
/// width for it. `MealTargetsCardRowTests` pins both the mark and the eight
/// labels against the share each row actually gives them.
struct MealTargetsSummaryCard: View {
    let targets: MealTargets
    /// Opens `MealTargetsSheet`, which is where ONE of the eight numbers is
    /// hand-edited. The page itself no longer needs it to change a vital.
    let onOpen: () -> Void

    /// The six, as the page holds them between edits. Loaded from the record and
    /// written back only by the one action, so typing a weight and walking away
    /// changes nothing — the same contract the sheet has always had.
    @State private var inputs = MealTargetInputs()

    /// The three numeric vitals as typed text, not as parsed numbers.
    /// Re-formatting a field mid-keystroke is how "7." becomes "7" under the
    /// caret.
    @State private var ageText = ""
    @State private var heightText = ""
    @State private var weightText = ""

    @State private var phase: MealTargetsPhase = .editing

    /// The stamp the fields were last loaded from. The record can move under
    /// this view — our own save moves it, and so does a peer arriving over sync
    /// — and the fields have to follow it without being rebuilt on every
    /// keystroke. Comparing the stamp does both.
    @State private var loadedStamp: Date?

    private var client: AnthropicClient { AnthropicClient() }
    private var service: MealService { .default() }

    private var isWorking: Bool { phase == .deriving }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            header
            pillRows
            aboutYou
            actions
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
        .onAppear { loadIfStale() }
        .onChange(of: targets.updatedAt) { _, _ in loadIfStale() }
    }

    // MARK: - Header

    /// The page's heading, at the Calistoga rung (#623).
    ///
    /// It was an eyebrow, which is the label a BLOCK inside a page gets. This is
    /// the page, and its subject is eight numbers and six fields, so it takes
    /// the heading step the rest of the app gives a page.
    ///
    /// No eyebrow above it. The setup state pairs "Targets" with a heading
    /// because its heading is a sentence ("Set your daily targets") rather than
    /// a name; here the word would be the same word twice, under a tab already
    /// labelled Targets.
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Daily targets")
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
                .accessibilityAddTraits(.isHeader)
            // The sentence the row used to be. It says what the pills still
            // cannot: what these were derived for, and when.
            Text(subtitle)
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - The eight

    private var pillRows: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // "Energy", not "Calories". The row eyebrow names the GROUP and the
            // pill names the nutrient, which is why Macros and Watch read
            // cleanly; a calories row headed "Calories" printed the word twice
            // over a figure already ending in kcal, three sayings of one thing
            // stacked vertically.
            pillRow("Energy", [.calories])
            pillRow("Macros", Nutrient.macrosInOrder)
            pillRow("Watch", Nutrient.ceilingsInOrder)
        }
    }

    /// One labelled row of pills, spread evenly across the card.
    ///
    /// `fillsWidth` on every pill and `fillsHeight` only where the row carries a
    /// mark: a row sizes to its tallest pill, so one marked pill would otherwise
    /// leave its neighbour's box ending short of the row it was given, which
    /// reads as a layout fault rather than as a mark.
    private func pillRow(_ title: String, _ nutrients: [Nutrient]) -> some View {
        let carriesMark = nutrients.contains { targets.isHandEdited($0) }
        return VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).eyebrow()
            HStack(spacing: Space.sm) {
                ForEach(nutrients) { nutrient in
                    let value = MealFormat.value(targets.target(for: nutrient), for: nutrient)
                    let edited = targets.isHandEdited(nutrient)
                    MealStatPill(
                        // The SHORT label, the way the day card's rows take it:
                        // "Saturated fat" is 123pt in a box and a three-across
                        // share is 103pt (#610).
                        label: nutrient.shortLabel,
                        value: value,
                        variant: .neutral,
                        fillsWidth: true,
                        fillsHeight: carriesMark,
                        accessibilityText: "\(nutrient.displayName) target, \(value)"
                            + (edited ? ", you changed this" : ""),
                        note: edited ? Self.handEditedMark : nil,
                        size: .large
                    )
                }
            }
        }
    }

    // MARK: - The six

    /// The vitals, editable in place (#623).
    ///
    /// One per line, each line label / control / unit, because that is the shape
    /// the sheet already uses and a second shape for the same six would make the
    /// two surfaces look like two features. `surface2` inside a `surface` card,
    /// which is the nesting that separates in both themes.
    private var aboutYou: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("About you").eyebrow()

            VStack(alignment: .leading, spacing: Space.xs) {
                MealNumberField(
                    label: "Age",
                    unit: "yrs",
                    text: Binding(
                        get: { ageText },
                        set: { ageText = $0; inputs.ageYears = Int(MealItemDraft.number($0).rounded()) }
                    ),
                    size: .large
                )

                MealTargetsChoiceField(
                    label: "Biological sex",
                    options: BiologicalSex.allCases,
                    title: \.displayName,
                    selection: $inputs.biologicalSex,
                    size: .large
                )

                MealNumberField(
                    label: "Height",
                    unit: "cm",
                    text: Binding(
                        get: { heightText },
                        set: { heightText = $0; inputs.heightCm = MealItemDraft.number($0) }
                    ),
                    size: .large
                )

                MealNumberField(
                    label: "Weight",
                    unit: "kg",
                    text: Binding(
                        get: { weightText },
                        set: { weightText = $0; inputs.weightKg = MealItemDraft.number($0) }
                    ),
                    size: .large
                )

                MealTargetsChoiceField(
                    label: "Activity",
                    options: ActivityLevel.allCases,
                    title: \.displayName,
                    selection: $inputs.activityLevel,
                    size: .large
                )

                // The band's own definition, under the field rather than inside
                // the option rows, exactly as the sheet places it:
                // `InlineDropdownRow` draws one line, and a second control shape
                // for one dropdown would break the pattern Finance and the
                // composer already share.
                Text(inputs.activityLevel.detail)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                MealTargetsChoiceField(
                    label: "Goal",
                    options: MealGoal.allCases,
                    title: \.displayName,
                    selection: $inputs.goal,
                    size: .large
                )
            }
            .padding(Space.md)
            .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    // MARK: - Actions

    /// One row, primary on the right (#623).
    ///
    /// It was primary-on-the-left, which is the one placement no other action
    /// row in the app uses. The secondary sits immediately beside it rather than
    /// at the far end of the bar, the way the sheet's footer pairs Cancel and
    /// Save: two buttons a thumb's width apart read as one decision with two
    /// answers, and two buttons at opposite ends read as two unrelated controls.
    private var actions: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                if isWorking {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #else
                        .scaleEffect(0.7)
                        #endif
                }
                Spacer(minLength: Space.sm)
                Button("Edit numbers", action: onOpen)
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                    .disabled(isWorking)
                    .opacity(isWorking ? 0.5 : 1)
                Button(isWorking ? "Working it out…" : "Save and re-derive") { saveAndDerive() }
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                    .disabled(isWorking || !inputs.isComplete)
                    .opacity(isWorking || !inputs.isComplete ? 0.5 : 1)
            }

            // One line under the row, and only when there is something to say.
            // The failure wins over the validation message: a call that came
            // back with an error is the more recent fact about the same button.
            if case .failed(let message) = phase {
                Text(message)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            } else if let problem = inputs.problem {
                Text(problem)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - Loading and saving

    /// Re-read the six from the record, when the record is not what the fields
    /// were built from.
    ///
    /// Guarded on the stamp rather than on a one-shot `loaded` flag, because
    /// this view outlives an edit: the sheet can save behind it, and so can a
    /// peer. A flag would leave the fields showing a body nobody has any more.
    private func loadIfStale() {
        guard loadedStamp != targets.updatedAt else { return }
        loadedStamp = targets.updatedAt
        inputs = MealTargetInputs(stored: targets)
        ageText = targets.ageYears > 0 ? "\(targets.ageYears)" : ""
        heightText = targets.heightCm > 0 ? MealItemDraft.string(targets.heightCm) : ""
        weightText = targets.weightKg > 0 ? MealItemDraft.string(targets.weightKg) : ""
    }

    /// Save the six and re-derive the eight against them, in one action.
    ///
    /// The derivation runs FIRST and the write happens only once it answers, so
    /// a failed call leaves the stored record untouched rather than saving a new
    /// weight against the old numbers — which would be a record describing a
    /// body it was not derived for, and nothing on screen would say so.
    ///
    /// The answer is folded through `MealTargetDraft` rather than written
    /// straight out, which is what protects a figure the user set by hand in the
    /// sheet: the draft refreshes the seven it may refresh and leaves the
    /// overridden one alone, keeping its flag. Re-deriving after a weight change
    /// therefore cannot silently undo a deliberate choice.
    private func saveAndDerive() {
        guard !isWorking, inputs.isComplete else { return }
        let request = inputs
        let record = targets
        phase = .deriving
        Task {
            do {
                let derived = try await client.deriveMealTargets(inputs: request)
                var draft = MealTargetDraft(stored: record)
                draft.apply(derived)
                try service.saveTargets(
                    targets: draft.values,
                    ageYears: request.ageYears,
                    biologicalSex: request.biologicalSex.rawValue,
                    heightCm: request.heightCm,
                    weightKg: request.weightKg,
                    activityLevel: request.activityLevel.rawValue,
                    goal: request.goal.rawValue,
                    // Still stored, no longer shown. See the note in
                    // `MealTargetsSheet.reviewSection`.
                    rationale: draft.rationale,
                    // Keep the day the record has always applied from. v1 is not
                    // versioned, so moving it forward would leave every earlier
                    // day reading against the fallback rather than against these.
                    effectiveFrom: record.deviceEffectiveFrom,
                    handEdited: draft.handEdited,
                    clientUUID: record.clientUUID
                )
                phase = .editing
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The mark on a pill the user set by hand. One word, because the box is a
    /// quarter of a phone-width card; see the type's doc comment.
    private static let handEditedMark = "Edited"

    /// `updatedAt` is a real instant rather than a stored day anchor, so a
    /// device-local formatter is correct here.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()
}
