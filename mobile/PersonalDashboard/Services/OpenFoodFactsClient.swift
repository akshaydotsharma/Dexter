import Foundation

/// A read-only window onto Open Food Facts, the free public food database
/// (#625).
///
/// ### Why a public database at all, when this app already has a model
///
/// Every meal before the library arrived the same way: a description, an
/// estimate, eight numbers. That is right for "chicken rice and a teh tarik".
/// It is wrong for a packet, whose exact numbers are printed on the back and
/// whose re-estimation costs a round trip and returns a slightly different
/// answer each time.
///
/// Open Food Facts already holds the back of the packet for roughly four
/// million products, keyed by the barcode on the front. A hit here is a
/// transcription, not a guess, so it is worth more than the best estimate this
/// app can make and it costs nothing per call.
///
/// ### Why it is read-only, and stays read-only
///
/// The database is crowd-sourced and writable, and this app has no business
/// writing to it. Someone logging their own breakfast has not verified anything
/// for anyone else, and a write path would put unreviewed numbers in front of
/// strangers. `LocalFoodItem.isVerified` records that the USER looked at the
/// packet; it says nothing that should travel back upstream.
///
/// It also means a hit is not automatically true. One Open Food Facts entry for
/// a high-protein vanilla yogurt claims 52 kcal per 100 g, which is wrong, and
/// nothing downstream can tell that from a plausible number.
///
/// That used to be answered with a confirm form on every import. It is now
/// answered with a row that prints its calories and protein BEFORE the tap, and
/// with an item that stays editable after it (#625). The form on every import
/// was friction on the path that has to stay fast, and it made the library
/// something the user had to curate; showing the numbers in the row buys the
/// same look for no taps. `LocalFoodItem.isVerified` stays false for a row that
/// arrived this way, which is what the flag is for.
///
/// ### Why there is no key and no account
///
/// There is no API key to hold, which removes the whole class of problems the
/// Anthropic path carries (see `AppConfig.anthropicAPIKey`). What the project's
/// usage policy asks for instead is a descriptive `User-Agent` naming the app
/// and a contact, so their operators can see who is calling and reach whoever
/// is doing it wrong. `Self.userAgent` builds it from the bundle version.
/// Sending the default `URLSession` agent is the one thing that policy names as
/// grounds for a block, so no request leaves here without it.
///
/// ### Shape
///
/// A plain struct with one injected `URLSession` and no stored state at all, so
/// it is `Sendable` by construction and any number of them can exist. The
/// search path is fired per keystroke by the picker, so the expensive thing to
/// get wrong here is not throughput, it is cancellation: see `fetch(_:)`.
struct OpenFoodFactsClient: Sendable {

    // MARK: - The wire

    /// Free-text search. The `cgi/search.pl` endpoint predates their v2 API and
    /// is still the one that answers a text query; v2's `/api/v2/search` exists
    /// but is slower and is documented as being for filtering by tag rather
    /// than for the "what did I just type" case.
    static let searchURL = "https://world.openfoodfacts.org/cgi/search.pl"

    /// One product by barcode, v2. `<code>` is appended.
    static let productURLPrefix = "https://world.openfoodfacts.org/api/v2/product/"

    /// The exact fields both endpoints are asked for.
    ///
    /// Naming them is not a micro-optimisation. A bare Open Food Facts product
    /// document is 30-100 KB of tags, translations, edit history and ingredient
    /// analysis, and 20 of those is a multi-megabyte response for a list that
    /// shows a name, a brand and a calorie figure. Asking for nine fields makes
    /// a search answer in well under a second on a phone connection.
    ///
    /// Keep this in step with `OpenFoodFactsProduct`: a field decoded there and
    /// missing here is silently always nil, which reads exactly like a product
    /// that does not carry it.
    static let fields = [
        "code",
        "product_name",
        "brands",
        "quantity",
        "serving_size",
        "serving_quantity",
        "nutriments",
        "nutrition_data_per",
        "image_front_small_url"
    ].joined(separator: ",")

    /// How many hits one search returns.
    ///
    /// Twenty rather than a full page of fifty, because the picker is a phone
    /// list the user scans rather than reads, and the right item is almost
    /// always in the first handful. The cost of a bigger page is paid on every
    /// keystroke.
    static let pageSize = 20

    /// The ceiling on one request.
    ///
    /// ⚠️ This value is set on the SESSION CONFIGURATION as well as on the
    /// request, and the two must agree. A session's
    /// `timeoutIntervalForRequest` CAPS whatever an individual `URLRequest`
    /// asks for, so `request.timeoutInterval = 15` run through
    /// `URLSession.shared` is not a 15 s timeout, it is a 60 s timeout with a
    /// misleading line of code in front of it. #594 lost hours to exactly that
    /// on the Anthropic path: the request said 150, the shared session said 60,
    /// and every call died at 60.1 s with `NSURLErrorTimedOut`. See
    /// `AnthropicClient.defaultSession`.
    ///
    /// Fifteen seconds is generous for a nine-field lookup and deliberately
    /// short enough that a dead network fails while the user is still looking
    /// at the field they typed into.
    static let timeout: TimeInterval = 15

