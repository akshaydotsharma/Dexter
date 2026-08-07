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
    /// #319: ticket attachments travel in the archive alongside receipts.
    private let ticketStorage: TicketStorage
    /// #395: note image attachments, same again.
    private let noteImageStorage: ReceiptStorage
    /// #399: task ticket attachments, same deal. A separate instance because it
    /// reads from `Documents/task-tickets/` rather than `Documents/tickets/`.
    private let taskTicketStorage: TicketStorage
    /// #428: fetched trip cover photographs, from `Documents/trip-covers/`.
    private let tripCoverStorage: ReceiptStorage

    init(
        modelContext: ModelContext,
        receiptStorage: ReceiptStorage = .shared,
        ticketStorage: TicketStorage = .shared,
        noteImageStorage: ReceiptStorage = .noteImages,
        taskTicketStorage: TicketStorage = .taskTickets,
        tripCoverStorage: ReceiptStorage = .tripCovers
    ) {
        self.modelContext = modelContext
        self.receiptStorage = receiptStorage
        self.ticketStorage = ticketStorage
        self.noteImageStorage = noteImageStorage
        self.taskTicketStorage = taskTicketStorage
        self.tripCoverStorage = tripCoverStorage
    }

    /// One archive entry whose bytes have not been read yet: the name it will
    /// take inside the zip, and the on-disk file to read it from.
    ///
    /// This exists so path resolution and byte reading can sit on opposite sides
    /// of an actor hop. Resolution needs the `@MainActor` storage classes; the
    /// read does not need anything but the URL.
    private struct AttachmentSource {
        let name: String
        let url: URL
    }

    /// Build the archive and return its on-disk URL. Filename follows
    /// `dexter-export-YYYY-MM-DD.zip`.
    ///
    /// ## Why this is split across two actors (#309)
    ///
    /// macOS now runs this from a launch/foreground pass, so a synchronous
    /// main-actor archive build would freeze the window on a realistic store
    /// (the user's has 1541 expenses). The work divides cleanly:
    ///
    /// - **Stays on the main actor:** the 13 fetches and the DTO mapping.
    ///   `buildPayload` fetches against a `ModelContext`, which is
    ///   main-actor-confined, so those fetches cannot leave without a
    ///   background context or `@ModelActor`. That is a data-layer change,
    ///   filed as #334, and deliberately not attempted here.
    /// - **Stays on the main actor, and is cheap:** resolving attachment paths
    ///   to URLs, because `ReceiptStorage` and `TicketStorage` are
    ///   `@MainActor`. This is a `fileExists` stat per attachment and reads no
    ///   file contents.
    /// - **Moves off:** JSON-encoding the manifest, reading every receipt and
    ///   ticket off disk, building the zip, and writing it out. This is where
    ///   the time on a large store actually goes — the manifest is the whole
    ///   store serialised, and the attachments are the whole image corpus.
    ///
    /// So the main-actor hold goes from "the entire archive build" to "fetch,
    /// DTO mapping, and N stat calls". **It does not go to zero**, and callers
    /// that promise a fully non-blocking backup are overstating it.
    func export() async throws -> URL {
        // ---- Main actor: fetch, map, resolve. ----
        let payload = try buildPayload()
        let manifest = DataArchive.Manifest(
            schemaVersion: DataArchive.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: Self.appVersion,
            data: payload,
            // #319 self-verification. `models` lets the importer detect a model
            // omitted entirely, which a count alone cannot; `counts` is asserted
            // before any write; `excludedModels` records the deliberate gaps so
            // they don't read as the bug this ticket fixed.
            models: DataArchive.exportedModels,
            counts: Self.counts(for: payload),
            excludedModels: DataArchive.excludedModels
        )

        var attachments = resolveReceiptSources(for: payload.expenses)
        // #319: ticket files were never archived, so restoring an itinerary
        // item's `attachmentPath` would have pointed at a file that isn't
        // there. Same shape as receipts: the stored relative path
        // ("tickets/<uuid>.<ext>") maps 1:1 onto an archive entry path.
        // #398: wallet-card files live in the SAME `tickets/` directory as
        // itinerary tickets, so both entities' paths go through one de-duping
        // resolve. Note images (#395) and task tickets (#399) have their own
        // directories and keep their own passes.
        attachments.append(contentsOf: resolveTicketSources(
            paths: payload.itineraryDays.map(\.attachmentPath)
                + (payload.walletCards ?? []).map { $0.attachmentPath }
        ))
        // #395: note image attachments, same relative-path-to-entry-name shape.
        attachments.append(contentsOf: resolveNoteImageSources(for: payload.noteImages ?? []))
        // #399: same again for task tickets. Their bytes are the only route
        // between devices, since the sync oplog carries JSON and has no asset
        // transfer, so leaving them out of the archive would mean a ticket could
        // never leave the phone it was photographed on.
        attachments.append(contentsOf: resolveTaskTicketSources(for: payload.taskTickets ?? []))
        // #428: trip cover photographs. Their own `trip-covers/` directory, so
        // their own pass. Cheaper to carry than to re-fetch on the restoring
        // device, and the only cover bytes that ever leave this device.
        attachments.append(contentsOf: resolveTripCoverSources(for: payload.itineraries))

        let url = Self.outputURL()

        // ---- Off the main actor: encode, read bytes, zip, write. ----
        //
        // `Task.detached` rather than a bare `nonisolated async func`: this
        // target builds in Swift 5 language mode, where a nonisolated async
        // function's executor is not the guarantee it is under Swift 6, and
        // "off the main actor" is the entire point of this call. Same reasoning
        // and same shape as `ReceiptStorage.compress`, which is already invoked
        // this way.
        //
        // Everything captured is a value type: `manifest` is a tree of `Codable`
        // structs over `String`/`Date`/`UUID`/`Data`, `attachments` is an array
        // of two immutable fields, and `url` is a `URL`. No `ModelContext` and
        // no SwiftData model object crosses the boundary — that is what makes
        // the hop legal at all.
        try await Task.detached(priority: .utility) {
            try Self.buildArchive(manifest: manifest, attachments: attachments, to: url)
        }.value

        return url
    }

    /// Encode, read attachment bytes, and write the zip. Runs off the main
    /// actor; touches no actor-isolated state.
    ///
    /// `nonisolated` is required, not stylistic: `static` members of a
    /// `@MainActor` type are themselves main-actor-isolated by default, so
    /// without this the detached task would hop straight back to main and the
    /// split would silently do nothing.
    private nonisolated static func buildArchive(
        manifest: DataArchive.Manifest,
        attachments: [AttachmentSource],
        to url: URL
    ) throws {
        let manifestData: Data
        do {
            manifestData = try DataArchive.makeEncoder().encode(manifest)
        } catch {
            throw ExportError.manifestEncodingFailed(error)
        }

        var entries: [MiniZip.Entry] = [
            MiniZip.Entry(name: "manifest.json", data: manifestData)
        ]
        for attachment in attachments {
            // A file that vanished between resolution and read is skipped, which
            // is the same outcome the pre-split code produced when its
            // `Data(contentsOf:)` failed: the row still exports, and the
            // importer only sets the path when it actually restored a file.
            guard let data = try? Data(contentsOf: attachment.url) else { continue }
            entries.append(MiniZip.Entry(name: attachment.name, data: data))
        }

        do {
            try MiniZip.write(entries: entries, to: url)
        } catch {
            throw ExportError.archiveWriteFailed(error)
        }
    }

    // MARK: - Payload assembly

    /// Internal rather than private since #348: `SyncEngine` calls this to
    /// enumerate every synced record.
    ///
    /// Sharing it is the point. Sync and the backup archive now agree on what a
    /// record is by construction, so a model added to the archive joins sync for
    /// free, and a fidelity fix made for one benefits the other. The alternative
    /// (a second parallel set of fetches and DTO mappings inside sync) would
    /// drift the moment either side gained a field.
    func buildPayload() throws -> DataArchive.Payload {
        let todos       = try modelContext.fetch(FetchDescriptor<LocalTodo>())
        let notes       = try modelContext.fetch(FetchDescriptor<LocalNote>())
        let noteImages  = try modelContext.fetch(FetchDescriptor<LocalNoteImage>())
        let folders     = try modelContext.fetch(FetchDescriptor<LocalNoteFolder>())
        let lists       = try modelContext.fetch(FetchDescriptor<LocalList>())
        let trips       = try modelContext.fetch(FetchDescriptor<LocalTrip>())
        let itineraryItems = try modelContext.fetch(FetchDescriptor<LocalItineraryItem>())
        let expenses    = try modelContext.fetch(FetchDescriptor<LocalExpense>())
        let vocab       = try modelContext.fetch(FetchDescriptor<LocalKeyword>())
        // #319: five models that previously had no fetch at all.
        let recurring   = try modelContext.fetch(FetchDescriptor<RecurringExpense>())
        let persons     = try modelContext.fetch(FetchDescriptor<LocalPerson>())
        let events      = try modelContext.fetch(FetchDescriptor<LocalEvent>())
        let statements  = try modelContext.fetch(FetchDescriptor<LocalStatementImport>())
        let processed   = try modelContext.fetch(FetchDescriptor<LocalProcessedEmail>())
        // #399: task ticket attachments.
        let taskTickets = try modelContext.fetch(FetchDescriptor<LocalTaskTicket>())
        // #398: standalone wallet cards.
        let walletCards = try modelContext.fetch(FetchDescriptor<LocalWalletCard>())

        var listItems: [DataArchive.ListItemDTO] = []
        for list in lists {
            for (idx, item) in list.items.enumerated() {
                listItems.append(DataArchive.ListItemDTO(
                    listClientUUID: list.clientUUID,
                    position: idx,
                    text: item.text,
                    checked: item.checked,
                    url: item.url
                ))
            }
        }

        // Each array is bound to an explicitly-typed local before the
        // initialiser rather than mapped inline.
        //
        // `Self.dto` is seventeen overloads distinguished only by argument type,
        // and resolving all of them inside one initialiser call is what tipped
        // the type-checker over its time limit when the seventeenth arrived
        // (#398 on top of #395 and #399). Annotating each result removes the
        // overload search entirely, and keeps the next model from hitting it.
        let taskDTOs: [DataArchive.TaskDTO] = todos.map(Self.dto)
        let noteDTOs: [DataArchive.NoteDTO] = notes.map(Self.dto)
        let folderDTOs: [DataArchive.NoteFolderDTO] = folders.map(Self.dto)
        let listDTOs: [DataArchive.ListDTO] = lists.map(Self.dto)
        let tripDTOs: [DataArchive.ItineraryDTO] = trips.map(Self.dto)
        let itineraryDTOs: [DataArchive.ItineraryDayDTO] = itineraryItems.map(Self.dto)
        let expenseDTOs: [DataArchive.ExpenseDTO] = expenses.map(Self.dto)
        let vocabDTOs: [DataArchive.VocabDTO] = vocab.map(Self.dto)
        let recurringDTOs: [DataArchive.RecurringExpenseDTO] = recurring.map(Self.dto)
        let personDTOs: [DataArchive.PersonDTO] = persons.map(Self.dto)
        let eventDTOs: [DataArchive.EventDTO] = events.map(Self.dto)
        let statementDTOs: [DataArchive.StatementImportDTO] = statements.map(Self.dto)
        let processedDTOs: [DataArchive.ProcessedEmailDTO] = processed.map(Self.dto)
        let noteImageDTOs: [DataArchive.NoteImageDTO] = noteImages.map(Self.dto)
        let taskTicketDTOs: [DataArchive.TaskTicketDTO] = taskTickets.map(Self.dto)
        let walletCardDTOs: [DataArchive.WalletCardDTO] = walletCards.map(Self.dto)

        return DataArchive.Payload(
            tasks: taskDTOs,
            notes: noteDTOs,
            noteFolders: folderDTOs,
            lists: listDTOs,
            listItems: listItems,
            itineraries: tripDTOs,
            itineraryDays: itineraryDTOs,
            expenses: expenseDTOs,
            vocab: vocabDTOs,
            recurringExpenses: recurringDTOs,
            persons: personDTOs,
            events: eventDTOs,
            statementImports: statementDTOs,
            processedEmails: processedDTOs,
            // Argument order follows the declaration order in `Payload`, which
            // is why wallet cards sit between the processed emails and the note
            // images rather than at the end.
            walletCards: walletCardDTOs,
            noteImages: noteImageDTOs,
            taskTickets: taskTicketDTOs
        )
    }

    /// #319: per-model row counts written into the manifest and asserted on
    /// import before anything is written. Keys match `DataArchive.exportedModels`.
    private static func counts(for payload: DataArchive.Payload) -> [String: Int] {
        [
            "LocalTodo":            payload.tasks.count,
            "LocalTaskTicket":      payload.taskTickets?.count ?? 0,
            "LocalNote":            payload.notes.count,
            "LocalNoteImage":       payload.noteImages?.count ?? 0,
            "LocalNoteFolder":      payload.noteFolders.count,
            "LocalList":            payload.lists.count,
            "LocalTrip":            payload.itineraries.count,
            "LocalItineraryItem":   payload.itineraryDays.count,
            "LocalExpense":         payload.expenses.count,
            "LocalKeyword":         payload.vocab.count,
            "RecurringExpense":     payload.recurringExpenses?.count ?? 0,
            "LocalPerson":          payload.persons?.count ?? 0,
            "LocalEvent":           payload.events?.count ?? 0,
            "LocalStatementImport": payload.statementImports?.count ?? 0,
            "LocalProcessedEmail":  payload.processedEmails?.count ?? 0,
            "LocalWalletCard":      payload.walletCards?.count ?? 0,
        ]
    }

    /// Resolve receipt files referenced by expenses to on-disk URLs, without
    /// reading a single byte (#309 — the reads happen off the main actor in
    /// `buildArchive`).
    ///
    /// Missing files are silently skipped, which matches what the app already
    /// does elsewhere: the expense row still appears and the thumbnail falls
    /// back to the empty state.
    private func resolveReceiptSources(for expenses: [DataArchive.ExpenseDTO]) -> [AttachmentSource] {
        var sources: [AttachmentSource] = []
        var seenPaths = Set<String>()
        for expense in expenses {
            guard let relativePath = expense.receiptImagePath,
                  !relativePath.isEmpty,
                  seenPaths.insert(relativePath).inserted else { continue }
            guard let url = receiptStorage.load(relativePath: relativePath) else { continue }
            // `relativePath` is already "receipts/<uuid>.<ext>" so it maps
            // 1:1 onto an archive entry path. Keep the same shape on the
            // importer side so restored files land back in the right
            // Documents subdirectory.
            sources.append(AttachmentSource(name: relativePath, url: url))
        }
        return sources
    }

    /// #319 counterpart of `resolveReceiptSources` for ticket attachments.
    /// Missing files are skipped, matching the receipt behaviour: the importer
    /// only sets `attachmentPath` when it actually restored a file, so a skipped
    /// file yields a row that correctly reports no ticket.
    ///
    /// Takes bare relative paths rather than a DTO (#398) because two entities
    /// now reference the same `tickets/` directory: itinerary items and wallet
    /// cards. De-duping across BOTH in one call is the point — a card and a trip
    /// item pointing at the same file must not be written into the zip twice.
    private func resolveTicketSources(paths: [String?]) -> [AttachmentSource] {
        var sources: [AttachmentSource] = []
        var seenPaths = Set<String>()
        for path in paths {
            guard let relativePath = path,
                  !relativePath.isEmpty,
                  seenPaths.insert(relativePath).inserted else { continue }
            guard let url = ticketStorage.load(relativePath: relativePath) else { continue }
            sources.append(AttachmentSource(name: relativePath, url: url))
        }
        return sources
    }

    /// #395 counterpart for note image attachments. Missing files are skipped
    /// like receipts and tickets, and for the same reason: the row still travels,
    /// and the strip renders a "not on this device" tile for it rather than
    /// pretending the image is there.
    private func resolveNoteImageSources(for images: [DataArchive.NoteImageDTO]) -> [AttachmentSource] {
        var sources: [AttachmentSource] = []
        var seenPaths = Set<String>()
        for image in images {
            let relativePath = image.relativePath
            guard !relativePath.isEmpty,
                  seenPaths.insert(relativePath).inserted else { continue }
            guard let url = noteImageStorage.load(relativePath: relativePath) else { continue }
            sources.append(AttachmentSource(name: relativePath, url: url))
        }
        return sources
    }

    /// #399 counterpart for task ticket attachments. Same contract as the three
    /// above: a missing file is skipped rather than failing the export, and the
    /// importer only sets `attachmentPath` when it actually restored a file, so a
    /// skipped file yields a row that correctly reports no attachment.
    private func resolveTaskTicketSources(
        for tickets: [DataArchive.TaskTicketDTO]
    ) -> [AttachmentSource] {
        var sources: [AttachmentSource] = []
        var seenPaths = Set<String>()
        for ticket in tickets {
            let relativePath = ticket.attachmentPath
            guard !relativePath.isEmpty,
                  seenPaths.insert(relativePath).inserted else { continue }
            guard let url = taskTicketStorage.load(relativePath: relativePath) else { continue }
            sources.append(AttachmentSource(name: relativePath, url: url))
        }
        return sources
    }

    /// #428 counterpart for trip cover photographs. Same contract as the four
    /// above: a missing file is skipped rather than failing the export, and the
    /// importer only sets `coverImagePath` when it actually restored a file.
    ///
    /// Unlike a receipt or a ticket, a skipped cover is not even a small loss: the
    /// row still carries `coverImageSourceURL`, so the importing device re-fetches
    /// it on the next launch sweep. The bytes travel purely to save that round trip.
    private func resolveTripCoverSources(
        for trips: [DataArchive.ItineraryDTO]
    ) -> [AttachmentSource] {
        var sources: [AttachmentSource] = []
        var seenPaths = Set<String>()
        for trip in trips {
            guard let relativePath = trip.coverImagePath,
                  !relativePath.isEmpty,
                  seenPaths.insert(relativePath).inserted else { continue }
            guard let url = tripCoverStorage.load(relativePath: relativePath) else { continue }
            sources.append(AttachmentSource(name: relativePath, url: url))
        }
        return sources
    }

    // MARK: - DTO mapping

    private static func dto(_ image: LocalNoteImage) -> DataArchive.NoteImageDTO {
        DataArchive.NoteImageDTO(
            clientUUID: image.clientUUID,
            noteClientUUID: image.noteClientUUID,
            relativePath: image.relativePath,
            position: image.position,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            createdAt: image.createdAt,
            updatedAt: image.updatedAt,
            deletedAt: image.deletedAt
        )
    }

    /// #399. Every field is carried: a partial ticket DTO is exactly the class of
    /// bug #366 had to add an overwrite path for, where a lossy archive left rows
    /// that an insert-only merge could never heal.
    private static func dto(_ ticket: LocalTaskTicket) -> DataArchive.TaskTicketDTO {
        DataArchive.TaskTicketDTO(
            clientUUID: ticket.clientUUID,
            todoClientUUID: ticket.todoClientUUID,
            itineraryItemUUID: ticket.itineraryItemUUID,
            attachmentPath: ticket.attachmentPath,
            barcodePayload: ticket.barcodePayload,
            barcodeSymbology: ticket.barcodeSymbology,
            eventTitle: ticket.eventTitle,
            eventDate: ticket.eventDate,
            startTimeText: ticket.startTimeText,
            venue: ticket.venue,
            seat: ticket.seat,
            gate: ticket.gate,
            reference: ticket.reference,
            ticketMetaJSON: ticket.ticketMetaJSON,
            position: ticket.position,
            createdAt: ticket.createdAt,
            updatedAt: ticket.updatedAt,
            deletedAt: ticket.deletedAt
        )
    }

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
            deletedAt: todo.deletedAt,
            priority: todo.priority,
            address: todo.address,
            googleMapsLink: todo.googleMapsLink,
            remindMe: todo.remindMe,
            reminderClearedAt: todo.reminderClearedAt
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
            deletedAt: note.deletedAt,
            archivedAt: note.archivedAt,
            archivedWithFolderAt: note.archivedWithFolderAt
        )
    }

    private static func dto(_ folder: LocalNoteFolder) -> DataArchive.NoteFolderDTO {
        DataArchive.NoteFolderDTO(
            clientUUID: folder.clientUUID,
            name: folder.name,
            position: folder.position,
            createdAt: folder.createdAt,
            updatedAt: folder.updatedAt,
            deletedAt: folder.deletedAt,
            archivedAt: folder.archivedAt
        )
    }

    private static func dto(_ list: LocalList) -> DataArchive.ListDTO {
        DataArchive.ListDTO(
            clientUUID: list.clientUUID,
            title: list.title,
            position: list.position,
            createdAt: list.createdAt,
            updatedAt: list.updatedAt,
            deletedAt: list.deletedAt,
            iconName: list.iconName,
            colorHex: list.colorHex,
            archivedAt: list.archivedAt
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
            updatedAt: trip.updatedAt,
            participantsData: trip.participantsData,
            // #428. Every cover field is carried, including the device-local path:
            // the bytes go into the zip under that exact name, so a restore can put
            // the file back where the path already points.
            coverImagePath: trip.coverImagePath,
            coverImageSourceURL: trip.coverImageSourceURL,
            coverImageAttribution: trip.coverImageAttribution,
            coverImageAttributionURL: trip.coverImageAttributionURL,
            coverImageState: trip.coverImageState,
            coverArtPromptVersion: trip.coverArtPromptVersion
        )
    }

    private static func dto(_ item: LocalItineraryItem) -> DataArchive.ItineraryDayDTO {
        DataArchive.ItineraryDayDTO(
            clientUUID: item.clientUUID,
            tripClientUUID: item.tripUUID,
            dayDate: item.dayDate,
            kind: item.kind,
            transportMode: item.transportMode,
            title: item.title,
            notes: item.notes,
            startTime: item.startTime,
            endDate: item.endDate,
            endTime: item.endTime,
            sortOrder: item.sortOrder,
            googleMapsLink: item.googleMapsLink,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            arrivalTime: item.arrivalTime,
            address: item.address,
            dedupeKey: item.dedupeKey,
            sourceConfirmation: item.sourceConfirmation,
            attachmentPath: item.attachmentPath,
            barcodePayload: item.barcodePayload,
            barcodeSymbology: item.barcodeSymbology,
            seat: item.seat,
            gate: item.gate,
            venue: item.venue,
            ticketMetaJSON: item.ticketMetaJSON
        )
    }

    private static func dto(_ card: LocalWalletCard) -> DataArchive.WalletCardDTO {
        DataArchive.WalletCardDTO(
            clientUUID: card.clientUUID,
            kind: card.kind,
            title: card.title,
            dayDate: card.dayDate,
            startTime: card.startTime,
            arrivalTime: card.arrivalTime,
            endDate: card.endDate,
            endTime: card.endTime,
            notes: card.notes,
            venue: card.venue,
            address: card.address,
            googleMapsLink: card.googleMapsLink,
            seat: card.seat,
            gate: card.gate,
            sourceConfirmation: card.sourceConfirmation,
            attachmentPath: card.attachmentPath,
            barcodePayload: card.barcodePayload,
            barcodeSymbology: card.barcodeSymbology,
            ticketMetaJSON: card.ticketMetaJSON,
            createdAt: card.createdAt,
            updatedAt: card.updatedAt
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
            createdAt: expense.createdAt,
            isRefund: expense.isRefund,
            dedupeDescriptor: expense.dedupeDescriptor,
            tripUUID: expense.tripUUID,
            sourceReference: expense.sourceReference,
            statementLabel: expense.statementLabel,
            statementFileName: expense.statementFileName,
            personUUID: expense.personUUID,
            personName: expense.personName,
            eventUUID: expense.eventUUID,
            eventName: expense.eventName,
            numberOfShares: expense.numberOfShares,
            paidByPersonUUID: expense.paidByPersonUUID,
            splitsData: expense.splitsData,
            hiddenFromFinance: expense.hiddenFromFinance,
            hiddenFromTrip: expense.hiddenFromTrip,
            dedupeKey: expense.dedupeKey
        )
    }

    // MARK: DTO mapping for the models added in #319

    private static func dto(_ template: RecurringExpense) -> DataArchive.RecurringExpenseDTO {
        DataArchive.RecurringExpenseDTO(
            clientUUID: template.clientUUID,
            amount: template.amount,
            currency: template.currency,
            category: template.category,
            merchant: template.merchant,
            expenseDescription: template.expenseDescription,
            paymentMethod: template.paymentMethod,
            dayOfMonth: template.dayOfMonth,
            isActive: template.isActive,
            startDate: template.startDate,
            endDate: template.endDate,
            lastPostedMonthKey: template.lastPostedMonthKey,
            createdAt: template.createdAt,
            updatedAt: template.updatedAt
        )
    }

    private static func dto(_ person: LocalPerson) -> DataArchive.PersonDTO {
        DataArchive.PersonDTO(
            clientUUID: person.clientUUID,
            name: person.name,
            colorHex: person.colorHex,
            createdAt: person.createdAt
        )
    }

    private static func dto(_ event: LocalEvent) -> DataArchive.EventDTO {
        DataArchive.EventDTO(
            clientUUID: event.clientUUID,
            name: event.name,
            startDate: event.startDate,
            endDate: event.endDate,
            tripUUID: event.tripUUID,
            notes: event.notes,
            createdAt: event.createdAt,
            updatedAt: event.updatedAt
        )
    }

    private static func dto(_ record: LocalStatementImport) -> DataArchive.StatementImportDTO {
        DataArchive.StatementImportDTO(
            clientUUID: record.clientUUID,
            fileName: record.fileName,
            statementLabel: record.statementLabel,
            imported: record.imported,
            skippedDuplicates: record.skippedDuplicates,
            ignoredNonSpend: record.ignoredNonSpend,
            failed: record.failed,
            refunds: record.refunds,
            deposits: record.deposits,
            possiblyTruncated: record.possiblyTruncated,
            importedExpenseUUIDs: record.importedExpenseUUIDs,
            createdAt: record.createdAt
        )
    }

    private static func dto(_ email: LocalProcessedEmail) -> DataArchive.ProcessedEmailDTO {
        DataArchive.ProcessedEmailDTO(
            messageKey: email.messageKey,
            uid: email.uid,
            uidValidity: email.uidValidity,
            processedAt: email.processedAt
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
