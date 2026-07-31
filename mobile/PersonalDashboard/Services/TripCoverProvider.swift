import Foundation

/// A resolved destination photograph: where the bytes are, and who is owed
/// credit for them (#428).
struct TripCoverCandidate: Sendable, Equatable {
    /// Direct URL to the full-resolution image file.
    let imageURL: URL
    /// True pixel dimensions, as reported by the provider. Both are required —
    /// the geometry gate cannot run without them, and admitting an unmeasured
    /// candidate is how a portrait or a panorama gets into a 2.4:1 band.
    let pixelWidth: Int
    let pixelHeight: Int
    /// "Artist · License", ready to render. Nil when the provider had nothing.
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

/// Wikipedia REST + the MediaWiki `imageinfo` API. No API key, no account, and no
/// attribution requirement on the surface where the photo appears — which is what
/// makes the "nothing is ever drawn on the photograph" layout rule possible.
/// (Unsplash was rejected for precisely the opposite reason: its terms force a
/// credit line onto the tile.)
///
/// Three requests, once per trip, then cached on disk indefinitely:
///   1. `/page/summary/<title>` for the lead image's file name.
///   2. `/page/media-list/<title>` for the rest of the page's images, in page
///      order, which is roughly best-first.
///   3. ONE batched `action=query&prop=imageinfo` for every plausible candidate:
///      original URL, true dimensions, artist and licence, all together.
///
/// ## Why the metadata call is not optional, and not per-candidate
///
/// Measured against the live API, not assumed. `media-list` returns
/// `"width": null, "height": null, "original": null` for every item — its only
/// usable field is the file title, and its `srcset` offers a 500px thumbnail,
/// which is under the resolution floor anyway. An earlier version of this file
/// read dimensions straight off `media-list` and therefore rejected every
/// fallback candidate for being unmeasured, which made the fallback path dead
/// code: "Vietnam" and "Japan" resolved to no cover at all, because their lead
/// images are a flag and an emblem and nothing was allowed to replace them.
///
/// `imageinfo` fixes that and folds the credit lookup into the same request, so
/// the request count is unchanged. It is batched (up to 50 titles per call) so
/// the fallback costs one request rather than one per candidate.
///
/// ## Known limitation: page order is not relevance order
///
/// Candidates are taken in the article's own image order, and for a large
/// country article the History section comes before Geography. Measured against
/// the live API: "Lisbon", "Bali" and "Hakuba" all resolve to real scenery, but
/// "Vietnam" resolves to an 1859 painting of the Siege of Saigon and "Japan" to a
/// medieval scroll. Both are large, landscape, correctly licensed images of the
/// right subject, so no reasonable gate rejects them — they are simply not
/// photography.
///
/// This is a ranking problem, not a correctness one, and fixing it properly means
/// choosing a better page for the query (`Geography of X`, `Tourism in X`) or a
/// different candidate ordering. That is a product decision, deliberately left to
/// its own ticket rather than guessed at here. Recorded so nobody has to
/// rediscover it: the feature works, and a broad destination name can still pick
/// a museum piece.
struct WikimediaTripCoverProvider: TripCoverProvider {

    /// Same 10 s ceiling and status check `FXService.fetchRemote(code:)` uses for
    /// its public JSON API. Copied rather than reinvented so both network call
    /// shapes in this app behave the same way when the network is bad.
    private let timeout: TimeInterval = 10

    /// How far down a page's media list to look. Lead images come first and
    /// relevance drops off fast, so a page's 80th image is not worth a look.
    private let candidateLimit = 12

