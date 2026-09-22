import Foundation

/// A read-only window onto USDA FoodData Central, the food composition database
/// the meal estimator looks things up in instead of remembering them (#653).
///
/// ### Why a second public database, when Open Food Facts is already here
///
/// They answer different questions, and the meal log needs both.
///
/// Open Food Facts holds the back of a PACKET, keyed by the barcode on the
/// front (#625). It is the right source for a protein wafer and a yogurt pouch.
/// It has nothing to say about a plate of biryani, because nobody prints a
/// panel on a plate.
///
/// FoodData Central's FNDDS dataset holds COMPOSITE DISHES AS EATEN: "Chicken
/// curry", "Biryani with vegetables", "Bread, paratha", each with a full
/// nutrient profile per 100 g. That is the granularity a meal description
/// actually arrives at, and it is the half of the estimate the model currently
/// answers from memory.
///
/// ### The half nobody else answers: how much
///
/// A meal's numbers are the sum of `mass x density` over its items, and the two
/// unknowns are independent. Every database above answers density. Measured
/// over the meals logged in the week to 2026-09-21, mass is the bigger error by
/// a wide margin: a composite dish's density varies 10 to 25% between sources,
/// while a restaurant portion varies by a factor of two.
///
/// FNDDS is the only free source here that answers mass. Each food carries a
/// portion table of household measures and their gram weights, including a
/// "Quantity not specified" row that is the dataset's own default serving.
/// Measured live on 2026-09-22:
///
///     Chicken curry                1 cup -> 240 g, unspecified -> 240 g
///     Biryani with vegetables      1 cup -> 172 g, unspecified -> 215 g
///
/// That is what turns "a cup of dal" and "a plate of biryani" into a number
/// nobody invented. See `FoodDataCentralPortion`.
///
/// ### Search relevance is weak, and the caller must know it
///
/// ⚠️ This is the one thing that will surprise anybody wiring this up. FDC's
/// free-text search matches tokens, not dishes. Measured on 2026-09-22:
///
///     "chicken curry"             -> Chicken curry                     (455 hits)
///     "biryani"                   -> Biryani with vegetables            (39 hits)
///     "paratha"                   -> Bread, paratha                      (1 hit)
///     "khao soi"                  -> Soy chips        ← soi matched soy
///     "hainanese chicken rice"    -> nothing
///     "dal"                       -> nothing
///
/// The data for two of those three misses is in the dataset under a generic
/// description. So the query must be a NORMALISED GENERIC FOOD TERM, not the
/// words the user typed, and a miss is worth one retry with a broader term.
/// Choosing that term is a language job, which is why this client is reached
/// through a tool the model calls rather than through a direct lookup on the
/// description.
///
/// ### The key
///
/// Unlike Open Food Facts this needs one, free from
/// https://fdc.nal.usda.gov/api-key-signup with an email and nothing else.
/// `DEMO_KEY` allows 30 requests an hour and was exhausted inside one
/// investigation; a real key allows 1,000. With no key configured every call
/// throws `notConfigured` and the estimator falls back to the model's own
/// numbers, which is exactly how it behaved before this file existed.
///
/// ### Shape
///
/// A plain struct with one injected `URLSession` and no stored state, so it is
/// `Sendable` by construction. Modelled on `OpenFoodFactsClient` deliberately:
/// two food-database clients that behave differently under cancellation and
/// retry would be two things to remember instead of one.
struct FoodDataCentralClient: Sendable {

    // MARK: - The wire

    static let searchURL = "https://api.nal.usda.gov/fdc/v1/foods/search"

    /// One food by its `fdcId`. The id is appended.
    ///
    /// This is the ONLY endpoint that carries `foodPortions`. The search
    /// response does not, whatever page size it is asked for, so resolving a
    /// mass always costs a second call. See `food(id:)`.
    static let detailURLPrefix = "https://api.nal.usda.gov/fdc/v1/food/"

    /// How many hits one search RETURNS to the caller.
    ///
    /// Five rather than the picker's twenty, because nothing here is a list a
    /// person scrolls. The consumer is a model choosing one row, and every row
    /// it is shown costs context on a call that is already carrying the day's
    /// meals. The right hit is first or it is not in the page.
    static let pageSize = 5

