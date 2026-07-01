import Foundation
import CoreLocation

/// Forward-geocodes a postal address into an exact coordinate, entirely with
/// free, built-in iOS APIs — no Google Maps Platform key, no billing, and no
/// location permission (`CLGeocoder`'s forward direction geocodes an arbitrary
/// address string; it does NOT require `CLLocationManager` authorization).
///
/// The mirror image of `MapsLinkResolver`, which reverse-geocodes a coordinate
/// into an address. This one goes address -> coordinate, then builds a Google
/// Maps *pin* URL (`?api=1&query=<lat>,<lng>`) that lands on an exact point
/// rather than a name+address search that Google has to re-resolve.
///
/// Everything degrades to `nil`: any error, empty result, rate-limit, or a
/// slow geocode past the timeout returns `nil` so the caller can keep the
/// existing search link untouched. Nothing throws.
struct AddressGeocoder {

    /// How long a single forward-geocode may run before we give up. Apple's
    /// geocoder is a shared, rate-limited network service; a slow one must not
    /// stall the ~22s email-capture budget, so we cap each request.
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 6) {
        self.timeout = timeout
    }

    /// Forward-geocode an address to a coordinate. Prefers the ADDRESS string
    /// (Apple's geocoder is address-oriented; a bare POI name confuses it).
    /// When the address alone yields nothing and a venue `name` is available,
    /// retries once with "name, address". Returns `nil` on any failure.
    func resolveCoordinate(address: String, name: String? = nil) async -> CLLocationCoordinate2D? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return nil }

        if let coordinate = await geocode(trimmedAddress) {
            return coordinate
        }

        // Retry with the venue name prepended — helps when the raw address is
        // partial (e.g. "Via Nazionale 207, Rome" missing a house-level pin).
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let combined = "\(name), \(trimmedAddress)"
            if combined != trimmedAddress, let coordinate = await geocode(combined) {
                return coordinate
            }
        }

        return nil
    }

    /// Builds a Google Maps *pin* URL from an exact coordinate:
    /// `https://www.google.com/maps/search/?api=1&query=<lat>,<lng>`.
    /// Sits alongside `LocalItineraryItem.googleMapsSearchURL` (same host and
    /// `?api=1&query=` shape) so the two link forms stay consistent — the only
    /// difference is the `query` value is a coordinate, not a name+address.
    /// Lat/lng are formatted to 6 decimals with an `en_US_POSIX` locale so the
    /// device locale can never substitute a comma for the decimal separator.
    static func pinURL(for coordinate: CLLocationCoordinate2D) -> URL? {
        let lat = posixDecimal(coordinate.latitude)
        let lng = posixDecimal(coordinate.longitude)
        var components = URLComponents(string: "https://www.google.com/maps/search/")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "query", value: "\(lat),\(lng)")
        ]
        return components?.url
    }

    // MARK: - Geocoding

    /// One forward-geocode with a hard timeout. `CLGeocoder`'s only async
    /// entry point is the completion-handler API, so we wrap it in a
    /// continuation and race it against `Task.sleep`. On timeout we cancel the
    /// in-flight geocode and return `nil`. Any thrown error (network failure,
    /// `.geocodeFoundNoResult`, `.geocodeCanceled`, rate-limit) also -> `nil`.
    private func geocode(_ addressString: String) async -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        return await withTaskGroup(of: CLLocationCoordinate2D?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    geocoder.geocodeAddressString(addressString) { placemarks, _ in
                        continuation.resume(returning: placemarks?.first?.location?.coordinate)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                return nil
            }

            // First task to finish wins. If the timeout returns first, cancel
            // the outstanding geocode so it can't leak past the deadline.
            let result = await group.next() ?? nil
            group.cancelAll()
            geocoder.cancelGeocode()
            return result
        }
    }

    // MARK: - Formatting

    /// Fixed 6-decimal formatting with a POSIX locale — guarantees a `.` decimal
    /// separator regardless of the device's regional settings.
    private static func posixDecimal(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
