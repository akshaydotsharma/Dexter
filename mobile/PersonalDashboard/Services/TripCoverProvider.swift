import Foundation

/// Generates the destination illustration for a trip tile (#428).
///
/// One method, so swapping image models later is a one-file change rather than a
/// redesign. `OpenAITripCoverArtProvider` is the only implementation today.
///
/// The contract: return the raw image bytes, or throw. There is no "nothing
/// suitable found" case any more — that was a property of *searching* a corpus,
/// and this makes the image to spec instead. Whether a trip name is a place at all
/// is decided before we get here, by `TripCoverPlaceness`.
protocol TripCoverArtProvider: Sendable {
    func illustration(forDestination destination: String) async throws -> Data
}

enum TripCoverArtProviderError: LocalizedError {
    case notConfigured
    case badRequest
    case transport(Error)
    case badStatus(Int, String?)
    case undecodable(Error)
    case emptyResponse
    /// The account will refuse every request until a human changes something: the
    /// spend cap is reached, or the key is revoked. NOT transient, and retrying it on
    /// every launch is how a hard limit gets hammered instead of respected.
    case permanentlyRefused(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No OpenAI API key is configured, so cover art can't be generated."
        case .badRequest:
            return "Couldn't build the cover art request."
        case .transport(let e):
            return e.localizedDescription
        case .badStatus(let code, let detail):
            return "Cover art generation failed with status \(code)." + (detail.map { " \($0)" } ?? "")
        case .undecodable(let e):
            return "Couldn't read the cover art response: \(e.localizedDescription)"
        case .emptyResponse:
            return "Cover art generation returned no image."
        case .permanentlyRefused(let detail):
            return "Cover art generation is blocked: \(detail)"
        }
    }
}

// MARK: - The pinned prompt

/// The one prompt that governs every destination (#428).
///
/// Pinned deliberately. The reason this feature moved off fetched photography is
/// that a per-destination *choice* — which of 74 candidate images wins — turned out
/// to be unrankable: two real destinations came out badly for reasons no filename or
/// geometry rule could separate from a good result. One fixed prompt with the
/// destination substituted in means every city arrives as the same visual system:
/// same palette, same weight, same composition. Photography could never do that,
/// and a photograph cannot respond to light or dark mode either.
enum TripCoverPrompt {

    /// Bumping this invalidates every cached illustration.
    ///
    /// Stored per trip on `LocalTrip.coverArtPromptVersion`, which exists purely so
    /// a prompt change is a deliberate, complete re-generation rather than leaving a
    /// device with a visibly mixed set — half old art, half new, and no way to tell
    /// which is which by looking.
    static let version = "1"

    /// Image model and size, both fixed. `1536x1024` gives a 1536-wide source, and
    /// the crop targets a quarter of that width as the band height (384 px at 4:1).
    static let model = "gpt-image-1-mini"
    static let size = "1536x1024"

    /// Deliberately emphatic about the bottom quarter and about nothing touching the
    /// top edge. The model still does not reliably obey it, which is exactly why
    /// `TripCoverCrop` exists and is not optional.
    static func text(for destination: String) -> String {
        """
        Flat vector editorial illustration of \(destination): a WIDE SHALLOW SKYLINE STRIP of its
        recognisable landmarks, all standing on a single common groundline along the bottom. The
        entire skyline including every spire and tower must occupy ONLY THE BOTTOM QUARTER of the
        image height, leaving the upper three quarters as completely empty warm off-white sky. Wide
        and shallow, like a distant city seen across water. Nothing may touch or approach the top
        edge. Simple geometric flat shapes, no gradients, no outlines. Strictly limited palette of
        warm muted earth tones: soft terracotta, sand, warm taupe, muted sage, deep warm charcoal,
        on warm off-white. Absolutely no text, no lettering, no numbers, no people, no logos.
        Understated, restrained, print-inspired. Minimal.
        """
    }
}

// MARK: - Destination identity

