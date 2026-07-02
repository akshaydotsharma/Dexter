import Foundation
import SwiftData

/// Reads a `.zip` exported by `DataExportService` and merges it into the
/// local store by `clientUUID`. Existing UUIDs are skipped, new UUIDs
/// inserted. Receipt files for new expenses get restored to
/// `Documents/receipts/<uuid>.<ext>`. Re-importing the same archive is a
/// clean no-op.
///
/// Use it in two steps:
///   1. `preview(url:)` parses + counts so the UI can show the user what
///      will change before they commit.
///   2. `commit(preview:)` writes the new rows + receipt files.
///
/// Splitting the two avoids surprise mutations from a malformed archive
/// and lets the preview screen render counts without holding any locks.
@MainActor
final class DataImportService {

    enum ImportError: LocalizedError {
        case unreadable(Error)
        case zipFailure(MiniZip.ReadError)
        case manifestMissing
        case manifestUnparseable(Error)
        case unsupportedSchemaVersion(found: Int, supported: Int)
        case commitFailed(Error)

        var errorDescription: String? {
            switch self {
            case .unreadable(let e):
                return "Couldn't read the file: \(e.localizedDescription)"
            case .zipFailure(let e):
                return e.errorDescription ?? "Couldn't read the ZIP archive."
            case .manifestMissing:
                return "The archive is missing manifest.json. It doesn't look like a Dexter export."
            case .manifestUnparseable(let e):
                return "The manifest couldn't be parsed: \(e.localizedDescription)"
            case .unsupportedSchemaVersion(let found, let supported):
                return "This archive uses schema version \(found), but this app supports version \(supported). Update the app to import it."
            case .commitFailed(let e):
                return "Couldn't save imported data: \(e.localizedDescription)"
            }
        }
    }

    /// Per-entity counts shown on the preview screen.
    struct EntityCounts: Equatable {
        var total: Int
        var new: Int
        var skipped: Int

        static let zero = EntityCounts(total: 0, new: 0, skipped: 0)
    }

    /// Snapshot of what an import would change. Hand back to `commit(...)`
    /// to actually mutate the store.
    struct Preview {
        let manifest: DataArchive.Manifest
        let archiveURL: URL
        let entries: [String: Data]      // path -> bytes (for receipts)
        let counts: [Entity: EntityCounts]

        var totalNew: Int {
            Entity.allCases.reduce(0) { $0 + (counts[$1]?.new ?? 0) }
        }
        var hasAnythingToImport: Bool { totalNew > 0 }
    }

    /// Display-order entities for the preview. Matches the order the
    /// user sees in the side drawer.
    enum Entity: String, CaseIterable, Hashable, Identifiable {
        case tasks
        case notes
        case noteFolders
        case lists
        case itineraries
        case itineraryDays
        case expenses
        case vocab

        var id: String { rawValue }

        var label: String {
            switch self {
            case .tasks:         return "Tasks"
            case .notes:         return "Notes"
            case .noteFolders:   return "Note folders"
            case .lists:         return "Lists"
            case .itineraries:   return "Itineraries"
            case .itineraryDays: return "Itinerary items"
            case .expenses:      return "Expenses"
            case .vocab:         return "Vocabulary"
            }
        }

        var icon: String {
            switch self {
            case .tasks:         return "checkmark.square"
            case .notes:         return "doc.text"
            case .noteFolders:   return "folder"
            case .lists:         return "list.bullet"
            case .itineraries:   return "airplane"
            case .itineraryDays: return "mappin.and.ellipse"
            case .expenses:      return "dollarsign.circle"
            case .vocab:         return "character.book.closed"
            }
        }
    }

    private let modelContext: ModelContext
    private let receiptStorage: ReceiptStorage

    init(modelContext: ModelContext, receiptStorage: ReceiptStorage = .shared) {
        self.modelContext = modelContext
        self.receiptStorage = receiptStorage
    }

    // MARK: - Preview

    func preview(url: URL) throws -> Preview {
        // Security-scoped resources: iOS hands the document picker a URL
        // outside the app sandbox; without start/stop access the read
        // fails silently. The export-side path lives in our own temp dir
        // and won't need this — but `startAccessingSecurityScopedResource`
        // is safe to call either way (returns false on non-scoped URLs).
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }

        let entries: [MiniZip.Entry]
        do {
            entries = try MiniZip.read(from: url)
        } catch let error as MiniZip.ReadError {
            throw ImportError.zipFailure(error)
        } catch {
            throw ImportError.unreadable(error)
        }

        var byPath: [String: Data] = [:]
        for entry in entries { byPath[entry.name] = entry.data }

        guard let manifestData = byPath["manifest.json"] else {
            throw ImportError.manifestMissing
        }

        let manifest: DataArchive.Manifest
        do {
            manifest = try DataArchive.makeDecoder().decode(DataArchive.Manifest.self, from: manifestData)
        } catch {
            throw ImportError.manifestUnparseable(error)
        }

