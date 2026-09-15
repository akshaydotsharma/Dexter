import SwiftUI
import SwiftData

/// A labelled number field that reads and writes a `Double` through a string
/// (#543).
///
/// A string rather than `TextField(value:format:)` because a partially typed
/// number ("12." on the way to "12.5") is not a `Double`, and the formatted
/// binding rewrites the field under the caret when it cannot parse one. The
/// commit happens when the text is read back, not on every keystroke.
struct MealNumberField: View {
    let label: String
    let unit: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(label)
                .font(.edFootnote)
                .foregroundStyle(Tokens.inkSoft)
            Spacer(minLength: Space.sm)
            TextField("0", text: $text)
                .font(.edFootnote)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .decimalKeyboard()
                .textFieldStyle(.plain)
                .frame(width: 72)
            Text(unit)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .frame(width: 28, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

/// One item being edited, as strings (#543).
struct MealItemDraft {
    var id: UUID
    var name: String
    var portionQuantity: String
    var portionUnit: String
    var values: [Nutrient: String]

    /// The portion and the eight values the draft started from, so a portion
    /// change can scale the numbers by a ratio rather than asking for a fresh
    /// estimate.
    let originalQuantity: Double
    let originalValues: MealNutrients

    init(_ item: MealItemEntry) {
        id = item.id
        name = item.name
        portionQuantity = MealItemDraft.string(item.portionQuantity)
        portionUnit = item.portionUnit.isEmpty ? "g" : item.portionUnit
        originalQuantity = item.portionQuantity
        originalValues = item.nutrients
        var values: [Nutrient: String] = [:]
        for nutrient in Nutrient.allCases {
            values[nutrient] = MealItemDraft.string(item.nutrients[nutrient])
        }
        self.values = values
    }

    static func string(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    static func number(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// Rewrite the eight values for a new portion, in proportion.
    ///
    /// This is the whole reason the portion is stored as a quantity and a unit
    /// rather than as "about a bowl": "the rice was actually double" becomes one
    /// multiplication, not a second API call.
    mutating func scaleToPortion() {
        let newQuantity = MealItemDraft.number(portionQuantity)
        guard originalQuantity > 0, newQuantity > 0 else { return }
        let ratio = newQuantity / originalQuantity
        for nutrient in Nutrient.allCases {
            values[nutrient] = MealItemDraft.string(originalValues[nutrient] * ratio)
        }
    }

    var entry: MealItemEntry {
        var out = MealItemEntry(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            portionQuantity: MealItemDraft.number(portionQuantity),
            portionUnit: portionUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        out.calories = MealItemDraft.number(values[.calories] ?? "0")
        out.proteinG = MealItemDraft.number(values[.protein] ?? "0")
        out.carbsG   = MealItemDraft.number(values[.carbs] ?? "0")
        out.fatG     = MealItemDraft.number(values[.fat] ?? "0")
        out.fibreG   = MealItemDraft.number(values[.fibre] ?? "0")
        out.sugarG   = MealItemDraft.number(values[.sugar] ?? "0")
        out.sodiumMg = MealItemDraft.number(values[.sodium] ?? "0")
        out.satFatG  = MealItemDraft.number(values[.saturatedFat] ?? "0")
        return out
    }
}

/// Correcting a logged meal (#543).
///
/// ### Three levels, and only the first one costs anything
///
/// 1. **Re-describe.** Edit the text, estimate again. One API call.
/// 2. **Edit one item.** Adjust a portion or its numbers. The meal re-totals in
///    Swift. No call.
/// 3. **Override totals.** Type the eight numbers. Source becomes user,
///    confidence becomes exact, and the meal is never re-estimated again without
///    a confirmation. Known beats estimated.
///
/// Plus **Repeat**, which copies the meal to today with its stored numbers and
/// makes no call at all. It is the cheapest capture path in the feature and the
/// main lever on what the feature costs per month.
struct MealDetailSheet: View {
    let meal: LocalMeal

    @Environment(\.dismiss) private var dismiss

    @State private var descriptionText: String = ""
    @State private var itemDrafts: [MealItemDraft] = []
    @State private var expandedItem: UUID?

    @State private var showingOverride = false
    @State private var overrideValues: [Nutrient: String] = [:]

    @State private var isReestimating = false
    @State private var errorMessage: String?
    @State private var confirmingReestimate = false
    @State private var confirmingDelete = false
    @State private var repeatedNote: String?

    private var service: MealEstimationService { .default() }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        statusBlock
                        describeSection
                        if !itemDrafts.isEmpty {
                            itemsSection
                        }
                        totalsSection
                        overrideSection
                        actionsSection
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.edFootnote)
                                .foregroundStyle(Tokens.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let repeatedNote {
                            Text(repeatedNote)
                                .font(.edFootnote)
                                .foregroundStyle(Tokens.success)
                        }
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle("Meal")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        // A macOS sheet with no explicit size collapses to its toolbar (#474).
        // On a phone this minWidth is wider than the screen, so it stays out of
        // the iOS tree entirely.
        .frame(minWidth: 480, idealWidth: 520, minHeight: 600, idealHeight: 720)
        #endif
        .onAppear(perform: load)
        .confirmationDialog(
            "Replace the numbers you typed?",
            isPresented: $confirmingReestimate,
            titleVisibility: .visible
        ) {
            Button("Re-estimate anyway", role: .destructive) { reestimate() }
            Button("Keep my numbers", role: .cancel) {}
        } message: {
            Text("You entered these totals by hand, so they are exact. A re-estimate replaces them with a guess.")
        }
        .confirmationDialog(
            "Delete this meal?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Keep it", role: .cancel) {}
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Label(meal.mealTypeEnum.displayName, systemImage: meal.mealTypeEnum.sfSymbol)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.accentMeals)
                Spacer(minLength: Space.sm)
                Text(MealRow.timeFormatter.string(from: meal.loggedAt))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .monospacedDigit()
                MealFlagChip(
                    MealFormat.confidenceBand(meal.confidence),
                    tint: meal.totalsWereOverridden ? Tokens.success : Tokens.muted
                )
            }
            if let reason = meal.suspectReason {
                Text(reason)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if meal.needsDetail {
                Text("No food was identified in this description. Add detail and re-estimate.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = meal.assumptionsNote {
                Text(note)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    private var describeSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Re-describe").eyebrow()
            TextField("What you ate", text: $descriptionText, axis: .vertical)
                .font(.edBody)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .stroke(Tokens.border, lineWidth: 0.5)
                )
            HStack(spacing: Space.sm) {
                Button(isReestimating ? "Estimating…" : "Re-estimate") {
                    if meal.totalsWereOverridden {
                        confirmingReestimate = true
                    } else {
                        reestimate()
                    }
                }
                .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                .disabled(isReestimating || descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if isReestimating {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #else
                        .scaleEffect(0.7)
                        #endif
                }
                Spacer(minLength: 0)
            }
            Text("Costs one estimate. Correcting a single item below costs nothing.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Items").eyebrow()
            VStack(spacing: 0) {
                ForEach($itemDrafts, id: \.id) { $draft in
                    itemRow($draft)
                    if draft.id != itemDrafts.last?.id {
                        Rectangle().fill(Tokens.divider).frame(height: 0.5)
                    }
                }
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            Text("Change a portion and the item's numbers scale with it. The meal re-totals here, with no estimate.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func itemRow(_ draft: Binding<MealItemDraft>) -> some View {
        let isOpen = expandedItem == draft.wrappedValue.id
        VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedItem = isOpen ? nil : draft.wrappedValue.id
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(draft.wrappedValue.name)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.ink)
                        Text("\(draft.wrappedValue.portionQuantity) \(draft.wrappedValue.portionUnit)")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .monospacedDigit()
                    }
                    Spacer(minLength: Space.sm)
                    Text("\(draft.wrappedValue.values[.calories] ?? "0") kcal")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.inkSoft)
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.muted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.sm) {
                        Text("Portion")
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.inkSoft)
                        Spacer(minLength: Space.sm)
                        TextField("0", text: draft.portionQuantity)
                            .font(.edFootnote)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .decimalKeyboard()
                            .textFieldStyle(.plain)
                            .frame(width: 72)
                            .onSubmit { draft.wrappedValue.scaleToPortion() }
                        TextField("g", text: draft.portionUnit)
                            .font(.edCaption)
                            .textFieldStyle(.plain)
                            .noAutocapitalization()
                            .frame(width: 28)
                    }
                    Button("Scale the numbers to this portion") {
                        draft.wrappedValue.scaleToPortion()
                    }
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))

                    ForEach(Nutrient.allCases) { nutrient in
                        MealNumberField(
                            label: nutrient.displayName,
                            unit: nutrient.unit,
                            text: binding(for: nutrient, in: draft)
                        )
                    }

                    Button("Apply to this item") {
                        applyItem(draft.wrappedValue)
                    }
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                }
                .padding(.top, Space.xs)
            }
        }
        .padding(Space.md)
    }

    private func binding(for nutrient: Nutrient, in draft: Binding<MealItemDraft>) -> Binding<String> {
        Binding(
            get: { draft.wrappedValue.values[nutrient] ?? "0" },
            set: { draft.wrappedValue.values[nutrient] = $0 }
        )
    }

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Meal total").eyebrow()
            VStack(spacing: 0) {
                ForEach(Nutrient.allCases) { nutrient in
                    HStack {
                        Text(nutrient.displayName)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.inkSoft)
                        Spacer(minLength: Space.sm)
                        Text(MealFormat.value(meal.nutrients[nutrient], for: nutrient))
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.ink)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, Space.xs)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var overrideSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showingOverride.toggle()
                }
            } label: {
                HStack(spacing: Space.xs) {
                    Text("Override the totals").eyebrow()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.muted)
                        .rotationEffect(.degrees(showingOverride ? 180 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingOverride {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Type what you know. The meal becomes exact and is never re-estimated without asking you first.")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Nutrient.allCases) { nutrient in
                        MealNumberField(
                            label: nutrient.displayName,
                            unit: nutrient.unit,
                            text: Binding(
                                get: { overrideValues[nutrient] ?? "0" },
                                set: { overrideValues[nutrient] = $0 }
                            )
                        )
                    }
                    Button("Save these totals") { applyOverride() }
                        .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                }
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)
            }
        }
    }

    private var actionsSection: some View {
        HStack(spacing: Space.sm) {
            Button("Repeat today") { repeatToday() }
                .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
            Spacer(minLength: Space.sm)
            Button("Delete") { confirmingDelete = true }
                .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                .foregroundStyle(Tokens.danger)
        }
    }

    // MARK: - Actions

    private func load() {
        guard descriptionText.isEmpty else { return }
        descriptionText = meal.mealDescription
        itemDrafts = meal.items.map(MealItemDraft.init)
        for nutrient in Nutrient.allCases {
            overrideValues[nutrient] = MealItemDraft.string(meal.nutrients[nutrient])
        }
    }

    private func reestimate() {
        let text = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = meal.clientUUID
        let day = meal.deviceDay
        let at = meal.loggedAt
        let type = meal.mealTypeEnum
        isReestimating = true
        errorMessage = nil
        Task {
            defer { isReestimating = false }
            do {
                let checked = try await service.estimate(
                    description: text,
                    mealTypeHint: type,
                    loggedAt: at
                )
                // The same `clientUUID` makes this a CORRECTION of the row, not
                // a second meal — the identity contract `MealService.addMeal`
                // holds for a retried Shortcut serves the re-estimate too.
                try service.save(
                    checked,
                    description: text,
                    day: day,
                    loggedAt: at,
                    source: MealSource.composer,
                    clientUUID: id
                )
                itemDrafts = meal.items.map(MealItemDraft.init)
                for nutrient in Nutrient.allCases {
                    overrideValues[nutrient] = MealItemDraft.string(meal.nutrients[nutrient])
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyItem(_ draft: MealItemDraft) {
        do {
            try service.replaceItem(draft.entry, in: meal)
            itemDrafts = meal.items.map(MealItemDraft.init)
            for nutrient in Nutrient.allCases {
                overrideValues[nutrient] = MealItemDraft.string(meal.nutrients[nutrient])
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyOverride() {
        var values = MealNutrients.zero
        for nutrient in Nutrient.allCases {
            values[nutrient] = max(MealItemDraft.number(overrideValues[nutrient] ?? "0"), 0)
        }
        do {
            try service.overrideTotals(of: meal, with: values)
            errorMessage = nil
            showingOverride = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func repeatToday() {
        do {
            try service.repeatMeal(meal)
            repeatedNote = "Copied to today. No estimate was made."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try MealService.default().deleteMeal(meal)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
