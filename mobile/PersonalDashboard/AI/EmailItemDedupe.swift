import Foundation
import SwiftData

/// Item-level deduplication for the email-ingest path (#143).
///
/// Message-level idempotency (`LocalProcessedEmail` by Message-Id) does NOT
/// cover two real cases:
///   (a) Re-scan, which deliberately bypasses the message ledger, and
///   (b) the user forwarding the SAME booking as two different emails (two
///       Airbnb PDFs of one Florence reservation: same confirmation code,
///       same dates/title, different Message-Ids).
/// Both would otherwise add the same itinerary item twice. This helper makes
/// each proposed item dedup against what already exists on the SAME trip, so
/// either path yields exactly one row.
///
/// Scope: used ONLY by `EmailToItinerary`. Chat/capture adds never call this
/// and keep their current behaviour. The signature is also stored on the row
/// (`dedupeKey` / `sourceConfirmation`) so a later email can match it cheaply.
enum EmailItemDedupe {

    /// A proposed item parsed out of an `add_itinerary_item` tool input,
    /// reduced to the fields that define equivalence.
    struct Proposed {
        let kind: String          // ItineraryKind.rawValue, lowercased
        let dayDate: Date         // startOfDay
        let endDate: Date?        // startOfDay, stays only
        let title: String         // raw title (for storage)
        let confirmation: String  // extracted code, or "" if none
    }

    /// Compute the equivalence signature for a proposed item on a given trip.
    ///
    /// Strongest signal first: when a confirmation/reservation code is present,
    /// equivalence is (tripUUID + confirmationCode) — two different emails of
    /// the same reservation collide here regardless of how their titles/dates
    /// render. Otherwise fall back to (tripUUID + kind + dayDate + normalized
    /// title), plus the checkout date for stays so two different stays on the
    /// same check-in day stay distinct.
    static func signature(tripUUID: UUID, proposed: Proposed) -> String {
        let trip = tripUUID.uuidString.lowercased()
        let day = dayKey(proposed.dayDate)
        let title = normalizeTitle(proposed.title)
        let structural: String = {
            if proposed.kind == "stay", let end = proposed.endDate {
                return "stay:\(day)-\(dayKey(end)):\(title)"
            }
            return "\(proposed.kind):\(day):\(title)"
        }()
        if !proposed.confirmation.isEmpty {
            // Combine the code with the structural key so a single PNR covering
            // several distinct legs keeps them distinct, while a re-forward of
            // the SAME leg collides. (The structural key alone would already
            // collide on a re-forward; the code makes title/date rewordings
            // across two emails of the same item still match via `exists`'s
            // confirmation check below.)
            return "conf:\(trip):\(normalizeConfirmation(proposed.confirmation)):\(structural)"
        }
        return "k:\(trip):\(structural)"
    }

