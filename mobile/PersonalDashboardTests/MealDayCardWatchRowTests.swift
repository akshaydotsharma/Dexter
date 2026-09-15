import XCTest
import SwiftUI
@testable import PersonalDashboard

/// The day card's Watch row fits the card at phone width (#561).
///
/// ### The defect this pins shut
///
/// The row drew its three ceilings as an even three-across split, which
/// truncated "Saturated fat" to "SATURATE…" on every iPhone, in both the
/// targets-set and the no-targets state, from #543 until #561. It was correct
/// only on the Mac, where the window is wide enough, so nothing caught it: the
/// surface the defect was on is the surface nobody develops against.
///
/// ### Why it is a measurement and not a screenshot
///
/// Truncation is the one rendering failure that leaves the layout looking
/// healthy. The row keeps its height, its alignment and its spacing, and three
/// characters go missing off the end of one label. A geometry assertion is what
/// catches that; a height or a frame check is not. So these render the real
/// pills through `ImageRenderer` and compare their natural widths against the
/// column the card actually gives them.
///
/// ### Why the even-split case is pinned too
///
/// An even grid is tidier and it is what the row looked like for two releases.
/// The pull to restore it is real, so the measurement that rules it out is
/// asserted here rather than only written in a comment: a tidy-up back towards
/// `fillsWidth: true` fails in the suite instead of on someone's phone.
@MainActor
final class MealDayCardWatchRowTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_757_462_400)

    // MARK: - The card's geometry at phone width
    //
    // `MealsView` gives the card the screen less `Space.lg` either side, and the
    // card's own `Space.lg` padding takes the rest. Spelled out from the tokens
    // rather than hard-coded, so a spacing change lands here.

    private let screen: CGFloat = 390
    private var cardWidth: CGFloat { screen - Space.lg * 2 }
    private var column: CGFloat { cardWidth - Space.lg * 2 }

    /// A day with numbers on every nutrient, at a realistic scale.
    private var summary: MealDaySummary {
        MealDaySummary(meals: [
            LocalMeal(
                date: day, loggedAt: day, mealType: MealType.lunch.rawValue,
                mealDescription: "Chicken rice",
                calories: 1_450, proteinG: 88, carbsG: 160, fatG: 52,
                fibreG: 18, sugarG: 46, sodiumMg: 2_600, satFatG: 21,
                confidence: 0.6, source: MealSource.composer
            )
        ])
    }

    private var targets: MealTargets {
        MealTargets(
            calories: 2_200, proteinG: 130, carbsG: 250, fatG: 70, fibreG: 30,
            sugarG: 50, sodiumMg: 2_300, satFatG: 20,
            ageYears: 38, biologicalSex: "male", heightCm: 178, weightKg: 76,
            activityLevel: "moderate", goal: "maintain",
            rationale: "Derived for the test.", effectiveFrom: day
        )
    }

    /// One pill exactly as the card builds it, measured at its natural size.
    private func naturalSize(of nutrient: Nutrient, withTarget: Bool) throws -> CGSize {
        let pill = MealStatPill(
            nutrient: nutrient,
            value: summary.totals[nutrient],
            target: withTarget ? targets.target(for: nutrient) : nil
        )
        return try XCTUnwrap(ImageRenderer(content: pill).uiImage?.size)
    }

    // MARK: - The fix

    /// The three ceilings, at natural width with one gap between each, fit the
    /// card's inner column. This is the assertion the fix has to keep true.
    func testTheWatchRowFitsTheCardAtPhoneWidth() throws {
        for withTarget in [true, false] {
            var total = Space.sm * CGFloat(Nutrient.ceilingsInOrder.count - 1)
            for nutrient in Nutrient.ceilingsInOrder {
                total += try naturalSize(of: nutrient, withTarget: withTarget).width
            }
            XCTAssertLessThanOrEqual(
                total, column,
                "the Watch row needs \(total) pt of a \(column) pt column"
                + (withTarget ? " with targets set" : " with no targets")
            )
        }
    }

    // MARK: - What must not come back

    /// An even three-across split does not fit, which is why the row does not
    /// use one. A change back to `fillsWidth: true` fails here.
    func testAnEvenThreeAcrossSplitWouldTruncateSaturatedFat() throws {
        let evenShare = (column - Space.sm * 2) / 3
        let widest = try naturalSize(of: .saturatedFat, withTarget: true).width

        XCTAssertGreaterThan(
            widest, evenShare,
            "an even split gives \(evenShare) pt and the pill needs \(widest) pt"
        )
    }

    /// And no iPhone is wide enough to rescue the even split. Stated as the
    /// screen width it would take, so the number is checkable against a device
    /// list rather than against intuition.
    func testNoPhoneIsWideEnoughForTheEvenSplit() throws {
        let widest = try naturalSize(of: .saturatedFat, withTarget: true).width
        let neededScreen = widest * 3 + Space.sm * 2 + Space.lg * 4

        XCTAssertGreaterThan(
            neededScreen, 440,
            "the even split needs a \(neededScreen) pt screen, which would change this verdict"
        )
    }

    /// The variant is not the cause and could not be the cure. A tinted pill
    /// and a plain one are the same size, because the variant changes four
    /// colours and both lines keep `lineLimit(1)`.
    func testAVerdictPillMeasuresTheSameAsANeutralOne() throws {
        for nutrient in Nutrient.ceilingsInOrder {
            let verdict = try naturalSize(of: nutrient, withTarget: true)
            let neutral = try naturalSize(of: nutrient, withTarget: false)
            XCTAssertEqual(verdict.width, neutral.width, accuracy: 0.5, nutrient.displayName)
            XCTAssertEqual(verdict.height, neutral.height, accuracy: 0.5, nutrient.displayName)
        }
    }

    // MARK: - What the fix must not disturb

    /// Sugar and Sodium always fitted, under either construction. The fix is
    /// about one label, and this says so.
    func testSugarAndSodiumFitEvenTheEvenSplit() throws {
        let evenShare = (column - Space.sm * 2) / 3
        for nutrient in [Nutrient.sugar, .sodium] {
            XCTAssertLessThanOrEqual(
                try naturalSize(of: nutrient, withTarget: true).width, evenShare,
                "\(nutrient.displayName) was never the problem"
            )
        }
    }

    /// The macro treatment is untouched. In the no-targets state the four
    /// macros are still an even four-across split, and they still fit it.
    func testTheMacroPillsStillFitTheirEvenFourAcrossSplit() throws {
        let evenShare = (column - Space.sm * 3) / 4
        for nutrient in Nutrient.macrosInOrder {
            XCTAssertLessThanOrEqual(
                try naturalSize(of: nutrient, withTarget: false).width, evenShare,
                "\(nutrient.displayName) would truncate in the no-targets macro row"
            )
        }
    }

    /// "Saturated fat" reaches the card through the Watch row and nowhere else,
    /// so this row is the whole of the fix.
    func testSaturatedFatIsOnlyEverInTheWatchRow() {
        XCTAssertTrue(Nutrient.ceilingsInOrder.contains(.saturatedFat))
        XCTAssertFalse(Nutrient.macrosInOrder.contains(.saturatedFat))
    }
}
