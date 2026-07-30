import Foundation

/// Reads a `.pkpass` file and turns it into a ticket, with no model call (#420).
///
/// ## Why this exists
///
/// The extraction pipeline reads a PICTURE of a ticket, because that is usually all
/// there is: a screenshot, a PDF, a photo of a printed stub. It does a good job and
/// it is also guessing — it can only see what the image shows, so the full street
/// address, the admission type and the holder's email, all of which live on the BACK
/// of an Apple Wallet pass, are simply not in the frame. That is why the Wallet card
/// for an event ended up thinner than the pass it came from.
///
/// A `.pkpass` is not a picture. It is a ZIP containing `pass.json`, and that file
/// states every field on the pass — front and back, with the issuer's own labels, in
/// the issuer's own order — plus the barcode payload, the relevant date and the
/// venue's coordinates. Read it and there is nothing left to infer: no model call, no
/// year to work out, no Vision decode, no fields lost because the back of the pass
/// was not photographed.
///
/// It also generalises, which is the point. Luma, Eventbrite, cinemas, airlines and
/// stadiums all issue `.pkpass` files against the same spec, so this path improves
/// every future pass rather than this one event. Anything that is not a pass keeps
/// going through the model exactly as before.
///
/// ## What it does not do
///
/// No signature verification. A pass carries a `signature` and a `manifest.json`
/// hashing its contents, and checking them would prove the issuer really issued it.
/// That matters to a gate scanner deciding whether to admit someone; it does not
/// matter to a personal archive whose only claim is "this is the file you gave me".
/// Verifying it needs Apple's WWDR certificate chain and CMS validation for no
/// benefit here, so the file is read as data, never trusted as an assertion.
struct WalletPassImport {

    /// Parse `data` as a `.pkpass`. `nil` when it is not one — which is the signal
    /// the caller uses to fall back to the image pipeline, so it must stay cheap and
    /// must never throw.
    ///
    /// Being a ZIP is not enough: a `.zip` of holiday photos would pass that test.
    /// The archive must actually contain a decodable `pass.json`.
    static func read(data: Data) -> WalletPassImport? {
        guard let archive = ZipArchiveReader(data: data),
              let json = archive.entry(named: "pass.json"),
              let pass = try? JSONDecoder().decode(PassJSON.self, from: json),
              pass.style != nil else {
            return nil
        }
        return WalletPassImport(pass: pass)
    }

    let pass: PassJSON

    // MARK: - Product

    /// The pass as the ingest pipeline's own extraction result, so the rest of the
    /// path (title suggestion, task-context fallbacks, DTO assembly, the editor)
    /// is shared verbatim with the model route rather than duplicated.
    ///
    /// - Parameter now: reference point for nothing at all here — a pass always
    ///   carries a full date — but taken so the caller can construct a read
    ///   deterministically in tests.
    func extracted(now: Date = Date()) -> ExtractedTaskTicket {
        var consumed = ConsumedValues()

        let title = firstValue(in: [.primary], consuming: &consumed) ?? trimmed(pass.description)
        if let title { consumed.insert(title) }

        // The event's day comes from `relevantDate` — the pass's own statement of when
        // it matters — read in the DEVICE timezone, which is how Wallet itself shows
        // it and therefore what the person has already seen on their phone.
        let day = Self.iso8601(pass.relevantDate) ?? Self.iso8601(pass.expirationDate)
        let dayText = day.map { Self.localDayText($0) }

        let time = printedTime(consuming: &consumed)
        let venue = locationValue(short: true, consuming: &consumed)
        let address = locationValue(short: false, consuming: &consumed)

        let guest = labelledValue(matching: Self.guestLabels, consuming: &consumed)
        let seat = labelledValue(matching: Self.seatLabels, consuming: &consumed)
        let row = labelledValue(matching: Self.rowLabels, consuming: &consumed)
        let section = labelledValue(matching: Self.sectionLabels, consuming: &consumed)
        let gate = labelledValue(matching: Self.gateLabels, consuming: &consumed)
        let reference = labelledValue(matching: Self.referenceLabels, consuming: &consumed)
        let eventURL = urlValue(matching: Self.eventPageLabels, excluding: Self.mapHosts, consuming: &consumed)
        let directions = urlValue(matching: Self.directionsLabels, requiring: Self.mapHosts, consuming: &consumed)

        // Every field the typed slots above did not take, in the issuer's order and
        // keeping its placement, so the card can render it without knowing what it is.
        let extras = remainingFields(consumed: consumed)

        return ExtractedTaskTicket(
            eventTitle: title,
            eventDate: dayText,
            startTimeText: time,
            venue: venue,
            seat: seat,
            gate: gate,
            reference: reference,
            eventType: eventType,
            section: section,
            row: row,
            printedWeekday: nil,
            eventURL: eventURL,
            guestName: guest,
            // A pass states its date in full, always. Nothing to infer, so the
            // year-correction backstop must leave it alone.
            yearWasPrinted: day != nil,
            // A signed pass with a scannable code is the definition of a document you
            // present at a door. Left unjudged for the styles that are not: a store
            // card or a coupon may or may not be, and the barcode rule downstream
            // decides those on its own.
            presentedAtEntry: presentedAtEntry,
            address: address,
            directionsURL: directions,
            fields: extras
        )
    }

