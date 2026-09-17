import XCTest
import SwiftUI
@testable import PersonalDashboard

/// The Targets page's three pill rows fit the card at phone width (#623).
///
/// ### Why this exists before the layout shipped, not after
///
/// The row this card copies has been fixed for truncation twice. #561 caught
/// "Saturated fat" overrunning a three-across share on every iPhone, and #610
/// caught the ragged widths that the first fix left behind. Both were shipped
/// defects, both looked healthy on the Mac, and both were invisible in a
/// screenshot because truncation is the one rendering failure that leaves the
/// layout intact: the row keeps its height, its alignment and its spacing, and
/// three characters go missing off the end of one label.
///
/// This card goes further than the row that broke twice. It draws a FOUR-across
/// macros row, where the even share is about 75pt rather than 103pt, it sets the
/// figure a rung larger than the day card does, and it can print a mark under
/// the figure. Any one of those three could be the thing that overruns, so the
/// measurement is taken against the shipped construction rather than trusted.
///
/// ### What is measured
///
/// The real pill, exactly as `MealTargetsSummaryCard.pillRow` builds it,
/// rendered through `ImageRenderer` at its natural size and compared against the
/// even share of the card's inner column. Natural width is the honest number: a
/// pill whose content needs more than its share is a pill that will truncate,
/// whatever the frame it is given.
@MainActor
final class MealTargetsCardRowTests: XCTestCase {

    // MARK: - The card's geometry at phone width
    //
    // `MealsView` gives the card the screen less `Space.lg` either side, and the
    // card's own `Space.lg` padding takes the rest. Spelled out from the tokens
    // rather than hard-coded, so a spacing change lands here.

    private let screen: CGFloat = 390
    private var cardWidth: CGFloat { screen - Space.lg * 2 }
    private var column: CGFloat { cardWidth - Space.lg * 2 }

    /// The even share of the column for a row of `count` pills, spaced the way
    /// the card spaces them.
    private func evenShare(across count: Int) -> CGFloat {
        (column - Space.sm * CGFloat(count - 1)) / CGFloat(count)
    }

    /// A realistic derivation for a 76 kg adult on maintenance. The figures
    /// matter: a pill is as wide as its widest line, and "2300 mg" is a
    /// different measurement from "50 g".
    private var targets: MealTargets {
        MealTargets(
            calories: 2_200, proteinG: 130, carbsG: 250, fatG: 70, fibreG: 30,
            sugarG: 50, sodiumMg: 2_300, satFatG: 20,
            ageYears: 38, biologicalSex: "male", heightCm: 178, weightKg: 76,
            activityLevel: "moderate", goal: "maintain",
            rationale: "Derived for the test.",
            effectiveFrom: Date(timeIntervalSince1970: 1_757_462_400)
        )
    }

    /// One pill exactly as the card builds it, measured at its natural size.
    ///
    /// Same arguments, same order, same `size: .large`. A test that built a
    /// plainer pill would measure a layout the card does not draw.
    private func naturalSize(of nutrient: Nutrient, marked: Bool) throws -> CGSize {
        let value = MealFormat.value(targets.target(for: nutrient), for: nutrient)
        let pill = MealStatPill(
            label: nutrient.shortLabel,
            value: value,
            variant: .neutral,
            fillsWidth: true,
            fillsHeight: marked,
            accessibilityText: "\(nutrient.displayName) target, \(value)",
            note: marked ? "Edited" : nil,
            size: .large
        )
        return try XCTUnwrap(ImageRenderer(content: pill).uiImage?.size)
    }

    /// A pill carrying an arbitrary mark, for measuring what a mark costs.
    private func naturalWidth(of nutrient: Nutrient, marked mark: String) throws -> CGFloat {
        let pill = MealStatPill(
            label: nutrient.shortLabel,
            value: MealFormat.value(targets.target(for: nutrient), for: nutrient),
            variant: .neutral,
            fillsWidth: true,
            fillsHeight: true,
            note: mark,
            size: .large
        )
        return try XCTUnwrap(ImageRenderer(content: pill).uiImage?.size.width)
    }

    // MARK: - The three rows

    /// Calories is one pill across the whole column, so it has the most room of
    /// anything on the card. Asserted anyway: it is the widest VALUE of the
    /// eight, and this is the row that would be reached for first if the layout
    /// ever changed.
    func testTheCaloriesRowFitsTheColumn() throws {
        for marked in [false, true] {
            let width = try naturalSize(of: .calories, marked: marked).width
            XCTAssertLessThanOrEqual(
                width, column,
                "Calories needs \(width) pt of a \(column) pt column"
                + (marked ? " when marked" : "")
            )
        }
    }

    /// The four macros share the row evenly. This is the tightest row on the
    /// card — about 75pt a pill — and the one this test file exists for.
    func testEveryMacroPillFitsTheEvenFourAcrossShare() throws {
        let share = evenShare(across: Nutrient.macrosInOrder.count)
        for marked in [false, true] {
            for nutrient in Nutrient.macrosInOrder {
                let width = try naturalSize(of: nutrient, marked: marked).width
                XCTAssertLessThanOrEqual(
                    width, share,
                    "\(nutrient.shortLabel) needs \(width) pt of a \(share) pt share"
                    + (marked ? " when marked" : "")
                )
            }
        }
    }