    /// The session every real call runs on.
    ///
    /// Its own session rather than `URLSession.shared` for the capping reason
    /// above, and so that raising or lowering this feature's patience cannot
    /// change the timeout of anything else in the app.
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = OpenFoodFactsClient.timeout
        // The resource timeout covers the whole transfer including retries. A
        // small multiple of the request timeout, so a stalling drip-feed
        // eventually ends rather than hanging a picker row forever.
        config.timeoutIntervalForResource = OpenFoodFactsClient.timeout * 2
        return URLSession(configuration: config)
    }()

    let session: URLSession

    init(session: URLSession = OpenFoodFactsClient.defaultSession) {
        self.session = session
    }

    /// What this app tells Open Food Facts it is.
    ///
    /// Their usage policy asks every client for a descriptive agent naming the
    /// app, the version and a way to be contacted, and names the stock
    /// `URLSession` agent as the thing that gets a caller blocked. The repo URL
    /// is the contact: it is public, it is stable, and it does not put a
    /// personal email address into a header sent to a third party.
    static var userAgent: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return "Dexter/\(short) (personal use; github.com/akshaydotsharma/Dexter)"
    }

    // MARK: - Search

    /// Products matching free text, best match first, at most `pageSize`.
    ///
    /// An empty or whitespace-only query returns no hits rather than throwing.
    /// This is fired per keystroke, and a field the user has just cleared is
    /// not an error state.
    func search(_ query: String) async throws -> [OpenFoodFactsProduct] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: Self.searchURL)
        components?.queryItems = [
            URLQueryItem(name: "search_terms", value: trimmed),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: String(Self.pageSize)),
            URLQueryItem(name: "fields", value: Self.fields)
        ]
        guard let url = components?.url else { throw OpenFoodFactsError.badRequest }

        let data = try await fetch(url)
        do {
            return try JSONDecoder().decode(OpenFoodFactsSearchResponse.self, from: data).products
        } catch {
            throw OpenFoodFactsError.malformed
        }
    }

    // MARK: - Barcode

    /// One product by its EAN or UPC, or `nil` when the database does not have
    /// it.
    ///
    /// Not-found is `nil` and not an error, and the distinction carries real
    /// weight at the call site. A scan that finds nothing is an ordinary,
    /// frequent outcome — the database is large but it is not complete, and it
    /// is thinnest exactly where a Singapore shelf is thickest. Treating it as a
    /// failure would show an apology for something that is working.
    ///
    /// The picker's answer to `nil` is a sentence saying the database does not
    /// have that packet, and a pointer at the other way in: close the sheet and
    /// describe the meal in words (#625).
    ///
    /// Their v2 endpoint answers HTTP 200 with `status: 0` for an unknown code,
    /// so the status field is the only thing that can tell you, not the HTTP
    /// layer.
    func product(barcode: String) async throws -> OpenFoodFactsProduct? {
        let trimmed = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A barcode is digits, but it arrives from a scanner and from a typed
        // field, so it is escaped rather than trusted into the path.
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
        var components = URLComponents(string: Self.productURLPrefix + escaped)
        components?.queryItems = [URLQueryItem(name: "fields", value: Self.fields)]
        guard let url = components?.url else { throw OpenFoodFactsError.badRequest }

        let data = try await fetch(url)
        let decoded: OpenFoodFactsProductResponse
        do {
            decoded = try JSONDecoder().decode(OpenFoodFactsProductResponse.self, from: data)
        } catch {
            throw OpenFoodFactsError.malformed
        }
        guard decoded.status == 1 else { return nil }
        return decoded.product
    }

    // MARK: - One request

    /// Run one GET and hand back the body.
    ///
    /// ### Cancellation is the interesting part
    ///
    /// The picker fires a search on every keystroke and cancels the one before
    /// it, so in a five-letter query four of the five requests are SUPPOSED to
    /// die. A cancelled request surfacing as "Could not reach the food
    /// database" would put an error under a field that is working perfectly,
    /// four times, while the user types.
    ///
    /// So cancellation is normalised to `CancellationError` and nothing else:
    /// the structured-concurrency check before the call, and `URLError.cancelled`
    /// after it, both end at the same type. The call site's `catch is
    /// CancellationError { }` then covers every way a cancelled search can
    /// arrive, and only a real failure reaches the user-facing branch.
    private func fetch(_ url: URL) async throws -> Data {
        var delay = Self.retryDelays.makeIterator()
        while true {
            do {
                return try await fetchOnce(url)
            } catch OpenFoodFactsError.unavailable {
                guard let pause = delay.next() else { throw OpenFoodFactsError.unavailable }
                try await Task.sleep(nanoseconds: pause)
            }
        }
    }

    /// How long to wait before each retry, and therefore how many there are.
    ///
    /// ── MEASURED, not defensive ─────────────────────────────────────────────
    ///
    /// Open Food Facts answers 503 with an HTML "Page temporarily unavailable"
    /// page for roughly one request in three at the moment, on an otherwise
    /// identical request that succeeds on the next attempt. Eight plain `curl`
    /// requests to each endpoint on 2026-09-18:
    ///
    ///     cgi/search.pl   200 200 200 503 503 200 200 503
    ///     api/v2/search   503 200 200 503 503 200 200 200
    ///
    /// Both flap at the same rate, which is the useful part of that
    /// measurement: it is their shared infrastructure shedding load, not the
    /// legacy endpoint being legacy and not anything about what this app sends.
    /// Moving to the v2 search endpoint would buy nothing, so this client stays
    /// on the one whose response shape is known.
    ///
    /// Three attempts take a one-in-three failure to about one in twenty-seven,
    /// which is the difference between a search that feels broken and one that
    /// occasionally feels slow. The worst case adds 1.7 s.
    ///
    /// The picker now searches this database as the user types rather than on a
    /// button (#625), which would make two retries expensive if every keystroke
    /// reached here. It does not: the picker debounces by 350 ms and cancels the
    /// in-flight request on each keystroke, so one request leaves per PAUSE and
    /// a cancelled attempt never reaches the retry loop at all. The local
    /// library answers instantly either way, so the wait this can add is always
    /// on results the user is still reading past.
    ///
    /// Only `unavailable` is retried. A GET with no side effects is safe to
    /// repeat; a transport error is usually a dead network, where retrying just
    /// doubles the wait, and a malformed body will parse exactly as badly the
    /// second time.
    private static let retryDelays: [UInt64] = [500_000_000, 1_200_000_000]

    /// One attempt. `fetch(_:)` owns the retry policy.
    private func fetchOnce(_ url: URL) async throws -> Data {
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Matches `defaultSession`'s configuration on purpose — see the note on
        // `timeout`. An injected test session may be shorter; it may not be
        // silently longer than it looks.
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
            throw OpenFoodFactsError.transport(error.localizedDescription)
        }

        try Task.checkCancellation()

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The status code is deliberately dropped here rather than put in
            // front of the user. "HTTP 503" tells them nothing they can act on,
            // and the action is the same for every one of them: try again.
            throw OpenFoodFactsError.unavailable
        }
        return data
    }
}

