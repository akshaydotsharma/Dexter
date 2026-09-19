import Foundation
import SwiftData

/// One item you keep, so you never have to describe it again (#625).
///
/// A brand-new `@Model`, which is the safe kind of SwiftData migration: it
/// creates one table and touches none of the models beside it.
///
/// ### Why a library exists at all
///
/// Every meal before this one arrived the same way: a description, an estimate,
/// eight numbers frozen onto the row. That is the right shape for "chicken rice
/// and a teh tarik", where nobody knows the numbers and a model's guess is the
/// best answer available.
///
/// It is the wrong shape for a packet. A Farmers Union 150 g pot and a Superyou
/// wafer both carry exact printed nutrition, and re-estimating them costs a
/// network round trip and returns a slightly different answer every time. Two
/// logs of one pot then disagree, and a week's protein total is the sum of that
/// disagreement.
///
/// So a row here is a FACT the user has accepted, not an estimate. Logging from
/// it makes no model call at all.
///
/// ### The numbers are per base portion, and scaling is linear
///
/// `calories` and the seven beside it describe this item AT
/// `basePortionQuantity` of `basePortionUnit`, normally 100 g, because that is
/// how a label prints and how every public food database returns it. A log of
/// 150 g multiplies all eight by 1.5.
///
/// Linearity is an assumption, and it is the right one here: the set this table
/// is for is packaged goods, where a portion is a fraction of a pack and the
/// label scales exactly. It would be wrong for a recipe whose yield changes
/// with size, and this model is not for recipes. `LocalMealPlanEntry.recipe`
/// is.
///
/// ### Why the numbers are copied onto the meal, not referenced from it
///
/// `mealItem(quantity:)` builds a plain `MealItemEntry`, the same value type an
/// estimate produces, and `LocalMeal` stores that. Nothing on the meal points
/// back here.
///
/// That is deliberate, and it is the same call `LocalExpense` makes about an FX
/// rate. Correcting this row must not silently rewrite last month's breakfasts.
/// A logged meal is what you ate; an edit here is what you will eat next time.
@Model
final class LocalFoodItem {

    /// Stable identity. Unique within the store. A `String` rather than a
    /// `UUID` for the reason `LocalMeal` and `LocalExpense` both give: the AI
    /// tool surface emits and consumes UUIDs as strings, and `find_saved_food`
    /// has to be able to name the row it matched.
    @Attribute(.unique) var clientUUID: String = UUID().uuidString.lowercased()

    /// What the thing is, without the brand: "Greek Style High Protein Yogurt".
    /// Held apart from `brand` so the picker can sort and group by maker, and
    /// so a search for "yogurt" hits every maker's.
    var name: String = ""

    /// Who makes it, or nil for something generic you typed yourself ("boiled
    /// egg"). Optional rather than an empty string, because "no brand" is a
    /// real and common state here and `nil` reads as that at every call site.
    var brand: String?

    // MARK: - The base portion

    /// The amount the eight nutrient columns describe. Normally 100.
    var basePortionQuantity: Double = 100

    /// `g` or `ml`, matching `MealItemEntry.portionUnit`, which
    /// `MealToolSchema` requires to be exactly one of those two.
    ///
    /// A raw `String` rather than the enum below for the reason `LocalMeal`
    /// stores `mealType` as a string: a stored enum is a migration every time
    /// the set moves. Read it through `unit`, which turns anything unknown into
    /// grams rather than trapping.
    var basePortionUnit: String = FoodPortionUnit.grams.rawValue

    /// The eight nutrients AT `basePortionQuantity`. Units match `LocalMeal`
    /// exactly: calories in kcal, sodium in mg, everything else in grams.
    ///
    /// ⚠️ Sodium in milligrams is the one that catches an importer out. Open
    /// Food Facts returns `sodium_100g` in GRAMS, so its value is multiplied by
    /// 1,000 on the way in. A missed conversion here is a thousandfold error
    /// that no guard downstream would question.
    var calories: Double = 0
    var proteinG: Double = 0
    var carbsG: Double = 0
    var fatG: Double = 0
    var fibreG: Double = 0
    var sugarG: Double = 0
    var sodiumMg: Double = 0
    var satFatG: Double = 0

    /// How much of this you normally eat, in `basePortionUnit`. The 150 g pot,
    /// the 40 g wafer, the 30 g scoop.
    ///
    /// Separate from `basePortionQuantity` because the two answer different
    /// questions and collapsing them loses one. The base is how the label is
    /// printed; the default is what you actually take. The picker opens on this
    /// number, so the common case is pick and log with nothing typed.
    var defaultPortionQuantity: Double = 100

