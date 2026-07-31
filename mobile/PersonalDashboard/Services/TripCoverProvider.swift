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

/// Wikivoyage + Wikipedia REST, resolved through the MediaWiki `imageinfo` API.
/// No API key, no account, and no attribution requirement on the surface where
/// the photo appears — which is what makes the "nothing is ever drawn on the
/// photograph" layout rule possible. (Unsplash was rejected for precisely the
/// opposite reason: its terms force a credit line onto the tile.)
///
/// ## Corpus order is the whole design
///
/// **Wikivoyage first, Wikipedia second.** Wikivoyage is a travel guide on the
/// same foundation, pointing at the same Commons files under the same licences,
/// so its image pool is scenery *by construction* rather than by ranking luck.
/// Wikipedia is an encyclopedia, and an encyclopedia article about a country
/// leads with the flag and puts History before Geography.
///
/// Measured, not assumed. Wikipedia alone gave: Vietnam → an 1859 painting of the
/// Siege of Saigon, Japan → a medieval scroll. Both are large, landscape,
/// correctly licensed images of the right subject, so no reasonable gate rejects
/// them; they are simply not photography. The gate was working and the *corpus*
/// was wrong.
///
/// Wikipedia is still the fallback, and is not vestigial: plenty of specific
/// places exist in one corpus and not the other.
///
/// ## Requests
///
/// Per corpus, in order, stopping at the first corpus that yields a candidate:
///   1. `/page/summary/<title>` for the lead image — **Wikipedia only**, see
///      `Corpus.usesLeadImage`.
///   2. `/page/media-list/<title>` for the page's images, in page order.
///   3. ONE batched `action=query&prop=imageinfo` for every name-plausible
///      candidate: original URL, true dimensions, artist and licence together.
///
/// So the common case (the place is on Wikivoyage) is TWO requests, fewer than
/// the Wikipedia-only path it replaces. The worst case (no Wikivoyage page) is
/// five. The ticket's "up to three requests" budget is superseded by the corpus
/// change, deliberately.
///
/// ## Why the metadata call is not optional, and not per-candidate
///
/// `media-list` returns `"width": null, "height": null, "original": null` for
/// every item — its only usable field is the file title, and its `srcset` offers
/// a 500px thumbnail, under the resolution floor anyway. An earlier version read
/// dimensions straight off `media-list` and therefore rejected every candidate
/// for being unmeasured, which made the whole fallback path dead code.
///
/// `imageinfo` fixes that and folds the credit lookup into the same request. It
/// is batched (up to 50 titles per call) so a corpus costs one request rather
/// than one per candidate. It is always addressed to `en.wikipedia.org`
/// regardless of which corpus supplied the titles, because that host resolves
/// BOTH its own local uploads and shared Commons files, and every Wikivoyage
/// image is a Commons file. (Such titles come back with negative page ids and
/// `missing`, and carry full `imageinfo` anyway — verified live.)
struct WikimediaTripCoverProvider: TripCoverProvider {

    /// The corpora searched, in order. Order is load-bearing and pinned by a test.
    enum Corpus: String, CaseIterable {
        case wikivoyage = "en.wikivoyage.org"
        case wikipedia  = "en.wikipedia.org"

        /// Whether to trust this corpus's `summary` lead image as a first
        /// candidate.
        ///
        /// False for Wikivoyage, and this is measured rather than cautious: its
        /// lead image is good for Japan and Bali but is a globe SVG for Vietnam
        /// and a district-boundary map for Lisbon. Its `media-list` is the useful
        /// part. True for Wikipedia, where the lead image is the article's own
        /// choice of representative image and is worth a look before the body
        /// even though it is often a flag.
        var usesLeadImage: Bool {
            switch self {
            case .wikivoyage: return false
            case .wikipedia:  return true
            }
        }

        /// Minimum number of name-plausible candidates before this corpus is
        /// trusted, or nil for no minimum.
        ///
        /// A Wikivoyage page offering one or two images is a stub, not a guide, so
        /// the "scenery by construction" argument does not hold for it and
        /// Wikipedia is the better read of intent. Measured: `Hakuba`'s Wikivoyage
        /// page has exactly ONE image, a photograph of a train on the Chuo Main
        /// Line, which beat Wikipedia's `Hakuba_Happo-one_Winter_Resort.JPG`
        /// purely by corpus order. Every other destination tested offers 9 to 74.
        ///
        /// Counted on the NAME gate rather than the full gate so the decision costs
        /// no extra request. Nothing is lost when the threshold trips: a skipped
        /// stub's candidates are retried as a last resort if no corpus yields
        /// anything (see `cover(forDestination:)`).
        ///
        /// nil for Wikipedia: it is already the fallback, and a threshold there
        /// would only convert usable covers into `none`.
        var stubThreshold: Int? {
            switch self {
            case .wikivoyage: return 3
            case .wikipedia:  return nil
            }
        }
    }

    static let corpusOrder: [Corpus] = [.wikivoyage, .wikipedia]

