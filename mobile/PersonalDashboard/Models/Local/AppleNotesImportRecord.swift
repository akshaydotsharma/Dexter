import Foundation
import SwiftData

/// Provenance for a note brought across from the Apple Notes app (#396).
///
/// A sidecar rather than a field on `LocalNote`, following `LocalProcessedEmail`:
/// this is import bookkeeping, not note content, and `LocalNote` is one of the
/// live models whose schema is risky to widen.
///
/// It exists to make re-import idempotent. Selecting the same folder twice, or
/// importing "everything" after already having taken one folder, must not produce
/// a second copy of anything — and the Apple Notes id is the only stable identity
/// available, since a note's title and body can both change.
@Model
final class AppleNotesImportRecord {
    /// The Notes-internal id, e.g. `x-coredata://…/ICNote/p1064`.
    @Attribute(.unique) var appleNoteID: String
    /// The `LocalNote.clientUUID` this became, so a future version could update
    /// the note in place instead of skipping it.
    var localNoteUUID: UUID
    var importedAt: Date
    /// The note's modification date in Notes at import time. Stored so a later
    /// "re-import changed notes" feature can tell stale from current without
    /// re-reading every body.
    var appleModifiedAt: Date?

    init(
        appleNoteID: String,
        localNoteUUID: UUID,
        importedAt: Date = Date(),
        appleModifiedAt: Date? = nil
    ) {
        self.appleNoteID = appleNoteID
        self.localNoteUUID = localNoteUUID
        self.importedAt = importedAt
        self.appleModifiedAt = appleModifiedAt
    }
}
