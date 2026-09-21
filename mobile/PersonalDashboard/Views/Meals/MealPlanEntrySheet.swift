import SwiftUI
import SwiftData

/// What the plan sheet was opened on (#599).
///
/// An enum rather than an optional block plus a couple of loose parameters,
/// because "new" carries facts that "existing" does not — the day and the slot
/// it is being added to — and holding those as separate `@State` on the parent
/// is how two sheets end up disagreeing about which day they are writing to.
enum MealPlanEditorTarget: Identifiable {
    /// A block that does not exist yet, for this day and this meal type.
    case new(day: Date, mealType: MealType)
    /// A block already on the calendar.
    case existing(LocalMealPlanEntry)

    var id: String {
        switch self {
        case .new(let day, let mealType):
            return "new-\(day.timeIntervalSinceReferenceDate)-\(mealType.rawValue)"
        case .existing(let entry):
            return entry.clientUUID
        }
    }
}

/// Add, inspect and edit one planned meal (#599).
///
/// ### One sheet, not three
///
/// This is the add flow, the detail view and the editor. They are the same
/// screen because they hold the same fields, and splitting them would mean a
/// user who opens a block to read the recipe has to press Edit before they can
/// fix the dish name they just noticed was wrong.
///
/// ### The dish is the input, the rest is the model's answer
///
/// You type "chicken rice". Dexter returns the nutrition, the key ingredients
/// and, when the method is not obvious, a recipe. That is the same bargain the
/// Tracking composer makes — a description in, an estimate out, no database
/// search and no portion picker — and it is why a planned meal can carry numbers
/// at all without becoming a form.
///
/// Estimating is deliberately NOT automatic on save. The call costs money and
/// takes a few seconds, and a block typed as a placeholder ("lunch with Dad")
/// wants neither. So a block can always be saved on its title alone, and the
/// tile says "No numbers yet" until somebody asks for them.
///
/// ### Everything the model returns stays editable
///
/// The ingredients are chips you can remove, the recipe is a text field, and the
/// eight numbers are behind a disclosure. An estimate the user cannot argue with
/// is an estimate they have to either accept or delete.
struct MealPlanEntrySheet: View {

    let target: MealPlanEditorTarget

    @Environment(\.dismiss) private var dismiss

    @State private var mealType: MealType = .breakfast
    @State private var day: Date = Date()
    @State private var title: String = ""
    /// The dish in a few words, as the estimate named it (#603). Held rather
    /// than shown: the sheet is where the user's own words live, and the short
    /// name is what the TILE prints.
    @State private var shortTitle: String?

    /// The typed title the held `shortTitle` was made from.
    ///
    /// A name describes the words it came from, so editing the words has to
    /// discard it. Comparing against this is how, rather than clearing the name
    /// from an `onChange`: `load()` sets the title and the name in the same
    /// pass, and an `onChange` fires AFTER that pass, so it would throw away the
    /// stored name of every block the moment it was opened.
    @State private var namedTitle: String = ""

    /// The name to write: the held one while it still describes what is typed,
    /// and nil once the words have moved on. The naming pass fills that nil in.
    private var titleToWrite: String? {
        trimmedTitle == namedTitle ? shortTitle : nil
    }
    @State private var ingredients: [String] = []
    @State private var ingredientDraft: String = ""
    @State private var notes: String = ""
    @State private var recipe: String = ""
    @State private var status: MealPlanStatus = .planned
    /// The per-dish breakdown the estimate made. Held so a save carries it, and
    /// shown under the numbers. Not editable here: correcting a portion is the
    /// Tracking detail sheet's job, on a meal that has actually been eaten.
    @State private var items: [MealItemEntry] = []

    @State private var showingNumbers = false
    /// The eight, as strings. Held as text so a half-typed "1." is not rounded
    /// to 1 under the user's caret on every keystroke.
    @State private var values: [Nutrient: String] = [:]
    /// True when the numbers on screen came from the model or from a block
    /// that already had them. It decides the estimate button's wording and the
    /// provenance a new block is saved with — NOT whether numbers are written.
    /// What gets written is whatever is in the fields; see `nutrientsToWrite`.
    @State private var hasNumbers = false

    /// The meal this block has been logged as, or nil (#612). Resolved from the
    /// store rather than from the block's stored id alone, so a meal deleted on
    /// Tracking un-ticks the control instead of leaving it ticked at nothing.
    @State private var loggedMeal: LocalMeal?
    @State private var isLogging = false

