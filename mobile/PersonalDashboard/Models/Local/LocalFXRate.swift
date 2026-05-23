import Foundation
import SwiftData

/// Cached foreign-exchange rate keyed by currency code (Finance v1).
///
/// One row per currency. `FXService` upserts on every fetch and reads the
/// most recent row before going out to the network — once-per-day per
/// currency. Stored separately from `LocalExpense` so dashboard totals
/// don't have to recompute conversions on every aggregation.
@Model
final class LocalFXRate {
    /// ISO 4217 code (e.g. "USD", "EUR"). Acts as the lookup key.
    @Attribute(.unique) var currencyCode: String

    /// How many SGD = 1 unit of `currencyCode`. SGD itself is `1.0`.
    var rateToSGD: Double

    /// Wall-clock moment we fetched (or last verified) this rate. FXService
    /// considers anything within the same day "fresh" and skips network.
    var fetchedOn: Date

    init(
        currencyCode: String,
        rateToSGD: Double,
        fetchedOn: Date = Date()
    ) {
        self.currencyCode = currencyCode
        self.rateToSGD = rateToSGD
        self.fetchedOn = fetchedOn
    }
}