    func cover(forDestination destination: String) async throws -> TripCoverCandidate? {
        let page = Self.pageTitle(from: destination)
        guard !page.isEmpty else { return nil }

        // Lead image first: it is the page's own choice of representative image,
        // so when it is a photograph it is almost always the right one.
        var fileTitles: [String] = []
        if let lead = try await leadImageFileTitle(page: page) {
            fileTitles.append(lead)
        }
        // Wikipedia lead images are encyclopedic, so a flag, an emblem, an
        // orthographic projection or a locator map is a very common first answer.
        // The rest of the page is the fallback.
        fileTitles += try await mediaListFileTitles(page: page)

        // Filename gate BEFORE spending the metadata request. A flag, an emblem
        // or a rasterised SVG is identifiable from its name alone, so there is no
        // reason to ask how big it is.
        var seen = Set<String>()
        let plausible = fileTitles
            .filter { seen.insert(Self.normalisedTitle($0)).inserted }
            .filter { Self.passesNameGate($0) }
            .prefix(candidateLimit)
        guard !plausible.isEmpty else { return nil }

        let described = try await imageInfo(fileTitles: Array(plausible))

        // Preserve the order they were offered in: lead image, then page order.
        for title in plausible {
            guard let candidate = described[Self.normalisedTitle(title)] else { continue }
            if Self.passesGate(candidate) { return candidate }
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

    /// The MediaWiki API normalises `File:Flag_of_Vietnam.svg` to
    /// `File:Flag of Vietnam.svg` in its response keys, so titles are matched on a
    /// canonical form rather than on the exact string that was sent.
    static func normalisedTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Quality gate

    /// Filename patterns that mean "this is not a photograph of a place".
    ///
    /// `map` is bounded by `(?<![a-z]) … (?![a-z])` rather than by `\b`, and this
    /// is a correction to the pattern this ticket specified, not a stylistic
    /// choice. Wikimedia filenames use UNDERSCORES where a title has spaces, and
    /// `_` is a word character, so `\b` finds no boundary inside `Map_of_Bali`:
    /// `\bmap\b` let every locator map straight through the gate it most exists to
    /// stop. Caught by a unit test, not by eye. A letter-boundary keeps the intent
    /// that made `\b` attractive: it still refuses to fire on `Maputo`,
    /// `Mapo_District` or `roadmap`.
    ///
    /// `location`, `marker` and `orthographic` are additions, all from live
    /// responses: `Bali` returns `Bali_in_Indonesia_(special_marker).svg` and
    /// `Vietnam` returns `Location_Vietnam_ASEAN.svg` and
    /// `Vietnam_(orthographic_projection).svg`. None contains the word "map".
    private static let rejectedNamePattern = [
        "flag", "coat[_ ]?of[_ ]?arms", "locator", "(?<![a-z])map(?![a-z])",
        "seal", "logo", "emblem", "montage", "collage",
        "location", "marker", "orthographic"
    ].joined(separator: "|")

    /// Extensions that cannot be shown in the band at all: vector artwork (which
    /// is what a flag, an emblem or a locator map usually is) and video.
    private static let rejectedExtensions: Set<String> = ["svg", "ogv", "webm", "gif"]

    /// Minimum long-edge resolution. The band is 868pt wide at its widest tested
    /// macOS pane, so anything under 900 px would be upscaled.
    private static let minimumPixelWidth = 900

    /// Aspect bounds. A 2.4:1 band crops a portrait by throwing away most of it
    /// and crops a panorama into a slice of its middle, so both are rejected
    /// rather than cropped badly.
    private static let maximumAspect: Double = 3.0
    private static let minimumAspect: Double = 1.1

    /// The name half of the gate, runnable on a bare file title before any
    /// metadata has been fetched. Split out from `passesGate` so an obvious flag
    /// costs no request.
    static func passesNameGate(_ rawName: String) -> Bool {
        let name = rawName.removingPercentEncoding ?? rawName

        // A rasterised SVG thumbnail is named `NNNpx-Foo.svg.png`, so the file
        // extension says "png" while the artwork is vector. Anything Wikimedia
        // holds as an SVG is a diagram, a flag, an emblem or a map — never a
        // photograph — so the marker to check is `.svg.` anywhere in the name.
        // This is what let `Bali_in_Indonesia_(special_marker).svg.png` through in
        // a live run.
        if name.range(of: "\\.svg\\.", options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if rejectedExtensions.contains(ext) { return false }

        return name.range(
            of: rejectedNamePattern, options: [.regularExpression, .caseInsensitive]
        ) == nil
    }

    /// The full gate: the name rules above plus geometry. Static and pure so it is
    /// directly testable without a network.
    static func passesGate(_ candidate: TripCoverCandidate) -> Bool {
        guard passesNameGate(candidate.imageURL.lastPathComponent) else { return false }
        guard candidate.pixelWidth >= minimumPixelWidth, candidate.pixelHeight > 0 else {
            return false
        }
        let aspect = Double(candidate.pixelWidth) / Double(candidate.pixelHeight)
        return aspect <= maximumAspect && aspect >= minimumAspect
    }

    // MARK: - Requests

    /// The page's lead image, as a `File:` title.
    ///
    /// `summary` hands back a THUMBNAIL URL (`960px-Flag_of_Vietnam.svg.png`), not
    /// the original, so the name is unwrapped back to the file title rather than
    /// used directly: a `NNNpx-` prefix would break the metadata lookup, and the
    /// thumbnail's dimensions are not the file's.
    private func leadImageFileTitle(page: String) async throws -> String? {
        guard let segment = Self.encodedPathSegment(page),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(segment)") else {
            throw TripCoverProviderError.badRequest
        }
        // A 404 means "no such page", which is a legitimate `none` rather than a
        // transient failure.
        guard let data = try await get(url, notFoundIsEmpty: true) else { return nil }
        let decoded: SummaryResponse
        do {
            decoded = try JSONDecoder().decode(SummaryResponse.self, from: data)
        } catch {
            throw TripCoverProviderError.undecodable(error)
        }
        guard let source = decoded.originalimage?.source,
              let url = URL(string: source) else { return nil }
        return "File:" + Self.fileName(fromUploadURL: url)
    }

    /// Every image on the page, as `File:` titles, in page order.
    private func mediaListFileTitles(page: String) async throws -> [String] {
        guard let segment = Self.encodedPathSegment(page),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/media-list/\(segment)") else {
            throw TripCoverProviderError.badRequest
        }
        guard let data = try await get(url, notFoundIsEmpty: true) else { return [] }
        let decoded: MediaListResponse
        do {
            decoded = try JSONDecoder().decode(MediaListResponse.self, from: data)
        } catch {
            throw TripCoverProviderError.undecodable(error)
        }
        return (decoded.items ?? [])
            .filter { $0.type == "image" }
            .compactMap { $0.title }
    }

    /// One batched metadata call for up to 50 file titles: original URL, true
    /// dimensions, artist and licence. Keyed by `normalisedTitle`.
    ///
    /// Queried against `en.wikipedia.org` rather than Commons directly, because
    /// en.wikipedia resolves BOTH its own local uploads and shared Commons files,
    /// while Commons knows nothing about a locally-uploaded file. The description
    /// URL it returns points at whichever wiki actually holds the file, so the
    /// credit link is correct either way.
    private func imageInfo(fileTitles: [String]) async throws -> [String: TripCoverCandidate] {
        guard !fileTitles.isEmpty else { return [:] }
        let joined = fileTitles.prefix(50).joined(separator: "|")
        guard let encoded = joined.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string:
                "https://en.wikipedia.org/w/api.php?action=query&format=json"
                + "&prop=imageinfo&iiprop=url%7Csize%7Cextmetadata&titles=\(encoded)"
              ) else {
            throw TripCoverProviderError.badRequest
        }
        guard let data = try await get(url, notFoundIsEmpty: true) else { return [:] }
        let decoded: ImageInfoResponse
        do {
            decoded = try JSONDecoder().decode(ImageInfoResponse.self, from: data)
        } catch {
            throw TripCoverProviderError.undecodable(error)
        }

        var out: [String: TripCoverCandidate] = [:]
        for page in decoded.query?.pages?.values ?? [:].values {
            guard let title = page.title,
                  let info = page.imageinfo?.first,
                  let source = info.url, let imageURL = URL(string: source),
                  let width = info.width, let height = info.height else { continue }

            let meta = info.extmetadata
            let artist = meta?.Artist?.value.map(Self.strippingHTML)
            let licence = meta?.LicenseShortName?.value.map(Self.strippingHTML)
            let credit = [artist, licence]
                .compactMap { ($0?.isEmpty == false) ? $0 : nil }
                .joined(separator: " · ")

            out[Self.normalisedTitle(title)] = TripCoverCandidate(
                imageURL: imageURL,
                pixelWidth: width,
                pixelHeight: height,
                attribution: credit.isEmpty ? nil : credit,
                attributionURL: info.descriptionurl.flatMap(URL.init(string:))
            )
        }
        return out
    }

