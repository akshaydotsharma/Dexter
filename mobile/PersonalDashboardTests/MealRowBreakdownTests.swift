import XCTest
import SwiftUI
@testable import PersonalDashboard

/// The nutrient breakdown on a meal row (#560).
///
/// The row gained seven pills under the description. Three of the four rules
/// that govern them are invisible to a build and to a screenshot of a healthy
/// day, which is why they are pinned here:
///
/// 1. The order is fixed in code and never sorted by value. Hue on this surface
///    means verdict, so nutrient identity has to survive greyscale, and
///    position is the first thing carrying it.
/// 2. A needs-detail meal has eight stored zeros and no knowledge behind them.
///    A rung of zero pills would state as fact what the em dash in the calorie
///    column exists to say is unknown.
/// 3. A suspect meal DOES show its numbers. It is held out of the day's totals
///    and the user cannot judge it without reading what it would have added.
/// 4. The spoken row stays a sentence. Seven readings folded into the label
///    would make ten meals unlistenable, so they live in custom content and the
///    label keeps naming the meal and its calories.
@MainActor
final class MealRowBreakdownTests: XCTestCase {

    private let day = Date(timeIntervalSince1970: 1_757_462_400)

    /// A meal built directly rather than through `MealService`: every rule under
    /// test reads stored fields, so a container would add a dependency and
    /// prove nothing.
    private func meal(
        _ description: String = "Chicken rice",
        calories: Double = 600,
        protein: Double = 35,
        carbs: Double = 70,
        fat: Double = 18,
        fibre: Double = 3,
        sugar: Double = 9,
        sodium: Double = 1_900,
        satFat: Double = 6,
        needsDetail: Bool = false,
        isSuspect: Bool = false,
        suspectReason: String? = nil
    ) -> LocalMeal {
        LocalMeal(
            date: day,
            loggedAt: day,
            mealType: MealType.lunch.rawValue,
            mealDescription: description,
            calories: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            fibreG: fibre,
            sugarG: sugar,
            sodiumMg: sodium,
            satFatG: satFat,
            confidence: 0.6,
            source: MealSource.composer,
            needsDetail: needsDetail,
            isSuspect: isSuspect,
            suspectReason: suspectReason
        )
    }

    private func row(_ meal: LocalMeal, isDuplicate: Bool = false) -> MealRow {
        MealRow(meal: meal, isDuplicate: isDuplicate, onTap: {})
    }

    // MARK: - The order

    /// The seven, in the one order every Meals surface prints: the four macros
    /// the day is steered by, then the three ceilings it is watched against.
    func testTheBreakdownIsTheFixedOrderMacrosThenCeilings() {
        XCTAssertEqual(
            MealRow.breakdown(for: meal()),
            [.protein, .carbs, .fat, .fibre, .sugar, .sodium, .saturatedFat]
        )
        // Stated against the shared constants too, so re-ordering either one
        // fails here rather than drifting the row away from the day card.
        XCTAssertEqual(
            MealRow.breakdown(for: meal()),
            Nutrient.macrosInOrder + Nutrient.ceilingsInOrder
        )
    }

    /// A meal whose values run in the opposite direction prints the same order.
    /// A row that re-ordered itself as the numbers changed would take position
    /// away as a carrier of identity.
    func testTheOrderDoesNotFollowTheValues() {
        let inverted = meal(protein: 1, carbs: 2, fat: 3, fibre: 4, sugar: 5, sodium: 6, satFat: 7)
        XCTAssertEqual(MealRow.breakdown(for: inverted), MealRow.breakdown(for: meal()))
    }

    /// Calories are not in the rung. They stay the row's anchor on the right at
    /// heading size, and a pill repeating them would make the row argue with
    /// itself about which figure leads.
    func testCaloriesAreNotOneOfThePills() {
        XCTAssertFalse(MealRow.breakdown(for: meal()).contains(.calories))
        XCTAssertEqual(MealRow.breakdown(for: meal()).count, 7)
    }

    // MARK: - Needs detail

    /// No numbers at all, not a row of zeros.
    func testANeedsDetailMealProducesNoNutrientPills() {
        let unknown = meal(
            "rice",
            calories: 0, protein: 0, carbs: 0, fat: 0, fibre: 0, sugar: 0, sodium: 0, satFat: 0,
            needsDetail: true
        )
        XCTAssertTrue(MealRow.breakdown(for: unknown).isEmpty)
        XCTAssertNil(MealRow.spokenReadings(Nutrient.macrosInOrder, of: unknown))
        XCTAssertNil(MealRow.spokenReadings(Nutrient.ceilingsInOrder, of: unknown))
    }