    /// How many hits are ASKED FOR on the wire, before the dataset filter.
    ///
    /// ── MEASURED, not defensive ─────────────────────────────────────────────
    ///
    /// This client does not send `dataType` at all, and that is not an
    /// oversight. Sending `dataType=Survey (FNDDS)` makes the API answer HTTP
    /// 400 from its fronting nginx — an HTML page, not a JSON error — for
    /// roughly three requests in five. Ten identical requests per variant on
    /// 2026-09-22, with the key valid throughout:
    ///
    ///     dataType=Survey (FNDDS)   400 200 400 400 200 400 400 200 400 200
    ///     dataType=Foundation       200 200 200 200 200 200 200 200 200 200
    ///     dataType=SR Legacy        200 200 200 200 200 200 200 200 200 200
    ///     dataType=Branded          200 200 200 200 200 200 200 200 200 200
    ///     no dataType               200 200 200 200 200 200 200 200 200 200
    ///
    /// The discriminator is the PARENTHESES. `SR Legacy` carries a space and is
    /// clean, so it is not the space; percent-encoding the parens as `%28`
    /// `%29` fails at the same rate, so it is not the encoding either. It reads
    /// as a request-filtering rule present on some nodes of a load-balanced
    /// fleet and not others, which is why it is intermittent rather than flat.
    ///
    /// It cost two live test runs to find, because at three in five a single
    /// probe "works" often enough to look like something else is wrong.
    ///
    /// So the filter moves to the device: ask for a wider page unfiltered, keep
    /// the rows whose `dataType` the caller wanted, and hand back the first
    /// `pageSize` of those. Relevance order is untouched. The cost is a larger
    /// response on a call that is already sub-second, which is a good trade for
    /// removing a three-in-five failure.
    static let wirePageSize = 25

    /// The ceiling on one request.
    ///
    /// ⚠️ Set on the SESSION CONFIGURATION as well as on the request, and the
    /// two must agree. A session's `timeoutIntervalForRequest` CAPS whatever an
    /// individual `URLRequest` asks for, so a 15 s request on a 60 s shared
    /// session is a 60 s timeout with a misleading line in front of it. #594
    /// lost hours to exactly that.
    static let timeout: TimeInterval = 15

