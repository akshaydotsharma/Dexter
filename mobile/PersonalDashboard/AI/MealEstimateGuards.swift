import Foundation

/// One way an estimate failed the checks run over it after the model answered
/// (#543).
///
/// Each case carries the numbers that earned it, so `reason` can state the fact
/// rather than a category. "This meal looks wrong" is not actionable; "the
/// macros account for 1,240 kcal but the meal states 700" tells the user
/// exactly which of the two to correct.
enum MealGuardFailure: Equatable, Sendable {

    /// A nutrient came back below zero. Clamped to zero so the row can be
    /// stored at all — `MealService` refuses a negative — and flagged, because a
    /// value that was negative says nothing about what the right value is.
    case negativeValue(Nutrient)

    /// The meal totals more than `caloriesCeiling` kcal.
    case caloriesOverCeiling(Double)

    /// The meal totals more than `proteinCeilingG` grams of protein.
    case proteinOverCeiling(Double)

    /// The meal totals more than `sodiumCeilingMg` milligrams of sodium.
    case sodiumOverCeiling(Double)

    /// `4P + 4C + 9F` misses the stated calories by more than
    /// `macroTolerance`.
    ///
    /// The highest-value check in the set: it is the only one that can prove an
    /// estimate wrong without knowing anything about the food.
    case macroMismatch(stated: Double, impliedByMacros: Double)

    /// An item came back with no portion assumption, or one that cannot be
    /// scaled.
    ///
    /// Portion size is the largest single source of error in a text-derived
    /// estimate, so an assumption the user cannot see is an error they cannot
    /// fix.
    case missingPortion(itemName: String)

    /// Saturated fat exceeded total fat. Clamped down to the fat and flagged.
    case saturatedFatClamped(from: Double, to: Double)

    /// Sugar exceeded total carbohydrate. Clamped down to the carbs and flagged.
    case sugarClamped(from: Double, to: Double)

    /// Whether this failure INVALIDATES the estimate or merely REPAIRS it.
    ///
    /// The distinction decides whether the meal counts, so it is the highest
    /// consequence line in this file.
    ///
    /// A REPAIR leaves the meal coherent. Sugar clamped down to the carbs is a
    /// number that is now usable, so the meal keeps its place in the day. Reading
    /// a clamp as a failure means a real 600 kcal lunch silently leaves the day's
    /// total because the model put sugar a gram over carbs, and a day card that
    /// under-counts without saying so is a worse outcome than the slip it was
    /// guarding against. A guard is not allowed to delete good data from a total.
    ///
    /// An INVALIDATION leaves the meal incoherent. A macro mismatch means the
    /// numbers contradict each other and nothing in the set can be trusted; a
    /// missing portion means the largest source of error is unstated; a hard
    /// bound means something was multiplied. None of those is repairable from
    /// here, so the meal is held out until a human corrects it.
    ///
    /// A negative value is an invalidation and not a repair, even though it is
    /// clamped like one. Zeroing a negative does not recover the right value, it
    /// erases the wrong one: the meal is now missing a nutrient rather than
    /// holding a corrected one.
    var invalidatesEstimate: Bool {
        switch self {
        case .saturatedFatClamped, .sugarClamped:
            return false
        case .negativeValue,
             .caloriesOverCeiling,
             .proteinOverCeiling,
             .sodiumOverCeiling,
             .macroMismatch,
             .missingPortion:
            return true
        }
    }

