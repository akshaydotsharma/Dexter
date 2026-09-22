import Foundation

/// One dish inside a logged meal (#542).
///
/// Stored as JSON inside `LocalMeal.itemsData`, the same shape decision
/// `ExpenseSplitEntry` / `LocalExpense.splitsData` and `VisionItem` /
/// `LocalVisionBlock.notesData` already make: SwiftData on iOS 17.0 will not
/// persist an array without a custom transformer, and a blob with a computed
/// accessor is the pattern this codebase trusts. It also means an item can gain
/// a field without a schema migration on a live store.
///
/// ### Why an item carries its own eight values
///
/// The meal's eight totals are not a derived sum that can be recomputed on
/// demand, because the split across items is a guess: "chicken rice and a teh
/// tarik" is one description that an estimate breaks into two dishes, and the
/// user can correct one of them without re-estimating the other. Keeping each
/// item's own numbers is what makes "the rice was actually double" a local
/// edit. The meal's totals stay the stored truth for every roll-up, so a
/// display never has to sum items to draw a day.
///
/// ### Why the portion is a number and a unit, not a string
///
/// The portion is an ASSUMPTION the estimate made ("1 bowl", "250 g"), and it is
/// the single most common thing a user corrects. Splitting it into a quantity
/// and a unit means a correction can scale the item's eight values by a ratio
/// rather than asking for a fresh estimate. A free-text "about a bowl and a
/// bit" cannot be scaled by anything.
struct MealItemEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Stable id for a list row and for an editor's selection. Minted on
    /// creation and carried through the JSON, so re-decoding a meal does not
    /// reshuffle identity under an open editor.
    let id: UUID

    /// The dish as named by the estimate, e.g. "Hainanese chicken rice".
    var name: String

    /// How much of it was assumed. Paired with `portionUnit`; never a string.
    var portionQuantity: Double

    /// The unit `portionQuantity` is in, verbatim as the estimate stated it
    /// ("bowl", "g", "slice", "cup"). Free text on purpose: a closed unit enum
    /// would force every real-world portion through a vocabulary that does not
    /// fit it, and nothing computes on the unit except the scaling ratio, which
    /// only needs the unit to stay the same between the two sides.
    var portionUnit: String

    /// This item's own share of the eight. Units per `Nutrient.unit`: kcal for
    /// calories, mg for sodium, grams for the rest.
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fibreG: Double
    var sugarG: Double
    var sodiumMg: Double
    var satFatG: Double

    /// Where the per-100 figures behind this item came from (#653), or nil for
    /// an item written before provenance existed.
    ///
    /// Nil is not "estimated". It is "this item predates the question", and the
    /// two must stay distinguishable: `MealEstimateGuards` falls back to the
    /// model's self-reported band for a meal whose items carry no provenance,
    /// and would wrongly grade every old meal as a guess if nil read as
    /// `estimated`.
    var densitySource: MealDensitySource?

    /// Where the PORTION came from (#653). Nil has the same meaning as above.
    ///
    /// Held apart from `densitySource` because the two unknowns are
    /// independent and one of them dominates the error. A meal can have a
    /// laboratory-grade composition and a portion somebody guessed, and calling
    /// that "sourced" would be the exact conflation this change undoes.
    var massSource: MealMassSource?

    /// The id of the record the density was read from, namespaced by source:
    /// `fdc:2706437`, `saved:<uuid>`.
    ///
    /// Stored so a figure can be traced back, and so a later re-check can ask
    /// the same source rather than starting again. Only ever set by the device,
    /// never trusted from the model: see `FoodLookupResolution`.
    var sourceID: String?

    init(
        id: UUID = UUID(),
        name: String,
        portionQuantity: Double = 1,
        portionUnit: String = "serving",
        calories: Double = 0,
        proteinG: Double = 0,
        carbsG: Double = 0,
        fatG: Double = 0,
        fibreG: Double = 0,
        sugarG: Double = 0,
        sodiumMg: Double = 0,
        satFatG: Double = 0,
        densitySource: MealDensitySource? = nil,
        massSource: MealMassSource? = nil,
        sourceID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.portionQuantity = portionQuantity
        self.portionUnit = portionUnit
        self.calories = calories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fibreG = fibreG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.satFatG = satFatG
        self.densitySource = densitySource
        self.massSource = massSource
        self.sourceID = sourceID
    }

    /// Decode tolerantly: an item written by a build that did not mint ids, or
    /// one hand-authored in a fixture, still reads rather than failing the whole
    /// meal. A missing id means a new one, which is correct for a value that
    /// only ever identifies a row within one decoded array.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        portionQuantity = try container.decodeIfPresent(Double.self, forKey: .portionQuantity) ?? 1
        portionUnit = try container.decodeIfPresent(String.self, forKey: .portionUnit) ?? "serving"
        calories = try container.decodeIfPresent(Double.self, forKey: .calories) ?? 0
        proteinG = try container.decodeIfPresent(Double.self, forKey: .proteinG) ?? 0
        carbsG = try container.decodeIfPresent(Double.self, forKey: .carbsG) ?? 0
        fatG = try container.decodeIfPresent(Double.self, forKey: .fatG) ?? 0
        fibreG = try container.decodeIfPresent(Double.self, forKey: .fibreG) ?? 0
        sugarG = try container.decodeIfPresent(Double.self, forKey: .sugarG) ?? 0
        sodiumMg = try container.decodeIfPresent(Double.self, forKey: .sodiumMg) ?? 0
        satFatG = try container.decodeIfPresent(Double.self, forKey: .satFatG) ?? 0
        // Additive and optional, so every meal written before #653 decodes
        // unchanged. The items are stored as a JSON blob rather than as rows,
        // so this is not a SwiftData migration and carries none of that risk.
        densitySource = try container.decodeIfPresent(MealDensitySource.self, forKey: .densitySource)
        massSource = try container.decodeIfPresent(MealMassSource.self, forKey: .massSource)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
    }

    /// The portion as one readable phrase, e.g. "1 bowl" or "250 g". Whole
    /// numbers print without a decimal point, because "1.0 bowl" reads as a
    /// measurement nobody made.
    var portionDescription: String {
        let quantity = portionQuantity.rounded() == portionQuantity
            ? String(Int(portionQuantity))
            : String(format: "%.1f", portionQuantity)
        return portionUnit.isEmpty ? quantity : "\(quantity) \(portionUnit)"
    }

    /// This item's value for one nutrient. The one accessor every bar, verdict
    /// and callout reads, so a surface never has to switch on eight fields.
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

