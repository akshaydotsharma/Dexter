import Foundation
import SwiftData

/// An image attached to a note (#395).
///
/// A separate model rather than a field on `LocalNote` because a note holds
/// any number of images, and because `LocalNote` is one of the 15 live models
/// whose schema is risky to alter — adding a NEW model is a safe lightweight
/// migration, widening an existing one is the operation that can fail on an
/// install with real data in it.
///
/// Only the relative path is persisted (`note-images/<uuid>.jpg`); the bytes
/// live on disk under Documents. Same split as `LocalExpense.receiptImagePath`
/// and for the same reason: the absolute container path changes on every
/// reinstall, so an absolute path would be dead the moment it was stored.
///
/// ## These rows sync but their files do not
///
/// The model is registered with sync like every other archived entity, so a
/// note's image rows reach the other device. The oplog carries JSON only and
/// has no asset transfer, so the JPEGs stay on the device that created them —
/// the same situation receipts and tickets are already in. The strip renders a
/// "not on this device" tile for a row whose file is missing, which also covers
/// the reinstall case. Images cross devices through the export archive.
@Model
final class LocalNoteImage {
    @Attribute(.unique) var clientUUID: UUID
    /// Owning note, by UUID rather than a SwiftData relationship. Matches how
    /// `LocalNote.folderClientUUID` points at its folder: the archive and the
    /// sync oplog both move flat records keyed on UUID, so a real relationship
    /// would have to be flattened on the way out and rebuilt on the way in.
    var noteClientUUID: UUID
    /// Relative to Documents, e.g. `note-images/9f2c….jpg`.
    var relativePath: String
    /// Display order within the note, ascending.
    var position: Int
    /// Pixel dimensions of the stored JPEG, when known. Kept so the strip can
    /// reserve the right aspect ratio before the image decodes, which stops the
    /// row from jumping as tiles load. Optional because a row restored from an
    /// archive written by a build that did not record them has neither.
    var pixelWidth: Int?
    var pixelHeight: Int?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    /// Intentional dead field, kept for parity with the other local models and
    /// for migration safety — removing a field is the risky direction.
    var needsSync: Bool

    init(
        clientUUID: UUID = UUID(),
        noteClientUUID: UUID,
        relativePath: String,
        position: Int = 0,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        needsSync: Bool = true
    ) {
        self.clientUUID = clientUUID
        self.noteClientUUID = noteClientUUID
        self.relativePath = relativePath
        self.position = position
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsSync = needsSync
    }

    func toDTO() -> NoteImage {
        NoteImage(
            id: clientUUID,
            noteId: noteClientUUID,
            relativePath: relativePath,
            position: position,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}
