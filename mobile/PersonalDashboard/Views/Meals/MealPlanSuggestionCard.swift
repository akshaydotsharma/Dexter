import SwiftUI

/// One suggestion the plan chat has put forward (#599).
///
/// ### Why it is a card and not a line of prose
///
/// Everything on it is actionable in a way a sentence is not: the meal type
/// decides which slot it lands in, the ingredients are what gets carried onto
/// the block, the numbers are what makes the planned day add up, and the footer
/// is the whole point. Prose carrying the same four things would have to be
/// parsed by the reader before it could be used.
///
/// ### The card chooses where it lands
///
/// Day and meal type are pickers ON the card, not assumptions the surface makes
/// behind it. The chat floats over whatever day the calendar happens to be on,
/// and a conversation ranges over several: you ask what to have this week and
/// get a breakfast, a lunch and something for Saturday. An Add that silently
/// used the day underneath would scatter those three onto one square and give
/// the user no way to notice, because the card disappears behind the overlay the
/// moment it is tapped.
///
/// Both default to the sensible thing — the day in view, the type the model
/// chose — so the common case is still one tap.
struct MealPlanSuggestionCard: View {
    let suggestion: MealPlanSuggestion
    /// The day the pickers start on: whatever the calendar is showing.
    let defaultDay: Date
    /// True once it has been added, which swaps the footer for a confirmation.
    let wasAdded: Bool
    var onAdd: (Date, MealType) -> Void

    @State private var day: Date
    @State private var mealType: MealType
    @State private var loaded = false
    /// Whether the day calendar is open under the footer row (#669).
    @State private var dayOpen = false

    init(
        suggestion: MealPlanSuggestion,
        defaultDay: Date,
        wasAdded: Bool,
        onAdd: @escaping (Date, MealType) -> Void
    ) {
        self.suggestion = suggestion
        self.defaultDay = defaultDay
        self.wasAdded = wasAdded
        self.onAdd = onAdd
        _day = State(initialValue: Calendar.current.startOfDay(for: defaultDay))
        _mealType = State(initialValue: suggestion.mealType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            header

            if let why = suggestion.why {
                Text(why)
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !suggestion.ingredients.isEmpty { ingredientChips }

            if let nutrients = suggestion.nutrients {
                macroRow(nutrients)
            } else {
                Text("No numbers for this one.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }

            if let prep = suggestion.prepNote {
                HStack(spacing: Space.xs) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .regular))
                    Text(prep)
                        .font(.edCaption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Tokens.muted)
            }

            footer
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Circle()
                    .fill(mealType.tint)
                    .frame(width: 6, height: 6)
                Text(mealType.displayName)
                    .eyebrow()
                Spacer(minLength: 0)
            }
            // The dish is what the card is about, so it takes the display
            // serif. It used to sit at `.edHeading` while the calorie figure
            // below it ran at `.edTitle`, which put the number above the thing
            // the number describes (#645).
            Text(suggestion.title)
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var ingredientChips: some View {
        ChipFlowLayout(spacing: Space.xs) {
            ForEach(suggestion.ingredients, id: \.self) { ingredient in
                Text(ingredient)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 3)
                    .background(Tokens.surface2, in: Capsule())
                    .overlay(Capsule().stroke(Tokens.border, lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ingredients: \(suggestion.ingredients.joined(separator: ", "))")
    }

    /// Calories, then the four the day is steered by, in the fixed order every
    /// Meals surface prints them. Never sorted by value: position is how a
    /// nutrient is identified once colour has been spent elsewhere.
    ///
    /// Neutral, never a verdict. These figures describe a meal nobody has eaten,
    /// so there is no day for them to be good or bad against yet.
    private func macroRow(_ nutrients: MealNutrients) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(MealFormat.calories(nutrients.calories))
                    .font(.edHeading)
                    .foregroundStyle(Tokens.ink)
                    .monospacedDigit()
                Text("kcal, roughly")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                Spacer(minLength: 0)
            }
            HStack(spacing: Space.sm) {
                ForEach(Nutrient.macrosInOrder) { nutrient in
                    MealStatPill(
                        label: nutrient.displayName,
                        value: MealFormat.value(nutrients[nutrient], for: nutrient),
                        variant: .neutral,
                        fillsWidth: true
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if wasAdded {
            SuccessRow(label: "Added to \(mealType.displayName.lowercased()) on \(Self.dayLabel(day))")
        } else {
            VStack(alignment: .leading, spacing: Space.sm) {
                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)

                // Wrapped so the three controls stack rather than squeeze when
                // the overlay is narrow. The day field measures at its natural
                // width here for the same reason: filling the row would put the
                // meal menu and the Add button on lines of their own.
                ChipFlowLayout(spacing: Space.sm) {
                    EdDayPicker(
                        day: $day,
                        isOpen: $dayOpen,
                        accessibilityName: "Day to add this meal to",
                        tint: mealType.tint,
                        fillsWidth: false
                    )

                    Menu {
                        Picker("Meal", selection: $mealType) {
                            ForEach(MealType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        HStack(spacing: Space.xs) {
                            Text(mealType.displayName)
                                .font(.edFootnote)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(Tokens.ink)
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, 6)
                        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                .stroke(Tokens.border, lineWidth: 0.5)
                        )
                    }
                    .menuStyleCompat()
                    .accessibilityLabel("Meal to add this to, currently \(mealType.displayName)")

                    Button {
                        onAdd(day, mealType)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Add")
                        }
                    }
                    // The one thing this card exists to do. It was `.secondary`,
                    // level with its own day and meal-type pickers, while the
                    // same commit in `MealPlanEntrySheet` is `.primary` (#645).
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                    .accessibilityLabel("Add \(suggestion.title) to \(mealType.displayName) on \(Self.dayLabel(day))")
                }

                // The day's calendar opens UNDER the row, the way every date
                // field does since #657, not in a popover over the chat
                // (#669). It hangs below the whole row rather than below the
                // chip because a flow layout cannot hold a full-width child,
                // and the card is already the surface, so no second card.
                if dayOpen {
                    EdDayPickerCalendar(
                        day: $day,
                        tint: mealType.tint,
                        drawsCard: false,
                        fillsWidth: true
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// "today", "tomorrow", or the weekday and date. The same phrasing the tab
    /// uses, so one meal is never described two ways on one screen.
    static func dayLabel(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "today" }
        if calendar.isDateInTomorrow(day) { return "tomorrow" }
        if calendar.isDateInYesterday(day) { return "yesterday" }
        return shortDay.string(from: day)
    }

    private static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM"
        return f
    }()
}