    /// The session every real call runs on, for the capping reason above.
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = FoodDataCentralClient.timeout
        config.timeoutIntervalForResource = FoodDataCentralClient.timeout * 2
        return URLSession(configuration: config)
    }()

    let session: URLSession

    /// The key, resolved once per instance so a test can inject one without
    /// touching `AppConfig` or the environment.
    let apiKey: String?

    init(
        session: URLSession = FoodDataCentralClient.defaultSession,
        apiKey: String? = AppConfig.usdaFDCAPIKey
    ) {
        self.session = session
        self.apiKey = apiKey
    }

    /// True when a key is configured at all. Callers check this to decide
    /// whether to advertise the lookup tool to the model, rather than
    /// advertising a tool whose every call will fail.
    var isConfigured: Bool {
        !(apiKey?.isEmpty ?? true)
    }

    // MARK: - Search

    /// Foods matching free text, best match first, at most `pageSize`.
    ///
    /// Read the relevance warning in the type comment before calling this with
    /// anything a user typed. `query` should be a generic food description.
    ///
    /// An empty query returns no hits rather than throwing.
    ///
    /// - Parameter kinds: which datasets to search. The default puts composite
    ///   dishes first because that is the shape a meal description arrives in;
    ///   a caller looking for a raw ingredient can narrow it.
    func search(
        _ query: String,
        kinds: [FoodDataCentralDataType] = FoodDataCentralDataType.defaultOrder
    ) async throws -> [FoodDataCentralFood] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let key = apiKey, !key.isEmpty else { throw FoodDataCentralError.notConfigured }

        var components = URLComponents(string: Self.searchURL)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "pageSize", value: String(Self.wirePageSize))
        ]
        guard let url = components?.url else { throw FoodDataCentralError.badRequest }

        let data = try await fetch(url)
        let rows: [FoodDataCentralFood]
        do {
            rows = try JSONDecoder()
                .decode(FoodDataCentralSearchResponse.self, from: data)
                .foods
                .map(\.food)
        } catch {
            throw FoodDataCentralError.malformed
        }

        // Filtered here rather than by the API — see `wirePageSize`. Relevance
        // order is the API's and is preserved; this only removes rows from
        // datasets the caller did not ask for.
        let wanted = Set(kinds)
        return rows
            .filter { $0.dataType.map(wanted.contains) ?? false }
            .prefix(Self.pageSize)
            .map { $0 }
    }

    // MARK: - Detail

    /// One food by `fdcId`, WITH its portion table, or nil when the id names
    /// nothing.
    ///
    /// The second call is not avoidable and not an oversight. The search
    /// response carries nutrients and no `foodPortions` at any page size, and
    /// the portion table is the whole reason this database is here. A caller
    /// that only needs density can stop at `search`.
    func food(id: Int) async throws -> FoodDataCentralFood? {
        guard let key = apiKey, !key.isEmpty else { throw FoodDataCentralError.notConfigured }

        var components = URLComponents(string: Self.detailURLPrefix + String(id))
        components?.queryItems = [URLQueryItem(name: "api_key", value: key)]
        guard let url = components?.url else { throw FoodDataCentralError.badRequest }

        let data: Data
        do {
            data = try await fetch(url)
        } catch FoodDataCentralError.notFound {
            return nil
        }
        do {
            return try JSONDecoder()
                .decode(FoodDataCentralDetail.self, from: data)
                .food
        } catch {
            throw FoodDataCentralError.malformed
        }
    }

    /// Fetch the portion table for a food somebody has ALREADY CHOSEN.
    ///
    /// ### Why there is no "search and take the best hit" helper
    ///
    /// There was one, and a live test killed it on 2026-09-22. Searching
    /// "hainanese chicken rice" does not come back empty, which is what the
    /// earlier measurement suggested. It comes back with five confident wrong
    /// answers:
    ///
    ///     Chicken curry with rice
    ///     Rice, fried, with chicken
    ///     Babyfood, dinner, chicken and rice
    ///     Burrito bowl, chicken, with rice
    ///     Burrito, chicken, with rice, cheese
    ///
    /// A helper that takes `.first` of that would have priced a plate of
    /// Hainanese chicken rice as a chicken curry, from a named database, and
    /// the provenance would have said the number was looked up rather than
    /// guessed. That is a worse failure than the guess this whole change is
    /// replacing: it invites more trust and gives the user nothing to check it
    /// against. It is the same defect as a recalled figure dressed up as a
    /// published one, which `MealToolSchema.brandLookupRule` already warns
    /// about in prose.
    ///
    /// So choosing among the candidates is not this client's decision to make.
    /// `search` returns them and the model picks one, having been shown each
    /// description, because "is `Chicken curry with rice` the same dish as
    /// Hainanese chicken rice" is a language question and not a ranking one.
    /// This method is the step AFTER that choice.
    ///
    /// Returns `food` unchanged when the detail call fails. The density is
    /// still worth having: it prices a portion the user stated themselves, it
    /// just cannot offer a standard one.
    func withPortions(_ food: FoodDataCentralFood) async -> FoodDataCentralFood {
        guard let detailed = try? await self.food(id: food.fdcID) else { return food }
        return detailed
    }

    // MARK: - One request

    /// Run one GET and hand back the body.
    ///
    /// Cancellation is normalised to `CancellationError` for the reason
    /// `OpenFoodFactsClient.fetch(_:)` spells out: a superseded lookup is not a
    /// failure and must not read like one at the call site.
    private func fetch(_ url: URL) async throws -> Data {
        var delay = Self.retryDelays.makeIterator()
        while true {
            do {
                return try await fetchOnce(url)
            } catch FoodDataCentralError.unavailable {
                guard let pause = delay.next() else { throw FoodDataCentralError.unavailable }
                try await Task.sleep(nanoseconds: pause)
            }
        }
    }

    /// How long to wait before each retry, and therefore how many there are.
    ///
    /// Shorter and fewer than the Open Food Facts ladder, because the failure
    /// being retried is different. Open Food Facts flaps 503 on roughly one
    /// request in three and a retry is the normal path. FDC is stable; what it
    /// does instead is answer 429 when the hourly allowance runs out, and an
    /// allowance does not refill in 1.7 seconds. Two quick attempts cover a
    /// transient 5xx and then give up honestly.
    private static let retryDelays: [UInt64] = [400_000_000]

    /// One attempt. `fetch(_:)` owns the retry policy.
    private func fetchOnce(_ url: URL) async throws -> Data {
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FoodDataCentralError.transport(error.localizedDescription)
        }

        try Task.checkCancellation()

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // These three are separated because the caller's move differs for
            // each. A bad key is a setup problem the user can fix in Settings;
            // a rate limit will clear on its own; a 404 on a detail id is an
            // ordinary miss. Everything else collapses to "try again".
            switch http.statusCode {
            case 401, 403: throw FoodDataCentralError.notConfigured
            case 404:      throw FoodDataCentralError.notFound
            case 429:      throw FoodDataCentralError.rateLimited
            default:       throw FoodDataCentralError.unavailable
            }
        }
        return data
    }
}

