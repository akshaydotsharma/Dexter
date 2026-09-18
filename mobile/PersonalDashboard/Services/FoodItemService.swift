import Foundation
import SwiftData

/// Errors thrown by `FoodItemService` (#625).
///
/// Shaped like `MealServiceError`: a `LocalizedError` whose non-storage cases
/// are mostly programming bugs, so UI rarely branches on them. Two of them are
/// NOT bugs and a caller does have to handle them — `emptyName`, which the item
/// editor surfaces under the name field, and `unknownPortionUnit`, which is the
/// honest answer when "save this as an item" is pressed on a dish the estimate
/// measured in bowls. See `saveFromMealItem`.
enum FoodItemServiceError: LocalizedError {
    case emptyName
    case invalidBasePortion
    case invalidDefaultPortion
    case invalidNutrients
    case unknownPortionUnit(String)
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "A food item needs a name."
        case .invalidBasePortion:
            return "The base portion must be more than zero."
        case .invalidDefaultPortion:
            return "The usual portion must be more than zero."
        case .invalidNutrients:
            return "Nutrient values cannot be negative."
        case .unknownPortionUnit(let unit):
            return "\"\(unit)\" is not a portion unit a saved item can scale. Use grams (g) or millilitres (ml)."
        case .persistence(let err):
            return err.localizedDescription
        }
    }
}

/// Everything needed to write one library row, as one value (#625).
///
/// This exists so the import path has a single argument instead of fourteen,
/// and so a new field is added in one place rather than at every call site. It
/// is deliberately a PLAIN struct declared here, with no knowledge of any
/// public food database: an Open Food Facts client maps its own response onto
/// this, and this file never learns what Open Food Facts is. That keeps the
/// dependency pointing one way, and it keeps this service testable with a
/// literal.
///
/// ### nil is not the same as empty, on every optional here
///
/// For the four optional strings, `nil` means "this source did not supply one",
/// so an upsert that carries nil LEAVES the stored value alone. An empty string
/// means "there is none", so it CLEARS. That is the same contract `updateItem`
/// documents below, and it is the #444 / #488 lesson: collapsing an emptied
/// field to nil makes a deletion and an untouched field the same request, and
/// untouched always wins.
struct FoodItemWrite {

    /// The product without its maker. Required, and rejected when it trims to
    /// nothing.
    var name: String

    /// The maker, or nil when the source did not say. See the note above.
    var brand: String? = nil

    /// What the nutrients below describe. Normally 100, because that is how a
    /// label prints and how every public database returns it.
    var basePortionQuantity: Double = 100

    /// `g` or `ml`. Validated against `FoodPortionUnit`, so a source that
    /// returns something else is refused rather than stored as a unit nothing
    /// can scale.
    var basePortionUnit: String = FoodPortionUnit.grams.rawValue

    /// The eight, AT `basePortionQuantity`.
    ///
    /// ⚠️ Sodium is in MILLIGRAMS here, as it is on `LocalMeal` and
    /// `LocalFoodItem`. Open Food Facts returns `sodium_100g` in grams, so an
    /// importer multiplies by 1,000 before it gets here. Nothing in this file
    /// can detect a missed conversion: 1.2 g and 1.2 mg are both plausible
    /// numbers.
    var nutrients: MealNutrients = .zero

    /// How much of it you normally eat. nil means "the source did not say",
    /// which keeps an existing row's number and falls back to the base portion
    /// on a new row. A refresh must not quietly reset a portion the user tuned.
    var defaultPortionQuantity: Double? = nil

    /// EAN or UPC. One of the two identities an upsert matches on.
    var barcode: String? = nil

    /// Which public database this came from, e.g. `FoodItemSource.openFoodFacts`.
    var externalSource: String? = nil

    /// That database's own product id. The other identity an upsert matches on,
    /// and the stronger of the two.
    var externalID: String? = nil

    /// How the row entered the library. A `FoodItemSource` constant.
    var source: String = FoodItemSource.manual

    /// Whether the numbers have been read against the packet. An importer
    /// passes false; a confirm step passes true.
    var isVerified: Bool = false

