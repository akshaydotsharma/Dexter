import Foundation
import SwiftData

/// The provenance strings `LocalMeal.source` carries (#543).
///
/// Constants rather than an enum, because the model stores a raw string on
/// purpose and its own documentation says to compare against a constant and
/// never to parse. An enum here would make the set closed, and the set of entry
/// points is still moving (#546 adds two more).
enum MealSource {
    /// Typed into the Meals composer and estimated.
    static let composer = "manual"

    /// Inserted by Repeat from a meal already logged. No API call was made, so
    /// the numbers are a copy rather than a fresh estimate.
    static let repeated = "repeat"

    /// The eight totals were typed by the user. Known beats estimated: a meal
    /// with this source is never re-estimated without a confirmation.
    static let user = "user"

    /// Logged through the chat surface's `log_meal` / `update_meal` tools
    /// (#546). Estimated, like `composer`, but by the chat turn itself rather
    /// than by a second call.
    static let chat = "chat"

    /// Logged hands-free through the Shortcut, via `CaptureService` (#546).
    /// Same tools and same guards as `chat`; kept apart because a meal logged
    /// without anyone looking at the screen is the one most worth being able to
    /// find later.
    static let capture = "capture"
}

/// Everything between "the user described a meal" and "a row exists" (#543).
///
/// Holds the one API call, the guards that run over its answer, and every write
/// path that does NOT make a call — Repeat, a per-item edit, a totals override.
/// Splitting it this way is the point: three of the four correction paths in
/// this feature cost nothing, and Repeat is the main lever on what the feature
/// costs per month.
@MainActor
struct MealEstimationService {
    let client: AnthropicClient
    let meals: MealService

    init(client: AnthropicClient = AnthropicClient(), meals: MealService) {
        self.client = client
        self.meals = meals
    }

    static func `default`() -> MealEstimationService {
        MealEstimationService(meals: .default())
    }

    // MARK: - The one call

    /// Estimate a described meal and run every guard over the answer.
    ///
    /// Exactly one API call. The guards add no calls of their own — they are
    /// arithmetic over what came back.
    func estimate(
        description: String,
        mealTypeHint: MealType? = nil,
        loggedAt: Date = Date()
    ) async throws -> CheckedMealEstimate {
        let raw = try await client.estimateMeal(
            description: description,
            mealTypeHint: mealTypeHint,
            loggedAt: loggedAt
        )
        // #594. The sources come from the RESPONSE and travel beside the
        // estimate rather than inside it, so the guards below grade a grounded
        // answer with exactly the arithmetic they grade a guessed one with. A
        // published panel can still be transcribed wrong.
        return MealEstimateGuards.check(
            raw.estimate,
            fallbackMealType: mealTypeHint ?? Self.inferredType(at: loggedAt),
            groundingSources: raw.groundingSources
        )
    }

