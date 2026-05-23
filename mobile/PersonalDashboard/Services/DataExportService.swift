import Foundation
import SwiftData

/// Builds a `.zip` archive containing every entity in the SwiftData store
/// plus on-disk receipt images. Single entry point: `export(context:)`.
///
/// The output file is written to the system temp directory. Caller owns
/// presenting it via the share sheet and deleting it afterwards (the OS
/// will clean up the tmp dir eventually anyway).
@MainActor
final class DataExportService {

    enum ExportError: LocalizedError {
        case manifestEncodingFailed(Error)
        case archiveWriteFailed(Error)

        var errorDescription: String? {
            switch self {
            case .manifestEncodingFailed(let e): return "Couldn't encode manifest: \(e.localizedDescription)"
            case .archiveWriteFailed(let e):     return "Couldn't write archive: \(e.localizedDescription)"
            }
        }
    }

    private let modelContext: ModelContext
    private let receiptStorage: ReceiptStorage

    init(modelContext: ModelContext, receiptStorage: ReceiptStorage = .shared) {
        self.modelContext = modelContext
        self.receiptStorage = receiptStorage
    }

    /// Build the archive and return its on-disk URL. Filename follows
    /// `dexter-export-YYYY-MM-DD.zip`.
    func export() throws -> URL {
        let payload = try buildPayload()
        let manifest = DataArchive.Manifest(
            schemaVersion: DataArchive.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: Self.appVersion,
            data: payload
        )

        let manifestData: Data
        do {
            manifestData = try DataArchive.makeEncoder().encode(manifest)
        } catch {
            throw ExportError.manifestEncodingFailed(error)
        }

        var entries: [MiniZip.Entry] = [
            MiniZip.Entry(name: "manifest.json", data: manifestData)
        ]
        entries.append(contentsOf: collectReceiptEntries(for: payload.expenses))

        let url = Self.outputURL()
        do {
            try MiniZip.write(entries: entries, to: url)
        } catch {
            throw ExportError.archiveWriteFailed(error)
        }
        return url
    }

    // MARK: - Payload assembly

    private func buildPayload() throws -> DataArchive.Payload {
        let todos       = try modelContext.fetch(FetchDescriptor<LocalTodo>())
        let notes       = try modelContext.fetch(FetchDescriptor<LocalNote>())
        let folders     = try modelContext.fetch(FetchDescriptor<LocalNoteFolder>())
        let lists       = try modelContext.fetch(FetchDescriptor<LocalList>())
        let trips       = try modelContext.fetch(FetchDescriptor<LocalTrip>())
        let itineraryItems = try modelContext.fetch(FetchDescriptor<LocalItineraryItem>())
        let expenses    = try modelContext.fetch(FetchDescriptor<LocalExpense>())
        let vocab       = try modelContext.fetch(FetchDescriptor<LocalKeyword>())

        var listItems: [DataArchive.ListItemDTO] = []
        for list in lists {
            for (idx, item) in list.items.enumerated() {
                listItems.append(DataArchive.ListItemDTO(
                    listClientUUID: list.clientUUID,
                    position: idx,
                    text: item.text,
                    checked: item.checked
                ))
            }
        }

        return DataArchive.Payload(
            tasks: todos.map(Self.dto),
            notes: notes.map(Self.dto),
            noteFolders: folders.map(Self.dto),
            lists: lists.map(Self.dto),
            listItems: listItems,
            itineraries: trips.map(Self.dto),
            itineraryDays: itineraryItems.map(Self.dto),
            expenses: expenses.map(Self.dto),
            vocab: vocab.map(Self.dto)
        )
    }

