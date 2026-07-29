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
}