/// Turns a trip name into the identity its cover art is cached under (#428).
///
/// Art is content-addressed on (normalised destination, prompt version) rather than on
/// the trip's UUID. Two trips to Hong Kong used to generate twice and bill twice, and
/// deleting a trip destroyed art that recreating it paid for again. Keyed this way, a
/// second trip to a place already on disk resolves with no API call at all, and
/// delete-then-recreate reuses what is already there.
///
/// ONE normaliser, used for both the cache key and the prompt substitution. Two
/// normalisers that disagree would mean art filed under a key the prompt never described.
enum TripCoverDestination {

    /// The canonical spelling of a destination: years and possessives removed, whitespace
    /// collapsed, trimmed. Casing is PRESERVED, because this string also goes into the
    /// prompt and "hong kong" is a worse prompt than "Hong Kong".
    ///
    /// Years come off for the same reason they did when covers were searched rather than
    /// generated: "Japan 2026" is how a trip is labelled, not what the place is called, and
    /// the illustration of Japan is the same either way. That is also what lets two trips a
    /// year apart share one image.
    static func canonical(_ name: String) -> String {
        var s = name
        s = s.replacingOccurrences(of: "’s", with: "")
        s = s.replacingOccurrences(of: "'s", with: "")
        // Four-digit years, 1900–2099. Scoped rather than "any four digits" so a place
        // whose name contains a number is not mangled.
        if let regex = try? NSRegularExpression(pattern: "\\b(19|20)\\d{2}\\b") {
            s = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: ""
            )
        }
        return s.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The identity two destinations must share to share art. Case-insensitive, so
    /// "Hong Kong", "hong kong" and "Hong Kong 2026" are one place.
    static func identity(_ name: String) -> String {
        canonical(name).lowercased()
    }

    /// Deterministic relative path for a destination's art under the current prompt.
    ///
    /// The prompt version is IN the key, so bumping it changes every path: new art is
    /// written alongside the old rather than over it, and the old files become orphans the
    /// reaper collects. That is what makes a prompt change a clean sweep instead of a
    /// device showing a mix of both.
    ///
    /// Hashed rather than using the name directly: a destination can contain slashes,
    /// emoji, or 64 characters of anything, and none of that belongs in a filename.
    /// `SyncHash.hex` is reused rather than reinvented.
    static func relativePath(for name: String, promptVersion: String = TripCoverPrompt.version) -> String? {
        let key = identity(name)
        guard !key.isEmpty else { return nil }
        let digest = SyncHash.hex(Data("\(key)|v\(promptVersion)".utf8))
        return "trip-covers/\(digest.prefix(32)).jpg"
    }
}

// MARK: - Place-ness

/// Whether a trip name names somewhere that can be illustrated (#428).
///
/// Fetched photography got this for free: a corpus lookup for "Work offsite" simply
/// 404'd, and that 404 was what made `coverImageState`'s `none` case meaningful. An
/// image model has no such honesty — it will cheerfully render a skyline for any
/// string — so the check has to be local now, or a trip called "Work offsite" ends
/// up carrying a confidently generated illustration of nowhere.
///
/// Deliberately conservative, and deliberately built from vocabulary ALREADY in this
/// feature: every word below is a keyword from `TripCoverArt.glyph(for:)`'s
/// non-place categories (its briefcase and gift rules). No new vocabulary is
/// invented here, so there is one place to look when the judgement is wrong.
///
/// The asymmetry is intentional. A false "not a place" costs a generated glyph tile,
/// which is a first-class state that looks deliberate. A false "is a place" costs one
/// wasted generation and some odd art. Neither is data loss, and this leans toward
/// the cheaper failure.
///
/// Note what this does NOT need to do any more: generation has no page title to
/// match, so "Bali beach break" is a perfectly good prompt even though it was never
/// a Wikipedia article. Free-text trip names got better with this pivot, not worse.
enum TripCoverPlaceness {

    /// Words that mean the trip is named for an OCCASION rather than a destination.
    private static let nonPlaceKeywords = [
        "offsite", "conference", "wedding", "birthday"
    ]

    /// `work` is bounded on letters so it cannot fire inside a place name, and is
    /// kept separate from the list above because it is the one word here common
    /// enough to need that care.
    private static let boundedNonPlacePattern = "(?<![a-z])work(?![a-z])"

