import XCTest
import SwiftUI
@testable import PersonalDashboard

/// The six vital rows fit the Targets page at phone width (#623).
///
/// ### The defect this pins shut
///
/// The page sets its rows a rung up, at `.edBodyMedium`. The sheet's sprung row
/// — label at its natural width, control in a fixed 180pt box — cannot carry
/// that: the first render of the page printed "Biologic…" where "Biological
/// sex" should be, because a sprung `Text` is what gives way when an `HStack`
/// runs out of width. Narrowing the control instead moved the failure rather
/// than fixing it, and printed "Moderately acti…".
///
/// Both ends are asserted here, because the fix is a DIVISION of 302pt and
/// either side of it can be the one that overruns. A change to the label
/// column that relieves one end tightens the other, and this file says so.
///
/// ### Why it is a measurement and not a screenshot
///
/// For the reason `MealDayCardWatchRowTests` gives: truncation leaves the
/// layout looking healthy. The row keeps its height, its alignment and its
/// spacing, and three characters go missing off the end of one label.
@MainActor
final class MealTargetsVitalRowTests: XCTestCase {

    private let screen: CGFloat = 390
    private var column: CGFloat { MealVitalRowMetrics.column(screenWidth: screen) }

    private func naturalWidth<V: View>(_ view: V) throws -> CGFloat {
        try XCTUnwrap(ImageRenderer(content: view).uiImage?.size.width)
    }

    private func labelWidth(_ text: String) throws -> CGFloat {
        try naturalWidth(Text(text).font(.edBodyMedium).lineLimit(1))
    }

    /// Every label the page prints in the left column of a vital row, whichever
    /// control sits beside it.
    private let labels = ["Age", "Biological sex", "Height", "Weight", "Activity", "Goal"]

    /// Every option the three dropdowns can be showing. The trigger prints the
    /// SELECTED one, so the widest of them is what the control has to hold.
    private var options: [String] {
        BiologicalSex.allCases.map(\.displayName)
            + ActivityLevel.allCases.map(\.displayName)
            + MealGoal.allCases.map(\.displayName)
    }

    // MARK: - The division

    /// No label truncates in its column. "Biological sex" is the long one and
    /// the one that shipped truncated.
    func testEveryVitalLabelFitsTheLabelColumn() throws {
        for label in labels {
            let width = try labelWidth(label)
            XCTAssertLessThanOrEqual(
                width, MealVitalRowMetrics.labelColumn,
                "\"\(label)\" needs \(width) pt of a \(MealVitalRowMetrics.labelColumn) pt column"
            )
        }
    }

    /// No selected option truncates in the control. "Moderately active" is the
    /// long one, and it is the one that truncated when the label column was
    /// widened to give the label more room.
    func testEveryDropdownOptionFitsTheControl() throws {
        let available = MealVitalRowMetrics.triggerWidth(inColumn: column)
            - MealVitalRowMetrics.triggerFurniture
        for option in options {
            let width = try labelWidth(option)
            XCTAssertLessThanOrEqual(
                width, available,
                "\"\(option)\" needs \(width) pt of the \(available) pt the control leaves for text"
            )
        }
    }

    /// The two halves add up to no more than the row. The same statement from
    /// the other end, and the one that fails if a token changes underneath both.
    func testTheLabelColumnAndTheControlFitTheRow() {
        let total = MealVitalRowMetrics.labelColumn
            + Space.sm
            + MealVitalRowMetrics.triggerWidth(inColumn: column)
        XCTAssertLessThanOrEqual(total, column, "a vital row needs \(total) pt of a \(column) pt row")
    }

    /// The chevron measures what the furniture figure says it does. It is the
    /// one part of the control's width that is not made of tokens, so a change
    /// to its point size has to fail here rather than on a phone.
    func testTheChevronMeasuresWhatTheFurnitureAssumes() throws {
        let chevron = Image(systemName: "chevron.down")
            .font(.system(size: MealVitalRowMetrics.chevronPointSize, weight: .medium))
        let width = try naturalWidth(chevron)
        XCTAssertEqual(width, MealVitalRowMetrics.chevronWidth, accuracy: 0.5)
    }

    // MARK: - The number rows

    /// The unit column holds the widest unit any caller passes. "kcal" reaches
    /// this row through the targets sheet's eight fields; the page's own six
    /// units are shorter (#616 is the same defect one column over).
    func testTheUnitColumnHoldsTheWidestUnit() throws {
        let units = Nutrient.allCases.map(\.unit) + ["yrs", "cm", "kg"]
        for unit in units {
            let width = try naturalWidth(Text(unit).font(.edFootnote).lineLimit(1))
            XCTAssertLessThanOrEqual(width, 36, "\"\(unit)\" needs \(width) pt of a 36 pt unit column")
        }
    }

    // MARK: - What must not move

    /// The sheet is unchanged. It still uses `.regular`, where the label is
    /// sprung rather than columned, and its own longest label still fits the
    /// room a 180pt control leaves it at 390pt phone width.
    func testTheSheetsRegularRowIsUntouched() throws {
        // The sheet's own column: the screen, less its padding, less the
        // block's.
        let sheetColumn = screen - Space.lg * 2 - Space.md * 2
        let available = sheetColumn - 180 - Space.sm * 2
        for label in labels {
            let width = try naturalWidth(Text(label).font(.edFootnote).lineLimit(1))
            XCTAssertLessThanOrEqual(
                width, available,
                "\"\(label)\" needs \(width) pt of the \(available) pt the sheet's row leaves it"
            )
        }
    }
}
