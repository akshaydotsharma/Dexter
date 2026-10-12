import Foundation
import SwiftData

/// Writes Dexter-only decisions about calendar events (#689): hide from the
/// Planner, decline in Dexter, and undo either. Nothing here touches EventKit;
/// the source calendar never changes and the organiser is never told.
@MainActor
struct EventOverrideService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) { self.store = store }

    static func `default`() -> EventOverrideService { EventOverrideService(store: .shared) }

    enum Scope: Equatable {
        /// This occurrence only (the same as the whole event when it does not repeat).
        case occurrence
        /// Every occurrence of a repeating event.
        case series
    }

    enum OverrideError: Error { case noEventKey }

    /// The occurrence a decision is stored against. Nil for the series, and
    /// nil for an event that does not repeat, so a moved one-off still matches.
    static func occurrenceStart(for event: PlannerEvent, scope: Scope) -> Date? {
        guard scope == .occurrence, event.isRecurring else { return nil }
        return event.occurrenceDate ?? event.start
    }

    /// Record a decision. The id is derived, so repeating it revives the one
    /// row rather than adding a duplicate.
    @discardableResult
    func set(_ action: EventOverrideAction, for event: PlannerEvent, scope: Scope) throws -> LocalEventOverride {
        guard !event.eventKey.isEmpty else { throw OverrideError.noEventKey }
        let occ = Self.occurrenceStart(for: event, scope: scope)
        let id = EventOverrideID.make(action: action, eventKey: event.eventKey, occurrenceStart: occ)
        if let existing = try row(id: id) {
            existing.deletedAt = nil
            existing.title = event.title
            existing.eventStart = event.start
            existing.calendarTitle = event.calendarTitle
            existing.appliesToSeries = occ == nil && event.isRecurring
            existing.updatedAt = Date()
            try store.context.save()
            return existing
        }
        let row = LocalEventOverride(
            clientUUID: id, eventKey: event.eventKey, occurrenceStart: occ, action: action,
            title: event.title, eventStart: event.start, calendarTitle: event.calendarTitle,
            appliesToSeries: occ == nil && event.isRecurring
        )
        store.context.insert(row)
        try store.context.save()
        return row
    }

    // MARK: Move (#697)

    /// The id of an event's move. One per occurrence (one per event when it
    /// does not repeat), so moving it again updates the one row.
    static func moveID(for event: PlannerEvent) -> String {
        EventOverrideID.make(action: .moved, eventKey: event.eventKey,
                             occurrenceStart: occurrenceStart(for: event, scope: .occurrence))
    }

    /// Show the event at `start` in Dexter only, with its own length. The
    /// calendar never changes. Moving it back to its calendar start removes
    /// the move instead, so a reset by dragging leaves no row behind.
    /// `event` may already be moved: its calendar start is `movedFrom`.
    @discardableResult
    func move(_ event: PlannerEvent, to start: Date) throws -> LocalEventOverride? {
        guard !event.eventKey.isEmpty else { throw OverrideError.noEventKey }
        let calendarStart = event.movedFrom ?? event.start
        if abs(start.timeIntervalSince(calendarStart)) < 1 {
            try resetMove(for: event)
            return nil
        }
        let occ = Self.occurrenceStart(for: event, scope: .occurrence)
        let id = Self.moveID(for: event)
        let now = Date()
        if let existing = try row(id: id) {
            existing.deletedAt = nil
            existing.action = EventOverrideAction.moved.rawValue
            existing.eventKey = EventOverrideMove.storedKey(event.eventKey)
            existing.movedStart = start
            existing.eventStart = start
            existing.title = event.title
            existing.calendarTitle = event.calendarTitle
            existing.appliesToSeries = false
            existing.updatedAt = now
            try store.context.save()
            return existing
        }
        let row = LocalEventOverride(
            clientUUID: id, eventKey: EventOverrideMove.storedKey(event.eventKey), occurrenceStart: occ,
            action: .moved, title: event.title, eventStart: start, calendarTitle: event.calendarTitle,
            createdAt: now, updatedAt: now, movedStart: start
        )
        store.context.insert(row)
        try store.context.save()
        return row
    }

    /// "Reset to calendar time": soft delete the event's move.
    func resetMove(for event: PlannerEvent) throws {
        try remove(id: Self.moveID(for: event))
    }

    /// Soft delete: Undo, and Restore from Settings.
    func remove(id: String) throws {
        guard let r = try row(id: id), r.deletedAt == nil else { return }
        r.deletedAt = Date()
        r.updatedAt = Date()
        try store.context.save()
    }

    /// "Undo decline": every live Dexter decline that matches this event,
    /// series and occurrence alike, so the event reads as not declined.
    func clearDecline(for event: PlannerEvent) throws {
        let now = Date()
        for r in try live() where r.actionEnum == .declined && r.rule.matches(event) {
            r.deletedAt = now
            r.updatedAt = now
        }
        try store.context.save()
    }

    func live() throws -> [LocalEventOverride] {
        try store.context.fetch(FetchDescriptor<LocalEventOverride>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
    }

    func row(id: String) throws -> LocalEventOverride? {
        try store.context.fetch(FetchDescriptor<LocalEventOverride>(
            predicate: #Predicate { $0.clientUUID == id }
        )).first
    }
}