    /// Anything the eight columns cannot hold.
    var notes: String? = nil
}

/// CRUD over `LocalFoodItem`, the library of items you keep so you never have
/// to describe them again (#625). Operates on the shared SwiftData context.
///
/// ### Why this service refuses things `MealService` does not
///
/// A meal is an estimate and the numbers on it are allowed to be rough. A row
/// here is a FACT the user accepted, and everything logged from it copies those
/// numbers verbatim with no model call in between. So the validation is
/// stricter by design: a zero base portion would make `nutrients(for:)` return
/// zeroes for every log forever, and a unit outside `FoodPortionUnit` would
/// make the scaling ratio meaningless. Both are cheap to refuse here and
/// impossible to notice downstream.
///
/// ### Identity, and the three ways a row is found again
///
/// `clientUUID` is the row. `externalID` (with `externalSource`) and `barcode`
/// are the two ways the OUTSIDE world names the same product, and `upsert`
/// matches on them so a re-import corrects the row it already wrote instead of
/// laying a second one beside it. See the note on `upsert` for why that matters
/// more here than it looks.
@MainActor
struct FoodItemService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    static func `default`() -> FoodItemService {
        FoodItemService(store: .shared)
    }

    // MARK: - Write

    /// Insert a new item, or rewrite the one an explicit `clientUUID` already
    /// names.
    ///
    /// The upsert-on-id behaviour mirrors `MealService.addMeal`, and it is not
    /// optional here. `LocalFoodItem.clientUUID` is `@Attribute(.unique)`, and
    /// inserting a second object carrying an id already in the store REPLACES
    /// the row rather than erroring — that is #514, where a retried save
    /// silently dropped everything the first save had written. Looking the row
    /// up first is what makes a supplied id a RETRY of one create instead of a
    /// destructive second one.
    ///
    /// A caller that passes NO id keeps insert-only behaviour, so adding "boiled
    /// egg" twice on purpose stays two rows.
    ///
    /// `createdAt` stays at the first attempt. `useCount` and `lastUsedAt` are
    /// never touched here: they are this device's history with the item, not
    /// part of what a create states.
    @discardableResult
    func createItem(
        name: String,
        brand: String? = nil,
        basePortionQuantity: Double = 100,
        basePortionUnit: String = FoodPortionUnit.grams.rawValue,
        nutrients: MealNutrients = .zero,
        defaultPortionQuantity: Double = 100,
        barcode: String? = nil,
        externalSource: String? = nil,
        externalID: String? = nil,
        source: String = FoodItemSource.manual,
        isVerified: Bool = false,
        notes: String? = nil,
        clientUUID: String? = nil
    ) throws -> LocalFoodItem {
        let checked = try validate(
            name: name,
            basePortionQuantity: basePortionQuantity,
            basePortionUnit: basePortionUnit,
            defaultPortionQuantity: defaultPortionQuantity,
            nutrients: nutrients
        )

        if let clientUUID, let existing = try item(clientUUID: clientUUID) {
            existing.name                   = checked.name
            existing.brand                  = brand?.trimmedNonEmptyFoodField
            existing.basePortionQuantity    = basePortionQuantity
            existing.basePortionUnit        = checked.unit
            existing.applyNutrients(nutrients)
            existing.defaultPortionQuantity = defaultPortionQuantity
            existing.barcode                = barcode?.trimmedNonEmptyFoodField
            existing.externalSource         = externalSource?.trimmedNonEmptyFoodField
            existing.externalID             = externalID?.trimmedNonEmptyFoodField
            existing.source                 = source
            existing.isVerified             = isVerified
            existing.notes                  = notes?.trimmedNonEmptyFoodField
            existing.updatedAt              = Date()
            try save()
            return existing
        }

        let row = LocalFoodItem(
            clientUUID: clientUUID ?? UUID().uuidString.lowercased(),
            name: checked.name,
            brand: brand?.trimmedNonEmptyFoodField,
            basePortionQuantity: basePortionQuantity,
            basePortionUnit: checked.unit,
            calories: nutrients.calories,
            proteinG: nutrients.proteinG,
            carbsG: nutrients.carbsG,
            fatG: nutrients.fatG,
            fibreG: nutrients.fibreG,
            sugarG: nutrients.sugarG,
            sodiumMg: nutrients.sodiumMg,
            satFatG: nutrients.satFatG,
            defaultPortionQuantity: defaultPortionQuantity,
            barcode: barcode?.trimmedNonEmptyFoodField,
            externalSource: externalSource?.trimmedNonEmptyFoodField,
            externalID: externalID?.trimmedNonEmptyFoodField,
            source: source,
            isVerified: isVerified,
            notes: notes?.trimmedNonEmptyFoodField
        )
        store.context.insert(row)
        try save()
        return row
    }

    /// Update an item in place. Every parameter is optional and nil means
    /// "leave this field alone".
    ///
    /// ### The two clearable text fields
    ///
    /// `brand` and `notes` are the fields a user can legitimately empty, and
    /// they are the ones #444 and #488 got wrong twice. The contract here is
    /// the #488 fix, not the #444 one: pass **nil to leave the field unchanged**
    /// and **an empty string to clear it to nil**. So an editor binds a
    /// `String` and always sends it, including as `""`, rather than collapsing
    /// its own empty box to nil — which is exactly the mistake that makes a
    /// deletion indistinguishable from an untouched field, with untouched
    /// always winning.
    ///
    /// The row keeps ONE representation of empty: `""` is normalised back to
    /// nil on the way in, so a consumer that only unwraps the optional cannot
    /// render a blank brand line or an empty pill.
    ///
    /// `barcode`, `externalSource` and `externalID` take the same treatment,
    /// for a harder reason than tidiness: an empty-string barcode is not a
    /// barcode, and storing one would make `item(barcode:)` match a row against
    /// a query nobody meant.
    ///
    /// `isVerified` and `isArchived` are plain `Bool?` rather than the double
    /// optional, and that is safe for the reason `LocalMeal.containsAlcohol`
    /// gives: a toggle always knows its own state, so it passes `false` rather
    /// than nil, and "set it false" stays a different request from "leave it".
    func updateItem(
        _ item: LocalFoodItem,
        name: String? = nil,
        brand: String? = nil,
        basePortionQuantity: Double? = nil,
        basePortionUnit: String? = nil,
        nutrients: MealNutrients? = nil,
        defaultPortionQuantity: Double? = nil,
        barcode: String? = nil,
        externalSource: String? = nil,
        externalID: String? = nil,
        source: String? = nil,
        isVerified: Bool? = nil,
        notes: String? = nil,
        isArchived: Bool? = nil
    ) throws {
        // Validate against the row as it WOULD be, not as it is, so a call that
        // moves two fields at once cannot be judged against a half-applied
        // state. Nothing is written until all five checks pass.
        let checked = try validate(
            name: name ?? item.name,
            basePortionQuantity: basePortionQuantity ?? item.basePortionQuantity,
            basePortionUnit: basePortionUnit ?? item.basePortionUnit,
            defaultPortionQuantity: defaultPortionQuantity ?? item.defaultPortionQuantity,
            nutrients: nutrients ?? item.nutrientsAtBase
        )

        if name != nil {
            item.name = checked.name
        }
        // nil leaves it; "" clears it. See the doc comment.
        if let brand {
            item.brand = brand.trimmedNonEmptyFoodField
        }
        if let basePortionQuantity {
            item.basePortionQuantity = basePortionQuantity
        }
        if basePortionUnit != nil {
            item.basePortionUnit = checked.unit
        }
        if let nutrients {
            item.applyNutrients(nutrients)
        }
        if let defaultPortionQuantity {
            item.defaultPortionQuantity = defaultPortionQuantity
        }
        if let barcode {
            item.barcode = barcode.trimmedNonEmptyFoodField
        }
        if let externalSource {
            item.externalSource = externalSource.trimmedNonEmptyFoodField
        }
        if let externalID {
            item.externalID = externalID.trimmedNonEmptyFoodField
        }
        if let source {
            item.source = source
        }
        if let isVerified {
            item.isVerified = isVerified
        }
        // nil leaves it; "" clears it. See the doc comment.
        if let notes {
            item.notes = notes.trimmedNonEmptyFoodField
        }
        if let isArchived {
            item.isArchived = isArchived
        }
        item.updatedAt = Date()
        try save()
    }

    /// Remove the row. The honest action for something typed by mistake.
    ///
    /// Meals already logged from it are untouched, because they carry their own
    /// copy of the eight and never point back here. That is the whole reason
    /// `LocalFoodItem.mealItem(quantity:)` returns a plain value type.
    func deleteItem(_ item: LocalFoodItem) throws {
        store.context.delete(item)
        try save()
    }

    /// Hide the item from the picker without removing it.
    ///
    /// The other half of `deleteItem`: something you ate for a year and stopped
    /// should leave the picker, but its numbers have to stay readable, and a
    /// delete would take them.
    func setArchived(_ item: LocalFoodItem, on isArchived: Bool) throws {
        item.isArchived = isArchived
        item.updatedAt = Date()
        try save()
    }

    /// Bump the use counters after an item has actually been logged.
    ///
    /// Separate from the write that logs the meal, and called by it, because
    /// the counters are ordering data for the picker rather than part of what
    /// the item IS. Keeping them apart means a preview, an edit or a sync of
    /// this row does not pretend the item was eaten.
    ///
    /// `updatedAt` moves too, deliberately. The sync diff compares a record's
    /// CONTENT hash, so a counter that changed without `updatedAt` moving would
    /// still be broadcast; moving it keeps this row's last-write-wins ordering
    /// honest against a peer editing the same item.
    func recordUse(_ item: LocalFoodItem) throws {
        item.useCount += 1
        item.lastUsedAt = Date()
        item.updatedAt = Date()
        try save()
    }

    // MARK: - Fetch

    /// The whole library, ordered the way the picker reads it: most used first,
    /// then most recently used, then by name.
    ///
    /// Archived rows are left out unless asked for, because the picker is the
    /// only caller that matters and a retired item in it is noise.
    ///
    /// Sorted in memory rather than by a `FetchDescriptor`, for two reasons.
    /// `lastUsedAt` is optional and the store's ordering of nulls is not a
    /// contract this code should depend on; and the name tiebreak has to be
    /// case-insensitive, which a `SortDescriptor` on a raw `String` is not.
    /// This is a personal-scale table, the same call `MealService.meals(on:)`
    /// makes about filtering.
    func allItems(includeArchived: Bool = false) throws -> [LocalFoodItem] {
        let rows = try store.context.fetch(FetchDescriptor<LocalFoodItem>())
        return Self.ranked(includeArchived ? rows : rows.filter { !$0.isArchived })
    }

    /// The items answering a typed query, in the same order as `allItems()`.
    ///
    /// Matching goes through `LocalFoodItem.matches(query:)` so the rule lives
    /// with the haystack it reads, and a barcode pasted into the search box
    /// finds its row. An empty query is every item rather than none: the picker
    /// opens with the box empty and must show the library, not a blank.
    func items(matching query: String, includeArchived: Bool = false) throws -> [LocalFoodItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try allItems(includeArchived: includeArchived)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.matches(query: trimmed) }
    }

    /// The row a `clientUUID` names, or nil.
    ///
    /// Archived rows are INCLUDED here and in the two lookups below. All three
    /// answer "is this exact thing already in the store", and an archived row
    /// still is: treating it as absent would let a re-import insert a duplicate
    /// of something the user only retired.
    func item(clientUUID: String) throws -> LocalFoodItem? {
        let descriptor = FetchDescriptor<LocalFoodItem>(
            predicate: #Predicate { $0.clientUUID == clientUUID }
        )
        return try store.context.fetch(descriptor).first
    }

    /// The row carrying a barcode, or nil. A second scan of the same packet
    /// lands here and skips the network entirely.
    func item(barcode: String) throws -> LocalFoodItem? {
        guard let needle = barcode.trimmedNonEmptyFoodField else { return nil }
        let descriptor = FetchDescriptor<LocalFoodItem>(
            predicate: #Predicate { $0.barcode == needle }
        )
        return try store.context.fetch(descriptor).first
    }

    /// The row a public database's own product id names, or nil.
    ///
    /// `source` narrows it when supplied, because two databases can hand out
    /// the same id string for different products and an unqualified match would
    /// overwrite one with the other. Passing nil matches on the id alone, which
    /// is what a caller with only a code in hand can do.
    func item(externalID: String, source: String? = nil) throws -> LocalFoodItem? {
        guard let needle = externalID.trimmedNonEmptyFoodField else { return nil }
        let descriptor = FetchDescriptor<LocalFoodItem>(
            predicate: #Predicate { $0.externalID == needle }
        )
        let rows = try store.context.fetch(descriptor)
        guard let source = source?.trimmedNonEmptyFoodField else { return rows.first }
        return rows.first { $0.externalSource == source }
    }

    // MARK: - The two derived entry points

    /// Turn one dish off a meal that is already logged into a library row.
    ///
    /// ### The base portion is the entry's own quantity, not 100
    ///
    /// This is the one thing here that is easy to get backwards. The eight
    /// numbers on a `MealItemEntry` describe `portionQuantity` of
    /// `portionUnit` — 150 g of yogurt, not 100 g of it. Writing them onto a
    /// row whose base says 100 would inflate or deflate every future log of
    /// that item by the ratio between the two, silently and forever. So the
    /// base portion IS `entry.portionQuantity`, and the default portion is the
    /// same number: what you ate last time is the best guess at what you will
    /// eat next time.
    ///
    /// A non-positive quantity is refused rather than coerced to 100, because
    /// there is no honest reading of "these numbers describe zero grams".
    ///
    /// ### Units, and why a bowl cannot be saved
    ///
    /// `MealItemEntry.portionUnit` is free text on purpose: an estimate says
    /// "bowl", "slice", "cup". A library row cannot be, because everything
    /// logged from it scales by a ratio and "1.5 bowls" of a bowl is not a
    /// measurement. Common spellings of grams and millilitres are normalised;
    /// anything else throws `unknownPortionUnit`, which the UI should surface
    /// as "re-state this in grams" rather than swallow.
    ///
    /// `isVerified` is false. The numbers came from an estimate, not from a
    /// packet, and the flag means the user has read them against the label.
    @discardableResult
    func saveFromMealItem(_ entry: MealItemEntry, brand: String? = nil) throws -> LocalFoodItem {
        guard entry.portionQuantity > 0 else { throw FoodItemServiceError.invalidBasePortion }
        let unit = try Self.normalisedUnit(entry.portionUnit)

        return try createItem(
            name: entry.name,
            brand: brand,
            basePortionQuantity: entry.portionQuantity,
            basePortionUnit: unit,
            nutrients: MealNutrients(
                calories: entry.calories,
                proteinG: entry.proteinG,
                carbsG: entry.carbsG,
                fatG: entry.fatG,
                fibreG: entry.fibreG,
                sugarG: entry.sugarG,
                sodiumMg: entry.sodiumMg,
                satFatG: entry.satFatG
            ),
            defaultPortionQuantity: entry.portionQuantity,
            source: FoodItemSource.meal,
            isVerified: false
        )
    }

    /// Write a row against its OUTSIDE identity: update the one an
    /// `externalID` or a `barcode` already names, or insert a new one.
    ///
    /// This is the entry point an import calls. It exists because the identity
    /// that matters to an importer is the product's, not this store's: a second
    /// scan of the same packet, or a refresh of the same database record, has
    /// no `clientUUID` to offer and would otherwise lay a duplicate beside the
    /// row it meant to correct. The library is a picker, and two rows for one
    /// yogurt make every choice in it a coin toss.
    ///
    /// Matching order is `externalID` (narrowed by `externalSource`) then
    /// `barcode`, strongest identity first. A write carrying neither always
    /// inserts.
    ///
    /// ### What an update deliberately does NOT overwrite
    ///
    /// - `useCount`, `lastUsedAt`, `createdAt`, `isArchived`: this device's
    ///   history with the item. A refresh of the numbers is not a statement
    ///   about any of them.
    /// - `isVerified`, once true. A user who read the packet and accepted the
    ///   row has said something no importer can un-say, and silently dropping
    ///   the badge would make the picker under-report what is trustworthy. An
    ///   import CAN set it true; it cannot set it back to false.
    /// - Any optional string the write left nil, and `defaultPortionQuantity`
    ///   when nil. Per `FoodItemWrite`, nil is "the source did not say", so the
    ///   stored value stands. An empty string is "there is none" and clears.
    @discardableResult
    func upsert(_ write: FoodItemWrite) throws -> LocalFoodItem {
        let existing = try matchingRow(for: write)

        // Resolve first, validate second: a nil `defaultPortionQuantity` has to
        // become a real number before it can be judged, and on a new row that
        // number is the base portion rather than a hard 100 — a row whose label
        // prints per 30 g should not open the picker at 100 g of it.
        let resolvedDefault = write.defaultPortionQuantity
            ?? existing?.defaultPortionQuantity
            ?? write.basePortionQuantity

        let checked = try validate(
            name: write.name,
            basePortionQuantity: write.basePortionQuantity,
            basePortionUnit: write.basePortionUnit,
            defaultPortionQuantity: resolvedDefault,
            nutrients: write.nutrients
        )

        guard let row = existing else {
            return try createItem(
                name: checked.name,
                brand: write.brand,
                basePortionQuantity: write.basePortionQuantity,
                basePortionUnit: checked.unit,
                nutrients: write.nutrients,
                defaultPortionQuantity: resolvedDefault,
                barcode: write.barcode,
                externalSource: write.externalSource,
                externalID: write.externalID,
                source: write.source,
                isVerified: write.isVerified,
                notes: write.notes
            )
        }

        row.name                   = checked.name
        row.brand                  = resolve(write.brand, keeping: row.brand)
        row.basePortionQuantity    = write.basePortionQuantity
        row.basePortionUnit        = checked.unit
        row.applyNutrients(write.nutrients)
        row.defaultPortionQuantity = resolvedDefault
        row.barcode                = resolve(write.barcode, keeping: row.barcode)
        row.externalSource         = resolve(write.externalSource, keeping: row.externalSource)
        row.externalID             = resolve(write.externalID, keeping: row.externalID)
        row.source                 = write.source
        row.isVerified             = row.isVerified || write.isVerified
        row.notes                  = resolve(write.notes, keeping: row.notes)
        row.updatedAt              = Date()
        try save()
        return row
    }

    // MARK: - Helpers

    /// The row a write is about, or nil for an insert. Strongest identity first.
    private func matchingRow(for write: FoodItemWrite) throws -> LocalFoodItem? {
        if let externalID = write.externalID?.trimmedNonEmptyFoodField,
           let hit = try item(externalID: externalID, source: write.externalSource) {
            return hit
        }
        if let barcode = write.barcode?.trimmedNonEmptyFoodField,
           let hit = try item(barcode: barcode) {
            return hit
        }
        return nil
    }

    /// The five checks, in one place, so `createItem`, `updateItem` and
    /// `upsert` cannot drift apart on what a valid row is.
    ///
    /// Returns the trimmed name and the canonical unit, so a caller writes what
    /// was validated rather than what was passed. Handing back the cleaned
    /// values instead of just throwing is what stops "  Yogurt " reaching the
    /// store past a check that already trimmed it to look at it.
    private func validate(
        name: String,
        basePortionQuantity: Double,
        basePortionUnit: String,
        defaultPortionQuantity: Double,
        nutrients: MealNutrients
    ) throws -> (name: String, unit: String) {
        guard let trimmedName = name.trimmedNonEmptyFoodField else {
            throw FoodItemServiceError.emptyName
        }
        guard basePortionQuantity > 0 else { throw FoodItemServiceError.invalidBasePortion }
        guard defaultPortionQuantity > 0 else { throw FoodItemServiceError.invalidDefaultPortion }
        guard !nutrients.hasNegativeValue else { throw FoodItemServiceError.invalidNutrients }
        guard let unit = FoodPortionUnit(rawValue: basePortionUnit) else {
            throw FoodItemServiceError.unknownPortionUnit(basePortionUnit)
        }
        return (trimmedName, unit.rawValue)
    }

    /// nil keeps what is stored, an empty string clears it, anything else sets
    /// the trimmed value. The one implementation of the contract `updateItem`
    /// and `FoodItemWrite` both document.
    private func resolve(_ incoming: String?, keeping current: String?) -> String? {
        guard let incoming else { return current }
        return incoming.trimmedNonEmptyFoodField
    }

    /// Most used, then most recently used, then by name.
    ///
    /// `lastUsedAt` is nil for an item never logged, and `.distantPast` is the
    /// right reading of that: never used sorts below used once. The name
    /// tiebreak is case-insensitive so the list does not put every capitalised
    /// brand above every lowercase one.
    private static func ranked(_ rows: [LocalFoodItem]) -> [LocalFoodItem] {
        rows.sorted { lhs, rhs in
            if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
            let lhsUsed = lhs.lastUsedAt ?? .distantPast
            let rhsUsed = rhs.lastUsedAt ?? .distantPast
            if lhsUsed != rhsUsed { return lhsUsed > rhsUsed }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// A meal item's free-text unit, mapped onto the two a library row can
    /// scale, or a throw.
    ///
    /// The spellings listed are the ones the estimate and the public databases
    /// actually emit. Deliberately NOT a fuzzy match: guessing that "oz" is
    /// close enough to grams would write a row wrong by a factor of 28, and a
    /// wrong number here is copied onto every meal logged from it.
    private static func normalisedUnit(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "g", "gm", "gms", "gram", "grams":
            return FoodPortionUnit.grams.rawValue
        case "ml", "milliliter", "millilitre", "milliliters", "millilitres":
            return FoodPortionUnit.millilitres.rawValue
        default:
            throw FoodItemServiceError.unknownPortionUnit(raw)
        }
    }

    private func save() throws {
        do {
            try store.context.save()
        } catch {
            throw FoodItemServiceError.persistence(error)
        }
    }
}

