import XCTest
import SwiftData
@testable import PersonalDashboard

/// Do attachment FILES actually cross between devices (#471)?
///
/// Sync moved rows and left their bytes behind, so a ticket reached the other
/// device as JSON while its PDF stayed put. These tests stand up two real device
/// subtrees in one temp folder — which is what the shared iCloud folder is — and
/// drive a publish on one and a fetch on the other.
///
/// Two properties get asserted harder than the round trip itself, because both
/// have already cost this project real data:
///
///  * **No path is created by two devices.** #353 forked a shared ancestor
///    directory into `devices/` and `devices 2/`, after which each device read
///    only its own branch while both reported healthy. Every path this feature
///    writes must sit under `DexterSync-<uuid>/`.
///  * **A row keeps its `attachmentPath` through a sync apply.** That is #411,
///    the prerequisite: without it there is no reference for the bytes to attach
///    to, so the transfer would be building on nothing.
@MainActor
final class SyncAssetTransferTests: XCTestCase {

    private var folderRoot: URL!
    private var storeDirectory: URL!
    private var writtenPaths: [String] = []

    private let deviceA = UUID()
    private let deviceB = UUID()

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-assets-\(UUID().uuidString)")
        folderRoot = base.appendingPathComponent("Folder")
        storeDirectory = base.appendingPathComponent("Store")
        try FileManager.default.createDirectory(at: folderRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        writtenPaths = []
    }

    override func tearDown() async throws {
        // Attachment bytes land in the test host's Documents, so clean up rather
        // than leaving a file from every run behind.
        for path in writtenPaths {
            try? ReceiptStorage.noteImages.delete(relativePath: path)
            try? TicketStorage.taskTickets.delete(relativePath: path)
        }
        try? FileManager.default.removeItem(at: folderRoot.deletingLastPathComponent())
        try await super.tearDown()
    }

    // MARK: - Layout

    /// #353's rule, applied to blobs: nothing outside the writing device's own
    /// directory, so there is no shared ancestor for iCloud to fork.
    func testEveryAssetPathLivesUnderTheWritingDevicesOwnDirectory() throws {
        let folder = makeFolder()
        let refs = [
            folder.assetsDirectory(deviceA),
            folder.blobURL(deviceA, blobName: "abc123.jpg"),
            folder.assetManifestURL(deviceA, sequence: 1),
        ]
        let own = folder.deviceDirectory(deviceA).standardizedFileURL.path
        for url in refs {
            XCTAssertTrue(
                url.standardizedFileURL.path.hasPrefix(own + "/"),
                "\(url.lastPathComponent) escaped DexterSync-<uuid>/, which is what #353 forked"
            )
        }
        // And the peer's tree is a sibling, never a shared parent this device
        // would also create.
        XCTAssertNotEqual(folder.assetsDirectory(deviceA), folder.assetsDirectory(deviceB))
    }

    /// The blob is named for its own contents, so two devices publishing the same
    /// bytes agree on the name and a re-publish has nothing to write.
    func testBlobNameIsTheContentHash() throws {
        let data = Data("a boarding pass".utf8)
        let ref = SyncAssetRef(
            relativePath: "tickets/\(UUID().uuidString).pdf",
            sha256: SyncHash.hex(data),
            ext: "pdf",
            byteCount: data.count
        )
        XCTAssertEqual(ref.blobName, "\(SyncHash.hex(data)).pdf")
        XCTAssertEqual(ref.sha256.count, 64)
    }

    /// A sealed manifest is never rewritten, for the same reason a sealed segment
    /// is not: a mutable file is the one thing iCloud will fork.
    func testAManifestRefusesToBeOverwritten() throws {
        let folder = makeFolder()
        let manifest = SyncAssetManifest(deviceUUID: deviceA, sequence: 1, assets: [])
        try folder.writeAssetManifest(manifest)
        XCTAssertThrowsError(try folder.writeAssetManifest(manifest))
    }

    // MARK: - Publish

