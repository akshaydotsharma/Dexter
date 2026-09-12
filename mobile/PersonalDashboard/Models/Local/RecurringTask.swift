import Foundation
import SwiftData

/// How often a `RecurringTask` comes back (#524).
///
/// Raw `String` values, stored on the model rather than an `Int`, so a rule added
/// later cannot renumber the ones already in the store.
enum RecurrenceFrequency: String, CaseIterable, Codable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly

    var label: String {
        switch self {
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        }
    }

    /// The noun the interval field counts, e.g. "every 2 **weeks**".
    func unit(plural: Bool) -> String {
        switch self {
        case .daily:   return plural ? "days" : "day"
        case .weekly:  return plural ? "weeks" : "week"
        case .monthly: return plural ? "months" : "month"
        case .yearly:  return plural ? "years" : "year"
        }
    }
}

/// A recurring-task TEMPLATE (#524). Defines a task that comes back on a rule
/// once; `RecurringTaskService` materialises it into a real `LocalTodo` as each
/// date enters the template's lead window.
///
/// This is a template, NOT a task — it never appears in the Tasks list itself.
/// The rows it generates are ordinary `LocalTodo`s carrying this template's
/// `clientUUID`, so they complete, edit, sort and bucket like any other task,
/// and are untouched when the template is later edited or deleted.
///
/// Deliberately shaped after `RecurringExpense` (#236), down to the `String`
/// `clientUUID` and the "every field additive with a default" rule that keeps
/// the SwiftData migration on existing installs lightweight.
///
/// ### What is different from the expense template
///
/// An expense posts ON its day and the user finds out afterwards. A task has to
/// arrive BEFORE its day or there is no time to act on it, which is what
/// `leadDays` is for, and only ONE occurrence is ever open at a time, which is
/// what stops a daily chore from stacking seven rows deep in the list.
@Model
final class RecurringTask {
    /// Stable identity. Generated locally on creation. Unique within the store.
    @Attribute(.unique) var clientUUID: String

    // MARK: - What the occurrence is
    //
    // Everything a generated `LocalTodo` needs, copied onto it at materialisation
    // time rather than referenced. A task edited after it appears keeps its own
    // edits, and a template edited later changes only what it makes next.

    var title: String
    /// Named `taskDescription`, not `description`, to avoid clashing with
    /// `CustomStringConvertible.description` (same reason as `LocalTodo`).
    var taskDescription: String?
    var tag: String?
    var priority: Int = 0
    var address: String = ""
    var googleMapsLink: String = ""
    /// Arm a reminder on each occurrence (#444). Every occurrence carries a due
    /// date by construction, so unlike on `LocalTodo` this can never be a flag
    /// with nothing to fire against.
    var remindMe: Bool = false

    // MARK: - The rule

    /// `RecurrenceFrequency.rawValue`. Stored raw so adding a frequency later
    /// needs no migration.
    var frequency: String

    /// Repeat every N of `frequency`'s unit. 1 = every day / week / month / year.
    /// Clamped to at least 1 on write.
    var interval: Int = 1

    /// Which weekdays a WEEKLY rule fires on, as a bitmask: bit 0 = Sunday …
    /// bit 6 = Saturday, matching `Calendar`'s 1-based `weekday` less one.
    ///
    /// A bitmask rather than `[Int]`: SwiftData stores a scalar array as an opaque
    /// blob, and an `Int` column is something a predicate and a migration can both
    /// see. 0 means "the weekday the start date falls on", so a weekly template
    /// created without touching the day picker still has a coherent rule.
    var weekdayMask: Int = 0

    /// Day of the month a MONTHLY or YEARLY rule fires on, 1...31. A value past
    /// the end of a short month is CLAMPED to that month's last day when the date
    /// is computed (so 31 fires on 28/29 Feb); the stored value is preserved.
    var dayOfMonth: Int = 1