// MARK: - Errors

/// What can go wrong talking to Open Food Facts, in words a person can read.
///
/// Note what is NOT in here: "not found" and "cancelled". A barcode the
/// database has never seen returns `nil` from `product(barcode:)`, and a search
/// the user typed over throws `CancellationError`. Both are ordinary outcomes
/// of a working feature, and giving either one an error case would make the
/// error enum something the UI has to filter before it can show it.
enum OpenFoodFactsError: LocalizedError, Equatable {

    /// The query could not be turned into a URL at all. Unreachable in
    /// practice, kept because the alternative is a force-unwrap.
    case badRequest

    /// The network refused, dropped, or timed out.
    case transport(String)

    /// The server answered, but not with a success status.
    case unavailable

    /// The server answered with a body this app cannot read. Usually an
    /// HTML error page served with a 200, which is a thing their CDN does
    /// under load.
    case malformed

    var errorDescription: String? {
        switch self {
        case .badRequest:
            return "That search could not be sent."
        case .transport(let detail):
            return "Could not reach the food database. \(detail)"
        case .unavailable:
            return "The food database is not answering right now. Try again in a moment."
        case .malformed:
            return "The food database sent back something this app could not read."
        }
    }
}

// MARK: - The wire shapes

/// `{"count": Int, "products": [ … ]}`.
struct OpenFoodFactsSearchResponse: Decodable, Sendable {
    let count: Int
    let products: [OpenFoodFactsProduct]

    private enum CodingKeys: String, CodingKey { case count, products }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `count` arrives as a number in every record seen, but it costs
        // nothing to read it the same lenient way the nutriments are read, and
        // a search must not fail over a field nothing uses for arithmetic.
        let rawCount = OpenFoodFactsNumber.decode(c, forKey: .count) ?? 0
        count = Int(exactly: rawCount.rounded()) ?? 0
        products = (try? c.decode([OpenFoodFactsProduct].self, forKey: .products)) ?? []
    }
}

/// `{"status": Int, "product": { … }}`. `status == 0` means not found.
struct OpenFoodFactsProductResponse: Decodable, Sendable {
    let status: Int
    let product: OpenFoodFactsProduct?

