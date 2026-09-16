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

    @State private var phase: Phase = .idle
    @State private var errorMessage: String?
    @State private var loaded = false

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
    private var canEstimate: Bool { !trimmedTitle.isEmpty && phase != .estimating }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.canvasIgnoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.lg) {
                            mealTypeSection
                            titleSection
                            daySection
                            estimateSection
                            numbersSection
                            ingredientsSection
                            recipeSection
                            notesSection
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
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
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
    /// Labelled by what it will DO rather than by what it is ("Estimate with
    /// Dexter", not "AI"), and it states what comes back, because a button that
    /// costs a few seconds and a few cents should say what it is buying.
    private var estimateSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Button(action: estimate) {
                    HStack(spacing: Space.xs) {
                        if phase == .estimating {
                            ProgressView()
                                #if os(macOS)
                                .controlSize(.small)
                                #else
                                .scaleEffect(0.7)
                                #endif
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(estimateLabel)
                    }
                }
                .buttonStyle(EdButtonStyle(kind: hasNumbers ? .secondary : .primary, size: .sm))
                .disabled(!canEstimate)
                .opacity(canEstimate ? 1 : 0.5)
                Spacer(minLength: 0)
            }

            Text("Dexter works out the nutrition, the key ingredients and a recipe when the method is not obvious. You can edit all of it afterwards.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var estimateLabel: String {
        if phase == .estimating { return "Working it out…" }
        return hasNumbers ? "Estimate again" : "Estimate with Dexter"
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
                if anyNumberEntered {
                    Button("Clear", action: clearNumbers)
                        .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
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

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)

            HStack(spacing: Space.sm) {
                if case .existing(let entry) = target {
                    Button("Delete", role: .destructive) { delete(entry) }
                        .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
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
            ingredients = entry.ingredients
            notes = entry.notes ?? ""
            recipe = entry.recipe ?? ""
            status = entry.statusEnum
            items = entry.items
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
        guard !dish.isEmpty else { return }
        errorMessage = nil
        phase = .estimating

        Task { @MainActor in
            defer { phase = .idle }
            do {
                let planned = try await estimator.estimate(title: dish, mealType: mealType)

                guard !planned.estimate.needsDetail else {
                    errorMessage = "Dexter couldn't tell what that is. Add a little more to the name, or fill the numbers in yourself."
                    return
                }

                items = planned.estimate.items
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
            switch target {
            case .new:
                try plans.addEntry(
                    date: day,
                    mealType: mealType,
                    title: title,
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
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
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