    /// The barcode, straight off the pass.
    ///
    /// Worth noting what this replaces: the image path renders the file and hands it
    /// to Vision to decode, which fails outright in the Simulator and degrades on a
    /// blurry screenshot. Here the payload is a string in a JSON file and the
    /// symbology is declared, so there is nothing to detect and nothing to get wrong.
    var barcode: (payload: String, symbology: BarcodeSymbology)? {
        let candidates = (pass.barcodes ?? []) + [pass.barcode].compactMap { $0 }
        for candidate in candidates {
            guard let message = trimmed(candidate.message) else { continue }
            return (message, Self.symbology(candidate.format))
        }
        return nil
    }

    // MARK: - Derived odds and ends

    /// The eyebrow's word for what this is, from the pass's own style. Deliberately
    /// coarse: the style is all a pass declares, and guessing "Concert" from an
    /// `eventTicket` would be inventing detail.
    private var eventType: String? {
        switch pass.style {
        case .eventTicket:  return "Event"
        case .boardingPass: return "Boarding pass"
        case .coupon:       return "Coupon"
        case .storeCard:    return "Card"
        case .generic:      return "Pass"
        case nil:           return nil
        }
    }

    private var presentedAtEntry: Bool? {
        switch pass.style {
        case .eventTicket, .boardingPass: return true
        default:                          return nil
        }
    }

    // MARK: - Field selection

    /// Labels are matched on lowercased substrings so an issuer's wording variations
    /// ("Guest", "Guest Name", "Attendee") all land, without a table of exact
    /// spellings that only ever grows.
    private static let guestLabels     = ["guest", "attendee", "passenger", "member", "holder", "name"]
    private static let seatLabels      = ["seat"]
    private static let rowLabels       = ["row"]
    private static let sectionLabels   = ["section", "block", "stand", "tier", "zone"]
    private static let gateLabels      = ["gate", "door", "entrance"]
    private static let referenceLabels = ["confirmation", "reference", "booking", "order", "record locator", "pnr"]
    private static let locationLabels  = ["location", "venue", "address", "where", "place"]
    private static let eventPageLabels = ["event", "page", "link", "website", "details", "info"]
    private static let directionsLabels = ["direction", "map", "getting there", "travel"]
    private static let mapHosts        = ["maps.google", "google.com/maps", "maps.apple", "goo.gl/maps", "share.google", "maps.app"]

    private typealias PlacedField = (field: PassJSON.Field, placement: TicketMeta.PassField.Placement)

    /// Fields in the order a pass reads: the face top-to-bottom, then the back.
    ///
    /// Built with a loop rather than five mapped arrays concatenated with `+`, which
    /// defeats the type checker outright — the same trap the extraction path hit with
    /// its coalescing chains.
    private var orderedFields: [PlacedField] {
        guard let groups = pass.groups else { return [] }
        let sources: [(fields: [PassJSON.Field]?, placement: TicketMeta.PassField.Placement)] = [
            (groups.headerFields, .header),
            (groups.primaryFields, .primary),
            (groups.secondaryFields, .secondary),
            (groups.auxiliaryFields, .auxiliary),
            (groups.backFields, .back)
        ]
        var out: [PlacedField] = []
        for source in sources {
            for field in source.fields ?? [] {
                out.append((field: field, placement: source.placement))
            }
        }
        return out
    }

    /// Values already claimed by a typed slot, so nothing is printed twice.
    ///
    /// Matched on the VALUE rather than the field key, because a pass routinely
    /// repeats the same datum front and back under different keys — this one carries
    /// `guest_name` and `guest_name_back`, and `ticket_info` and `ticket_info_back`.
    /// Keying on the value collapses those pairs; keying on the key would print each
    /// of them twice.
    private struct ConsumedValues {
        private var values: Set<String> = []