    /// True when an equivalent item already exists on the trip. Checks both the
    /// stored `dedupeKey` (fast path for items the email path created) AND a
    /// structural comparison against existing rows (covers items created before
    /// this field existed, and confirmation-vs-structural mismatches).
    @MainActor
    static func exists(signature: String, proposed: Proposed, tripUUID: UUID, context: ModelContext) -> Bool {
        // Fast path: a previously-ingested item carrying the same dedupeKey.
        let sig = signature
        let byKey = (try? context.fetchCount(
            FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.dedupeKey == sig }
            )
        )) ?? 0
        if byKey > 0 { return true }

        // Confirmation match against rows that stored a code (any title/date
        // rendering of the same reservation).
        if !proposed.confirmation.isEmpty {
            let conf = normalizeConfirmation(proposed.confirmation)
            let byConf = (try? context.fetchCount(
                FetchDescriptor<LocalItineraryItem>(
                    predicate: #Predicate { $0.tripUUID == tripUUID && $0.sourceConfirmation == conf }
                )
            )) ?? 0
            if byConf > 0 { return true }
        }

        // Structural fallback: compare against all items on the trip (covers
        // chat-created or pre-field rows that have no dedupeKey). Done in
        // memory because normalized-title equality isn't expressible in a
        // #Predicate.
        let fk = tripUUID
        let rows = (try? context.fetch(
            FetchDescriptor<LocalItineraryItem>(predicate: #Predicate { $0.tripUUID == fk })
        )) ?? []
        let targetKind = proposed.kind
        let targetDay = dayKey(proposed.dayDate)
        let targetTitle = normalizeTitle(proposed.title)
        let targetEnd = proposed.endDate.map(dayKey)
        for row in rows {
            guard row.kind.lowercased() == targetKind else { continue }
            guard dayKey(row.dayDate) == targetDay else { continue }
            guard normalizeTitle(row.title) == targetTitle else { continue }
            if targetKind == "stay" {
                let rowEnd = row.endDate.map(dayKey)
                guard rowEnd == targetEnd else { continue }
            }
            return true
        }
        return false
    }

    // MARK: - Normalisation

    static func normalizeTitle(_ title: String) -> String {
        let lowered = title.lowercased()
        let collapsed = lowered.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeConfirmation(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func dayKey(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Confirmation-code extraction

    /// Pull a booking/reservation/confirmation code out of free text. Looks for
    /// an explicit "confirmation code"/"booking reference"/"PNR"/"reservation"
    /// label followed by an alphanumeric token, then falls back to a standalone
    /// 6–12 char uppercase-alphanumeric token (airline PNRs, Airbnb codes).
    /// Returns "" when nothing convincing is found.
    static func extractConfirmation(from text: String) -> String {
        // Most-specific labels first. A generic "reservation"/"reference" label
        // can appear far from the actual code (e.g. "Reservation details ...
        // coming4 guests"), so prefer the strong labels and, within each label,
        // take the BEST nearby token, not just the first.
        let labels = [
            "confirmation code", "confirmation number", "confirmation",
            "booking reference", "booking ref", "booking code", "booking id",
            "reservation code", "reservation number",
            "record locator", "reference number",
            "pnr", "booking", "reservation", "reference",
        ]
        let lower = text.lowercased()
        for label in labels {
            guard let r = lower.range(of: label) else { continue }
            // Look only at a short window after the label so a distant word
            // doesn't get picked. Codes sit right next to their label.
            let tail = text[r.upperBound...]
            let window = String(tail.prefix(60))
            if let token = bestCodeToken(in: window) {
                return token
            }
        }
        // Label-free fallback: scan the whole text for a strong code token.
        if let token = bestCodeToken(in: text, strongOnly: true) {
            return token
        }
        return ""
    }

    /// Pick the most code-like token in `text`. A "strong" code is ≥8 chars OR
    /// has ≥2 digits — this rejects word+digit artifacts like "coming4" while
    /// accepting real PNRs and Airbnb codes (HM84R8EPNF, ABC123).
    ///
    /// PDF text normalisation can glue a code to the next word ("HM84R8EPNF" +
    /// "Cancellation" -> "HM84R8EPNFCancellation"), so we first try a regex
    /// that captures an UPPERCASE-alphanumeric run of 6–12 chars (with ≥1
    /// digit) even when it's the prefix of a longer mixed-case run — codes are
    /// upper-case, the glued word that follows starts with one capital then
    /// lowercase, so the uppercase run ends cleanly at the code boundary.
    /// Falls back to whitespace/punctuation token splitting.
    private static func bestCodeToken(in text: String, strongOnly: Bool = false) -> String? {
        // 1) Uppercase-run regex: capture a 6–13 run of [A-Z0-9] that starts at
        //    a non-alphanumeric boundary. When the run is immediately followed
        //    by a lowercase letter, the trailing uppercase char is the start of
        //    a glued next word (PDF normalisation removed the space, e.g.
        //    "HM84R8EPNFCancellation"), so drop it. This recovers the code even
        //    when it's fused to the following word.
        let pattern = "(?<![A-Za-z0-9])[A-Z0-9]{6,13}"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var token = ns.substring(with: m.range)
                let after = m.range.location + m.range.length
                if after < ns.length {
                    let nextChar = ns.substring(with: NSRange(location: after, length: 1))
                    if nextChar.rangeOfCharacter(from: .lowercaseLetters) != nil {
                        token = String(token.dropLast())
                    }
                }
                guard token.count >= 6, token.count <= 12 else { continue }
                let digits = token.filter { $0.isNumber }.count
                guard digits >= 1, digits < token.count else { continue }
                let isStrong = token.count >= 8 || digits >= 2
                if isStrong { return token }
            }
        }
        // 2) Token-split fallback (handles lowercase/mixed codes).
        let tokens = text.split { !($0.isLetter || $0.isNumber) }
        var weak: String?
        for raw in tokens.prefix(40) {
            let t = String(raw)
            guard t.count >= 6, t.count <= 14 else { continue }
            let upper = t.uppercased()
            guard upper.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
            let digits = upper.filter { $0.isNumber }.count
            guard digits >= 1, digits < upper.count else { continue }
            let isStrong = upper.count >= 8 || digits >= 2
            if isStrong { return upper }
            if !strongOnly, weak == nil { weak = upper }
        }
        return strongOnly ? nil : weak
    }
}
