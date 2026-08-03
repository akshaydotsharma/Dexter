import XCTest
import SwiftData
import CoreGraphics
import CoreImage
@testable import PersonalDashboard

/// Task ticket attachments (#399).
///
/// Four things here can break silently and would not be caught by a build:
///
/// 1. **The barcode round trip.** The whole feature rests on the claim that a
///    payload decoded off a ticket can be re-rendered into something a scanner
///    reads back as the same string. If that is wrong the card is decorative and
///    someone finds out at a turnstile. It is also perfectly deterministic, so
///    there is no excuse for not asserting it.
/// 2. **The archive round trip.** A new model is easy to add to the payload and
///    forget in the exporter, the importer, or the attachment resolver. The
///    failure looks like "my tickets vanished on restore".
/// 3. **The delete cascade.** Orphaned rows and leaked files after a task goes.
/// 4. **Sync registration.** The mapper has to know the entity or the rows never
///    leave the device.
///
/// The LLM extraction step is deliberately not covered: it is one network call
/// whose output every field of the UI treats as correctable, and stubbing
/// `AnthropicClient` to assert on a prompt would test the mock. Rows are built
/// directly instead, which is what the archive and cascade paths actually see.
///
/// Runs against an isolated in-memory store. File bytes necessarily go through
/// the real `TicketStorage.taskTickets`, which writes into the test host's
/// Documents container, so every test cleans up the paths it created.
@MainActor
final class TaskTicketAttachmentTests: XCTestCase {

    private var store: SwiftDataStore!
    /// Relative paths written during the test, removed in tearDown.
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

    // MARK: - Fixtures

    private func insertTodo(title: String = "Coldplay at the National Stadium") -> LocalTodo {
        let todo = LocalTodo(title: title)
        store.context.insert(todo)
        try? store.context.save()
        return todo
    }

