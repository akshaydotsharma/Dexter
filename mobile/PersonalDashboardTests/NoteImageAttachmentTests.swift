import XCTest
import SwiftData
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import PersonalDashboard

/// Note image attachments (#395).
///
/// The three things that can silently break and would not be caught by a build:
/// the write path (row + compressed file + recorded dimensions), the archive
/// round trip (a new model is easy to add to the payload and forget in the
/// exporter, the importer, or the attachment resolver, and the failure looks
/// like "my pictures vanished on restore"), and the delete cascade (orphaned
/// rows and leaked JPEGs after a note goes away).
///
/// Runs against an isolated in-memory store. Image bytes necessarily go through
/// the real `ReceiptStorage.noteImages`, which writes into the test host's
/// Documents container, so every test cleans up the paths it created.
@MainActor
final class NoteImageAttachmentTests: XCTestCase {

    private var store: SwiftDataStore!
    private var tempDir: URL!
    /// Relative paths written during the test, removed in tearDown.
    private var createdPaths: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("note-image-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        createdPaths = []
    }

    override func tearDown() async throws {
        for path in createdPaths {
            try? ReceiptStorage.noteImages.delete(relativePath: path)
        }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        store = nil
        tempDir = nil
        createdPaths = []
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// A real encodable image, so the compressor and the ImageIO dimension read
    /// are exercised rather than stubbed. PNG on the way in specifically to prove
    /// the normalise-to-JPEG step actually happens.
    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create a bitmap context")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            throw XCTSkip("Could not render the bitmap")
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw XCTSkip("Could not create a PNG destination")
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func insertNote(title: String = "Shot list") -> LocalNote {
        let note = LocalNote(title: title, content: "Camilo session")
        store.context.insert(note)
        try? store.context.save()
        return note
    }

    // MARK: - Write path

    func testAttachingImageStoresRowFileAndDimensions() async throws {
        let note = insertNote()
        let service = NoteImageService(store: store)
        let png = try makePNG(width: 400, height: 200)

        let attached = try await service.add(noteId: note.clientUUID, imageData: png)
        createdPaths.append(attached.relativePath)

        // Row is attached to the right note, at the head of the strip.
        let listed = try service.list(noteId: note.clientUUID)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, attached.id)
        XCTAssertEqual(listed.first?.position, 0)

        // Stored under note-images/, not alongside receipts.
        XCTAssertTrue(
            attached.relativePath.hasPrefix("note-images/"),
            "expected a note-images/ path, got \(attached.relativePath)"
        )
        // Normalised to JPEG regardless of the PNG input.
        XCTAssertTrue(attached.relativePath.hasSuffix(".jpg"))

        // Bytes actually landed, and are a JPEG.
        let url = try XCTUnwrap(service.fileURL(for: attached))
        let written = try Data(contentsOf: url)
        XCTAssertGreaterThan(written.count, 0)
        XCTAssertEqual(Array(written.prefix(2)), [0xFF, 0xD8], "not a JPEG")

        // Dimensions recorded, so the strip can reserve the aspect ratio.
        XCTAssertEqual(attached.pixelWidth, 400)
        XCTAssertEqual(attached.pixelHeight, 200)
        XCTAssertEqual(try XCTUnwrap(attached.aspectRatio), 2.0, accuracy: 0.01)
    }

    func testSecondImageAppendsRatherThanReplacing() async throws {
        let note = insertNote()
        let service = NoteImageService(store: store)

        let first = try await service.add(noteId: note.clientUUID, imageData: try makePNG(width: 100, height: 100))
        let second = try await service.add(noteId: note.clientUUID, imageData: try makePNG(width: 120, height: 90))
        createdPaths += [first.relativePath, second.relativePath]

        let listed = try service.list(noteId: note.clientUUID)
        XCTAssertEqual(listed.map(\.position), [0, 1])
        XCTAssertEqual(listed.map(\.id), [first.id, second.id])
        XCTAssertNotEqual(first.relativePath, second.relativePath)
    }

    func testAttachingImageBumpsNoteUpdatedAt() async throws {
        let note = insertNote()
        let before = Date(timeIntervalSince1970: 1_000_000)
        note.updatedAt = before
        try store.context.save()

        let attached = try await NoteImageService(store: store)
            .add(noteId: note.clientUUID, imageData: try makePNG(width: 80, height: 80))
        createdPaths.append(attached.relativePath)

        XCTAssertGreaterThan(
            note.updatedAt, before,
            "adding a photo is an edit; the notes index sorts on updatedAt"
        )
    }

    // MARK: - Delete + cascade

    func testDeletingImageDetachesRowAndRemovesFile() async throws {
        let note = insertNote()
        let service = NoteImageService(store: store)
        let attached = try await service.add(noteId: note.clientUUID, imageData: try makePNG(width: 60, height: 60))
        let url = try XCTUnwrap(service.fileURL(for: attached))

        try service.delete(attached)

        XCTAssertTrue(try service.list(noteId: note.clientUUID).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "a detached image should not leak its JPEG"
        )
    }