    // MARK: - Where the row came from

    /// EAN or UPC off the packet, when a scan or a database hit supplied one.
    /// Also the fastest re-match: a second scan of the same packet finds this
    /// row instead of asking the network again.
    var barcode: String?

    /// The public database this row was seeded from, e.g. "openfoodfacts", or
    /// nil for a row typed by hand. Kept beside `externalID` so a future
    /// refresh knows which service to ask.
    var externalSource: String?

    /// The seeding database's own id for the product, e.g. the Open Food Facts
    /// product code. Kept so a re-import updates this row instead of making a
    /// second one.
    var externalID: String?

    /// How the row entered the library: "manual", "openfoodfacts", "barcode",
    /// "meal", "chat". A raw string rather than an enum, exactly as
    /// `LocalMeal.source` is, because the requirement is provenance for a
    /// caption and the set of entry points is still moving. Compare against a
    /// constant, never parse.
    var source: String = FoodItemSource.manual

    /// The user has read the numbers against the packet and accepted them.
    ///
    /// Every row reaches the store through a confirm step, so this is true for
    /// a hand-typed row and for an import the user looked at. It stays false
    /// only where a row was seeded without eyes on it. The picker prints it,
    /// because a public database is crowd-sourced: one Open Food Facts hit for
    /// a high-protein vanilla yogurt claims 52 kcal per 100 g, which is wrong,
    /// and nothing downstream can tell that from a plausible number.
    var isVerified: Bool = false

    /// Anything the label says that the eight columns cannot hold. Nil normally.
    var notes: String?

    // MARK: - Ordering the picker

    /// How many times this item has been logged. The picker sorts on it, so the
    /// list orders itself around what you actually eat instead of around when
    /// you happened to add it.
    var useCount: Int = 0

    /// When it was last logged, or nil if never. Breaks ties in `useCount` and
    /// keeps a recently rediscovered item near the top.
    var lastUsedAt: Date?

    /// Hidden from the picker without being deleted.
    ///
    /// A delete is the honest action for a row typed by mistake, and
    /// `FoodItemService` offers one. This flag is for the other case: something
    /// you ate for a year and stopped, whose numbers must stay readable because
    /// meals already logged from it are not the thing being retired.
    var isArchived: Bool = false

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: - Dead-field parity with the other local models
    //
    // Intentionally unused. Kept so this model's schema lines up with the
    // others and so no future sync or migration story needs a destructive
    // change. Removing a field from a live model triggers a lightweight
    // migration that can fail and take the whole store with it, so this
    // codebase adds fields and never removes them. Don't remove.
    var needsSync: Bool = false
    var version: Int = 0

    init(
        clientUUID: String = UUID().uuidString.lowercased(),
        name: String,
        brand: String? = nil,
        basePortionQuantity: Double = 100,
        basePortionUnit: String = FoodPortionUnit.grams.rawValue,
        calories: Double = 0,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0,
        fibreG: Double = 0,
        sugarG: Double = 0,
        sodiumMg: Double = 0,
        satFatG: Double = 0,
        defaultPortionQuantity: Double = 100,
        barcode: String? = nil,
        externalSource: String? = nil,
        externalID: String? = nil,
        source: String = FoodItemSource.manual,
        isVerified: Bool = false,
        notes: String? = nil,
        useCount: Int = 0,
        lastUsedAt: Date? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        needsSync: Bool = false,
        version: Int = 0
    ) {
        self.clientUUID = clientUUID
        self.name = name
        self.brand = brand
        self.basePortionQuantity = basePortionQuantity
        self.basePortionUnit = basePortionUnit
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fibreG = fibreG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.satFatG = satFatG
        self.defaultPortionQuantity = defaultPortionQuantity
        self.barcode = barcode
        self.externalSource = externalSource
        self.externalID = externalID
        self.source = source
        self.isVerified = isVerified
        self.notes = notes
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.needsSync = needsSync
        self.version = version
    }
}

// MARK: - Convenience

extension LocalFoodItem {

    /// Typed view of `basePortionUnit`. Anything unknown reads as grams, the
    /// bucket that is true of most things eaten, rather than trapping.
    var unit: FoodPortionUnit {
        get { FoodPortionUnit(rawValue: basePortionUnit) ?? .grams }
        set { basePortionUnit = newValue.rawValue }
    }