    /// The flag is what suppresses the rung, not the zeros. A meal that really
    /// came to nothing on a nutrient still prints its pill.
    func testAZeroNutrientOnAKnownMealStillPrintsItsPill() {
        let noFibre = meal(fibre: 0)
        XCTAssertEqual(MealRow.breakdown(for: noFibre).count, 7)
        XCTAssertEqual(MealRow.reading(.fibre, of: noFibre), "0 g")
    }

    // MARK: - Suspect

    /// A suspect meal shows its numbers. It is held out of the day's totals, so
    /// the row is the only place the user can see what it would have added.
    func testASuspectMealDoesShowItsNumbers() {
        let doubted = meal(
            "A suspiciously large salad",
            calories: 4_000, protein: 200, carbs: 300, fat: 150, fibre: 40,
            sugar: 120, sodium: 6_000, satFat: 60,
            isSuspect: true,
            suspectReason: "The macros do not add up."
        )

        XCTAssertEqual(MealRow.breakdown(for: doubted).count, 7)
        XCTAssertEqual(MealRow.reading(.protein, of: doubted), "200 g")
        XCTAssertEqual(MealRow.reading(.sodium, of: doubted), "6000 mg")
        // And it is still visibly held back: the reason still reaches the
        // spoken row, which is what #560 must not have quietly dropped.
        XCTAssertTrue(row(doubted).accessibilityText.contains("The macros do not add up."))
    }

    // MARK: - The readings

    /// Units come from the nutrient, through the one formatter Meals uses.
    func testEachReadingCarriesItsOwnUnit() {
        let m = meal()
        XCTAssertEqual(MealRow.reading(.protein, of: m), "35 g")
        XCTAssertEqual(MealRow.reading(.carbs, of: m), "70 g")
        XCTAssertEqual(MealRow.reading(.fat, of: m), "18 g")
        XCTAssertEqual(MealRow.reading(.fibre, of: m), "3 g")
        XCTAssertEqual(MealRow.reading(.sugar, of: m), "9 g")
        XCTAssertEqual(MealRow.reading(.sodium, of: m), "1900 mg")
        XCTAssertEqual(MealRow.reading(.saturatedFat, of: m), "6 g")
    }

    // MARK: - VoiceOver

    /// The label still names the meal and its calories.
    func testTheSpokenRowStillNamesTheMealAndItsCalories() {
        let text = row(meal()).accessibilityText
        XCTAssertTrue(text.contains("Lunch"))
        XCTAssertTrue(text.contains("Chicken rice"))
        XCTAssertTrue(text.contains("600 kilocalories"))
    }

    /// And it does NOT carry the seven. They are custom content, read on
    /// demand; folded into the label they would put eight figures between a
    /// reader and the next meal, ten times over on a full day.
    func testTheSpokenRowDoesNotFoldInTheSevenReadings() {
        let text = row(meal()).accessibilityText
        for nutrient in MealRow.breakdown(for: meal()) {
            XCTAssertFalse(
                text.contains(MealRow.reading(nutrient, of: meal())),
                "\(nutrient.displayName) must not be spoken as part of the row's label"
            )
        }
    }

    /// The custom content itself: two clauses, each naming its nutrients in the
    /// fixed order with their units.
    func testTheCustomContentCarriesBothGroupsInOrder() throws {
        let m = meal()
        let macros = try XCTUnwrap(MealRow.spokenReadings(Nutrient.macrosInOrder, of: m))
        let ceilings = try XCTUnwrap(MealRow.spokenReadings(Nutrient.ceilingsInOrder, of: m))

        XCTAssertEqual(macros, "Protein 35 g, Carbs 70 g, Fat 18 g, Fibre 3 g")
        XCTAssertEqual(ceilings, "Sugar 9 g, Sodium 1900 mg, Saturated fat 6 g")
    }

    /// A needs-detail meal says so rather than reading out eight zeros.
    func testANeedsDetailMealSaysItHasNoNumbersYet() {
        let text = row(meal("rice", calories: 0, needsDetail: true)).accessibilityText
        XCTAssertTrue(text.contains("needs detail, no numbers yet"))
        XCTAssertFalse(text.contains("kilocalories"))
    }

    // MARK: - Phone width

