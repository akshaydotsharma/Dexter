import XCTest
@testable import PersonalDashboard

/// Soft duplicate detection over a day's meals (#543).
///
/// The rule has to catch the same meal entered twice and must NOT catch two real
/// meals that happen to resemble each other. The cost of the two mistakes is not
/// symmetric — a missed duplicate is a row the user deletes, a wrongly blocked
/// meal is a capture path that stopped working — which is why the rule only ever
/// flags and why the boundary cases below are pinned.
final class MealDuplicateCheckTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_757_462_400)

    private func candidate(
        _ id: String,
        _ description: String,
        type: MealType = .breakfast,
        minutesAfterMidnight: Int = 8 * 60,
        onDay: Date? = nil
    ) -> MealDuplicateCandidate {
        let base = onDay ?? day
        return MealDuplicateCandidate(
            id: id,
            dayAnchor: WallClock.dayAnchor(from: base),
            mealType: type,
            mealDescription: description,
            loggedAt: base.addingTimeInterval(TimeInterval(minutesAfterMidnight * 60))
        )
    }

    // MARK: - The rule's four conditions

    func testTheSameMealLoggedTwiceWithinTwoHoursFlagsBothRows() {
        let flagged = MealDuplicateCheck.flaggedIDs(among: [
            candidate("a", "Flat white", minutesAfterMidnight: 8 * 60),
            candidate("b", "A flat white", minutesAfterMidnight: 8 * 60 + 30)
        ])

        // BOTH, not just the later one. The user is choosing between two rows,
        // and marking one of them would hide half the choice.
        XCTAssertEqual(flagged, ["a", "b"])
    }

    func testTheSameMealMoreThanTwoHoursApartIsNotFlagged() {
        let flagged = MealDuplicateCheck.flaggedIDs(among: [
            candidate("a", "Flat white", minutesAfterMidnight: 8 * 60),
            candidate("b", "Flat white", minutesAfterMidnight: 11 * 60)
        ])

        XCTAssertTrue(flagged.isEmpty)
    }

    /// Exactly at the window is still a duplicate. The boundary belongs inside
    /// the rule rather than a minute outside it.
    func testExactlyTwoHoursApartIsStillFlagged() {
        let flagged = MealDuplicateCheck.flaggedIDs(among: [
            candidate("a", "Flat white", minutesAfterMidnight: 8 * 60),
            candidate("b", "Flat white", minutesAfterMidnight: 10 * 60)
        ])

        XCTAssertEqual(flagged, ["a", "b"])
    }

    func testDifferentMealTypesAreNotFlagged() {
        let flagged = MealDuplicateCheck.flaggedIDs(among: [
            candidate("a", "Chicken rice", type: .lunch, minutesAfterMidnight: 13 * 60),
            candidate("b", "Chicken rice", type: .snack, minutesAfterMidnight: 13 * 60 + 20)
        ])

        XCTAssertTrue(flagged.isEmpty)
    }

    func testDifferentDaysAreNotFlagged() {
        let nextDay = day.addingTimeInterval(24 * 60 * 60)
        let flagged = MealDuplicateCheck.flaggedIDs(among: [
            candidate("a", "Porridge", minutesAfterMidnight: 8 * 60),
            candidate("b", "Porridge", minutesAfterMidnight: 8 * 60, onDay: nextDay)
        ])

        // The same breakfast two mornings running is two breakfasts. The day
        // check is what stops this rule flagging a habit.
        XCTAssertTrue(flagged.isEmpty)
    }

    func testDifferentFoodAtTheSameTimeIsNotFlagged() {
        let flagged = MealDuplicateCheck.flaggedIDs(among: [
            candidate("a", "Porridge with banana", minutesAfterMidnight: 8 * 60),
            candidate("b", "Scrambled eggs on rye", minutesAfterMidnight: 8 * 60 + 10)
        ])

        XCTAssertTrue(flagged.isEmpty)
    }

    // MARK: - Description similarity

    /// The pair the rule most needs to catch, and the one a naive word-overlap
    /// misses: the descriptions differ by exactly a count.
    func testACountDoesNotHideADuplicate() {
        XCTAssertTrue(MealDuplicateCheck.isSimilar("two coffees", "a coffee"))
        XCTAssertTrue(MealDuplicateCheck.isSimilar("2 slices of toast", "toast"))
    }

    func testWordOrderAndFillerDoNotMatter() {
        XCTAssertTrue(MealDuplicateCheck.isSimilar("chicken rice with soup", "soup and chicken rice"))
    }

    func testPunctuationAndCaseDoNotMatter() {
        XCTAssertTrue(MealDuplicateCheck.isSimilar("Flat white.", "flat  WHITE!"))
    }

    func testDistinctMealsAreNotSimilar() {
        XCTAssertFalse(MealDuplicateCheck.isSimilar("chicken rice", "laksa"))
        XCTAssertFalse(MealDuplicateCheck.isSimilar("two eggs on toast", "a bowl of laksa"))
    }

    /// Two descriptions that normalise to nothing are not similar. Matching
    /// empty against empty would flag every pair of contentless logs.
    func testTwoContentlessDescriptionsAreNotSimilar() {
        XCTAssertFalse(MealDuplicateCheck.isSimilar("a", "the"))
        XCTAssertFalse(MealDuplicateCheck.isSimilar("", ""))
    }

    // MARK: - Asking before the row exists

    func testMatchesFindsWhatAPendingMealWouldDuplicate() {
        let existing = [
            candidate("a", "Flat white", minutesAfterMidnight: 8 * 60),
            candidate("b", "Chicken rice", type: .lunch, minutesAfterMidnight: 13 * 60)
        ]
        let pending = candidate("pending", "flat white", minutesAfterMidnight: 8 * 60 + 45)

        let matches = MealDuplicateCheck.matches(for: pending, among: existing)

        XCTAssertEqual(matches.map(\.id), ["a"])
    }

    /// A meal never duplicates itself, or every stored row would flag on the
    /// second read.
    func testAMealIsNeverItsOwnDuplicate() {
        let one = candidate("a", "Flat white")

        XCTAssertTrue(MealDuplicateCheck.matches(for: one, among: [one]).isEmpty)
        XCTAssertTrue(MealDuplicateCheck.flaggedIDs(among: [one]).isEmpty)
    }

    // MARK: - Three of a kind

    func testThreeSimilarMealsInTheWindowAllFlag() {
        let flagged = MealDuplicateCheck.flaggedIDs(among: [
            candidate("a", "Flat white", minutesAfterMidnight: 8 * 60),
            candidate("b", "Flat white", minutesAfterMidnight: 8 * 60 + 40),
            candidate("c", "Flat white", minutesAfterMidnight: 9 * 60 + 30)
        ])

        XCTAssertEqual(flagged, ["a", "b", "c"])
    }
}