    /// Brand and name, as a shelf would label it: "Farmers Union Greek Style
    /// High Protein Yogurt". The brand is dropped when it is nil or already the
    /// first word of the name, so an imported row whose `product_name` repeats
    /// its own maker does not read "Superyou Superyou Protein Wafer".
    var displayName: String {
        guard let brand = brand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !brand.isEmpty else { return name }
        if name.lowercased().hasPrefix(brand.lowercased()) { return name }
        return "\(brand) \(name)"
    }

    /// The eight nutrients for `quantity` of `basePortionUnit`, scaled linearly
    /// off the base.
    ///
    /// The arithmetic itself lives in `MealNutrients.scaled(_:fromBasePortion:to:)`,
    /// which `FoodItemDraft` also calls. A hit that is not saved yet has to be
    /// rescalable in the tray with no row behind it, and two copies of the
    /// ratio is how the saved and unsaved halves of one picker start printing
    /// different numbers for the same packet (#625).
    func nutrients(for quantity: Double) -> MealNutrients {
        MealNutrients.scaled(
            MealNutrients(
                calories: calories,
                proteinG: proteinG,
                carbsG: carbsG,
                fatG: fatG,
                fibreG: fibreG,
                sugarG: sugarG,
                sodiumMg: sodiumMg,
                satFatG: satFatG
            ),
            fromBasePortion: basePortionQuantity,
            to: quantity
        )
    }

    /// The nutrients at `defaultPortionQuantity`, which is what the picker
    /// shows before anything is typed.
    var defaultNutrients: MealNutrients { nutrients(for: defaultPortionQuantity) }

    /// This item, at `quantity`, as the value type a meal actually stores.
    ///
    /// The returned entry is a plain copy with no link back to this row. See
    /// the note on the model: an edit here must not rewrite meals already
    /// logged.
    func mealItem(quantity: Double? = nil) -> MealItemEntry {
        let amount = quantity ?? defaultPortionQuantity
        let n = nutrients(for: amount)
        return MealItemEntry(
            name: displayName,
            portionQuantity: amount,
            portionUnit: basePortionUnit,
            calories: n.calories,
            proteinG: n.proteinG,
            carbsG: n.carbsG,
            fatG: n.fatG,
            fibreG: n.fibreG,
            sugarG: n.sugarG,
            sodiumMg: n.sodiumMg,
            satFatG: n.satFatG
        )
    }

    /// Everything a typed query is matched against, lowercased once.
    ///
    /// The barcode is in it deliberately: a scan that finds no row can be typed
    /// in, and a pasted code should find the row it belongs to.
    var searchHaystack: String {
        [name, brand ?? "", notes ?? "", barcode ?? ""]
            .joined(separator: " ")
            .lowercased()
    }

    /// Does this row answer `query`? Every whitespace-separated word must
    /// appear somewhere in the haystack, so "farmers protein" finds the
    /// high-protein Farmers Union row and "farmers mango" does not.
    func matches(query: String) -> Bool {
        let words = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = searchHaystack
        return words.allSatisfy { haystack.contains($0) }
    }
}

// MARK: - The two units

/// What a portion is measured in. Exactly the two units `MealToolSchema`
/// allows on a meal item, and for the same reason: a weight or a volume can be
/// scaled by a ratio, and "one bowl" cannot.
enum FoodPortionUnit: String, CaseIterable, Identifiable, Sendable {
    case grams = "g"
    case millilitres = "ml"

    var id: String { rawValue }

    /// How the unit is spoken in a label, as opposed to printed after a number.
    var displayName: String {
        switch self {
        case .grams:       return "grams (g)"
        case .millilitres: return "millilitres (ml)"
        }
    }
}

/// Provenance constants for `LocalFoodItem.source`.
///
/// An enum-shaped namespace of plain strings rather than a Swift enum, matching
/// `MealSource` and `MealPlanSource`: the value is stored, it is written by
/// paths that keep arriving, and a stored enum is a migration each time the set
/// moves.
enum FoodItemSource {
    /// Typed by hand off the label.
    static let manual = "manual"
    /// Imported from an Open Food Facts search hit.
    static let openFoodFacts = "openfoodfacts"
    /// Imported after scanning the packet's barcode.
    static let barcode = "barcode"
    /// Saved out of an item on a meal that was already logged.
    static let meal = "meal"
    /// Saved by the assistant during a chat or a Shortcut run.
    static let chat = "chat"
}
