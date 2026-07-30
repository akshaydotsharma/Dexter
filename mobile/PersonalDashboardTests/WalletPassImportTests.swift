import XCTest
import Compression
@testable import PersonalDashboard

/// Reading a `.pkpass` (#420).
///
/// This path is worth testing precisely because nothing downstream of it can tell
/// that it went wrong. Every other route into a ticket ends with a person looking at
/// a card and correcting it; this one claims to be exact, so a field silently landing
/// in the wrong slot — or an inflate that returns truncated JSON — reads as "the pass
/// just did not have that on it".
///
/// Three things are asserted:
///
/// 1. **The ZIP reader**, against both compression methods a real writer emits. A
///    pass's `pass.json` is deflated in practice, so the stored-only case passing
///    proves very little on its own.
/// 2. **The field mapping**, against the exact `pass.json` shape a Luma event pass
///    ships — including its two deliberate traps: the printed time lives in the
///    header field's LABEL with the date as its value, and the location is written
///    twice at two resolutions under the same label.
/// 3. **The absence of duplication.** The generic field list exists to carry what the
///    typed slots do not, and a value reaching both is the failure mode that turns a
///    card into the same fact printed twice.
final class WalletPassImportTests: XCTestCase {

    // MARK: - Fixtures

    /// A Luma event pass's `pass.json`, reduced to the fields that matter here and
    /// otherwise byte-for-byte as issued: the header field carrying "18:30" as its
    /// LABEL, the venue on the face and the full address on the back under labels
    /// that do not distinguish them, an event page and a Maps link that are both
    /// URLs in back fields, and a front/back duplicate pair for guest and ticket.
    static let lumaPassJSON = """
    {
      "formatVersion": 1,
      "description": "Vibe Coders SG #2 - Securing Vibe Coded Apps",
      "organizationName": "Vibe Coders SG #2 - Securing Vibe Coded Apps",
      "relevantDate": "2026-07-31T10:30:00.000Z",
      "expirationDate": "2026-07-31T16:00:00.000Z",
      "eventTicket": {
        "headerFields": [
          { "key": "start_at", "label": "18:30", "value": "31 Jul 2026" }
        ],
        "primaryFields": [
          { "key": "event_name", "value": "Vibe Coders SG #2 - Securing Vibe Coded Apps" }
        ],
        "secondaryFields": [
          { "key": "event_address", "label": "Location", "value": "Lorong AI @ One-North" }
        ],
        "auxiliaryFields": [
          { "key": "guest_name", "value": "Akshay Sharma", "label": "Guest" },
          { "key": "ticket_info", "value": "In-Person", "label": "Ticket" }
        ],
        "backFields": [
          { "key": "event_name_back", "value": "Vibe Coders SG #2 - Securing Vibe Coded Apps", "label": "Event" },
          { "key": "event_url", "label": "Event Page", "value": "https://luma.com/4ptmrf91" },
          { "key": "address", "value": "Lorong AI @ One-North, 69 Ayer Rajah Cres., Level 3 Vidacity, Singapore 139961", "label": "Address" },
          { "key": "google_maps_url", "label": "Directions", "value": "https://www.google.com/maps/search/?api=1&query=Lorong%20AI" },
          { "key": "guest_name_back", "value": "Akshay Sharma", "label": "Guest" },
          { "key": "guest_email", "value": "sharma.akshay.mi@gmail.com", "label": "Email" },
          { "key": "ticket_info_back", "value": "In-Person", "label": "Ticket" }
        ]
      },
      "locations": [
        { "latitude": 1.296167, "longitude": 103.787009, "relevantText": "Lorong AI @ One-North" }
      ],
      "barcodes": [
        {
          "format": "PKBarcodeFormatQR",
          "messageEncoding": "utf-8",
          "message": "https://luma.com/check-in/evt-oQFgiXtb73y8yCh?pk=g-TZIx7lJbtxy4uaO"
        }
      ]
    }
    """

    // MARK: - ZIP reader

    func testReadsAStoredEntry() throws {
        let payload = Data("hello pass".utf8)
        let archive = try XCTUnwrap(
            ZipArchiveReader(data: Self.makeZip(name: "pass.json", payload: payload, deflate: false))
        )
        XCTAssertEqual(archive.entry(named: "pass.json"), payload)
    }

