import SwiftUI
import SwiftData

/// What the plan editor was opened on (#599).
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

/// Add or edit one planned meal (#599).
///
/// ### Everything is optional except the title
///
/// A block is worth writing down the moment it has a name. The ingredients, the
/// note and the numbers are all things you might add later or never, and an
/// editor that demanded them would make "chicken rice on Thursday" a form to
/// fill in rather than a thing to jot down.
///
/// The numbers sit behind a disclosure for the same reason: eight fields open by
/// default would make a two-second edit look like a chore, and almost no
/// hand-typed block ever gets them. They are there for a block that came from a
/// chat suggestion and for the user who does want to plan a day against a
/// target.
///
/// ### Clearing the numbers is a real action
///
/// "Remove the numbers" is not the same request as "set them all to zero", and
/// the service takes a double optional so the two stay expressible (#444, #488).
/// This is the surface that can issue both: emptying every field leaves zeros,
/// and the Clear button sends the removal.
struct MealPlanEntryEditor: View {

    let target: MealPlanEditorTarget

    @Environment(\.dismiss) private var dismiss

    @State private var mealType: MealType = .breakfast
    @State private var day: Date = Date()
    @State private var title: String = ""
    @State private var ingredients: [String] = []
    @State private var ingredientDraft: String = ""
    @State private var notes: String = ""
    @State private var status: MealPlanStatus = .planned

    @State private var showingNumbers = false
    /// The eight, as strings. Held as text so a half-typed "1." is not rounded
    /// to 1 under the user's caret on every keystroke.
    @State private var values: [Nutrient: String] = [:]
    /// True when the block arrived with numbers. Decides whether an untouched
    /// disclosure means "leave them" or "there were none".
    @State private var startedWithNumbers = false

    @State private var errorMessage: String?
    @State private var loaded = false

    private var service: MealPlanService { .default() }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                            daySection
                            ingredientsSection
                            notesSection
                            numbersSection
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
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 680)
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

    /// The day control is here as well as in the calendar, and that is not a
    /// second answer to the same question.
    ///
    /// The calendar chooses which day you are LOOKING at; this chooses which day
    /// a block BELONGS to. They are the same value only until you want to move
    /// Thursday's dinner to Friday, which is the single most common edit a plan
    /// gets and which the calendar cannot express at all.
    private var daySection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Day").eyebrow()
            DatePicker("Day", selection: $day, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.compact)
                .accessibilityLabel("Day this meal is planned for")
        }
    }

    // MARK: - Ingredients

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack(spacing: Space.sm) {
                Text("Main ingredients").eyebrow()
                Spacer(minLength: 0)
                Text("the few that matter")
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
    /// trimming and the de-duplication, so the editor and the service cannot
    /// disagree about what counts as a repeat.
    private func commitIngredient() {
        let parts = ingredientDraft.split(separator: ",").map(String.init)
        guard !parts.isEmpty else { return }
        ingredients = MealPlanService.cleaned(ingredients + parts)
        ingredientDraft = ""
    }

    // MARK: - Notes

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

    // MARK: - Numbers

    private var numbersSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showingNumbers.toggle() }
            } label: {
                HStack(spacing: Space.sm) {
                    Text("Rough numbers").eyebrow()
                    Image(systemName: showingNumbers ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.mutedSoft)
                    Spacer(minLength: 0)
                    if !showingNumbers, startedWithNumbers {
                        Text("\(values[.calories] ?? "0") kcal")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .monospacedDigit()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showingNumbers ? "Hide rough numbers" : "Show rough numbers")

            if showingNumbers {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Optional. They let the day add up against your targets. Leave them out and the block still counts as planned.")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Nutrient.allCases) { nutrient in
                        MealNumberField(
                            label: nutrient.displayName,
                            unit: nutrient.unit,
                            text: Binding(
                                get: { values[nutrient] ?? "" },
                                set: { values[nutrient] = $0 }
                            )
                        )
                    }

                    if startedWithNumbers || hasAnyTypedNumber {
                        Button("Remove the numbers", action: clearNumbers)
                            .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                    }
                }
                .padding(Space.lg)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.lg)
            }
        }
    }

    private var hasAnyTypedNumber: Bool {
        Nutrient.allCases.contains { !(values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func clearNumbers() {
        for nutrient in Nutrient.allCases { values[nutrient] = "" }
        startedWithNumbers = false
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
            status = entry.statusEnum
            let stored = entry.plannedNutrients
            startedWithNumbers = stored != nil
            showingNumbers = stored != nil
            for nutrient in Nutrient.allCases {
                values[nutrient] = stored.map { MealItemDraft.string($0[nutrient]) } ?? ""
            }
        }
    }

    // MARK: - Save

    /// The eight as they should be written, or nil for "this block has no
    /// numbers".
    ///
    /// Nil when nothing was typed AND nothing was there to start with. A block
    /// that arrived with numbers and had every field emptied writes zeros, which
    /// is what emptying a field means; removing them outright is the Clear
    /// button, which sets `startedWithNumbers` false and empties the fields, so
    /// both paths land here saying the same thing.
    private var nutrientsToWrite: MealNutrients? {
        guard startedWithNumbers || hasAnyTypedNumber else { return nil }
        var out = MealNutrients.zero
        for nutrient in Nutrient.allCases {
            out[nutrient] = MealItemDraft.number(values[nutrient] ?? "")
        }
        return out
    }

    private func save() {
        errorMessage = nil
        do {
            switch target {
            case .new:
                try service.addEntry(
                    date: day,
                    mealType: mealType,
                    title: title,
                    ingredients: ingredients,
                    notes: notes,
                    status: .planned,
                    nutrients: nutrientsToWrite,
                    source: MealPlanSource.manual
                )
            case .existing(let entry):
                try service.updateEntry(
                    entry,
                    date: day,
                    mealType: mealType,
                    title: title,
                    ingredients: ingredients,
                    // `.some(...)` all the way down: the editor always knows the
                    // state of both fields, so "leave it alone" is never what it
                    // means. An emptied note clears the note and an emptied set
                    // of numbers removes them.
                    notes: .some(notes),
                    status: status,
                    nutrients: .some(nutrientsToWrite)
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ entry: LocalMealPlanEntry) {
        do {
            try service.deleteEntry(entry)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
