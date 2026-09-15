import Foundation

/// Everything the two surfaces need to say about a meal that was just written
/// by `log_meal` or `update_meal` (#546).
///
/// ### Why this is computed in the executor and not in the view
///
/// The chat card wants the day's remaining calories and protein, which is a
/// read of every meal on the day plus the targets in force. The Shortcut wants
/// one spoken sentence. Both are derived from the same facts, and those facts
/// are only cheaply available at the moment of the write, when the store is
/// already open and the row has just been saved.
///
/// Computing it there and carrying it on `DraftActionOutcome` also makes it a
/// plain value: the card renders a struct instead of re-fetching, and the
/// dialog sentence is a pure function a test can pin without a store.
struct MealLogSummary: Equatable, Sendable {

    // MARK: - What was logged

    let mealType: MealType
    /// The description as the user gave it, verbatim.
    let mealDescription: String
    /// The stored UTC day anchor. Read through `dayLabel`, never formatted raw.
    let dayAnchor: Date
    /// The day is today. When false the card and the dialog BOTH name the date:
    /// a silently misdated meal corrupts two days at once and neither one looks
    /// wrong.
    let isToday: Bool

    // MARK: - The numbers

    let nutrients: MealNutrients
    /// 0...1, as stored. Banded for display through `MealFormat.confidenceBand`.
    let confidence: Double
    /// The portions the estimate assumed, one collapsed line:
    /// "100 g egg · 60 g toast · 200 ml flat white". Empty when nothing was
    /// broken down.
    let portionsLine: String

    // MARK: - What is left today

    /// Calories still available against the day's target, or nil when no
    /// targets are set. Negative when the day is over.
    let caloriesRemaining: Double?
    /// Protein still owed against the day's target, or nil when no targets are
    /// set. Negative once the target is beaten.
    let proteinRemaining: Double?

    // MARK: - What the user has to know

    /// The estimate named nothing edible. The row exists with the description
    /// and zero nutrients, which is the whole point: losing the fact that you
    /// ate is worse than losing the number.
    let needsDetail: Bool
    /// Why the guards flagged the numbers, or nil.
    let suspectReason: String?
    /// The model emitted a future date and it was pulled back to today.
    let wasDateClampedFromFuture: Bool
    /// Minutes since a meal on the same day that this one closely resembles, or
    /// nil when there is none. BOTH rows are kept; this is a remark, not a
    /// block.
    let duplicateMinutesAgo: Int?
    /// Logged in the small hours and plausibly belonging to yesterday. The card
    /// offers one tap; nothing moves on its own.
    let offersYesterdayMove: Bool

    // MARK: - Display

    /// "today", "yesterday", or "3 Sep". Read off the anchor through
    /// `WallClock.deviceDay`, because formatting the anchor directly prints the
    /// day before anywhere west of UTC (#506).
    func dayLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = WallClock.deviceDay(from: dayAnchor)
        if calendar.isDateInToday(day) { return "today" }
        if calendar.isDateInYesterday(day) { return "yesterday" }
        if calendar.isDateInTomorrow(day) { return "tomorrow" }
        return Self.dayMonth.string(from: day)
    }

    /// The one sentence the Shortcut speaks.
    ///
    /// It ALWAYS states either a number or the reason there is no number. A
    /// silent success is how a day quietly ends up half logged: the user hears
    /// "done", believes lunch is in, and finds out at 21:00 that it never was.
    ///
    /// The base sentence is held under 20 words so it reads well spoken by Siri
    /// or announced through AirPods. The extra clauses — a duplicate remark, a
    /// clamped date — are appended after it and deliberately push past that,
    /// because each one is a fact the user cannot recover if it goes unsaid.
    func dialogSentence(now: Date = Date(), calendar: Calendar = .current) -> String {
        var sentence = baseSentence(now: now, calendar: calendar)
        if let minutes = duplicateMinutesAgo {
            sentence += " Similar to a meal logged \(Self.spelledMinutes(minutes))."
        }
        if wasDateClampedFromFuture {
            sentence += " That date was in the future, so I used today."
        }
        return sentence
    }

    /// The part of the dialog that must fit in 20 words.
    func baseSentence(now: Date = Date(), calendar: Calendar = .current) -> String {
        let label = dayLabel(now: now, calendar: calendar)
        let when = isToday ? "" : " for \(label)"
        let head = "Logged \(mealType.rawValue)\(when)"

        if needsDetail {
            return "\(head). I need more detail to estimate it, open Meals to fill it in."
        }

        let kcal = MealFormat.calories(nutrients.calories)
        let protein = MealFormat.grams(nutrients.proteinG)
        var line = "\(head), about \(kcal) calories and \(protein) grams of protein."
        if let suspectReason, !suspectReason.isEmpty {
            // A flagged meal is out of the day's totals, and saying "about 640
            // calories" without saying so would report a number that is not
            // being counted.
            line += " Flagged, so it is not counted yet."
        } else if confidence < 0.45 {
            line += " Rough estimate."
        }
        return line
    }

    /// "eight minutes ago" / "just now" / "43 minutes ago".
    ///
    /// Spelled out below eleven because the dialog is spoken as often as it is
    /// read, and a digit in a spoken sentence is a number the voice has to
    /// decide how to say.
    static func spelledMinutes(_ minutes: Int) -> String {
        if minutes <= 0 { return "moments ago" }
        let words = [
            1: "one", 2: "two", 3: "three", 4: "four", 5: "five",
            6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten"
        ]
        let unit = minutes == 1 ? "minute" : "minutes"
        if let word = words[minutes] { return "\(word) \(unit) ago" }
        return "\(minutes) \(unit) ago"
    }

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        return f
    }()
}