    /// The case that matters: every real pass writer deflates its `pass.json`, so a
    /// broken inflate would fail on every actual file while a stored-entry test passed.
    func testReadsADeflatedEntry() throws {
        let payload = Data(Self.lumaPassJSON.utf8)
        let archive = try XCTUnwrap(
            ZipArchiveReader(data: Self.makeZip(name: "pass.json", payload: payload, deflate: true))
        )
        XCTAssertEqual(archive.entry(named: "pass.json"), payload)
    }

    func testMissingEntryIsNil() throws {
        let archive = try XCTUnwrap(
            ZipArchiveReader(data: Self.makeZip(name: "pass.json", payload: Data("{}".utf8), deflate: true))
        )
        XCTAssertNil(archive.entry(named: "manifest.json"))
    }

    /// Bytes that are not a ZIP must be refused rather than crashing on a bounds read,
    /// because this runs against whatever file someone picked.
    func testNonZipIsRefused() {
        XCTAssertNil(ZipArchiveReader(data: Data("not a zip at all".utf8)))
        XCTAssertNil(ZipArchiveReader(data: Data()))
        XCTAssertNil(ZipArchiveReader(data: Data(repeating: 0x50, count: 40)))
    }

    /// A ZIP with no `pass.json` is not a pass, so the importer must decline it and let
    /// the image pipeline have the file.
    func testZipWithoutPassJSONIsNotAPass() {
        let zip = Self.makeZip(name: "photo.jpg", payload: Data(repeating: 0xAB, count: 64), deflate: true)
        XCTAssertNil(WalletPassImport.read(data: zip))
    }

    // MARK: - Field mapping

    func testMapsALumaEventPass() throws {
        let extracted = try XCTUnwrap(pass(Self.lumaPassJSON)).extracted()

        XCTAssertEqual(extracted.eventTitle, "Vibe Coders SG #2 - Securing Vibe Coded Apps")
        XCTAssertEqual(extracted.eventType, "Event")
        XCTAssertEqual(extracted.guestName, "Akshay Sharma")
        XCTAssertEqual(extracted.eventURL, "https://luma.com/4ptmrf91")
        XCTAssertEqual(extracted.presentedAtEntry, true)
        // A pass states its date in full, so the year-inference backstop must not run.
        XCTAssertTrue(extracted.yearWasPrinted)

        // The venue is the SHORT form and the address the long one, even though the
        // issuer labels them "Location" and "Address" interchangeably.
        XCTAssertEqual(extracted.venue, "Lorong AI @ One-North")
        XCTAssertEqual(
            extracted.address,
            "Lorong AI @ One-North, 69 Ayer Rajah Cres., Level 3 Vidacity, Singapore 139961"
        )

        // The Maps link goes to directions and the event page does not, even though
        // both are URLs sitting in back fields.
        XCTAssertEqual(
            extracted.directionsURL,
            "https://www.google.com/maps/search/?api=1&query=Lorong%20AI"
        )
    }

    /// The printed time is taken VERBATIM from the header field's label, which is where
    /// Luma puts it. Formatting `relevantDate` instead would render the instant in
    /// whatever timezone the test machine is in, which is the #163 / #168 failure.
    func testTakesThePrintedTimeVerbatim() throws {
        let extracted = try XCTUnwrap(pass(Self.lumaPassJSON)).extracted()
        XCTAssertEqual(extracted.startTimeText, "18:30")
    }

    /// With no printed clock time anywhere on the face, `relevantDate` is the fallback —
    /// rendered in the device timezone, as Apple Wallet itself does.
    func testFallsBackToRelevantDateForTheTime() throws {
        let json = """
        {
          "formatVersion": 1,
          "description": "Timeless",
          "relevantDate": "2026-07-31T10:30:00Z",
          "eventTicket": {
            "primaryFields": [{ "key": "n", "value": "Timeless" }]
          }
        }
        """
        let extracted = try XCTUnwrap(pass(json)).extracted()
        let expected = WalletPassImport.localTimeText(
            try XCTUnwrap(WalletPassImport.iso8601("2026-07-31T10:30:00Z"))
        )
        XCTAssertEqual(extracted.startTimeText, expected)
    }