// MARK: - Datasets

/// Which FoodData Central dataset a food came from.
///
/// The order matters more than the names. A meal description names a DISH, so
/// the dataset of dishes is asked first; the ingredient datasets answer the
/// cases a dish table cannot ("120 g raw chicken thigh"). Branded is last and
/// deliberately so: Open Food Facts already covers packets, is not US-weighted,
/// and carries the barcode this app scans.
enum FoodDataCentralDataType: String, Sendable, CaseIterable {

    /// Composite dishes as eaten, from the dietary survey. The reason this
    /// client exists.
    case survey = "Survey (FNDDS)"

    /// Single foods, laboratory-analysed, the highest-quality rows in the set.
    case foundation = "Foundation"

    /// The legacy standard reference. Broader than Foundation and older.
    case srLegacy = "SR Legacy"

    /// Manufacturer-supplied label data, US-weighted.
    case branded = "Branded"

    /// Dishes first, then ingredients. Branded is excluded: asking for it
    /// floods a generic query with one brand's twelve flavours of the same bar.
    static let defaultOrder: [FoodDataCentralDataType] = [.survey, .foundation, .srLegacy]
}

// MARK: - A food

/// One food from FoodData Central: what it is, what 100 g of it contains, and
/// the household measures it is served in (#653).
///
/// Nutrients are held per 100 g rather than at some serving, because that is
/// how the API states them for every dataset and because it keeps the two
/// unknowns apart. Density lives here; mass lives in `portions`, and a caller
/// combines them explicitly. A type that stored "the numbers for one cup" would
/// have folded a mass assumption into a density record, which is the exact
/// conflation this whole change is undoing.
struct FoodDataCentralFood: Sendable, Equatable, Identifiable {

    let fdcID: Int

    /// The dataset's own description, e.g. "Biryani with vegetables". Shown to
    /// the model so it can tell a near-miss from a hit.
    let description: String

    let dataType: FoodDataCentralDataType?

    /// The manufacturer, for a Branded row. Nil for everything else.
    let brandOwner: String?

    /// The eight, per 100 g. Sodium in MILLIGRAMS, which is the unit FDC uses
    /// natively — unlike Open Food Facts, which states it in grams and needs
    /// the x1000 that #625 was caught by.
    let nutrientsPer100: MealNutrients

    /// Which of the eight the record did not carry. Each one is sitting at
    /// zero in `nutrientsPer100`, and a zero meaning "not stated" has to be
    /// shown differently from a zero meaning zero.
    let missingNutrients: [Nutrient]

    /// Household measures and their gram weights. Empty for a food the dataset
    /// gives no portion table for, which is most Foundation rows and all of
    /// Branded.
    let portions: [FoodDataCentralPortion]

    var id: Int { fdcID }

