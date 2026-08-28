import Foundation

/// Which of a ticket's facts belong on its face, and which belong on its back
/// (#481).
///
/// A card used to print every fact the extractor read, in one list, on the face.
/// That fails in two directions at once. The face buries the barcode under the
/// issuer's bookkeeping — the Monza F1 pass carries nine internal codes
/// ("Progr.sessivo", "Cod.Rich.Em.Sigillo", "S.F") that nobody has ever read —
/// and because the list is as long as the document is chatty, no two cards are
/// the same height.
///
/// A pass solves this by having two sides. The face is a FIXED set of slots: one
/// full-width secondary line and a row of up to three auxiliary fields. Anything
/// that does not fit a slot goes on the back, which is a plain label / value
/// table you reach by turning the card over.
///
/// This type is that split, computed once from a `TicketCardData` and handed to
/// both sides, so the face and the back can never disagree about which fields
/// each of them owns.
///
/// It deliberately does NOT trust `PassField.placement`. The placement is a guess
/// made by a model that read the document once, and it guessed `auxiliary` for
/// all nine of the Monza codes. Every generic field therefore goes to the back:
/// the face carries only the typed slots this app understands, which is what
/// makes its height fixed.
struct TicketCardFields {

    /// One label / value pair, as it will be drawn.
    struct Row: Identifiable, Hashable {
        var label: String
        var value: String
        /// Set when the value is an openable link, so the row becomes a tap
        /// target showing its host instead of 180 characters of query string.
        var url: URL?
        /// A slot the document keeps but has not filled in. Only a boarding pass
        /// has these: an unassigned gate is a fact about the flight, not an
        /// absent field, so the slot stays and prints an em dash in muted ink.
        var isUnknown: Bool = false

        var id: String { "\(label)\u{1F}\(value)" }
    }

    /// The face's full-width line: the one fact that names the thing. Venue for
    /// an event, the operating flight for a boarding pass, the confirmation code
    /// for a stay. `nil` when the document carried none, and the slot then
    /// collapses rather than printing an empty row.
    let secondary: Row?

    /// The face's side-by-side row, at most three wide. Seat-level detail for an
    /// event, the gate-side facts for a boarding pass, the two times for a stay.
    let auxiliary: [Row]

    /// The back, in reading order: where you are going first, then whatever the
    /// document printed, then the typed facts the face had no slot for.
    let back: [Row]

    /// At most this many fields sit side by side on the face. Three is what fits
    /// legibly at card width; a fourth column turns "26b - Tribuna Laterale
    /// Destra" into three characters and an ellipsis.
    static let auxiliaryLimit = 3

    // MARK: - Build