    /// The barcode comes off the JSON, so there is nothing to detect: no Vision call,
    /// no dependence on image quality, and it works in the Simulator (where
    /// `VNDetectBarcodesRequest` fails for every input).
    func testReadsTheBarcodeWithoutDecodingAnImage() throws {
        let barcode = try XCTUnwrap(try XCTUnwrap(pass(Self.lumaPassJSON)).barcode)
        XCTAssertEqual(barcode.payload, "https://luma.com/check-in/evt-oQFgiXtb73y8yCh?pk=g-TZIx7lJbtxy4uaO")
        XCTAssertEqual(barcode.symbology, .qr)
    }

    // MARK: - Generic fields

    /// Everything a typed slot did not take, and NOTHING it did.
    ///
    /// This pass repeats the guest and the ticket type front and back under different
    /// keys, and states its own name in a back field. All three must be absent here:
    /// two are already typed fields and the third is the card's title, so carrying them
    /// would print each of them twice on one card.
    func testExtraFieldsCarryOnlyWhatIsLeft() throws {
        let extracted = try XCTUnwrap(pass(Self.lumaPassJSON)).extracted()
        let labels = extracted.fields.map(\.label)

        XCTAssertEqual(labels.sorted(), ["Email", "Ticket"])

        let ticket = try XCTUnwrap(extracted.fields.first { $0.label == "Ticket" })
        XCTAssertEqual(ticket.value, "In-Person")
        // Front-of-pass, so it renders on the card's face.
        XCTAssertEqual(ticket.placement, .auxiliary)

        let email = try XCTUnwrap(extracted.fields.first { $0.label == "Email" })
        XCTAssertEqual(email.value, "sharma.akshay.mi@gmail.com")
        // Back-of-pass, so it renders on the detail surface, not the card.
        XCTAssertEqual(email.placement, .back)
    }

    /// The placement split is what routes a field to the face or to the back, so the
    /// two accessors the views read must agree with it.
    func testFacePlacementDrivesWhichSurfaceRenders() throws {
        let extracted = try XCTUnwrap(pass(Self.lumaPassJSON)).extracted()
        var meta = TicketMeta()
        meta.fields = extracted.fields

        XCTAssertEqual(meta.faceFields.map(\.label), ["Ticket"])
        XCTAssertEqual(meta.backFields.map(\.label), ["Email"])
    }

    /// A field with a label and no value, or a value and no label, has nothing to
    /// render as a label-over-value row and must not become an empty one.
    func testUnrenderableFieldsAreDropped() {
        XCTAssertFalse(TicketMeta.PassField(label: "", value: "x", placement: .back).isRenderable)
        XCTAssertFalse(TicketMeta.PassField(label: "x", value: "  ", placement: .back).isRenderable)
        XCTAssertTrue(TicketMeta.PassField(label: "Email", value: "a@b.c", placement: .back).isRenderable)
    }

    /// A date-styled field is rendered the way the pass asked for, not printed as
    /// machine text. Asserted loosely on purpose: the exact string is locale- and
    /// timezone-dependent, and pinning it would make this fail on a machine set to
    /// anything but the author's.
    func testDateStyledFieldsAreFormattedNotPrintedRaw() throws {
        let json = """
        {
          "formatVersion": 1,
          "description": "Styled",
          "eventTicket": {
            "primaryFields": [{ "key": "n", "value": "Styled" }],
            "backFields": [
              {
                "key": "start",
                "label": "Start Time",
                "value": "2026-07-31T10:30:00.000Z",
                "dateStyle": "PKDateStyleLong",
                "timeStyle": "PKDateStyleShort"
              }
            ]
          }
        }
        """
        let extracted = try XCTUnwrap(pass(json)).extracted()
        let start = try XCTUnwrap(extracted.fields.first { $0.label == "Start Time" })
        XCTAssertFalse(start.value.contains("T"), "raw ISO text reached the card: \(start.value)")
        XCTAssertTrue(start.value.contains("2026"), "the formatted date lost its year: \(start.value)")
    }

