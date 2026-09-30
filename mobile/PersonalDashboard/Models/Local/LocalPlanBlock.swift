import Foundation
import SwiftData

/// One block of time the user planned in the Planner (#687).
///
/// A brand-new `@Model`, which is the safe kind of SwiftData migration: it
/// creates one table and touches none of the models beside it. Every property
/// carries its default ON THE DECLARATION (#555), so a later additive field
/// migrates the same way.
///
/// ### Two kinds, one table
///
/// - `manual`: a block typed by hand ("Focus: alert PRD 10am 1h"). It owns its
///   title and nothing else.
/// - `task`: a Dexter task placed into the plan. `taskUUID` names the
///   `LocalTodo`, and `title` is a copy of the task title at the moment it was
///   placed, so a block still reads correctly if the task is later deleted.
///
/// A placement is its own row rather than a field on `LocalTodo` because a plan
/// and a due date say different things. "Due Thursday" is a promise to someone;
/// "planned for Tuesday 11:30" is a private intention that moves freely. Writing
/// the plan into `dueDate` would make every re-plan look like a moved deadline,
/// and a new column on `LocalTodo` is a field an older peer writes back as NULL
/// on the next sync (#428).
///
/// ### Timed or day-only
///
/// `start` and `end` are absolute instants, like the calendar events the block
/// sits between. Both nil means the block is planned for `day` with no hour,
/// the same "on a day" idea a task due at midnight carries (#657). A day-only
/// block still has `durationMinutes`, which is what the day's capacity meter
/// counts.
///
/// `day` is ALWAYS set, anchored at UTC midnight via `WallClock.dayAnchor(from:)`
/// (#506). For a timed block it is the device-local day of `start`, so one
/// predicate finds every block of a day whatever its kind.
///
/// ### Private
///
/// Nothing here is written to any calendar. The block lives in the Dexter store,
/// the backup archive and the sync oplog, and nowhere else.
@Model
final class LocalPlanBlock {
    /// Stable identity. A `String`, like every model added after v1, so the
    /// archive and the oplog carry it verbatim.
    @Attribute(.unique) var clientUUID: String = ""

    /// `PlanBlockKind.rawValue`. Stored raw so a future kind does not force a
    /// migration; read through `kindEnum`, which falls back instead of trapping.
    var kind: String = "manual"

    var title: String = ""

    /// The calendar day, as a UTC day ANCHOR (#506). Read it back through
    /// `WallClock.deviceDay(from:)` before any device-local formatter.
    var day: Date = Date(timeIntervalSince1970: 0)

    /// Absolute start, or nil for a day-only block.
    var start: Date? = nil

    /// Absolute end, or nil for a day-only block.
    var end: Date? = nil

    /// Length in minutes. For a timed block it equals `end - start`; for a
    /// day-only block it is the estimate the capacity meter counts.
    var durationMinutes: Int = 30

    /// `LocalTodo.clientUUID.uuidString` for a `task` block, "" otherwise.
    var taskUUID: String = ""

    /// Free text from the details sheet (#687 round 3). Additive, with the
    /// default ON THE DECLARATION, so a store written before this field
    /// migrates with "" on every row (#555).
    var notes: String = ""

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil

    init(
        clientUUID: String = UUID().uuidString,
        kind: PlanBlockKind,
        title: String,
        day: Date,
        start: Date? = nil,
        end: Date? = nil,
        durationMinutes: Int = 30,
        taskUUID: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.clientUUID = clientUUID
        self.kind = kind.rawValue
        self.title = title
        self.day = day
        self.start = start
        self.end = end
        self.durationMinutes = durationMinutes
        self.taskUUID = taskUUID
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var kindEnum: PlanBlockKind { PlanBlockKind(rawValue: kind) ?? .manual }

    /// True when the block has an hour.
    var isTimed: Bool { start != nil && end != nil }
}

enum PlanBlockKind: String, Codable, Sendable {
    case manual
    case task
}
