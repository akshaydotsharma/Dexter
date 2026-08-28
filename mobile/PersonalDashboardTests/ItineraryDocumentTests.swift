import XCTest
import SwiftData
@testable import PersonalDashboard

/// Documents attached to a trip stop (#432).
///
/// The stop path reuses the task-attachment stack wholesale, so what needs
/// asserting is not the pipeline — `TaskTicketAttachmentTests` covers the read,
/// the barcode, the duplicate checks and the archive — but the four seams where a
/// second owner could go wrong silently:
///
/// 1. **Owner routing.** A stop's documents must not appear on a task and vice
///    versa. The two live in one table keyed on one column, which is cheap and
///    correct right up until a predicate forgets the discriminator.
/// 2. **The Wallet gate, in both directions.** This change NARROWS what a stop
///    earns a card for, and a gate that is too tight loses a boarding pass while a
///    gate that is too loose is the #405 flood again.
/// 3. **The archive round trip.** `itineraryItemUUID` is a new field on an
///    existing DTO. If the exporter or importer drops it, every restored stop
///    document silently reattaches to a task id that is really a stop's, and the
///    Wallet then skips them all as orphans — the shape of the loss in #366.
/// 4. **The delete cascade.** A stop is hard-deleted, so nothing gets a second
///    chance to notice its documents.
///
/// Runs against an isolated in-memory store; file bytes go through the real
/// `TicketStorage.taskTickets`, so every path written is removed in tearDown.
@MainActor
final class ItineraryDocumentTests: XCTestCase {

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

    // MARK: - Fixtures

    private static let tripStart = Date(timeIntervalSince1970: 1_800_000_000)

    private func insertTrip(name: String = "Italy") -> LocalTrip {
        let trip = LocalTrip(
            name: name,
            startDate: Self.tripStart,
            endDate: Self.tripStart.addingTimeInterval(7 * 86_400)
        )
        store.context.insert(trip)
        try? store.context.save()
        return trip
    }

    @discardableResult
    private func insertStop(
        on trip: LocalTrip,
        title: String = "SQ 356 to Milan",
        kind: ItineraryKind = .transport,
        confirmation: String = "",
        attachmentPath: String = "",
        barcodePayload: String = ""
    ) -> LocalItineraryItem {
        let cal = Calendar(identifier: .gregorian)
        let item = LocalItineraryItem(
            tripUUID: trip.clientUUID,
            dayDate: cal.startOfDay(for: Self.tripStart),
            kind: kind,
            title: title,
            address: "Malpensa Airport",
            attachmentPath: attachmentPath,
            barcodePayload: barcodePayload
        )
        item.sourceConfirmation = confirmation
        store.context.insert(item)
        try? store.context.save()
        return item
    }

    /// Attach a document the way the section would, minus the network call: real
    /// bytes through the real storage, then the row pointing at them.
    @discardableResult
    private func attachDocument(
        to owner: TicketOwner,
        payload: String = "DEXTER-TRIP-DOC-1",
        eventTitle: String = "Boarding pass",
        reference: String = "",
        seat: String = "",
        eventDate: Date? = nil,
        presentedAtEntry: Bool? = nil,
        showInWallet: Bool? = nil,
        position: Int = 0
    ) throws -> TaskTicket {
        let image = try XCTUnwrap(
            BarcodeService.render(
                payload: payload.isEmpty ? "FIXTURE-NO-BARCODE" : payload,
                symbology: .qr
            ),
            "could not render a fixture barcode"
        )
        let jpeg = try XCTUnwrap(image.jpegDataCompat(quality: 0.9))
        let relativePath = try TicketStorage.taskTickets.saveCompressedJpeg(jpeg)
        createdPaths.append(relativePath)

        var meta = TicketMeta()
        meta.presentedAtEntry = presentedAtEntry
        meta.showInWallet = showInWallet

        let row = LocalTaskTicket(
            todoClientUUID: owner.id,
            itineraryItemUUID: owner.itineraryItemUUID,
            attachmentPath: relativePath,
            barcodePayload: payload,
            barcodeSymbology: payload.isEmpty ? "" : BarcodeSymbology.qr.rawValue,
            eventTitle: eventTitle,
            eventDate: eventDate,
            startTimeText: "09:35",
            venue: "Terminal 3",
            seat: seat,
            gate: "",
            reference: reference,
            ticketMetaJSON: meta.isEmpty ? "" : meta.encodedString(),
            position: position
        )
        store.context.insert(row)
        try store.context.save()
        return row.toDTO()
    }

