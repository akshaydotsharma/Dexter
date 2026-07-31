import Foundation

/// A resolved destination photograph: where the bytes are, and who is owed
/// credit for them (#428).
struct TripCoverCandidate: Sendable, Equatable {
    /// Direct URL to the full-resolution image file.
    let imageURL: URL
    /// Pixel dimensions, as reported by the provider. Both are required — the
    /// quality gate cannot run without them, and admitting an unmeasured
    /// candidate is how a portrait or a panorama gets into a 2.4:1 band.
    let pixelWidth: Int
    let pixelHeight: Int
    /// "Artist — License", ready to render. Nil when the provider had nothing.
    let attribution: String?
    /// Link to the file's description page, where the full licence lives.
    let attributionURL: URL?
}

/// One method, so swapping providers later is a one-file change rather than a
/// redesign. `WikimediaTripCoverProvider` is the only implementation today.
///
/// The contract: return a candidate that has ALREADY passed the quality gate, or
/// nil when the place is real but nothing suitable exists (which is a legitimate
/// outcome, not a failure), or throw for a transient problem worth retrying.
/// Callers map those three cases onto `LocalTrip.coverImageState`'s `resolved` /
/// `none` / `failed`.
protocol TripCoverProvider: Sendable {
    func cover(forDestination destination: String) async throws -> TripCoverCandidate?
}

/// Transient failures. Distinct from "nothing suitable found", which is `nil`.
enum TripCoverProviderError: LocalizedError {
    case badRequest
    case transport(Error)
    case badStatus(Int)
    case undecodable(Error)

    var errorDescription: String? {
        switch self {
        case .badRequest:           return "Couldn't build the cover lookup request."
        case .transport(let e):     return e.localizedDescription
        case .badStatus(let code):  return "Cover lookup failed with status \(code)."
        case .undecodable(let e):   return "Couldn't read the cover response: \(e.localizedDescription)"
        }
    }
}

// MARK: - Wikimedia

/// Wikipedia REST + Wikimedia Commons. No API key, no account, no attribution
/// requirement on the surface where the photo appears — which is what makes the
/// "nothing is ever drawn on the photograph" layout rule possible. (Unsplash was
/// rejected for precisely the opposite reason: its terms force a credit line onto
/// the tile.)
///
/// Up to three requests, once per trip, then cached on disk indefinitely:
///   1. `/page/summary/<title>` for the lead image.
///   2. `/page/media-list/<title>` only if the lead image fails the gate.
///   3. Commons `imageinfo` for the credit line.
struct WikimediaTripCoverProvider: TripCoverProvider {

    /// Same 10 s ceiling and status check `FXService.fetchRemote(code:)` uses for
    /// its public JSON API. Copied rather than reinvented so both network call
    /// shapes in this app behave the same way when the network is bad.
    private let timeout: TimeInterval = 10

    func cover(forDestination destination: String) async throws -> TripCoverCandidate? {
        let title = Self.pageTitle(from: destination)
        guard !title.isEmpty else { return nil }

        // 1. Lead image.
        if let lead = try await leadImage(title: title), Self.passesGate(lead) {
            return try await withAttribution(lead)
        }

        // 2. Wikipedia lead images are encyclopedic, so a flag, a coat of arms or
        //    a locator map is a common first answer. Fall through to the page's
        //    full media list and take the first candidate that passes.
        if let fromMedia = try await firstPassingMediaItem(title: title) {
            return try await withAttribution(fromMedia)
        }

        // Nothing suitable. Not a failure: the caller draws generated art, which
        // is a first-class state, and stops retrying.
        return nil
    }

    // MARK: - Query normalisation

