import Foundation

/// Parsed facts from an IATA BCBP (Bar Coded Boarding Pass, IATA Resolution
/// 792) payload — the "M1..." string encoded in a boarding pass's PDF417 /
/// Aztec / QR code. Every field is optional: a malformed or truncated payload
/// yields whatever prefix parsed cleanly, never a crash.
struct BCBPTicket: Equatable {
    var passengerName: String?      // "SMITH/JOHN" reflowed to "John Smith"
    var pnr: String?                // Booking / record locator
    var originCode: String?         // 3-letter IATA airport code
    var destinationCode: String?
    var carrier: String?            // Operating carrier designator, e.g. "SQ"
    var flightNumber: String?       // Numeric, leading zeros stripped
    var julianDate: Int?            // Day-of-year (1…366); no year in BCBP
    var seat: String?               // e.g. "12A"
    var cabin: String?              // Compartment code letter, e.g. "Y"

    /// A combined "SQ 322" style label when we have both carrier + number.
    var flightLabel: String? {
        guard let carrier, let flightNumber else { return flightNumber }
        return "\(carrier)\(flightNumber)"
    }
}

/// Deterministic IATA BCBP parser. The BCBP mandatory section is fixed-width;
/// we walk it with bounds-checked slices so a short or corrupt payload returns
/// `nil` (or a partial ticket) rather than trapping. Only the fields the ticket
/// card needs are extracted — we do NOT attempt the full conditional/security
/// sections.
///
/// Mandatory layout (single leg), offsets from the start of the string:
/// ```
///  0        Format code           "M"
///  1        Number of legs        digit
///  2..21    Passenger name        20 chars  ("SURNAME/GIVEN")
/// 22        E-ticket indicator    "E"
/// 23..29    Operating carrier PNR 7 chars
/// 30..32    From (origin)         3 chars
/// 33..35    To (destination)      3 chars
/// 36..38    Operating carrier     3 chars
/// 39..43    Flight number         5 chars
/// 44..46    Julian date of flight 3 chars
/// 47        Compartment (cabin)   1 char
/// 48..51    Seat number           4 chars
/// ```
enum BCBPParser {

    /// Cheap prefix test: BCBP payloads start with "M" followed by a leg-count
    /// digit (almost always "M1"). Lets callers skip a full parse for obviously
    /// non-boarding-pass payloads (QR URLs, event tickets).
    static func looksLikeBCBP(_ payload: String) -> Bool {
        let s = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 23, s.hasPrefix("M") else { return false }
        let second = s[s.index(s.startIndex, offsetBy: 1)]
        return second.isNumber
    }

    /// Parse a BCBP payload into a `BCBPTicket`, or `nil` if it isn't a BCBP
    /// string at all. A recognisable-but-truncated payload returns a ticket
    /// with only the fields that fit.
    static func parse(_ payload: String) -> BCBPTicket? {
        guard looksLikeBCBP(payload) else { return nil }
        // Work on the raw scalar array so fixed-width offsets are exact and
        // never trip on multi-byte characters.
        let chars = Array(payload)
        func slice(_ start: Int, _ length: Int) -> String? {
            guard start >= 0, length > 0, start + length <= chars.count else { return nil }
            return String(chars[start..<(start + length)])
        }
        func trimmed(_ start: Int, _ length: Int) -> String? {
            guard let raw = slice(start, length) else { return nil }
            let t = raw.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }

        var ticket = BCBPTicket()

        ticket.passengerName = trimmed(2, 20).map(Self.reflowName)
        ticket.pnr = trimmed(23, 7)
        ticket.originCode = validAirport(trimmed(30, 3))
        ticket.destinationCode = validAirport(trimmed(33, 3))
        ticket.carrier = trimmed(36, 3)
        ticket.flightNumber = trimmed(39, 5).map(Self.stripLeadingZeros)
        if let julian = trimmed(44, 3), let value = Int(julian), (1...366).contains(value) {
            ticket.julianDate = value
        }
        ticket.cabin = trimmed(47, 1)
        ticket.seat = trimmed(48, 4).map(Self.normaliseSeat)

        // Reject a "ticket" that yielded nothing meaningful — the payload
        // passed the prefix test but wasn't real BCBP.
        if ticket == BCBPTicket() { return nil }
        return ticket
    }

    // MARK: - Field normalisation

    /// "SMITH/JOHN MR" → "John Smith". Splits on the BCBP "SURNAME/GIVEN"
    /// separator, drops trailing honorifics, and title-cases. Falls back to the
    /// raw string when it doesn't fit the expected shape.
    static func reflowName(_ raw: String) -> String {
        let parts = raw.split(separator: "/", maxSplits: 1).map { String($0) }
        guard parts.count == 2 else { return titleCased(raw) }
        let surname = titleCased(parts[0])
        // Given field may carry a trailing title token ("JOHN MR"); keep only
        // the first token as the given name for a clean display.
        let given = titleCased(parts[1].split(separator: " ").first.map(String.init) ?? parts[1])
        let full = "\(given) \(surname)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? titleCased(raw) : full
    }

    private static func titleCased(_ s: String) -> String {
        s.lowercased()
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// "0322" → "322". Keeps a bare "0" as "0" rather than empty.
    static func stripLeadingZeros(_ s: String) -> String {
        let trimmed = String(s.drop(while: { $0 == "0" }))
        return trimmed.isEmpty ? s : trimmed
    }

    /// "012A" → "12A" (strip leading zeros on the numeric part, keep the row
    /// letter). Leaves non-standard shapes untouched.
    static func normaliseSeat(_ s: String) -> String {
        let digits = s.prefix(while: { $0.isNumber })
        let rest = s.drop(while: { $0.isNumber })
        guard !digits.isEmpty else { return s }
        let num = Int(digits).map(String.init) ?? String(digits)
        return num + rest
    }

    /// A 3-letter uppercase alpha code is a plausible IATA airport code. Filters
    /// out padding artefacts so we don't render a nonsense "  X" as an airport.
    private static func validAirport(_ s: String?) -> String? {
        guard let s, s.count == 3, s.allSatisfy({ $0.isLetter }) else { return nil }
        return s.uppercased()
    }
}