    /// The dataset's own default serving, when it has one.
    ///
    /// FNDDS states this as a portion literally described "Quantity not
    /// specified", which is the survey's answer to a respondent who said they
    /// ate the thing without saying how much of it. That is precisely the
    /// question this app is asking, so the oddly-named row is the single most
    /// useful number in the table.
    var defaultPortion: FoodDataCentralPortion? {
        portions.first(where: \.isUnspecifiedQuantity) ?? portions.first
    }

    /// The eight for `grams` of this food.
    func nutrients(forGrams grams: Double) -> MealNutrients {
        MealNutrients.scaled(nutrientsPer100, fromBasePortion: 100, to: grams)
    }

    /// This food as a library draft, so a hit can be saved exactly like an Open
    /// Food Facts one.
    ///
    /// `defaultPortionQuantity` takes the dataset's own serving where there is
    /// one and 100 g otherwise, so a row saved from here opens with a plausible
    /// amount rather than with the base the numbers happen to be stated at.
    func draft() -> FoodItemDraft {
        FoodItemDraft(
            name: description,
            brand: brandOwner,
            basePortionQuantity: 100,
            basePortionUnit: .grams,
            calories: nutrientsPer100.calories,
            proteinG: nutrientsPer100.proteinG,
            carbsG: nutrientsPer100.carbsG,
            fatG: nutrientsPer100.fatG,
            fibreG: nutrientsPer100.fibreG,
            sugarG: nutrientsPer100.sugarG,
            sodiumMg: nutrientsPer100.sodiumMg,
            satFatG: nutrientsPer100.satFatG,
            defaultPortionQuantity: defaultPortion?.gramWeight ?? 100,
            barcode: nil,
            externalSource: FoodItemSource.usdaFDC,
            externalID: String(fdcID),
            source: FoodItemSource.usdaFDC,
            imageURL: nil,
            missingNutrients: missingNutrients
        )
    }
}

/// One household measure and what it weighs (#653).
///
/// The mass half of an estimate, from a named source. "1 cup" of chicken curry
/// is 240 g because the dataset says so, not because a model recalled a
/// plausible number.
struct FoodDataCentralPortion: Sendable, Equatable {

    /// How the measure is described, e.g. "1 cup", "1 piece", "Quantity not
    /// specified".
    let description: String

    /// What that measure weighs, in grams.
    let gramWeight: Double

    /// This is the dataset's default serving rather than a named measure.
    ///
    /// Matched on the description because that is the only field carrying it:
    /// the row's `measureUnit` is the placeholder "undetermined" and its
    /// `amount` is null, so nothing structural distinguishes it.
    var isUnspecifiedQuantity: Bool {
        description.lowercased().contains("quantity not specified")
    }
}

// MARK: - Errors

/// What can go wrong talking to FoodData Central.
///
/// `notFound` is here and `cancelled` is not, which is the opposite of the Open
/// Food Facts split and is deliberate. A barcode miss is an ordinary outcome
/// the user sees; a 404 on an `fdcId` the search just handed back is a broken
/// assumption, and `food(id:)` turns it into nil at the one call site where it
/// is ordinary rather than making every caller filter it.
enum FoodDataCentralError: LocalizedError, Equatable {

    /// No API key configured, or the one configured was rejected.
    case notConfigured

    /// The query could not be turned into a URL at all.
    case badRequest

    /// The network refused, dropped, or timed out.
    case transport(String)

    /// The hourly allowance is spent. Distinct from `unavailable` because
    /// retrying in 400 ms cannot help and the caller should stop asking.
    case rateLimited

    /// The id names no food.
    case notFound

    /// The server answered, but not with a success status.
    case unavailable

    /// The server answered with a body this app cannot read.
    case malformed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No USDA FoodData Central key is configured, so food lookups are off."
        case .badRequest:
            return "That lookup could not be sent."
        case .transport(let detail):
            return "Could not reach the food composition database. \(detail)"
        case .rateLimited:
            return "The food composition database has had too many requests this hour."
        case .notFound:
            return "That food is not in the composition database."
        case .unavailable:
            return "The food composition database is not answering right now."
        case .malformed:
            return "The food composition database sent back something this app could not read."
        }
    }
}

// MARK: - The wire shapes