    // MARK: - Name helpers

    /// Recover a file name from an upload URL, undoing the two things Wikimedia's
    /// thumbnailer does to it: a `NNNpx-` size prefix, and a raster extension
    /// appended to a vector original (`Foo.svg` becomes `500px-Foo.svg.png`).
    static func fileName(fromUploadURL url: URL) -> String {
        let raw = url.lastPathComponent
        var name = raw.removingPercentEncoding ?? raw

        if let match = name.range(of: "^[0-9]+px-", options: .regularExpression) {
            name.removeSubrange(match)
        }
        // `Foo.svg.png` → `Foo.svg`. Only unwraps ONE raster suffix, and only when
        // the name underneath still has an extension of its own.
        for suffix in [".png", ".jpg", ".jpeg"] where name.lowercased().hasSuffix(suffix) {
            let stem = String(name.dropLast(suffix.count))
            if (stem as NSString).pathExtension.lowercased() == "svg" {
                name = stem
            }
            break
        }
        return name
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
    }
    let originalimage: ImageInfo?
}

/// Subset of `/api/rest_v1/page/media-list/<title>`.
///
/// Only `title` and `type` are read. `width`, `height` and `original` are present
/// in the schema but come back null in practice, which is the whole reason the
/// `imageinfo` call exists — see the type doc comment above.
private struct MediaListResponse: Decodable {
    struct Item: Decodable {
        let title: String?
        let type: String?
    }
    let items: [Item]?
}

/// Subset of `action=query&prop=imageinfo&iiprop=url|size|extmetadata`.
/// Field names match the API's own casing, which is capitalised for extmetadata.
private struct ImageInfoResponse: Decodable {
    struct Query: Decodable {
        /// Keyed by page id, which is unknown ahead of time (and is `-1` for a
        /// title the wiki does not have).
        let pages: [String: Page]?
    }
    struct Page: Decodable {
        let title: String?
        let imageinfo: [Info]?
    }
    struct Info: Decodable {
        let url: String?
        let descriptionurl: String?
        let width: Int?
        let height: Int?
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
