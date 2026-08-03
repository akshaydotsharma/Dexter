import Foundation
import SwiftData

/// Local-first store for a task's wallet-style ticket attachments (#399).
///
/// Mirrors `NoteImageService` (#395): reads and writes are scoped to one task, the
/// expensive compression runs off the main actor inside the extractor, and the
/// SwiftData work stays on it. Ingestion itself is delegated to
/// `TaskTicketExtraction`, which owns the persist → decode → extract pipeline.
@MainActor
struct TaskTicketService {
    let store: SwiftDataStore
    private let storage = TicketStorage.taskTickets

    init(store: SwiftDataStore = .shared) {
        self.store = store
    }

    // MARK: - Reads

    /// Tickets attached to `todoId`, in display order.
    func list(todoId: UUID) throws -> [TaskTicket] {
        try list(owner: .task(todoId))
    }

    /// Documents attached to any owner, in display order (#432).
    ///
    /// Filters on the owner id alone: a task's id and a trip stop's id are both
    /// freshly minted UUIDs, so one can never return the other's rows.
    func list(owner: TicketOwner) throws -> [TaskTicket] {
        let ownerID = owner.id
        let descriptor = FetchDescriptor<LocalTaskTicket>(
            predicate: #Predicate { $0.todoClientUUID == ownerID && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.position, order: .forward)]
        )
        return try store.context.fetch(descriptor).map { $0.toDTO() }
    }

    /// What a task's attachments amount to, for the list chip: how many, and whether
    /// any of them is actually a pass (#402, corrected #437).
    ///
    /// The chip has to know, because "TICKET" on a plain PDF is a claim the
    /// attachment does not support and the same picker now takes any document.
    ///
    /// This was `hasBarcode` and counted decoded payloads, which is the substitution
    /// #435 broke: a car rental voucher carries a QR that opens the rental company's
    /// manage-my-booking page, so the row called it a ticket while the Wallet had
    /// already stopped. It now reports the Wallet's own verdict, so the pill, the
    /// Today glyph and the shelf cannot disagree about what a pass is.
    struct Summary: Equatable {
        var count: Int
        var holdsAPass: Bool
    }

    /// Summary per owner for a set of records, so the Tasks, Today and trip
    /// timeline lists can show a chip without loading any bytes.
    ///
    /// Keyed on the owner id, which is what the caller already has, whether those
    /// ids are tasks' or trip stops' (#432).
    func counts(todoIds: Set<UUID>) throws -> [UUID: Summary] {
        guard !todoIds.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<LocalTaskTicket>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        var out: [UUID: Summary] = [:]
        for row in try store.context.fetch(descriptor) where todoIds.contains(row.todoClientUUID) {
            var summary = out[row.todoClientUUID] ?? Summary(count: 0, holdsAPass: false)
            summary.count += 1
            // The shared rule, not a copy of part of it. `belongsInWallet` decodes a
            // small JSON blob per row, which is the same cost the Wallet already pays
            // on every build and is nothing at personal scale.
            if row.belongsInWallet {
                summary.holdsAPass = true
            }
            out[row.todoClientUUID] = summary
        }
        return out
    }

    /// Resolve a ticket's stored relative path to an on-disk URL, or nil when the
    /// file is not on this device (synced from a peer, or lost to a reinstall).
    func fileURL(for ticket: TaskTicket) -> URL? {
        storage.load(relativePath: ticket.attachmentPath)
    }