// Internal rather than private, matching `OpenFoodFactsSearchResponse`: the
// mapping tests decode a fixture through these directly, with no URLSession and
// no network, so the suite says the same thing on any machine at any hour. The
// mapping is the part that fails by producing a PLAUSIBLE number, which nothing
// downstream would object to — see `FoodDataCentralMappingTests`.

/// `{"totalHits": Int, "foods": [ … ]}`.
struct FoodDataCentralSearchResponse: Decodable {
    let foods: [FoodDataCentralSearchRow]
}

/// A row from `/foods/search`.
///
/// ⚠️ Its nutrients are FLAT — `{nutrientId, nutrientName, unitName, value}` —
/// while `/food/{id}` nests them under `nutrient` and renames `value` to
/// `amount`. Two shapes for one concept, from one API, and a decoder written
/// for either one silently reads every nutrient as absent from the other. The
/// two are decoded separately here for that reason and meet only as
/// `FoodDataCentralFood`.
struct FoodDataCentralSearchRow: Decodable {
    let fdcId: Int
    let description: String
    let dataType: String?
    let brandOwner: String?
    let foodNutrients: [FlatNutrient]

    struct FlatNutrient: Decodable {
        let nutrientId: Int?
        let unitName: String?
        let value: Double?
    }

    var food: FoodDataCentralFood {
        let readings = foodNutrients.reduce(into: [Int: NutrientReading]()) { out, n in
            guard let id = n.nutrientId, let value = n.value else { return }
            out[id] = NutrientReading(value: value, unit: n.unitName)
        }
        let built = FoodDataCentralNutrientMap.build(from: readings)
        return FoodDataCentralFood(
            fdcID: fdcId,
            description: description,
            dataType: dataType.flatMap(FoodDataCentralDataType.init(rawValue:)),
            brandOwner: brandOwner,
            nutrientsPer100: built.nutrients,
            missingNutrients: built.missing,
            // The search endpoint carries no portion table at any page size.
            portions: []
        )
    }
}

/// The body of `/food/{id}`.
struct FoodDataCentralDetail: Decodable {
    let fdcId: Int
    let description: String
    let dataType: String?
    let brandOwner: String?
    let foodNutrients: [NestedNutrient]
    let foodPortions: [Portion]?

    struct NestedNutrient: Decodable {
        let nutrient: Descriptor?
        let amount: Double?

        struct Descriptor: Decodable {
            let id: Int?
            let unitName: String?
        }
    }

    struct Portion: Decodable {
        let portionDescription: String?
        let gramWeight: Double?
        let amount: Double?
        let measureUnit: MeasureUnit?

        struct MeasureUnit: Decodable {
            let name: String?
        }

        /// How this measure should read to a human, and to a model.
        ///
        /// FNDDS states it in `portionDescription` ("1 cup"). Foundation and SR
        /// Legacy leave that null and state the same thing as an amount plus a
        /// unit ("0.5", "cup"), so both shapes are folded into one sentence
        /// here rather than at three call sites.
        var label: String? {
            if let described = portionDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
               !described.isEmpty {
                return described
            }
            guard let unit = measureUnit?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !unit.isEmpty, unit.lowercased() != "undetermined" else { return nil }
            guard let amount else { return unit }
            return "\(FoodDataCentralDetail.trim(amount)) \(unit)"
        }
    }

    static func trim(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.2g", value)
    }

    var food: FoodDataCentralFood {
        let readings = foodNutrients.reduce(into: [Int: NutrientReading]()) { out, n in
            guard let id = n.nutrient?.id, let amount = n.amount else { return }
            out[id] = NutrientReading(value: amount, unit: n.nutrient?.unitName)
        }
        let built = FoodDataCentralNutrientMap.build(from: readings)
        let portions = (foodPortions ?? []).compactMap { raw -> FoodDataCentralPortion? in
            guard let grams = raw.gramWeight, grams > 0, let label = raw.label else { return nil }
            return FoodDataCentralPortion(description: label, gramWeight: grams)
        }
        return FoodDataCentralFood(
            fdcID: fdcId,
            description: description,
            dataType: dataType.flatMap(FoodDataCentralDataType.init(rawValue:)),
            brandOwner: brandOwner,
            nutrientsPer100: built.nutrients,
            missingNutrients: built.missing,
            portions: portions
        )
    }
}