    /// Same 10 s ceiling and status check `FXService.fetchRemote(code:)` uses for
    /// its public JSON API. Copied rather than reinvented so both network call
    /// shapes in this app behave the same way when the network is bad.
    private let timeout: TimeInterval = 10

    /// How far down a page's media list to look. Relevance drops off fast, so a
    /// page's 80th image is not worth a look. Japan's Wikivoyage page has 74.
    private let candidateLimit = 12

    func cover(forDestination destination: String) async throws -> TripCoverCandidate? {
        let page = Self.pageTitle(from: destination)
        guard !page.isEmpty else { return nil }

        // A transient failure in one corpus must NOT be reported as "nothing
        // suitable exists": `none` is a permanent answer and would leave the trip
        // with generated art forever after one bad network moment. So the search
        // continues past an error, and if nothing is found AND something failed,
        // the failure is rethrown so the caller records `failed` and retries.
        var firstError: Error?
        /// Candidates from a corpus that was skipped for being a stub. Retried at
        /// the very end rather than discarded: a thin guide's one good photograph
        /// still beats no cover at all.
        var deferredStubTitles: [String] = []

        for corpus in Self.corpusOrder {
            do {
                var fileTitles: [String] = []
                if corpus.usesLeadImage, let lead = try await leadImageFileTitle(corpus: corpus, page: page) {
                    fileTitles.append(lead)
                }
                fileTitles += try await mediaListFileTitles(corpus: corpus, page: page)

                let plausible = Self.namePlausibleTitles(fileTitles, limit: candidateLimit)
                if let minimum = corpus.stubThreshold, plausible.count < minimum {
                    deferredStubTitles += plausible
                    continue
                }
                if let hit = try await firstPassingCandidate(namePlausible: plausible) {
                    return hit
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // Last resort: whatever a skipped stub had to offer.
        if !deferredStubTitles.isEmpty {
            do {
                let plausible = Self.namePlausibleTitles(deferredStubTitles, limit: candidateLimit)
                if let hit = try await firstPassingCandidate(namePlausible: plausible) {
                    return hit
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError { throw firstError }

        // Nothing suitable in either corpus. Not a failure: the caller draws
        // generated art, which is a first-class state, and stops retrying.
        return nil
    }

    /// Dedupe, apply the filename gate, and cap.
    ///
    /// The name gate runs BEFORE any metadata request. A flag, an emblem, a
    /// rasterised SVG or an administrative map is identifiable from its name
    /// alone, so there is no reason to ask how big it is — and the surviving count
    /// is what the stub threshold is measured on.
    static func namePlausibleTitles(_ fileTitles: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return fileTitles
            .filter { seen.insert(normalisedTitle($0)).inserted }
            .filter { passesNameGate($0) }
            .prefix(limit)
            .map { $0 }
    }

    /// Resolve the first name-plausible title that also passes the geometry gate.
    private func firstPassingCandidate(namePlausible: [String]) async throws -> TripCoverCandidate? {
        guard !namePlausible.isEmpty else { return nil }

        let described = try await imageInfo(fileTitles: namePlausible)

        // Preserve the order they were offered in: lead image (if any), then page
        // order. This is what makes the corpus choice matter.
        for title in namePlausible {
            guard let candidate = described[Self.normalisedTitle(title)] else { continue }
            if Self.passesGate(candidate) { return candidate }
        }
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
    ///
    /// ## The administrative-map class
    ///
    /// The second group below exists because a whole family of maps never contains
    /// the word "map". All of these are real filenames from live responses for the
    /// user's own destinations: `Italy_regions.png`,
    /// `Lisboa_freguesias_-_Wikivoyage_City_districts_divison.png`,
    /// `Japan_topo_en.jpg`, `Bali2022OSM.png`. Relying on the aspect floor to catch
    /// them is relying on luck — `Italy_regions.png` is only excluded because it
    /// happens to be portrait, and one landscape administrative map would win.
    ///
    /// `boundary` is in this group and earns its place on the strongest evidence
    /// here: `City_Boundary_1903_-_Old_Peak_Road.jpg` was the FIRST name-plausible
    /// candidate for "Hong Kong", one of the user's actual trips, at 4416x3312 —
    /// comfortably through every geometry check. It is a close-up of a boundary
    /// marker stone, and it was winning.
    ///
    /// Plurals are deliberate on `regions`, `districts`, `provinces` and
    /// `subdivisions`. The singular forms appear in ordinary place names
    /// (`Mapo_District_Seoul.jpg`, `Yunnan_Province_...`), so matching them would
    /// reject real photographs. This distinction is asserted by a test.
    ///
    /// `blank_map` from the brief is deliberately absent: the bounded `map` rule
    /// above already matches it, and a redundant alternative in a regex is a place
    /// for a future edit to disagree with itself.
    private static let rejectedNamePattern = [
        // Insignia and non-photographic artwork.
        "flag", "coat[_ ]?of[_ ]?arms", "seal", "logo", "emblem", "montage", "collage",
        // Maps, by name.
        "locator", "(?<![a-z])map(?![a-z])", "location", "marker", "orthographic",
        // Maps, by everything except the word "map".
        "regions", "districts", "freguesias", "provinces", "administrative",
        "political", "subdivisions", "topographic", "topo", "boundary",
        "(?<![a-z])osm(?![a-z])"
    ].joined(separator: "|")

    /// Extensions that cannot be shown in the band at all: vector artwork (which
    /// is what a flag, an emblem or a locator map usually is) and video.
    private static let rejectedExtensions: Set<String> = ["svg", "ogv", "webm", "gif"]

    /// Minimum long-edge resolution.
    ///
    /// Raised from 900 to 1400 on measurement. Three reasons, in order of weight:
    ///
    /// 1. **The band genuinely needs it.** 900 px was derived from an 868pt band at
    ///    1x, but the band renders at 2x or 3x: 398pt at 3x is 1194 px and an
    ///    868pt macOS pane at 2x is 1736 px. 900 px was always an upscale on every
    ///    real device. 1400 is a compromise rather than a fit — it covers the iOS
    ///    band natively and keeps enough candidate supply to matter.
    /// 2. **It fixes the ticket's headline example.** At 900, "Vietnam" resolved to
    ///    `Pho_quay.JPG`, a 1024x768 photograph of a food stall: real, but a weak
    ///    cover, and only just over the floor. At 1400 it resolves to
    ///    `Cua_Tung_Beach.jpg` at 2822x1829. "Bali" and "Lisbon" are unaffected.
    /// 3. **It reduces the chance of an inappropriate cover.** Article-order
    ///    selection over an encyclopedic corpus can surface war and disaster
    ///    imagery — Wikivoyage's "Japan" list carries `AtomicEffects-p42a.jpg`
    ///    ahead of the image that currently wins. It is excluded here only
    ///    incidentally, by being 640x514, and scanned historical photographs are
    ///    systematically low-resolution, so a higher floor screens more of them.
    ///    That is a real benefit and NOT a substitute for a content check: nothing
    ///    in this gate understands what an image depicts.
    ///
    /// This is a strengthening of the gate, not a weakening. The cost is more trips
    /// settling on `none`, which draws generated cover art — a first-class state.
    private static let minimumPixelWidth = 1400

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
    private func leadImageFileTitle(corpus: Corpus, page: String) async throws -> String? {
        guard let segment = Self.encodedPathSegment(page),
              let url = URL(string: "https://\(corpus.rawValue)/api/rest_v1/page/summary/\(segment)") else {
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
    ///
    /// A 404 is ordinary here, not an error: plenty of places have a Wikipedia
    /// article and no Wikivoyage one, and vice versa.
    private func mediaListFileTitles(corpus: Corpus, page: String) async throws -> [String] {
        guard let segment = Self.encodedPathSegment(page),
              let url = URL(string: "https://\(corpus.rawValue)/api/rest_v1/page/media-list/\(segment)") else {
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
                  let source = info.url,
                  let imageURL = Self.strippingTrackingParameters(source),
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

    // MARK: - URL hygiene

    /// Parse an image URL, dropping analytics query parameters.
    ///
    /// Wikivoyage's REST responses append
    /// `?utm_source=en.wikivoyage.org&utm_campaign=parser&utm_content=thumbnail`
    /// to the URLs they hand back. Those must not reach `coverImageSourceURL`,
    /// which is the PORTABLE IDENTITY of a cover: it is what the self-heal
    /// re-fetch reads on a device that has the row but not the file, and what any
    /// future dedup would key on. Two rows pointing at the same photograph with
    /// different `utm_content` values would read as two different covers.
    ///
    /// Applied even though the current code path reads titles rather than
    /// `srcset` URLs, because the field it protects is the one that travels
    /// between devices, and a defensive strip there costs nothing.
    static func strippingTrackingParameters(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return URL(string: raw) }
        if let items = components.queryItems {
            let kept = items.filter { !$0.name.lowercased().hasPrefix("utm_") }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.url ?? URL(string: raw)
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
        request.setValue(TripCoverUserAgent.value, forHTTPHeaderField: "User-Agent")
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

// MARK: - User-Agent

/// The `User-Agent` sent on every Wikimedia request, metadata and bytes alike.
///
/// Not cosmetic and not optional. Wikimedia's API etiquette asks for a
/// descriptive agent with a way to make contact, and it enforces that: a bare
/// default agent gets HTTP errors from the Commons API, which in this feature
/// would surface as a `failed` cover state and a silent retry loop rather than as
/// anything legible. One constant so the metadata calls and the byte download
/// cannot drift apart, which is exactly the kind of divergence that leaves one of
/// two paths mysteriously failing.
enum TripCoverUserAgent {
    static let value = "Dexter/1.0 (personal productivity app; https://github.com/akshaydotsharma/Dexter)"
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
        request.setValue(TripCoverUserAgent.value, forHTTPHeaderField: "User-Agent")
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