    /// The meal type a clock alone implies, used when the user picked none and
    /// the model returned none either.
    ///
    /// Snack is the default rather than the nearest meal, because it is the one
    /// bucket that is true at any hour. Guessing "dinner" for a 16:00 log states
    /// something the user did not.
    static func inferredType(at date: Date) -> MealType {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<11:  return .breakfast
        case 11..<15: return .lunch
        case 18..<23: return .dinner
        default:      return .snack
        }
    }

    /// The instant to stamp on a meal logged onto a day that has already ended
    /// (#592).
    ///
    /// The clock cannot answer this one. A dinner logged three days late is
    /// still a dinner, and the hour on the row is the only thing the log has to
    /// say when it was eaten, so the meal type answers instead of "now". Every
    /// retrospective meal used to be stamped at midday, which printed "12:00" on
    /// a dinner and put four meals of one day on the same minute.
    ///
    /// The hours sit inside the band `inferredType(at:)` reads for that type, so
    /// the two functions are inverses: a retrospective stamp fed back through the
    /// inference returns the type it was derived from. That is not decoration. A
    /// row can be re-estimated later with no type hint, and a stamp that inferred
    /// back to a different meal would reclassify it silently.
    ///
    /// Dinner is the one stamp that is not on the hour. The evening band is the
    /// widest of the four, so 19:30 costs nothing there, and a log whose every
    /// retrospective row lands on an exact hour reads as a form a machine filled
    /// in.
    static func retrospectiveInstant(
        for type: MealType,
        on day: Date,
        calendar: Calendar = .current
    ) -> Date {
        let hour: Int
        let minute: Int
        switch type {
        case .breakfast: hour = 8;  minute = 0
        case .lunch:     hour = 13; minute = 0
        case .dinner:    hour = 19; minute = 30
        case .snack:     hour = 16; minute = 0
        }
        // Anchored on the day's own start, so a `day` that arrives as any
        // instant inside the day lands on the same stamp as its midnight.
        let start = calendar.startOfDay(for: day)
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start
    }

    // MARK: - Writes

    /// Write a checked estimate as a meal.
    ///
    /// Passing `clientUUID` makes this a correction of the row that id names
    /// rather than a second meal — the identity contract `MealService.addMeal`
    /// already holds. The re-estimate path uses it; the composer does not.
    @discardableResult
    func save(
        _ checked: CheckedMealEstimate,
        description: String,
        day: Date,
        loggedAt: Date,
        source: String = MealSource.composer,
        clientUUID: String? = nil
    ) throws -> LocalMeal {
        try meals.addMeal(
            date: day,
            loggedAt: loggedAt,
            mealType: checked.mealType,
            mealDescription: description.trimmingCharacters(in: .whitespacesAndNewlines),
            // #603. The name every list draws. Written on every save, including
            // a re-estimate, so the short name and the numbers always describe
            // the same answer.
            title: checked.title,
            nutrients: checked.nutrients,
            items: checked.items,
            confidence: checked.confidence,
            source: source,
            needsDetail: checked.needsDetail,
            isSuspect: checked.isSuspect,
            suspectReason: checked.suspectReason,
            // Carries the repairs ahead of the model's own prose, so a clamp is
            // visible on a meal that is NOT suspect and therefore has no
            // `suspectReason` to show it in.
            assumptionsNote: checked.storedAssumptionsNote,
            // #555. The model's answer is stored rather than consumed, so a
            // later hand edit re-checks the meal against the same fact that
            // exempted it the first time.
            containsAlcohol: checked.containsAlcohol,
            // #594. Stored so the figure can be checked against the page it
            // came from months later, and so the surfaces can stop printing it
            // as a portion guess.
            groundingSources: checked.groundingSources,
            clientUUID: clientUUID
        )
    }

    /// Insert a copy of a meal dated today, with its stored numbers.
    ///
    /// No API call at all. The cheapest capture path in the feature: the same
    /// breakfast logged four mornings a week costs one estimate and three
    /// copies.
    ///
    /// The copy keeps the original's flags, including a suspect one, because a
    /// repeat of a meal whose numbers were wrong is a meal whose numbers are
    /// still wrong. It does NOT keep the source: the row was not estimated, and
    /// pretending otherwise would misreport where the numbers came from.
    @discardableResult
    func repeatMeal(_ meal: LocalMeal, on day: Date = Date(), at loggedAt: Date = Date()) throws -> LocalMeal {
        try meals.addMeal(
            date: day,
            loggedAt: loggedAt,
            mealType: meal.mealTypeEnum,
            mealDescription: meal.mealDescription,
            // #603. A repeat is the same dish, so it keeps the same name.
            title: meal.title,
            nutrients: meal.nutrients,
            items: meal.items,
            confidence: meal.confidence,
            source: meal.source == MealSource.user ? MealSource.user : MealSource.repeated,
            needsDetail: meal.needsDetail,
            isSuspect: meal.isSuspect,
            suspectReason: meal.suspectReason,
            assumptionsNote: meal.assumptionsNote,
            // #555. A repeat of a meal that held a drink still holds a drink.
            containsAlcohol: meal.containsAlcohol,
            // #594. A repeat copies the numbers, so it copies what they came
            // from. The same GYG bowl logged on Thursday is still the same
            // published panel.
            groundingSources: meal.groundingSources
        )
    }

    /// Replace one item and re-total the meal from its items, in Swift.
    ///
    /// No API call. Correcting a portion is arithmetic over numbers the estimate
    /// already gave, and asking the model again would re-guess the components
    /// the user did not touch.
    ///
    /// See `recomputeTotals` for what is re-checked afterwards, and for the one
    /// check that deliberately is not.
    func replaceItem(
        _ item: MealItemEntry,
        in meal: LocalMeal
    ) throws {
        var items = meal.items
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        try recomputeTotals(of: meal, from: items)
    }

    /// Set a meal's items and re-total from them, re-checking the result.
    ///
    /// No API call. `MealEstimateGuards.recheckHandEdited` runs the clamps, the
    /// hard bounds and, since #555, the macro consistency check. The stored
    /// `containsAlcohol` is what makes that last one answerable here: without
    /// it the guard could not tell a beer from a broken estimate.
    ///
    /// Re-checking at all is deliberate in the other direction: a meal that was
    /// suspect for a reason the edit has fixed must stop being suspect, or a
    /// corrected meal would stay out of the day's totals forever.
    func recomputeTotals(of meal: LocalMeal, from items: [MealItemEntry]) throws {
        let result = MealEstimateGuards.recheckHandEdited(
            items: items,
            containsAlcohol: meal.containsAlcohol
        )
        // Only the INVALIDATING failures flag the meal. A clamp leaves the
        // numbers coherent, and excluding a repaired meal would take a real
        // lunch out of the day's total over a gram of sugar.
        let invalidating = result.failures.filter(\.invalidatesEstimate)
        let reason = invalidating.isEmpty
            ? nil
            : invalidating.map(\.reason).joined(separator: " ")

        // The assumptions note is deliberately left alone here, unlike on the
        // estimate path. A clamp applied to a number the user just typed is
        // visible the moment the field redraws with the clamped value, and
        // appending a sentence on every edit would grow the note without bound.
        try meals.updateMeal(
            meal,
            nutrients: result.totals,
            items: result.items,
            isSuspect: !invalidating.isEmpty,
            suspectReason: .some(reason)
        )
    }

    /// Replace the eight totals with numbers the user typed.
    ///
    /// Known beats estimated, so this clears every warning: an overridden meal
    /// is not suspect, does not need detail, and is exact. The items are left
    /// alone — they are what the estimate thought the meal was made of, and the
    /// user has not said they were wrong, only that the totals were.
    ///
    /// `source` becomes `MealSource.user`, which is what later stops a
    /// re-estimate from quietly replacing these numbers.
    func overrideTotals(of meal: LocalMeal, with nutrients: MealNutrients) throws {
        try meals.updateMeal(
            meal,
            nutrients: nutrients,
            confidence: 1,
            source: MealSource.user,
            needsDetail: false,
            isSuspect: false,
            suspectReason: .some(nil),
            // #594. The sources go with the numbers they described. These
            // numbers were typed, so pointing at a brand's page for them would
            // credit a figure the brand never published.
            groundingSources: []
        )
    }

    /// Correct whether a meal held a drink, and re-grade it on the new answer
    /// (#555).
    ///
    /// No API call. The flag decides whether the macro consistency check fires,
    /// so writing it without re-grading would leave a meal flagged suspect for
    /// a miss the user has just explained, or unflagged for one they have just
    /// withdrawn.
    ///
    /// ### Why the re-grade is skipped for two kinds of meal
    ///
    /// The re-grade re-totals from the items, which is a no-op on the numbers
    /// whenever the totals ARE the sum of the items — true of every estimated
    /// meal by construction. It is NOT true of the other two:
    ///
    /// 1. A meal whose totals the user typed. Known beats estimated, so the
    ///    guards do not grade it, and re-totalling would throw the typed
    ///    numbers away.
    /// 2. A meal with no items at all, which can still carry totals (a restore
    ///    from a peer, a needs-detail row). Re-totalling from an empty array
    ///    would zero it.
    ///
    /// Both still take the flag. Only the grading is withheld.
    ///
    /// This lives on the service and not in the sheet on purpose: a decision
    /// made inside a SwiftUI View is a decision no test can reach (#488).
    func setContainsAlcohol(_ containsAlcohol: Bool, on meal: LocalMeal) throws {
        try meals.updateMeal(meal, containsAlcohol: containsAlcohol)
        guard !meal.totalsWereOverridden, !meal.items.isEmpty else { return }
        try recomputeTotals(of: meal, from: meal.items)
    }
}

extension LocalMeal {
    /// True when this meal's totals were typed by the user rather than
    /// estimated.
    ///
    /// The one thing that makes a re-estimate ask first. There is no separate
    /// column for it and there does not need to be: `source` already records
    /// where the numbers came from, and a second field saying the same thing
    /// could disagree with it.
    var totalsWereOverridden: Bool { source == MealSource.user }
}