    private enum CodingKeys: String, CodingKey { case status, product }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawStatus = OpenFoodFactsNumber.decode(c, forKey: .status) ?? 0
        status = Int(exactly: rawStatus.rounded()) ?? 0
        product = try? c.decode(OpenFoodFactsProduct.self, forKey: .product)
    }
}

/// One product exactly as Open Food Facts returned it, before any of this
/// app's opinions are applied (#625).
///
/// Kept as a separate type from `FoodItemDraft` on purpose. This one is the
/// record of what the database said, so a mapping bug can be told apart from a
/// bad record: if the draft's sodium is wrong, the question is whether
/// `nutriments["sodium_100g"]` was wrong too, and collapsing the two types
/// would delete the evidence.
///
/// ### Everything here is lenient, because the data is crowd-sourced
///
/// Open Food Facts rows are typed in by people through several generations of
/// form, and the same field arrives as a JSON number in one record and a
/// numeric STRING in the next. `serving_quantity` does it; individual
/// nutriments do it. A strict `Decodable` throws on the whole product for one
/// such field and the hit disappears, which looks like the product not being in
/// the database at all.
///
/// So every field here is optional-with-a-default and every number goes
/// through `OpenFoodFactsNumber`. A missing field means missing; it never
/// means a failed search.
struct OpenFoodFactsProduct: Decodable, Sendable, Equatable {

    /// The barcode. Also the product's id in their system.
    let code: String

    /// The name without the brand, as the contributor typed it. Frequently
    /// empty, and empty is handled rather than rejected.
    let productName: String

    /// A COMMA-SEPARATED list of makers, not one name. "Superyou" and
    /// "Farmers Union,Farmers Union Australia" are both normal values.
    let brands: String

    /// Pack size as printed: "150 g", "330 ml", "6 x 200ml".
    let quantity: String

    /// Serving size as printed: "40 g", "1 serving size (160 g)".
    let servingSize: String

    /// The serving as a bare number, when the record carries one. Nil often.
    let servingQuantity: Double?

    /// "100g" or "100ml", saying which the `_100g` keys are per. Despite the
    /// key names, the suffix stays `_100g` even for a record whose panel is per
    /// 100 ml, so this field is the only thing that says which.
    let nutritionDataPer: String

    /// A small product photo, for the picker row. Often empty.
    let imageFrontSmallURL: String

    /// Every nutrient the record carries, keyed exactly as the wire spells
    /// them: `energy-kcal_100g`, `saturated-fat_100g`, `sodium_100g`, and the
    /// `_serving` variants beside them. Values that are not numbers at all are
    /// dropped rather than stored as zero, so "absent" and "zero" stay
    /// distinguishable — which rule 5 of the mapping depends on.
    let nutriments: [String: Double]

    private enum CodingKeys: String, CodingKey {
        case code
        case productName = "product_name"
        case brands
        case quantity
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
        case nutritionDataPer = "nutrition_data_per"
        case imageFrontSmallURL = "image_front_small_url"
        case nutriments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = OpenFoodFactsNumber.decodeString(c, forKey: .code) ?? ""
        productName = OpenFoodFactsNumber.decodeString(c, forKey: .productName) ?? ""
        brands = OpenFoodFactsNumber.decodeString(c, forKey: .brands) ?? ""
        quantity = OpenFoodFactsNumber.decodeString(c, forKey: .quantity) ?? ""
        servingSize = OpenFoodFactsNumber.decodeString(c, forKey: .servingSize) ?? ""
        servingQuantity = OpenFoodFactsNumber.decode(c, forKey: .servingQuantity)
        nutritionDataPer = OpenFoodFactsNumber.decodeString(c, forKey: .nutritionDataPer) ?? ""
        imageFrontSmallURL = OpenFoodFactsNumber.decodeString(c, forKey: .imageFrontSmallURL) ?? ""
        nutriments = (try? c.decode([String: OpenFoodFactsNumber].self, forKey: .nutriments))?
            .compactMapValues(\.value) ?? [:]
    }

    /// Memberwise, for tests and for anything that needs to build a record by
    /// hand. Decoding is the real path.
    init(
        code: String = "",
        productName: String = "",
        brands: String = "",
        quantity: String = "",
        servingSize: String = "",
        servingQuantity: Double? = nil,
        nutritionDataPer: String = "",
        imageFrontSmallURL: String = "",
        nutriments: [String: Double] = [:]
    ) {
        self.code = code
        self.productName = productName
        self.brands = brands
        self.quantity = quantity
        self.servingSize = servingSize
        self.servingQuantity = servingQuantity
        self.nutritionDataPer = nutritionDataPer
        self.imageFrontSmallURL = imageFrontSmallURL
        self.nutriments = nutriments
    }
}