    /// Attach a ticket the way the extractor would, minus the network call: write
    /// real bytes through the real storage, then insert the row pointing at them.
    @discardableResult
    private func attachTicket(
        to todo: LocalTodo,
        payload: String = "DEXTER-TEST-PAYLOAD-1",
        symbology: BarcodeSymbology = .qr,
        eventTitle: String = "Coldplay",
        venue: String = "National Stadium",
        seat: String = "8",
        gate: String = "3",
        reference: String = "ORD-99213",
        section: String? = "122",
        row: String? = "14",
        presentedAtEntry: Bool? = nil,
        showInWallet: Bool? = nil,
        position: Int = 0
    ) throws -> TaskTicket {
        // A rendered barcode is a legitimate stand-in for a photographed ticket
        // and keeps the fixture free of a checked-in binary. An empty `payload`
        // means "a document with no barcode in it", so the file still needs real
        // bytes — only the stored payload is blank.
        let image = try XCTUnwrap(
            BarcodeService.render(
                payload: payload.isEmpty ? "FIXTURE-NO-BARCODE" : payload,
                symbology: symbology
            ),
            "could not render a fixture barcode"
        )
        let jpeg = try XCTUnwrap(image.jpegDataCompat(quality: 0.9))
        let relativePath = try TicketStorage.taskTickets.saveCompressedJpeg(jpeg)
        createdPaths.append(relativePath)

        var meta = TicketMeta()
        meta.eventType = "Concert"
        meta.section = section
        meta.row = row
        // Left nil by default so the fixture keeps reproducing a row written
        // before the field existed (#405).
        meta.presentedAtEntry = presentedAtEntry
        meta.showInWallet = showInWallet

        let ticket = LocalTaskTicket(
            todoClientUUID: todo.clientUUID,
            attachmentPath: relativePath,
            barcodePayload: payload,
            barcodeSymbology: symbology.rawValue,
            eventTitle: eventTitle,
            eventDate: Calendar(identifier: .gregorian)
                .startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)),
            startTimeText: "20:00",
            venue: venue,
            seat: seat,
            gate: gate,
            reference: reference,
            ticketMetaJSON: meta.encodedString(),
            position: position
        )
        store.context.insert(ticket)
        try store.context.save()
        return ticket.toDTO()
    }

    // MARK: - Barcode round trip

    /// Can Vision decode a barcode at all in this environment?
    ///
    /// It cannot in the iOS Simulator: `VNDetectBarcodesRequest` fails there with
    /// "Could not create inference context" for every input, including the
    /// generator's own un-upscaled output. That is an environment limitation, not
    /// a property of what we render, so the round-trip test below distinguishes
    /// the two rather than reporting a green it has not earned or a red it cannot
    /// fix.
    ///
    /// The probe deliberately uses `CIQRCodeGenerator` directly rather than
    /// `BarcodeService.render`, so a bug in our upscale step cannot make the probe
    /// skip the very test that would catch it.
    private func visionCanDecodeBarcodes() -> Bool {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return false }
        filter.setValue("PROBE".data(using: .utf8), forKey: "inputMessage")
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else {
            return false
        }
        return BarcodeService.decode(image: PlatformImage(cgImage: cg))?.payload == "PROBE"
    }

    /// The claim the feature rests on: re-rendering a decoded payload yields an
    /// image that decodes back to the identical string.
    ///
    /// Covers the three symbologies the app can regenerate and that a real ticket
    /// actually uses. Code128 is excluded on purpose: it cannot encode the
    /// lowercase and control characters a QR payload routinely carries, so a
    /// round-trip assertion on arbitrary text would be testing the wrong thing.
    ///
    /// Skipped where Vision cannot decode anything (the Simulator). On those runs
    /// the guarantee is carried by device QA: scanning the card with a second
    /// phone's camera and comparing against the original ticket.
    func testRenderedBarcodeDecodesBackToTheSamePayload() throws {
        try XCTSkipUnless(
            visionCanDecodeBarcodes(),
            "Vision cannot create a barcode inference context here (expected in the Simulator); run this on a device"
        )

        let cases: [(BarcodeSymbology, String)] = [
            (.qr, "https://tickets.example.com/order/99213?seat=122-14-8"),
            (.aztec, "DEXTER-AZTEC-PAYLOAD-0042"),
            (.pdf417, "M1SHARMA/AKSHAY   EABC123 SINLHRSQ 0322 195Y012A0044 100")
        ]

        for (symbology, payload) in cases {
            let image = try XCTUnwrap(
                BarcodeService.render(payload: payload, symbology: symbology),
                "\(symbology.rawValue): render returned nil"
            )
            let decoded = try XCTUnwrap(
                BarcodeService.decode(image: image),
                "\(symbology.rawValue): a freshly rendered code did not decode"
            )
            XCTAssertEqual(
                decoded.payload, payload,
                "\(symbology.rawValue): round trip changed the payload"
            )
            XCTAssertEqual(
                decoded.symbology, symbology,
                "\(symbology.rawValue): round trip changed the symbology"
            )
        }
    }

    /// A symbology we cannot regenerate must return nil rather than a wrong image,
    /// because the card's fallback (crop the original) depends on that nil.
    func testUnsupportedSymbologyRendersNothing() {
        XCTAssertNil(BarcodeService.render(payload: "12345", symbology: .other))
    }

    // MARK: - Write path

    func testAttachingTicketStoresRowAndFile() throws {
        let todo = insertTodo()
        let service = TaskTicketService(store: store)
        let attached = try attachTicket(to: todo)

        let listed = try service.list(todoId: todo.clientUUID)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, attached.id)
        XCTAssertEqual(listed.first?.position, 0)

        // Its own namespace, not alongside itinerary tickets or receipts.
        XCTAssertTrue(
            attached.attachmentPath.hasPrefix("task-tickets/"),
            "expected a task-tickets/ path, got \(attached.attachmentPath)"
        )
        XCTAssertNotNil(service.fileURL(for: attached), "bytes did not land on disk")

        // The extras that live in JSON rather than columns survive the round trip.
        XCTAssertEqual(attached.ticketMeta?.section, "122")
        XCTAssertEqual(attached.ticketMeta?.row, "14")
        XCTAssertEqual(attached.ticketMeta?.eventType, "Concert")
    }

    /// A second ticket appends rather than replacing: one task, two seats.
    func testTaskHoldsMoreThanOneTicket() throws {
        let todo = insertTodo()
        let service = TaskTicketService(store: store)
        try attachTicket(to: todo, payload: "SEAT-8", seat: "8", position: 0)
        try attachTicket(to: todo, payload: "SEAT-9", seat: "9", position: 1)

        let listed = try service.list(todoId: todo.clientUUID)
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed.map(\.position), [0, 1])
        XCTAssertEqual(listed.map(\.seat), ["8", "9"])
    }

    func testCountsReportPerTask() throws {
        let withTickets = insertTodo(title: "Match")
        let without = insertTodo(title: "Buy milk")
        try attachTicket(to: withTickets, payload: "A")
        try attachTicket(to: withTickets, payload: "B", position: 1)

        let counts = try TaskTicketService(store: store)
            .counts(todoIds: [withTickets.clientUUID, without.clientUUID])

        XCTAssertEqual(counts[withTickets.clientUUID]?.count, 2)
        XCTAssertNil(counts[without.clientUUID], "a task with no tickets should not appear")
    }

    /// The list chip says TICKET off the back of this, so a plain document must not
    /// report a pass it does not carry (#402).
    func testCountsReportWhetherAnythingIsAPass() throws {
        let scannable = insertTodo(title: "Concert")
        let paperwork = insertTodo(title: "Visa forms")
        try attachTicket(to: scannable, payload: "SCAN-ME")
        try attachTicket(to: paperwork, payload: "")

        let counts = try TaskTicketService(store: store)
            .counts(todoIds: [scannable.clientUUID, paperwork.clientUUID])

        XCTAssertEqual(counts[scannable.clientUUID], .init(count: 1, holdsAPass: true))
        XCTAssertEqual(
            counts[paperwork.clientUUID], .init(count: 1, holdsAPass: false),
            "a document with no barcode must not read as a ticket"
        )
    }

    /// One pass among several attachments is enough to call the task a ticket.
    func testOneBarcodeAmongSeveralAttachmentsCountsAsScannable() throws {
        let todo = insertTodo(title: "Trip paperwork")
        try attachTicket(to: todo, payload: "")
        try attachTicket(to: todo, payload: "BOARDING-PASS", position: 1)

        let counts = try TaskTicketService(store: store).counts(todoIds: [todo.clientUUID])

        XCTAssertEqual(counts[todo.clientUUID], .init(count: 2, holdsAPass: true))
    }

    /// The bug #437 closed: the summary counted decoded payloads, so the rental
    /// voucher flew a TICKET pill on its Tasks row and a ticket glyph in Today while
    /// the Wallet had already stopped calling it a pass. Three surfaces, one rule.
    func testManageBookingLinkIsNotATicketOnTheRowEither() throws {
        let rental = insertTodo(title: "Pickup Car")
        let concert = insertTodo(title: "Concert")
        try attachTicket(
            to: rental,
            payload: "sixt.com/account/#/manage-my-booking-info?metadata=eyJhIjoiYiJ9",
            presentedAtEntry: true
        )
        try attachTicket(to: concert, payload: "SCAN-ME")

        let counts = try TaskTicketService(store: store)
            .counts(todoIds: [rental.clientUUID, concert.clientUUID])

        XCTAssertEqual(
            counts[rental.clientUUID], .init(count: 1, holdsAPass: false),
            "a QR that opens a booking page is not a ticket on any surface"
        )
        XCTAssertEqual(counts[concert.clientUUID], .init(count: 1, holdsAPass: true))
    }

    /// The summary and the Wallet must answer the same question, since disagreeing
    /// about it is the whole history of this feature (#402, #405, #414, #435, #437).
    func testTheSummaryAgreesWithTheWallet() throws {
        let cases: [(String, String, Bool?)] = [
            ("opaque token", "S3FA7901F97B3", nil),
            ("check-in link", "https://luma.com/check-in/evt-abc?pk=g-1", nil),
            ("manage link", "sixt.com/account/#/manage-my-booking-info?m=1", true),
            ("no barcode, judged a pass", "", true),
            ("no barcode, unjudged", "", nil)
        ]

        for (label, payload, judged) in cases {
            let todo = insertTodo(title: label)
            try attachTicket(to: todo, payload: payload, presentedAtEntry: judged)

            let summary = try TaskTicketService(store: store)
                .counts(todoIds: [todo.clientUUID])[todo.clientUUID]
            let inWallet = !(try walletEntries(for: todo).isEmpty)

            XCTAssertEqual(
                summary?.holdsAPass, inWallet,
                "\(label): the row pill and the Wallet disagree"
            )
        }
    }

    // MARK: - What earns a place in the Wallet (#405)

    /// The picker takes any document (#400), so being attached to a task stopped
    /// meaning "is a pass". These four cases are the whole rule, and they are pure
    /// logic over a stored JSON blob — nothing about them needs a device, so there
    /// is no reason for the Wallet's contents to be something we find out by
    /// looking.

    /// Every card the wallet would build from one task's attachments.
    private func walletEntries(for todo: LocalTodo) throws -> [WalletEntry] {
        let tickets = try store.context.fetch(
            FetchDescriptor<LocalTaskTicket>(predicate: #Predicate { $0.deletedAt == nil })
        )
        return WalletEntry.build(
            cards: [],
            itineraryItems: [],
            trips: [],
            taskTickets: tickets.filter { $0.todoClientUUID == todo.clientUUID },
            todos: [todo]
        )
    }

    func testScannableAttachmentBecomesAWalletCard() throws {
        let todo = insertTodo(title: "Coldplay")
        try attachTicket(to: todo, payload: "SCAN-ME")

        XCTAssertEqual(try walletEntries(for: todo).count, 1)
    }

    /// The bug: a Chope confirmation photographed into a task showed up in the
    /// Wallet beside a boarding pass. Nobody scans a table reservation.
    func testBookingRecordStaysOffTheWallet() throws {
        let todo = insertTodo(title: "Mr. Bucket Chocolaterie")
        try attachTicket(to: todo, payload: "", presentedAtEntry: false)

        XCTAssertTrue(
            try walletEntries(for: todo).isEmpty,
            "a booking you are looked up for by name is not a card you present"
        )
    }

    /// The bug #435 opened, reported off the real store: a Sixt rental voucher
    /// carries a QR that opens the company's manage-my-booking page. It is a real
    /// decoded barcode, so "something scannable" admitted it, and the extractor had
    /// judged it presented-at-entry as well — both arms said yes to a document that
    /// admits nobody.
    func testManageBookingLinkIsNotAPass() throws {
        let todo = insertTodo(title: "Pickup Car")
        try attachTicket(
            to: todo,
            payload: "sixt.com/account/#/manage-my-booking-info?metadata=eyJlbWFpbCI6IngifQ",
            presentedAtEntry: true
        )

        XCTAssertTrue(
            try walletEntries(for: todo).isEmpty,
            "a QR that opens a booking-management page is a link, not a credential"
        )
    }

    /// The card the blunt version of that fix would have thrown away. Luma prints a
    /// check-in URL as its entry QR, so a rule of "reject web addresses" would drop
    /// a pass that is genuinely scanned at the door — and this row has no seat, no
    /// gate and no reference to fall back on.
    func testCheckInLinkIsAPass() throws {
        let todo = insertTodo(title: "Vibe Coders SG")
        try attachTicket(
            to: todo,
            payload: "https://luma.com/check-in/evt-oQFgiXtb73y8yCh?pk=g-TZIx7lJbtxy4uaO",
            seat: "",
            gate: "",
            reference: "",
            section: nil,
            row: nil
        )

        XCTAssertEqual(try walletEntries(for: todo).count, 1)
    }

    /// An IATA boarding pass splits on a slash the way a URL does, and the host test
    /// is the only thing standing between it and being read as a self-service link.
    func testBoardingPassStringIsACredential() {
        XCTAssertEqual(
            BarcodePurpose.classify("M1SHARMA/AKSHAY        H9UQJJ IXCPNQ6E 0681 183Y005C0014 152>5181"),
            .credential
        )
        XCTAssertEqual(BarcodePurpose.classify("S3FA7901F97B3"), .credential)
        XCTAssertEqual(BarcodePurpose.classify("   "), BarcodePurpose.none)
        XCTAssertEqual(
            BarcodePurpose.classify("https://vendor.example.com/r/9f2a"),
            .unknownLink,
            "a link that claims nothing decides nothing on its own"
        )
    }

    /// A link that says neither thing falls back to the judgement, so it behaves
    /// exactly as an unscannable document does rather than being admitted or
    /// dropped on the strength of being a URL.
    func testAmbiguousLinkFallsBackToTheJudgement() throws {
        let unjudged = insertTodo(title: "Unjudged")
        try attachTicket(to: unjudged, payload: "https://vendor.example.com/r/9f2a")
        XCTAssertTrue(try walletEntries(for: unjudged).isEmpty)

        let judged = insertTodo(title: "Judged a pass")
        try attachTicket(
            to: judged,
            payload: "https://vendor.example.com/r/9f2a",
            presentedAtEntry: true
        )
        XCTAssertEqual(try walletEntries(for: judged).count, 1)
    }

    /// The escape hatch has to survive the new arm, because the arm is absolute:
    /// #435 drops a self-service link whatever else the row prints, so the person's
    /// own answer is the only way back in.
    func testOverrideStillBeatsASelfServiceLink() throws {
        let todo = insertTodo(title: "Rental I want on the shelf")
        try attachTicket(
            to: todo,
            payload: "sixt.com/account/#/manage-my-booking-info?metadata=x",
            presentedAtEntry: true,
            showInWallet: true
        )

        XCTAssertEqual(try walletEntries(for: todo).count, 1)
    }

    /// The case a barcode-only rule would get wrong: a real event ticket that
    /// prints nothing scannable at all. It still prints a seat and a reference,
    /// which is what it hands over at the door.
    func testUnscannableTicketPresentedAtEntryStillBecomesAWalletCard() throws {
        let todo = insertTodo(title: "Open-air cinema")
        try attachTicket(to: todo, payload: "", presentedAtEntry: true)

        XCTAssertEqual(try walletEntries(for: todo).count, 1)
    }

    /// The bug #414 opened: a padel court booking came back judged a pass, with no
    /// barcode, no reference, no seat and no gate. The judgement alone put a card in
    /// the Wallet that could not be shown to anyone.
    func testCourtBookingWithNothingToPresentStaysOffTheWallet() throws {
        let todo = insertTodo(title: "PADEL")
        try attachTicket(
            to: todo,
            payload: "",
            eventTitle: "PADEL",
            venue: "The Racket Co. - Tanjong Pagar",
            seat: "",
            gate: "",
            reference: "",
            section: nil,
            row: nil,
            presentedAtEntry: true
        )

        XCTAssertTrue(
            try walletEntries(for: todo).isEmpty,
            "a judgement with nothing behind it is an opinion, not a pass"
        )
    }

    /// The other side of that rule: one printed credential is enough, because that
    /// is the thing the person actually holds up.
    func testJudgedPassWithOnlyAReferenceStillBecomesAWalletCard() throws {
        let todo = insertTodo(title: "Museum entry")
        try attachTicket(
            to: todo,
            payload: "",
            seat: "",
            gate: "",
            reference: "ADM-4471",
            section: nil,
            row: nil,
            presentedAtEntry: true
        )

        XCTAssertEqual(try walletEntries(for: todo).count, 1)
    }

    /// The person's answer beats the rule, including over a decoded barcode: the
    /// reason to force a scannable document out is that its code admits nobody.
    func testManualOverrideForcesAScannableAttachmentOut() throws {
        let todo = insertTodo(title: "Menu with a QR on it")
        try attachTicket(to: todo, payload: "SCAN-ME", showInWallet: false)

        XCTAssertTrue(try walletEntries(for: todo).isEmpty)
    }

    /// And in the other direction, which is what makes the switch worth having on a
    /// row the rule has just excluded.
    func testManualOverrideForcesAnUnscannableAttachmentIn() throws {
        let todo = insertTodo(title: "PADEL")
        try attachTicket(
            to: todo,
            payload: "",
            seat: "",
            gate: "",
            reference: "",
            section: nil,
            row: nil,
            presentedAtEntry: false,
            showInWallet: true
        )

        XCTAssertEqual(try walletEntries(for: todo).count, 1)
    }

    /// The override has to survive an edit of the other fields. The detail sheet
    /// rebuilds `TicketMeta` from the copy it was handed when it opened, so a flip
    /// written after that copy was taken is exactly what a later Save could undo.
    func testManualOverrideSurvivesAFieldEdit() throws {
        let todo = insertTodo(title: "Menu with a QR on it")
        let service = TaskTicketService(store: store)
        let attached = try attachTicket(to: todo, payload: "SCAN-ME", showInWallet: false)

        var meta = try XCTUnwrap(attached.ticketMeta)
        meta.section = "B"
        _ = try service.update(id: attached.id, venue: "Somewhere else", meta: meta)

        XCTAssertTrue(try walletEntries(for: todo).isEmpty)
    }

    /// Every row written before the field existed is unjudged. Reading that silence
    /// as "yes" would leave exactly the cards this is meant to remove, so it falls
    /// back to the barcode.
    func testUnjudgedAttachmentFallsBackToTheBarcode() throws {
        let scannable = insertTodo(title: "Arsenal v Chelsea")
        let paperwork = insertTodo(title: "Visa forms")
        try attachTicket(to: scannable, payload: "OLD-ROW-WITH-QR")
        try attachTicket(to: paperwork, payload: "")

        XCTAssertEqual(try walletEntries(for: scannable).count, 1)
        XCTAssertTrue(try walletEntries(for: paperwork).isEmpty)
    }

    /// A scannable code outranks the judgement: whatever the document is for, you
    /// are about to hold it under a reader.
    func testScannableBookingIsAWalletCardDespiteTheJudgement() throws {
        let todo = insertTodo(title: "Museum entry")
        try attachTicket(to: todo, payload: "QR-AT-THE-DOOR", presentedAtEntry: false)

        XCTAssertEqual(try walletEntries(for: todo).count, 1)
    }

    /// The field is three-valued on the wire. "no" and "not answered" must not
    /// collapse into each other — one is trusted, the other falls back.
    func testPresentedAtEntryReadsAsThreeValued() {
        func decode(_ raw: String?) -> Bool? {
            var input: [String: AnthropicJSONValue] = [:]
            if let raw { input["presented_at_entry"] = .string(raw) }
            return ExtractedTaskTicket(input: input).presentedAtEntry
        }

        XCTAssertEqual(decode("yes"), true)
        XCTAssertEqual(decode("YES"), true)
        XCTAssertEqual(decode("true"), true)
        XCTAssertEqual(decode("no"), false)
        XCTAssertEqual(decode(" No "), false)
        XCTAssertNil(decode(nil), "an omitted field means nobody judged it")
        XCTAssertNil(decode(""), "so does a blank one")
        XCTAssertNil(decode("maybe"), "and so does an answer we do not recognise")
    }

    /// The judgement has to survive the read → attach hop, or the Wallet gate sees
    /// nothing regardless of what the model said.
    func testJudgementSurvivesIntoTheStoredRow() throws {
        let todo = insertTodo(title: "Dinner at Odette")
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/x.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: ExtractedTaskTicket(eventTitle: "Odette", presentedAtEntry: false),
            degradeMessage: nil
        )
        let stored = try TaskTicketService(store: store)
            .attach(read.ticket(todoId: todo.clientUUID), todoId: todo.clientUUID)

        let row = try XCTUnwrap(try store.context.fetch(
            FetchDescriptor<LocalTaskTicket>(predicate: #Predicate { $0.clientUUID == stored })
        ).first)
        XCTAssertEqual(row.ticketMeta?.presentedAtEntry, false)
        XCTAssertFalse(row.belongsInWallet)
    }

    // MARK: - Editing

    /// Every extracted field is correctable — that is what makes an imperfect
    /// extraction acceptable, so it needs to actually persist.
    func testUpdateOverwritesFieldsAndClearsTheDate() throws {
        let todo = insertTodo()
        let service = TaskTicketService(store: store)
        let attached = try attachTicket(to: todo)

        var meta = attached.ticketMeta ?? TicketMeta()
        meta.section = "A"
        meta.row = nil

        let updated = try XCTUnwrap(try service.update(
            id: attached.id,
            eventTitle: "Coldplay · Music of the Spheres",
            eventDate: .some(nil),
            startTimeText: "Doors 19:00",
            venue: "Singapore National Stadium",
            seat: "12",
            gate: "5",
            reference: "ORD-00001",
            meta: meta
        ))

        XCTAssertEqual(updated.eventTitle, "Coldplay · Music of the Spheres")
        XCTAssertNil(updated.eventDate, "an explicit nil date should clear, not be ignored")
        XCTAssertEqual(updated.startTimeText, "Doors 19:00")
        XCTAssertEqual(updated.venue, "Singapore National Stadium")
        XCTAssertEqual(updated.seat, "12")
        XCTAssertEqual(updated.gate, "5")
        XCTAssertEqual(updated.reference, "ORD-00001")
        XCTAssertEqual(updated.ticketMeta?.section, "A")
        XCTAssertNil(updated.ticketMeta?.row)

        // The barcode is not user-editable and must be untouched by an edit.
        XCTAssertEqual(updated.barcodePayload, attached.barcodePayload)
        XCTAssertEqual(updated.attachmentPath, attached.attachmentPath)
    }

    /// A nil argument leaves the stored value alone, matching `TodoUpdateRequest`.
    func testUpdateLeavesOmittedFieldsUntouched() throws {
        let todo = insertTodo()
        let service = TaskTicketService(store: store)
        let attached = try attachTicket(to: todo)

        let updated = try XCTUnwrap(try service.update(id: attached.id, seat: "99"))

        XCTAssertEqual(updated.seat, "99")
        XCTAssertEqual(updated.eventTitle, attached.eventTitle)
        XCTAssertEqual(updated.venue, attached.venue)
        XCTAssertEqual(updated.eventDate, attached.eventDate)
    }

    // MARK: - Delete + cascade

    func testDeletingTicketDetachesRowAndRemovesFile() throws {
        let todo = insertTodo()
        let service = TaskTicketService(store: store)
        let attached = try attachTicket(to: todo)
        let url = try XCTUnwrap(service.fileURL(for: attached))

        try service.delete(attached)

        XCTAssertTrue(try service.list(todoId: todo.clientUUID).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "a detached ticket should not leak its file"
        )
    }

    func testDeletingTaskTakesItsTicketsWithIt() async throws {
        let todo = insertTodo()
        let service = TaskTicketService(store: store)
        let attached = try attachTicket(to: todo)
        let url = try XCTUnwrap(service.fileURL(for: attached))

        try await TodoService(store: store).delete(todo.toDTO())

        XCTAssertTrue(
            try service.list(todoId: todo.clientUUID).isEmpty,
            "ticket rows outlived the task that owned them"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Archive round trip

    /// The regression that matters most: a new model reaching the payload but not
    /// the exporter's attachment resolver ships an archive whose rows point at
    /// files it never packed, and the restore looks like data loss.
    func testTicketsSurviveExportAndImportIntoAFreshStore() async throws {
        // ---- Device A: a task with two tickets. ----
        let todo = insertTodo(title: "Coldplay")
        let service = TaskTicketService(store: store)
        let first = try attachTicket(to: todo, payload: "FIRST-SEAT", seat: "8", position: 0)
        let second = try attachTicket(to: todo, payload: "SECOND-SEAT", seat: "9", position: 1)
        let originalBytes = try Data(contentsOf: try XCTUnwrap(service.fileURL(for: first)))

        let archiveURL = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        // The zip must carry the ticket bytes, not just the rows.
        let entries = try MiniZip.read(from: archiveURL)
        let entryNames = Set(entries.map(\.name))
        XCTAssertTrue(
            entryNames.contains(first.attachmentPath),
            "archive is missing \(first.attachmentPath); entries: \(entryNames.sorted())"
        )
        XCTAssertTrue(entryNames.contains(second.attachmentPath))

        // ---- Device B: a fresh store, with the files removed from disk so the
        // restore has to come from the archive rather than from what is already
        // there. ----
        for path in [first.attachmentPath, second.attachmentPath] {
            try? TicketStorage.taskTickets.delete(relativePath: path)
        }
        let freshStore = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let importer = DataImportService(modelContext: freshStore.context)
        let preview = try importer.preview(url: archiveURL)

        let ticketCounts = try XCTUnwrap(preview.counts(for: .skipExisting)[.taskTickets])
        XCTAssertEqual(ticketCounts.total, 2, "importer did not see the ticket rows")
        XCTAssertEqual(ticketCounts.new, 2)

        try importer.commit(preview: preview, mode: .skipExisting)

        // ---- Rows and bytes both restored, at full fidelity. ----
        let restoredService = TaskTicketService(store: freshStore)
        let restored = try restoredService.list(todoId: todo.clientUUID)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.map(\.position), [0, 1])

        let restoredFirst = try XCTUnwrap(restored.first)
        XCTAssertEqual(restoredFirst.attachmentPath, first.attachmentPath)
        XCTAssertEqual(restoredFirst.barcodePayload, "FIRST-SEAT")
        XCTAssertEqual(restoredFirst.barcodeSymbology, BarcodeSymbology.qr.rawValue)
        XCTAssertEqual(restoredFirst.eventTitle, first.eventTitle)
        XCTAssertEqual(restoredFirst.eventDate, first.eventDate)
        // The printed time is the field most at risk of being "helpfully"
        // reformatted somewhere in the chain.
        XCTAssertEqual(restoredFirst.startTimeText, "20:00")
        XCTAssertEqual(restoredFirst.venue, first.venue)
        XCTAssertEqual(restoredFirst.seat, "8")
        XCTAssertEqual(restoredFirst.gate, first.gate)
        XCTAssertEqual(restoredFirst.reference, first.reference)
        XCTAssertEqual(restoredFirst.ticketMeta?.section, "122")

        let restoredURL = try XCTUnwrap(restoredService.fileURL(for: restoredFirst))
        XCTAssertEqual(
            try Data(contentsOf: restoredURL), originalBytes,
            "restored ticket bytes differ from what was exported"
        )
    }

    /// Re-importing the same archive must not duplicate tickets.
    func testReimportingTheSameArchiveIsANoOp() async throws {
        let todo = insertTodo()
        let service = TaskTicketService(store: store)
        try attachTicket(to: todo)

        let archiveURL = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let importer = DataImportService(modelContext: store.context)
        let preview = try importer.preview(url: archiveURL)
        XCTAssertEqual(preview.counts(for: .skipExisting)[.taskTickets]?.new, 0)
        try importer.commit(preview: preview, mode: .skipExisting)

        XCTAssertEqual(try service.list(todoId: todo.clientUUID).count, 1)
    }

    /// A row whose file the archive did not carry still restores, because it is a
    /// real ticket sitting on the user's other device. Dropping it would lose the
    /// barcode and the details as well as the scan.
    func testRowWithoutBytesStillRestoresAndReportsNoFile() throws {
        let todoID = UUID()
        let orphanPath = "task-tickets/\(UUID().uuidString.lowercased()).jpg"
        let dto = DataArchive.TaskTicketDTO(
            clientUUID: UUID(),
            todoClientUUID: todoID,
            attachmentPath: orphanPath,
            barcodePayload: "STILL-SCANNABLE",
            barcodeSymbology: BarcodeSymbology.qr.rawValue,
            eventTitle: "Arsenal v Chelsea",
            eventDate: nil,
            startTimeText: "17:30",
            venue: "Emirates Stadium",
            seat: "42",
            gate: "B",
            reference: "REF-1",
            ticketMetaJSON: "",
            position: 0,
            createdAt: Date(),
            updatedAt: Date(),
            deletedAt: nil
        )
        var payload = DataArchive.Payload.empty
        payload.taskTickets = [dto]
        let manifest = DataArchive.Manifest(
            schemaVersion: DataArchive.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: "test",
            data: payload
        )
        let preview = DataImportService.Preview(
            manifest: manifest,
            archiveURL: URL(fileURLWithPath: "/dev/null"),
            entries: [:],
            counts: [:]
        )

        try DataImportService(modelContext: store.context)
            .commit(preview: preview, mode: .skipExisting)

        let service = TaskTicketService(store: store)
        let restored = try service.list(todoId: todoID)
        XCTAssertEqual(restored.count, 1, "a ticket row with no bytes was dropped")
        // The importer must leave the path empty rather than pointing at bytes it
        // never restored.
        XCTAssertEqual(restored.first?.attachmentPath, "")
        XCTAssertNil(
            service.fileURL(for: try XCTUnwrap(restored.first)),
            "no file should resolve, so the card renders the on-other-device state"
        )
        // The scannable part came across, which is why keeping the row is right.
        XCTAssertEqual(restored.first?.barcodePayload, "STILL-SCANNABLE")
        XCTAssertEqual(restored.first?.startTimeText, "17:30")
    }

    // MARK: - Filling the task's own fields from the ticket

    /// Build a read the way `TaskTicketExtraction.read` would, without the network.
    private func makeRead(
        eventTitle: String? = "COLDPLAY",
        eventDate: String? = "2026-09-12",
        startTimeText: String? = "Show 20:00",
        venue: String? = "National Stadium, Singapore",
        yearWasPrinted: String? = "yes"
    ) -> TaskTicketRead {
        var input: [String: AnthropicJSONValue] = [:]
        if let eventTitle { input["event_title"] = .string(eventTitle) }
        if let eventDate { input["event_date"] = .string(eventDate) }
        if let startTimeText { input["start_time_text"] = .string(startTimeText) }
        if let venue { input["venue"] = .string(venue) }
        if let yearWasPrinted { input["year_was_printed"] = .string(yearWasPrinted) }
        return TaskTicketRead(
            attachmentPath: "task-tickets/x.jpg",
            barcodePayload: "P",
            barcodeSymbology: BarcodeSymbology.qr.rawValue,
            extracted: ExtractedTaskTicket(input: input),
            degradeMessage: nil
        )
    }

    /// The regression behind two rounds of "it asks me for a title first": the
    /// upload has to be able to NAME the task, so these suggestions must survive
    /// even when nothing has been typed.
    func testReadSuggestsTaskFieldsFromTheTicket() throws {
        let read = makeRead()
        XCTAssertEqual(read.suggestedTitle, "COLDPLAY")
        XCTAssertEqual(read.suggestedAddress, "National Stadium, Singapore")

        // The due date is the one place a real `Date` is correct, and it must land
        // on the PRINTED day in the device's own timezone — an off-by-one here puts
        // the reminder on the wrong day, which is the bug #163 / #168 were about.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let due = try XCTUnwrap(read.suggestedDueDate)
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 12, "due date landed on the wrong day")
        XCTAssertEqual(parts.hour, 20, "the printed show time did not carry into the due date")
        XCTAssertEqual(parts.minute, 0)
    }

    /// A ticket with a date but no readable time still yields a usable due date.
    func testSuggestedDueDateWithoutATimeFallsBackToMorning() throws {
        let read = makeRead(startTimeText: nil)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let parts = cal.dateComponents([.day, .hour], from: try XCTUnwrap(read.suggestedDueDate))
        XCTAssertEqual(parts.day, 12)
        XCTAssertEqual(parts.hour, 9)
    }

    /// Nothing readable means no suggestions, and the caller falls back rather than
    /// refusing the upload.
    func testUnreadableTicketSuggestsNothing() {
        let bare = TaskTicketRead(
            attachmentPath: "task-tickets/x.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: nil,
            degradeMessage: "couldn't read"
        )
        XCTAssertNil(bare.suggestedTitle)
        XCTAssertNil(bare.suggestedAddress)
        XCTAssertNil(bare.suggestedDueDate)
    }

    /// A blank field from the model must not become a blank task title.
    func testBlankExtractedFieldsAreTreatedAsAbsent() {
        let read = makeRead(eventTitle: "   ", venue: "")
        XCTAssertNil(read.suggestedTitle)
        XCTAssertNil(read.suggestedAddress)
    }

    // MARK: - Working out a year the ticket never printed

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func localDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// The exact failure seen on a Chope restaurant confirmation: the card printed
    /// "2 AUG · Sun" with no year, and the model — which has no idea what today is —
    /// answered 2025-08-02, a Saturday, putting the task a year in the past. The
    /// printed weekday pins the year, so this is recoverable without asking anyone.
    func testUnprintedYearIsCorrectedFromThePrintedWeekday() {
        let resolved = TaskTicketExtraction.resolveDay(
            iso: "2025-08-02",
            printedWeekday: "Sun",
            yearWasPrinted: false,
            today: localDay(2026, 7, 30)
        )
        XCTAssertEqual(resolved, day(2026, 8, 2), "2 August falls on a Sunday in 2026, not 2025")
    }

    /// With no weekday to check against, the next occurrence is the answer: nobody
    /// attaches a ticket for something that already happened.
    func testUnprintedYearWithoutAWeekdayRollsForward() {
        let resolved = TaskTicketExtraction.resolveDay(
            iso: "2025-08-02",
            printedWeekday: nil,
            yearWasPrinted: false,
            today: localDay(2026, 7, 30)
        )
        XCTAssertEqual(resolved, day(2026, 8, 2))
    }

    /// A date still to come this year is already right and must not be nudged.
    func testUnprintedYearLeavesAnUpcomingDateAlone() {
        let resolved = TaskTicketExtraction.resolveDay(
            iso: "2026-09-12",
            printedWeekday: "Sat",
            yearWasPrinted: false,
            today: localDay(2026, 7, 30)
        )
        XCTAssertEqual(resolved, day(2026, 9, 12))
    }

    /// A printed year is authoritative even when it is in the past: filing a ticket
    /// for something that already happened is a legitimate thing to do, and guessing
    /// past it would be worse than the bug this fixes.
    func testPrintedYearInThePastIsTrusted() {
        let resolved = TaskTicketExtraction.resolveDay(
            iso: "2024-08-02",
            printedWeekday: "Fri",
            yearWasPrinted: true,
            today: localDay(2026, 7, 30)
        )
        XCTAssertEqual(resolved, day(2024, 8, 2))
    }

    /// Something in the weekday slot that is not a day name is ignored rather than
    /// derailing the whole date.
    func testAnUnrecognisedWeekdayIsIgnored() {
        let resolved = TaskTicketExtraction.resolveDay(
            iso: "2025-08-02",
            printedWeekday: "party time",
            yearWasPrinted: false,
            today: localDay(2026, 7, 30)
        )
        XCTAssertEqual(resolved, day(2026, 8, 2))
    }

    /// A printed weekday genuinely selects the year, including one further out: 2
    /// August is a Thursday in 2029 and in no nearer year.
    func testAPrintedWeekdayCanSelectALaterYear() {
        let resolved = TaskTicketExtraction.resolveDay(
            iso: "2025-08-02",
            printedWeekday: "Thu",
            yearWasPrinted: false,
            today: localDay(2026, 7, 30)
        )
        XCTAssertEqual(resolved, day(2029, 8, 2))
    }

    /// 29 February exists only in a leap year, so the candidate scan has to skip the
    /// years it does not. This only works because the month and day are read off the
    /// string: a `DateFormatter` silently turns 2025-02-29 into 1 March, and the
    /// answer would then be a date the ticket never mentioned.
    func testLeapDayResolvesToALeapYear() {
        let resolved = TaskTicketExtraction.resolveDay(
            iso: "2025-02-29",
            printedWeekday: nil,
            yearWasPrinted: false,
            today: localDay(2026, 7, 30)
        )
        XCTAssertEqual(resolved, day(2028, 2, 29))
    }

    func testWeekdayNamesParseInTheFormsTicketsPrintThem() {
        XCTAssertEqual(TaskTicketExtraction.weekdayIndex("Sun"), 1)
        XCTAssertEqual(TaskTicketExtraction.weekdayIndex("sunday"), 1)
        XCTAssertEqual(TaskTicketExtraction.weekdayIndex("SAT"), 7)
        XCTAssertEqual(TaskTicketExtraction.weekdayIndex("Wed."), 4)
        XCTAssertNil(TaskTicketExtraction.weekdayIndex(nil))
        XCTAssertNil(TaskTicketExtraction.weekdayIndex("payday"))
    }

    /// The model states today's date to the extractor, because without it there is
    /// nothing to reason from and it answers from its training cutoff instead.
    func testUserPromptStatesTodaysDate() {
        let prompt = TaskTicketExtraction.userPrompt(
            context: TaskTicketContext(),
            today: localDay(2026, 7, 30)
        )
        XCTAssertTrue(prompt.contains("Thursday, 30 July 2026"), prompt)
    }

    // MARK: - What the task already knows (#408)

    /// The task's own details reach the model. The bug was a Luma check-in page —
    /// a title and a QR code — attached to a task carrying the date, the time and
    /// the address, and a card that came out with three empty fields because the
    /// prompt named only the title and forbade using it.
    func testUserPromptCarriesWhatTheTaskAlreadyKnows() {
        let prompt = TaskTicketExtraction.userPrompt(
            context: TaskTicketContext(
                title: "Vibe Coders SG #2",
                notes: "https://luma.com/4ptmrf91",
                dueDate: localDay(2026, 7, 31).addingTimeInterval(18 * 3600 + 30 * 60),
                address: "Lorong AI @ One-North"
            ),
            today: localDay(2026, 7, 30)
        )
        XCTAssertTrue(prompt.contains("Vibe Coders SG #2"), prompt)
        XCTAssertTrue(prompt.contains("Lorong AI @ One-North"), prompt)
        XCTAssertTrue(prompt.contains("luma.com/4ptmrf91"), prompt)
        XCTAssertTrue(prompt.contains("Friday, 31 July 2026 at 6:30 PM"), prompt)
        // The instruction that keeps the file authoritative. Losing it would let the
        // task's own values overwrite what is printed on the ticket.
        XCTAssertTrue(prompt.contains("always wins"), prompt)
    }

    /// A task with nothing filled in adds nothing to the prompt, rather than a block
    /// of empty labels for the model to read meaning into.
    func testUserPromptOmitsTheBlockWhenTheTaskKnowsNothing() {
        let prompt = TaskTicketExtraction.userPrompt(
            context: TaskTicketContext(),
            today: localDay(2026, 7, 30)
        )
        XCTAssertFalse(prompt.contains("already recorded"), prompt)
    }

    /// The deterministic half of the same fix: whatever the file did not show is
    /// filled from the task, so the card is complete even when the model call fails
    /// outright and there is no extraction at all.
    func testFieldsTheFileDidNotShowComeFromTheTask() throws {
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/x.jpg",
            barcodePayload: "https://luma.com/check-in/evt-oQFgiXtb",
            barcodeSymbology: BarcodeSymbology.qr.rawValue,
            // Title only, which is all the check-in page showed.
            extracted: ExtractedTaskTicket(eventTitle: "Vibe Coders SG #2"),
            degradeMessage: nil,
            context: TaskTicketContext(
                title: "Vibe Coders SG #2 - Securing Vibe Coded Apps",
                dueDate: localDay(2026, 7, 31).addingTimeInterval(18 * 3600 + 30 * 60),
                address: "Lorong AI @ One-North"
            )
        )
        let ticket = read.ticket(todoId: UUID())

        // Read off the file, so it stands.
        XCTAssertEqual(ticket.eventTitle, "Vibe Coders SG #2")
        // Absent from the file, so the task supplies them.
        XCTAssertEqual(ticket.venue, "Lorong AI @ One-North")
        XCTAssertEqual(try XCTUnwrap(ticket.eventDate), localDay(2026, 7, 31))
        XCTAssertEqual(ticket.startTimeText, "6:30 PM")
    }

    /// The rule that makes the fallback safe: a value printed on the file is never
    /// replaced by the task's version of it.
    func testWhatTheFileShowsBeatsWhatTheTaskSays() throws {
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/x.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: ExtractedTaskTicket(
                eventTitle: "COLDPLAY",
                eventDate: "2026-09-12",
                startTimeText: "Show 20:00",
                venue: "National Stadium, Singapore",
                yearWasPrinted: true
            ),
            degradeMessage: nil,
            context: TaskTicketContext(
                title: "Buy merch",
                dueDate: localDay(2026, 1, 1),
                address: "Somewhere else entirely"
            )
        )
        let ticket = read.ticket(todoId: UUID())
        XCTAssertEqual(ticket.eventTitle, "COLDPLAY")
        XCTAssertEqual(ticket.venue, "National Stadium, Singapore")
        XCTAssertEqual(ticket.startTimeText, "Show 20:00")
        XCTAssertEqual(try XCTUnwrap(ticket.eventDate), localDay(2026, 9, 12))
    }

    /// A file that printed its own date does NOT borrow the task's clock time: the
    /// two are about different days, and 6:30 PM on the task's day says nothing about
    /// the hour on the ticket's day.
    func testTheTaskClockTimeIsOnlyUsedWhenItsDayIsToo() {
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/x.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: ExtractedTaskTicket(eventDate: "2026-09-12", yearWasPrinted: true),
            degradeMessage: nil,
            context: TaskTicketContext(
                dueDate: localDay(2026, 7, 31).addingTimeInterval(18 * 3600 + 30 * 60)
            )
        )
        XCTAssertEqual(read.ticket(todoId: UUID()).startTimeText, "")
    }

    /// Filling the card from the task must not turn round and suggest those same
    /// values back to the task's own fields — that direction is for what the FILE
    /// said, and echoing would make an empty read look like a productive one.
    func testTaskContextNeverBecomesASuggestionBackToTheTask() {
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/x.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: nil,
            degradeMessage: "couldn't read",
            context: TaskTicketContext(
                title: "Vibe Coders SG #2",
                dueDate: localDay(2026, 7, 31),
                address: "Lorong AI @ One-North"
            )
        )
        XCTAssertNil(read.suggestedTitle)
        XCTAssertNil(read.suggestedAddress)
        XCTAssertNil(read.suggestedDueDate)
    }

    /// The stored day is local midnight, so every surface that formats it with the
    /// local calendar shows the day printed on the ticket. Calling `startOfDay` on
    /// the UTC value instead lands a day early anywhere west of UTC.
    func testStoredEventDateIsLocalMidnightOfThePrintedDay() throws {
        let ticket = makeRead().ticket(todoId: UUID())
        XCTAssertEqual(try XCTUnwrap(ticket.eventDate), localDay(2026, 9, 12))
    }

    // MARK: - Completing a title the page itself truncated (#413)

    /// Build a ticket through the read, so the test exercises the real derivation.
    private func ticketTitled(_ eventTitle: String) -> TaskTicket {
        TaskTicketRead(
            attachmentPath: "task-tickets/t.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: ExtractedTaskTicket(eventTitle: eventTitle),
            degradeMessage: nil
        ).ticket(todoId: UUID())
    }

    /// The Luma check-in page truncates its own heading, and the extractor is told to
    /// read verbatim, so the stored title is literally "… Securing Vibe Co...". The
    /// task holds the whole name, so the card shows that instead.
    func testATruncatedTitleIsCompletedFromTheTask() {
        XCTAssertEqual(
            ticketTitled("Vibe Coders SG #2 - Securing Vibe Co...")
                .displayTitle(fallback: "Vibe Coders SG #2 - Securing Vibe Coded Apps"),
            "Vibe Coders SG #2 - Securing Vibe Coded Apps"
        )
    }

    /// The single-glyph ellipsis too, since that is what a renderer emits.
    func testTheSingleGlyphEllipsisIsHandled() {
        XCTAssertEqual(
            ticketTitled("Arsenal v Chelsea \u{2014} Premier Leag\u{2026}")
                .displayTitle(fallback: "Arsenal v Chelsea \u{2014} Premier League"),
            "Arsenal v Chelsea \u{2014} Premier League"
        )
    }

    /// It completes a name; it never replaces one.
    func testAFullTitleIsNeverReplacedByTheTask() {
        // Not truncated, so the file's own value stands.
        XCTAssertEqual(
            ticketTitled("COLDPLAY").displayTitle(fallback: "Buy merch before the show"),
            "COLDPLAY"
        )
        // Truncated, but the task is about something else entirely.
        XCTAssertEqual(
            ticketTitled("Some Long Event Na...").displayTitle(fallback: "Pick up the dry cleaning"),
            "Some Long Event Na..."
        )
        // Too short a prefix to trust against any task title.
        XCTAssertEqual(
            ticketTitled("Vibe...").displayTitle(fallback: "Vibe Coders SG #2"),
            "Vibe..."
        )
        // And an empty read still falls back whole, as it always did.
        XCTAssertEqual(ticketTitled("").displayTitle(fallback: "Vibe Coders"), "Vibe Coders")
    }

    // MARK: - The event's own page (#412)

    /// The link is usually in the task's notes, not on the file: the file is a QR code
    /// with no readable address on it. Modelled on the Apple Wallet pass for this same
    /// event, which carries the Luma page as a back field.
    func testEventURLComesFromTheTaskNotesWhenTheFileHasNone() throws {
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/x.jpg",
            barcodePayload: "https://luma.com/check-in/evt-oQFgiXtb73y8yCh?pk=g-TZIx7lJbtxy4uaO",
            barcodeSymbology: BarcodeSymbology.qr.rawValue,
            extracted: ExtractedTaskTicket(eventTitle: "Vibe Coders SG #2"),
            degradeMessage: nil,
            context: TaskTicketContext(
                title: "Vibe Coders SG #2 - Securing Vibe Coded Apps",
                notes: "https://luma.com/4ptmrf91?pk=g-TZIx7lJbtxy4uaO"
            )
        )
        let meta = try XCTUnwrap(read.ticket(todoId: UUID()).ticketMeta)
        XCTAssertEqual(meta.eventURL, "https://luma.com/4ptmrf91?pk=g-TZIx7lJbtxy4uaO")
    }

    /// A URL printed on the document wins over the one in the notes, the same way every
    /// other field does.
    func testAURLReadOffTheFileBeatsTheOneInTheNotes() throws {
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/x.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: ExtractedTaskTicket(eventURL: "https://luma.com/from-the-file"),
            degradeMessage: nil,
            context: TaskTicketContext(notes: "https://luma.com/from-the-notes")
        )
        let meta = try XCTUnwrap(read.ticket(todoId: UUID()).ticketMeta)
        XCTAssertEqual(meta.eventURL, "https://luma.com/from-the-file")
    }

    /// The check-in URL in the barcode is NOT the event page. Promoting it would send
    /// someone to a scan endpoint instead of the page about the event.
    func testTheBarcodeURLIsNeverUsedAsTheEventPage() throws {
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/x.jpg",
            barcodePayload: "https://luma.com/check-in/evt-oQFgiXtb73y8yCh",
            barcodeSymbology: BarcodeSymbology.qr.rawValue,
            extracted: ExtractedTaskTicket(eventTitle: "Vibe Coders"),
            degradeMessage: nil,
            context: TaskTicketContext(title: "Vibe Coders")
        )
        XCTAssertNil(read.ticket(todoId: UUID()).ticketMeta?.eventURL)
    }

    /// Notes are free text, so only real links count. Prose must not become a link.
    func testNotesWithoutALinkYieldNoEventPage() {
        XCTAssertNil(
            TaskTicketContext(notes: "Ask Rahul about the after-party. Bring a laptop.")
                .eventURLFromNotes
        )
        XCTAssertNil(TaskTicketContext(notes: "").eventURLFromNotes)
        // A bare host still counts, and comes back openable rather than as typed.
        XCTAssertEqual(
            TaskTicketContext(notes: "details at luma.com/4ptmrf91").eventURLFromNotes,
            "http://luma.com/4ptmrf91"
        )
    }

    /// The link has to survive the write, or the detail surface can never offer it.
    func testTheEventPageSurvivesIntoTheStoredRow() throws {
        let todo = insertTodo()
        let service = TaskTicketService(store: store)
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/u.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: nil,
            degradeMessage: nil,
            context: TaskTicketContext(notes: "https://luma.com/4ptmrf91")
        )
        try service.attach(read.ticket(todoId: todo.clientUUID), todoId: todo.clientUUID)
        let stored = try XCTUnwrap(try service.list(todoId: todo.clientUUID).first)
        XCTAssertEqual(stored.ticketMeta?.eventURL, "https://luma.com/4ptmrf91")
    }

    // MARK: - Refusing the same file twice (#408)

    /// The failure this closes: the attach gave no visible sign it had worked, so it
    /// was done again, and the task ended up with two identical cards. Byte-identical
    /// files are recognised on the way in, before anything is stored or read.
    func testTheSameFileIsRecognisedAsAlreadyAttached() throws {
        let todo = insertTodo()
        let bytes = Data("the-same-ticket-pdf".utf8)
        let service = TaskTicketService(store: store)

        let read = TaskTicketRead(
            attachmentPath: "task-tickets/first.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: ExtractedTaskTicket(eventTitle: "Vibe Coders SG #2"),
            degradeMessage: nil,
            sourceHash: SyncHash.hex(bytes)
        )
        try service.attach(read.ticket(todoId: todo.clientUUID), todoId: todo.clientUUID)

        let existing = try service.list(todoId: todo.clientUUID)
        let hit = service.duplicate(of: bytes, among: existing)
        XCTAssertEqual(
            hit?.eventTitle, "Vibe Coders SG #2",
            "a second run at the identical file was not recognised"
        )
        XCTAssertNil(
            service.duplicate(of: Data("a-different-ticket".utf8), among: existing),
            "a different file must still be accepted"
        )
    }

    /// The fingerprint has to survive the write, or the check only ever works within
    /// one session.
    func testTheIngestFingerprintIsStoredOnTheRow() throws {
        let todo = insertTodo()
        let bytes = Data("fingerprint-me".utf8)
        let service = TaskTicketService(store: store)
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/f.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: nil,
            degradeMessage: nil,
            sourceHash: SyncHash.hex(bytes)
        )
        try service.attach(read.ticket(todoId: todo.clientUUID), todoId: todo.clientUUID)

        let stored = try XCTUnwrap(try service.list(todoId: todo.clientUUID).first)
        XCTAssertEqual(stored.ticketMeta?.sourceHash, SyncHash.hex(bytes))
    }

    /// The other half, for the two cases the hash cannot see: a row written before
    /// fingerprints existed, and the same ticket arriving as a different file (a
    /// fresh screenshot, a re-download). Both scan to the same payload.
    func testTheSameBarcodeCountsAsAlreadyAttached() throws {
        let todo = insertTodo()
        let service = TaskTicketService(store: store)
        // No sourceHash at all: exactly the shape of the rows already in the store.
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/legacy.jpg",
            barcodePayload: "https://luma.com/check-in/evt-oQFgiXtb",
            barcodeSymbology: BarcodeSymbology.qr.rawValue,
            extracted: ExtractedTaskTicket(eventTitle: "Vibe Coders SG #2"),
            degradeMessage: nil
        )
        try service.attach(read.ticket(todoId: todo.clientUUID), todoId: todo.clientUUID)

        let existing = try service.list(todoId: todo.clientUUID)
        XCTAssertNotNil(
            service.duplicate(
                ofBarcode: "https://luma.com/check-in/evt-oQFgiXtb",
                among: existing
            ),
            "a re-exported copy of an attached ticket was not recognised"
        )
        XCTAssertNil(
            service.duplicate(ofBarcode: "https://luma.com/check-in/evt-somethingelse", among: existing)
        )
    }

    /// "No barcode" is not an identity. Two unscannable documents on one task are a
    /// perfectly ordinary thing to have, so an empty payload must never match.
    func testAnEmptyBarcodeNeverCountsAsADuplicate() throws {
        let todo = insertTodo()
        let service = TaskTicketService(store: store)
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/plain.pdf",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: ExtractedTaskTicket(eventTitle: "Booking confirmation"),
            degradeMessage: nil
        )
        try service.attach(read.ticket(todoId: todo.clientUUID), todoId: todo.clientUUID)

        let existing = try service.list(todoId: todo.clientUUID)
        XCTAssertNil(service.duplicate(ofBarcode: "", among: existing))
        XCTAssertNil(service.duplicate(ofBarcode: "   ", among: existing))
    }

    /// Scoped to the task, not the store: the same pass legitimately lives on two
    /// different tasks (an outbound and a return, a match and the dinner after).
    func testTheSameFileOnADifferentTaskIsNotADuplicate() throws {
        let first = insertTodo(title: "Vibe Coders")
        let second = insertTodo(title: "Dinner after")
        let bytes = Data("shared-file".utf8)
        let service = TaskTicketService(store: store)

        let read = TaskTicketRead(
            attachmentPath: "task-tickets/shared.jpg",
            barcodePayload: "SAME-CODE",
            barcodeSymbology: BarcodeSymbology.qr.rawValue,
            extracted: nil,
            degradeMessage: nil,
            sourceHash: SyncHash.hex(bytes)
        )
        try service.attach(read.ticket(todoId: first.clientUUID), todoId: first.clientUUID)

        // The section only ever checks against the tickets on the task in hand.
        let onSecond = try service.list(todoId: second.clientUUID)
        XCTAssertNil(service.duplicate(of: bytes, among: onSecond))
        XCTAssertNil(service.duplicate(ofBarcode: "SAME-CODE", among: onSecond))
    }

    // MARK: - Attaching without creating a task

    /// A ticket added while composing a new task must be renderable and editable
    /// before anything is written, which is what lets Cancel actually cancel.
    func testProvisionalTicketCarriesEveryExtractedField() throws {
        let read = makeRead()
        let ticket = read.ticket(todoId: UUID())
        XCTAssertEqual(ticket.eventTitle, "COLDPLAY")
        XCTAssertEqual(ticket.venue, "National Stadium, Singapore")
        XCTAssertEqual(ticket.startTimeText, "Show 20:00")
        XCTAssertEqual(ticket.attachmentPath, "task-tickets/x.jpg")
        XCTAssertEqual(ticket.barcodePayload, "P")
        XCTAssertTrue(ticket.hasBarcode)
        XCTAssertFalse(ticket.isBare)
    }

    /// The same values whether it goes straight to disk or waits in the editor: one
    /// derivation, so the card cannot change when it is committed.
    func testAttachingAProvisionalTicketStoresWhatTheCardShowed() throws {
        let todo = insertTodo(title: "Coldplay")
        let provisional = makeRead().ticket(todoId: todo.clientUUID)
        let service = TaskTicketService(store: store)

        _ = try service.attach(provisional, todoId: todo.clientUUID)

        let stored = try XCTUnwrap(try service.list(todoId: todo.clientUUID).first)
        XCTAssertEqual(stored.eventTitle, provisional.eventTitle)
        XCTAssertEqual(stored.eventDate, provisional.eventDate)
        XCTAssertEqual(stored.startTimeText, provisional.startTimeText)
        XCTAssertEqual(stored.venue, provisional.venue)
        XCTAssertEqual(stored.barcodePayload, provisional.barcodePayload)
        XCTAssertEqual(stored.attachmentPath, provisional.attachmentPath)
    }

    /// An edit made to a ticket before the task was saved has to be what gets
    /// written, not the extractor's original reading of it.
    func testEditsMadeBeforeSavingSurviveTheAttach() throws {
        let todo = insertTodo(title: "Dinner")
        var provisional = makeRead().ticket(todoId: todo.clientUUID)
        provisional.eventTitle = "Corrected by hand"
        provisional.seat = "12A"

        let service = TaskTicketService(store: store)
        _ = try service.attach(provisional, todoId: todo.clientUUID)

        let stored = try XCTUnwrap(try service.list(todoId: todo.clientUUID).first)
        XCTAssertEqual(stored.eventTitle, "Corrected by hand")
        XCTAssertEqual(stored.seat, "12A")
    }

    /// Abandoning the editor has to take the stored bytes with it.
    ///
    /// The file is written during the read, before there is any task to hang it on,
    /// so both Cancel and a read that was still in flight when the editor went away
    /// have to clean up or every abandoned upload leaks a file.
    func testDiscardingAnUnattachedTicketRemovesItsFile() throws {
        let todo = insertTodo(title: "Never saved")
        let provisional = makeRead().ticket(todoId: todo.clientUUID)
        // Real bytes on disk at the provisional ticket's path.
        let image = try XCTUnwrap(BarcodeService.render(payload: "ABANDONED", symbology: .qr))
        let jpeg = try XCTUnwrap(image.jpegDataCompat(quality: 0.9))
        let path = try TicketStorage.taskTickets.saveCompressedJpeg(jpeg)
        createdPaths.append(path)
        var stranded = provisional
        stranded.attachmentPath = path
        XCTAssertNotNil(TicketStorage.taskTickets.load(relativePath: path))

        let service = TaskTicketService(store: store)
        service.discardUnattached(stranded)

        XCTAssertNil(
            TicketStorage.taskTickets.load(relativePath: path),
            "an abandoned upload left its file behind"
        )
        // The path-only form is what a cancelled in-flight read has to use, since it
        // never got as far as a ticket.
        service.discardStoredFile(at: path)
        service.discardStoredFile(at: "")
    }

    /// Attaching several holds their order, since they are flushed as a batch when
    /// the task is finally created.
    func testAttachingSeveralPendingTicketsKeepsTheirOrder() throws {
        let todo = insertTodo(title: "Two tickets")
        let service = TaskTicketService(store: store)
        let first = makeRead(eventTitle: "First").ticket(todoId: todo.clientUUID)
        let second = makeRead(eventTitle: "Second").ticket(todoId: todo.clientUUID)

        let ids = service.attachAll([first, second], todoId: todo.clientUUID)

        XCTAssertEqual(ids.count, 2)
        let stored = try service.list(todoId: todo.clientUUID)
        XCTAssertEqual(stored.map(\.eventTitle), ["First", "Second"])
        XCTAssertEqual(stored.map(\.position), [0, 1])
    }

    func testClockTimeParsingHandlesTheFormsTicketsUse() {
        typealias E = TaskTicketExtraction
        XCTAssertEqual(E.parseClockTime("Show 20:00").map { [$0.0, $0.1] }, [20, 0])
        XCTAssertEqual(E.parseClockTime("20:00").map { [$0.0, $0.1] }, [20, 0])
        XCTAssertEqual(E.parseClockTime("Doors 7.30pm").map { [$0.0, $0.1] }, [19, 30])
        XCTAssertEqual(E.parseClockTime("8:05 AM").map { [$0.0, $0.1] }, [8, 5])
        XCTAssertEqual(E.parseClockTime("12:15am").map { [$0.0, $0.1] }, [0, 15])
        XCTAssertNil(E.parseClockTime("Doors open early"))
        XCTAssertNil(E.parseClockTime(nil))
        // Junk that looks numeric but is not a clock time.
        XCTAssertNil(E.parseClockTime("Section 122"))
    }

    // MARK: - Sync registration

    /// Sync carries the rows, so the mapper has to know about the entity.
    /// Registered via `exportedModels`, which is easy to update without adding
    /// the corresponding `map` call.
    func testSyncMapperEmitsTaskTicketRecords() async throws {
        let todo = insertTodo()
        let attached = try attachTicket(to: todo)

        let payload = try DataExportService(modelContext: store.context).buildPayload()
        let records = try SyncRecordMapper.records(from: payload)

        XCTAssertTrue(SyncRecordMapper.syncedEntities.contains("LocalTaskTicket"))
        let ticketRecords = records.filter { $0.entity == "LocalTaskTicket" }
        XCTAssertEqual(ticketRecords.count, 1)
        XCTAssertEqual(ticketRecords.first?.recordID, attached.id.uuidString)
    }
}
