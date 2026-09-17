import Foundation
import SwiftData

/// One planned meal on one day (#599).
///
/// A brand-new `@Model`, which is the safe kind of SwiftData migration: it
/// creates one table and touches none of the models beside it — the same call
/// `LocalMeal` made in #542.
///
/// ### Why this is not a `LocalMeal` with a flag
///
/// A plan and a log answer different questions and a shared row could only
/// answer one of them at a time. Every roll-up over `LocalMeal` — the day card,
/// the trends band, the calendar readings, the Today tile — sums the table
/// without asking what kind of row it is holding, so a planned dinner sitting in
/// it would land in Thursday's calories before Thursday happened. Filtering it
/// back out again would mean finding all of those readers and agreeing, forever,
/// on a test none of them needs today.
///
/// It also gets the direction of the two wrong. A meal is an ESTIMATE of
/// something that happened; a plan is an INTENTION that may not. A plan can be
/// skipped, and there is no such thing as skipping a meal you already ate.
///
/// ### The day is a day, not a moment
///
/// `date` is the calendar day this block belongs to, stored as a UTC ANCHOR via
/// `WallClock.dayAnchor(from:)`, exactly like `LocalMeal.date` and a trip day.
/// Read it back through `deviceDay` before handing it to any device-local
/// formatter, never the raw anchor (#506).
///
/// There is no `loggedAt` twin here, and that absence is deliberate. A plan has
/// no instant: "lunch on Thursday" is the whole of what was decided, and a
/// stored time would be a number nobody chose showing up on a card. Order
/// within the day comes from `mealType` and `slotIndex` instead.
@Model
final class LocalMealPlanEntry {
    /// Stable identity. Unique within the store, and a `String` rather than a
    /// `UUID` for the same reason `LocalMeal.clientUUID` is one: the AI surface
    /// emits and consumes ids as strings, and a repeated add carrying an id is a
    /// retry of one block rather than a second block (#514).
    @Attribute(.unique) var clientUUID: String

    /// The calendar day this block is planned for, anchored at UTC midnight.
    ///
    /// ⚠️ Written through `WallClock.dayAnchor(from:)` and read through
    /// `WallClock.deviceDay(from:)`. Never `Calendar.current.startOfDay`, and
    /// never formatted directly (#506).
    var date: Date

    /// `MealType.rawValue`. Stored raw, like `LocalMeal.mealType`, so a future
    /// type does not force a migration, and read back through `mealTypeEnum`,
    /// which falls back rather than trapping on a value this build has not
    /// heard of.
    var mealType: String

    /// Position of this block WITHIN its meal type on this day, from zero.
    ///
    /// This is what lets a day hold three snacks. `mealType` alone cannot: two
    /// snack rows would have no defined order, so the list would reshuffle on
    /// every fetch and an edit would land on whichever one SwiftData returned
    /// first.
    ///
    /// Not unique in the schema and deliberately so. A duplicate index is a
    /// cosmetic ordering question, and a `@Attribute(.unique)` on a compound of
    /// (day, type, index) would make a legitimate insert REPLACE a sibling
    /// block, which is the failure #514 spent a ticket on. `MealPlanService`
    /// normalises the indices after every write instead, where a bad value
    /// costs an order and never a row.
    var slotIndex: Int

    /// What is going to be eaten, in the user's words. Named `title` rather
    /// than `description` to avoid clashing with `CustomStringConvertible`, the
    /// same dodge `LocalMeal.mealDescription` makes.
    var title: String

    /// The dish in a few words, as the estimate named it (#603).
    ///
    /// `title` is what the USER typed, verbatim, and it is what the plan sheet
    /// shows and edits. This is what a TILE prints, because a block is a row in
    /// a stack of four tiles and a title typed as a sentence ("leftover chicken
    /// curry with the rice from Sunday, plus a salad") pushes the calorie pill
    /// onto its own line and the ingredients off the bottom.
    ///
    /// Nil means nobody has named it yet, which is every block typed and not
    /// estimated, and every block written before this field existed.
    /// `MealNamingService` fills those in one batched call, and until it does
    /// `MealDisplayName` shortens the typed title instead. Read it through that
    /// resolver, never directly, so one block is never named two ways.
    ///
    /// Additive and OPTIONAL, which is the safe kind of SwiftData migration: an
    /// optional attribute gets NULL on every existing row and nothing else on
    /// the model moves. The non-optional fields below carry `= false` / `= 0` on
    /// their declarations for the opposite reason (#555); an optional has no
    /// such gap.
    var shortTitle: String?