/// One nutrient as it came off the wire, before it is known which of the eight
/// it is. The unit travels with the value because energy is the one field whose
/// unit changes what the number means.
///
/// Internal rather than private because `FoodDataCentralNutrientMap` takes it as
/// a parameter and that type is internal: the id-to-nutrient mapping is the part
/// of this file a test pins directly, without a URLSession in the way.
struct NutrientReading {
    let value: Double
    let unit: String?
}

/// Which FDC nutrient id is which of this app's eight (#653).
///
/// Verified against a live FNDDS food on 2026-09-22: every one of the eight was
/// present on `Chicken curry`, in the units this app stores. FDC states sodium
/// in mg natively, so there is no unit conversion here at all except for
/// energy.
enum FoodDataCentralNutrientMap {

    static let protein = 1003
    static let fat     = 1004
    static let carbs   = 1005
    static let energyKcal = 1008
    static let fibre   = 1079
    static let sodium  = 1093
    static let satFat  = 1258
    static let sugar   = 2000

    /// Total sugars under its older label. Foundation rows carry 2000; some SR
    /// Legacy rows carry only this one, and a food whose sugar reads zero
    /// because the newer id was absent is a wrong number, not a missing one.
    static let sugarNLEA = 1063

    /// Energy in kilojoules, and the two Atwater-specific energy rows. Read
    /// only when 1008 is absent — see `energy(from:)`.
    static let energyKJ = 1062
    static let energyAtwaterGeneral = 2047
    static let energyAtwaterSpecific = 2048

    /// Turn a bag of readings into the eight, and name the ones that were not
    /// there.
    static func build(from readings: [Int: NutrientReading]) -> (nutrients: MealNutrients, missing: [Nutrient]) {
        var missing: [Nutrient] = []

        func read(_ id: Int, _ nutrient: Nutrient, fallback: Int? = nil) -> Double {
            if let reading = readings[id] { return reading.value }
            if let fallback, let reading = readings[fallback] { return reading.value }
            missing.append(nutrient)
            return 0
        }

        let calories = energy(from: readings)
        if calories == nil { missing.append(.calories) }

        let nutrients = MealNutrients(
            calories: calories ?? 0,
            proteinG: read(protein, .protein),
            carbsG:   read(carbs, .carbs),
            fatG:     read(fat, .fat),
            fibreG:   read(fibre, .fibre),
            sugarG:   read(sugar, .sugar, fallback: sugarNLEA),
            sodiumMg: read(sodium, .sodium),
            satFatG:  read(satFat, .saturatedFat)
        )
        // `Nutrient.allCases` order, so the list is stable across runs and a
        // snapshot of it can be asserted.
        let ordered = Nutrient.allCases.filter { missing.contains($0) }
        return (nutrients, ordered)
    }

    /// Calories, in kcal, from whichever energy row the food carries.
    ///
    /// Three sources in a deliberate order. 1008 is what FNDDS and Branded
    /// state and it is already kcal. Some Foundation rows state 1008 in
    /// KILOJOULES instead, so the unit is checked rather than assumed — reading
    /// 447 kJ as 447 kcal would be a 4.184x error that every downstream guard
    /// would wave through as a large meal. The Atwater rows are the last
    /// fallback for rows that carry no 1008 at all.
    static func energy(from readings: [Int: NutrientReading]) -> Double? {
        if let reading = readings[energyKcal] {
            return isKilojoules(reading.unit) ? reading.value / 4.184 : reading.value
        }
        if let reading = readings[energyAtwaterSpecific] ?? readings[energyAtwaterGeneral] {
            return isKilojoules(reading.unit) ? reading.value / 4.184 : reading.value
        }
        if let reading = readings[energyKJ] {
            return reading.value / 4.184
        }
        return nil
    }

    private static func isKilojoules(_ unit: String?) -> Bool {
        unit?.lowercased().hasPrefix("kj") ?? false
    }
}