// MARK: - Provenance (#653)

/// Where an item's per-100 composition came from.
///
/// The point of this enum is that four things that all produce eight numbers
/// are not the same claim. A laboratory analysis, a brand's printed panel, a
/// row the user has eaten before, and a model's recollection all arrive in the
/// same shape and deserve different amounts of trust. Before #653 they were
/// indistinguishable once stored.
///
/// A raw-value enum rather than a plain string, unlike `MealSource` and
/// `FoodItemSource`, because this one is NOT written by paths that keep
/// arriving: it is written in exactly one place, by the device, after checking
/// the claim. An unknown value decoded here would mean a bug, not a new
/// feature.
enum MealDensitySource: String, Codable, Sendable, CaseIterable {

    /// Read from a public food-composition database the device looked up in
    /// this turn, and the id was checked against what the device actually
    /// offered. See `FoodLookupResolution`.
    case lookedUp = "looked_up"

    /// Taken from a row in the user's own saved library, which is either a
    /// transcribed packet or a figure they have already accepted (#625).
    case saved

    /// Read from a brand's own published nutrition, found by web search (#594).
    case published

    /// The model's own figure. Honest, and the weakest of the four.
    case estimated

    /// Whether this source is something other than the model's memory.
    ///
    /// The one question confidence turns on, asked in one place so no caller
    /// has to enumerate the cases and miss one when a fifth arrives.
    var isSourced: Bool { self != .estimated }

    /// How the app says it in a sentence.
    var displayName: String {
        switch self {
        case .lookedUp:  return "food database"
        case .saved:     return "your saved item"
        case .published: return "published panel"
        case .estimated: return "estimated"
        }
    }
}

/// Where an item's PORTION came from.
///
/// There are only four honest answers to "how much of it was there", and this
/// enum is the list. Everything else — a plausible restaurant serving, a
/// photograph with nothing in frame to judge scale against, a model's sense of
/// a typical bowl — is `estimated`, however confident it sounds.
///
/// This is the half that decides the error. A composite dish's composition
/// varies 10 to 25% between sources; a restaurant portion varies by a factor of
/// two.
enum MealMassSource: String, Codable, Sendable, CaseIterable {

    /// The user said it: "250 g chicken curry", "a 330 ml can".
    case stated

    /// A packet's serving size, or a chain's published serving weight.
    case publishedServing = "published_serving"

    /// A standard portion weight from a composition database's own portion
    /// table, e.g. FNDDS "1 cup = 240 g".
    case standardPortion = "standard_portion"

    /// A portion this user accepted for this dish before.
    case history

    /// A guess. The default, and the thing this feature exists to make rare.
    case estimated

    var isSourced: Bool { self != .estimated }

    var displayName: String {
        switch self {
        case .stated:           return "you stated it"
        case .publishedServing: return "published serving"
        case .standardPortion:  return "standard portion"
        case .history:          return "your usual portion"
        case .estimated:        return "estimated"
        }
    }
}

extension MealItemEntry {

    /// This item's provenance score: how many of the two unknowns were answered
    /// by something other than the model's memory.
    ///
    /// Nil when the item predates provenance, which is a different state from
    /// zero and must not be graded as one.
    var provenanceScore: Int? {
        guard let densitySource, let massSource else { return nil }
        return (densitySource.isSourced ? 1 : 0) + (massSource.isSourced ? 1 : 0)
    }
}