    func testDeletingNoteTakesItsImagesWithIt() async throws {
        let note = insertNote()
        let service = NoteImageService(store: store)
        let attached = try await service.add(noteId: note.clientUUID, imageData: try makePNG(width: 60, height: 60))
        let url = try XCTUnwrap(service.fileURL(for: attached))

        try await NoteService(store: store).delete(note.toDTO())

        XCTAssertTrue(
            try service.list(noteId: note.clientUUID).isEmpty,
            "image rows outlived the note that owned them"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Archive round trip

    /// The regression that matters most: a new model reaching the payload but not
    /// the exporter's attachment resolver ships an archive whose rows point at
    /// files it never packed, and the restore looks like data loss.
    func testImagesSurviveExportAndImportIntoAFreshStore() async throws {
        // ---- Device A: a note with two attachments. ----
        let note = insertNote(title: "Bali")
        let service = NoteImageService(store: store)
        let first = try await service.add(noteId: note.clientUUID, imageData: try makePNG(width: 300, height: 150))
        let second = try await service.add(noteId: note.clientUUID, imageData: try makePNG(width: 90, height: 180))
        createdPaths += [first.relativePath, second.relativePath]
        let originalBytes = try Data(contentsOf: try XCTUnwrap(service.fileURL(for: first)))

        let archiveURL = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        // The zip must carry the image bytes, not just the rows.
        let entries = try MiniZip.read(from: archiveURL)
        let entryNames = Set(entries.map(\.name))
        XCTAssertTrue(
            entryNames.contains(first.relativePath),
            "archive is missing \(first.relativePath); entries: \(entryNames.sorted())"
        )
        XCTAssertTrue(entryNames.contains(second.relativePath))

        // ---- Device B: a fresh store, and the files removed from disk so the
        // restore has to come from the archive rather than from what is already
        // there. ----
        for path in [first.relativePath, second.relativePath] {
            try? ReceiptStorage.noteImages.delete(relativePath: path)
        }
        let freshStore = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let importer = DataImportService(modelContext: freshStore.context)
        let preview = try importer.preview(url: archiveURL)

        let imageCounts = try XCTUnwrap(preview.counts(for: .skipExisting)[.noteImages])
        XCTAssertEqual(imageCounts.total, 2, "importer did not see the image rows")
        XCTAssertEqual(imageCounts.new, 2)

        try importer.commit(preview: preview, mode: .skipExisting)

        // ---- Rows and bytes both restored. ----
        let restoredService = NoteImageService(store: freshStore)
        let restored = try restoredService.list(noteId: note.clientUUID)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.map(\.position), [0, 1])
        XCTAssertEqual(restored.first?.relativePath, first.relativePath)
        XCTAssertEqual(restored.first?.pixelWidth, 300)
        XCTAssertEqual(restored.first?.pixelHeight, 150)

        let restoredURL = try XCTUnwrap(restoredService.fileURL(for: try XCTUnwrap(restored.first)))
        XCTAssertEqual(
            try Data(contentsOf: restoredURL), originalBytes,
            "restored image bytes differ from what was exported"
        )
    }

    /// Re-importing the same archive must not duplicate attachments.
    func testReimportingTheSameArchiveIsANoOp() async throws {
        let note = insertNote()
        let service = NoteImageService(store: store)
        let attached = try await service.add(noteId: note.clientUUID, imageData: try makePNG(width: 100, height: 100))
        createdPaths.append(attached.relativePath)

        let archiveURL = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let importer = DataImportService(modelContext: store.context)
        let preview = try importer.preview(url: archiveURL)
        XCTAssertEqual(preview.counts(for: .skipExisting)[.noteImages]?.new, 0)
        try importer.commit(preview: preview, mode: .skipExisting)

        XCTAssertEqual(try service.list(noteId: note.clientUUID).count, 1)
    }

    /// A row whose file the archive did not carry still restores, because it is a
    /// real attachment sitting on the user's other device. It must not be dropped.
    func testRowWithoutBytesStillRestoresAndReportsNoFile() throws {
        let noteID = UUID()
        let orphanPath = "note-images/\(UUID().uuidString.lowercased()).jpg"
        let dto = DataArchive.NoteImageDTO(
            clientUUID: UUID(),
            noteClientUUID: noteID,
            relativePath: orphanPath,
            position: 0,
            pixelWidth: 200,
            pixelHeight: 100,
            createdAt: Date(),
            updatedAt: Date(),
            deletedAt: nil
        )
        var payload = DataArchive.Payload.empty
        payload.noteImages = [dto]
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

        let service = NoteImageService(store: store)
        let restored = try service.list(noteId: noteID)
        XCTAssertEqual(restored.count, 1, "an image row with no bytes was dropped")
        XCTAssertEqual(restored.first?.relativePath, orphanPath)
        XCTAssertNil(
            service.fileURL(for: try XCTUnwrap(restored.first)),
            "no file should resolve, so the strip renders the on-other-device tile"
        )
    }

    /// Sync carries the rows, so the mapper has to know about the entity.
    /// Registered via `exportedModels`, which is easy to update without adding
    /// the corresponding `map` call.
    func testSyncMapperEmitsNoteImageRecords() async throws {
        let note = insertNote()
        let attached = try await NoteImageService(store: store)
            .add(noteId: note.clientUUID, imageData: try makePNG(width: 70, height: 70))
        createdPaths.append(attached.relativePath)

        let payload = try DataExportService(modelContext: store.context).buildPayload()
        let records = try SyncRecordMapper.records(from: payload)

        XCTAssertTrue(SyncRecordMapper.syncedEntities.contains("LocalNoteImage"))
        let imageRecords = records.filter { $0.entity == "LocalNoteImage" }
        XCTAssertEqual(imageRecords.count, 1)
        XCTAssertEqual(imageRecords.first?.recordID, attached.id.uuidString)
    }
}