    /// One plain sentence naming what went wrong. An invalidating failure's
    /// sentence is stored verbatim in `LocalMeal.suspectReason`; a repair's goes
    /// into the assumptions note, which is what the user argues with.
    var reason: String {
        switch self {
        case .negativeValue(let nutrient):
            return "\(nutrient.displayName) came back below zero and was set to 0."
        case .caloriesOverCeiling(let value):
            return "\(MealGuardFailure.whole(value)) kcal is beyond what one meal plausibly holds."
        case .proteinOverCeiling(let value):
            return "\(MealGuardFailure.whole(value)) g of protein is beyond what one meal plausibly holds."
        case .sodiumOverCeiling(let value):
            return "\(MealGuardFailure.whole(value)) mg of sodium is beyond what one meal plausibly holds."
        case .macroMismatch(let stated, let implied):
            return "The macros account for \(MealGuardFailure.whole(implied)) kcal but the meal states \(MealGuardFailure.whole(stated)) kcal."
        case .missingPortion(let name):
            return "\(name.isEmpty ? "An item" : name) came back with no portion assumption."
        case .saturatedFatClamped(let from, let to):
            return "Saturated fat (\(MealGuardFailure.oneDecimal(from)) g) exceeded total fat and was clamped to \(MealGuardFailure.oneDecimal(to)) g."
        case .sugarClamped(let from, let to):
            return "Sugar (\(MealGuardFailure.oneDecimal(from)) g) exceeded total carbs and was clamped to \(MealGuardFailure.oneDecimal(to)) g."
        }
    }

    private static func whole(_ value: Double) -> String {
        String(format: "%.0f", value.rounded())
    }

    private static func oneDecimal(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}

/// An estimate after every guard has run over it: the values that will actually
/// be stored, plus the verdict on them (#543).
///
/// Nothing here is ever discarded. A meal that failed a check still carries its
/// items and its numbers, because a user correcting a bad estimate needs to see
/// what was wrong with it, and because the fact that they ate is worth more than
/// the number attached to it.
struct CheckedMealEstimate: Equatable, Sendable {
    var mealType: MealType

    /// Items after clamping. Nutrient totals are the sum of these, always.
    var items: [MealItemEntry]

    /// `MealNutrients.sum(of: items)`, which is the one place a meal's totals
    /// come from at capture time.
    var nutrients: MealNutrients

    var confidence: Double

    /// What the MODEL said it assumed. The repairs are appended to this on the
    /// way to storage — see `storedAssumptionsNote`.
    var assumptionsNote: String?

    /// The model named nothing edible. Saves with the description, zero
    /// nutrients, and a prompt on the row.
    var needsDetail: Bool

    /// Carried through so a later re-check of the same meal exempts it from the
    /// macro consistency rule for the same reason the first one did.
    var containsAlcohol: Bool

    /// Everything the guards found, repairs included. Kept whole: the clamp
    /// message is worth showing even though it does not flag the meal.
    var failures: [MealGuardFailure]

    /// The failures that leave the meal unusable.
    var invalidatingFailures: [MealGuardFailure] {
        failures.filter(\.invalidatesEstimate)
    }

    /// The failures the guards fixed in place.
    var repairs: [MealGuardFailure] {
        failures.filter { !$0.invalidatesEstimate }
    }

    /// A check INVALIDATED the estimate. The meal is stored, pinned above the
    /// day's other rows, and excluded from every total and average until it is
    /// corrected.
    ///
    /// Keys off the invalidating failures alone, not off `failures`. A repaired
    /// meal is a meal whose numbers are now right, and holding it out of the
    /// day would make the total lie.
    var isSuspect: Bool { !invalidatingFailures.isEmpty }

    /// Why the meal is suspect, or nil when it is not. Only ever the
    /// invalidating reasons, which is what `LocalMeal.suspectReason` promises:
    /// that field documents why `isSuspect` is set and is nil when it is not.
    var suspectReason: String? {
        invalidatingFailures.isEmpty
            ? nil
            : invalidatingFailures.map(\.reason).joined(separator: " ")
    }

    /// What the guards adjusted, or nil when they adjusted nothing.
    var repairNote: String? {
        repairs.isEmpty ? nil : repairs.map(\.reason).joined(separator: " ")
    }

