import XCTest
import SwiftData
@testable import PersonalDashboard

/// Does a delete arriving over sync take the attachment file with it (#477)?
///
/// A local delete already removed the file, but every one of those call sites is
/// in a view or a service (`ItineraryDocumentCleanup.removeEverything`,
/// `TicketStorage.delete`), so a delete applied by `SyncApplier` removed the row
/// and left the bytes on disk forever, unreferenced by anything.
///
/// The property guarded hardest here is NOT the deletion — it is the restraint:
/// a file another surviving row still points at must be kept. Deleting a file
/// out from under a live row leaves that row with a broken viewer, which is far
/// worse than an orphan, and #411 is the standing proof that this area punishes
/// over-eager cleanup.
@MainActor
final class SyncDeleteRemovesAttachmentTests: XCTestCase {

    private var storeDirectory: URL!
    private var writtenPaths: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        storeDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        writtenPaths = []
    }

    override func tearDown() async throws {
        for path in writtenPaths {
            try? SyncAssetStorage.delete(at: path)
        }
        try? FileManager.default.removeItem(at: storeDirectory)
        try await super.tearDown()
    }

    // MARK: - The defect

    /// A peer delete for a ticket must remove the PDF, not just the row.
    func testPeerDeleteOfAnItineraryItemRemovesItsFile() throws {
        let context = ModelContext(try makeContainer())
        let itemID = UUID()
        let path = try writeTicket()

        let item = makeItem(uuid: itemID, attachmentPath: path)
        context.insert(item)
        try context.save()
        XCTAssertNotNil(SyncAssetStorage.existingURL(for: path), "fixture should be on disk")

        let outcome = try SyncApplier(modelContext: context)
            .apply([deleteOp(entity: "LocalItineraryItem", recordID: itemID.uuidString)],
                   localDeviceUUID: UUID())

        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertNil(
            SyncAssetStorage.existingURL(for: path),
            "the row went but its attachment stayed — that is #477")
    }

    /// The same must hold for a wallet card, so this is not a trip-only patch.
    func testPeerDeleteOfAWalletCardRemovesItsFile() throws {
        let context = ModelContext(try makeContainer())
        let cardID = UUID()
        let path = try writeTicket()

        let card = LocalWalletCard(
            clientUUID: cardID, kind: .boardingPass, title: "SQ874",
            dayDate: .now, createdAt: .now, updatedAt: .now)
        card.attachmentPath = path
        context.insert(card)
        try context.save()

        _ = try SyncApplier(modelContext: context)
            .apply([deleteOp(entity: "LocalWalletCard", recordID: cardID.uuidString)],
                   localDeviceUUID: UUID())

        XCTAssertNil(SyncAssetStorage.existingURL(for: path))
    }

    // MARK: - The restraint

    /// #475 gives each leg of a round trip its own copy of the file precisely
    /// because sharing is unsafe, but an archive restore could still produce two
    /// rows on one path. Deleting one leg must not blind the other.
    func testAFileStillReferencedByASurvivingRowIsKept() throws {
        let context = ModelContext(try makeContainer())
        let outboundID = UUID()
        let returnID = UUID()
        let shared = try writeTicket()

        context.insert(makeItem(uuid: outboundID, attachmentPath: shared))
        context.insert(makeItem(uuid: returnID, attachmentPath: shared))
        try context.save()

        _ = try SyncApplier(modelContext: context)
            .apply([deleteOp(entity: "LocalItineraryItem", recordID: outboundID.uuidString)],
                   localDeviceUUID: UUID())

        XCTAssertNotNil(
            SyncAssetStorage.existingURL(for: shared),
            "the return leg still points at this file; deleting it breaks that row's viewer")
    }

    /// Once the LAST referencing row goes, the file may go too.
    func testTheFileGoesOnceTheLastReferenceIsDeleted() throws {
        let context = ModelContext(try makeContainer())
        let first = UUID()
        let second = UUID()
        let shared = try writeTicket()

        context.insert(makeItem(uuid: first, attachmentPath: shared))
        context.insert(makeItem(uuid: second, attachmentPath: shared))
        try context.save()

        let applier = SyncApplier(modelContext: context)
        _ = try applier.apply([deleteOp(entity: "LocalItineraryItem", recordID: first.uuidString)],
                              localDeviceUUID: UUID())
        XCTAssertNotNil(SyncAssetStorage.existingURL(for: shared), "one reference left")

        _ = try applier.apply([deleteOp(entity: "LocalItineraryItem", recordID: second.uuidString)],
                              localDeviceUUID: UUID())
        XCTAssertNil(SyncAssetStorage.existingURL(for: shared), "no references left")
    }

    /// Both rows deleted in ONE batch must still clear the file. The reference
    /// check runs after the save, so a row on its way out must not be counted as
    /// a live reference that pins the file forever.
    func testTwoRowsSharingAFileDeletedInOneBatchClearIt() throws {
        let context = ModelContext(try makeContainer())
        let first = UUID()
        let second = UUID()
        let shared = try writeTicket()

        context.insert(makeItem(uuid: first, attachmentPath: shared))
        context.insert(makeItem(uuid: second, attachmentPath: shared))
        try context.save()

        _ = try SyncApplier(modelContext: context).apply([
            deleteOp(entity: "LocalItineraryItem", recordID: first.uuidString),
            deleteOp(entity: "LocalItineraryItem", recordID: second.uuidString),
        ], localDeviceUUID: UUID())

        XCTAssertNil(SyncAssetStorage.existingURL(for: shared))
    }

    /// A file another ENTITY still references must be kept, or the check would
    /// only be as good as the one table it happened to look at.
    func testAFileReferencedByADifferentEntityIsKept() throws {
        let context = ModelContext(try makeContainer())
        let itemID = UUID()
        let cardID = UUID()
        let shared = try writeTicket()

        context.insert(makeItem(uuid: itemID, attachmentPath: shared))
        let card = LocalWalletCard(
            clientUUID: cardID, kind: .boardingPass, title: "SQ874",
            dayDate: .now, createdAt: .now, updatedAt: .now)
        card.attachmentPath = shared
        context.insert(card)
        try context.save()

        _ = try SyncApplier(modelContext: context)
            .apply([deleteOp(entity: "LocalItineraryItem", recordID: itemID.uuidString)],
                   localDeviceUUID: UUID())

        XCTAssertNotNil(
            SyncAssetStorage.existingURL(for: shared),
            "a wallet card still points at this path")
    }

    // MARK: - Harmless cases

    /// A row with no attachment must apply exactly as before.
    func testDeletingARowWithNoAttachmentIsANoOp() throws {
        let context = ModelContext(try makeContainer())
        let itemID = UUID()
        context.insert(makeItem(uuid: itemID, attachmentPath: ""))
        try context.save()

        let outcome = try SyncApplier(modelContext: context)
            .apply([deleteOp(entity: "LocalItineraryItem", recordID: itemID.uuidString)],
                   localDeviceUUID: UUID())
        XCTAssertEqual(outcome.deleted, 1)
    }

    /// An already-missing file must not fail the pass. Orphaned bytes cost disk;
    /// a thrown error costs every row in the batch.
    func testDeletingARowWhoseFileIsAlreadyGoneStillApplies() throws {
        let context = ModelContext(try makeContainer())
        let itemID = UUID()
        let path = "tickets/never-written-\(UUID().uuidString).pdf"
        context.insert(makeItem(uuid: itemID, attachmentPath: path))
        try context.save()

        let outcome = try SyncApplier(modelContext: context)
            .apply([deleteOp(entity: "LocalItineraryItem", recordID: itemID.uuidString)],
                   localDeviceUUID: UUID())
        XCTAssertEqual(outcome.deleted, 1)
    }

    /// A delete arriving before the record ever did must not throw either.
    func testDeletingAnAbsentRowStillApplies() throws {
        let context = ModelContext(try makeContainer())
        let outcome = try SyncApplier(modelContext: context)
            .apply([deleteOp(entity: "LocalItineraryItem", recordID: UUID().uuidString)],
                   localDeviceUUID: UUID())
        XCTAssertEqual(outcome.deleted, 0, "nothing to delete, and no crash")
    }

    /// A path under a directory this build does not know must be left alone
    /// rather than guessed at.
    func testAnUnrecognisedPathIsLeftAlone() throws {
        let context = ModelContext(try makeContainer())
        let itemID = UUID()
        context.insert(makeItem(uuid: itemID, attachmentPath: "who-knows/x.pdf"))
        try context.save()

        let outcome = try SyncApplier(modelContext: context)
            .apply([deleteOp(entity: "LocalItineraryItem", recordID: itemID.uuidString)],
                   localDeviceUUID: UUID())
        XCTAssertEqual(outcome.deleted, 1)
    }

    // MARK: - One shared list of models

    /// The applier's cleanup and the asset transfer must agree on what an
    /// attachment is. Two hand-maintained lists is the shape that left #446's
    /// blocks unbacked-up.
    func testReferencedPathsIsTheSharedEnumeration() throws {
        let context = ModelContext(try makeContainer())
        let ticket = try writeTicket()
        let item = makeItem(uuid: UUID(), attachmentPath: ticket)
        context.insert(item)
        try context.save()

        XCTAssertTrue(SyncAssetStorage.referencedPaths(in: context).contains(ticket))
    }

    // MARK: - Fixtures

    private var storeURL: URL { storeDirectory.appendingPathComponent("store.sqlite") }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SwiftDataStore.schemaModels)
        return try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
    }

    private func makeItem(uuid: UUID, attachmentPath: String) -> LocalItineraryItem {
        let item = LocalItineraryItem(
            clientUUID: uuid,
            tripUUID: UUID(),
            dayDate: .now,
            kind: .transport,
            title: "SQ874 · SIN→HKG",
            createdAt: .now,
            updatedAt: .now
        )
        item.attachmentPath = attachmentPath
        return item
    }

    private func writeTicket() throws -> String {
        let path = "tickets/test-\(UUID().uuidString).pdf"
        try TicketStorage.shared.write(data: Data("%PDF-1.4 fixture".utf8), relativePath: path)
        writtenPaths.append(path)
        return path
    }

    private func deleteOp(entity: String, recordID: String) -> SyncOp {
        SyncOp(
            opID: UUID(),
            deviceUUID: UUID(),
            lamport: 100,
            wallClock: .now,
            entity: entity,
            recordID: recordID,
            kind: .delete,
            payload: nil,
            contentHash: nil
        )
    }
}