    /// Fetch one ticket by id, for the detail and scan surfaces.
    func ticket(id: UUID) throws -> TaskTicket? {
        var descriptor = FetchDescriptor<LocalTaskTicket>(
            predicate: #Predicate { $0.clientUUID == id && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = 1
        return try store.context.fetch(descriptor).first?.toDTO()
    }

    // MARK: - Writes

    /// Ingest an uploaded image or PDF and attach it to `todoId`.
    ///
    /// Throws only when the file cannot be persisted or the task vanished
    /// mid-flight. A failed LLM read is NOT an error: the result comes back with
    /// `degraded` set and a row carrying the file plus whatever barcode was
    /// found, which the UI turns into manual entry.
    /// Store and read an upload, WITHOUT attaching it to anything yet.
    ///
    /// Split from `attach` (#399) so the caller can create the task from what the
    /// ticket says. Demanding a task title before accepting a ticket had the order
    /// backwards: the ticket is what tells you the title.
    ///
    /// `extraction` is injectable for tests. It is `nil`-defaulted rather than
    /// defaulted to a value because a default argument is evaluated in a
    /// nonisolated context, and `TaskTicketExtraction` is `@MainActor`.
    func read(
        data: Data,
        isPDF: Bool,
        context: TaskTicketContext,
        extraction: TaskTicketExtraction? = nil
    ) async throws -> TaskTicketRead {
        let extraction = extraction ?? TaskTicketExtraction()
        return try await extraction.read(data: data, isPDF: isPDF, context: context)
    }

    // MARK: - Duplicate detection (#408)

    /// The attachment already on this task that `data` would be a second copy of,
    /// or nil when the file is new to it.
    ///
    /// Runs BEFORE the file is stored or read, so a repeat costs neither a write nor
    /// an extraction call. It catches the case that actually happens: the attach
    /// appeared to do nothing, so it was done again. See `duplicate(ofBarcode:among:)`
    /// for the half of the problem this cannot see.
    func duplicate(of data: Data, among tickets: [TaskTicket]) -> TaskTicket? {
        let hash = SyncHash.hex(data)
        return tickets.first { $0.ticketMeta?.sourceHash == hash }
    }

    /// The attachment already on this task carrying the same barcode.
    ///
    /// The second half of the check, and it has to run AFTER the read because the
    /// payload is only known once Vision has decoded it. Two things need it: a row
    /// written before `sourceHash` existed carries no fingerprint at all, and the
    /// same ticket re-exported or re-screenshotted is a different byte stream
    /// entirely. What makes it safe is that a barcode is the ticket's own identity —
    /// two files scanning to the same payload admit you once.
    ///
    /// Empty payloads never match: "no barcode" is not an identity.
    func duplicate(ofBarcode payload: String, among tickets: [TaskTicket]) -> TaskTicket? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return tickets.first {
            $0.barcodePayload.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
    }

    /// Attach a ticket to a task, returning the id of the stored row.
    ///
    /// Takes the DTO rather than the read so that a ticket held unsaved in the task
    /// editor — and possibly edited there — is written as it stands.
    @discardableResult
    func attach(
        _ ticket: TaskTicket,
        todoId: UUID,
        extraction: TaskTicketExtraction? = nil
    ) throws -> UUID {
        try attach(ticket, owner: .task(todoId), extraction: extraction)
    }

    /// Attach a document to any owner, returning the id of the stored row (#432).
    @discardableResult
    func attach(
        _ ticket: TaskTicket,
        owner: TicketOwner,
        extraction: TaskTicketExtraction? = nil
    ) throws -> UUID {
        let extraction = extraction ?? TaskTicketExtraction()
        let id = try extraction.attach(ticket, to: owner, context: store.context)
        announce(owner)
        return id
    }

    /// Attach several tickets in order, for flushing what the editor was holding
    /// once the task it belongs to exists.
    ///
    /// Each is attempted independently: one bad row should not strand the others,
    /// and the task has already been created by this point either way.
    @discardableResult
    func attachAll(_ tickets: [TaskTicket], todoId: UUID) -> [UUID] {
        attachAll(tickets, owner: .task(todoId))
    }

    /// Same, for any owner: an editor composing a brand-new trip stop holds its
    /// documents until the stop is committed, exactly as the task editor does.
    @discardableResult
    func attachAll(_ tickets: [TaskTicket], owner: TicketOwner) -> [UUID] {
        var stored: [UUID] = []
        for ticket in tickets {
            do {
                stored.append(try attach(ticket, owner: owner))
            } catch {
                NSLog("TaskTicketService: could not attach a pending document: %@",
                      error.localizedDescription)
            }
        }
        return stored
    }

    /// Discard a ticket that was never attached, removing its stored file.
    ///
    /// The bytes land on disk during the read, before there is any task to hang them
    /// on, so abandoning the editor has to clean them up or they leak.
    func discardUnattached(_ ticket: TaskTicket) {
        discardStoredFile(at: ticket.attachmentPath)
    }

    /// Same, for a file whose read never got far enough to produce a ticket — the
    /// editor was dismissed while the read was still in flight.
    func discardStoredFile(at relativePath: String) {
        guard !relativePath.isEmpty else { return }
        try? storage.delete(relativePath: relativePath)
    }

    /// Convenience for callers that already have a task: read then attach.
    @discardableResult
    func add(
        todoId: UUID,
        context: TaskTicketContext,
        data: Data,
        isPDF: Bool,
        extraction: TaskTicketExtraction? = nil
    ) async throws -> UUID {
        try await add(owner: .task(todoId), context: context, data: data, isPDF: isPDF, extraction: extraction)
    }

    /// Convenience for callers that already have an owner: read then attach.
    @discardableResult
    func add(
        owner: TicketOwner,
        context: TaskTicketContext,
        data: Data,
        isPDF: Bool,
        extraction: TaskTicketExtraction? = nil
    ) async throws -> UUID {
        let read = try await read(data: data, isPDF: isPDF, context: context, extraction: extraction)
        return try attach(read.ticket(owner: owner), owner: owner, extraction: extraction)
    }

    /// Overwrite the user-editable fields on a ticket. Every extracted value is
    /// correctable, which is what makes an imperfect extraction acceptable.
    ///
    /// `nil` leaves a field untouched; a value (including "") overwrites it,
    /// matching the `TodoUpdateRequest` convention.
    @discardableResult
    func update(
        id: UUID,
        eventTitle: String? = nil,
        eventDate: Date?? = nil,
        startTimeText: String? = nil,
        venue: String? = nil,
        seat: String? = nil,
        gate: String? = nil,
        reference: String? = nil,
        meta: TicketMeta? = nil,
        attachmentPath: String? = nil
    ) throws -> TaskTicket? {
        var descriptor = FetchDescriptor<LocalTaskTicket>(
            predicate: #Predicate { $0.clientUUID == id && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = 1
        guard let row = try store.context.fetch(descriptor).first else { return nil }

        if let eventTitle { row.eventTitle = eventTitle }
        if let eventDate { row.eventDate = eventDate }
        if let startTimeText { row.startTimeText = startTimeText }
        if let venue { row.venue = venue }
        if let seat { row.seat = seat }
        if let gate { row.gate = gate }
        if let reference { row.reference = reference }
        if let meta { row.ticketMetaJSON = meta.isEmpty ? "" : meta.encodedString() }
        if let attachmentPath { row.attachmentPath = attachmentPath }

        row.updatedAt = Date()
        try store.context.save()
        announce(row.owner)
        return row.toDTO()
    }

    // MARK: - Upgrading an attachment in place (#420)

    /// Complete an attachment the task already has, from a richer copy of the same
    /// ticket.
    ///
    /// The case this exists for: a ticket was attached as a screenshot, which is all
    /// anyone had at the time, and later the real `.pkpass` turns up. The pass carries
    /// its street address, its admission type and the holder's email — none of which
    /// were in the photograph — and the duplicate check would otherwise refuse it,
    /// leaving the thinner card as the only version there will ever be. Refusing a
    /// BETTER copy of something you already have is the wrong answer.
    ///
    /// Only empty fields are filled. A value already on the row may have been typed or
    /// corrected by hand, and an import silently overwriting that is a worse failure
    /// than a stale field: the person cannot tell it happened. The one exception is the
    /// ingest fingerprint, which is deliberately replaced so a third attempt at the
    /// same pass is caught on the cheap byte check rather than after a full read.
    ///
    /// - Returns: `true` when something actually changed, so the caller can say
    ///   "updated" rather than "already attached". `false` leaves the row untouched.
    @discardableResult
    func enrich(_ existing: TaskTicket, from read: TaskTicketRead) throws -> Bool {
        let candidate = read.ticket(
            id: existing.id,
            owner: existing.owner,
            position: existing.position
        )

        /// A field worth writing: the row has nothing and the incoming copy does.
        func fill(_ current: String, _ incoming: String) -> String? {
            let now = current.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
            guard now.isEmpty, !next.isEmpty else { return nil }
            return next
        }

        let title = fill(existing.eventTitle, candidate.eventTitle)
        let time = fill(existing.startTimeText, candidate.startTimeText)
        let venue = fill(existing.venue, candidate.venue)
        let seat = fill(existing.seat, candidate.seat)
        let gate = fill(existing.gate, candidate.gate)
        let reference = fill(existing.reference, candidate.reference)
        let day: Date?? = (existing.eventDate == nil && candidate.eventDate != nil)
            ? .some(candidate.eventDate)
            : nil

        var meta = existing.ticketMeta ?? TicketMeta()
        let incoming = candidate.ticketMeta ?? TicketMeta()
        var metaChanged = false
        func fillMeta(_ current: inout String?, _ next: String?) {
            guard current == nil || current?.isEmpty == true, let next, !next.isEmpty else { return }
            current = next
            metaChanged = true
        }
        fillMeta(&meta.eventType, incoming.eventType)
        fillMeta(&meta.section, incoming.section)
        fillMeta(&meta.row, incoming.row)
        fillMeta(&meta.guestName, incoming.guestName)
        fillMeta(&meta.eventURL, incoming.eventURL)
        fillMeta(&meta.address, incoming.address)
        fillMeta(&meta.directionsURL, incoming.directionsURL)
        if (meta.fields ?? []).isEmpty, let fields = incoming.fields, !fields.isEmpty {
            meta.fields = fields
            metaChanged = true
        }
        if meta.presentedAtEntry == nil, let judged = incoming.presentedAtEntry {
            meta.presentedAtEntry = judged
            metaChanged = true
        }
        if let hash = incoming.sourceHash, meta.sourceHash != hash {
            meta.sourceHash = hash
            metaChanged = true
        }

        // The row adopts the new file only when it had none. Two files for one ticket
        // is a leak, so whichever copy is not kept goes back out.
        let adoptsFile = !existing.hasAttachment && !candidate.attachmentPath.isEmpty
        if !adoptsFile {
            discardStoredFile(at: candidate.attachmentPath)
        }

        let changed = title != nil || time != nil || venue != nil || seat != nil
            || gate != nil || reference != nil || day != nil || metaChanged || adoptsFile
        guard changed else { return false }

        _ = try update(
            id: existing.id,
            eventTitle: title,
            eventDate: day,
            startTimeText: time,
            venue: venue,
            seat: seat,
            gate: gate,
            reference: reference,
            meta: metaChanged ? meta : nil,
            attachmentPath: adoptsFile ? candidate.attachmentPath : nil
        )
        return true
    }

    /// Detach a ticket and remove its file.
    ///
    /// Soft-deletes the row so the delete propagates through sync the way every
    /// other entity's does, then removes the bytes: a tombstoned row will never be
    /// shown again, so keeping the file would just leak disk.
    func delete(_ ticket: TaskTicket) throws {
        let ticketID = ticket.id
        let descriptor = FetchDescriptor<LocalTaskTicket>(
            predicate: #Predicate { $0.clientUUID == ticketID }
        )
        guard let row = try store.context.fetch(descriptor).first else { return }
        let path = row.attachmentPath
        let owner = row.owner
        row.deletedAt = Date()
        row.updatedAt = Date()
        try store.context.save()
        // A file that is already gone is not an error worth surfacing: the row is
        // detached either way, which is what the user asked for.
        try? storage.delete(relativePath: path)
        announce(owner)
    }

    /// Detach every ticket on a task. Called when the task itself is deleted so
    /// its tickets don't outlive it as orphaned rows and files.
    func deleteAll(todoId: UUID) throws {
        try deleteAll(owner: .task(todoId))
    }

    /// Same for any owner. A trip stop is deleted outright rather than tombstoned,
    /// so without this its documents would survive it as rows pointing at nothing,
    /// with their files still on disk (#432).
    func deleteAll(owner: TicketOwner) throws {
        let ownerID = owner.id
        let descriptor = FetchDescriptor<LocalTaskTicket>(
            predicate: #Predicate { $0.todoClientUUID == ownerID && $0.deletedAt == nil }
        )
        let rows = try store.context.fetch(descriptor)
        guard !rows.isEmpty else { return }
        let now = Date()
        var paths: [String] = []
        for row in rows {
            paths.append(row.attachmentPath)
            row.deletedAt = now
            row.updatedAt = now
        }
        try store.context.save()
        for path in paths {
            try? storage.delete(relativePath: path)
        }
    }

    // MARK: - Internals

    /// Bump the owner's `updatedAt` so attaching, editing or removing a document
    /// counts as editing the record it hangs off, then tell the rest of the app the
    /// store moved.
    ///
    /// Without the `updatedAt` bump, sync would not see the owner as changed and
    /// any surface sorted on `updatedAt` would not move it. Without the
    /// notification, the chip on the Tasks, Today and trip timeline rows would keep
    /// its old count until those views happened to reload — they refresh off
    /// `localStoreDidChange` and nothing else here would post it.
    private func announce(_ owner: TicketOwner) {
        switch owner {
        case .task(let id):
            let descriptor = FetchDescriptor<LocalTodo>(
                predicate: #Predicate { $0.clientUUID == id }
            )
            if let todo = try? store.context.fetch(descriptor).first {
                todo.updatedAt = Date()
                try? store.context.save()
            }
        case .tripStop(let id):
            let descriptor = FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.clientUUID == id }
            )
            if let item = try? store.context.fetch(descriptor).first {
                item.updatedAt = Date()
                try? store.context.save()
            }
        }
        NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
    }
}
