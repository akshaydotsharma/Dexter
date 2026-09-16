import SwiftUI

/// Fixed metrics for the Plan tab's two calendars (#599).
///
/// Held here rather than as literals inside the two views for the reason every
/// other metrics table in this app gives: the week cell and the month cell are
/// read side by side as the scope is switched, and a change to one that is not a
/// change to the other is the kind of drift nobody notices until a row clips.
enum MealPlanMetrics {
    /// Height of one square in the month grid. Shorter than the Tracking
    /// calendar's 48, because this cell carries a numeral and four pips rather
    /// than a numeral, a calorie figure and a bar.
    static let monthCell: CGFloat = 42
    /// Height of one day cell in the week strip. Taller: it carries a weekday,
    /// a numeral and the pips, and it is the cell the user actually aims at.
    static let weekCell: CGFloat = 60
    /// Gap between squares, in both calendars.
    static let gutter: CGFloat = Space.xs
    /// The month grid stops widening past this, matching
    /// `MealCalendarMetrics.maxWidth` so the two calendars in this section are
    /// the same object at the same size.
    static let maxWidth: CGFloat = 460
    /// Diameter of one meal-type pip.
    static let pip: CGFloat = 5
    /// Gap between pips.
    static let pipGutter: CGFloat = 3
}

/// The four marks under a day, one per meal type (#599).
///
/// ### Why four pips and not a count
///
/// "3 planned" does not answer the question a plan calendar is for. The user
/// wants to know WHICH meal is still blank, and a count cannot say: three blocks
/// could be breakfast, lunch and dinner, or it could be three snacks on a day
/// with nothing to eat in it. Four pips in a fixed order answer it without a
/// number, at a size a calendar square can afford.
///
/// ### Why they are tinted
///
/// Hue on every other Meals surface means a VERDICT about a quantity, and is
/// spent carefully for that reason. These are the meal-type identity hues, which
/// `Tokens.mealTypeBreakfast` establishes as a family the verdict palette never
/// enters, so a filled pip cannot be read as "this meal went well". There is no
/// verdict available here anyway: a planned meal has not been eaten.
///
/// Position, not colour, is what identifies a pip. The order never changes and
/// an uncovered slot keeps its place, so the row reads the same way at every
/// size and in greyscale.
struct MealPlanDayPips: View {
    let reading: MealPlanReading

    var body: some View {
        HStack(spacing: MealPlanMetrics.pipGutter) {
            ForEach(MealType.allCases) { type in
                Circle()
                    .fill(reading.coveredTypes.contains(type) ? type.tint : Color.clear)
                    .frame(width: MealPlanMetrics.pip, height: MealPlanMetrics.pip)
                    .overlay {
                        if !reading.coveredTypes.contains(type) {
                            Circle().stroke(Tokens.mutedSoft.opacity(0.55), lineWidth: 0.5)
                        }
                    }
            }
        }
        // The pips repeat what the cell's accessibility label already says in
        // words, so a reader that announced them too would say everything twice.
        .accessibilityHidden(true)
    }

    /// What a day's plan reads as, in words. Shared by both calendars so the
    /// two cannot describe the same day differently.
    ///
    /// Says which meals are MISSING rather than which are present, once the day
    /// has anything on it at all. That is the actionable half: a user checking a
    /// plan by ear is looking for the gap, and "breakfast, lunch and dinner
    /// planned" makes them work out the fourth themselves.
    static func spokenSummary(_ reading: MealPlanReading) -> String {
        if reading.isEmpty { return "nothing planned" }
        if reading.counted == 0 {
            return "\(reading.skipped) skipped, nothing else planned"
        }

        var parts: [String] = []
        if reading.isComplete {
            parts.append("all four meals planned")
        } else {
            let missing = MealType.allCases
                .filter { !reading.coveredTypes.contains($0) }
                .map { $0.displayName.lowercased() }
            parts.append("\(reading.counted) planned, no \(missing.joined(separator: " or "))")
        }
        if reading.eaten > 0 { parts.append("\(reading.eaten) eaten") }
        if reading.skipped > 0 { parts.append("\(reading.skipped) skipped") }
        return parts.joined(separator: ", ")
    }
}
