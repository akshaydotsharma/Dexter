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
        let descriptor = FetchDescriptor<LocalTaskTicket>(
            predicate: #Predicate { $0.todoClientUUID == todoId && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.position, order: .forward)]
        )
        return try store.context.fetch(descriptor).map { $0.toDTO() }
    }

    /// Count per task for a set of tasks, so the Tasks and Today lists can show a
    /// pass chip without loading any bytes.
    func counts(todoIds: Set<UUID>) throws -> [UUID: Int] {
        guard !todoIds.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<LocalTaskTicket>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        var out: [UUID: Int] = [:]
        for row in try store.context.fetch(descriptor) where todoIds.contains(row.todoClientUUID) {
            out[row.todoClientUUID, default: 0] += 1
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
        taskTitle: String,
        extraction: TaskTicketExtraction? = nil
    ) async throws -> TaskTicketRead {
        let extraction = extraction ?? TaskTicketExtraction()
        return try await extraction.read(data: data, isPDF: isPDF, taskTitle: taskTitle)
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
        let extraction = extraction ?? TaskTicketExtraction()
        let id = try extraction.attach(ticket, toTodo: todoId, context: store.context)
        touchTodo(todoId)
        return id
    }

    /// Attach several tickets in order, for flushing what the editor was holding
    /// once the task it belongs to exists.
    ///
    /// Each is attempted independently: one bad row should not strand the others,
    /// and the task has already been created by this point either way.
    @discardableResult
    func attachAll(_ tickets: [TaskTicket], todoId: UUID) -> [UUID] {
        var stored: [UUID] = []
        for ticket in tickets {
            do {
                stored.append(try attach(ticket, todoId: todoId))
            } catch {
                NSLog("TaskTicketService: could not attach a pending ticket: %@",
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
        try? storage.delete(relativePath: ticket.attachmentPath)
    }

    /// Convenience for callers that already have a task: read then attach.
    @discardableResult
    func add(
        todoId: UUID,
        taskTitle: String,
        data: Data,
        isPDF: Bool,
        extraction: TaskTicketExtraction? = nil
    ) async throws -> UUID {
        let read = try await read(data: data, isPDF: isPDF, taskTitle: taskTitle, extraction: extraction)
        return try attach(read.ticket(todoId: todoId), todoId: todoId, extraction: extraction)
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
        meta: TicketMeta? = nil
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

        row.updatedAt = Date()
        try store.context.save()
        touchTodo(row.todoClientUUID)
        return row.toDTO()
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
        row.deletedAt = Date()
        row.updatedAt = Date()
        try store.context.save()
        // A file that is already gone is not an error worth surfacing: the row is
        // detached either way, which is what the user asked for.
        try? storage.delete(relativePath: path)
        touchTodo(ticket.todoId)
    }

    /// Detach every ticket on a task. Called when the task itself is deleted so
    /// its tickets don't outlive it as orphaned rows and files.
    func deleteAll(todoId: UUID) throws {
        let descriptor = FetchDescriptor<LocalTaskTicket>(
            predicate: #Predicate { $0.todoClientUUID == todoId && $0.deletedAt == nil }
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

    /// Bump the task's `updatedAt` so attaching, editing or removing a ticket
    /// counts as editing the task, then tell the rest of the app the store moved.
    ///
    /// Without the `updatedAt` bump, sync would not see the task as changed and
    /// any surface sorted on `updatedAt` would not move it. Without the
    /// notification, the pass chip on the Tasks and Today rows would keep its old
    /// count until those views happened to reload — they refresh off
    /// `localStoreDidChange` and nothing else here would post it.
    private func touchTodo(_ todoId: UUID) {
        let descriptor = FetchDescriptor<LocalTodo>(
            predicate: #Predicate { $0.clientUUID == todoId }
        )
        if let todo = try? store.context.fetch(descriptor).first {
            todo.updatedAt = Date()
            try? store.context.save()
        }
        NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
    }
}
