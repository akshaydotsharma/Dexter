import Foundation
import SwiftData
import ImageIO

/// Local-first store for note image attachments (#395).
///
/// Splits the work the way `ReceiptStorage` intends: compression runs off the
/// main actor (it decodes and re-encodes a full-resolution photo, which is the
/// expensive step), while the SwiftData insert stays on it.
@MainActor
struct NoteImageService {
    let store: SwiftDataStore
    private let storage = ReceiptStorage.noteImages

    init(store: SwiftDataStore = .shared) {
        self.store = store
    }

    // MARK: - Reads

    /// Images attached to `noteId`, in display order.
    func list(noteId: UUID) throws -> [NoteImage] {
        let descriptor = FetchDescriptor<LocalNoteImage>(
            predicate: #Predicate { $0.noteClientUUID == noteId && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.position, order: .forward)]
        )
        return try store.context.fetch(descriptor).map { $0.toDTO() }
    }

    /// Count per note for a set of notes, used by the notes index to show an
    /// image badge without loading any bytes.
    func counts(noteIds: Set<UUID>) throws -> [UUID: Int] {
        guard !noteIds.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<LocalNoteImage>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        var out: [UUID: Int] = [:]
        for row in try store.context.fetch(descriptor) where noteIds.contains(row.noteClientUUID) {
            out[row.noteClientUUID, default: 0] += 1
        }
        return out
    }

    /// Resolve a stored relative path to an on-disk URL, or nil when the file
    /// is not on this device (synced from a peer, or lost to a reinstall).
    func fileURL(for image: NoteImage) -> URL? {
        storage.load(relativePath: image.relativePath)
    }

    // MARK: - Writes

    /// Compress `imageData` to a capped JPEG, write it under
    /// `Documents/note-images/`, and attach it to `noteId` at the end of the
    /// existing strip.
    ///
    /// Whatever came in (HEIC from the iPhone camera, the TIFF that Apple Notes
    /// hands back, a PNG screenshot) leaves as a downsized JPEG, so the note
    /// strip never holds a 12 MB original.
    @discardableResult
    func add(noteId: UUID, imageData: Data) async throws -> NoteImage {
        let storage = self.storage
        let compressed = try await Task.detached(priority: .userInitiated) {
            try storage.compress(imageData: imageData)
        }.value

        let relativePath = try storage.saveCompressedJpeg(compressed)
        let size = Self.pixelSize(of: compressed)

        let row = LocalNoteImage(
            noteClientUUID: noteId,
            relativePath: relativePath,
            position: try nextPosition(noteId: noteId),
            pixelWidth: size?.width,
            pixelHeight: size?.height
        )
        store.context.insert(row)
        try store.context.save()
        touchNote(noteId)
        return row.toDTO()
    }

    /// Detach an image and remove its file.
    ///
    /// Soft-deletes the row so the delete propagates through sync the way every
    /// other entity's does, then removes the bytes: a tombstoned row will never
    /// be shown again, so keeping the file would just leak disk.
    func delete(_ image: NoteImage) throws {
        let imageID = image.id
        let descriptor = FetchDescriptor<LocalNoteImage>(
            predicate: #Predicate { $0.clientUUID == imageID }
        )
        guard let row = try store.context.fetch(descriptor).first else { return }
        let path = row.relativePath
        row.deletedAt = Date()
        row.updatedAt = Date()
        try store.context.save()
        // A file that is already gone is not an error worth surfacing: the row
        // is detached either way, which is what the user asked for.
        try? storage.delete(relativePath: path)
        touchNote(image.noteId)
    }

    /// Detach every image on a note. Called when the note itself is deleted so
    /// its attachments don't outlive it as orphaned rows and files.
    func deleteAll(noteId: UUID) throws {
        let descriptor = FetchDescriptor<LocalNoteImage>(
            predicate: #Predicate { $0.noteClientUUID == noteId && $0.deletedAt == nil }
        )
        let rows = try store.context.fetch(descriptor)
        guard !rows.isEmpty else { return }
        let now = Date()
        var paths: [String] = []
        for row in rows {
            paths.append(row.relativePath)
            row.deletedAt = now
            row.updatedAt = now
        }
        try store.context.save()
        for path in paths {
            try? storage.delete(relativePath: path)
        }
    }

    // MARK: - Internals

    /// Append position. Reads the current max rather than counting rows, so a
    /// strip that has had images removed doesn't reuse a position.
    private func nextPosition(noteId: UUID) throws -> Int {
        let descriptor = FetchDescriptor<LocalNoteImage>(
            predicate: #Predicate { $0.noteClientUUID == noteId && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.position, order: .reverse)]
        )
        let rows = try store.context.fetch(descriptor)
        return (rows.first?.position ?? -1) + 1
    }

    /// Bump the note's `updatedAt` so attaching or removing an image counts as
    /// editing the note. Without this, the notes index (sorted by `updatedAt`)
    /// would not move a note the user just added a photo to, and sync would not
    /// see the note as changed.
    private func touchNote(_ noteId: UUID) {
        let descriptor = FetchDescriptor<LocalNote>(
            predicate: #Predicate { $0.clientUUID == noteId }
        )
        guard let note = try? store.context.fetch(descriptor).first else { return }
        note.updatedAt = Date()
        try? store.context.save()
    }

    /// Pixel dimensions straight from the JPEG header. ImageIO reads the
    /// metadata without decoding the pixels, and is portable across both
    /// platforms unlike `UIImage` / `NSImage`.
    private nonisolated static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