extension MealLogSummary {

    /// Build the summary from a freshly written row plus the day it landed on.
    ///
    /// - Parameters:
    ///   - meal: the row `MealEstimationService.save` returned.
    ///   - dayMeals: every meal on that day, the saved row included. The
    ///     remaining-today figures are computed from this, so they already
    ///     account for the meal just logged — which is the point of the line.
    ///   - targets: the targets in force on that day, or nil.
    ///   - duplicateOf: the closest already-stored meal this one resembles.
    ///   - wasDateClampedFromFuture: from `MealToolSchema.resolveDay`.
    ///   - now: injected so the tests can stand at a fixed clock.
    init(
        meal: LocalMeal,
        dayMeals: [LocalMeal],
        targets: MealTargets?,
        duplicateOf: LocalMeal?,
        wasDateClampedFromFuture: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let summary = MealDaySummary(meals: dayMeals)
        self.mealType = meal.mealTypeEnum
        self.mealDescription = meal.mealDescription
        self.dayAnchor = meal.date
        self.isToday = WallClock.isSameStoredDay(meal.date, WallClock.dayAnchor(from: now))
        self.nutrients = meal.nutrients
        self.confidence = meal.confidence
        self.portionsLine = meal.items
            .map { item in
                item.name.isEmpty
                    ? item.portionDescription
                    : "\(item.portionDescription) \(item.name.lowercased())"
            }
            .joined(separator: " · ")

        // Remaining reads the day's COUNTED totals, so a suspect or
        // needs-detail meal does not move the line. That is deliberate and it
        // is the same rule the Meals day card follows: a number known to be
        // wrong must not quietly change what is left.
        if let targets {
            let calorieTarget = targets.target(for: .calories)
            let proteinTarget = targets.target(for: .protein)
            self.caloriesRemaining = calorieTarget > 0 ? calorieTarget - summary.totals.calories : nil
            self.proteinRemaining = proteinTarget > 0 ? proteinTarget - summary.totals.proteinG : nil
        } else {
            self.caloriesRemaining = nil
            self.proteinRemaining = nil
        }

        self.needsDetail = meal.needsDetail
        self.suspectReason = meal.isSuspect ? meal.suspectReason : nil
        self.wasDateClampedFromFuture = wasDateClampedFromFuture
        self.duplicateMinutesAgo = duplicateOf.map { other in
            Int((meal.loggedAt.timeIntervalSince(other.loggedAt) / 60).rounded())
        }
        self.offersYesterdayMove = MealToolSchema.offersYesterdayMove(
            mealType: meal.mealTypeEnum,
            day: meal.date,
            now: now,
            calendar: calendar
        )
    }
}