    /// Collect receipt files referenced by expenses. Missing files are
    /// silently skipped — the importer treats a missing receipt the same
    /// way the existing app does, namely the expense row still appears
    /// but the thumbnail falls back to the empty state.
    private func collectReceiptEntries(for expenses: [DataArchive.ExpenseDTO]) -> [MiniZip.Entry] {
        var entries: [MiniZip.Entry] = []
        var seenPaths = Set<String>()
        for expense in expenses {
            guard let relativePath = expense.receiptImagePath,
                  !relativePath.isEmpty,
                  seenPaths.insert(relativePath).inserted else { continue }
            guard let url = receiptStorage.load(relativePath: relativePath),
                  let data = try? Data(contentsOf: url) else { continue }
            // `relativePath` is already "receipts/<uuid>.<ext>" so it maps
            // 1:1 onto an archive entry path. Keep the same shape on the
            // importer side so restored files land back in the right
            // Documents subdirectory.
            entries.append(MiniZip.Entry(name: relativePath, data: data))
        }
        return entries
    }

    // MARK: - DTO mapping

    private static func dto(_ todo: LocalTodo) -> DataArchive.TaskDTO {
        DataArchive.TaskDTO(
            clientUUID: todo.clientUUID,
            title: todo.title,
            description: todo.todoDescription,
            completed: todo.completed,
            dueDate: todo.dueDate,
            tag: todo.tag,
            position: todo.position,
            createdAt: todo.createdAt,
            updatedAt: todo.updatedAt,
            deletedAt: todo.deletedAt
        )
    }

    private static func dto(_ note: LocalNote) -> DataArchive.NoteDTO {
        DataArchive.NoteDTO(
            clientUUID: note.clientUUID,
            folderClientUUID: note.folderClientUUID,
            title: note.title,
            content: note.content,
            position: note.position,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            deletedAt: note.deletedAt
        )
    }

    private static func dto(_ folder: LocalNoteFolder) -> DataArchive.NoteFolderDTO {
        DataArchive.NoteFolderDTO(
            clientUUID: folder.clientUUID,
            name: folder.name,
            position: folder.position,
            createdAt: folder.createdAt,
            updatedAt: folder.updatedAt,
            deletedAt: folder.deletedAt
        )
    }

    private static func dto(_ list: LocalList) -> DataArchive.ListDTO {
        DataArchive.ListDTO(
            clientUUID: list.clientUUID,
            title: list.title,
            position: list.position,
            createdAt: list.createdAt,
            updatedAt: list.updatedAt,
            deletedAt: list.deletedAt
        )
    }

    private static func dto(_ trip: LocalTrip) -> DataArchive.ItineraryDTO {
        DataArchive.ItineraryDTO(
            clientUUID: trip.clientUUID,
            name: trip.name,
            startDate: trip.startDate,
            endDate: trip.endDate,
            notes: trip.notes,
            createdAt: trip.createdAt,
            updatedAt: trip.updatedAt
        )
    }

    private static func dto(_ item: LocalItineraryItem) -> DataArchive.ItineraryDayDTO {
        DataArchive.ItineraryDayDTO(
            clientUUID: item.clientUUID,
            tripClientUUID: item.tripUUID,
            dayDate: item.dayDate,
            kind: item.kind,
            title: item.title,
            notes: item.notes,
            startTime: item.startTime,
            endDate: item.endDate,
            endTime: item.endTime,
            sortOrder: item.sortOrder,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )
    }

    private static func dto(_ expense: LocalExpense) -> DataArchive.ExpenseDTO {
        DataArchive.ExpenseDTO(
            clientUUID: expense.clientUUID,
            date: expense.date,
            category: expense.category,
            merchant: expense.merchant,
            expenseDescription: expense.expenseDescription,
            originalAmount: expense.originalAmount,
            originalCurrency: expense.originalCurrency,
            sgdAmount: expense.sgdAmount,
            fxRate: expense.fxRate,
            paymentMethod: expense.paymentMethod,
            receiptImagePath: expense.receiptImagePath,
            source: expense.source,
            createdAt: expense.createdAt
        )
    }

    private static func dto(_ keyword: LocalKeyword) -> DataArchive.VocabDTO {
        DataArchive.VocabDTO(
            clientUUID: keyword.clientUUID,
            term: keyword.term,
            notes: keyword.notes,
            createdAt: keyword.createdAt,
            updatedAt: keyword.updatedAt
        )
    }

    // MARK: - Output URL / version helpers

    private static func outputURL() -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "dexter-export-\(formatter.string(from: Date())).zip"
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
