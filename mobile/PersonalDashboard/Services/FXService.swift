import Foundation
import SwiftData

/// Errors thrown by `FXService` when it can't supply a rate. Surfaced into
/// the AddExpense sheet so the user sees a real "couldn't convert" hint
/// instead of a silent zero.
enum FXServiceError: LocalizedError {
    /// Network failed and we have no cached rate to fall back to.
    case noRateAvailable(currency: String)
    /// API returned a 2xx but with no `rates[CCY]` field.
    case missingRateInResponse(currency: String)
    /// Anything else (HTTP error, decode failure, etc).
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .noRateAvailable(let c):
            return "No FX rate available for \(c) and the network is unreachable."
        case .missingRateInResponse(let c):
            return "Rate for \(c) wasn't in the FX response."
        case .underlying(let err):
            return err.localizedDescription
        }
    }
}

/// Foreign-exchange service backing the AddExpense sheet and the AI's
/// `add_expense` tool. Fetches rates once per day from the
/// `@fawazahmed0/currency-api` JSON feed (free, no key, jsdelivr CDN-cached,
/// updated daily) and caches in `LocalFXRate`.
///
/// Provider history: we used `exchangerate.host` originally, but the service
/// switched to a paid/keyed model in 2024 and now returns 200 + "missing
/// access key" for any keyless call. Fawazahmed's project is GitHub-hosted
/// JSON updated daily by a workflow and served via jsdelivr, so there's no
/// API key, no rate limit, and broad currency coverage (including VND, IDR,
/// THB which some other free APIs drop).
///
/// Design choices:
/// - SGD is the home currency. Rates are stored as "1 unit of foreign = N SGD"
///   so conversion is a single multiply (`sgdAmount = amount * rateToSGD`).
/// - Cache freshness is "same calendar day in user's timezone" — once a day
///   is more than enough for personal expense tracking.
/// - Offline + no cache = throw `noRateAvailable`. Offline + stale cache =
///   return the stale value silently (it's still better than nothing for
///   a personal app).
@MainActor
struct FXService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    static func `default`() -> FXService {
        FXService(store: .shared)
    }

    /// Get the rate "1 unit of `currencyCode` = N SGD". Cached for one day
    /// per currency. SGD itself short-circuits to 1.0.
    func rate(for currencyCode: String) async throws -> Double {
        let code = currencyCode.uppercased()
        if code == "SGD" { return 1.0 }

        // Cache hit: same calendar day.
        if let cached = try fetchCached(code: code), isSameDay(cached.fetchedOn, Date()) {
            return cached.rateToSGD
        }

        // Cache miss or stale: try to refresh from the network.
        do {
            let fresh = try await fetchRemote(code: code)
            try upsert(code: code, rateToSGD: fresh)
            return fresh
        } catch {
            // Network failed. If we have ANY cached value (even stale), use
            // it — better stale than nothing. If we have nothing, throw.
            if let cached = try fetchCached(code: code) {
                return cached.rateToSGD
            }
            if let fxError = error as? FXServiceError {
                throw fxError
            }
            throw FXServiceError.noRateAvailable(currency: code)
        }
    }

    /// Convert `amount` from `currencyCode` to SGD. Returns both the SGD
    /// amount and the rate used (so the caller can freeze it on
    /// `LocalExpense.fxRate`).
    func convert(_ amount: Double, from currencyCode: String) async throws -> (sgdAmount: Double, rate: Double) {
        let rate = try await rate(for: currencyCode)
        return (amount * rate, rate)
    }

    // MARK: - Cache I/O

    private func fetchCached(code: String) throws -> LocalFXRate? {
        let descriptor = FetchDescriptor<LocalFXRate>(
            predicate: #Predicate { $0.currencyCode == code }
        )
        return try store.context.fetch(descriptor).first
    }

    private func upsert(code: String, rateToSGD: Double) throws {
        if let existing = try fetchCached(code: code) {
            existing.rateToSGD = rateToSGD
            existing.fetchedOn = Date()
        } else {
            store.context.insert(LocalFXRate(currencyCode: code, rateToSGD: rateToSGD))
        }
        try store.context.save()
    }

    private func isSameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }

    // MARK: - Network

    /// Fetch the SGD → all-currencies rate sheet from the fawazahmed API.
    /// The JSON shape is `{ "date": "...", "sgd": { "vnd": 20604.88, ... } }`
    /// where each value is "1 SGD = N foreign", so we invert to get
    /// "1 foreign = M SGD".
    ///
    /// We fetch the whole sheet (one HTTP request gets every currency) and
    /// pluck the one we need. Cheaper than per-currency requests and lets
    /// future calls hit the SwiftData cache for any currency we've ever
    /// looked up.
    private func fetchRemote(code: String) async throws -> Double {
        let urlString = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/sgd.json"
        guard let url = URL(string: urlString) else {
            throw FXServiceError.noRateAvailable(currency: code)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FXServiceError.noRateAvailable(currency: code)
            }
            let decoded = try JSONDecoder().decode(FawazahmedCurrencyResponse.self, from: data)
            let lowerCode = code.lowercased()
            guard let foreignPerSGD = decoded.sgd[lowerCode], foreignPerSGD > 0 else {
                throw FXServiceError.missingRateInResponse(currency: code)
            }
            // The API stores rates as "1 SGD = N foreign". We need the
            // inverse: "1 foreign = M SGD" so `sgdAmount = amount * rateToSGD`.
            return 1.0 / foreignPerSGD
        } catch let fxError as FXServiceError {
            throw fxError
        } catch {
            throw FXServiceError.underlying(error)
        }
    }
}

/// Subset of the `@fawazahmed0/currency-api` response. The top-level key
/// matches the base currency (lowercased) — for our base-SGD fetch it's `sgd`,
/// containing a dictionary of `lowercased-iso-code -> foreignPerSGD`.
private struct FawazahmedCurrencyResponse: Decodable {
    let sgd: [String: Double]
}