    /// Every pill fits its line's EVEN share at phone width (#610).
    ///
    /// The breakdown is two fixed lines, four across then three across, and
    /// since #610 each line is shared evenly rather than drawn at natural
    /// widths. A pill that runs out of room cannot wrap away from it:
    /// `MealStatPill` sets `lineLimit(1)` on both its label and its value, so
    /// the label truncates instead. This is the assertion that stands in for
    /// looking at the row.
    ///
    /// The column is the 390pt phone width less the row's own horizontal
    /// padding and the icon gutter.
    func testEveryPillFitsItsLineAtPhoneWidth() throws {
        try assertEvenShareFits(Nutrient.macrosInOrder)
        try assertEvenShareFits(Nutrient.ceilingsInOrder)
    }

    /// Every pill in the group measures no wider than the even share of its
    /// own line, so nothing truncates when the line is split evenly.
    private func assertEvenShareFits(_ group: [Nutrient]) throws {
        let column: CGFloat = 390 - (Space.lg * 2) - 22 - Space.md
        let evenShare = (column - Space.sm * CGFloat(group.count - 1)) / CGFloat(group.count)
        for nutrient in group {
            XCTAssertLessThanOrEqual(
                try naturalWidth(of: nutrient), evenShare,
                "\(nutrient.shortLabel) needs more than the \(evenShare) pt an even \(group.count)-across share gives it"
            )
        }
    }

    /// The LABEL was the thing that did not fit, and the short one is the fix.
    ///
    /// Pinned in both directions so a tidy-up back to `displayName` on the
    /// pills fails here rather than on the screen: the full name overruns the
    /// even share, the short one does not.
    func testTheFullSaturatedFatLabelIsWhatOverranTheEvenShare() throws {
        let column: CGFloat = 390 - (Space.lg * 2) - 22 - Space.md
        let evenShare = (column - Space.sm * 2) / 3

        XCTAssertGreaterThan(
            try naturalWidth(labelled: Nutrient.saturatedFat.displayName), evenShare,
            "\"Saturated fat\" was never going to fit an even three-across share"
        )
        XCTAssertLessThanOrEqual(
            try naturalWidth(of: .saturatedFat), evenShare,
            "\"Sat fat\" is the whole of the fix and it has to fit"
        )
    }

    /// A reader still hears the full name. The short label is a drawing
    /// decision and must never reach the spoken reading.
    func testTheShortLabelOnlyShortensSaturatedFat() {
        for nutrient in Nutrient.allCases where nutrient != .saturatedFat {
            XCTAssertEqual(nutrient.shortLabel, nutrient.displayName, "\(nutrient)")
        }
        XCTAssertEqual(Nutrient.saturatedFat.displayName, "Saturated fat")
        XCTAssertEqual(Nutrient.saturatedFat.shortLabel, "Sat fat")
    }

    private func naturalWidth(of nutrient: Nutrient) throws -> CGFloat {
        try naturalWidth(labelled: nutrient.shortLabel, value: MealRow.reading(nutrient, of: meal()))
    }

    private func naturalWidth(labelled label: String, value: String = "43 g") throws -> CGFloat {
        let pill = MealStatPill(label: label, value: value)
        return try XCTUnwrap(ImageRenderer(content: pill).uiImage?.size.width)
    }

    /// The whole row renders at phone width with a long description and three
    /// flag chips, which is the case every rung competes for space in.
    func testTheRowRendersAtPhoneWidthWithALongDescriptionAndThreeChips() throws {
        let crowded = meal(
            "Leftover chicken biryani with raita, two papadums and a small gulab jamun from the fridge",
            isSuspect: true,
            suspectReason: "The macros do not add up to the calories."
        )
        let renderer = ImageRenderer(
            content: row(crowded, isDuplicate: true).frame(width: 390)
        )
        let image = try XCTUnwrap(renderer.uiImage)

        XCTAssertEqual(image.size.width, 390, accuracy: 0.5)
        // A sanity band, not a pixel pin: the row must grow for the breakdown
        // and must not run away with the screen.
        XCTAssertGreaterThan(image.size.height, 120)
        XCTAssertLessThan(image.size.height, 400)

        // An eyeball of the worst case, for whoever changes this rung next.
        // The env var has to reach the TEST RUNNER, not xcodebuild, so it is
        // set as `TEST_RUNNER_DEXTER_RENDER_DUMP=1`.
        if ProcessInfo.processInfo.environment["DEXTER_RENDER_DUMP"] != nil {
            let png = try XCTUnwrap(image.pngData())
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("meal-row-560.png")
            try png.write(to: url)
            print("DEXTER_RENDER_DUMP wrote \(url.path)")
        }
    }
}
