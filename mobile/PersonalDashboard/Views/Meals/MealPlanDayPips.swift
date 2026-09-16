import SwiftUI

/// Fixed metrics for the Plan tab's two calendars (#599).
///
/// Held here rather than as literals inside the two views for the reason every
/// other metrics table in this app gives: the week cell and the month cell are
/// read side by side as the scope is switched, and a change to one that is not a
/// change to the other is the kind of drift nobody notices until a row clips.
enum MealPlanMetrics {
    /// Height of one square in the month grid.
    ///
    /// 32, well under the Tracking calendar's 48, and the gap is earned: that
    /// cell carries a numeral, a calorie figure and a quantity bar, and this one
    /// carries a numeral and four 5pt pips.
    ///
    /// The height is the whole reason this number is tuned rather than copied.
    /// The grid is the FIRST thing on the tab now, not a popover, so six rows of
    /// it are paid for out of the space the day's meals need: at 42 the tiles
    /// started below the fold of a 652pt window, which made a calendar put there
    /// to orient you the thing you had to scroll past.
    static let monthCell: CGFloat = 32
    /// Height of one day cell in the week strip. Taller: it carries a weekday,
    /// a numeral and the pips, and it is the cell the user actually aims at.
    static let weekCell: CGFloat = 60
    /// Gap between squares, in both calendars.
    static let gutter: CGFloat = Space.xs
    /// One month stops widening past this, matching `MealCalendarMetrics.maxWidth`
    /// so the two calendars in this section are the same object at the same size.
    static let maxWidth: CGFloat = 460
    /// How much of the card's width one month takes, until the cap bites. The
    /// remainder is what the two neighbouring months show through.
    static let pageFraction: CGFloat = 0.62
    /// Gap between months in the reel.
    static let pageGutter: CGFloat = Space.lg
    /// How much of a neighbouring month is left visible. Enough to read the
    /// month's name and the shape of its weeks; not enough to be mistaken for
    /// something you can act on.
    static let neighbourOpacity: Double = 0.3
    /// How far back a neighbouring month sits.
    static let neighbourScale: CGFloat = 0.9
    /// How far a neighbouring month is turned, in degrees.
    ///
    /// Moderate on purpose. Past about 40 degrees a grid of numerals stops
    /// reading as a month and becomes texture, and the point of showing the
    /// neighbours is that you can see WHICH months they are.
    static let neighbourTilt: Double = 34
    /// How strong the vanishing point is. Higher is a wider lens: the turn
    /// reads at a smaller angle, at the cost of the near edge ballooning.
    static let reelPerspective: CGFloat = 0.6
    /// How long one step takes. Long enough to be seen as a direction, short
    /// enough that holding the chevron still steps at a usable rate.
    static let slideDuration: Double = 0.28
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
