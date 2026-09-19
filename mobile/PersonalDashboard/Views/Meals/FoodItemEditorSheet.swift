import SwiftUI
import SwiftData

/// What the item editor was opened on (#625).
///
/// An enum rather than an optional row plus a handful of loose parameters, for
/// the reason `MealPlanEditorTarget` gives: an import carries facts a blank form
/// does not, and holding those as separate `@State` on the parent is how two
/// sheets end up disagreeing about what they are editing.
///
/// ### Which cases are live, and which are a route nothing takes today
///
/// `existing` and `fromMealItem` are the two the app constructs. The first is
/// the per-row Edit in the picker, the second is "Save to library" on a dish in
/// `MealDetailSheet`. Both are CORRECTIONS: fixing a number, or keeping
/// something already eaten. Neither asks the user to curate a list.
///
/// `new`, `draft`, `scannedDraft` and `newBarcode` are the confirm-before-save
/// route, and nothing constructs them any more (#625). A search hit and a
/// barcode scan now go straight into the meal, because the form in front of
/// every import was the friction that turned the library into a thing to
/// maintain. They are kept, rather than deleted, because they are the complete
/// and tested way to open this form on a draft, and a future caller that wants
/// a confirm step should use them instead of writing a second one.
///
/// - `scannedDraft` is a database hit that arrived from a scan rather than from
///   a typed search. The numbers are identical; the PROVENANCE is not, and
///   `LocalFoodItem.source` is the field that has to tell them apart.
/// - `newBarcode` is a code the database did not know: a blank form with one
///   fact already in hand.
enum FoodItemEditorTarget: Identifiable {
    /// A blank form.
    case new
    /// A hit from an Open Food Facts search, to be confirmed.
    case draft(FoodItemDraft)
    /// A hit reached by scanning the packet, to be confirmed.
    case scannedDraft(FoodItemDraft)
    /// A scanned code the database did not know. A blank form holding the code.
    case newBarcode(String)
    /// A row already in the library.
    case existing(LocalFoodItem)
    /// One dish off a meal that was already logged, being kept.
    case fromMealItem(MealItemEntry)

    var id: String {
        switch self {
        case .new:                  return "new"
        case .draft(let d):         return "draft-\(d.externalID ?? d.barcode ?? d.name)"
        case .scannedDraft(let d):  return "scan-\(d.externalID ?? d.barcode ?? d.name)"
        case .newBarcode(let code): return "code-\(code)"
        case .existing(let item):   return item.clientUUID
        case .fromMealItem(let e):  return "meal-\(e.id.uuidString)"
        }
    }
}

/// Create, confirm or edit one saved food item (#625).
///
/// ### One form, six ways in
///
/// Typing a packet in by hand, confirming a database hit, confirming a scan,
/// keeping a dish off a meal and editing a row you already have are the same
/// screen, because they hold the same fields. Splitting them would mean five
/// forms that drift on which nutrient is behind the disclosure and what an
/// emptied brand does.
///
/// ### What this screen is for, now that imports do not come through it
///
/// Open Food Facts is crowd-sourced and writable by anyone. One of its entries
/// for a high-protein vanilla yogurt claims 52 kcal per 100 g, which is wrong,
/// and nothing downstream can tell that from a plausible number.
///
/// That used to make this form compulsory on every import. It is not any more:
/// `FoodItemPick.commit` writes a tapped hit directly, and the picker row
/// prints the figures before the tap instead (#625). What answers the bad
/// record now is this form being REACHABLE afterwards, from the picker's
/// per-row Edit. An item imported without eyes on it keeps `isVerified` false
/// until somebody opens it here and saves, which is the only thing that flag
/// has ever meant.
///
/// ### Why a save from here always claims verification
///
/// Every route into this form ends at a person looking at eight numbers and
/// pressing Save. A hand-typed row was read off the label; an edit was made
/// against it. There is no route that saves without a look, so there is no route
/// that should save the flag false. A row created without eyes on it, by an
/// import, by the assistant or by a peer, is what the false state is for.
struct FoodItemEditorSheet: View {

    let target: FoodItemEditorTarget

    /// The row as it stands after the write. The picker adds it to its tray, so
    /// a scan that started as "log this packet" does not end as "the packet is
    /// now saved, find it again".
    let onSaved: (LocalFoodItem) -> Void

