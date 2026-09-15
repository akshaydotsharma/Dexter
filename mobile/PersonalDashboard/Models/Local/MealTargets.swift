import Foundation
import SwiftData

/// The eight daily nutrient targets, and what they were derived from (#542).
///
/// ### Why this is a model and not `UserDefaults`
///
/// `FinanceSettings` keeps its preferences in `UserDefaults`, and that is the
/// wrong home for these. `UserDefaults` is device-local, so the phone and the
/// Mac would each derive their own targets from whatever body figures each one
/// happened to be told. A target that differs between the two devices makes
/// every verdict on one of them wrong, silently, and there is nothing on screen
/// to reveal it. As a `@Model` the targets are one record, backed up with
/// everything else and carried by sync.
///
/// ### Why `effectiveFrom` ships now
///
/// v1 only ever holds ONE active record, so nothing reads this field yet. It
/// ships anyway because retrofitting a date onto a model that already has rows
/// is precisely the change this schema cannot take safely: SwiftData would have
/// to invent a value for every existing row, and the value it invents is not
/// the one those rows mean. Adding the column while the table is empty costs
/// nothing; adding it later costs a migration nobody can make correct.
///
/// ### Why the derivation inputs are stored beside the outputs
///
/// The eight numbers are derived from the six inputs, and a derivation is only
/// re-runnable if its inputs survive. Keeping them here is what lets a weight
/// change re-derive the targets instead of asking the six questions again, and
/// it is what makes `rationale` checkable against something.
@Model
final class MealTargets {
    /// Stable identity. Unique within the store. `String` rather than `UUID`,
    /// matching `LocalMeal` and `LocalExpense`, so both meal-logging models key
    /// the same way through the archive and the oplog.
    @Attribute(.unique) var clientUUID: String

    // MARK: - The eight targets
    //
    // Same names and same units as `LocalMeal`'s eight, so `value(for:)` there
    // and `target(for:)` here are read side by side without a unit conversion
    // between them. Units per `Nutrient.unit`.
    //
    // What each number MEANS depends on `Nutrient.goalKind`: a floor to reach
    // (protein, fibre), a ceiling to stay under (sugar, sodium, saturated fat),
    // or the middle of a band (calories, carbs, fat). Nothing here re-decides
    // that; every reader asks the nutrient.

    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fibreG: Double
    var sugarG: Double
    var sodiumMg: Double
    var satFatG: Double

    // MARK: - The six derivation inputs

    /// Age in whole years at the time of derivation.
    var ageYears: Int

    /// Biological sex as used by the energy equations: "male", "female". A raw
    /// string rather than an enum because it is an input to a formula, not a
    /// concept this feature reasons about, and because the set may need a value
    /// the equations treat as an average. Compare against a constant.
    var biologicalSex: String

    var heightCm: Double
    var weightKg: Double

    /// Activity level, as the multiplier band it names: "sedentary", "light",
    /// "moderate", "active", "very_active". Raw string for the same reason as
    /// `biologicalSex`.
    var activityLevel: String

    /// What the targets are for: "lose", "maintain", "gain". Raw string, same
    /// reasoning again.
    var goal: String

    /// Plain-language explanation of how these eight numbers came out of those
    /// six inputs, written when they were derived.
    ///
    /// Stored rather than re-derived on demand: the derivation can change
    /// between builds, and a rationale that no longer describes the stored
    /// numbers is worse than no rationale. This one is always the one that
    /// produced the numbers sitting next to it.
    var rationale: String

    /// The first day these targets apply to, anchored at UTC midnight like
    /// every other day field (#506). Written through
    /// `WallClock.dayAnchor(from:)`, read through `WallClock.deviceDay(from:)`.
    var effectiveFrom: Date

