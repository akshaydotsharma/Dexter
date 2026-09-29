import Foundation

/// Whether a task's due date carries an hour, and what follows from that (#657).
///
/// ### Why this is derived and not stored
///
/// A task used to be forced to have a time: the editor showed one picker for
/// both halves, so every due date carried an hour whether the person meant one
/// or not. Letting the Time switch go off needs an answer to "does this one
/// have an hour", and there are two ways to get it.
///
/// A stored `Bool` on `LocalTodo` would be a new column, a backfill for every
/// existing row, and a field an older peer does not know about — which it would
/// write back as NULL on the next sync, exactly the shape of #428. A derived
/// answer costs none of that.
///
/// So the convention is the one the itinerary already uses: **a due date at
/// exactly local midnight means that day, with no hour**. Every task that
/// exists today was written through a picker seeded an hour ahead of now, so
/// they all read as timed, and nothing has to be repaired.
///
/// ### A deliberate 12:00 AM (#683)
///
/// That leaves one moment the convention cannot say: a task the person meant
/// to be due AT midnight. It used to read as having no time at all. Closing it
/// with a column costs the schema change above, so it is closed with a second
/// convention instead: **a deliberate 12:00 AM is stored one second past
/// midnight** (`deliberateMidnightOffset`).
///
/// Nothing else can produce that value. Every timed writer goes through
/// `normalised`, which truncates to the minute first, so the only non-zero
/// second a stored due date can carry is this one. And one second is below
/// everything that reads the value: the row and the calendar print hours and
/// minutes, so it shows "12:00 AM"; a reminder fires at the START of its
/// minute (`TaskReminderScheduler.fireDate`), so it fires at midnight; and
/// `isSet` already said "not exactly midnight", so it needed no change.
///
/// The rule for a writer is therefore one line: never store a timed due date
/// without passing it through `normalised(_:hasTime: true)`. A raw
/// `WallClock.minutePrecision` on a timed value would fold the second away
/// and turn a 12:00 AM task back into a dayless one.
///
/// The convention is not new. `TaskCalendarPopover` has read a midnight due
/// time as "no particular time" since it was written; what #657 changed is that
/// the editor can now MEAN it. This type is that rule, pulled into one place.
///
/// One type rather than four call sites, because "has a time", "what to store"
/// and "when is it late" have to agree, and they agree here or nowhere.
enum TaskDueTime {

    /// True when this due date names an hour.
    static func isSet(on due: Date, calendar: Calendar = .current) -> Bool {
        due != calendar.startOfDay(for: due)
    }

    /// What goes into storage.
    ///
    /// Minute precision when there is a time — `Date()` carries seconds and a
    /// fraction of one that no picker shows and that would otherwise ride into
    /// the store (#444). Local midnight when there is not, which is the whole
    /// convention above.
    ///
    /// A time that lands on midnight is pushed one second past it, so it still
    /// reads as a time (#683). See "A deliberate 12:00 AM" above.
    static func normalised(_ due: Date, hasTime: Bool, calendar: Calendar = .current) -> Date {
        guard hasTime else { return calendar.startOfDay(for: due) }
        let minute = WallClock.minutePrecision(due)
        guard minute == calendar.startOfDay(for: minute) else { return minute }
        return minute.addingTimeInterval(deliberateMidnightOffset)
    }

    /// The repaired due date for a row written before #683, or nil to leave it.
    ///
    /// Before #683 a deliberate 12:00 AM was stored at exactly midnight, the
    /// same value as "no time". Most such rows cannot be told apart, but one
    /// kind can: a row with an armed reminder. #657 offers the reminder only
    /// once Time is on and clears it when Time goes off, so a midnight row
    /// with `remindMe` set was a deliberate 12:00 AM. Those rows move to the
    /// sentinel; every other row is left alone.
    static func repairedDeliberateMidnight(
        _ due: Date?, remindMe: Bool, calendar: Calendar = .current
    ) -> Date? {
        guard remindMe, let due, !isSet(on: due, calendar: calendar) else { return nil }
        return normalised(due, hasTime: true, calendar: calendar)
    }

    /// How far past midnight a deliberate 12:00 AM is stored (#683).
    ///
    /// One second: below the minute that every display and the reminder
    /// scheduler read at, and a value no minute-granularity picker produces.
    static let deliberateMidnightOffset: TimeInterval = 1

    /// The moment the task stops being "not yet due".
    ///
    /// With an hour, that is the hour. Without one, it is the END of the day: a
    /// task due Thursday is not late at one minute past midnight on Thursday,
    /// and colouring it red all day would make the one colour that means
    /// "overdue" mean "due today" as well.
    static func overdueAfter(_ due: Date, calendar: Calendar = .current) -> Date {
        guard !isSet(on: due, calendar: calendar) else { return due }
        let day = calendar.startOfDay(for: due)
        return calendar.date(byAdding: .day, value: 1, to: day) ?? due
    }
}