    init(card: TicketCardData) {
        let meta = card.meta
        var back: [Row] = []

        // MARK: Face

        switch card.layout {
        case .event:
            secondary = Self.row("Venue", card.venue)
            auxiliary = Self.rows([
                ("Section", meta?.section),
                ("Row", meta?.row),
                ("Seat", card.seat),
                // Most events outside a stadium have no seating at all, and a
                // pass fills that row with the holder's name instead. It is last
                // so it only claims a column the seat facts left empty.
                ("Guest", meta?.guestName)
            ])

        case .boardingPass:
            secondary = Self.row("Flight", Self.operatorLabel(meta))
            // Kept whether or not they are filled. On a pass a blank gate reads
            // as "not assigned yet", which is worth a slot; dropping the row
            // would say the flight has no gate at all.
            auxiliary = Self.dashedRows([
                ("Seat", card.seat),
                ("Gate", TicketField.code(card.gate)),
                ("Terminal", TicketField.code(meta?.terminal))
            ])

        case .stay:
            secondary = Self.row("Confirmation", card.sourceConfirmation)
            auxiliary = Self.rows([
                ("Check-in", Self.time(card.startTime)),
                ("Check-out", Self.time(card.endTime))
            ])
        }

        // MARK: Back

        // WHICH ticket this is, before WHERE it is (#487). Two cards can carry the
        // same title, date, venue and booking reference and differ only by seat —
        // the two Monza cards do — and until this, turning either one over left you
        // holding a card that would not say which one it was.
        //
        // Deliberately a repeat of what the face shows. The `onFace` rule below is
        // right for a detail and wrong for an identifier: the back is a different
        // side of the card, not a continuation of the front, and it has to stand on
        // its own. Apple Wallet's backs carry the serial number for the same reason.
        if let reference = Self.row(Self.referenceLabel(card.layout), card.sourceConfirmation) {
            back.append(reference)
        }
        if let seat = Self.row("Seat", card.seat) {
            back.append(seat)
        }

        // Where you are going, first: it is the reason you turn a pass over on
        // the day, and Apple Wallet puts it at the top of every back it issues.
        // Suppressed when the address is just the venue again under a second
        // label, which reads as a rendering fault rather than as detail.
        //
        // Unless the stub is already carrying it: a stay with nothing to scan
        // tears off its address and a map link instead of a barcode, and printing
        // the same two lines again on the back reads as a rendering fault.
        let address = card.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationIsOnTheStub = card.layout == .stay && !card.hasTicket
            && (!address.isEmpty || card.mapsURL != nil)
        if !locationIsOnTheStub {
            if !address.isEmpty, address.caseInsensitiveCompare(card.venue.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
                back.append(Row(label: "Address", value: address))
            }
            if let maps = card.mapsURL {
                back.append(Row(label: "Directions", value: maps.absoluteString, url: maps))
            }
        }

        // Everything the document printed, under its own labels, in its own
        // order. Placement is ignored on purpose: see the type's note.
        for field in meta?.fields ?? [] where field.isRenderable {
            back.append(Row(label: field.label, value: field.value, url: field.url))
        }

        // The typed facts the face has no slot for. Appended after the issuer's
        // own fields so the back reads as "the document, then what we know about
        // it" rather than interleaving the two.
        // `eventType` deliberately absent (#486). It renders as "TYPE / Formula 1
        // race" under a title reading "Formula 1 Gran Premio d'Italia 2026", which
        // is the title again in fewer words. It is a classification this app sorts
        // and colours cards by, not a fact the holder reads off the back.
        var typed: [(String, String?)] = []
        switch card.layout {
        // The confirmation is not repeated here for either of these: the stub
        // already prints it under the code, as "PNR" or "REF", which is where you
        // look for it. A stay has it on the face instead and is caught by the
        // `onFace` check below.
        case .event:
            typed.append(("Gate", TicketField.code(card.gate)))
        case .boardingPass:
            typed.append(contentsOf: [
                ("Cabin", meta?.cabin),
                ("Passenger", meta?.passengerName),
                ("Boarding", meta?.boardingTime)
            ])
        case .stay:
            typed.append(("Venue", card.venue))
        }
        // A field already on the face is not repeated on the back. The identity rows
        // above are appended before this runs and are not filtered by it — they are
        // repeats on purpose.
        let onFace = Set(([secondary].compactMap { $0 } + auxiliary).map { $0.label.lowercased() })
        for (label, value) in typed {
            guard !onFace.contains(label.lowercased()) else { continue }
            guard let row = Self.row(label, value) else { continue }
            back.append(row)
        }

        // The event's own page. Last, because it is a link out rather than a fact
        // about the ticket.
        if let url = Self.eventPageURL(meta) {
            back.append(Row(label: "Event page", value: url.absoluteString, url: url))
        }

        // A label the issuer also printed generically would otherwise appear
        // twice under two spellings of the same word. First occurrence wins, which
        // is what keeps the identity rows at the top: a later "Reference" from the
        // typed list or the issuer's own fields collapses into them rather than
        // pushing them down.
        var seen = Set<String>()
        self.back = back.filter { seen.insert($0.label.lowercased()).inserted }
    }

    /// Whether there is anything to turn the card over FOR. A hand-typed card
    /// with a title and a date has an empty back, and it should have no info
    /// control rather than a control that reveals nothing.
    var hasBack: Bool { !back.isEmpty }

    // MARK: - Helpers

    /// The stored event page, coercing a bare host to https so a hand-typed
    /// value still opens.
    static func eventPageURL(_ meta: TicketMeta?) -> URL? {
        guard let raw = meta?.eventURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: "https://\(raw)")
    }

    /// What a booking reference is called, per layout, matching what the same
    /// number is called elsewhere on the card: the stub prints PNR on a boarding
    /// pass, and a stay's face already says Confirmation.
    private static func referenceLabel(_ layout: TicketCardLayout) -> String {
        switch layout {
        case .boardingPass: return "PNR"
        case .stay:         return "Confirmation"
        case .event:        return "Reference"
        }
    }

    private static func operatorLabel(_ meta: TicketMeta?) -> String? {
        let parts = [meta?.airline, meta?.flightNumber]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The UTC wall-clock formatter every ticket time goes through, so a printed
    /// time cannot drift with the device's timezone.
    private static func time(_ date: Date?) -> String? {
        guard let date else { return nil }
        return TimelineEntry.itineraryTimeFormatter.string(from: date)
    }

    private static func row(_ label: String, _ value: String?) -> Row? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return Row(label: label, value: trimmed)
    }

    /// The first `auxiliaryLimit` slots that carry a real value. Slots are listed
    /// in priority order by the caller, so a sparse ticket promotes what it has
    /// rather than showing empty columns.
    private static func rows(_ slots: [(String, String?)]) -> [Row] {
        slots.compactMap { row($0.0, $0.1) }.prefix(auxiliaryLimit).map { $0 }
    }

    /// Every slot, filled or not. An empty one renders an em dash rather than
    /// collapsing, so the row keeps its columns.
    private static func dashedRows(_ slots: [(String, String?)]) -> [Row] {
        slots.prefix(auxiliaryLimit).map { label, value in
            row(label, value) ?? Row(label: label, value: TicketField.unknownDash, isUnknown: true)
        }
    }
}