    /// Month a YEARLY rule fires in, 1...12. Ignored by every other frequency.
    var monthOfYear: Int = 1

    /// Time of day the occurrence is due, as minutes past local midnight.
    ///
    /// Stored as an `Int`, not a `Date`. A task is due at "09:00 wherever I am",
    /// which is neither an instant nor the UTC-anchored wall clock a ticket needs
    /// (#168, #506) — it is a time of day, and an `Int` is the only one of the
    /// three storage shapes that cannot drift across a timezone change.
    var timeOfDayMinutes: Int = 9 * 60

    /// How many days before its due date an occurrence appears in the task list.
    ///
    /// 0 means it appears on the day. The occurrence is a real task from the
    /// moment it is created, so the existing buckets place it without any new
    /// code: a 3-day lead on a Thursday task shows up in This Week on Monday,
    /// in Tomorrow on Wednesday, then in Today.
    var leadDays: Int = 3

    // MARK: - Lifecycle

    /// Whether this template is live. A paused template creates nothing and is
    /// skipped by the materialiser until resumed.
    var isActive: Bool = true

    /// First day this template can fire on. A UTC-midnight day anchor
    /// (`WallClock.dayAnchor`), because it names a calendar day and not a moment.
    var startDate: Date

    /// Optional last day it fires on. Nil = open-ended. Also a day anchor.
    var endDate: Date?

    /// Cursor: the last date the materialiser has dealt with, as "yyyy-MM-dd".
    /// Nil = never run. The walk resumes from the date AFTER this one, so a
    /// normal pass never re-walks history and a date already skipped stays
    /// skipped.
    var lastOccurrenceKey: String?

    var createdAt: Date
    var updatedAt: Date

    // MARK: - Dead-field parity with the other local models
    //
    // Unused today; present so this model's columns line up with the rest and a
    // future migration never needs a destructive change.
    var needsSync: Bool = false
    var version: Int = 0

    init(
        clientUUID: String = UUID().uuidString.lowercased(),
        title: String,
        taskDescription: String? = nil,
        tag: String? = nil,
        priority: Int = 0,
        address: String = "",
        googleMapsLink: String = "",
        remindMe: Bool = false,
        frequency: String = RecurrenceFrequency.weekly.rawValue,
        interval: Int = 1,
        weekdayMask: Int = 0,
        dayOfMonth: Int = 1,
        monthOfYear: Int = 1,
        timeOfDayMinutes: Int = 9 * 60,
        leadDays: Int = 3,
        isActive: Bool = true,
        startDate: Date = Date(),
        endDate: Date? = nil,
        lastOccurrenceKey: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        needsSync: Bool = false,
        version: Int = 0
    ) {
        self.clientUUID = clientUUID
        self.title = title
        self.taskDescription = taskDescription
        self.tag = tag
        self.priority = priority
        self.address = address
        self.googleMapsLink = googleMapsLink
        self.remindMe = remindMe
        self.frequency = frequency
        self.interval = interval
        self.weekdayMask = weekdayMask
        self.dayOfMonth = dayOfMonth
        self.monthOfYear = monthOfYear
        self.timeOfDayMinutes = timeOfDayMinutes
        self.leadDays = leadDays
        self.isActive = isActive
        self.startDate = startDate
        self.endDate = endDate
        self.lastOccurrenceKey = lastOccurrenceKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.needsSync = needsSync
        self.version = version
    }

    // MARK: - Convenience

    /// Typed view of `frequency`. An unreadable stored value falls back to
    /// weekly rather than leaving the template with no rule at all.
    var frequencyEnum: RecurrenceFrequency {
        RecurrenceFrequency(rawValue: frequency) ?? .weekly
    }

    /// The rule in words, e.g. "Every 2 weeks on Mon, Fri at 09:00".
    /// Used by the Recurring list and by the read-only line on an occurrence.
    var ruleSummary: String {
        RecurrenceRule(template: self).summary
    }
}