// MARK: - Model-side conveniences this service owns

private extension LocalFoodItem {

    /// The eight stored columns as one value. The inverse of `applyNutrients`,
    /// and only needed so `updateItem` can validate the row as it would be
    /// rather than as it is.
    var nutrientsAtBase: MealNutrients {
        MealNutrients(
            calories: calories,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            fibreG: fibreG,
            sugarG: sugarG,
            sodiumMg: sodiumMg,
            satFatG: satFatG
        )
    }

    /// Copy the eight onto the row.
    ///
    /// Written as eight assignments rather than a loop over `Nutrient.allCases`
    /// because a SwiftData model cannot be keyed into by a subscript, and
    /// because a missed field here is a wrong number forever rather than a
    /// compile error. Kept private to this file: nothing outside the service
    /// should be able to move these without going past the validation.
    func applyNutrients(_ n: MealNutrients) {
        calories = n.calories
        proteinG = n.proteinG
        carbsG   = n.carbsG
        fatG     = n.fatG
        fibreG   = n.fibreG
        sugarG   = n.sugarG
        sodiumMg = n.sodiumMg
        satFatG  = n.satFatG
    }
}

private extension String {
    /// Trim whitespace, return nil for empty.
    ///
    /// Named apart from `MealService`'s `trimmedNonEmptyMealField` and
    /// `ExpenseService`'s `trimmedNonEmpty` for the reason those two are named
    /// apart from each other: they are file-private extensions on `String` in
    /// one module, and three identical names would be ambiguous to nobody but a
    /// reader.
    var trimmedNonEmptyFoodField: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