/// One JSON value that is supposed to be a number and might be a string.
///
/// The single place this file is lenient about types, rather than eight
/// special cases at eight call sites. A value that is neither a number nor a
/// string a number can be read out of decodes to `nil`, which every reader
/// treats as absent.
struct OpenFoodFactsNumber: Decodable, Sendable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d; return }
        if let i = try? c.decode(Int.self) { value = Double(i); return }
        if let s = try? c.decode(String.self) {
            // A European record can write "25,9". Trim first: " 466 " happens.
            let cleaned = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            value = Double(cleaned)
            return
        }
        value = nil
    }

    /// Read a possibly-stringly number out of a keyed container.
    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Double? {
        (try? container.decode(OpenFoodFactsNumber.self, forKey: key))?.value
    }

    /// Read a possibly-numeric string out of a keyed container. `code` is a
    /// string in v2 and has been seen as a number in older exports.
    static func decodeString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> String? {
        if let s = try? container.decode(String.self, forKey: key) { return s }
        if let i = try? container.decode(Int.self, forKey: key) { return String(i) }
        if let d = try? container.decode(Double.self, forKey: key) { return String(d) }
        return nil
    }
}

// MARK: - The draft a hit travels in

/// Everything `LocalFoodItem` needs, as a plain value with no store behind it
/// (#625).
///
/// ### Why this is not just a `LocalFoodItem`
///
/// Because nothing has been committed yet. A search answers with twenty hits
/// and the user picks at most one. Building a `@Model` for each would mean
/// twenty writes per search and a window in which a stranger's record is
/// indistinguishable in the store from a row the user chose.
///
/// So a hit stays a draft while it is only a result, and while it is only in
/// the tray. `FoodItemPick.commit` is the one place a draft becomes a row, and
/// it runs when the meal is written.
///
/// So this type deliberately touches no SwiftData at all. It can be built on
/// any thread, held by a view, diffed, thrown away. `FoodItemService` is the
/// one place that turns a draft into a row.
///
/// It is also what a hand-typed item flows through, which is the reason the
/// fields are `var`: the item editor binds straight to them, and an import and
/// a manual entry then reach the store by the same path with the same
/// validation. The scan path sets `barcode` and `source` on a hit it made
/// itself, for the same reason.
///
/// ### `imageURL` and `missingNutrients` are not on the model, on purpose
///
/// Both are facts about THIS IMPORT rather than about the food. The image is
/// remote, temporary, and the library does not show pictures; carrying it on
/// the row would mean a column that is stale the moment the contributor
/// replaces the photo. `missingNutrients` is the list of figures the record did
/// not carry, which the picker row prints as "3 figures not stated" so a
/// confident `0 g` is never read as a measurement. Once the row is in the
/// library the zero is what the user chose to keep, and the list has no meaning
/// any more.
struct FoodItemDraft: Sendable, Equatable {

    /// What the thing is, without the brand. May be empty coming out of an
    /// import; the confirm form is expected to demand one before saving.
    var name: String

    /// A single maker, already picked out of Open Food Facts' comma-separated
    /// list. Nil for something generic.
    var brand: String?

    /// The amount the eight nutrients describe. 100 for anything imported.
    var basePortionQuantity: Double

    /// Grams or millilitres, the only two `MealItemEntry` accepts.
    var basePortionUnit: FoodPortionUnit

    /// The eight, AT `basePortionQuantity`. Units match `LocalFoodItem`
    /// exactly: kcal, grams, and SODIUM IN MILLIGRAMS.
    var calories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var fibreG: Double
    var sugarG: Double
    var sodiumMg: Double
    var satFatG: Double

    /// How much of it you normally eat, in `basePortionUnit`.
    var defaultPortionQuantity: Double

    var barcode: String?
    var externalSource: String?
    var externalID: String?

    /// How this draft would enter the library, as a `FoodItemSource` constant.
    ///
    /// Provenance, not content. A typed search and a barcode scan return the
    /// SAME numbers for the same product and must still be told apart, because
    /// `LocalFoodItem.source` is the only field that records which door was
    /// used. The scan path overwrites this with `FoodItemSource.barcode` on the
    /// hit it built; nothing else touches it.
    var source: String = FoodItemSource.openFoodFacts

    /// The product photo, for a form that wants one. Never persisted.
    var imageURL: URL?

    /// Which of the eight the source record did not carry. Every one of these
    /// is sitting at zero, and a zero that means "not stated" must be shown
    /// differently from a zero that means zero.
    var missingNutrients: [Nutrient]

    init(
        name: String = "",
        brand: String? = nil,
        basePortionQuantity: Double = 100,
        basePortionUnit: FoodPortionUnit = .grams,
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
        source: String = FoodItemSource.openFoodFacts,
        imageURL: URL? = nil,
        missingNutrients: [Nutrient] = []
    ) {
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
        self.imageURL = imageURL
        self.missingNutrients = missingNutrients
    }
}

// MARK: - A draft behaving like a library row it is not yet (#625)