    /// The three ceilings share the row evenly, at the larger figure size this
    /// page sets. The day card pins the same row at `.regular`; this pins that
    /// the rung up did not cost the fit.
    func testEveryWatchPillFitsTheEvenThreeAcrossShare() throws {
        let share = evenShare(across: Nutrient.ceilingsInOrder.count)
        for marked in [false, true] {
            for nutrient in Nutrient.ceilingsInOrder {
                let width = try naturalSize(of: nutrient, marked: marked).width
                XCTAssertLessThanOrEqual(
                    width, share,
                    "\(nutrient.shortLabel) needs \(width) pt of a \(share) pt share"
                    + (marked ? " when marked" : "")
                )
            }
        }
    }

    /// And each row fits the column, which is the same statement from the other
    /// end: the sum of the pills plus the gaps between them.
    func testEachRowFitsTheColumn() throws {
        let rows: [(String, [Nutrient])] = [
            ("Calories", [.calories]),
            ("Macros", Nutrient.macrosInOrder),
            ("Watch", Nutrient.ceilingsInOrder)
        ]
        for (name, nutrients) in rows {
            for marked in [false, true] {
                var total = Space.sm * CGFloat(nutrients.count - 1)
                for nutrient in nutrients {
                    total += try naturalSize(of: nutrient, marked: marked).width
                }
                XCTAssertLessThanOrEqual(
                    total, column,
                    "the \(name) row needs \(total) pt of a \(column) pt column"
                    + (marked ? " when marked" : "")
                )
            }
        }
    }

    // MARK: - What must not come back

    /// The sheet's sentence does not fit the box.
    ///
    /// "You changed this" is the wording beside the field in `MealTargetsSheet`
    /// and the obvious thing to reuse here, which is exactly why the
    /// measurement ruling it out is asserted rather than only written in a
    /// comment. A macro pill has about 60pt of content width once its padding is
    /// taken, and the sentence needs more than the whole share.
    func testTheSheetsSentenceDoesNotFitAMacroPill() throws {
        let share = evenShare(across: Nutrient.macrosInOrder.count)
        let sentence = try naturalWidth(of: .protein, marked: "You changed this")
        let mark = try naturalWidth(of: .protein, marked: "Edited")

        XCTAssertGreaterThan(
            sentence, share,
            "\"You changed this\" needs \(sentence) pt of a \(share) pt share"
        )
        XCTAssertLessThanOrEqual(
            mark, share,
            "\"Edited\" needs \(mark) pt of a \(share) pt share"
        )
    }

    /// The full nutrient names do not fit either, which is why the rows take
    /// `shortLabel`. A change back to `displayName` fails here.
    func testTheFullSaturatedFatLabelDoesNotFitTheThreeAcrossShare() throws {
        let share = evenShare(across: Nutrient.ceilingsInOrder.count)
        let pill = MealStatPill(
            label: Nutrient.saturatedFat.displayName,
            value: MealFormat.value(targets.target(for: .saturatedFat), for: .saturatedFat),
            variant: .neutral,
            fillsWidth: true,
            size: .large
        )
        let full = try XCTUnwrap(ImageRenderer(content: pill).uiImage?.size.width)
        XCTAssertGreaterThan(
            full, share,
            "\"Saturated fat\" needs \(full) pt of a \(share) pt share"
        )
    }

    // MARK: - What the size knob must not disturb

    /// `.large` moves the figure and nothing else. The label is an eyebrow at
    /// both sizes, so a pill only ever grows by what the taller figure costs.
    func testTheLargeSizeGrowsTheFigureAndNotTheLabel() throws {
        for nutrient in Nutrient.macrosInOrder {
            let value = MealFormat.value(targets.target(for: nutrient), for: nutrient)
            let regular = MealStatPill(label: nutrient.shortLabel, value: value)
            let large = MealStatPill(label: nutrient.shortLabel, value: value, size: .large)
            let regularSize = try XCTUnwrap(ImageRenderer(content: regular).uiImage?.size)
            let largeSize = try XCTUnwrap(ImageRenderer(content: large).uiImage?.size)

            XCTAssertGreaterThan(largeSize.height, regularSize.height, nutrient.displayName)
            // The label is what sets the width on these four, so the width is
            // unchanged unless the figure was the wider of the two lines.
            XCTAssertGreaterThanOrEqual(largeSize.width, regularSize.width, nutrient.displayName)
        }
    }

    /// Every caller that predates the knob keeps `.regular`. The day card's own
    /// suite measures those pills; this only pins that the default did not move.
    func testTheDefaultSizeIsRegular() throws {
        let value = MealFormat.value(targets.target(for: .sodium), for: .sodium)
        let defaulted = MealStatPill(label: Nutrient.sodium.shortLabel, value: value)
        let explicit = MealStatPill(label: Nutrient.sodium.shortLabel, value: value, size: .regular)
        let a = try XCTUnwrap(ImageRenderer(content: defaulted).uiImage?.size)
        let b = try XCTUnwrap(ImageRenderer(content: explicit).uiImage?.size)
        XCTAssertEqual(a.width, b.width, accuracy: 0.5)
        XCTAssertEqual(a.height, b.height, accuracy: 0.5)
    }
}
