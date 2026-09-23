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
/// The edge is real and small: a person who deliberately sets 12:00 AM gets a
/// task that reads as having no time. It is a display difference on a value
/// nobody picks, and it costs a schema change to close.
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
    static func normalised(_ due: Date, hasTime: Bool, calendar: Calendar = .current) -> Date {
        hasTime
            ? WallClock.minutePrecision(due)
            : calendar.startOfDay(for: due)
    }

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