    /// Turn a trip name into a Wikipedia page title.
    ///
    /// `trip.name` is the only source available: `LocalItineraryItem` has no
    /// structured place field, only free-text `address` and `venue`, so there is
    /// nothing better to prefer.
    ///
    /// Years and possessives come off because they are how people label trips and
    /// not how Wikipedia titles places: "Japan 2026" is a trip, "Japan" is a
    /// page, and "Japan 2026" resolves to nothing.
    static func pageTitle(from destination: String) -> String {
        var s = destination

        // Possessives first, so "Rohan's Wedding" does not leave a stray "s".
        s = s.replacingOccurrences(of: "’s", with: "")
        s = s.replacingOccurrences(of: "'s", with: "")

        // Four-digit years, 1900–2099. Scoped rather than "any 4 digits" so a
        // place whose name contains a number is not mangled.
        if let regex = try? NSRegularExpression(pattern: "\\b(19|20)\\d{2}\\b") {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        }

        // Collapse whatever whitespace that left behind.
        let words = s.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Percent-encode a title for a REST path segment. Wikipedia titles use
    /// underscores for spaces.
    private static func encodedPathSegment(_ title: String) -> String? {
        let underscored = title.replacingOccurrences(of: " ", with: "_")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return underscored.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    // MARK: - Quality gate

    /// Filename patterns that mean "this is not a photograph of a place".
    /// Wikipedia's lead image for a country is very often one of these.
    ///
    /// `map` is bounded by `(?<![a-z]) … (?![a-z])` rather than by `\b`, and this
    /// is a correction to the pattern this ticket specified, not a stylistic
    /// choice. Wikimedia filenames use UNDERSCORES where a title has spaces, and
    /// `_` is a word character, so `\b` finds no boundary inside `Map_of_Bali`:
    /// `\bmap\b` let every locator map straight through the gate, which is the
    /// single thing it most exists to stop. Caught by a unit test, not by eye.
    ///
    /// A letter-boundary keeps the intent that made `\b` attractive: it still
    /// refuses to fire on `Maputo`, `Mapo_District` or `roadmap`.
    private static let rejectedNamePattern =
        "flag|coat[_ ]?of[_ ]?arms|locator|(?<![a-z])map(?![a-z])|seal|logo|emblem|montage|collage"

    /// Extensions that cannot be shown in the band at all: vector artwork (which
    /// is what a flag or emblem usually is) and video.
    private static let rejectedExtensions: Set<String> = ["svg", "ogv"]

    /// Minimum long-edge resolution. The band is 868pt wide at its widest tested
    /// macOS pane, so anything under 900 px would be upscaled.
    private static let minimumPixelWidth = 900

    /// Aspect bounds. A 2.4:1 band crops a portrait by throwing away most of it
    /// and crops a panorama into a slice of its middle, so both are rejected
    /// rather than cropped badly.
    private static let maximumAspect: Double = 3.0
    private static let minimumAspect: Double = 1.1

    /// Whether a candidate is worth showing. Static and pure so it is directly
    /// testable without a network.
    static func passesGate(_ candidate: TripCoverCandidate) -> Bool {
        let filename = candidate.imageURL.lastPathComponent
            .removingPercentEncoding ?? candidate.imageURL.lastPathComponent

        if rejectedExtensions.contains(candidate.imageURL.pathExtension.lowercased()) {
            return false
        }
        if filename.range(of: rejectedNamePattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }
        guard candidate.pixelWidth >= minimumPixelWidth, candidate.pixelHeight > 0 else {
            return false
        }
        let aspect = Double(candidate.pixelWidth) / Double(candidate.pixelHeight)
        return aspect <= maximumAspect && aspect >= minimumAspect
    }

    // MARK: - Requests

    private func leadImage(title: String) async throws -> TripCoverCandidate? {
        guard let segment = Self.encodedPathSegment(title),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(segment)") else {
            throw TripCoverProviderError.badRequest
        }
        // A 404 here means "no such page", which is a legitimate `none`, so it is
        // not treated as a transient failure.
        guard let data = try await get(url, notFoundIsEmpty: true) else { return nil }
        let decoded: SummaryResponse
        do {
            decoded = try JSONDecoder().decode(SummaryResponse.self, from: data)
        } catch {
            throw TripCoverProviderError.undecodable(error)
        }
        guard let image = decoded.originalimage,
              let source = URL(string: image.source),
              let width = image.width, let height = image.height else {
            return nil
        }
        return TripCoverCandidate(
            imageURL: source,
            pixelWidth: width,
            pixelHeight: height,
            attribution: nil,
            attributionURL: nil
        )
    }

    private func firstPassingMediaItem(title: String) async throws -> TripCoverCandidate? {
        guard let segment = Self.encodedPathSegment(title),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/media-list/\(segment)") else {
            throw TripCoverProviderError.badRequest
        }
        guard let data = try await get(url, notFoundIsEmpty: true) else { return nil }
        let decoded: MediaListResponse
        do {
            decoded = try JSONDecoder().decode(MediaListResponse.self, from: data)
        } catch {
            throw TripCoverProviderError.undecodable(error)
        }
        for item in decoded.items ?? [] {
            guard item.type == "image",
                  let width = item.width, let height = item.height,
                  let source = item.resolvedSourceURL else { continue }
            let candidate = TripCoverCandidate(
                imageURL: source,
                pixelWidth: width,
                pixelHeight: height,
                attribution: nil,
                attributionURL: nil
            )
            if Self.passesGate(candidate) { return candidate }
        }
        return nil
    }