    /// JSON-encoded `[String]`: the MAIN ingredients, not a shopping list.
    ///
    /// Optional, and nil means none were named, which is a real state — "eat
    /// out with Dad" is a plan with no ingredients. Read and write through
    /// `ingredients`, which turns nil and a decode failure both into the empty
    /// array, so a block whose payload is unreadable still shows its title
    /// instead of taking the day down with it.
    ///
    /// Stored as a blob rather than as a relationship for the reason every
    /// other list in this codebase is (`MealItemEntry`, `ExpenseSplitEntry`,
    /// `VisionItem`): SwiftData on iOS 17.0 will not persist an array without a
    /// custom transformer, and a blob with a computed accessor is the pattern
    /// the store already trusts.
    var ingredientsData: Data?

    /// Anything else about the block: where it is coming from, who is cooking,
    /// what to prep the night before. Nil when empty.
    var notes: String?

    /// How to make it, when the estimate offered a method. Nil otherwise, which
    /// is most blocks: a meal that is bought, or one the user already knows how
    /// to cook, has no recipe worth storing.
    ///
    /// Plain text with one step per line rather than a structured list. A recipe
    /// on a PLAN is a reminder, not a document to follow at the hob: it exists so
    /// that a dish suggested on Sunday is still makeable on Thursday. Structuring
    /// it would invite quantities, timings and substitutions, none of which this
    /// surface is going to keep up to date.
    var recipe: String?

    /// JSON-encoded `[MealItemEntry]`: the per-dish breakdown the estimate made.
    ///
    /// The same type `LocalMeal.itemsData` carries, deliberately. A planned meal
    /// and a logged one are broken down by the same estimator against the same
    /// rules (`MealToolSchema`), so the detail sheet can show a planned block's
    /// components in the same shape Tracking shows a logged meal's, and a block
    /// that later becomes a real meal carries its breakdown across.
    ///
    /// Optional, and nil means no breakdown was made, which is a real state: a
    /// block the user typed a title into and never estimated. Read and write
    /// through `items`, which turns nil and a decode failure both into the empty
    /// array.
    ///
    /// ⚠️ NOT the source of the eight totals. The totals are their own columns,
    /// for the reason `LocalMeal` spells out: the split across items is a guess
    /// the user can correct one dish at a time, and every roll-up reads the
    /// totals directly rather than decoding a payload per row.
    var itemsData: Data?

    /// `MealPlanStatus.rawValue`. Raw for the same reason `mealType` is, and
    /// read through `statusEnum`, which reads an unknown value as `.planned` —
    /// the state that claims the least.
    var status: String

    // MARK: - Planned nutrition
    //
    // Optional in meaning, not in type. `hasNutrition` is the flag that says
    // whether the eight below mean anything; the eight themselves are
    // non-optional with a stored zero, exactly as `LocalMeal`'s are, because a
    // missing nutrient and a zero nutrient are the same thing for a total and
    // an optional would push an `?? 0` into every roll-up.
    //
    // ⚠️ The `= false` / `= 0` on each DECLARATION is load-bearing on a model
    // that ever ships a second time. SwiftData reads the declaration to give the
    // attribute a default, and a non-optional attribute without one fails a
    // lightweight migration outright (#555). Every field here carries one from
    // the first commit so nobody has to remember the rule later.

    /// True when the eight below were filled in. False on a block someone
    /// typed a title into and nothing else, which is the common case.
    ///
    /// A flag rather than "calories > 0", because a planned fast, a black
    /// coffee and a plan with no numbers would all read as zero calories and
    /// only two of those are the same state.
    var hasNutrition: Bool = false

    var calories: Double = 0
    var proteinG: Double = 0
    var carbsG: Double = 0
    var fatG: Double = 0
    var fibreG: Double = 0
    var sugarG: Double = 0
    var sodiumMg: Double = 0
    var satFatG: Double = 0

    /// Where the block came from: `MealPlanSource.manual`, `.chat` or `.copy`.
    /// A raw string compared against a constant, never parsed — the same
    /// contract `LocalMeal.source` documents.
    var source: String = MealPlanSource.manual

    var createdAt: Date
    var updatedAt: Date

    // MARK: - Dead-field parity with the other local models
    //
    // Intentionally unused, and kept so this model's schema lines up with the
    // others. Removing a field from a live model triggers a lightweight
    // migration that can fail and take the whole store with it, so this
    // codebase adds fields and never removes them. Don't remove.
    var needsSync: Bool = false
    var version: Int = 0