    @State private var phase: Phase = .idle
    @State private var errorMessage: String?
    @State private var loaded = false

    /// Whether the saved-item picker is up (#625).
    @State private var showingPicker = false

    /// Pictures of the dish, held only until the estimate returns (#627).
    ///
    /// On a plan this is most often a menu, a recipe page or a photograph of
    /// something eaten elsewhere that is worth repeating. Same lifetime rule as
    /// the Tracking composer: an input, never an attachment, dropped once the
    /// estimate has read it. See `MealPhoto`.
    @State private var photos: [MealPhoto] = []

    private enum Phase: Equatable {
        case idle
        case estimating
    }

    private var plans: MealPlanService { .default() }
    private var estimator: MealPlanEstimationService { .default() }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedTitle.isEmpty && phase != .estimating }
    /// A dish name OR a picture of one (#627). `canSave` is deliberately NOT
    /// widened to match: a block still has to be NAMED to be saved, and the
    /// photo is not kept, so a nameless block would be a row with nothing on it.
    /// The estimate is what fills the name in.
    private var canEstimate: Bool {
        (!trimmedTitle.isEmpty || !photos.isEmpty) && phase != .estimating
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.canvasIgnoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.lg) {
                            mealTypeSection
                            titleSection
                            estimateSection
                            daySection
                            numbersSection
                            ingredientsSection
                            recipeSection
                            notesSection
                            logSection
                            if let errorMessage {
                                Text(errorMessage)
                                    .font(.edFootnote)
                                    .foregroundStyle(Tokens.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(Space.lg)
                    }
                    footer
                }
            }
            .navigationTitle(isNew ? "Plan a meal" : "Planned meal")
            .inlineNavigationTitle()
        }
        #if os(macOS)
        // A macOS sheet with no explicit size collapses to its toolbar (#474).
        // On a phone this minWidth is wider than the screen, so it stays out of
        // the iOS tree entirely.
        .frame(minWidth: 500, idealWidth: 560, minHeight: 620, idealHeight: 760)
        #endif
        .onAppear(perform: load)
        .sheet(isPresented: $showingPicker) {
            // `initialPicks` is deliberately empty every time. The picker hands
            // back its WHOLE tray, and this sheet ADDS that tray to what it
            // already holds, so seeding it with the last round would count the
            // same yogurt twice.
            FoodItemPickerSheet { chosen in
                adoptPicks(chosen)
            }
        }
    }

    // MARK: - Meal type

    private var mealTypeSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Meal").eyebrow()
            EdTabStrip(
                tabs: MealType.allCases,
                selection: $mealType,
                label: { $0.displayName },
                accessibilityName: "Meal"
            )
        }
    }

    // MARK: - Title

    /// The dish, with the camera and the microphone inside its border (#627).
    ///
    /// The same two accessories the Tracking composer carries, laid out the same
    /// way and for the same reason: they are other ways of filling THIS field,
    /// not other actions. A plan is usually typed from memory, so these matter
    /// less here than on Tracking — but a menu photographed at the table and a
    /// dish named out loud while cooking are both real, and a user who learns
    /// the gesture on one surface should find it on the other.
    private var titleSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("What are you having?").eyebrow()
            TextField("Chicken rice", text: $title, axis: .vertical)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .paperFieldOnMac()
                .padding(Space.md)
                .padding(.trailing, accessoryGutter)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)
                .overlay(alignment: .bottomTrailing) {
                    MealCaptureAccessories(
                        text: $title,
                        photos: $photos,
                        isEnabled: phase != .estimating,
                        onError: { errorMessage = $0 }
                    )
                    .padding(.trailing, Space.sm)
                    .padding(.bottom, Space.sm)
                }
            if !photos.isEmpty {
                MealPhotoStrip(
                    photos: $photos,
                    note: trimmedTitle.isEmpty
                        ? "Estimate will name the dish from the picture."
                        : nil
                )
            }
        }
    }

    /// Room for the two accessory glyphs on the field's last line. Matches
    /// `MealComposer.accessoryGutter`, including the reason it no longer forks
    /// per platform: the Mac carries the microphone too since #640.
    private var accessoryGutter: CGFloat {
        28 + Space.xs + 28 + Space.sm
    }

    // MARK: - Day

    /// The day control is here as well as in the section chrome, and that is not
    /// a second answer to the same question.
    ///
    /// The chrome calendar chooses which day you are LOOKING at; this chooses
    /// which day a block BELONGS to. They are the same value only until you want
    /// to move Thursday's dinner to Friday, which is the most common edit a plan
    /// gets and which the calendar cannot express at all.
    private var daySection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Day").eyebrow()
            // Dexter's own calendar, not the system one. See `EdDayPicker`.
            EdDayPicker(
                day: $day,
                accessibilityName: "Day this meal is planned for",
                tint: mealType.tint
            )
        }
    }

    // MARK: - Estimate

    /// The one API call in this sheet, and the one control that spends money.
    ///
    /// ### Why it sits directly under the dish
    ///
    /// The sheet is read top to bottom as the order of the work: what are you
    /// having, work it out, which day, what it costs. It used to ask for the day
    /// in between, which put a field nobody had a question about between the
    /// dish and the control that acts on it (#607).
    ///
    /// ### Why it is a full-width slab
    ///
    /// It was a small secondary button in a row with empty space beside it,
    /// under a grey sentence explaining itself. That made the one control that
    /// fills the rest of the sheet in look like the least important thing on it.
    /// The explanation came off with it: a button that says what it will do does
    /// not need a paragraph saying the same thing more slowly.
    private var estimateSection: some View {
        Button(action: estimate) {
            HStack(spacing: Space.sm) {
                if phase == .estimating {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #else
                        .scaleEffect(0.7)
                        #endif
                        .tint(Tokens.accentFg)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(estimateLabel)
            }
        }
        .buttonStyle(MealEstimateButtonStyle())
        .disabled(!canEstimate)
        .opacity(canEstimate ? 1 : 0.45)
        .accessibilityLabel(estimateLabel)
        .accessibilityHint("Works out the nutrition, the key ingredients and a recipe. You can edit all of it afterwards.")
    }

    private var estimateLabel: String {
        if phase == .estimating { return "Working it out…" }
        return hasNumbers ? "Estimate again" : "Estimate"
    }

    // MARK: - Numbers

    /// The eight, always here and always editable.
    ///
    /// ### Why it is not behind the estimate
    ///
    /// It used to appear only once an estimate had filled it in, which made the
    /// model the only way to put numbers on a planned meal. That is wrong twice
    /// over: the user often KNOWS the figures — a packet, a brand, a dish they
    /// have logged fifty times — and the estimate costs money and a few seconds
    /// to reach a worse answer than the one they already have. A plan you can
    /// only complete by asking is not a plan you own.
    ///
    /// ### Five fields, then three
    ///
    /// Calories and the four macros are what a plan is read against, so they
    /// are on the surface. Sugar, sodium and saturated fat are real and tracked,
    /// and are typed by hand roughly never, so they wait behind a disclosure
    /// rather than making the common case scroll past them.
    private var numbersSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text("Nutrition").eyebrow()
                Spacer(minLength: Space.sm)
                // A planned block is often a packet: the overnight oats, the
                // shake, the wafer. Finding it beats typing eight numbers off
                // the back of it for the second time (#625).
                Button("Find an item") { showingPicker = true }
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                if anyNumberEntered {
                    // Erases every number typed or estimated into this sheet.
                    // It was `.ghost`, i.e. identical to the "Find an item"
                    // lookup beside it, so nothing told the two apart (#645).
                    Button("Clear", action: clearNumbers)
                        .buttonStyle(EdButtonStyle(kind: .danger, size: .sm))
                }
            }

            // The same pills the block draws, so the sheet is a preview of what
            // you will see on the plan rather than a second way of stating it.
            if let preview = enteredNutrients {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(MealFormat.calories(preview.calories))
                            .font(.edDisplay)
                            .foregroundStyle(Tokens.ink)
                            .monospacedDigit()
                        Text("kcal")
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.muted)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)

                    MealPlanNutrientPills(nutrients: preview, compact: false)
                }
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Self.keyNutrients) { nutrient in
                    numberField(for: nutrient)
                }
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) { showingNumbers.toggle() }
            } label: {
                HStack(spacing: Space.xs) {
                    Text(showingNumbers ? "Fewer" : "Sugar, sodium and saturated fat")
                    Image(systemName: showingNumbers ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))

            if showingNumbers {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(Self.minorNutrients) { nutrient in
                        numberField(for: nutrient)
                    }
                }
            }

            if !items.isEmpty { breakdown }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    private func numberField(for nutrient: Nutrient) -> some View {
        MealNumberField(
            label: nutrient.displayName,
            unit: nutrient.unit,
            text: Binding(
                get: { values[nutrient] ?? "" },
                set: { values[nutrient] = $0 }
            )
        )
    }

    /// Calories and the macros: the five a plan is read against.
    private static let keyNutrients: [Nutrient] = [.calories] + Nutrient.macrosInOrder
    private static let minorNutrients: [Nutrient] = Nutrient.allCases.filter { !keyNutrients.contains($0) }

    /// True once any of the eight carries something. The test every other part
    /// of this sheet asks, so "has numbers" cannot mean one thing to the save
    /// and another to the UI.
    private var anyNumberEntered: Bool {
        Nutrient.allCases.contains { !(values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The eight as typed, or nil when none of them is.
    private var enteredNutrients: MealNutrients? {
        guard anyNumberEntered else { return nil }
        var out = MealNutrients.zero
        for nutrient in Nutrient.allCases {
            out[nutrient] = MealItemDraft.number(values[nutrient] ?? "")
        }
        return out
    }

    /// What the estimate thought the meal was made of, with its assumed
    /// portions. Read-only here on purpose: correcting a portion belongs on a
    /// meal that has been EATEN, where the correction changes a real total, and
    /// putting it on a forecast would invite the user to tune numbers that are
    /// about to be replaced.
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Breakdown").eyebrow()
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(item.name)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.inkSoft)
                    Spacer(minLength: Space.sm)
                    Text(item.portionDescription)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                        .monospacedDigit()
                    Text("\(MealFormat.calories(item.calories)) kcal")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Fold a round of picks into the block (#625).
    ///
    /// ### Why the fields are added to and not replaced
    ///
    /// A planned block is built in pieces: two eggs typed in, then the yogurt
    /// picked, then a shake picked. Each of those is part of the same meal, so
    /// a pick that overwrote the fields would delete the part the user had
    /// already worked out. Adding is also what makes the second press of the
    /// button mean what it looks like it means.
    ///
    /// All eight are written, including the ones that come to zero. A picked
    /// item states its sugar and its sodium; zero there is a reading, not a
    /// blank, and leaving the field empty would make the block claim it does
    /// not know.
    ///
    /// ### Why the rows are written but NOT counted as used
    ///
    /// An item found in the public food database is not in the library until
    /// something commits it, so this calls `FoodItemPick.commit` and the row
    /// exists afterwards: planning tomorrow's shake and then logging it should
    /// find the same item, not search for it twice.
    ///
    /// `countingUse` is false, and that is the difference between planning and
    /// eating. The use counters order the picker by what gets EATEN. A plan is
    /// a forecast, and a block ticked off later logs a real meal through its
    /// own path. Counting a plan would let a week of intentions outrank the
    /// thing the user has actually had forty times.
    ///
    /// ### Why `hasNumbers` is left alone
    ///
    /// On a new block that flag chooses between `MealPlanSource.manual` and
    /// `MealPlanSource.chat`, and `chat` is documented as "the model's
    /// estimate of a meal that has not been eaten". These figures are the
    /// opposite of that, so `manual` is the honest half of the pair the enum
    /// offers. The block still saves WITH its numbers either way, because
    /// `nutrientsToWrite` reads the fields and not this flag.
    private func adoptPicks(_ picks: [FoodItemPick]) {
        let entries = picks.map(\.entry)
        guard !entries.isEmpty else { return }

        // The one commit path, with the plan's own answer to the counters.
        FoodItemPick.commit(picks, countingUse: false)

        items += entries

        let added = MealNutrients.sum(of: entries)
        for nutrient in Nutrient.allCases {
            let current = MealItemDraft.number(values[nutrient] ?? "")
            values[nutrient] = MealItemDraft.string(current + added[nutrient])
        }
    }

    private func clearNumbers() {
        for nutrient in Nutrient.allCases { values[nutrient] = "" }
        items = []
        hasNumbers = false
        showingNumbers = false
    }

    // MARK: - Ingredients

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack(spacing: Space.sm) {
                Text("Key ingredients").eyebrow()
                Spacer(minLength: 0)
                Text("what you'll need to buy")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }

            if !ingredients.isEmpty {
                ChipFlowLayout(spacing: Space.xs) {
                    ForEach(ingredients, id: \.self) { ingredient in
                        Button {
                            ingredients.removeAll { $0 == ingredient }
                        } label: {
                            HStack(spacing: 4) {
                                Text(ingredient)
                                    .font(.edCaption)
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .foregroundStyle(Tokens.inkSoft)
                            .padding(.horizontal, Space.sm)
                            .padding(.vertical, 4)
                            .background(Tokens.surface2, in: Capsule())
                            .overlay(Capsule().stroke(Tokens.border, lineWidth: 0.5))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(ingredient)")
                    }
                }
            }

            HStack(spacing: Space.sm) {
                TextField("Add an ingredient", text: $ingredientDraft)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.ink)
                    .textFieldStyle(.plain)
                    .paperFieldOnMac()
                    .noAutocapitalization()
                    .submitLabel(.done)
                    .onSubmit(commitIngredient)
                Button("Add", action: commitIngredient)
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                    .disabled(ingredientDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Commit whatever is in the field, then clear it.
    ///
    /// Splits on commas, so pasting "chicken, rice, cucumber" makes three chips
    /// rather than one very long one. `MealPlanService.cleaned` does the
    /// trimming and the de-duplication, so this sheet, the estimate and the
    /// service cannot disagree about what counts as a repeat.
    private func commitIngredient() {
        let parts = ingredientDraft.split(separator: ",").map(String.init)
        guard !parts.isEmpty else { return }
        ingredients = MealPlanService.cleaned(ingredients + parts)
        ingredientDraft = ""
    }

    // MARK: - Recipe

    private var recipeSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack(spacing: Space.sm) {
                Text("Recipe").eyebrow()
                Spacer(minLength: 0)
                Text("optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            TextField("One step per line", text: $recipe, axis: .vertical)
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .lineLimit(2...10)
                .textFieldStyle(.plain)
                .paperFieldOnMac()
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    // MARK: - Note

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Note").eyebrow()
            TextField("Soak the beans overnight", text: $notes, axis: .vertical)
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .paperFieldOnMac()
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    // MARK: - Did you have it?

    /// Log this block as a meal, from the numbers it already carries (#612).
    ///
    /// ### Why it is here and not on Tracking
    ///
    /// Everything a logged meal needs is already on this block: the day, the
    /// meal type, the dish, the breakdown and the eight totals. Typing it again
    /// on the composer buys a second estimate of a meal that has been estimated
    /// once, at the price of a call, a few seconds, and two sets of numbers for
    /// one dinner that can disagree.
    ///
    /// ### Why it acts immediately
    ///
    /// Every other control on this sheet is a FIELD, and fields are applied by
    /// Save. This is an action: it writes a row in another table, the way Delete
    /// does. Deferring it to Save would make "Cancel" mean "do not log", which
    /// is a third meaning for a button that already has two.
    ///
    /// ### Why a future block cannot be ticked
    ///
    /// A meal is a record of something already eaten. The composer will not
    /// write to a day past today either, and the model's own date is clamped
    /// forward for the same reason (#592).
    @ViewBuilder
    private var logSection: some View {
        if case .existing(let entry) = target {
            VStack(alignment: .leading, spacing: Space.sm) {
                Button {
                    toggleLogged(entry)
                } label: {
                    HStack(alignment: .top, spacing: Space.md) {
                        Image(systemName: loggedMeal == nil ? "square" : "checkmark.square.fill")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(loggedMeal == nil ? Tokens.mutedSoft : Tokens.success)
                            .frame(width: 22, height: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Did you have this meal?")
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                            Text(logCaption)
                                .font(.edCaption)
                                .foregroundStyle(loggedMeal == nil ? Tokens.muted : Tokens.success)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        if isLogging {
                            ProgressView()
                                #if os(macOS)
                                .controlSize(.small)
                                #else
                                .scaleEffect(0.7)
                                #endif
                        }
                    }
                    .padding(Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                    .paperBorder(Tokens.border, radius: Radius.lg)
                    .contentShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canLog || isLogging)
                .opacity(canLog ? 1 : 0.55)
                .accessibilityLabel("Did you have this meal?")
                .accessibilityValue(loggedMeal == nil ? "Not logged" : "Logged")
                .accessibilityHint(canLog ? "Logs it to the day it was planned for, with no new estimate" : "Only a meal on today or an earlier day can be logged")
            }
        }
    }

    /// What the control says under its question, in the three states it has.
    private var logCaption: String {
        guard canLog else {
            return "Planned for \(Self.dayPhrase.string(from: day)). You can log it on the day."
        }
        guard loggedMeal != nil else {
            if enteredNutrients == nil {
                return "Logs it onto \(Self.dayPhrase.string(from: day)) with no numbers, since this block has none."
            }
            return "Logs it onto \(Self.dayPhrase.string(from: day)) with these numbers. No new estimate."
        }
        return "Logged to \(Self.dayPhrase.string(from: day)). Untick to remove it from Tracking."
    }

    /// Only a block on today or an earlier day. Read from the DAY FIELD rather
    /// than from the stored block, so moving a block forward in the sheet
    /// disables the control before the move is even saved.
    private var canLog: Bool {
        Calendar.current.startOfDay(for: day) <= Calendar.current.startOfDay(for: Date())
    }

    private func toggleLogged(_ entry: LocalMealPlanEntry) {
        errorMessage = nil
        isLogging = true
        defer { isLogging = false }
        do {
            if loggedMeal == nil {
                // The block is saved FIRST, so what gets logged is what is on
                // screen. Without it, an estimate run in this sheet and never
                // saved would be logged as the numbers the block held before it.
                try persist()
                loggedMeal = try plans.logAsMeal(entry)
                status = entry.statusEnum
                Haptics.light()
            } else {
                try plans.unlogAsMeal(entry)
                loggedMeal = nil
                status = entry.statusEnum
                Haptics.light()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let dayPhrase: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM"
        return f
    }()

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)

            HStack(spacing: Space.sm) {
                if case .existing(let entry) = target {
                    // Was `.ghost`, which left the one irreversible control in
                    // the sheet visually WEAKER than the Cancel beside it (#645).
                    Button("Delete", role: .destructive) { delete(entry) }
                        .buttonStyle(EdButtonStyle(kind: .danger, size: .sm))
                }
                Spacer(minLength: Space.sm)
                Button("Cancel") { dismiss() }
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                Button(isNew ? "Add" : "Save") { save() }
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        }
        .background(Tokens.surface)
    }

    // MARK: - Load

    private func load() {
        guard !loaded else { return }
        loaded = true

        switch target {
        case .new(let day, let mealType):
            self.day = Calendar.current.startOfDay(for: day)
            self.mealType = mealType
            for nutrient in Nutrient.allCases { values[nutrient] = "" }

        case .existing(let entry):
            day = entry.deviceDay
            mealType = entry.mealTypeEnum
            title = entry.title
            shortTitle = entry.shortTitle
            namedTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            ingredients = entry.ingredients
            notes = entry.notes ?? ""
            recipe = entry.recipe ?? ""
            status = entry.statusEnum
            items = entry.items
            loggedMeal = try? plans.loggedMeal(for: entry)
            let stored = entry.plannedNutrients
            hasNumbers = stored != nil
            for nutrient in Nutrient.allCases {
                values[nutrient] = stored.map { MealItemDraft.string($0[nutrient]) } ?? ""
            }
        }
    }

    // MARK: - Estimate

    /// Ask the model, then fill the fields it answered and leave the rest alone.
    ///
    /// A re-estimate REPLACES the ingredients, the numbers and the breakdown,
    /// because those are three views of one answer and keeping half of an old
    /// one beside half of a new one would produce a block whose ingredients do
    /// not make its calories.
    ///
    /// The note is never touched: it is the user's, not the model's. The recipe
    /// is replaced only when the new answer HAS one, so re-estimating a dish
    /// whose method the model now considers obvious does not silently delete a
    /// recipe the user has been keeping.
    private func estimate() {
        let dish = trimmedTitle
        let attached = photos
        guard !dish.isEmpty || !attached.isEmpty else { return }
        errorMessage = nil
        phase = .estimating

        Task { @MainActor in
            defer { phase = .idle }
            do {
                let planned = try await estimator.estimate(
                    title: dish,
                    photos: attached,
                    mealType: mealType
                )

                guard !planned.estimate.needsDetail else {
                    errorMessage = dish.isEmpty
                        ? "Dexter couldn't tell what that is. Try another photo, or type the dish in yourself."
                        : "Dexter couldn't tell what that is. Add a little more to the name, or fill the numbers in yourself."
                    return
                }

                // A picture with no typed name: the model's reading of it IS the
                // name, because the photo is not kept and `canSave` still
                // requires one (#627). Falls back to nothing if the model
                // returned no title, which leaves Save disabled and the field
                // empty — the honest state, not a placeholder dish.
                let resolvedDish = dish.isEmpty
                    ? (planned.estimate.title ?? "")
                    : dish
                if dish.isEmpty, !resolvedDish.isEmpty {
                    title = resolvedDish
                    // The photo said everything it had to say. Leaving it
                    // attached would send it again on a re-estimate of a dish
                    // that now has a name.
                    photos = []
                }

                items = planned.estimate.items
                shortTitle = planned.estimate.title
                namedTitle = resolvedDish
                ingredients = planned.ingredients
                if let newRecipe = planned.recipe { recipe = newRecipe }
                for nutrient in Nutrient.allCases {
                    values[nutrient] = MealItemDraft.string(planned.estimate.nutrients[nutrient])
                }
                hasNumbers = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Save

    /// The eight as they should be written, or nil for "this block has no
    /// numbers".
    ///
    /// Reads the FIELDS, not a flag. It used to read `hasNumbers`, which was
    /// set by the estimate, so a user who typed the figures themselves saved a
    /// block with none: the numbers were on screen and thrown away on Save.
    /// Emptying every field is how you remove them, which is also what the
    /// Clear button does.
    private var nutrientsToWrite: MealNutrients? { enteredNutrients }

    private func save() {
        errorMessage = nil
        do {
            try persist()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Write the fields, without dismissing.
    ///
    /// Split out of `save()` for the log control (#612), which has to commit
    /// what is on screen BEFORE it copies the block into a meal: an estimate
    /// run in this sheet and not yet saved would otherwise be logged as the
    /// numbers the block held before it.
    private func persist() throws {
    switch target {
        case .new:
            try plans.addEntry(
                date: day,
                mealType: mealType,
                title: title,
                shortTitle: titleToWrite,
                ingredients: ingredients,
                notes: notes,
                recipe: recipe,
                status: .planned,
                nutrients: nutrientsToWrite,
                items: items,
                // Provenance, not content. On a new block `hasNumbers` is
                // true only after an estimate has run, so a user who typed
                // the figures themselves is recorded as having done so.
                source: hasNumbers ? MealPlanSource.chat : MealPlanSource.manual
            )
        case .existing(let entry):
            try plans.updateEntry(
                entry,
                date: day,
                mealType: mealType,
                title: title,
                // `.some(...)`, so a title edited without a re-estimate
                // CLEARS the stored name rather than leaving the block
                // labelled after the words it used to hold. The naming pass
                // picks it up again (#603).
                shortTitle: .some(titleToWrite),
                ingredients: ingredients,
                // `.some(...)` all the way down: the sheet always knows the
                // state of both text fields, so "leave it alone" is never
                // what it means. An emptied note clears the note, an emptied
                // recipe clears the recipe, and an emptied set of numbers
                // removes them (#444, #488).
                notes: .some(notes),
                recipe: .some(recipe),
                status: status,
                nutrients: .some(nutrientsToWrite),
                items: items
            )
    }
    }

    private func delete(_ entry: LocalMealPlanEntry) {
        do {
            try plans.deleteEntry(entry)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The plan sheet's Estimate control (#607).
///
/// ### Why it is not `EdButtonStyle(kind: .primary)`
///
/// The primary style is the app's ink-on-paper slab, and it is what the Add and
/// Save buttons in this sheet's footer wear. Estimate is not one of those: it
/// does not commit anything, it goes and fetches. Drawing it in the same ink as
/// the footer's Save would put two identical-looking slabs on one sheet with
/// completely different consequences, which is the one mistake a form cannot
/// afford to invite.
///
/// So it takes a green ground and a taller box. The height is the point as much
/// as the colour: this is a control you press once and then wait on, and a 6pt
/// vertical padding reads as a link with a background rather than as something
/// with a press in it.
///
/// ### Green here is not a verdict
///
/// On the Tracking surfaces hue means a reading of a quantity against a target,
/// and green means "on track". That rule does not reach this sheet: the plan
/// palette is identity-only (see `MealPlanNutrientPills`), and a filled control
/// under the dish field is not a mark on a number. It cannot be confused with a
/// verdict because there is no quantity for it to be a verdict ABOUT.
struct MealEstimateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.edBodyMedium)
            .foregroundStyle(Tokens.accentFg)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity)
            .background(
                Tokens.success.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
