import Foundation

/// The eight nutrient values as one value type (#542).
///
/// `LocalMeal` and `MealTargets` both store the eight as flat columns, because
/// SwiftData needs them flat to sort, filter and sum without decoding anything.
/// This struct is the shape they travel in BETWEEN those columns and everything
/// else: one service argument instead of eight, one thing to validate, one
/// thing to add up.
///
/// Field names and units match the model columns exactly (`Nutrient.unit`:
/// kcal for calories, mg for sodium, grams for the rest), so moving a value in
/// either direction is a copy and never a conversion.
struct MealNutrients: Codable, Equatable, Hashable, Sendable {
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fibreG: Double
    var sugarG: Double
    var sodiumMg: Double
    var satFatG: Double

    init(
        calories: Double = 0,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0,
        fibreG: Double = 0,
        sugarG: Double = 0,
        sodiumMg: Double = 0,
        satFatG: Double = 0
    ) {
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fibreG = fibreG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.satFatG = satFatG
    }

    /// Nothing recorded. The starting point for a meal logged with a
    /// description and no estimate yet.
    static let zero = MealNutrients()

    /// Read or write one nutrient by name, so a loop over `Nutrient.allCases`
    /// covers all eight without naming a field.
    subscript(nutrient: Nutrient) -> Double {
        get {
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
        set {
            switch nutrient {
            case .calories:     calories = newValue
            case .protein:      proteinG = newValue
            case .carbs:        carbsG = newValue
            case .fat:          fatG = newValue
            case .fibre:        fibreG = newValue
            case .sugar:        sugarG = newValue
            case .sodium:       sodiumMg = newValue
            case .saturatedFat: satFatG = newValue
            }
        }
    }

    /// True when any of the eight is below zero. There is no such thing as
    /// negative protein, so this is a bad estimate or a bad caller, and
    /// `MealService` refuses it rather than storing a total that can never be
    /// reconciled against its items.
    var hasNegativeValue: Bool {
        Nutrient.allCases.contains { self[$0] < 0 }
    }

    /// Add two sets of values, nutrient by nutrient. Used to total a day.
    static func + (lhs: MealNutrients, rhs: MealNutrients) -> MealNutrients {
        var out = MealNutrients()
        for nutrient in Nutrient.allCases { out[nutrient] = lhs[nutrient] + rhs[nutrient] }
        return out
    }

    /// The sum of a list of dishes.
    ///
    /// ⚠️ NOT what a meal's stored totals are read from. A meal's eight columns
    /// are its own truth (see `LocalMeal`), because the split across items is a
    /// guess that the user can correct one dish at a time. This is here for the
    /// caller building a meal FROM items, and for checking one against the
    /// other.
    static func sum(of items: [MealItemEntry]) -> MealNutrients {
        items.reduce(MealNutrients.zero) { $0 + $1.nutrients }
    }
}

extension MealItemEntry {
    /// This dish's eight values as one struct.
    var nutrients: MealNutrients {
        MealNutrients(
            calories: calories, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
            fibreG: fibreG, sugarG: sugarG, sodiumMg: sodiumMg, satFatG: satFatG
        )
    }
}

extension LocalMeal {
    /// The meal's eight stored values as one struct. Writing replaces all
    /// eight; a partial update reads, mutates and writes back.
    var nutrients: MealNutrients {
        get {
            MealNutrients(
                calories: calories, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                fibreG: fibreG, sugarG: sugarG, sodiumMg: sodiumMg, satFatG: satFatG
            )
        }
        set {
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
}

extension MealTargets {
    /// The eight targets as one struct. Writing replaces all eight and does NOT
    /// touch `handEdited`: marking an override is the service's call, not a
    /// side effect of assignment.
    var targets: MealNutrients {
        get {
            MealNutrients(
                calories: calories, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                fibreG: fibreG, sugarG: sugarG, sodiumMg: sodiumMg, satFatG: satFatG
            )
        }
        set {
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
}