    func testPublishWritesOneBlobAndOneManifestThenStopsRepeating() async throws {
        let relativePath = "note-images/\(UUID().uuidString).jpg"
        let bytes = Data("a photo of a whiteboard".utf8)
        try writeLocal(bytes, to: relativePath)

        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(LocalNoteImage(
            clientUUID: UUID(),
            noteClientUUID: UUID(),
            relativePath: relativePath,
            position: 0
        ))
        try context.save()

        let folder = makeFolder()
        let first = await SyncAssetTransfer(modelContext: context)
            .run(folder: folder, state: state(deviceA, in: context))
        XCTAssertEqual(first.published, 1)

        let blobName = "\(SyncHash.hex(bytes)).jpg"
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.blobURL(deviceA, blobName: blobName).path),
            "the blob must be on disk under its content hash"
        )
        XCTAssertEqual(try folder.assetManifestSequences(for: deviceA), [1])

        // Content addressing makes the second pass a no-op. If this regresses, the
        // folder grows a manifest per pass forever.
        let second = await SyncAssetTransfer(modelContext: context)
            .run(folder: folder, state: state(deviceA, in: context))
        XCTAssertEqual(second.published, 0)
        XCTAssertEqual(try folder.assetManifestSequences(for: deviceA), [1])
    }

    // MARK: - Fetch

    /// The whole point of the ticket: a file added on one device opens on the
    /// other.
    func testAPeersFileIsFetchedToThePathTheRowNames() async throws {
        let relativePath = "task-tickets/\(UUID().uuidString).pdf"
        let bytes = Data("%PDF-1.4 a real ticket".utf8)
        let folder = makeFolder()

        // Device A publishes by hand, standing in for its own pass.
        let ref = SyncAssetRef(
            relativePath: relativePath,
            sha256: SyncHash.hex(bytes),
            ext: "pdf",
            byteCount: bytes.count
        )
        try folder.writeBlob(bytes, deviceUUID: deviceA, blobName: ref.blobName)
        try folder.writeAssetManifest(
            SyncAssetManifest(deviceUUID: deviceA, sequence: 1, assets: [ref])
        )

        // Device B holds the ROW but not the bytes, which is the state a sync
        // apply leaves behind.
        let container = try makeContainer()
        let context = ModelContext(container)
        let ticket = LocalTaskTicket(clientUUID: UUID(), todoClientUUID: UUID())
        ticket.attachmentPath = relativePath
        context.insert(ticket)
        try context.save()
        writtenPaths.append(relativePath)
        XCTAssertNil(TicketStorage.taskTickets.load(relativePath: relativePath))

        let outcome = await SyncAssetTransfer(modelContext: context)
            .run(folder: folder, state: state(deviceB, in: context))

        XCTAssertEqual(outcome.fetched, 1)
        let landed = try XCTUnwrap(TicketStorage.taskTickets.load(relativePath: relativePath))
        XCTAssertEqual(try Data(contentsOf: landed), bytes, "the bytes must survive the trip intact")
        XCTAssertFalse(
            SyncAssetInbox.shared.isArriving(relativePath),
            "a file that has landed is no longer arriving"
        )
    }

    /// Bytes that do not hash to the name they were fetched under are thrown
    /// away. Writing them would put a corrupt file in the user's Documents that
    /// is indistinguishable from a damaged original.
    func testBytesThatDoNotMatchTheirBlobNameAreRefused() async throws {
        let relativePath = "task-tickets/\(UUID().uuidString).pdf"
        let folder = makeFolder()
        let claimed = SyncHash.hex(Data("what the manifest promises".utf8))
        let ref = SyncAssetRef(
            relativePath: relativePath, sha256: claimed, ext: "pdf", byteCount: 4
        )
        try folder.writeBlob(Data("something else entirely".utf8), deviceUUID: deviceA, blobName: ref.blobName)
        try folder.writeAssetManifest(
            SyncAssetManifest(deviceUUID: deviceA, sequence: 1, assets: [ref])
        )

        let container = try makeContainer()
        let context = ModelContext(container)
        let ticket = LocalTaskTicket(clientUUID: UUID(), todoClientUUID: UUID())
        ticket.attachmentPath = relativePath
        context.insert(ticket)
        try context.save()

        let outcome = await SyncAssetTransfer(modelContext: context)
            .run(folder: folder, state: state(deviceB, in: context))

        XCTAssertEqual(outcome.rejected, 1)
        XCTAssertEqual(outcome.fetched, 0)
        XCTAssertNil(
            TicketStorage.taskTickets.load(relativePath: relativePath),
            "nothing may be written when the hash disagrees"
        )
    }

    /// A file nobody has published is reported as unavailable, not as arriving.
    /// The distinction is the whole reason the UI has two sentences.
    func testAFileNoPeerHasIsNotReportedAsArriving() async throws {
        let relativePath = "task-tickets/\(UUID().uuidString).pdf"
        let container = try makeContainer()
        let context = ModelContext(container)
        let ticket = LocalTaskTicket(clientUUID: UUID(), todoClientUUID: UUID())
        ticket.attachmentPath = relativePath
        context.insert(ticket)
        try context.save()

        let outcome = await SyncAssetTransfer(modelContext: context)
            .run(folder: makeFolder(), state: state(deviceB, in: context))

        XCTAssertEqual(outcome.unavailable, 1)
        XCTAssertEqual(outcome.awaiting, 0)
        XCTAssertFalse(SyncAssetInbox.shared.isArriving(relativePath))
    }

    // MARK: - Sweep

    /// Space is reclaimed by an age-based sweep rather than by reference counting,
    /// so the rule has to refuse three cases outright. Each one loses a file the
    /// user still wants if it goes wrong.
    func testTheSweepOnlyRemovesUnreferencedBlobsThatAreOldEnough() {
        let now = Date()
        let old = now.addingTimeInterval(-60 * 24 * 60 * 60)
        let young = now.addingTimeInterval(-60 * 60)

        let doomed = SyncAssetTransfer.blobsToSweep(
            blobNames: ["gone.jpg", "kept.jpg", "young.jpg", "shared.jpg", "stranger.jpg"],
            pathsByBlob: [
                "gone.jpg": ["receipts/gone.jpg"],
                "kept.jpg": ["receipts/kept.jpg"],
                "young.jpg": ["receipts/young.jpg"],
                // One blob, two trips. Content-addressed art is shared, so the
                // second trip's reference has to keep it alive.
                "shared.jpg": ["trip-covers/a.jpg", "trip-covers/b.jpg"],
            ],
            referenced: ["receipts/kept.jpg", "trip-covers/b.jpg"],
            createdAt: { $0 == "young.jpg" ? young : old },
            now: now
        )

        XCTAssertEqual(doomed, ["gone.jpg"])
        XCTAssertFalse(doomed.contains("kept.jpg"), "a referenced blob must survive")
        XCTAssertFalse(doomed.contains("young.jpg"), "a peer has not had time to fetch this yet")
        XCTAssertFalse(doomed.contains("shared.jpg"), "one live path is enough to keep a shared blob")
        XCTAssertFalse(
            doomed.contains("stranger.jpg"),
            "a blob in no manifest of ours is not ours to delete"
        )
    }

    // MARK: - Wording

    func testTheTwoMissingFileSentencesDiffer() {
        XCTAssertEqual(
            SyncAssetMessage.missing("Ticket", isArriving: true),
            "Ticket arriving from your other device"
        )
        XCTAssertEqual(
            SyncAssetMessage.missing("Ticket", isArriving: false),
            "Ticket on your other device"
        )
    }

    /// The task row's subtitle is where the arriving state is most visible, and it
    /// is reachable without a view, so it is asserted directly.
    func testTaskRowSubtitleSaysArrivingWhenThePeerHasTheFile() {
        let ticket = TaskTicket(
            id: UUID(),
            todoId: UUID(),
            attachmentPath: "task-tickets/x.pdf",
            barcodePayload: "",
            barcodeSymbology: "",
            eventTitle: "Odette",
            eventDate: nil,
            startTimeText: "",
            venue: "",
            seat: "",
            gate: "",
            reference: "",
            ticketMetaJSON: "",
            position: 0,
            createdAt: .now,
            updatedAt: .now,
            deletedAt: nil
        )
        XCTAssertEqual(
            TaskAttachmentRow.subtitle(for: ticket, fileIsPresent: false, isArriving: true),
            "File arriving from your other device"
        )
        XCTAssertEqual(
            TaskAttachmentRow.subtitle(for: ticket, fileIsPresent: false, isArriving: false),
            "File on your other device"
        )
    }

    // MARK: - #411, the prerequisite

    /// A sync apply must not detach a row from bytes that are on this device.
    ///
    /// The importer is driven exactly as `SyncApplier` drives it — `.replaceMatching`
    /// with no archive entries, because attachment bytes never ride in the oplog.
    /// Under the old ordering every restorer returned nil here and the row was
    /// re-inserted with an empty path over a file that was sitting on disk.
    func testASyncShapedImportKeepsAPathWhoseFileIsOnThisDevice() throws {
        let relativePath = "task-tickets/\(UUID().uuidString).jpg"
        try writeLocal(Data("the scan".utf8), to: relativePath, taskTicket: true)

        let container = try makeContainer()
        let context = ModelContext(container)
        let uuid = UUID()

        try commitTaskTicket(
            uuid: uuid,
            attachmentPath: relativePath,
            into: context,
            unresolvedAssets: .keepPath
        )

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<LocalTaskTicket>()).first
        )
        XCTAssertEqual(stored.clientUUID, uuid)
        XCTAssertEqual(stored.attachmentPath, relativePath, "#411: the path must survive the apply")
    }

    /// The other half of #411's acceptance criteria: an archive restore that did
    /// not carry the file still ends up with an empty path, so a row never claims
    /// bytes that are nowhere.
    func testAnArchiveRestoreWithoutTheFileStillLeavesThePathEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        try commitTaskTicket(
            uuid: UUID(),
            attachmentPath: "task-tickets/\(UUID().uuidString).jpg",
            into: context,
            unresolvedAssets: .dropPath
        )

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<LocalTaskTicket>()).first
        )
        XCTAssertEqual(stored.attachmentPath, "")
    }

    /// And the sync path keeps the reference even when the bytes are nowhere yet,
    /// which is what a freshly received row looks like before its blob lands.
    func testASyncApplyKeepsTheReferenceForBytesThatHaveNotArrivedYet() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let relativePath = "task-tickets/\(UUID().uuidString).jpg"

        try commitTaskTicket(
            uuid: UUID(),
            attachmentPath: relativePath,
            into: context,
            unresolvedAssets: .keepPath
        )

        let stored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<LocalTaskTicket>()).first
        )
        XCTAssertEqual(
            stored.attachmentPath, relativePath,
            "without the reference there is nothing for the transfer to attach bytes to"
        )
    }

    // MARK: - Helpers

    private func makeFolder() -> SyncFolder {
        SyncFolder(
            root: folderRoot,
            usingBackupFolder: false,
            displayName: "Test folder",
            // A plain temp directory was never minted from a bookmark, so
            // `startAccessingSecurityScopedResource()` returns false for it and the
            // callers would read that as access denied.
            isSecurityScoped: false
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: Schema(SwiftDataStore.schemaModels),
            url: storeDirectory.appendingPathComponent("Store-\(UUID().uuidString).sqlite")
        )
        return try ModelContainer(
            for: Schema(SwiftDataStore.schemaModels),
            configurations: configuration
        )
    }

    private func state(_ uuid: UUID, in context: ModelContext) -> SyncDeviceState {
        let state = SyncDeviceState(deviceUUID: uuid, deviceName: "Test device")
        context.insert(state)
        return state
    }

    private func writeLocal(_ data: Data, to relativePath: String, taskTicket: Bool = false) throws {
        if taskTicket {
            _ = try TicketStorage.taskTickets.write(data: data, relativePath: relativePath)
        } else {
            _ = try ReceiptStorage.noteImages.write(data: data, relativePath: relativePath)
        }
        writtenPaths.append(relativePath)
    }

    /// Drive `DataImportService` the way `SyncApplier` does: replace-matching, no
    /// archive entries, one task ticket.
    private func commitTaskTicket(
        uuid: UUID,
        attachmentPath: String,
        into context: ModelContext,
        unresolvedAssets: DataImportService.UnresolvedAssetPolicy
    ) throws {
        var payload = DataArchive.Payload.empty
        payload.taskTickets = [
            DataArchive.TaskTicketDTO(
                clientUUID: uuid,
                todoClientUUID: UUID(),
                attachmentPath: attachmentPath,
                barcodePayload: "",
                barcodeSymbology: "",
                eventTitle: "Odette",
                eventDate: nil,
                startTimeText: "",
                venue: "",
                seat: "",
                gate: "",
                reference: "",
                ticketMetaJSON: "",
                position: 0,
                createdAt: Date(),
                updatedAt: Date(),
                deletedAt: nil
            )
        ]
        let preview = DataImportService.Preview(
            manifest: DataArchive.Manifest(
                schemaVersion: DataArchive.currentSchemaVersion,
                exportedAt: Date(),
                appVersion: "test",
                data: payload
            ),
            archiveURL: URL(fileURLWithPath: "/dev/null"),
            entries: [:],
            counts: [:]
        )
        try DataImportService(modelContext: context)
            .commit(preview: preview, mode: .replaceMatching, unresolvedAssets: unresolvedAssets)
    }
}
