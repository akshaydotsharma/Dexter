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

    /// How large the row is set (#623).
    ///
    /// Additive, and `.regular` is the shipped row verbatim: the meal detail
    /// sheet and the targets sheet both name nothing and keep what they had.
    /// `.large` exists for the Targets page, where the six vitals are the page
    /// rather than one block inside a sheet, so the whole page is set a rung up.
    ///
    /// A knob rather than a second field type. Two near-identical rows would
    /// drift the moment one of them grew a validation state, and the caret
    /// behaviour this type exists for is the part nobody would remember to copy.
    enum Size: Equatable {
        case regular
        case large
    }

    let label: String
    let unit: String
    @Binding var text: String
    var size: Size = .regular

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(label)
                .font(labelFont)
                .foregroundStyle(Tokens.muted)
            Spacer(minLength: Space.sm)
            TextField("0", text: $text)
                .font(valueFont)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .decimalKeyboard()
                .textFieldStyle(.plain)
                .frame(width: size == .large ? 84 : 72)
            Text(unit)
                .font(size == .large ? .edFootnote : .edCaption)
                .foregroundStyle(Tokens.muted)
                // Sized to the widest unit any caller passes ("kcal"), at the
                // font this row is set in. A fixed column is what keeps the
                // fields of a stack aligned down the page; it has to grow with
                // the text or the widest unit wraps (#616).
                .frame(width: size == .large ? 36 : 28, alignment: .leading)
        }
        .padding(.vertical, size == .large ? Space.xs : 2)
    }

    /// The label sits a rung UNDER the value, not the other way round (#645).
    ///
    /// These two were previously one token, which is most of why the Meals
    /// sheets read as undifferentiated: this row is reused by the meal editor,
    /// the food-item editor, the targets sheet and the targets card, so every
    /// numeric field in the section showed its name and its number at the same
    /// size and weight.
    ///
    /// The step is made by dropping the LABEL rather than shrinking the value,
    /// which is what the previous note here was protecting against: a field set
    /// under its own label does read as placeholder text. The value keeps its
    /// size and gains weight; the label gives up a rung and goes muted. The
    /// sentence "Weight, 76, kg" still reads as one line, with the number as
    /// the part being stated.
    private var labelFont: Font {
        size == .large ? .edFootnote : .edCaption
    }

    /// The number is the content of the row, so it carries the weight. Same
    /// point size as before at each step, so the fixed value and unit columns
    /// this row depends on are unaffected (#616).
    private var valueFont: Font {
        size == .large ? .edBodyMedium : .edFootnoteStrong
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

    /// The item editor, opened on one dish off this meal (#625). Nil when it
    /// is closed, which is what `sheet(item:)` reads.
    @State private var editorTarget: FoodItemEditorTarget?

    /// Whether the meal-type picker is showing (#629).
    @State private var typePickerOpen = false

    #if os(macOS)
    @State private var typeHovering = false
    #endif

    private var service: MealEstimationService { .default() }

    /// How this meal's figures are printed. A grounded meal and a meal whose
    /// totals the user typed are both stated rather than guessed, so neither is
    /// rounded as if a portion had been assumed for it (#594).
    private var precision: MealFormat.Precision {
        MealGrounding.precision(
            isGrounded: meal.isGrounded,
            totalsWereOverridden: meal.totalsWereOverridden,
            isFromLibrary: meal.source == MealSource.library
        )
    }

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
                        alcoholSection
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
        .sheet(item: $editorTarget) { target in
            // The editor writes the library row and hands it back. Nothing on
            // this meal changes: a logged meal is what was eaten, and keeping
            // one of its dishes is a statement about the NEXT one (#625).
            FoodItemEditorSheet(target: target) { _ in
                editorTarget = nil
            }
        }
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
                mealTypeControl
                Spacer(minLength: Space.sm)
                if meal.isGrounded {
                    MealGrounding.chip()
                }
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
            // After the fact is where the sources belong: the preview had to
            // answer "should I log this", and this sheet answers "where did
            // this number come from" months later (#594).
            MealSourcesBlock(sources: meal.groundingSources)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    /// The meal type, as a control rather than a caption (#629).
    ///
    /// Every other fact about a logged meal is correctable in this sheet: the
    /// description, each item's portion, the totals, the alcohol flag. The type
    /// was the one that was printed and then frozen, so a lunch the composer
    /// read off the clock stayed a lunch.
    ///
    /// It edits in place, where the type is READ, rather than earning a field
    /// of its own further down the sheet. A "Meal" section below the totals
    /// would be a second statement of the same fact, and the user would still
    /// meet the wrong one first (`feedback_put_control_where_the_name_is_read`).
    ///
    /// The grammar is the composer's type picker verbatim: a trigger showing
    /// the current type, a popover of the four options, a checkmark on the one
    /// in force. Not a `Menu` (#540) — a system panel is the one control the
    /// design system cannot reach.
    private var mealTypeControl: some View {
        Button {
            typePickerOpen.toggle()
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: meal.mealTypeEnum.sfSymbol)
                    .font(.system(size: 12, weight: .regular))
                Text(meal.mealTypeEnum.displayName)
                    .font(.edFootnote)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.muted)
                    .rotationEffect(.degrees(typePickerOpen ? 180 : 0))
            }
            .foregroundStyle(Tokens.accentMeals)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A bordered `surface2` chip inside a `surface` card, which is the one
        // pairing that separates in both themes (`project_nested_tile_surfaces`).
        // Without it the trigger reads as the caption it used to be.
        .background(typeTriggerBackground, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .paperBorder(typeTriggerBorder, radius: Radius.sm)
        #if os(macOS)
        .onHover { typeHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: typeHovering)
        #endif
        // `.top`, so the options hang BELOW the trigger. The composer's picker
        // uses `.bottom` because it sits mid-screen; this status block is the
        // first thing in the sheet, and a panel above it is clipped by the
        // sheet's own top edge — two of the four types were cut off.
        .popover(isPresented: $typePickerOpen, arrowEdge: .top) {
            typeOptions
        }
        .accessibilityLabel("Meal type, \(meal.mealTypeEnum.displayName)")
        .accessibilityHint("Changes which part of the day this meal counts towards")
    }

    /// The four types, floated over the sheet.
    ///
    /// No "Auto" row, unlike the composer's picker. Auto is a decision about a
    /// meal that has not been written yet; this one already carries a type, and
    /// "let Dexter decide again" would re-read a clock that has moved on.
    private var typeOptions: some View {
        VStack(spacing: 0) {
            ForEach(MealType.allCases) { type in
                InlineDropdownRow(
                    glyph: .symbol(type.sfSymbol),
                    label: type.displayName,
                    isSelected: meal.mealTypeEnum == type,
                    accent: Tokens.accentMeals
                ) { setType(type) }
            }
        }
        .padding(.vertical, Space.xs)
        .frame(width: 220)
        .background(Tokens.surface)
        .presentationBackground(Tokens.surface)
        // Without this an iPhone adapts a popover into a full-screen sheet,
        // which this sheet cannot host anyway.
        .presentationCompactAdaptation(.popover)
    }

    private var typeTriggerBackground: Color {
        #if os(macOS)
        return typeHovering && !typePickerOpen ? Tokens.surface : Tokens.surface2
        #else
        return Tokens.surface2
        #endif
    }

    private var typeTriggerBorder: Color {
        #if os(macOS)
        return typeHovering || typePickerOpen ? Tokens.borderStrong : Tokens.border
        #else
        return typePickerOpen ? Tokens.borderStrong : Tokens.border
        #endif
    }

    private var describeSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Re-describe").eyebrow()
            // The same plain-field placeholder trap the composer hit (#576).
            // This field is normally seeded with the meal's description, so it
            // only shows a placeholder once the user clears it, which is exactly
            // when an ink-strength "What you ate" reads as text they still have.
            TextField(
                PlainFieldPlaceholder.title("What you ate"),
                text: $descriptionText,
                axis: .vertical
            )
                .font(.edBody)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .padding(Space.md)
                .plainFieldPlaceholder(
                    "What you ate",
                    isVisible: descriptionText.isEmpty,
                    padding: Space.md
                )
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .stroke(Tokens.border, lineWidth: 0.5)
                )
            // Right, and primary. It is the one thing this section is for, and
            // the sheet's other committing controls ("Save these totals",
            // "Apply to this item") all sit at the trailing edge of their own
            // block. A secondary button on the left read as a footnote to the
            // field above it.
            HStack(spacing: Space.sm) {
                Spacer(minLength: 0)
                if isReestimating {
                    ProgressView()
                        #if os(macOS)
                        .controlSize(.small)
                        #else
                        .scaleEffect(0.7)
                        #endif
                }
                Button(isReestimating ? "Estimating…" : "Re-estimate") {
                    if meal.totalsWereOverridden {
                        confirmingReestimate = true
                    } else {
                        reestimate()
                    }
                }
                .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                .disabled(isReestimating || descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    /// The one fact about a meal the user can correct that changes whether a
    /// guard fires (#555).
    ///
    /// It earns a row of its own rather than a line in the items list because
    /// it is not a number: it is the reason a set of numbers is allowed to
    /// disagree with itself. A meal the model read as a soft drink and the user
    /// knows was a cider has to be fixable, or the macro consistency check
    /// flags an honest estimate forever.
    private var alcoholSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Toggle(isOn: alcoholBinding) {
                Text("Contains alcohol")
                    .font(.edFootnote)
            }
            .toggleStyle(.switch)
            .tint(Tokens.accentMeals)
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Reads the stored flag and writes through the service, which re-grades
    /// the meal on the new answer. The decision about WHAT re-grading means
    /// lives in `MealEstimationService.setContainsAlcohol`, not here.
    private var alcoholBinding: Binding<Bool> {
        Binding(
            get: { meal.containsAlcohol },
            set: { setAlcohol($0) }
        )
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

                    HStack(spacing: Space.sm) {
                        Button("Apply to this item") {
                            applyItem(draft.wrappedValue)
                        }
                        .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))

                        // Keep this dish, so the next time it is eaten it is
                        // picked rather than estimated again (#625).
                        //
                        // A plain button inside the row's own drawer, which is
                        // the gesture grammar this sheet already uses for a row
                        // action: the row opens on a TAP and its actions are
                        // buttons inside it. Never a long press, and never a
                        // context menu that only one platform can find
                        // (`feedback_inline_edit_gestures`).
                        Button("Save to library") {
                            // The entry goes through untouched, legacy unit and
                            // all. The editor asks for a weight when the portion
                            // cannot be scaled ("1.5 bowls"), and pre-validating
                            // it here would mean two answers to one question.
                            editorTarget = .fromMealItem(draft.wrappedValue.entry)
                        }
                        .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                    }
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
                        Text(
                            MealFormat.value(
                                meal.nutrients[nutrient],
                                for: nutrient,
                                precision: precision
                            )
                        )
                            // Same weight step as every other label/value pair
                            // in the section (#645).
                            .font(.edFootnoteStrong)
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
                }
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)

                // Outside the tile, at its trailing edge. The tile is the eight
                // fields; the button is what commits them, and a primary
                // control inside the surface it acts on reads as a ninth row.
                HStack(spacing: Space.sm) {
                    Spacer(minLength: 0)
                    Button("Save these totals") { applyOverride() }
                        .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                }
            }
        }
    }

    /// Delete leads, the reversible action trails.
    ///
    /// The two were the other way round, with Delete `.ghost` and a
    /// `.foregroundStyle(Tokens.danger)` chained AFTER `.buttonStyle(...)` that
    /// never took effect: `EdButtonStyle` applies its own `.foregroundStyle` to
    /// the label inside `makeBody`, and the inner one wins. So the sheet's only
    /// destructive control rendered as plain grey text (#645).
    ///
    /// Leading edge with a spring between is the rule the section now follows
    /// everywhere a destructive action shares a row: it puts Delete as far as
    /// the row allows from whatever commits, and it matches the footers in
    /// `FoodItemEditorSheet` and `MealPlanEntrySheet`.
    private var actionsSection: some View {
        HStack(spacing: Space.sm) {
            Button("Delete") { confirmingDelete = true }
                .buttonStyle(EdButtonStyle(kind: .danger, size: .sm))
            Spacer(minLength: Space.sm)
            Button("Repeat today") { repeatToday() }
                .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
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

    /// Write the corrected type (#629).
    ///
    /// Nothing else moves. The type says which part of the day a meal counts
    /// towards; it is not an input to any number, so the totals, the items, the
    /// time and the day all stay exactly as they were. A later re-estimate
    /// picks the corrected type up on its own, because `reestimate` reads the
    /// hint off the meal.
    private func setType(_ type: MealType) {
        typePickerOpen = false
        guard type != meal.mealTypeEnum else { return }
        do {
            try MealService.default().updateMeal(meal, mealType: type)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setAlcohol(_ containsAlcohol: Bool) {
        do {
            try service.setContainsAlcohol(containsAlcohol, on: meal)
            itemDrafts = meal.items.map(MealItemDraft.init)
            for nutrient in Nutrient.allCases {
                overrideValues[nutrient] = MealItemDraft.string(meal.nutrients[nutrient])
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