    /// One extra Commons call for the credit line. A failure here downgrades the
    /// candidate to "no credit recorded" rather than losing the photograph: a
    /// missing credit is a gap in metadata, and the layout owes nothing on the
    /// surface, so failing the whole fetch over it would be the wrong trade.
    private func withAttribution(_ candidate: TripCoverCandidate) async throws -> TripCoverCandidate {
        let rawName = candidate.imageURL.lastPathComponent
        let fileName = rawName.removingPercentEncoding ?? rawName
        guard let encodedTitle = "File:\(fileName)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string:
                "https://commons.wikimedia.org/w/api.php?action=query&format=json"
                + "&prop=imageinfo&iiprop=extmetadata&titles=\(encodedTitle)"
              ) else {
            return candidate
        }
        let filePageURL = URL(string:
            "https://commons.wikimedia.org/wiki/File:"
            + ((fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)) ?? fileName)
        )

        // `try?` on a `Data?`-returning throwing call flattens to `Data?`, so one
        // optional binding covers both "the request failed" and "404".
        guard let data = try? await get(url, notFoundIsEmpty: true) else {
            return Self.replacing(candidate, attribution: nil, attributionURL: filePageURL)
        }
        guard let decoded = try? JSONDecoder().decode(CommonsQueryResponse.self, from: data),
              let meta = decoded.query?.pages?.values
                .compactMap({ $0.imageinfo?.first?.extmetadata })
                .first else {
            return Self.replacing(candidate, attribution: nil, attributionURL: filePageURL)
        }

        let artist = meta.Artist?.value.map(Self.strippingHTML)
        let licence = meta.LicenseShortName?.value.map(Self.strippingHTML)
        let credit = [artist, licence]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")

        return Self.replacing(
            candidate,
            attribution: credit.isEmpty ? nil : credit,
            attributionURL: filePageURL
        )
    }

    private static func replacing(
        _ candidate: TripCoverCandidate,
        attribution: String?,
        attributionURL: URL?
    ) -> TripCoverCandidate {
        TripCoverCandidate(
            imageURL: candidate.imageURL,
            pixelWidth: candidate.pixelWidth,
            pixelHeight: candidate.pixelHeight,
            attribution: attribution,
            attributionURL: attributionURL
        )
    }

    /// Commons returns `Artist` as an HTML fragment (usually an anchor). Reduce it
    /// to text and unescape the handful of entities that actually appear.
    static func strippingHTML(_ raw: String) -> String {
        var s = raw.replacingOccurrences(
            of: "<[^>]+>", with: "", options: [.regularExpression]
        )
        for (entity, replacement) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")
        ] {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transport

    /// Public JSON GET, shaped after `FXService.fetchRemote(code:)`: explicit
    /// timeout, explicit status check, transport errors wrapped rather than
    /// leaked. Returns nil (rather than throwing) on 404 when the caller has said
    /// a missing page is a legitimate empty answer.
    private func get(_ url: URL, notFoundIsEmpty: Bool) async throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // Wikimedia asks for a descriptive UA on API traffic.
        request.setValue("Dexter/1.0 (personal use; SwiftUI)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TripCoverProviderError.badStatus(-1)
            }
            if http.statusCode == 404, notFoundIsEmpty { return nil }
            guard (200..<300).contains(http.statusCode) else {
                throw TripCoverProviderError.badStatus(http.statusCode)
            }
            return data
        } catch let known as TripCoverProviderError {
            throw known
        } catch {
            throw TripCoverProviderError.transport(error)
        }
    }

}

