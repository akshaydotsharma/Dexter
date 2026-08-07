import Foundation

/// Conversions across the wall-clock storage boundary used by ticket and
/// itinerary times.
///
/// ### Why times are stored this way
///
/// A ticket states a LOCAL time at its own location: a flight boards at 19:00 in
/// Milan whatever timezone the phone is in. Storing that as a real instant means
/// the displayed time moves when the device timezone changes, which is exactly
/// what #163 / #168 were about. So the stored `Date` is an ANCHOR, not an
/// instant: its components in a UTC calendar are the printed local time. A
/// UTC-pinned display formatter (`TimelineEntry.itineraryTimeFormatter`) then
/// renders precisely what was on the ticket, anywhere in the world.
///
/// Extracted from the itinerary editor's private helpers (#398) so the wallet
/// editor writes byte-identical values rather than carrying a second copy that
/// could drift. The itinerary editor now delegates here; behaviour is unchanged.
enum WallClock {

    /// Picker → storage. Read the (hour, minute) of `timeFrom` in the DEVICE
    /// calendar (what the picker shows), then build a Date on `onDay`'s calendar
    /// day with those same components anchored in UTC.
    static func utcAnchor(onDay: Date, timeFrom: Date) -> Date {
        let local = Calendar.current
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = local.dateComponents([.year, .month, .day], from: onDay)
        let time = local.dateComponents([.hour, .minute], from: timeFrom)
        var comps = DateComponents()
        comps.year = day.year
        comps.month = day.month
        comps.day = day.day
        comps.hour = time.hour
        comps.minute = time.minute
        comps.second = 0
        return utc.date(from: comps) ?? timeFrom
    }

    /// Storage → picker. Inverse of `utcAnchor`: read the (hour, minute) of a
    /// stored anchor in a UTC calendar, then build a DEVICE-local Date carrying
    /// those components on `onDay`'s local calendar day, so a `DatePicker`
    /// surfaces the stated time.
    static func devicePickerDate(onDay: Date, anchor: Date) -> Date {
        let local = Calendar.current
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let time = utc.dateComponents([.hour, .minute], from: anchor)
        return local.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: 0,
            of: onDay
        ) ?? onDay
    }

    /// Drop the seconds a `DatePicker` never showed, in the DEVICE calendar.
    ///
    /// Unrelated to the UTC anchoring above — this one is about *granularity*, not
    /// about which timezone a stated time belongs to. A `Date` is an instant, so it
    /// always carries seconds and a fraction of a second, but a picker configured
    /// `[.date, .hourAndMinute]` lets nobody see or set them. Whatever the value was
    /// seeded with therefore survives into storage: a task editor opening on
    /// `Date().addingTimeInterval(3600)` stored a due time of `16:28:44.910929` for
    /// a 4:28 PM pick (#444).
    ///
    /// That is invisible until something compares or schedules against it. It made
    /// reminders fire most of a minute late, and it makes two tasks that both read
    /// "4:28 PM" sort by a difference nobody can see. So a value that came from a
    /// minute-granularity picker is stored at minute granularity.
    ///
    /// Truncates rather than rounds: 4:28 means the moment 4:28 begins.
    static func minutePrecision(_ date: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: parts) ?? date
    }
}