    /// JSON-encoded `[String]` of `Nutrient.rawValue`s the user typed a figure
    /// for by hand.
    ///
    /// Per-value rather than one flag for the record, because that is the
    /// question a re-derivation has to ask: a user who overrode protein and left
    /// the other seven alone must keep their protein and get the other seven
    /// refreshed. Stored as a blob rather than eight `Bool` columns so that a
    /// ninth nutrient, if there ever is one, adds no column, and so the set
    /// reads back through `Nutrient` instead of through eight field names.
    ///
    /// Nil means nothing was hand-edited. Read and write through `handEdited`.
    var handEditedData: Data?

    var createdAt: Date
    var updatedAt: Date

    // MARK: - Dead-field parity with the other local models
    //
    // Unused here, kept so the schema lines up with every other local model.
    // Fields are added and never removed in this codebase — see `LocalMeal`.
    var needsSync: Bool
    var version: Int

    init(
        clientUUID: String = UUID().uuidString.lowercased(),
        calories: Double = 0,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0,
        fibreG: Double = 0,
        sugarG: Double = 0,
        sodiumMg: Double = 0,
        satFatG: Double = 0,
        ageYears: Int = 0,
        biologicalSex: String = "",
        heightCm: Double = 0,
        weightKg: Double = 0,
        activityLevel: String = "",
        goal: String = "",
        rationale: String = "",
        effectiveFrom: Date = WallClock.todayAnchor(),
        handEditedData: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        needsSync: Bool = false,
        version: Int = 0
    ) {
        self.clientUUID = clientUUID
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fibreG = fibreG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.satFatG = satFatG
        self.ageYears = ageYears
        self.biologicalSex = biologicalSex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.activityLevel = activityLevel
        self.goal = goal
        self.rationale = rationale
        self.effectiveFrom = effectiveFrom
        self.handEditedData = handEditedData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.needsSync = needsSync
        self.version = version
    }

    // MARK: - Convenience

    /// The device-local midnight of `effectiveFrom`, for a picker or a
    /// device-local formatter. Formatting the anchor itself prints the day
    /// before, anywhere west of UTC.
    var deviceEffectiveFrom: Date {
        WallClock.deviceDay(from: effectiveFrom)
    }

    /// The target for one nutrient. Paired with `LocalMeal.value(for:)` and
    /// `Nutrient.goalKind`, this is everything a bar needs.
    func target(for nutrient: Nutrient) -> Double {
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

    /// Set the target for one nutrient. Does NOT mark it hand-edited on its
    /// own: a re-derivation writes through here too, and only the user's own
    /// typing is an override. `MealService` owns that distinction.
    func setTarget(_ value: Double, for nutrient: Nutrient) {
        switch nutrient {
        case .calories:     calories = value
        case .protein:      proteinG = value
        case .carbs:        carbsG = value
        case .fat:          fatG = value
        case .fibre:        fibreG = value
        case .sugar:        sugarG = value
        case .sodium:       sodiumMg = value
        case .saturatedFat: satFatG = value
        }
    }

    /// Read/write the set of hand-edited nutrients. A decode failure reads as
    /// empty, which means a re-derivation would overwrite an override rather
    /// than crash: the recoverable failure of the two. Setting an empty set
    /// clears the blob back to nil. Raw values this build does not know are
    /// skipped on read and therefore dropped on the next write, which is the
    /// same call `LocalVisionBlock.members` makes about an id it cannot resolve.
    var handEdited: Set<Nutrient> {
        get {
            guard let handEditedData, !handEditedData.isEmpty else { return [] }
            let raw = (try? JSONDecoder().decode([String].self, from: handEditedData)) ?? []
            return Set(raw.compactMap(Nutrient.init(rawValue:)))
        }
        set {
            handEditedData = newValue.isEmpty
                ? nil
                : (try? JSONEncoder().encode(newValue.map(\.rawValue).sorted()))
        }
    }

    /// Whether the user typed this nutrient's target themselves.
    func isHandEdited(_ nutrient: Nutrient) -> Bool {
        handEdited.contains(nutrient)
    }
}
