import Foundation
import SwiftData

#if os(macOS)

/// Brings selected Apple Notes into Dexter (#396).
///
/// Reads one note at a time on purpose. A body carries its images inlined as
/// base64, so a single note can be tens of megabytes; fetching the selection in
/// one go would move hundreds of megabytes before writing anything. One at a time
/// also means a failure costs one note rather than the whole run, and the progress
/// count is honest instead of a spinner that sits still.
@MainActor
struct AppleNotesImportService {
    let store: SwiftDataStore
    private let imageStorage = ReceiptStorage.noteImages

    init(store: SwiftDataStore = .shared) {
        self.store = store
    }

    // MARK: - Types

    /// What a run will do, resolved before anything is written.
    struct Plan {
        /// Notes that will be created, paired with the folder name to file them
        /// under.
        var pending: [(folderName: String, note: AppleNotesReader.NoteRef)]
        /// Notes in the selection already imported previously, which are skipped.
        var alreadyImported: Int

        var isEmpty: Bool { pending.isEmpty }
    }

    struct Outcome {
        var imported = 0
        var skipped = 0
        var failed = 0
        var imagesImported = 0
        /// PDFs and other non-image attachments Notes reported that could not be
        /// carried across, because a Dexter note body can only reference an image.
        var nonImageAttachmentsSkipped = 0
        /// Names of notes that failed, so the summary can be specific rather than
        /// just reporting a count.
        var failedNoteNames: [String] = []
    }

    // MARK: - Planning

    /// Resolve a selection against what has already been imported.
    ///
    /// Dedup is by Apple Notes id, not by title: two notes can share a title, and
    /// a note's title changes when its first line does.
    func plan(
        folders: [AppleNotesReader.Folder],
        selectedNoteIDs: Set<String>
    ) throws -> Plan {
        let imported = try importedAppleNoteIDs()
        var plan = Plan(pending: [], alreadyImported: 0)

        for folder in folders {
            for note in folder.notes where selectedNoteIDs.contains(note.id) {
                if imported.contains(note.id) {
                    plan.alreadyImported += 1
                } else {
                    plan.pending.append((folderName: folder.name, note: note))
                }
            }
        }
        return plan
    }

    private func importedAppleNoteIDs() throws -> Set<String> {
        let rows = try store.context.fetch(FetchDescriptor<AppleNotesImportRecord>())
        return Set(rows.map(\.appleNoteID))
    }

    // MARK: - Import

    /// Import every pending note, reporting progress as each one lands.
    ///
    /// `onProgress` is called with (completed, total) after each note so the UI can
    /// count up. Never throws for a single bad note: it is recorded in the outcome
    /// and the run continues, because one unreadable note should not abandon
    /// ninety-nine good ones.
    func run(
        plan: Plan,
        onProgress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async -> Outcome {
        var outcome = Outcome()
        outcome.skipped = plan.alreadyImported
        let total = plan.pending.count

        for (index, item) in plan.pending.enumerated() {
            do {
                let result = try await importOne(
                    folderName: item.folderName, note: item.note
                )
                outcome.imported += 1
                outcome.imagesImported += result.images
                outcome.nonImageAttachmentsSkipped += result.nonImageAttachments
            } catch {
                outcome.failed += 1
                outcome.failedNoteNames.append(item.note.name)
            }
            onProgress(index + 1, total)
        }

        // Tasks / Notes / Lists cache rows in view models rather than a live
        // `@Query`, so they show stale content until told. Same reason the data
        // importer and sync post this (#364).
        if outcome.imported > 0 {
            NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
        }
        return outcome
    }

    private struct SingleResult {
        let images: Int
        let nonImageAttachments: Int
    }

    private func importOne(
        folderName: String, note: AppleNotesReader.NoteRef
    ) async throws -> SingleResult {
        let body = try await AppleNotesReader.body(noteID: note.id)
        let converted = AppleNotesHTMLConverter.convert(
            html: body.html, attachmentCount: body.attachmentCount
        )

        // The note's UUID is minted up front so its images can point at it before
        // the note row is saved.
        let noteUUID = UUID()

        // Compress and store each image, then swap its placeholder for the real
        // reference. Compression happens off the main actor: these are frequently
        // multi-megabyte TIFF scans and the re-encode is the expensive step.
        var markdown = converted.markdown
        var savedImages: [(path: String, size: (width: Int, height: Int)?)] = []
        for image in converted.images {
            let storage = imageStorage
            guard let compressed = try? await Task.detached(priority: .userInitiated, operation: {
                try storage.compress(imageData: image.data)
            }).value,
            let relativePath = try? storage.saveCompressedJpeg(compressed) else {
                // An image that will not decode is dropped and its placeholder
                // removed, rather than leaving `{{dexter-image-N}}` in the note.
                markdown = markdown.replacingOccurrences(
                    of: AppleNotesHTMLConverter.placeholder(image.index), with: ""
                )
                continue
            }
            markdown = markdown.replacingOccurrences(
                of: AppleNotesHTMLConverter.placeholder(image.index),
                with: NoteBodyMarkdown.token(for: relativePath)
            )
            savedImages.append((path: relativePath, size: nil))
        }

        let folderUUID = try folderUUID(named: folderName)
        let created = note.created ?? Date()
        let modified = note.modified ?? created

        let row = LocalNote(
            clientUUID: noteUUID,
            folderClientUUID: folderUUID,
            // Prefer the note's own name: it is what Notes shows in its list, and
            // the leading <h1> the converter lifted is the same string.
            title: note.name.isEmpty ? converted.title : note.name,
            content: markdown.isEmpty ? nil : markdown,
            createdAt: created,
            updatedAt: modified,
            needsSync: true
        )
        store.context.insert(row)

        for (position, saved) in savedImages.enumerated() {
            store.context.insert(LocalNoteImage(
                noteClientUUID: noteUUID,
                relativePath: saved.path,
                position: position,
                createdAt: created,
                updatedAt: modified
            ))
        }

        store.context.insert(AppleNotesImportRecord(
            appleNoteID: note.id,
            localNoteUUID: noteUUID,
            appleModifiedAt: note.modified
        ))

        try store.context.save()
        return SingleResult(
            images: savedImages.count,
            nonImageAttachments: converted.nonImageAttachmentCount
        )
    }

    /// Find or create the Dexter folder for an Apple Notes folder name.
    ///
    /// Matched by name against ACTIVE folders only. Matching an archived or
    /// deleted folder would file fresh imports somewhere the user cannot see them.
    private func folderUUID(named name: String) throws -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Apple's default top-level folder is "Notes"; those notes are unfiled in
        // Dexter rather than sitting in a folder called Notes inside Notes.
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Notes") != .orderedSame else {
            return nil
        }

        let existing = try store.context.fetch(FetchDescriptor<LocalNoteFolder>(
            predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil }
        ))
        if let match = existing.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return match.clientUUID
        }

        let folder = LocalNoteFolder(name: trimmed)
        store.context.insert(folder)
        try store.context.save()
        return folder.clientUUID
    }
}

#endif
