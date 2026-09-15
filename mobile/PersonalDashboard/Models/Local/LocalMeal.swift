import Foundation
import SwiftData

/// Local-first SwiftData model for one logged meal (meal logging v1 — #542).
///
/// A brand-new `@Model`, which is the safe kind of SwiftData migration: it
/// creates one table and touches none of the models beside it.
///
/// ### The day is a day, not a moment
///
/// `date` is the calendar day the meal belongs to and is stored as a UTC
/// ANCHOR via `WallClock.dayAnchor(from:)`, exactly like a trip day. `loggedAt`
/// is the true instant, kept separately, and is the only field here that is a
/// moment.
///
/// `LocalExpense.date` uses a device-local `Calendar.startOfDay` because it
/// predates #506. Copying that here would make a day an instant, so a Tuesday's
/// calories would re-bucket to Monday the moment the device moved west — the
/// defect that split one Italy itinerary day across two headers. Read the day
/// back through `deviceDay` (or `WallClock.deviceDay(from:)`) before handing it
/// to any device-local formatter, never the raw anchor.
///
/// ### Estimates are stored, not recomputed
///
/// Every number on this row is an ESTIMATE from a description the user typed or
/// spoke. It is frozen at capture time for the same reason `LocalExpense`
/// freezes its FX conversion: a day's totals must not drift when the model
/// behind the estimate changes. A re-estimate is a write, not a read.
///
/// The eight nutrient columns are the meal's own truth, not a sum of `items`.
/// Roll-ups read them directly, so drawing a week never decodes a single item
/// payload.
@Model
final class LocalMeal {
    /// Stable identity. Unique within the store. Stored as `String` rather than
    /// `UUID` for the same reason `LocalExpense` does: the AI tool surface emits
    /// and consumes UUIDs as strings, and a retried Shortcut has to be able to
    /// name the row it already made.
    @Attribute(.unique) var clientUUID: String

    /// The calendar day this meal counts towards, anchored at UTC midnight.
    ///
    /// ⚠️ Written through `WallClock.dayAnchor(from:)` and read through
    /// `WallClock.deviceDay(from:)`. Never `Calendar.current.startOfDay`, and
    /// never formatted directly (#506).
    var date: Date

    /// The true instant the meal was eaten or logged. Separate from `date`
    /// because a day view orders breakfast before dinner by this, while every
    /// grouping and total keys on the anchored day.
    var loggedAt: Date

    /// `MealType.rawValue`. Stored raw so a future type does not force a
    /// SwiftData migration, and read back through `mealTypeEnum`, which falls
    /// back rather than trapping on a value this build has not heard of.
    var mealType: String

    /// What the user said they ate, VERBATIM. Never the model's tidied-up
    /// rewrite: this is the text a re-estimate runs against, and the text the
    /// user recognises as theirs. Named `mealDescription` (not `description`)
    /// to avoid clashing with `CustomStringConvertible.description`.
    var mealDescription: String

    // MARK: - The eight
    //
    // Units per `Nutrient.unit`: kcal for calories, mg for sodium, grams for
    // the rest. Non-optional with a stored value on every row because a missing
    // nutrient and a zero nutrient are the same thing for a total, and an
    // optional would push an `?? 0` into every roll-up.

    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fibreG: Double
    var sugarG: Double
    var sodiumMg: Double
    var satFatG: Double

    /// JSON-encoded `[MealItemEntry]`: the per-dish breakdown of this meal.
    ///
    /// Optional, and nil means "no breakdown was made", which is a real state —
    /// a quick log of "leftovers" has totals and no items. Read and write
    /// through `items`, which turns nil and a decode failure both into the empty
    /// array, so a meal whose payload is unreadable still shows its totals
    /// instead of taking the day down with it.
    var itemsData: Data?

    /// How much the estimate trusts itself, 0...1. A `Double` rather than a
    /// three-band enum so a surface can both band it ("low confidence") and
    /// order by it ("show me what I should check"), which a string cannot do.
    /// Clamped on write by `MealService`.
    var confidence: Double

    /// Channel this meal came from: "chat", "capture", "manual", "photo",
    /// "voice". A raw string rather than an enum, because the requirement here
    /// is only provenance for a badge and for telemetry, and the set of entry
    /// points is still moving. Compare against a constant, never parse.
    var source: String

