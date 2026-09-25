import Foundation
import SwiftData

/// When a habit is due (#661).
///
/// Raw `String` values stored on the model, so a rule added later ("N times a
/// week" is the v2 candidate) cannot renumber the ones already in the store.
enum HabitSchedule: String, CaseIterable, Codable, Sendable {
    /// Every day.
    case daily
    /// Only on the weekdays set in `LocalHabit.weekdayMask`.
    case weekdays

    var label: String {
        switch self {
        case .daily:    return "Every day"
        case .weekdays: return "Some days"
        }
    }
}

/// What a check-in row says about its day (#661).
///
/// Only two values are ever STORED. Partial is not one of them: it is derived
/// from `count` against the habit's target, so raising a target turns
/// yesterday's "done" into "partial" without rewriting a row. Missed is not
/// stored either, ever. It is the absence of a row on a day that was due.
enum HabitCheckInStatus: String, Codable, Sendable {
    /// Progress was logged. Done or partial depending on `count`.
    case done
    /// The user chose to skip the day. Neutral: it neither extends nor breaks a
    /// streak, and it is not in the completion rate.
    case skipped
}

/// A daily habit (#661).
///
/// A brand-new `@Model`, the safe kind of SwiftData migration: it creates one
/// table and touches nothing beside it.
///
/// ### Why this is not a `RecurringTask`
///
/// A recurring task keeps ONE open occurrence and walks its cursor past any day
/// that went by, so the store never records a miss. A habit's whole value is the
/// record of misses and streaks, so it needs one row per day it was acted on,
/// and a pure derivation (`HabitLedger`) that can say "due, and nothing logged".
///
/// ### Defaults are on the declarations
///
/// Every stored property carries its default inline (#555). A new table does not
/// strictly need them, but the first field added to this model later will, and
/// the pattern is cheaper to keep than to remember.
@Model
final class LocalHabit {
    /// Stable identity. A lowercased UUID string, like `RecurringTask`, because
    /// the check-in rows key on it as a string.
    @Attribute(.unique) var clientUUID: String = UUID().uuidString.lowercased()

    var name: String = ""

    /// One emoji, or empty. The row falls back to a colour dot when empty.
    var emoji: String = ""

    /// `HabitColor.rawValue`. Stored raw so a new colour needs no migration, and
    /// read back through a resolver that falls back rather than trapping.
    var colorKey: String = "gold"

    /// `HabitSchedule.rawValue`.
    var schedule: String = "daily"

    /// Which weekdays a `.weekdays` habit is due on, as a bitmask: bit 0 =
    /// Sunday ... bit 6 = Saturday. The same Sunday-based mask
    /// `RecurringTask.weekdayMask` uses, so a rule does not change meaning when
    /// the device moves to a locale whose week starts on Monday. Ignored by
    /// `.daily`.
    var weekdayMask: Int = 0b111_1111

    /// How many a day counts as done. 1 for a yes/no habit; 8 for "8 glasses".
    var targetCount: Int = 1

    /// Optional unit for a count habit ("glasses"). Nil for a yes/no habit.
    var unit: String? = nil

    /// The first day the habit is due, as a UTC day ANCHOR (#506).
    ///
    /// Days before it are neutral, never missed. Written through
    /// `WallClock.dayAnchor(from:)` and read through `WallClock.deviceDay(from:)`
    /// before any device-local formatter.
    var startDay: Date = Date(timeIntervalSince1970: 0)

    /// Set when the habit is archived. An archived habit keeps its history and
    /// leaves the Today card and the active list.
    var archivedAt: Date? = nil

    /// Soft delete. A soft-deleted row still syncs, so the delete reaches the
    /// other device as an upsert rather than depending on a tombstone.
    var deletedAt: Date? = nil

    /// Order on the Today card and in the section, ascending.
    var sortIndex: Int = 0

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        clientUUID: String = UUID().uuidString.lowercased(),
        name: String,
        emoji: String = "",
        colorKey: String = "gold",
        schedule: String = HabitSchedule.daily.rawValue,
        weekdayMask: Int = 0b111_1111,
        targetCount: Int = 1,
        unit: String? = nil,
        startDay: Date,
        archivedAt: Date? = nil,
        deletedAt: Date? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.name = name
        self.emoji = emoji
        self.colorKey = colorKey
        self.schedule = schedule
        self.weekdayMask = weekdayMask
        self.targetCount = targetCount
        self.unit = unit
        self.startDay = startDay
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Typed view of `schedule`. An unreadable value falls back to daily.
    var scheduleEnum: HabitSchedule {
        HabitSchedule(rawValue: schedule) ?? .daily
    }

    var isArchived: Bool { archivedAt != nil }

    /// The value-type rule the ledger reads. The ledger never sees the model.
    var rule: HabitRule {
        HabitRule(
            schedule: scheduleEnum,
            weekdayMask: weekdayMask,
            targetCount: max(1, targetCount),
            startDay: startDay
        )
    }
}

/// One habit's record for one day (#661).
///
/// ### One row per habit per day
///
/// `clientUUID` is DERIVED from the habit and the day
/// (`HabitCheckInID.make`), not minted. Two consequences, both intended:
///
/// 1. A second write for the same day finds the row and updates it. The service
///    never inserts twice, and even if it did, the unique id would collapse the
///    pair instead of storing two answers for one day.
/// 2. The phone and the Mac checking off the same day produce the SAME record,
///    so sync resolves it by last-write-wins on one row instead of shipping two
///    rows that disagree.
///
/// Clearing a day sets `deletedAt` rather than deleting the row, so a later
/// check-in on that day revives the same record.
@Model
final class LocalHabitCheckIn {
    @Attribute(.unique) var clientUUID: String = ""

    /// `LocalHabit.clientUUID`.
    var habitUUID: String = ""

    /// The calendar day, as a UTC day ANCHOR (#506).
    var day: Date = Date(timeIntervalSince1970: 0)

    /// How many were logged. 1 for a done yes/no habit.
    var count: Int = 0

    /// `HabitCheckInStatus.rawValue`.
    var status: String = "done"

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil

    init(
        clientUUID: String,
        habitUUID: String,
        day: Date,
        count: Int = 0,
        status: String = HabitCheckInStatus.done.rawValue,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.clientUUID = clientUUID
        self.habitUUID = habitUUID
        self.day = day
        self.count = count
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var statusEnum: HabitCheckInStatus {
        HabitCheckInStatus(rawValue: status) ?? .done
    }

    /// The value-type view the ledger reads.
    var entry: HabitDayEntry {
        HabitDayEntry(count: count, status: statusEnum)
    }
}

/// Builds the one id a (habit, day) pair can have.
enum HabitCheckInID {
    /// `<habitUUID>-<yyyyMMdd>`, read from the anchor's UTC components, so the
    /// id does not depend on the timezone of the device that writes it.
    static func make(habitUUID: String, day: Date) -> String {
        let parts = WallClock.dayCalendar.dateComponents([.year, .month, .day], from: day)
        let y = parts.year ?? 0, m = parts.month ?? 0, d = parts.day ?? 0
        return String(format: "%@-%04d%02d%02d", habitUUID.lowercased(), y, m, d)
    }
}
