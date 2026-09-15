import SwiftUI

/// The month grid, in an anchored popover from Today's date control (#565).
///
/// ### Why a popover and not an inline block
///
/// Today's first job is logging today. A calendar that sat in the tab would push
/// the composer down the screen every time it was on show, and a section that
/// expanded in place was already rejected on this surface: the user asked for a
/// local popover instead. So the grid is a detour — it opens over the tab, it
/// answers one question, and picking a day closes it and leaves the tab looking
/// the way it did.
///
/// ### Why it wraps `MealCalendarCard` rather than replacing it
///
/// The grid is the same grid #559 built and tested: the month arithmetic, the
/// leap-February handling, the future-day rule, the quantity bar that spends no
/// hue. None of that changes because the frame around it did. This type adds the
/// popover's width and presentation and nothing else.
///
/// The card draws its own `surface` and border inside the popover, which is the
/// house pattern — `TaskCalendarPopover` and `TripCalendarPopover` both present a
/// raised bordered card the same way.
struct MealCalendarPopover: View {

    @Binding var month: Date
    @Binding var selectedDay: Date
    let readings: [Date: MealDayReading]
    var today: Date = Date()

    /// Matches `TaskCalendarPopover`, so the two calendars in this app are the
    /// same size in the same kind of container. Seven columns inside it leave
    /// about 40 pt a square, which holds a four-digit calorie figure.
    private let contentWidth: CGFloat = 340

    var body: some View {
        MealCalendarCard(
            month: $month,
            selectedDay: $selectedDay,
            readings: readings,
            today: today
        )
        .frame(width: contentWidth)
        .presentationBackground(Tokens.surface)
        // Without this an iPhone renders a popover as a sheet, which is the
        // full-screen commitment this is deliberately not.
        .presentationCompactAdaptation(.popover)
    }
}