    static func isLikelyPlace(_ tripName: String) -> Bool {
        let trimmed = tripName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        if nonPlaceKeywords.contains(where: { lowered.contains($0) }) { return false }
        if lowered.range(of: boundedNonPlacePattern, options: .regularExpression) != nil {
            return false
        }
        return true
    }
}

// MARK: - OpenAI

/// Generates the illustration through the OpenAI images API.
///
/// Reuses `AppConfig.openAIAPIKey`, which already resolves env var then Info.plist
/// and is already baked into the IPA for voice transcription. No new credential and
/// no new build-time plumbing.
struct OpenAITripCoverArtProvider: TripCoverArtProvider {

    /// Generation takes tens of seconds, so the 10 s ceiling the fetch path used
    /// would have timed out every call. This is the one place in this feature where
    /// `FXService`'s call shape deliberately does NOT transfer.
    private let timeout: TimeInterval = 180

    func illustration(forDestination destination: String) async throws -> Data {
        guard let key = AppConfig.openAIAPIKey else {
            throw TripCoverArtProviderError.notConfigured
        }
        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else {
            throw TripCoverArtProviderError.badRequest
        }

        let body: [String: Any] = [
            "model": TripCoverPrompt.model,
            // The CANONICAL name, so the art matches the identity it is cached under.
            // Passing the raw name would file "Japan 2026" under Japan's key while having
            // asked the model for "Japan 2026".
            "prompt": TripCoverPrompt.text(for: TripCoverDestination.canonical(destination)),
            "size": TripCoverPrompt.size,
            "n": 1
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw TripCoverArtProviderError.badRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TripCoverArtProviderError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TripCoverArtProviderError.badStatus(-1, nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            // The API's own message is far more useful than the status alone — quota,
            // content policy and a bad model name all arrive as 4xx — and this is the
            // string that lands in the log when a cover stays `failed`.
            let detail = Self.errorMessage(from: data)
            if Self.isPermanentRefusal(status: http.statusCode, detail: detail) {
                throw TripCoverArtProviderError.permanentlyRefused(detail ?? "status \(http.statusCode)")
            }
            throw TripCoverArtProviderError.badStatus(http.statusCode, detail)
        }

        let decoded: ImageResponse
        do {
            decoded = try JSONDecoder().decode(ImageResponse.self, from: data)
        } catch {
            throw TripCoverArtProviderError.undecodable(error)
        }
        guard let first = decoded.data?.first else {
            throw TripCoverArtProviderError.emptyResponse
        }
        // `gpt-image-1*` returns base64 rather than a URL. The `url` branch is
        // defensive: three lines that cover a model or account answering the older way.
        if let b64 = first.b64JSON, let bytes = Data(base64Encoded: b64) {
            return bytes
        }
        if let urlString = first.url, let remote = URL(string: urlString) {
            return try await download(remote)
        }
        throw TripCoverArtProviderError.emptyResponse
    }

    /// A refusal no amount of waiting fixes.
    ///
    /// `billing_hard_limit_reached` arrives as a 400, which is otherwise indistinguishable
    /// from a malformed request, so it was being recorded as transient and retried on every
    /// launch — three generations a launch aimed at a wall that had already said no. 401 and
    /// 403 are the same shape of problem: a revoked or wrong key will not start working.
    ///
    /// 429 is deliberately NOT here. Rate limiting IS transient and should retry.
    static func isPermanentRefusal(status: Int, detail: String?) -> Bool {
        if status == 401 || status == 403 { return true }
        guard status == 400, let detail = detail?.lowercased() else { return false }
        return detail.contains("billing_hard_limit_reached")
            || detail.contains("billing hard limit")
            || detail.contains("exceeded your current quota")
            || detail.contains("insufficient_quota")
    }

    static func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw TripCoverArtProviderError.badStatus(
                    (response as? HTTPURLResponse)?.statusCode ?? -1, nil
                )
            }
            return data
        } catch let known as TripCoverArtProviderError {
            throw known
        } catch {
            throw TripCoverArtProviderError.transport(error)
        }
    }

    private struct ImageResponse: Decodable {
        struct Item: Decodable {
            let b64JSON: String?
            let url: String?

            enum CodingKeys: String, CodingKey {
                case b64JSON = "b64_json"
                case url
            }
        }
        let data: [Item]?
    }
}