        mutating func insert(_ value: String) {
            values.insert(Self.normalise(value))
        }

        func contains(_ value: String) -> Bool {
            values.contains(Self.normalise(value))
        }

        private static func normalise(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// First usable value from the given placements, consuming it.
    private func firstValue(
        in placements: [TicketMeta.PassField.Placement],
        consuming consumed: inout ConsumedValues
    ) -> String? {
        for entry in orderedFields where placements.contains(entry.placement) {
            if let value = displayValue(entry.field) {
                consumed.insert(value)
                return value
            }
        }
        return nil
    }

    /// First value whose LABEL contains one of `needles`.
    private func labelledValue(
        matching needles: [String],
        consuming consumed: inout ConsumedValues
    ) -> String? {
        for entry in orderedFields {
            guard let label = trimmed(entry.field.label)?.lowercased(),
                  needles.contains(where: { label.contains($0) }),
                  let value = displayValue(entry.field),
                  !consumed.contains(value),
                  // A URL is never one of these short facts; it is a link that has
                  // its own handling and would otherwise land as a "Name".
                  !value.lowercased().hasPrefix("http") else { continue }
            consumed.insert(value)
            return value
        }
        return nil
    }

    /// The location, at one of its two resolutions.
    ///
    /// A pass writes the place twice: a name on the face and a postal address on the
    /// back. Rather than trusting the labels — issuers use "Location" for both — the
    /// candidates are gathered and split on length, which is what actually
    /// distinguishes them. With only one candidate, it is the venue and there is no
    /// address, because a single string is the name of the place, not a second copy
    /// of it.
    private func locationValue(short: Bool, consuming consumed: inout ConsumedValues) -> String? {
        var candidates: [String] = []
        for entry in orderedFields {
            guard let label = trimmed(entry.field.label)?.lowercased(),
                  Self.locationLabels.contains(where: { label.contains($0) }),
                  let value = displayValue(entry.field),
                  !value.lowercased().hasPrefix("http") else { continue }
            if !candidates.contains(value) { candidates.append(value) }
        }
        // The coordinates' own label is a fair venue name when no field carried one.
        if candidates.isEmpty, let relevant = trimmed(pass.locations?.first?.relevantText) {
            candidates.append(relevant)
        }
        guard !candidates.isEmpty else { return nil }

        let sorted = candidates.sorted { $0.count < $1.count }
        let picked: String?
        if short {
            picked = sorted.first
        } else {
            // Only when it is materially longer. "Lorong AI @ One-North" and
            // "Lorong AI" are the same place said twice, not a name and an address.
            guard let longest = sorted.last, let shortest = sorted.first,
                  longest != shortest, longest.count > shortest.count + 8 else { return nil }
            picked = longest
        }
        guard let picked else { return nil }
        consumed.insert(picked)
        return picked
    }

    /// First URL value whose label matches, optionally constrained by host.
    ///
    /// The host test is what keeps the event page and the directions link apart: both
    /// are URLs sitting in back fields, and a label match alone would hand whichever
    /// came first to both slots.
    private func urlValue(
        matching needles: [String],
        excluding excludedHosts: [String] = [],
        requiring requiredHosts: [String] = [],
        consuming consumed: inout ConsumedValues
    ) -> String? {
        for entry in orderedFields {
            guard let value = displayValue(entry.field),
                  value.lowercased().hasPrefix("http"),
                  !consumed.contains(value) else { continue }
            let host = value.lowercased()
            if !requiredHosts.isEmpty, !requiredHosts.contains(where: { host.contains($0) }) { continue }
            if excludedHosts.contains(where: { host.contains($0) }) { continue }
            let label = trimmed(entry.field.label)?.lowercased() ?? ""
            guard requiredHosts.isEmpty == false || needles.contains(where: { label.contains($0) }) else { continue }
            consumed.insert(value)
            return value
        }
        return nil
    }

    /// The printed start time.
    ///
    /// Preferred, in order:
    ///  1. A bare clock time already printed somewhere on the face. Luma puts "18:30"
    ///     in the header field's LABEL with the date as its value, which reads
    ///     backwards written down and is exactly right on a card. Taking it verbatim
    ///     is what keeps the number on our card equal to the number on theirs.
    ///  2. `relevantDate`, formatted in the DEVICE timezone.
    ///
    /// Step 2 carries the caveat behind #163 / #168: a pass states an instant, not a
    /// wall clock, and rendering an instant somewhere else shows the wrong number. We
    /// cannot do better — a pass declares no timezone, and coordinates alone do not
    /// yield one offline — and it is what Apple Wallet shows on the same phone, so at
    /// least the two agree. Step 1 exists because a literal printed string has no
    /// such problem, which is why it wins.
    private func printedTime(consuming consumed: inout ConsumedValues) -> String? {
        for entry in orderedFields where entry.placement == .header || entry.placement == .primary {
            for candidate in [entry.field.label, entry.field.value?.stringValue] {
                guard let text = trimmed(candidate), Self.isClockTime(text) else { continue }
                consumed.insert(text)
                return text
            }
        }
        guard let date = Self.iso8601(pass.relevantDate) else { return nil }
        return Self.localTimeText(date)
    }

    /// Fields no typed slot took, ready for generic rendering.
    private func remainingFields(consumed: ConsumedValues) -> [TicketMeta.PassField] {
        var out: [TicketMeta.PassField] = []
        var seen = consumed
        for entry in orderedFields {
            guard let label = trimmed(entry.field.label),
                  let value = displayValue(entry.field),
                  !seen.contains(value),
                  // A field whose LABEL was taken as a value has already been used. This
                  // is Luma's header inversion: it writes the printed time as the label
                  // and the date as the value, so the time is consumed but the value is
                  // not, and without this check the pass grew an extra field labelled
                  // "18:30" whose value was the date.
                  !seen.contains(label) else { continue }
            seen.insert(value)
            out.append(
                TicketMeta.PassField(
                    label: label,
                    value: value,
                    // A leftover header or primary field has no render site of its own —
                    // the card's hero and title are built from the date and the name, not
                    // from whatever else is up there. Re-placed as auxiliary so it shows
                    // as a labelled fact instead of being silently dropped, which is what
                    // would happen to a boarding pass's second endpoint.
                    placement: Self.renderPlacement(entry.placement)
                )
            )
        }
        return out
    }

    private static func renderPlacement(
        _ placement: TicketMeta.PassField.Placement
    ) -> TicketMeta.PassField.Placement {
        switch placement {
        case .header, .primary, .auxiliary: return .auxiliary
        case .secondary:                    return .secondary
        case .back:                         return .back
        }
    }

    // MARK: - Values

    /// A field's value as the pass would print it.
    ///
    /// `value` is typed loosely by the spec — a string, a number, or an ISO 8601
    /// date — and a date field additionally carries `dateStyle` / `timeStyle` saying
    /// how to render it. Honouring those is what turns
    /// `"2026-07-31T10:30:00.000Z"` into "31 July 2026 at 18:30" rather than
    /// printing machine text on the card.
    private func displayValue(_ field: PassJSON.Field) -> String? {
        guard let raw = field.value else { return nil }
        if let text = raw.stringValue {
            if let date = Self.iso8601(text), field.dateStyle != nil || field.timeStyle != nil {
                return Self.styledDateText(date, dateStyle: field.dateStyle, timeStyle: field.timeStyle)
            }
            return trimmed(text)
        }
        return trimmed(raw.numberText)
    }

    private func trimmed(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // MARK: - Formatting

    /// A bare clock time and nothing else: "18:30", "7.30pm", "9:05 AM".
    static func isClockTime(_ text: String) -> Bool {
        let pattern = #"^\d{1,2}[:.]\d{2}\s*([AaPp]\.?[Mm]\.?)?$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Lenient ISO 8601: with or without fractional seconds, with or without a
    /// timezone. Pass writers emit all three shapes.
    static func iso8601(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let noZone = DateFormatter()
        noZone.locale = Locale(identifier: "en_US_POSIX")
        noZone.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        noZone.timeZone = .current
        return noZone.date(from: text)
    }

    /// `yyyy-MM-dd` of the instant in the DEVICE timezone, which is the shape the
    /// rest of the pipeline parses a date in.
    static func localDayText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// "18:30" in the device's own time format.
    static func localTimeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        f.timeZone = .current
        // Same reason as `TaskTicketContext.dueClockText`: this string lands in a
        // hand-editable field, and an invisible narrow no-break space in it makes a
        // retyped value differ from the stored one for no visible reason.
        return f.string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Render a date field the way its `dateStyle` / `timeStyle` asked for.
    static func styledDateText(_ date: Date, dateStyle: String?, timeStyle: String?) -> String {
        let f = DateFormatter()
        f.timeZone = .current
        f.dateStyle = Self.style(dateStyle)
        f.timeStyle = Self.style(timeStyle)
        if f.dateStyle == .none && f.timeStyle == .none { f.dateStyle = .medium }
        return f.string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// `PKDateStyleShort` and friends map one-to-one onto `DateFormatter.Style`.
    private static func style(_ raw: String?) -> DateFormatter.Style {
        switch raw {
        case "PKDateStyleShort":  return .short
        case "PKDateStyleMedium": return .medium
        case "PKDateStyleLong":   return .long
        case "PKDateStyleFull":   return .full
        default:                  return .none
        }
    }

    /// Map the pass's barcode format onto our own symbology ids. `other` for a
    /// format we cannot regenerate, which falls the card back to a crop of the
    /// original exactly as an undecodable image does.
    static func symbology(_ format: String?) -> BarcodeSymbology {
        switch format {
        case "PKBarcodeFormatQR":      return .qr
        case "PKBarcodeFormatPDF417":  return .pdf417
        case "PKBarcodeFormatAztec":   return .aztec
        case "PKBarcodeFormatCode128": return .code128
        default:                       return .other
        }
    }
}

// MARK: - pass.json

/// `pass.json` as the spec defines it, narrowed to the parts a ticket needs.
///
/// Unknown keys are ignored by `Codable`, which is the behaviour we want: passes
/// carry issuer-specific extras, web-service credentials and localisation keys that
/// are none of our business, and a strict decode would reject a perfectly good pass
/// for carrying one.
struct PassJSON: Decodable {

    enum Style: String {
        case eventTicket, boardingPass, coupon, storeCard, generic
    }

    var description: String?
    var organizationName: String?
    var logoText: String?
    var serialNumber: String?
    var relevantDate: String?
    var expirationDate: String?
    var voided: Bool?

    var barcodes: [Barcode]?
    /// The pre-iOS 9 single-barcode key. Still emitted by some issuers alongside
    /// `barcodes`, and occasionally instead of it.
    var barcode: Barcode?
    var locations: [Location]?

    private var eventTicket: FieldGroups?
    private var boardingPass: FieldGroups?
    private var coupon: FieldGroups?
    private var storeCard: FieldGroups?
    private var generic: FieldGroups?

    /// Which of the five style keys the pass actually used. Exactly one is present
    /// on a valid pass; `nil` means this is not one.
    var style: Style? {
        if eventTicket != nil  { return .eventTicket }
        if boardingPass != nil { return .boardingPass }
        if coupon != nil       { return .coupon }
        if storeCard != nil    { return .storeCard }
        if generic != nil      { return .generic }
        return nil
    }

    /// The field groups of whichever style this pass is.
    var groups: FieldGroups? {
        eventTicket ?? boardingPass ?? coupon ?? storeCard ?? generic
    }

    struct FieldGroups: Decodable {
        var headerFields: [Field]?
        var primaryFields: [Field]?
        var secondaryFields: [Field]?
        var auxiliaryFields: [Field]?
        var backFields: [Field]?
    }

    struct Field: Decodable {
        var key: String?
        var label: String?
        var value: LooseValue?
        var dateStyle: String?
        var timeStyle: String?
    }

    struct Barcode: Decodable {
        var format: String?
        var message: String?
    }

    struct Location: Decodable {
        var latitude: Double?
        var longitude: Double?
        var relevantText: String?
    }

    /// A field's `value`, which the spec allows to be a string, a number or an ISO
    /// 8601 date string. Decoded permissively so a numeric seat ("12") does not
    /// throw the whole pass away.
    struct LooseValue: Decodable {
        var stringValue: String?
        var doubleValue: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { stringValue = s; return }
            if let i = try? c.decode(Int.self) { doubleValue = Double(i); return }
            if let d = try? c.decode(Double.self) { doubleValue = d; return }
            if let b = try? c.decode(Bool.self) { stringValue = b ? "Yes" : "No"; return }
            stringValue = nil
        }

        /// A number rendered without a trailing `.0`, so seat 12 is "12".
        var numberText: String? {
            guard let doubleValue else { return nil }
            if doubleValue == doubleValue.rounded(), abs(doubleValue) < 1e15 {
                return String(Int(doubleValue))
            }
            return String(doubleValue)
        }
    }
}