extension FoodItemDraft {

    /// Brand and name, as a shelf would label it. The same rule
    /// `LocalFoodItem.displayName` follows, so a hit and the row it becomes
    /// read identically and a tray entry does not rename itself on commit.
    ///
    /// The "Unnamed product" fallback is only reachable for a record carrying
    /// neither a name nor a maker, which is a broken row rather than a food.
    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let brand = brand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !brand.isEmpty else {
            return trimmedName.isEmpty ? "Unnamed product" : trimmedName
        }
        if trimmedName.isEmpty { return brand }
        if trimmedName.lowercased().hasPrefix(brand.lowercased()) { return trimmedName }
        return "\(brand) \(trimmedName)"
    }

    /// The eight AT `basePortionQuantity`, as one value.
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

    /// The eight for `quantity`, through the same ratio a stored row uses.
    func nutrients(for quantity: Double) -> MealNutrients {
        MealNutrients.scaled(nutrientsAtBase, fromBasePortion: basePortionQuantity, to: quantity)
    }

    /// This hit, at `quantity`, as the value type a meal actually stores.
    ///
    /// The counterpart of `LocalFoodItem.mealItem(quantity:)`, and it exists
    /// for one reason: a hit the user has tapped sits in the tray with no row
    /// behind it, and retyping its amount there has to rescale something. The
    /// alternative was writing the row at tap time, which fills the library
    /// with everything the user tried and then removed (#625).
    func mealItem(quantity: Double? = nil) -> MealItemEntry {
        let amount = quantity ?? defaultPortionQuantity
        let n = nutrients(for: amount)
        return MealItemEntry(
            name: displayName,
            portionQuantity: amount,
            portionUnit: basePortionUnit.rawValue,
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

    /// This draft as the one argument `FoodItemService.upsert` takes.
    ///
    /// Every optional is passed through as it stands, nil included, because
    /// `FoodItemWrite` reads nil as "this source did not say" and leaves the
    /// stored value alone. Collapsing a missing brand to `""` would CLEAR a
    /// brand the user had corrected on a row this write is updating, which is
    /// the #444 / #488 mistake pointed the other way.
    ///
    /// `isVerified` is false, and that is the honest value: nobody has read
    /// these numbers against the packet. The flag is the user's statement, and
    /// tapping a row in a list is not it.
    var libraryWrite: FoodItemWrite {
        FoodItemWrite(
            name: name,
            brand: brand,
            basePortionQuantity: basePortionQuantity,
            basePortionUnit: basePortionUnit.rawValue,
            nutrients: nutrientsAtBase,
            defaultPortionQuantity: defaultPortionQuantity,
            barcode: barcode,
            externalSource: externalSource,
            externalID: externalID,
            source: source,
            isVerified: false,
            notes: nil
        )
    }
}

// MARK: - The mapping

extension OpenFoodFactsProduct {

    /// This hit as a draft the confirm form can open.
    var draft: FoodItemDraft { FoodItemDraft(product: self) }
}

extension FoodItemDraft {

    /// Turn one Open Food Facts hit into a draft.
    ///
    /// This initialiser is the whole point of the file. Everything above it is
    /// plumbing that can fail loudly; this can fail QUIETLY, by producing a
    /// plausible number that is wrong, and a plausible wrong number goes into
    /// the library, gets logged, and is summed into a week's totals without
    /// anything ever objecting.
    ///
    /// The five rules it implements are each written out at the step that
    /// applies them.
    init(product: OpenFoodFactsProduct) {
        let n = product.nutriments

        // ── Rule 3: the base portion is always 100 ───────────────────────────
        //
        // Not a choice: the `_100g` keys are per 100 by definition, so any
        // other base would be a lie about the eight numbers below. The unit is
        // the only open question, and `inferredUnit` answers it.
        let unit = OpenFoodFactsProduct.inferredUnit(
            nutritionDataPer: product.nutritionDataPer,
            quantity: product.quantity,
            servingSize: product.servingSize
        )

        var missing: [Nutrient] = []

        // ── Rule 2: calories, kcal first and kJ as the fallback ─────────────
        //
        // Plenty of European records carry only the kilojoule figure, because
        // that is what the EU panel is required to print. 4.184 kJ per kcal is
        // the thermochemical definition, not an approximation.
        let calories: Double
        if let kcal = OpenFoodFactsProduct.reading(n, "energy-kcal_100g") {
            calories = kcal
        } else if let kj = OpenFoodFactsProduct.reading(n, "energy-kj_100g") {
            calories = kj / 4.184
        } else {
            calories = 0
            missing.append(.calories)
        }

        // ── Rule 5: a nutrient that is absent or negative is zero AND missing ─
        //
        // Absent and zero are different claims, and only one of them is safe to
        // print without a caveat. A negative is treated as absent because it is
        // a typo in a crowd-sourced field, never a measurement.
        func read(_ key: String, _ nutrient: Nutrient, alternate: String? = nil) -> Double {
            if let v = OpenFoodFactsProduct.reading(n, key) { return v }
            if let alternate, let v = OpenFoodFactsProduct.reading(n, alternate) { return v }
            missing.append(nutrient)
            return 0
        }

        let protein = read("proteins_100g", .protein)
        let carbs = read("carbohydrates_100g", .carbs)
        let fat = read("fat_100g", .fat)
        // Their canonical spelling is American; a handful of records carry the
        // British one. Both are the same field.
        let fibre = read("fiber_100g", .fibre, alternate: "fibre_100g")
        let sugar = read("sugars_100g", .sugar)
        let satFat = read("saturated-fat_100g", .saturatedFat)

        // ── Rule 1: SODIUM IS IN GRAMS ON THE WIRE AND MILLIGRAMS ON THE ROW ──
        //
        // ⚠️⚠️ THE ONE THAT WILL BITE. Open Food Facts returns `sodium_100g` in
        // GRAMS: the Superyou wafer's real value is 0.4425, meaning 442.5 mg per
        // 100 g. `LocalFoodItem.sodiumMg` is MILLIGRAMS. Forget the ×1000 and
        // the library says a wafer has 0.44 mg of sodium; do it twice and it has
        // 442,500. Neither is implausible enough for any guard in this app to
        // catch, because nothing downstream knows what a sodium figure should
        // look like — `MealEstimateGuards` grades an ESTIMATE, and this number
        // never goes near it.
        //
        // The salt fallback: many records print salt and not sodium, because
        // the EU panel mandates salt. Salt is sodium chloride, sodium is
        // 39.34% of it by mass, and 1 / 0.3934 = 2.542 — which food labelling
        // rounds to the standard factor 2.5, used here so this app's figure
        // matches the one the packet's own maths came from. Salt is also in
        // grams, so the ×1000 applies to the derived value exactly the same way.
        let sodiumMg: Double
        if let sodiumG = OpenFoodFactsProduct.reading(n, "sodium_100g") {
            sodiumMg = sodiumG * 1_000
        } else if let saltG = OpenFoodFactsProduct.reading(n, "salt_100g") {
            sodiumMg = (saltG / 2.5) * 1_000
        } else {
            sodiumMg = 0
            missing.append(.sodium)
        }

        // ── Rule 4: the default portion ─────────────────────────────────────
        //
        // `serving_quantity` when the record states one, the number out of the
        // printed `serving_size` when it does not, and 100 when neither says
        // anything. 100 rather than nothing, because the picker has to open on
        // SOME number and the base is the one figure that is certainly true of
        // this row.
        let defaultPortion: Double
        if let stated = product.servingQuantity, stated > 0 {
            defaultPortion = stated
        } else if let parsed = OpenFoodFactsProduct.portion(fromServingSize: product.servingSize), parsed > 0 {
            defaultPortion = parsed
        } else {
            defaultPortion = 100
        }

        // ── Rule 6: name and brand ──────────────────────────────────────────
        let brand = OpenFoodFactsProduct.primaryBrand(product.brands)
        var name = product.productName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            // A record with no product name still has a maker often enough to
            // be worth offering. The pack size is NOT folded in: "150 g" is not
            // a name, and `LocalFoodItem.displayName` would then print it twice.
            // If there is no brand either, the name stays empty and the confirm
            // form is expected to require one — better an obviously blank field
            // than a row called "Unknown product".
            name = brand ?? ""
        }

        // `missingNutrients` is ordered by the canonical nutrient order rather
        // than by the order the reads happened, so two records missing the same
        // set produce the same list and a test can compare it directly.
        let orderedMissing = Nutrient.allCases.filter { missing.contains($0) }

        self.init(
            name: name,
            brand: brand,
            basePortionQuantity: 100,
            basePortionUnit: unit,
            calories: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fibreG: fibre,
            sugarG: sugar,
            sodiumMg: sodiumMg,
            satFatG: satFat,
            defaultPortionQuantity: defaultPortion,
            barcode: product.code.isEmpty ? nil : product.code,
            externalSource: FoodItemSource.openFoodFacts,
            externalID: product.code.isEmpty ? nil : product.code,
            imageURL: product.imageFrontSmallURL.isEmpty
                ? nil
                : URL(string: product.imageFrontSmallURL),
            missingNutrients: orderedMissing
        )
    }
}