    init(target: FoodItemEditorTarget, onSaved: @escaping (LocalFoodItem) -> Void) {
        self.target = target
        self.onSaved = onSaved
    }

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var brand: String = ""
    @State private var baseQuantity: String = "100"
    @State private var unit: FoodPortionUnit = .grams
    @State private var defaultPortion: String = "100"
    @State private var notes: String = ""
    @State private var barcode: String = ""

    /// The eight, as strings, AT the base portion. Text for the reason
    /// `MealNumberField` exists: a half-typed "1." is not a `Double`, and a
    /// formatted binding rewrites the field under the caret.
    @State private var values: [Nutrient: String] = [:]

    /// Which figures the source record did not state. Rendered beside those
    /// fields, because a zero that means "not stated" has to look different from
    /// a zero that means zero.
    @State private var missing: [Nutrient] = []

    /// The identity the outside world knows this product by, carried through
    /// from an import so a later re-import corrects this row instead of laying a
    /// second one beside it.
    @State private var externalSource: String?
    @State private var externalID: String?

    /// True when the base portion is a number the user still has to supply.
    ///
    /// Only `.fromMealItem` can set it: a logged dish states its portion in
    /// whatever words the estimate used, and "1.5 bowls" of a bowl is not a
    /// measurement. See `loadFromMealItem`.
    @State private var baseUnresolved = false
    /// The portion the meal item stated, for the sentence that asks for grams.
    @State private var unresolvedPortion: String = ""

    @State private var isArchived = false
    @State private var showingMinor = false
    @State private var unitPickerOpen = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var loaded = false

