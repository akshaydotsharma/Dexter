import SwiftUI

/// The plan month grid, in an anchored popover from the section's date control
/// (#599).
///
/// The Plan tab used to carry its own Week/Month strip inline, above the day.
/// That was two calendars on one surface: the section chrome already has a date
/// control, and a second one below it pushed the day's content down the screen
/// every time it was on show. So the plan reuses the chrome control, exactly as
/// Tracking does, and this is the popover behind it.
///
/// It wraps `MealPlanMonthGrid` rather than `MealCalendarCard` for the ONE
/// reason those two views exist separately: this grid can reach a future month,
/// and it marks a day by which meals are planned rather than by how many
/// calories were logged. Everything about the frame is the same, which is the
/// point — the two calendars in this section should be the same object at the
/// same size, differing only in what they are a calendar OF.
struct MealPlanCalendarPopover: View {

    @Binding var month: Date
    @Binding var selectedDay: Date
    /// Every planned day, keyed by stored day anchor.
    let readings: [Date: MealPlanReading]
    var today: Date = Date()

    /// Matches `MealCalendarPopover`, so the two calendars in this section are
    /// the same size in the same kind of container.
    private let contentWidth: CGFloat = 340

    var body: some View {
        MealPlanMonthGrid(
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