// MARK: - The small readers the mapping is built from

extension OpenFoodFactsProduct {

    /// One nutriment, or nil when it is absent, negative, or not a finite
    /// number. See rule 5: all three mean the same thing to the caller.
    static func reading(_ nutriments: [String: Double], _ key: String) -> Double? {
        guard let value = nutriments[key], value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Grams or millilitres for this product.
    ///
    /// Grams is the default and the tie-break, because it is right for most of
    /// what people eat and because getting it wrong on a solid is a label
    /// error, while getting it wrong on a drink is also only a label error:
    /// both units scale linearly and the arithmetic is identical. The stakes
    /// are legibility, so this leans on the clearest signal available and
    /// stops.
    ///
    /// `nutrition_data_per` is that signal when it exists, because it is the
    /// field whose entire job is to say which the panel is per. The pack size
    /// and the serving size are the fallbacks, in that order: a pack is labelled
    /// in the unit the contents are measured in.
    static func inferredUnit(
        nutritionDataPer: String,
        quantity: String,
        servingSize: String
    ) -> FoodPortionUnit {
        let per = nutritionDataPer.lowercased().replacingOccurrences(of: " ", with: "")
        if per.contains("ml") || per.contains("100ml") { return .millilitres }
        if per.contains("100g") { return .grams }
        if endsInVolumeUnit(quantity) { return .millilitres }
        if endsInVolumeUnit(servingSize) { return .millilitres }
        return .grams
    }

    /// Does this printed amount end in a volume unit?
    ///
    /// Reads the trailing run of letters rather than pattern-matching the whole
    /// string, so "330ml", "330 ml", "1.5 L" and "6 x 200ml" all answer the
    /// same. A digit must appear somewhere, so a stray word like "oil" cannot
    /// be read as a unit.
    static func endsInVolumeUnit(_ raw: String) -> Bool {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard s.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        let trailing = String(s.reversed().prefix(while: { $0.isLetter }).reversed())
        return ["ml", "cl", "dl", "l", "litre", "litres", "liter", "liters"].contains(trailing)
    }

    /// The number out of a printed serving size, normalised to the base unit's
    /// magnitude.
    ///
    /// Not simply "the first number in the string". `serving_size` is free text
    /// and the two shapes that matter disagree about where the number is:
    ///
    ///     "40 g"                    →  40
    ///     "1 serving size (160 g)"  → 160, not 1
    ///
    /// So the rule is "the first number that has a UNIT attached to it", which
    /// is right for both, and a bare first number only as a last resort. The
    /// multiplier then folds kg and litres down to g and ml, so a "0.2 kg"
    /// serving opens the picker on 200 rather than on 0.2.
    static func portion(fromServingSize raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Longest units first: "mg" and "ml" must not be read as "m" + junk,
        // and "kg" must not be read as "g".
        let withUnit = "([0-9]+(?:[.,][0-9]+)?)\\s*(mg|kg|ml|cl|dl|oz|g|l)\\b"
        if let match = firstMatch(withUnit, in: text),
           let value = number(match.0) {
            return value * magnitude(of: match.1)
        }
        // No unit anywhere. Take the first number and assume it is already in
        // the base unit, which is what a bare "150" on a serving size means.
        if let match = firstMatch("([0-9]+(?:[.,][0-9]+)?)", in: text),
           let value = number(match.0) {
            return value
        }
        return nil
    }

    /// How many base units one of `unit` is. Anything unrecognised is 1, which
    /// leaves the number as printed rather than inventing a conversion.
    private static func magnitude(of unit: String) -> Double {
        switch unit.lowercased() {
        case "mg":       return 0.001
        case "kg", "l":  return 1_000
        case "cl":       return 10
        case "dl":       return 100
        case "oz":       return 28.3495
        default:         return 1   // g, ml
        }
    }

    /// A decimal that may use a comma, as a European label prints it.
    private static func number(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    /// First regex match, as (group 1, group 2-or-empty).
    private static func firstMatch(_ pattern: String, in text: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let first = Range(match.range(at: 1), in: text) else { return nil }
        var second = ""
        if match.numberOfRanges >= 3, let r = Range(match.range(at: 2), in: text) {
            second = String(text[r])
        }
        return (String(text[first]), second)
    }

    /// One maker out of Open Food Facts' comma-separated `brands`.
    ///
    /// The first entry, because their convention is most-specific-first and the
    /// rest are usually the parent company and the country arm
    /// ("Farmers Union,Farmers Union Australia,Lactalis").
    ///
    /// Title-cased ONLY when the value is entirely lowercase. That condition is
    /// doing real work: a contributor typing "superyou" means the brand
    /// "Superyou", but "LU", "Ben & Jerry's" and "innocent" are how those
    /// brands are actually written, and `.capitalized` would mangle the first
    /// two. Restricting the fix to the all-lowercase case fixes the typo
    /// without overwriting a deliberate spelling — except for a brand that is
    /// genuinely lowercase by design, like innocent, which is the known and
    /// accepted cost, and which the user can correct on the confirm form.
    static func primaryBrand(_ brands: String) -> String? {
        let first = brands
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !first.isEmpty else { return nil }
        return first == first.lowercased() ? first.capitalized : first
    }
}