    /// The estimate answered, but wants more from the user before it should be
    /// trusted ("rice — how much?"). Drives a prompt on the row, not a warning:
    /// the meal still counts while it is unanswered.
    var needsDetail: Bool

    /// The stored numbers are implausible for the description, as judged at
    /// capture time (a 4,000 kcal salad, 200 g of protein from one bowl).
    /// Distinct from `needsDetail`: that one wants an answer FROM the user,
    /// this one is a warning ABOUT the estimate.
    var isSuspect: Bool

    /// Why `isSuspect` is set, in one plain sentence, or nil when it is not.
    /// Stored rather than re-derived so the reason cannot drift away from the
    /// numbers that earned it.
    var suspectReason: String?

    /// What the estimate assumed and the user never said: portion sizes,
    /// cooking oil, a default drink size. Kept so a correction has something to
    /// argue with. Nil when nothing was assumed.
    var assumptionsNote: String?

    var createdAt: Date
    var updatedAt: Date

    // MARK: - Dead-field parity with the other local models
    //
    // Intentionally unused. Kept so this model's schema lines up with the
    // others and so no future sync or migration story needs a destructive
    // change. Removing a field from a live model triggers a lightweight
    // migration that can fail and take the whole store with it, so this
    // codebase adds fields and never removes them. Don't remove.
    var needsSync: Bool
    var version: Int

    init(
        clientUUID: String = UUID().uuidString.lowercased(),
        date: Date = Date(),
        loggedAt: Date = Date(),
        mealType: String,
        mealDescription: String,
        calories: Double = 0,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0,
        fibreG: Double = 0,
        sugarG: Double = 0,
        sodiumMg: Double = 0,
        satFatG: Double = 0,
        itemsData: Data? = nil,
        confidence: Double = 0,
        source: String,
        needsDetail: Bool = false,
        isSuspect: Bool = false,
        suspectReason: String? = nil,
        assumptionsNote: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        needsSync: Bool = false,
        version: Int = 0
    ) {
        self.clientUUID = clientUUID
        self.date = date
        self.loggedAt = loggedAt
        self.mealType = mealType
        self.mealDescription = mealDescription
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fibreG = fibreG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.satFatG = satFatG
        self.itemsData = itemsData
        self.confidence = confidence
        self.source = source
        self.needsDetail = needsDetail
        self.isSuspect = isSuspect
        self.suspectReason = suspectReason
        self.assumptionsNote = assumptionsNote
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.needsSync = needsSync
        self.version = version
    }

    // MARK: - Convenience

    /// Typed view of `mealType`. An unknown raw value reads as `.snack`, the
    /// one bucket that is true at any hour, rather than trapping.
    var mealTypeEnum: MealType {
        get { MealType(rawValue: mealType) ?? .snack }
        set { mealType = newValue.rawValue }
    }

    /// The device-local midnight of this meal's day. The value to hand a
    /// `DatePicker` or any device-local formatter. Formatting `date` itself
    /// prints the day before, anywhere west of UTC (#506).
    var deviceDay: Date {
        WallClock.deviceDay(from: date)
    }

    /// Read/write the per-dish breakdown. Nil and a decode failure both read as
    /// empty, and setting an empty array clears the blob back to nil so a meal
    /// with no breakdown stores nothing.
    var items: [MealItemEntry] {
        get {
            guard let itemsData, !itemsData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([MealItemEntry].self, from: itemsData)) ?? []
        }
        set {
            itemsData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue))
        }
    }

    /// This meal's value for one nutrient. The single accessor every bar,
    /// verdict and callout reads, paired with `Nutrient.goalKind`, so no
    /// surface switches on eight fields to draw one row.
    func value(for nutrient: Nutrient) -> Double {
        switch nutrient {
        case .calories:     return calories
        case .protein:      return proteinG
        case .carbs:        return carbsG
        case .fat:          return fatG
        case .fibre:        return fibreG
        case .sugar:        return sugarG
        case .sodium:       return sodiumMg
        case .saturatedFat: return satFatG
        }
    }
}
