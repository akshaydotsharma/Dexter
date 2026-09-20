import SwiftUI

/// One day's plan, as four tiles (#599).
///
/// ### Why a grid and not a column of sections
///
/// The plan is four things and the question it answers is "which of them is
/// still empty". A column answers that only by scrolling to the end of each
/// section; four tiles answer it at a glance. The grid is adaptive, so a phone
/// gets one column and a Mac detail pane gets two or three, and the tile order
/// is the order of an actual day in every case.
///
/// ### Why the day's total carries no verdict
///
/// Every other total on this surface is read against a target and tinted:
/// `MealStatPill` draws amber for under, green for on track, red for over. That
/// is right for a day that has HAPPENED, where falling short is a fact about the
/// day.
///
/// A plan is different in a way that matters. A half-planned day is the normal
/// state of a plan, so a verdict would paint amber on almost every day almost
/// all of the time, and a warning that is always on is a warning nobody reads.
/// Worse, it would be naming the wrong shortage: the day is not short on
/// calories, it is short on PLANNING, and those want opposite responses.
///
/// So the figures are neutral and the reading is one plain sentence about what
/// is left to plan. The verdict arrives on Tracking, once the meals are real.
struct MealPlanBoard: View {
    let plan: MealPlanDay
    let targets: MealTargets?
    /// Injected so a preview or a test can pin "now".
    var today: Date = Date()

    var onAdd: (MealType) -> Void
    var onOpen: (LocalMealPlanEntry) -> Void
    var onLogEntry: (LocalMealPlanEntry) -> Void
    var onDeleteEntry: (LocalMealPlanEntry) -> Void
    /// Copy another day's plan onto this one. The offset is in days, so -1 is
    /// the day before and -7 is this day last week.
    var onCopyDay: (Int) -> Void
    var onClearDay: () -> Void

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            header
            if plan.blocksWithNutrition > 0 { dayTotals }
            // Stacked, not a grid. The blocks inside need the full pane: a dish
            // name, four figures and a row of ingredient pills do not fit across
            // half a window without truncating one of the three. See the note on
            // `MealPlanTile`.
            VStack(alignment: .leading, spacing: MealPlanBoardMetrics.gutter) {
                ForEach(plan.slots) { slot in
                    MealPlanTile(
                        slot: slot,
                        onAdd: { onAdd(slot.mealType) },
                        onOpen: onOpen,
                        onLog: onLogEntry,
                        onDelete: onDeleteEntry
                    )
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            // One line, not two. The calendar above this already carries the
            // month and the selected square, so repeating the full date here
            // would state the same fact twice within one screen.
            VStack(alignment: .leading, spacing: 2) {
                Text(dayTitle)
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                Text(Self.longDate.string(from: plan.day))
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: Space.sm)
            dayMenu
        }
    }

    /// Copy and Clear, behind one glyph beside the day they act on.
    ///
    /// Copy was a labelled button in the action bar and read as noise: it sat
    /// beside the chat with no day attached to it, so "Copy" was a verb with no
    /// object. Here it names its source ("Copy yesterday's plan here") and sits
    /// next to the day it will write to, which is the whole of what it was
    /// missing.
    ///
    /// It is a menu rather than two buttons because both actions are bulk writes
    /// that are easy to reach for by accident: a copy onto the wrong day leaves
    /// blocks to delete one at a time.
    private var dayMenu: some View {
        Menu {
            Button {
                onCopyDay(-1)
            } label: {
                Label("Copy yesterday's plan here", systemImage: "arrow.left.arrow.right")
            }
            Button {
                onCopyDay(-7)
            } label: {
                Label("Copy this day last week", systemImage: "calendar.badge.clock")
            }
            if !plan.isEmpty {
                Divider()
                Button(role: .destructive, action: onClearDay) {
                    Label("Clear this day", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Tokens.mutedSoft)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyleCompat()
        .accessibilityLabel("More actions for this day")
    }

    /// "Today", "Tomorrow", "Yesterday" or the weekday. The full date sits under
    /// it in every case, so the relative word never has to carry which week.
    private var dayTitle: String {
        if calendar.isDate(plan.day, inSameDayAs: today) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: today)),
           calendar.isDate(plan.day, inSameDayAs: tomorrow) { return "Tomorrow" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: today)),
           calendar.isDate(plan.day, inSameDayAs: yesterday) { return "Yesterday" }
        return Self.weekday.string(from: plan.day)
    }

    // MARK: - What the day adds up to

    private var dayTotals: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.xs) {
                Text("Planned").eyebrow()
                Spacer(minLength: 0)
                if plan.blocksWithoutNutrition > 0 {
                    MealFlagChip(
                        "\(plan.blocksWithoutNutrition) without numbers",
                        systemImage: "questionmark.circle",
                        tint: Tokens.muted
                    )
                }
            }

            // The headline figure, then the four macros as pills. The same shape
            // `MealChatCard` uses, so a planned day and a logged meal present
            // their numbers as one object rather than as two designs.
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(MealFormat.calories(plan.totals.calories))
                    .font(.edDisplay)
                    .foregroundStyle(Tokens.ink)
                    .monospacedDigit()
                Text("kcal")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Planned total, \(MealFormat.calories(plan.totals.calories)) kilocalories")

            HStack(spacing: Space.sm) {
                ForEach(Nutrient.macrosInOrder) { nutrient in
                    MealStatPill(
                        label: nutrient.displayName,
                        value: MealFormat.value(plan.totals[nutrient], for: nutrient),
                        variant: .neutral,
                        fillsWidth: true
                    )
                }
            }

            if let line = remainingLine {
                Text(line)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    /// "About 800 kcal and 60 g protein still to plan", or nil with no targets.
    ///
    /// Nil rather than a zero: an unset target is not a target of zero, and
    /// printing "0 left to plan" would read as a day already full.
    private var remainingLine: String? {
        guard let targets else { return nil }
        let calories = targets.calories - plan.totals.calories
        let protein = targets.proteinG - plan.totals.proteinG
        let caloriePart = calories >= 0
            ? "about \(MealFormat.calories(calories)) kcal"
            : "about \(MealFormat.calories(-calories)) kcal over"
        let proteinPart = protein > 0
            ? "\(MealFormat.grams(protein)) g protein"
            : "protein target already covered"
        return calories >= 0
            ? "\(caloriePart) and \(proteinPart) still to plan."
            : "\(caloriePart), \(proteinPart)."
    }

    // MARK: - Formatters
    //
    // `plan.day` is a device-local midnight, never a stored anchor, so a
    // device-local formatter is correct (#506).

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy"
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()
}
