import SwiftUI

/// One day's plan, in full (#599).
///
/// Four slots in the order of an actual day, each holding its blocks and an add
/// row. The skeleton is the same on an empty day as on a full one, so nothing
/// below the fold moves as blocks are added and an unplanned Lunch is visible
/// as a gap rather than as an absence.
///
/// ### Why the planned total carries no verdict
///
/// Every other total on this surface is read against a target and tinted:
/// `MealStatPill` draws amber for under, green for on track, red for over. That
/// is right for a day that has HAPPENED, where falling short is a fact about
/// the day.
///
/// A plan is different in a way that matters. A half-planned day is the normal
/// state of a plan — you write down dinner on Sunday and fill the rest in
/// later — so a verdict would paint amber on almost every day almost all of the
/// time, and a warning that is always on is a warning nobody reads. Worse, it
/// would be saying something false: the day is not short on calories, it is
/// short on PLANNING, and those want opposite responses.
///
/// So the figures are neutral, and the reading is one plain sentence about what
/// is left to plan. The verdict arrives on the Tracking tab, once the meals are
/// real.
struct MealPlanDayPanel: View {
    let plan: MealPlanDay
    let targets: MealTargets?
    /// Injected so a preview or a test can pin "now".
    var today: Date = Date()

    var onAdd: (MealType) -> Void
    var onOpen: (LocalMealPlanEntry) -> Void
    var onToggleEaten: (LocalMealPlanEntry) -> Void
    var onSkip: (LocalMealPlanEntry) -> Void
    var onDuplicate: (LocalMealPlanEntry) -> Void
    var onDelete: (LocalMealPlanEntry) -> Void

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            header
            if plan.blocksWithNutrition > 0 { plannedTotals }
            ForEach(plan.slots) { slot in
                slotSection(slot)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
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

    private var plannedTotals: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.xs) {
                Text("Planned")
                    .eyebrow()
                Spacer(minLength: 0)
                if plan.blocksWithoutNutrition > 0 {
                    MealFlagChip(
                        "\(plan.blocksWithoutNutrition) without numbers",
                        systemImage: "questionmark.circle",
                        tint: Tokens.muted
                    )
                }
            }

            // The headline figure, then the four macros as pills. The same
            // shape `MealChatCard` uses, so a planned day and a logged meal
            // present their numbers as one object rather than as two designs.
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

            Text(Self.roughnessNote)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    /// Stated once per day, not once per block. The figures on a plan are an
    /// estimate of a meal nobody has eaten, and a surface that showed them like
    /// logged figures would be claiming a precision it has not got.
    static let roughnessNote =
        "Planned figures are rough. A meal is estimated properly when you log it on Tracking."

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

    // MARK: - One slot

    private func slotSection(_ slot: MealPlanSlot) -> some View {
        VStack(alignment: .leading, spacing: RowMetrics.interRowSpacing) {
            HStack(spacing: Space.sm) {
                Circle()
                    .fill(slot.mealType.tint)
                    .frame(width: 6, height: 6)
                Text(slot.mealType.displayName)
                    .eyebrow()
                Spacer(minLength: 0)
                if slot.entries.count > 1 {
                    Text("\(slot.entries.count)")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, RowMetrics.rowBlockHeaderPadding)
            .padding(.bottom, Space.xs)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ForEach(slot.entries, id: \.clientUUID) { entry in
                MealPlanEntryRow(
                    entry: entry,
                    onOpen: { onOpen(entry) },
                    onToggleEaten: { onToggleEaten(entry) },
                    onSkip: { onSkip(entry) },
                    onDuplicate: { onDuplicate(entry) },
                    onDelete: { onDelete(entry) }
                )
            }

            GhostAddRow(
                label: addLabel(for: slot),
                minHeight: 40
            ) {
                onAdd(slot.mealType)
            }
        }
        .padding(.horizontal, RowMetrics.rowBlockPadding)
    }

    /// "Add breakfast" on an empty slot, "Add another snack" on one that
    /// already has something. Naming the meal rather than saying "Add" keeps
    /// four identical rows on one screen distinguishable by ear.
    private func addLabel(for slot: MealPlanSlot) -> String {
        let meal = slot.mealType.displayName.lowercased()
        return slot.isEmpty ? "Add \(meal)" : "Add another \(meal)"
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