    private var items: FoodItemService { .default() }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.canvasIgnoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.lg) {
                            if let provenance { provenanceBlock(provenance) }
                            nameSection
                            portionSection
                            numbersSection
                            barcodeSection
                            notesSection
                            if case .existing = target { archiveSection }
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
            .navigationTitle(navigationTitle)
            .inlineNavigationTitle()
        }
        #if os(macOS)
        // A macOS sheet with no explicit size collapses to its toolbar (#474).
        // On a phone this minWidth is wider than the screen, so it stays out of
        // the iOS tree entirely.
        .frame(minWidth: 500, idealWidth: 560, minHeight: 620, idealHeight: 780)
        #endif
        .onAppear(perform: load)
        .confirmationDialog(
            "Delete this saved item?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteRow() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Meals you already logged from it keep their own numbers and are untouched.")
        }
    }

    private var navigationTitle: String {
        switch target {
        case .existing:                     return "Saved item"
        case .draft, .scannedDraft:         return "Check these numbers"
        case .fromMealItem:                 return "Keep this item"
        case .new, .newBarcode:             return "New item"
        }
    }

    // MARK: - Provenance

    /// One honest sentence about where the numbers on screen came from.
    ///
    /// It is a sentence rather than a badge because the point is not decoration:
    /// a database hit and a hand-typed label carry different amounts of trust,
    /// and the user is about to accept one of them on the app's behalf.
    private var provenance: String? {
        switch target {
        case .draft:
            return "These numbers came from Open Food Facts, which is public and crowd-sourced. Check them against the packet before you save."
        case .scannedDraft:
            return "Dexter read the barcode and found this in Open Food Facts, which is public and crowd-sourced. Check it against the packet before you save."
        case .newBarcode:
            return "Dexter read the barcode and the food database did not know it. Type what the packet says."
        case .fromMealItem:
            return "These numbers came from an estimate of a meal you logged, not from a packet. Correct anything you know better."
        case .new, .existing:
            return nil
        }
    }

    private func provenanceBlock(_ text: String) -> some View {
        Text(text)
            .font(.edFootnote)
            .foregroundStyle(Tokens.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
    }

    // MARK: - Name and brand

    private static let nameExample = "Greek style high protein yogurt"
    private static let brandExample = "Farmers Union"

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                Text("Name").eyebrow()
                TextField(PlainFieldPlaceholder.title(Self.nameExample), text: $name, axis: .vertical)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .paperFieldOnMac()
                    .padding(Space.md)
                    .plainFieldPlaceholder(Self.nameExample, isVisible: name.isEmpty, padding: Space.md)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .paperBorder(Tokens.border, radius: Radius.md)
            }

            VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                HStack(spacing: Space.sm) {
                    Text("Brand").eyebrow()
                    Spacer(minLength: 0)
                    Text("optional")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                }
                TextField(PlainFieldPlaceholder.title(Self.brandExample), text: $brand)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .textFieldStyle(.plain)
                    .paperFieldOnMac()
                    .padding(Space.md)
                    .plainFieldPlaceholder(Self.brandExample, isVisible: brand.isEmpty, padding: Space.md)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .paperBorder(Tokens.border, radius: Radius.md)
            }
        }
    }

    // MARK: - The portion

    /// The base portion, the unit, and the usual serving.
    ///
    /// ### Why the explanation is in the form
    ///
    /// The base portion is the one concept here a person can get wrong, and
    /// getting it wrong is silent: numbers written against 100 when they
    /// describe a 150 g pot inflate every future log of that item by half,
    /// forever, with nothing downstream able to question it. A tooltip would put
    /// the one sentence that prevents that behind a gesture nobody makes on a
    /// form they are filling in for the first time.
    private var portionSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("The portion these numbers describe").eyebrow()

            Text(baseUnresolved
                 ? "These numbers describe \(unresolvedPortion), and Dexter cannot scale that. State the same portion as a weight, and every log of this item scales from it."
                 : "The numbers below describe this much of it. A log of any other amount scales from it. Most labels print per 100, so that is the usual answer.")
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.sm) {
                Text("Base portion")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                Spacer(minLength: Space.sm)
                TextField(baseUnresolved ? "weight" : "100", text: $baseQuantity)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .decimalKeyboard()
                    .textFieldStyle(.plain)
                    .paperFieldOnMac()
                    .frame(width: 72)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 4)
                    .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .paperBorder(Tokens.border, radius: Radius.sm)
                    .accessibilityLabel("Base portion")
                unitPicker
            }

            MealNumberField(
                label: "Usual serving",
                unit: unit.rawValue,
                text: $defaultPortion
            )

            Text("How much of it you normally eat. The picker opens on this number, so the common case is one tap.")
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    /// Grams or millilitres, drawn out of the design system.
    ///
    /// Not a `Menu`, for the reason the composer's meal-type control is not one
    /// (#540): a system menu panel is the one surface the design system cannot
    /// reach, and it looks different again on the Mac.
    private var unitPicker: some View {
        Button {
            unitPickerOpen.toggle()
        } label: {
            HStack(spacing: Space.xs) {
                Text(unit.rawValue)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.muted)
            }
            .frame(width: 52)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.sm)
        .popover(isPresented: $unitPickerOpen, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ForEach(FoodPortionUnit.allCases) { option in
                    InlineDropdownRow(
                        glyph: .none,
                        label: option.displayName,
                        isSelected: unit == option,
                        accent: Tokens.accentMeals
                    ) {
                        unit = option
                        unitPickerOpen = false
                    }
                }
            }
            .padding(.vertical, Space.xs)
            .frame(width: 220)
            .background(Tokens.surface)
            .presentationBackground(Tokens.surface)
            // Without this an iPhone turns a popover into a full-screen sheet.
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Portion unit, \(unit.displayName)")
    }

    // MARK: - The eight

    /// Calories and the four macros on the surface, the other three behind a
    /// disclosure.
    ///
    /// The same split `MealPlanEntrySheet` makes, and for the same reason: the
    /// five are what a day is read against, and sugar, sodium and saturated fat
    /// are typed by hand roughly never. Putting all eight on the surface would
    /// make the common case scroll past three fields nobody filled.
    private var numbersSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text("Nutrition per \(baseLabel)").eyebrow()
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Self.keyNutrients) { nutrient in
                    numberRow(nutrient)
                }
            }

            Button {
                withAnimation(.easeOut(duration: 0.15)) { showingMinor.toggle() }
            } label: {
                HStack(spacing: Space.xs) {
                    Text(showingMinor ? "Fewer" : "Sugar, sodium and saturated fat")
                    Image(systemName: showingMinor ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))

            if showingMinor {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(Self.minorNutrients) { nutrient in
                        numberRow(nutrient)
                    }
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    /// One field, with a line under it when the source record said nothing.
    ///
    /// The caption sits beside the figure it is about rather than in a list at
    /// the top of the form, because the thing a user needs to know is which of
    /// these eight boxes is a real reading and which is a zero standing in for
    /// silence, and that question is asked one box at a time.
    private func numberRow(_ nutrient: Nutrient) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MealNumberField(
                label: nutrient.displayName,
                unit: nutrient.unit,
                text: Binding(
                    get: { values[nutrient] ?? "" },
                    set: { values[nutrient] = $0 }
                )
            )
            if missing.contains(nutrient) {
                Text("The database did not state this one.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let keyNutrients: [Nutrient] = [.calories] + Nutrient.macrosInOrder
    private static let minorNutrients: [Nutrient] = Nutrient.allCases.filter { !keyNutrients.contains($0) }

    /// "100 g", or just the unit while the amount is still being typed.
    private var baseLabel: String {
        let amount = MealItemDraft.number(baseQuantity)
        guard amount > 0 else { return unit.rawValue }
        return "\(MealItemDraft.string(amount)) \(unit.rawValue)"
    }

    // MARK: - Barcode

    private static let barcodeExample = "8 850 999 320 014"

    private var barcodeSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack(spacing: Space.sm) {
                Text("Barcode").eyebrow()
                Spacer(minLength: 0)
                Text("optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            TextField(PlainFieldPlaceholder.title(Self.barcodeExample), text: $barcode)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .textFieldStyle(.plain)
                .paperFieldOnMac()
                .noAutocapitalization()
                .autocorrectionDisabled(true)
                .padding(Space.md)
                .plainFieldPlaceholder(Self.barcodeExample, isVisible: barcode.isEmpty, padding: Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)
            Text("A scan of this packet finds the item straight away, with no lookup.")
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Note

    private static let notesExample = "Two pots in a pack"

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack(spacing: Space.sm) {
                Text("Note").eyebrow()
                Spacer(minLength: 0)
                Text("optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            TextField(PlainFieldPlaceholder.title(Self.notesExample), text: $notes, axis: .vertical)
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .paperFieldOnMac()
                .padding(Space.md)
                .plainFieldPlaceholder(Self.notesExample, isVisible: notes.isEmpty, padding: Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    // MARK: - Archive

    /// Retire the item without taking its numbers away.
    ///
    /// The other half of Delete. Something eaten for a year and stopped should
    /// leave the picker, but the meals logged from it are not the thing being
    /// retired and a delete would be a claim about them.
    private var archiveSection: some View {
        Button {
            isArchived.toggle()
        } label: {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: isArchived ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isArchived ? Tokens.accentMeals : Tokens.mutedSoft)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide it from the picker")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    Text("It keeps its numbers and stops showing up when you log a meal.")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.lg)
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide it from the picker")
        .accessibilityValue(isArchived ? "Hidden" : "Shown")
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)

            HStack(spacing: Space.sm) {
                if case .existing = target {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                        .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                }
                Spacer(minLength: Space.sm)
                Button("Cancel") { dismiss() }
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                Button(saveLabel) { save() }
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        }
        .background(Tokens.surface)
    }

    private var saveLabel: String {
        switch target {
        case .existing:              return "Save"
        case .draft, .scannedDraft:  return "Confirm and save"
        default:                     return "Save"
        }
    }

    /// The cheap half of validation, so the button says no before the service
    /// has to. The service still checks all five; this only stops a press that
    /// could not possibly succeed.
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && MealItemDraft.number(baseQuantity) > 0
    }

    // MARK: - Load

    private func load() {
        guard !loaded else { return }
        loaded = true
        for nutrient in Nutrient.allCases { values[nutrient] = "" }

        switch target {
        case .new:
            break

        case .newBarcode(let code):
            barcode = code

        case .draft(let draft), .scannedDraft(let draft):
            loadDraft(draft)

        case .existing(let item):
            loadExisting(item)

        case .fromMealItem(let entry):
            loadFromMealItem(entry)
        }
    }

    private func loadDraft(_ draft: FoodItemDraft) {
        name = draft.name
        brand = draft.brand ?? ""
        baseQuantity = MealItemDraft.string(draft.basePortionQuantity)
        unit = draft.basePortionUnit
        defaultPortion = MealItemDraft.string(draft.defaultPortionQuantity)
        barcode = draft.barcode ?? ""
        externalSource = draft.externalSource
        externalID = draft.externalID
        missing = draft.missingNutrients
        values[.calories]     = MealItemDraft.string(draft.calories)
        values[.protein]      = MealItemDraft.string(draft.proteinG)
        values[.carbs]        = MealItemDraft.string(draft.carbsG)
        values[.fat]          = MealItemDraft.string(draft.fatG)
        values[.fibre]        = MealItemDraft.string(draft.fibreG)
        values[.sugar]        = MealItemDraft.string(draft.sugarG)
        values[.sodium]       = MealItemDraft.string(draft.sodiumMg)
        values[.saturatedFat] = MealItemDraft.string(draft.satFatG)
        // A record that left figures out has them behind the disclosure as often
        // as in front of it, and a caption nobody scrolls to says nothing.
        if missing.contains(where: Self.minorNutrients.contains) { showingMinor = true }
    }

    private func loadExisting(_ item: LocalFoodItem) {
        name = item.name
        brand = item.brand ?? ""
        baseQuantity = MealItemDraft.string(item.basePortionQuantity)
        unit = item.unit
        defaultPortion = MealItemDraft.string(item.defaultPortionQuantity)
        barcode = item.barcode ?? ""
        notes = item.notes ?? ""
        externalSource = item.externalSource
        externalID = item.externalID
        isArchived = item.isArchived
        // Read off the eight columns rather than through the service's own
        // `nutrientsAtBase`, which is private to that file. Eight assignments
        // rather than a loop for the reason `applyNutrients` gives: a SwiftData
        // model cannot be keyed into, and a missed field here would be a wrong
        // number rather than a compile error.
        values[.calories]     = MealItemDraft.string(item.calories)
        values[.protein]      = MealItemDraft.string(item.proteinG)
        values[.carbs]        = MealItemDraft.string(item.carbsG)
        values[.fat]          = MealItemDraft.string(item.fatG)
        values[.fibre]        = MealItemDraft.string(item.fibreG)
        values[.sugar]        = MealItemDraft.string(item.sugarG)
        values[.sodium]       = MealItemDraft.string(item.sodiumMg)
        values[.saturatedFat] = MealItemDraft.string(item.satFatG)
    }

    /// One dish off a logged meal, which is the one entry point whose portion
    /// may not be a measurement at all.
    ///
    /// ### Why an unscalable unit is asked about rather than converted
    ///
    /// `MealItemEntry.portionUnit` is free text on purpose: an estimate says
    /// "bowl", "slice", "cup". A library row cannot be, because everything
    /// logged from it scales by a ratio and 1.5 bowls of a bowl is not a
    /// measurement. `FoodItemService.saveFromMealItem` throws
    /// `unknownPortionUnit` on exactly that, and the honest answer is to ask
    /// for the weight rather than to guess one. Guessing is how a row lands
    /// wrong by a factor of 28 and stays wrong on every meal logged from it.
    ///
    /// ### Why the test here is narrower than the service's
    ///
    /// The service's normaliser is private to it, and it accepts a handful of
    /// spellings ("gram", "gms") beyond the two raw values. This asks only
    /// whether the unit IS one of the two. A second copy of that vocabulary in
    /// a view is exactly the drift that puts two answers in the codebase, and
    /// being narrower is safe in one direction only: the worst case is that a
    /// legacy row spelled "grams" asks the user to restate 150 as 150, with the
    /// portion named in the sentence above the field.
    private func loadFromMealItem(_ entry: MealItemEntry) {
        name = entry.name
        values[.calories]     = MealItemDraft.string(entry.calories)
        values[.protein]      = MealItemDraft.string(entry.proteinG)
        values[.carbs]        = MealItemDraft.string(entry.carbsG)
        values[.fat]          = MealItemDraft.string(entry.fatG)
        values[.fibre]        = MealItemDraft.string(entry.fibreG)
        values[.sugar]        = MealItemDraft.string(entry.sugarG)
        values[.sodium]       = MealItemDraft.string(entry.sodiumMg)
        values[.saturatedFat] = MealItemDraft.string(entry.satFatG)

        let raw = entry.portionUnit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let resolved = FoodPortionUnit(rawValue: raw), entry.portionQuantity > 0 {
            unit = resolved
            baseQuantity = MealItemDraft.string(entry.portionQuantity)
            defaultPortion = MealItemDraft.string(entry.portionQuantity)
        } else {
            baseUnresolved = true
            unresolvedPortion = entry.portionDescription
            unit = .grams
            // Empty, not a guess. There is no honest number to put here, and a
            // prefilled 100 would be accepted by a user who assumed the app
            // knew something it does not.
            baseQuantity = ""
            defaultPortion = ""
        }
    }

    // MARK: - Save

    /// Write the form, then hand the row back.
    ///
    /// ### Which service call, and why it is decided by the barcode
    ///
    /// A row with a barcode or a database id has an identity the OUTSIDE world
    /// knows, and `upsert` matches on that, so a second scan of the same packet
    /// corrects this row instead of laying a duplicate beside it. Two rows for
    /// one yogurt make every later choice in the picker a coin toss. A row with
    /// neither identity has nothing to match on, so it is a plain create and
    /// "boiled egg" typed twice on purpose stays two rows.
    ///
    /// ### Why every optional string is always sent
    ///
    /// `nil` means "leave it alone" and `""` means "clear it", both in
    /// `updateItem` and in `FoodItemWrite`. This form always knows the state of
    /// its own boxes, so "leave it alone" is never what it means. Collapsing an
    /// emptied brand to nil is the #444 and #488 mistake: it makes a deletion
    /// and an untouched field the same request, and untouched always wins.
    private func save() {
        errorMessage = nil
        let base = MealItemDraft.number(baseQuantity)
        // The usual serving falls back to the base portion rather than to a
        // constant: a user who stated the base and left this blank meant "the
        // whole thing", and 100 would be a number nobody typed.
        let usual = MealItemDraft.number(defaultPortion) > 0
            ? MealItemDraft.number(defaultPortion)
            : base

        var nutrients = MealNutrients.zero
        for nutrient in Nutrient.allCases {
            nutrients[nutrient] = MealItemDraft.number(values[nutrient] ?? "")
        }

        do {
            let row: LocalFoodItem
            switch target {
            case .existing(let item):
                try items.updateItem(
                    item,
                    name: name,
                    brand: brand,
                    basePortionQuantity: base,
                    basePortionUnit: unit.rawValue,
                    nutrients: nutrients,
                    defaultPortionQuantity: usual,
                    barcode: barcode,
                    // An edit is a look at the numbers, so the flag goes true
                    // here as it does on a create. See the note on the type.
                    isVerified: true,
                    notes: notes,
                    isArchived: isArchived
                )
                row = item

            default:
                row = try write(base: base, usual: usual, nutrients: nutrients)
            }
            onSaved(row)
            dismiss()
        } catch {
            // The sheet stays open. A failed save that dismissed would take the
            // user's typing with it, and the error is usually one field.
            errorMessage = error.localizedDescription
        }
    }

    private func write(base: Double, usual: Double, nutrients: MealNutrients) throws -> LocalFoodItem {
        let trimmedBarcode = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOutsideIdentity = !trimmedBarcode.isEmpty || externalID != nil

        if hasOutsideIdentity {
            return try items.upsert(
                FoodItemWrite(
                    name: name,
                    brand: brand,
                    basePortionQuantity: base,
                    basePortionUnit: unit.rawValue,
                    nutrients: nutrients,
                    defaultPortionQuantity: usual,
                    barcode: barcode,
                    externalSource: externalSource ?? "",
                    externalID: externalID ?? "",
                    source: sourceConstant,
                    isVerified: true,
                    notes: notes
                )
            )
        }

        return try items.createItem(
            name: name,
            brand: brand,
            basePortionQuantity: base,
            basePortionUnit: unit.rawValue,
            nutrients: nutrients,
            defaultPortionQuantity: usual,
            barcode: barcode,
            externalSource: externalSource,
            externalID: externalID,
            source: sourceConstant,
            isVerified: true,
            notes: notes
        )
    }

    /// How the row entered the library. Provenance, not content: it says which
    /// door was used, and a caption reads it back.
    private var sourceConstant: String {
        switch target {
        case .new:                      return FoodItemSource.manual
        case .draft:                    return FoodItemSource.openFoodFacts
        case .scannedDraft, .newBarcode: return FoodItemSource.barcode
        case .fromMealItem:             return FoodItemSource.meal
        case .existing(let item):       return item.source
        }
    }

    private func deleteRow() {
        guard case .existing(let item) = target else { return }
        do {
            try items.deleteItem(item)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
