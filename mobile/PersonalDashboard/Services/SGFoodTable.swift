import Foundation

/// The Singapore dishes, shipped with the app (#653).
///
/// ### Why this table exists
///
/// USDA FoodData Central does not hold Singapore food, and the way it fails is
/// the dangerous way. Searching "hainanese chicken rice" there does not come
/// back empty; it comes back with five confident wrong answers led by "Chicken
/// curry with rice", each with a real id and a real nutrient profile. A lookup
/// that returns the wrong dish is worse than one that returns nothing, because
/// the number it produces carries a citation.
///
/// The Health Promotion Board publishes the real dishes, with a real local
/// serving weight and, for many rows, laboratory analysis rather than a survey
/// average. Roasted chicken rice: 178 kcal per 100 g, one plate 363 g.
///
/// ### Why it is shipped rather than called
///
/// The data is static, the whole set is a couple of thousand rows, and the app
/// is a personal food log that should not need a network round trip to price a
/// plate of chicken rice. `mobile/scripts/build-sg-food-table.py` reads the
/// service ONCE, at build time, and writes the asset this type loads. The
/// running app never talks to HPB.
///
/// ### The sentinel that would have poisoned the table
///
/// HPB states an unanalysed nutrient as `-1`, not as null. Shipping that would
/// have put negative grams into meals, and the guards would have clamped them
/// to zero and flagged perfectly good dishes as suspect. The build script maps
/// `-1` and null alike into a `missing` list, and the nutrient reads zero with
/// its absence recorded — the same distinction `FoodDataCentralFood`
/// draws, and the same one Open Food Facts' sodium-in-grams trap taught in
/// #625.
struct SGFoodTable: Sendable {

    /// One dish.
    struct Dish: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let description: String
        let category: String
        let subCategory: String
        let source: String
        let year: Int?
        let per100: Nutrients
        let missing: [String]?
        let portionGrams: Double?
        let portionLabel: String?

        struct Nutrients: Decodable, Sendable, Equatable {
            let calories: Double
            let proteinG: Double
            let carbsG: Double
            let fatG: Double
            let fibreG: Double
            let sugarG: Double
            let sodiumMg: Double
            let satFatG: Double

            var value: MealNutrients {
                MealNutrients(
                    calories: calories, proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                    fibreG: fibreG, sugarG: sugarG, sodiumMg: sodiumMg, satFatG: satFatG
                )
            }
        }

        /// The dish as a lookup candidate.
        ///
        /// The portion label is cleaned up on the way through: HPB writes
        /// "1 plate(s) = 363g", which already contains the weight this app
        /// prints beside it, so the duplicate is stripped and the plural
        /// bracket with it.
        var candidate: FoodLookupCandidate {
            // Built in steps rather than as one expression. Swift's type
            // checker gives up on the inline version ("unable to type-check
            // this expression in reasonable time"), which is what a chain of
            // string concatenation, an optional map and an array literal costs.
            var provenance = "Health Promotion Board Singapore"
            if !source.isEmpty { provenance += ", " + source.lowercased() }
            if let year { provenance += ", " + String(year) }

            var portions: [FoodDataCentralPortion] = []
            if let grams = portionGrams, grams > 0 {
                let label: String = Dish.tidy(portionLabel) ?? "1 serving"
                portions = [FoodDataCentralPortion(description: label, gramWeight: grams)]
            }

            let absent: [Nutrient] = (missing ?? []).compactMap(Dish.nutrient(named:))

            return FoodLookupCandidate(
                id: "sg:" + id,
                name: name,
                provenance: provenance,
                nutrientsPer100: per100.value,
                missingNutrients: absent,
                portions: portions,
                density: .lookedUp
            )
        }

        static func tidy(_ label: String?) -> String? {
            guard var out = label?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else {
                return nil
            }
            if let equals = out.firstIndex(of: "=") {
                out = String(out[out.startIndex..<equals])
            }
            out = out.replacingOccurrences(of: "(s)", with: "")
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? nil : out
        }