    /// Every wallet entry the app would build from the current store.
    private func walletEntries() throws -> [WalletEntry] {
        WalletEntry.build(
            cards: try store.context.fetch(FetchDescriptor<LocalWalletCard>()),
            itineraryItems: try store.context.fetch(FetchDescriptor<LocalItineraryItem>()),
            trips: try store.context.fetch(FetchDescriptor<LocalTrip>()),
            taskTickets: try store.context.fetch(FetchDescriptor<LocalTaskTicket>())
                .filter { $0.deletedAt == nil },
            todos: try store.context.fetch(FetchDescriptor<LocalTodo>())
        )
    }

    // MARK: - Owner routing

    func testDocumentAttachesToTheStopItWasAddedTo() throws {
        let trip = insertTrip()
        let stop = insertStop(on: trip)
        let service = TaskTicketService(store: store)

        try attachDocument(to: .tripStop(stop.clientUUID))

        let listed = try service.list(owner: .tripStop(stop.clientUUID))
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.itineraryItemUUID, stop.clientUUID)
        XCTAssertEqual(listed.first?.owner, .tripStop(stop.clientUUID))
    }

    /// The discriminator is the whole reason a task's list stays a task's list.
    func testAStopsDocumentsNeverAppearOnATask() throws {
        let trip = insertTrip()
        let stop = insertStop(on: trip)
        let todo = LocalTodo(title: "Check in online")
        store.context.insert(todo)
        try store.context.save()

        try attachDocument(to: .tripStop(stop.clientUUID), payload: "STOP-DOC")
        try attachDocument(to: .task(todo.clientUUID), payload: "TASK-DOC")

        let service = TaskTicketService(store: store)
        XCTAssertEqual(try service.list(todoId: todo.clientUUID).map(\.barcodePayload), ["TASK-DOC"])
        XCTAssertEqual(
            try service.list(owner: .tripStop(stop.clientUUID)).map(\.barcodePayload),
            ["STOP-DOC"]
        )
    }

    /// A row written before #432 has no discriminator, and must still read as a
    /// task's — every one of them is.
    func testARowWithoutADiscriminatorIsATasks() throws {
        let todo = LocalTodo(title: "Coldplay")
        store.context.insert(todo)
        try store.context.save()

        let row = LocalTaskTicket(todoClientUUID: todo.clientUUID)
        store.context.insert(row)
        try store.context.save()

        XCTAssertNil(row.itineraryItemUUID)
        XCTAssertEqual(row.owner, .task(todo.clientUUID))
        XCTAssertEqual(row.owner.section, .tasks)
    }

    func testOneStopHoldsSeveralDocuments() throws {
        let trip = insertTrip()
        let stop = insertStop(on: trip)
        let owner = TicketOwner.tripStop(stop.clientUUID)

        try attachDocument(to: owner, payload: "SEAT-12A", seat: "12A", position: 0)
        try attachDocument(to: owner, payload: "SEAT-12B", seat: "12B", position: 1)

        let listed = try TaskTicketService(store: store).list(owner: owner)
        XCTAssertEqual(listed.map(\.seat), ["12A", "12B"], "documents lost their order")
    }

    // MARK: - The Wallet gate

    func testScannableStopDocumentBecomesAWalletCard() throws {
        let trip = insertTrip(name: "Italy")
        let stop = insertStop(on: trip)
        try attachDocument(to: .tripStop(stop.clientUUID), eventTitle: "SQ 356")

        let entries = try walletEntries()
        let card = try XCTUnwrap(entries.first { entry in
            if case .tripDocument = entry.source { return true }
            return false
        })
        XCTAssertEqual(card.card.title, "SQ 356")
        // Chipped with the TRIP, not the stop: above a boarding pass you want to
        // read where you are going.
        XCTAssertEqual(card.source.label, "Italy")
    }

    func testUnscannableStopDocumentStaysOffTheWallet() throws {
        let trip = insertTrip()
        let stop = insertStop(on: trip, title: "Hertz pickup", kind: .activity)
        // A rental receipt: a file, no barcode, nothing printed to present.
        try attachDocument(to: .tripStop(stop.clientUUID), payload: "", eventTitle: "Rental receipt")

        let hasDocumentCard = try walletEntries().contains { entry in
            if case .tripDocument = entry.source { return true }
            return false
        }
        XCTAssertFalse(hasDocumentCard, "a receipt with nothing to present reached the Wallet")
    }

    func testManualOverrideForcesAnUnscannableStopDocumentIn() throws {
        let trip = insertTrip()
        let stop = insertStop(on: trip, title: "Hertz pickup", kind: .activity)
        try attachDocument(
            to: .tripStop(stop.clientUUID),
            payload: "",
            eventTitle: "Rental voucher",
            showInWallet: true
        )

        let hasDocumentCard = try walletEntries().contains { entry in
            if case .tripDocument = entry.source { return true }
            return false
        }
        XCTAssertTrue(hasDocumentCard, "the person's own answer did not win")
    }

    /// A document orphaned by its stop is skipped rather than shown unlabelled —
    /// the same call the task path makes for a deleted task.
    func testADocumentWhoseStopIsGoneIsSkipped() throws {
        let trip = insertTrip()
        let stop = insertStop(on: trip)
        try attachDocument(to: .tripStop(stop.clientUUID))

        store.context.delete(stop)
        try store.context.save()

        let hasDocumentCard = try walletEntries().contains { entry in
            if case .tripDocument = entry.source { return true }
            return false
        }
        XCTAssertFalse(hasDocumentCard)
    }

    /// A document that printed no date of its own sorts on the day of the stop it
    /// hangs off, not on whenever the file happened to be uploaded.
    func testAnUndatedDocumentTakesTheStopsDay() throws {
        let trip = insertTrip()
        let stop = insertStop(on: trip)
        try attachDocument(to: .tripStop(stop.clientUUID), eventDate: nil)

        let card = try XCTUnwrap(try walletEntries().first { entry in
            if case .tripDocument = entry.source { return true }
            return false
        })
        XCTAssertEqual(card.day, stop.dayDate)
        XCTAssertEqual(card.validThrough, stop.dayDate)
    }

    // MARK: - The gate on the stop's own inline ticket (narrowed by #432)

    /// The regression this change deliberately accepts: an attachment with nothing
    /// scannable and no confirmation code no longer earns the stop a card.
    func testAStopWhoseOnlyAttachmentHasNothingToPresentDropsOutOfTheWallet() throws {
        let trip = insertTrip()
        insertStop(
            on: trip,
            title: "Museum map",
            kind: .activity,
            attachmentPath: "tickets/not-a-real-file.jpg"
        )

        let hasTripCard = try walletEntries().contains { entry in
            if case .trip = entry.source { return true }
            return false
        }
        XCTAssertFalse(hasTripCard)
    }

    /// #433 admitted every booking carrying a confirmation code, and #434 deleted
    /// that arm the day it shipped: it let in 12 of 12 booked stops, 11 of them
    /// with nothing scannable, burying the one card holding a real barcode.
    ///
    /// A PNR is looked up at a counter, not held up at a gate, and it is already
    /// legible on the timeline row. These two tests asserted the old arm and were
    /// left behind when it went, so they have failed on `main` ever since. They now
    /// pin the rule that replaced it: gating on a field every row of a kind carries
    /// is not a gate.
    func testAFlightWithOnlyAConfirmationCodeGetsNoWalletCard() throws {
        let trip = insertTrip()
        insertStop(on: trip, title: "SQ 356 to Milan", confirmation: "HM84R8")

        let hasTripCard = try walletEntries().contains { entry in
            if case .trip = entry.source { return true }
            return false
        }
        XCTAssertFalse(hasTripCard, "a booking code is not a credential (#434)")
    }

    func testAStayWithAConfirmationCodeGetsNoWalletCard() throws {
        let trip = insertTrip()
        insertStop(on: trip, title: "207 Inn", kind: .stay, confirmation: "BK-4413")

        let hasTripCard = try walletEntries().contains { entry in
            if case .trip = entry.source { return true }
            return false
        }
        XCTAssertFalse(hasTripCard)
    }

    func testAScannableStopKeepsItsWalletCard() throws {
        let trip = insertTrip()
        insertStop(on: trip, barcodePayload: "M1SHARMA/AKSHAY")

        let hasTripCard = try walletEntries().contains { entry in
            if case .trip = entry.source { return true }
            return false
        }
        XCTAssertTrue(hasTripCard)
    }

    // MARK: - Delete cascade

    func testDeletingAStopTakesItsDocumentsAndFilesWithIt() throws {
        let trip = insertTrip()
        let stop = insertStop(on: trip)
        let document = try attachDocument(to: .tripStop(stop.clientUUID))
        let service = TaskTicketService(store: store)
        let fileURL = try XCTUnwrap(service.fileURL(for: document))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        ItineraryDocumentCleanup.removeEverything(attachedTo: stop, using: service)
        store.context.delete(stop)
        try store.context.save()

        XCTAssertTrue(try service.list(owner: .tripStop(stop.clientUUID)).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "the document's file outlived the stop"
        )
    }

    // MARK: - Archive round trip

    /// If `itineraryItemUUID` is dropped anywhere in export → import, every stop
    /// document comes back as a task's and disappears from the Wallet with no error.
    func testStopDocumentsSurviveExportAndImportIntoAFreshStore() async throws {
        let trip = insertTrip(name: "Italy")
        let stop = insertStop(on: trip)
        let document = try attachDocument(to: .tripStop(stop.clientUUID), payload: "SEAT-12A")

        let archiveURL = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        try? TicketStorage.taskTickets.delete(relativePath: document.attachmentPath)

        let freshStore = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let importer = DataImportService(modelContext: freshStore.context)
        let preview = try importer.preview(url: archiveURL)
        try importer.commit(preview: preview, mode: .skipExisting)

        let restored = try TaskTicketService(store: freshStore)
            .list(owner: .tripStop(stop.clientUUID))
        XCTAssertEqual(restored.count, 1, "the stop's document did not come back to the stop")
        XCTAssertEqual(restored.first?.itineraryItemUUID, stop.clientUUID)
        XCTAssertEqual(restored.first?.barcodePayload, "SEAT-12A")
    }

    // MARK: - Sync

    /// Documents on a stop have to reach the other device like everything else.
    func testSyncMapperEmitsStopDocumentRecords() throws {
        let trip = insertTrip()
        let stop = insertStop(on: trip)
        try attachDocument(to: .tripStop(stop.clientUUID))

        let payload = try DataExportService(modelContext: store.context).buildPayload()
        let records = try SyncRecordMapper.records(from: payload)
        let documentRecords = records.filter { $0.entity == "LocalTaskTicket" }
        XCTAssertEqual(documentRecords.count, 1, "the stop's document was not offered to sync")
    }
}