        guard manifest.schemaVersion == DataArchive.currentSchemaVersion else {
            throw ImportError.unsupportedSchemaVersion(
                found: manifest.schemaVersion,
                supported: DataArchive.currentSchemaVersion
            )
        }

        let counts = try computeCounts(payload: manifest.data)
        return Preview(
            manifest: manifest,
            archiveURL: url,
            entries: byPath,
            counts: counts
        )
    }

    private func computeCounts(payload: DataArchive.Payload) throws -> [Entity: EntityCounts] {
        let existingTodoUUIDs       = try existingUUIDs(LocalTodo.self,           keyPath: \.clientUUID)
        let existingNoteUUIDs       = try existingUUIDs(LocalNote.self,           keyPath: \.clientUUID)
        let existingFolderUUIDs     = try existingUUIDs(LocalNoteFolder.self,     keyPath: \.clientUUID)
        let existingListUUIDs       = try existingUUIDs(LocalList.self,           keyPath: \.clientUUID)
        let existingTripUUIDs       = try existingUUIDs(LocalTrip.self,           keyPath: \.clientUUID)
        let existingItineraryUUIDs  = try existingUUIDs(LocalItineraryItem.self,  keyPath: \.clientUUID)
        let existingExpenseUUIDs    = try existingStringUUIDs(LocalExpense.self,  keyPath: \.clientUUID)
        let existingVocabUUIDs      = try existingUUIDs(LocalKeyword.self,        keyPath: \.clientUUID)

        return [
            .tasks:         counts(payload.tasks.map(\.clientUUID),         existing: existingTodoUUIDs),
            .notes:         counts(payload.notes.map(\.clientUUID),         existing: existingNoteUUIDs),
            .noteFolders:   counts(payload.noteFolders.map(\.clientUUID),   existing: existingFolderUUIDs),
            .lists:         counts(payload.lists.map(\.clientUUID),         existing: existingListUUIDs),
            .itineraries:   counts(payload.itineraries.map(\.clientUUID),   existing: existingTripUUIDs),
            .itineraryDays: counts(payload.itineraryDays.map(\.clientUUID), existing: existingItineraryUUIDs),
            .expenses:      counts(payload.expenses.map(\.clientUUID),      existing: existingExpenseUUIDs),
            .vocab:         counts(payload.vocab.map(\.clientUUID),         existing: existingVocabUUIDs),
        ]
    }

    private func counts<ID: Hashable>(_ incoming: [ID], existing: Set<ID>) -> EntityCounts {
        var new = 0
        for id in incoming where !existing.contains(id) { new += 1 }
        return EntityCounts(total: incoming.count, new: new, skipped: incoming.count - new)
    }

    private func existingUUIDs<M: PersistentModel>(_ model: M.Type, keyPath: KeyPath<M, UUID>) throws -> Set<UUID> {
        let rows = try modelContext.fetch(FetchDescriptor<M>())
        return Set(rows.map { $0[keyPath: keyPath] })
    }

    private func existingStringUUIDs<M: PersistentModel>(_ model: M.Type, keyPath: KeyPath<M, String>) throws -> Set<String> {
        let rows = try modelContext.fetch(FetchDescriptor<M>())
        return Set(rows.map { $0[keyPath: keyPath] })
    }

    // MARK: - Commit

    /// Applies the preview's changes. Receipt files get written to disk
    /// inside the same transaction window; if the SwiftData save fails,
    /// the receipts written so far are rolled back so re-running the
    /// import after the error is still a clean no-op for the rows that
    /// did succeed.
    func commit(preview: Preview) throws {
        // Resolve existing UUIDs once up front. A second `fetch` after we
        // start `insert`ing would include the new rows.
        let existingTodoUUIDs       = try existingUUIDs(LocalTodo.self,           keyPath: \.clientUUID)
        let existingNoteUUIDs       = try existingUUIDs(LocalNote.self,           keyPath: \.clientUUID)
        let existingFolderUUIDs     = try existingUUIDs(LocalNoteFolder.self,     keyPath: \.clientUUID)
        let existingListUUIDs       = try existingUUIDs(LocalList.self,           keyPath: \.clientUUID)
        let existingTripUUIDs       = try existingUUIDs(LocalTrip.self,           keyPath: \.clientUUID)
        let existingItineraryUUIDs  = try existingUUIDs(LocalItineraryItem.self,  keyPath: \.clientUUID)
        let existingExpenseUUIDs    = try existingStringUUIDs(LocalExpense.self,  keyPath: \.clientUUID)
        let existingVocabUUIDs      = try existingUUIDs(LocalKeyword.self,        keyPath: \.clientUUID)

        let payload = preview.manifest.data
        var writtenReceiptPaths: [String] = []

        do {
            for dto in payload.noteFolders where !existingFolderUUIDs.contains(dto.clientUUID) {
                modelContext.insert(LocalNoteFolder(
                    clientUUID: dto.clientUUID,
                    name: dto.name,
                    position: dto.position,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    needsSync: false
                ))
            }

            for dto in payload.tasks where !existingTodoUUIDs.contains(dto.clientUUID) {
                modelContext.insert(LocalTodo(
                    clientUUID: dto.clientUUID,
                    title: dto.title,
                    todoDescription: dto.description,
                    completed: dto.completed,
                    dueDate: dto.dueDate,
                    tag: dto.tag,
                    position: dto.position,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    needsSync: false
                ))
            }

            for dto in payload.notes where !existingNoteUUIDs.contains(dto.clientUUID) {
                modelContext.insert(LocalNote(
                    clientUUID: dto.clientUUID,
                    folderClientUUID: dto.folderClientUUID,
                    title: dto.title,
                    content: dto.content,
                    position: dto.position,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    needsSync: false
                ))
            }

            // Lists: re-attach list items by `listClientUUID` and preserve
            // order via `position`. We only attach items for lists that
            // are being newly inserted; lists that already exist keep
            // their on-device items as-is (skip semantics).
            let itemsByList: [UUID: [DataArchive.ListItemDTO]] = Dictionary(grouping: payload.listItems, by: \.listClientUUID)
            for dto in payload.lists where !existingListUUIDs.contains(dto.clientUUID) {
                let rawItems = (itemsByList[dto.clientUUID] ?? []).sorted { $0.position < $1.position }
                let items = rawItems.map { ChecklistItem(text: $0.text, checked: $0.checked) }
                modelContext.insert(LocalList(
                    clientUUID: dto.clientUUID,
                    title: dto.title,
                    items: items,
                    position: dto.position,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    needsSync: false
                ))
            }

            for dto in payload.itineraries where !existingTripUUIDs.contains(dto.clientUUID) {
                modelContext.insert(LocalTrip(
                    clientUUID: dto.clientUUID,
                    name: dto.name,
                    startDate: dto.startDate,
                    endDate: dto.endDate,
                    notes: dto.notes,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt
                ))
            }

            for dto in payload.itineraryDays where !existingItineraryUUIDs.contains(dto.clientUUID) {
                let kind = ItineraryKind(rawValue: dto.kind) ?? .activity
                modelContext.insert(LocalItineraryItem(
                    clientUUID: dto.clientUUID,
                    tripUUID: dto.tripClientUUID,
                    dayDate: dto.dayDate,
                    kind: kind,
                    title: dto.title,
                    notes: dto.notes,
                    startTime: dto.startTime,
                    endDate: dto.endDate,
                    endTime: dto.endTime,
                    sortOrder: dto.sortOrder,
                    googleMapsLink: dto.googleMapsLink ?? "",
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt
                ))
            }

            for dto in payload.expenses where !existingExpenseUUIDs.contains(dto.clientUUID) {
                let restoredPath = try restoreReceipt(for: dto, archiveEntries: preview.entries)
                if let restoredPath { writtenReceiptPaths.append(restoredPath) }

                modelContext.insert(LocalExpense(
                    clientUUID: dto.clientUUID,
                    date: dto.date,
                    category: dto.category,
                    merchant: dto.merchant,
                    expenseDescription: dto.expenseDescription,
                    originalAmount: dto.originalAmount,
                    originalCurrency: dto.originalCurrency,
                    sgdAmount: dto.sgdAmount,
                    fxRate: dto.fxRate,
                    paymentMethod: dto.paymentMethod,
                    receiptImagePath: restoredPath ?? dto.receiptImagePath,
                    source: dto.source,
                    createdAt: dto.createdAt,
                    isRefund: dto.isRefund ?? false,
                    needsSync: false,
                    version: 0
                ))
            }

            for dto in payload.vocab where !existingVocabUUIDs.contains(dto.clientUUID) {
                modelContext.insert(LocalKeyword(
                    clientUUID: dto.clientUUID,
                    term: dto.term,
                    notes: dto.notes,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt
                ))
            }

            try modelContext.save()
            Haptics.light()
        } catch {
            modelContext.rollback()
            for path in writtenReceiptPaths {
                try? receiptStorage.delete(relativePath: path)
            }
            throw ImportError.commitFailed(error)
        }
    }

    /// Restore a receipt's image bytes from the archive. Returns the
    /// relative path now persisted on disk (e.g. `"receipts/<uuid>.jpg"`)
    /// or `nil` if the archive didn't include the file. We honour the
    /// stored relative path exactly so the round-trip is byte-identical:
    /// the same path that was on `LocalExpense.receiptImagePath` at
    /// export time is what we write back. If a different file already
    /// occupies that path on this device (e.g. user ran the importer
    /// after a partial reset), the existing file wins — receipts are
    /// content-addressed by UUID, collisions on the same UUID mean the
    /// same logical image.
    private func restoreReceipt(
        for expense: DataArchive.ExpenseDTO,
        archiveEntries: [String: Data]
    ) throws -> String? {
        guard let relativePath = expense.receiptImagePath,
              !relativePath.isEmpty,
              let archivedData = archiveEntries[relativePath] else {
            return nil
        }
        if receiptStorage.load(relativePath: relativePath) != nil {
            return relativePath
        }
        return try receiptStorage.write(data: archivedData, relativePath: relativePath)
    }
}