// MARK: - Byte download

/// Fetching the candidate's bytes is deliberately NOT on `TripCoverProvider`,
/// which stays the one method the ticket specifies. Downloading a file at a URL
/// is provider-agnostic — any replacement provider would hand back a URL and want
/// exactly this — so it lives here rather than being reimplemented per provider.
enum TripCoverDownload {
    /// A 404 here IS a failure, unlike the metadata calls: the API has just told
    /// us this file exists.
    static func imageData(at url: URL, timeout: TimeInterval = 10) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Dexter/1.0 (personal use; SwiftUI)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw TripCoverProviderError.badStatus(
                    (response as? HTTPURLResponse)?.statusCode ?? -1
                )
            }
            return data
        } catch let known as TripCoverProviderError {
            throw known
        } catch {
            throw TripCoverProviderError.transport(error)
        }
    }
}

// MARK: - Wire shapes

/// Subset of `/api/rest_v1/page/summary/<title>`.
private struct SummaryResponse: Decodable {
    struct ImageInfo: Decodable {
        let source: String
        let width: Int?
        let height: Int?
    }
    let originalimage: ImageInfo?
}

/// Subset of `/api/rest_v1/page/media-list/<title>`.
private struct MediaListResponse: Decodable {
    struct Item: Decodable {
        struct Original: Decodable { let source: String? }
        struct SrcSetEntry: Decodable { let src: String? }

        let type: String?
        let width: Int?
        let height: Int?
        let original: Original?
        let srcset: [SrcSetEntry]?

        /// `original.source` when present, else the first `srcset` entry. Both
        /// arrive protocol-relative (`//upload.wikimedia.org/…`), which `URL`
        /// will happily parse into something unusable, so the scheme is filled in.
        var resolvedSourceURL: URL? {
            let raw = original?.source ?? srcset?.first?.src
            guard var raw else { return nil }
            if raw.hasPrefix("//") { raw = "https:" + raw }
            return URL(string: raw)
        }
    }
    let items: [Item]?
}

/// Subset of the Commons `action=query&prop=imageinfo&iiprop=extmetadata`
/// response. Field names match the API's own casing, which is capitalised.
private struct CommonsQueryResponse: Decodable {
    struct Query: Decodable {
        /// Keyed by page id, which is unknown ahead of time.
        let pages: [String: Page]?
    }
    struct Page: Decodable {
        let imageinfo: [ImageInfo]?
    }
    struct ImageInfo: Decodable {
        let extmetadata: ExtMetadata?
    }
    struct ExtMetadata: Decodable {
        struct Field: Decodable { let value: String? }
        // swiftlint:disable identifier_name
        let Artist: Field?
        let LicenseShortName: Field?
        // swiftlint:enable identifier_name
    }
    let query: Query?
}