    init(
        clientUUID: String = UUID().uuidString.lowercased(),
        date: Date = Date(),
        mealType: String,
        slotIndex: Int = 0,
        title: String,
        shortTitle: String? = nil,
        ingredientsData: Data? = nil,
        notes: String? = nil,
        recipe: String? = nil,
        itemsData: Data? = nil,
        status: String = MealPlanStatus.planned.rawValue,
        hasNutrition: Bool = false,
        calories: Double = 0,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0,
        fibreG: Double = 0,
        sugarG: Double = 0,
        sodiumMg: Double = 0,
        satFatG: Double = 0,
        source: String = MealPlanSource.manual,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        needsSync: Bool = false,
        version: Int = 0
    ) {
        self.clientUUID = clientUUID
        self.date = date
        self.mealType = mealType
        self.slotIndex = slotIndex
        self.title = title
        self.shortTitle = shortTitle
        self.ingredientsData = ingredientsData
        self.notes = notes
        self.recipe = recipe
        self.itemsData = itemsData
        self.status = status
        self.hasNutrition = hasNutrition
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fibreG = fibreG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.satFatG = satFatG
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.needsSync = needsSync
        self.version = version
    }

    // MARK: - Convenience

    /// Typed view of `mealType`. An unknown raw value reads as `.snack`, the
    /// one bucket that is true at any hour, matching `LocalMeal.mealTypeEnum`
    /// rather than inventing a second rule for the same column.
    var mealTypeEnum: MealType {
        get { MealType(rawValue: mealType) ?? .snack }
        set { mealType = newValue.rawValue }
    }

    /// Typed view of `status`. An unknown raw value reads as `.planned`: a
    /// block from a newer build whose state this one cannot name is still a
    /// block somebody wrote down, and `.planned` is the reading that neither
    /// claims it happened nor claims it was abandoned.
    var statusEnum: MealPlanStatus {
        get { MealPlanStatus(rawValue: status) ?? .planned }
        set { status = newValue.rawValue }
    }

    /// The device-local midnight of this block's day. The value to hand a
    /// `DatePicker` or any device-local formatter. Formatting `date` itself
    /// prints the day before, anywhere west of UTC (#506).
    var deviceDay: Date {
        WallClock.deviceDay(from: date)
    }

    /// Read/write the main ingredients. Nil and a decode failure both read as
    /// empty, and setting an empty array clears the blob back to nil so a block
    /// with no ingredients stores nothing.
    var ingredients: [String] {
        get {
            guard let ingredientsData, !ingredientsData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([String].self, from: ingredientsData)) ?? []
        }
        set {
            ingredientsData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue))
        }
    }

    /// Read/write the per-dish breakdown. Nil and a decode failure both read as
    /// empty, and setting an empty array clears the blob back to nil so a block
    /// with no breakdown stores nothing. Mirrors `LocalMeal.items`.
    var items: [MealItemEntry] {
        get {
            guard let itemsData, !itemsData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([MealItemEntry].self, from: itemsData)) ?? []
        }
        set {
            itemsData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue))
        }
    }

    /// The eight planned values as one struct, or nil when this block carries
    /// no numbers.
    ///
    /// Nil rather than `.zero` on purpose: a caller that summed a `.zero` for
    /// every numberless block would report a planned day of 400 kcal as if the
    /// other four meals were fasts. `MealPlanDay` counts what it could read and
    /// says how many it could not.
    var plannedNutrients: MealNutrients? {
        get {
            guard hasNutrition else { return nil }
            return MealNutrients(
                calories: calories, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                fibreG: fibreG, sugarG: sugarG, sodiumMg: sodiumMg, satFatG: satFatG
            )
        }
        set {
            guard let newValue else {
                hasNutrition = false
                calories = 0; proteinG = 0; carbsG = 0; fatG = 0
                fibreG = 0; sugarG = 0; sodiumMg = 0; satFatG = 0
                return
            }
            hasNutrition = true
            calories = newValue.calories
            proteinG = newValue.proteinG
            carbsG   = newValue.carbsG
            fatG     = newValue.fatG
            fibreG   = newValue.fibreG
            sugarG   = newValue.sugarG
            sodiumMg = newValue.sodiumMg
            satFatG  = newValue.satFatG
        }
    }

    /// True when this block still counts towards what the day intends to eat.
    /// Delegates to `MealPlanStatus.countsTowardsPlan` so the rule has one
    /// statement — see the note there.
    var countsTowardsPlan: Bool { statusEnum.countsTowardsPlan }
}

/// The provenance strings `LocalMealPlanEntry.source` carries (#599).
///
/// Constants rather than an enum, matching `MealSource`, because the model
/// stores a raw string on purpose and the set of entry points is still moving.
enum MealPlanSource {
    /// Typed into the plan editor by hand.
    static let manual = "manual"

    /// Added from a suggestion the plan chat proposed. The numbers are the
    /// model's estimate of a meal that has not been eaten, which is a weaker
    /// claim than a logged meal's estimate and is why the card says so.
    static let chat = "chat"

    /// Copied from another day's plan, or from a meal already logged. No API
    /// call was made, so the numbers are a copy rather than a fresh estimate —
    /// the same distinction `MealSource.repeated` draws.
    static let copy = "copy"
}
