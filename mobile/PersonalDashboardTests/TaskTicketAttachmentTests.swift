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
        section: String? = "122",
        row: String? = "14",
        position: Int = 0
    ) throws -> TaskTicket {
        // A rendered barcode is a legitimate stand-in for a photographed ticket
        // and keeps the fixture free of a checked-in binary.
        let image = try XCTUnwrap(
            BarcodeService.render(payload: payload, symbology: symbology),
            "could not render a fixture barcode"
        )
        let jpeg = try XCTUnwrap(image.jpegDataCompat(quality: 0.9))
        let relativePath = try TicketStorage.taskTickets.saveCompressedJpeg(jpeg)
        createdPaths.append(relativePath)

        var meta = TicketMeta()
        meta.eventType = "Concert"
        meta.section = section
        meta.row = row

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
            gate: "3",
            reference: "ORD-99213",
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

        XCTAssertEqual(counts[withTickets.clientUUID], 2)
        XCTAssertNil(counts[without.clientUUID], "a task with no tickets should not appear")
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