    /// A pass whose location appears only once is a NAME, not an address. Inventing a
    /// second row from the same string is the duplication this guards against.
    func testASingleLocationIsAVenueAndNotAnAddress() throws {
        let json = """
        {
          "formatVersion": 1,
          "description": "One place",
          "eventTicket": {
            "primaryFields": [{ "key": "n", "value": "One place" }],
            "secondaryFields": [{ "key": "l", "label": "Location", "value": "The O2, London" }]
          }
        }
        """
        let extracted = try XCTUnwrap(pass(json)).extracted()
        XCTAssertEqual(extracted.venue, "The O2, London")
        XCTAssertNil(extracted.address)
    }

    /// A boarding pass is the other style that gets admitted to the Wallet outright,
    /// and its own vocabulary has to land in the right slots.
    func testMapsABoardingPassStyle() throws {
        let json = """
        {
          "formatVersion": 1,
          "description": "SQ 322",
          "boardingPass": {
            "headerFields": [{ "key": "gate", "label": "Gate", "value": "A11" }],
            "primaryFields": [{ "key": "route", "value": "SIN to LHR" }],
            "auxiliaryFields": [
              { "key": "seat", "label": "Seat", "value": "12A" },
              { "key": "passenger", "label": "Passenger", "value": "SHARMA/AKSHAY" },
              { "key": "pnr", "label": "Booking Reference", "value": "X7K2QP" }
            ]
          }
        }
        """
        let extracted = try XCTUnwrap(pass(json)).extracted()
        XCTAssertEqual(extracted.eventType, "Boarding pass")
        XCTAssertEqual(extracted.gate, "A11")
        XCTAssertEqual(extracted.seat, "12A")
        XCTAssertEqual(extracted.guestName, "SHARMA/AKSHAY")
        XCTAssertEqual(extracted.reference, "X7K2QP")
        XCTAssertEqual(extracted.presentedAtEntry, true)
    }

    /// A store card is not something anyone hands over at a door, so the importer must
    /// leave that judgement unmade rather than admitting it to the Wallet on the
    /// strength of being a pass.
    func testAStoreCardIsNotJudgedAPass() throws {
        let json = """
        {
          "formatVersion": 1,
          "description": "Loyalty",
          "storeCard": { "primaryFields": [{ "key": "b", "label": "Balance", "value": "12.00" }] }
        }
        """
        let extracted = try XCTUnwrap(pass(json)).extracted()
        XCTAssertNil(extracted.presentedAtEntry)
        XCTAssertEqual(extracted.eventType, "Card")
    }

    /// A numeric field value is legal per the spec and must not throw the pass away or
    /// render as "12.0".
    func testNumericValuesRenderAsIntegers() throws {
        let json = """
        {
          "formatVersion": 1,
          "description": "Numbers",
          "eventTicket": {
            "primaryFields": [{ "key": "n", "value": "Numbers" }],
            "auxiliaryFields": [{ "key": "table", "label": "Table", "value": 12 }]
          }
        }
        """
        let extracted = try XCTUnwrap(pass(json)).extracted()
        let table = try XCTUnwrap(extracted.fields.first { $0.label == "Table" })
        XCTAssertEqual(table.value, "12")
    }

    // MARK: - Helpers

    private func pass(_ json: String) -> WalletPassImport? {
        WalletPassImport.read(data: Self.makeZip(name: "pass.json", payload: Data(json.utf8), deflate: true))
    }

    /// Build a single-entry ZIP by hand.
    ///
    /// Written out rather than shelling to `zip`, because the test target runs on a
    /// device and in the Simulator where there is no `zip` binary, and rather than
    /// checking in a real `.pkpass`, which would commit a live check-in token.
    static func makeZip(name: String, payload: Data, deflate: Bool) -> Data {
        let nameBytes = Data(name.utf8)
        let stored: Data
        let method: UInt16
        if deflate, let compressed = rawDeflate(payload) {
            stored = compressed
            method = 8
        } else {
            stored = payload
            method = 0
        }
        let crc = crc32(payload)

        func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: UInt32) -> Data {
            Data([
                UInt8(v & 0xFF),
                UInt8((v >> 8) & 0xFF),
                UInt8((v >> 16) & 0xFF),
                UInt8((v >> 24) & 0xFF)
            ])
        }

        var local = Data()
        local += u32(0x0403_4b50)
        local += u16(20)                          // version needed
        local += u16(0)                           // flags
        local += u16(method)
        local += u16(0) + u16(0)                  // mod time / date
        local += u32(crc)
        local += u32(UInt32(stored.count))
        local += u32(UInt32(payload.count))
        local += u16(UInt16(nameBytes.count))
        local += u16(0)                           // extra length
        local += nameBytes
        local += stored

