import Foundation
import CoreLocation
import Contacts

/// Resolves a pasted Google Maps link into a human-readable street address,
/// entirely with free, built-in iOS APIs — no Google Maps Platform key, no
/// billing, and no location permission (reverse-geocoding an arbitrary
/// coordinate does not require `CLLocationManager` authorization).
///
/// Strategy, best to worst:
///   1. Expand short links (`maps.app.goo.gl`, `goo.gl/maps`) by capturing the
///      first HTTP redirect target — lightweight (we never download the maps
///      page body).
///   2. Extract `@lat,lng` (or `!3d…!4d…` / `q=`/`ll=` coordinate forms) from
///      the expanded URL and reverse-geocode with `CLGeocoder` → a clean
///      postal address.
///   3. Fall back to the human-readable `/place/<name>` path segment when no
///      coordinate is present (plus-codes, bare search queries, offline).
///
/// Returns `nil` when nothing usable can be extracted.
struct MapsLinkResolver {

    func resolveAddress(from link: String) async -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = normalizedURL(trimmed) else { return nil }

        let target = await expandedURL(for: url) ?? url
        let urlString = target.absoluteString

        if let coordinate = coordinate(in: urlString),
           let address = await reverseGeocode(coordinate) {
            return address
        }

        // No usable coordinate: fall back to text Google embeds in the URL.
        // Short links commonly expand to `maps.google.com?q=<full address>`.
        return placeName(in: target) ?? textQuery(in: target)
    }

    /// `true` when the string is plausibly a Google Maps link worth resolving.
    /// Cheap gate used by the editors so we don't fire on arbitrary typing.
    static func looksLikeMapsLink(_ string: String) -> Bool {
        let lower = string.lowercased()
        guard lower.contains("http") else { return false }
        return lower.contains("google.com/maps")
            || lower.contains("maps.google")
            || lower.contains("maps.app.goo.gl")
            || lower.contains("goo.gl/maps")
    }

    // MARK: - URL normalisation

    private func normalizedURL(_ string: String) -> URL? {
        if let url = URL(string: string), url.scheme != nil { return url }
        return URL(string: "https://\(string)")
    }

    private func isShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "maps.app.goo.gl" || host == "goo.gl"
    }

    /// Follow a short link through all its redirects to the final URL, which
    /// carries the place data (`@lat,lng`, `/place/<name>`, or `?q=<address>`).
    /// We read only the response URL and cancel the body stream, so the large
    /// destination maps page is never fully downloaded. Non-short URLs are
    /// returned unchanged.
    private func expandedURL(for url: URL) async -> URL? {
        guard isShortLink(url) else { return url }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 12
        do {
            // `bytes(for:)` follows redirects automatically; `response.url` is
            // the final URL. Cancel the stream once we have the headers.
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            bytes.task.cancel()
            return response.url ?? url
        } catch {
            return url
        }
    }

    // MARK: - Coordinate extraction

    private func coordinate(in urlString: String) -> CLLocationCoordinate2D? {
        // Patterns ordered by reliability. Each captures (lat, lng).
        let patterns = [
            "@(-?\\d{1,3}\\.\\d+),(-?\\d{1,3}\\.\\d+)",            // /@lat,lng,zoom
            "!3d(-?\\d{1,3}\\.\\d+)!4d(-?\\d{1,3}\\.\\d+)",        // data=…!3dlat!4dlng
            "[?&](?:q|query|ll|destination|center)=(-?\\d{1,3}\\.\\d+),(-?\\d{1,3}\\.\\d+)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(urlString.startIndex..., in: urlString)
            guard let match = regex.firstMatch(in: urlString, range: range),
                  match.numberOfRanges >= 3,
                  let latRange = Range(match.range(at: 1), in: urlString),
                  let lngRange = Range(match.range(at: 2), in: urlString),
                  let lat = Double(urlString[latRange]),
                  let lng = Double(urlString[lngRange]),
                  (-90...90).contains(lat), (-180...180).contains(lng)
            else { continue }
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        return nil
    }

    // MARK: - Reverse geocoding

    private func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }
        if let postal = placemark.postalAddress {
            let formatted = CNPostalAddressFormatter.string(from: postal, style: .mailingAddress)
                .replacingOccurrences(of: "\n", with: ", ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !formatted.isEmpty { return formatted }
        }
        return placemark.name
    }

    // MARK: - Place-name fallback

    /// The decoded `/place/<name>` (or `/search/<name>`) path segment, with `+`
    /// turned back into spaces. Often a business name; useful when there are no
    /// coordinates to geocode.
    private func placeName(in url: URL) -> String? {
        let components = url.pathComponents
        guard let anchorIndex = components.firstIndex(where: { $0 == "place" || $0 == "search" }),
              anchorIndex + 1 < components.count else { return nil }
        let raw = components[anchorIndex + 1]
        guard !raw.isEmpty, !raw.hasPrefix("@") else { return nil }
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        let decoded = spaced.removingPercentEncoding ?? spaced
        let cleaned = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The `q` / `query` / `destination` query parameter as text. Short Google
    /// Maps links frequently expand to `maps.google.com?q=<full address>`, where
    /// `q` holds the place name and full postal address. Skipped when `q` is a
    /// bare `lat,lng` pair (the coordinate path handles those).
    private func textQuery(in url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        for key in ["q", "query", "destination"] {
            guard let value = items.first(where: { $0.name == key })?.value else { continue }
            // URLComponents percent-decodes but leaves `+` as-is; treat it as space.
            let cleaned = value
                .replacingOccurrences(of: "+", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !isCoordinatePair(cleaned) else { continue }
            return cleaned
        }
        return nil
    }

    /// `true` when the string is just `lat,lng` (so it isn't a usable address).
    private func isCoordinatePair(_ string: String) -> Bool {
        let pattern = "^-?\\d{1,3}\\.\\d+,\\s*-?\\d{1,3}\\.\\d+$"
        return string.range(of: pattern, options: .regularExpression) != nil
    }
}