    /// The note actually written to `LocalMeal.assumptionsNote`: the repairs
    /// first, then whatever the model said it assumed.
    ///
    /// The assumptions note is where a repair belongs. A clamp IS an assumption
    /// the app made that the user never stated, and that field exists precisely
    /// so a correction has something to argue with. It is also the only field
    /// that can carry it: `suspectReason` is defined as the reason `isSuspect`
    /// is set, and a repaired meal is not suspect.
    ///
    /// Repairs go FIRST because a row shows this note on one line. Whatever is
    /// truncated there should be the model's prose, not the sentence saying a
    /// number was changed.
    var storedAssumptionsNote: String? {
        let parts = [repairNote, assumptionsNote].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The checks run in Swift over whatever the model returned (#543).
///
/// ### Why none of this is in the prompt
///
/// Every rule here could be phrased as an instruction, and some of them are, as
/// a first line of defence. None of them is trusted there. A prompt is graded by
/// the same model whose output is in question, it drifts between model versions,
/// and a rule stated in prose is silently dropped the first time the input is
/// unusual. A check written in Swift either runs or fails to compile.
///
/// ### Why a failure does not discard the estimate
///
/// A failed check means the numbers are wrong, not that the meal did not happen.
/// So the row is written either way: flagged, excluded from totals, and pinned
/// at the top of the day with a one-tap re-estimate. Losing the fact that you
/// ate is worse than losing the number.
enum MealEstimateGuards {

    // MARK: - Bounds

    /// No single meal is 3,000 kcal. A number past this is an estimate that
    /// multiplied something, not a large lunch.
    static let caloriesCeiling: Double = 3000

    /// 250 g of protein is more than a day's intake for almost anyone, let alone
    /// one meal.
    static let proteinCeilingG: Double = 250

    /// 8,000 mg of sodium is roughly four times a whole day's recommended
    /// ceiling.
    static let sodiumCeilingMg: Double = 8000

    /// How far `4P + 4C + 9F` may sit from the stated calories before the
    /// estimate is provably inconsistent with itself.
    ///
    /// 20% rather than something tighter because the Atwater factors are
    /// themselves rounded, fibre is counted differently by different sources,
    /// and sugar alcohols sit outside the model entirely. Under 20% the check
    /// would fire on estimates that are merely approximate, which is every
    /// estimate here by construction.
    static let macroTolerance: Double = 0.20

    // MARK: - Entry point

    /// Run every check over a decoded estimate and return what should be stored.
    ///
    /// - Parameters:
    ///   - estimate: what the model returned.
    ///   - fallbackMealType: the type to use when the model returned none or
    ///     returned one that does not map. The user's picked type, or the one
    ///     inferred from the clock.
    static func check(
        _ estimate: EstimatedMeal,
        fallbackMealType: MealType
    ) -> CheckedMealEstimate {
        let mealType = estimate.mealType
            .flatMap { MealType(rawValue: $0.lowercased()) } ?? fallbackMealType
        let containsAlcohol = estimate.containsAlcohol ?? false
        let note = estimate.assumptions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let assumptions = (note?.isEmpty ?? true) ? nil : note

        // The model could not name a food. Nothing to check: there are no
        // numbers. Save the description with zero nutrients and ask for detail.
        //
        // `needsDetail` and `isSuspect` are deliberately not the same flag.
        // This one wants an answer FROM the user; the other is a warning ABOUT
        // the estimate.
        if estimate.noFoodIdentified == true || estimate.items.isEmpty {
            return CheckedMealEstimate(
                mealType: mealType,
                items: [],
                nutrients: .zero,
                confidence: 0,
                assumptionsNote: assumptions,
                needsDetail: true,
                containsAlcohol: containsAlcohol,
                failures: []
            )
        }

        var failures: [MealGuardFailure] = []
        var items: [MealItemEntry] = []

        for raw in estimate.items {
            let name = (raw.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Unnamed item"

            // A portion assumption that is absent, zero, negative, not a real
            // number, or stated in a unit nothing can scale is no assumption at
            // all. The item is kept so its numbers stay visible; the meal is
            // flagged so the numbers are not counted.
            let unit = (raw.portionUnit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                .lowercased()
            let quantity = raw.portionQuantity ?? 0
            let portionIsUsable = quantity.isFinite
                && quantity > 0
                && Self.scalableUnits.contains(unit)
            if !portionIsUsable {
                failures.append(.missingPortion(itemName: name))
            }

            items.append(
                MealItemEntry(
                    name: name,
                    portionQuantity: portionIsUsable ? quantity : 0,
                    portionUnit: portionIsUsable ? unit : "",
                    calories: raw.calories ?? 0,
                    proteinG: raw.proteinG ?? 0,
                    carbsG:   raw.carbsG ?? 0,
                    fatG:     raw.fatG ?? 0,
                    fibreG:   raw.fibreG ?? 0,
                    sugarG:   raw.sugarG ?? 0,
                    sodiumMg: raw.sodiumMg ?? 0,
                    satFatG:  raw.satFatG ?? 0
                )
            )
        }

        let clamped = clampItems(items)
        items = clamped.items
        failures.append(contentsOf: clamped.failures)

        // The meal's totals ARE the sum of its items at capture time. Every
        // meal-level bound below therefore tests a number no separate field can
        // contradict.
        let totals = MealNutrients.sum(of: items)
        failures.append(contentsOf: boundsFailures(totals: totals))

        if let mismatch = macroConsistency(totals: totals, containsAlcohol: containsAlcohol) {
            failures.append(mismatch)
        }

        return CheckedMealEstimate(
            mealType: mealType,
            items: items,
            nutrients: totals,
            confidence: estimate.numericConfidence,
            assumptionsNote: assumptions,
            needsDetail: false,
            containsAlcohol: containsAlcohol,
            failures: failures
        )
    }

    // MARK: - Individual checks, exposed for the tests that pin them

    /// Clamp every item so no value is negative, no saturated fat exceeds its
    /// own fat, and no sugar exceeds its own carbohydrate.
    ///
    /// Applied PER ITEM rather than to the summed meal, so the meal's totals
    /// satisfy the subset rules by construction: a sum of items that each hold
    /// `satFat <= fat` cannot hold more saturated fat than fat.
    ///
    /// Failures are aggregated, so eight bad items produce one sentence per
    /// KIND rather than eight copies of the same one.
    static func clampItems(_ items: [MealItemEntry]) -> (items: [MealItemEntry], failures: [MealGuardFailure]) {
        var out: [MealItemEntry] = []
        var failures: [MealGuardFailure] = []

        var negativeNutrients: Set<Nutrient> = []
        var satFatFrom: Double = 0
        var satFatTo: Double = 0
        var satFatClamped = false
        var sugarFrom: Double = 0
        var sugarTo: Double = 0
        var sugarClamped = false

        for item in items {
            var values = item.nutrients

            // Hard bound: negative. Clamped to zero rather than dropped, so the
            // row is storable (`MealService` refuses a negative) and the rest of
            // the item survives.
            for nutrient in Nutrient.allCases {
                let value = values[nutrient]
                if !value.isFinite || value < 0 {
                    negativeNutrients.insert(nutrient)
                    values[nutrient] = 0
                }
            }

            // Subset rule: saturated fat is a PART of fat, so it cannot exceed
            // it. Clamp and flag rather than reject: the excess is provably
            // wrong, the remainder is probably right, and clamping makes the
            // item internally consistent.
            if values.satFatG > values.fatG {
                satFatClamped = true
                satFatFrom += values.satFatG
                satFatTo += values.fatG
                values.satFatG = values.fatG
            }

            // Subset rule: sugar is a PART of carbohydrate.
            if values.sugarG > values.carbsG {
                sugarClamped = true
                sugarFrom += values.sugarG
                sugarTo += values.carbsG
                values.sugarG = values.carbsG
            }

            var clamped = item
            clamped.calories = values.calories
            clamped.proteinG = values.proteinG
            clamped.carbsG   = values.carbsG
            clamped.fatG     = values.fatG
            clamped.fibreG   = values.fibreG
            clamped.sugarG   = values.sugarG
            clamped.sodiumMg = values.sodiumMg
            clamped.satFatG  = values.satFatG
            out.append(clamped)
        }

        // Ordered by `Nutrient.allCases` so the sentence is stable across runs
        // and a snapshot of it can be asserted.
        for nutrient in Nutrient.allCases where negativeNutrients.contains(nutrient) {
            failures.append(.negativeValue(nutrient))
        }
        if satFatClamped {
            failures.append(.saturatedFatClamped(from: satFatFrom, to: satFatTo))
        }
        if sugarClamped {
            failures.append(.sugarClamped(from: sugarFrom, to: sugarTo))
        }
        return (out, failures)
    }

    /// The three hard bounds, read off a meal's totals.
    static func boundsFailures(totals: MealNutrients) -> [MealGuardFailure] {
        var failures: [MealGuardFailure] = []
        if totals.calories > caloriesCeiling {
            failures.append(.caloriesOverCeiling(totals.calories))
        }
        if totals.proteinG > proteinCeilingG {
            failures.append(.proteinOverCeiling(totals.proteinG))
        }
        if totals.sodiumMg > sodiumCeilingMg {
            failures.append(.sodiumOverCeiling(totals.sodiumMg))
        }
        return failures
    }

    /// Re-check a meal whose items the USER has just edited by hand.
    ///
    /// Runs the clamps, the hard bounds AND the macro consistency check.
    ///
    /// ### Why the consistency check runs here now (#555)
    ///
    /// It did not before, and the reason was the alcohol flag. That flag
    /// arrived on the estimate and was never stored, so this path could not
    /// tell a beer from a broken estimate: the only two options were to guess
    /// the flag back from the numbers, which reads every legitimately exempt
    /// meal as a failure the moment a portion moves, or to skip the check.
    /// `LocalMeal.containsAlcohol` removes that fork. The caller reads the
    /// stored flag and passes it, so the exemption is decided by the same fact
    /// that decided it the first time.
    ///
    /// The check is worth having back. It is the only one in the set that can
    /// prove a number wrong without knowing anything about the food, and a
    /// hand-typed number is not exempt from arithmetic: a portion halved in the
    /// grams field and left alone in the calories field is exactly the slip it
    /// catches.
    ///
    /// - Parameter containsAlcohol: `LocalMeal.containsAlcohol` for the meal
    ///   being re-checked. True exempts it from the consistency check, for the
    ///   reason spelled out on `macroConsistency`.
    static func recheckHandEdited(
        items: [MealItemEntry],
        containsAlcohol: Bool
    ) -> (items: [MealItemEntry], totals: MealNutrients, failures: [MealGuardFailure]) {
        let clamped = clampItems(items)
        let totals = MealNutrients.sum(of: clamped.items)
        var failures = clamped.failures + boundsFailures(totals: totals)
        if let mismatch = macroConsistency(totals: totals, containsAlcohol: containsAlcohol) {
            failures.append(mismatch)
        }
        return (clamped.items, totals, failures)
    }

    /// Portion units a correction can scale by a ratio.
    ///
    /// Deliberately only two. "1 bowl" cannot be halved by anything, so an
    /// estimate stated in bowls is not correctable, which is the whole point of
    /// storing the assumption.
    static let scalableUnits: Set<String> = ["g", "ml"]

    /// `4P + 4C + 9F` against the stated calories.
    ///
    /// Returns nil when the check passes, when the meal has no calories to
    /// compare against, or when the meal contains alcohol.
    ///
    /// **The alcohol exemption is not optional.** Ethanol carries about 7 kcal
    /// per gram and is not protein, carbohydrate or fat, so it appears in the
    /// stated calories and in none of the three terms. A 330 ml beer is roughly
    /// 140 kcal of which about 100 is alcohol: the macros imply 40 and the meal
    /// states 140, a 71% miss. Without this exemption the single highest-value
    /// check in the set fires on every beer, and a check that cries wolf is one
    /// nobody reads.
    static func macroConsistency(
        totals: MealNutrients,
        containsAlcohol: Bool
    ) -> MealGuardFailure? {
        guard !containsAlcohol else { return nil }
        guard totals.calories > 0 else { return nil }

        let implied = 4 * totals.proteinG + 4 * totals.carbsG + 9 * totals.fatG
        let drift = abs(implied - totals.calories) / totals.calories
        guard drift > macroTolerance else { return nil }
        return .macroMismatch(stated: totals.calories, impliedByMacros: implied)
    }
}