        /// The build script writes this app's own nutrient key names, so the
        /// mapping is by `MealItemEntry`'s spelling rather than by `Nutrient`'s
        /// raw value.
        static func nutrient(named key: String) -> Nutrient? {
            switch key {
            case "calories": return .calories
            case "proteinG": return .protein
            case "carbsG":   return .carbs
            case "fatG":     return .fat
            case "fibreG":   return .fibre
            case "sugarG":   return .sugar
            case "sodiumMg": return .sodium
            case "satFatG":  return .saturatedFat
            default:         return nil
            }
        }
    }

    private struct Payload: Decodable {
        let source: String
        let retrieved: String
        let entries: [Dish]
    }

    let dishes: [Dish]

    /// Lowercased haystacks, built once. A search runs over every row, and
    /// re-lowercasing two thousand names on every keystroke of a three-dish
    /// meal is work nobody needs to repeat.
    private let haystacks: [String]

    /// Word sets, precomputed for the same reason `haystacks` is: a search runs
    /// over every row, and re-splitting two thousand names per query word is
    /// work nobody needs to repeat.
    private let nameWords: [Set<String>]
    private let haystackWords: [Set<String>]

    init(dishes: [Dish]) {
        self.dishes = dishes
        self.haystacks = dishes.map { "\($0.name) \($0.description)".lowercased() }
        self.nameWords = dishes.map { Set(SGFoodTable.words(in: $0.name)) }
        self.haystackWords = dishes.map {
            Set(SGFoodTable.words(in: "\($0.name) \($0.description)"))
        }
    }

    /// The shipped table, loaded once.
    ///
    /// A missing or unreadable asset yields an EMPTY table rather than a crash
    /// or a fatal error. The lookup then behaves exactly as it did before this
    /// file existed, which is the right failure for an additive data source: a
    /// meal must not be lost because a bundle resource did not copy.
    static let shared: SGFoodTable = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return SGFoodTable(dishes: [])
        }
        return SGFoodTable(dishes: payload.entries)
    }()

    static let resourceName = "sg-food-table"

    var isEmpty: Bool { dishes.isEmpty }

    /// How many candidates one query returns from here.
    ///
    /// Two, against FoodData Central's three, because this table is narrower
    /// and better targeted: when it has the dish at all it usually has it
    /// exactly, and a third near-miss from a small table is noise.
    static let resultLimit = 2

    /// Dishes matching a query, best first.
    ///
    /// Scored rather than filtered, because a Singapore dish has several names
    /// and the model writes a generic description. "poached chicken with rice"
    /// has to reach "Hainanese chicken rice", and it does so on the words they
    /// share.
    ///
    /// ### Two things measured against the real table, each of which broke a
    /// simpler version of this
    ///
    /// 1. **Word boundaries.** Matching a query word as a raw substring makes
    ///    "mala" match "Malay", and the table holds dozens of Malay dishes. A
    ///    query for mala noodles would have surfaced nasi lemak. Words are
    ///    matched at boundaries.
    ///
    /// 2. **Local spellings.** HPB writes "Nasi briyani"; everybody else, and
    ///    every model, writes "biryani". One transposition, and a whole family
    ///    of dishes invisible. Words of six characters or more therefore also
    ///    match at an edit distance of one, scored below an exact hit. Six is
    ///    the floor because at four characters an edit of one turns "rice" into
    ///    "rick" and "mala" into "male".
    ///
    /// Beyond that the scoring stays crude on purpose: whole-phrase beats word,
    /// name beats description, more words beat fewer. Anything cleverer would
    /// be a ranking function pretending to answer the question the model is
    /// there to answer, which is whether this row IS the dish.
    func search(_ query: String) -> [FoodLookupCandidate] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !dishes.isEmpty else { return [] }

        let words = Self.words(in: needle).filter { $0.count > 2 }
        guard !words.isEmpty || needle.count > 2 else { return [] }

        var scored: [(score: Int, index: Int)] = []
        for index in dishes.indices {
            let score = self.score(index: index, needle: needle, words: words)
            guard score >= Self.threshold else { continue }
            scored.append((score, index))
        }

        let ranked: [(score: Int, index: Int)] = scored.sorted { a, b in
            a.score == b.score ? a.index < b.index : a.score > b.score
        }
        return ranked.prefix(Self.resultLimit).map { dishes[$0.index].candidate }
    }

    /// The lowest score that counts as a match: one whole word shared with the
    /// dish's NAME. One shared word with a description is a coincidence.
    static let threshold = 6

    private func score(index: Int, needle: String, words: [String]) -> Int {
        let name = nameWords[index]
        let hay = haystackWords[index]
        let nameText = dishes[index].name.lowercased()

        var score = 0
        if nameText == needle { score += 100 }
        else if nameText.contains(needle) { score += 50 }
        else if haystacks[index].contains(needle) { score += 25 }

        for word in words {
            if name.contains(word) { score += 6 }
            else if hay.contains(word) { score += 2 }
            else if word.count >= Self.fuzzyFloor {
                // A local spelling, one edit away. Scored below an exact word
                // so a real hit always outranks a near one.
                if name.contains(where: { Self.withinOneEdit($0, word) }) { score += 4 }
                else if hay.contains(where: { Self.withinOneEdit($0, word) }) { score += 1 }
            }
        }
        return score
    }

    /// Shortest word length eligible for a one-edit match. See `search`.
    static let fuzzyFloor = 6

    static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// True when two words are the same, or one insertion, deletion or
    /// substitution apart.
    ///
    /// Hand-rolled rather than a full edit-distance matrix because only a
    /// distance of ONE is ever asked about, and the single-edit test is a
    /// linear scan. It runs across two thousand rows per query word.
    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }

        // A transposition ("briyani" / "biryani") is two substitutions, which
        // this deliberately does NOT accept on its own; it is caught because
        // the two words also differ by one substitution in most real cases.
        // Kept simple: equal lengths compare position by position.
        if x.count == y.count {
            var differences = 0
            for i in x.indices where x[i] != y[i] {
                differences += 1
                if differences > 1 {
                    // Allow a single adjacent transposition, which is what a
                    // transliteration difference usually is.
                    return differences == 2 && Self.isSingleTransposition(x, y)
                }
            }
            return true
        }

        let (longer, shorter) = x.count > y.count ? (x, y) : (y, x)
        var i = 0, j = 0, skipped = false
        while i < longer.count && j < shorter.count {
            if longer[i] == shorter[j] {
                i += 1; j += 1
            } else {
                if skipped { return false }
                skipped = true
                i += 1
            }
        }
        return true
    }

    /// Two equal-length words differing only by one adjacent swap.
    static func isSingleTransposition(_ x: [Character], _ y: [Character]) -> Bool {
        let differing = x.indices.filter { x[$0] != y[$0] }
        guard differing.count == 2 else { return false }
        let (i, j) = (differing[0], differing[1])
        guard j == i + 1 else { return false }
        return x[i] == y[j] && x[j] == y[i]
    }
}