        var central = Data()
        central += u32(0x0201_4b50)
        central += u16(20) + u16(20)              // version made by / needed
        central += u16(0)                         // flags
        central += u16(method)
        central += u16(0) + u16(0)                // mod time / date
        central += u32(crc)
        central += u32(UInt32(stored.count))
        central += u32(UInt32(payload.count))
        central += u16(UInt16(nameBytes.count))
        central += u16(0) + u16(0)                // extra / comment length
        central += u16(0) + u16(0)                // disk number / internal attrs
        central += u32(0)                         // external attrs
        central += u32(0)                         // local header offset
        central += nameBytes

        var eocd = Data()
        eocd += u32(0x0605_4b50)
        eocd += u16(0) + u16(0)                   // disk numbers
        eocd += u16(1) + u16(1)                   // entry counts
        eocd += u32(UInt32(central.count))
        eocd += u32(UInt32(local.count))
        eocd += u16(0)                            // comment length

        return local + central + eocd
    }

    /// Raw DEFLATE, matching what a ZIP entry stores (and what the reader inflates).
    static func rawDeflate(_ input: Data) -> Data? {
        let capacity = input.count + 1024
        var out = Data(count: capacity)
        let written: Int = out.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { src in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    dstBase, capacity,
                    srcBase, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }

    /// Standard CRC-32. The reader does not verify it, but a writer that emits a wrong
    /// one produces an archive other tools reject, and this fixture should be a real
    /// ZIP rather than one only our own reader accepts.
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Upgrading an attachment in place

/// A pass completing a ticket the task already has (#420).
///
/// The rule under test is a promise about DATA LOSS: a richer copy of a ticket fills
/// what is missing and touches nothing else. Getting it wrong in the permissive
/// direction silently replaces values someone typed by hand, and there is no way for
/// them to notice — which is exactly the class of bug that has to be asserted rather
/// than reasoned about.
@MainActor
final class TaskTicketEnrichmentTests: XCTestCase {

    private var store: SwiftDataStore!
    private var createdPaths: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        createdPaths = []
    }

    override func tearDown() async throws {
        for path in createdPaths {
            try? TicketStorage.taskTickets.delete(relativePath: path)
        }
        store = nil
        createdPaths = []
        try await super.tearDown()
    }

    /// A screenshot-era row gains everything the pass knows and it did not.
    func testPassFillsTheGapsOnAnExistingTicket() throws {
        let service = TaskTicketService(store: store)
        let todo = insertTodo()
        let existing = try insertTicket(
            todo: todo,
            eventTitle: "Vibe Coders SG #2 - Securing Vibe Coded Apps",
            venue: "Lorong AI @ One-North",
            startTimeText: "18:30"
        )

        let read = try makePassRead()
        XCTAssertTrue(try service.enrich(existing, from: read), "nothing was filled in")

        let updated = try XCTUnwrap(try service.ticket(id: existing.id))
        let meta = try XCTUnwrap(updated.ticketMeta)
        XCTAssertEqual(
            meta.address,
            "Lorong AI @ One-North, 69 Ayer Rajah Cres., Level 3 Vidacity, Singapore 139961"
        )
        XCTAssertEqual(meta.guestName, "Akshay Sharma")
        XCTAssertEqual(meta.eventURL, "https://luma.com/4ptmrf91")
        XCTAssertNotNil(meta.directionsURL)
        XCTAssertEqual(meta.fields?.map(\.label).sorted(), ["Email", "Ticket"])
        // The row had no file of its own, so it adopts the pass.
        XCTAssertTrue(TicketStorage.isPass(updated.attachmentPath))
    }

    /// The load-bearing assertion: a value already on the row survives untouched, even
    /// when the pass states a different one. Anything already there may have been
    /// corrected by hand.
    func testPassNeverOverwritesWhatIsAlreadyThere() throws {
        let service = TaskTicketService(store: store)
        let todo = insertTodo()
        let existing = try insertTicket(
            todo: todo,
            eventTitle: "Vibe Coders — my own title",
            venue: "Level 3, Vidacity",
            startTimeText: "6.30pm",
            seat: "A1",
            reference: "MINE-1"
        )

        _ = try service.enrich(existing, from: try makePassRead())

        let updated = try XCTUnwrap(try service.ticket(id: existing.id))
        XCTAssertEqual(updated.eventTitle, "Vibe Coders — my own title")
        XCTAssertEqual(updated.venue, "Level 3, Vidacity")
        XCTAssertEqual(updated.startTimeText, "6.30pm")
        XCTAssertEqual(updated.seat, "A1")
        XCTAssertEqual(updated.reference, "MINE-1")
        // And it still gained what it genuinely lacked.
        XCTAssertEqual(updated.ticketMeta?.guestName, "Akshay Sharma")
    }

    /// A row that already has everything reports no change, so the caller says "already
    /// attached" rather than claiming to have updated something.
    func testNothingToFillReportsNoChange() throws {
        let service = TaskTicketService(store: store)
        let todo = insertTodo()
        let read = try makePassRead()
        let full = read.ticket(todoId: todo.clientUUID)
        _ = try service.attach(full, todoId: todo.clientUUID)
        createdPaths.append(full.attachmentPath)

        let stored = try XCTUnwrap(try service.list(todoId: todo.clientUUID).first)
        let second = try makePassRead()
        XCTAssertFalse(try service.enrich(stored, from: second))
        // The unused copy is not left on disk.
        XCTAssertNil(TicketStorage.taskTickets.load(relativePath: second.attachmentPath))
    }

    /// A row that already has a file keeps it, and the second copy's bytes go back out
    /// rather than leaking a file nothing references.
    func testAnExistingFileIsKeptAndTheSpareIsDiscarded() throws {
        let service = TaskTicketService(store: store)
        let todo = insertTodo()
        let firstPath = try TicketStorage.taskTickets.save(pdfData: Data("%PDF-1.4 fake".utf8))
        createdPaths.append(firstPath)
        let existing = try insertTicket(todo: todo, attachmentPath: firstPath)

        let read = try makePassRead()
        _ = try service.enrich(existing, from: read)

        let updated = try XCTUnwrap(try service.ticket(id: existing.id))
        XCTAssertEqual(updated.attachmentPath, firstPath)
        XCTAssertNil(TicketStorage.taskTickets.load(relativePath: read.attachmentPath))
    }

    // MARK: - Fixtures

    private func insertTodo(title: String = "Vibe Coders SG #2") -> LocalTodo {
        let todo = LocalTodo(title: title)
        store.context.insert(todo)
        try? store.context.save()
        return todo
    }

    @discardableResult
    private func insertTicket(
        todo: LocalTodo,
        eventTitle: String = "",
        venue: String = "",
        startTimeText: String = "",
        seat: String = "",
        reference: String = "",
        attachmentPath: String = ""
    ) throws -> TaskTicket {
        let row = LocalTaskTicket(
            todoClientUUID: todo.clientUUID,
            attachmentPath: attachmentPath,
            barcodePayload: "https://luma.com/check-in/evt-oQFgiXtb73y8yCh?pk=g-TZIx7lJbtxy4uaO",
            barcodeSymbology: BarcodeSymbology.qr.rawValue,
            eventTitle: eventTitle,
            eventDate: nil,
            startTimeText: startTimeText,
            venue: venue,
            seat: seat,
            reference: reference
        )
        store.context.insert(row)
        try store.context.save()
        return row.toDTO()
    }

    /// A read as the `.pkpass` route produces one, file and all.
    private func makePassRead() throws -> TaskTicketRead {
        let data = WalletPassImportTests.makeZip(
            name: "pass.json",
            payload: Data(WalletPassImportTests.lumaPassJSON.utf8),
            deflate: true
        )
        let pass = try XCTUnwrap(WalletPassImport.read(data: data))
        let path = try TicketStorage.taskTickets.save(passData: data)
        createdPaths.append(path)
        let barcode = pass.barcode
        return TaskTicketRead(
            attachmentPath: path,
            barcodePayload: barcode?.payload ?? "",
            barcodeSymbology: barcode?.symbology.rawValue ?? "",
            extracted: pass.extracted(),
            degradeMessage: nil,
            sourceHash: SyncHash.hex(data)
        )
    }
}
