import XCTest
@testable import PersonalDashboard

/// A ticket value must never carry its own label (#485).
///
/// The card already prints a label above every value, so "Fila D" in the row slot
/// renders as "ROW / fila D": the same word twice, and on a foreign ticket in the
/// wrong language. The prompt asks for the value alone and usually gets it, but at
/// temperature 0.3 the same Monza ticket came back both ways across two runs, so the
/// guarantee lives in `unlabelled` rather than in the prompt.
///
/// These are the cases the sanitizer must get right, and the ones it must leave
/// alone. The second half matters more than the first: a rule that strips too eagerly
/// turns a stand's name into a letter and sends someone to the wrong seat.
final class TicketValueLabelStripTests: XCTestCase {

    private func strip(_ s: String?) -> String? { TaskTicketRead.unlabelled(s) }

    // MARK: - Strips the label

    func testStripsALabelBeforeAColon() {
        XCTAssertEqual(strip("Ore: 08:00"), "08:00")
        XCTAssertEqual(strip("Start: 20:00"), "20:00")
    }

    func testStripsALeadingLabelWordFromACode() {
        XCTAssertEqual(strip("Fila D"), "D")
        XCTAssertEqual(strip("Posto 313"), "313")
        XCTAssertEqual(strip("Gate 12"), "12")
        XCTAssertEqual(strip("Seat 8"), "8")
        XCTAssertEqual(strip("Row 14"), "14")
        XCTAssertEqual(strip("Settore B"), "B")
    }

    // MARK: - Leaves the value alone

    func testKeepsABareTimeWhoseColonIsPartOfIt() {
        // The colon rule must not eat the hour: there is no label here.
        XCTAssertEqual(strip("08:00"), "08:00")
        XCTAssertEqual(strip("9:50 PM"), "9:50 PM")
    }

    func testKeepsAStandsName() {
        // The signage at Monza says these words. Translating or truncating it sends
        // someone looking for a sign that does not exist.
        XCTAssertEqual(
            strip("26b - Tribuna Laterale Destra"),
            "26b - Tribuna Laterale Destra"
        )
        // Two words, but the second is a word rather than a code.
        XCTAssertEqual(strip("Tribuna Centrale"), "Tribuna Centrale")
    }

    func testKeepsAValueThatIsAlreadyBare() {
        XCTAssertEqual(strip("12A"), "12A")
        XCTAssertEqual(strip("D"), "D")
        XCTAssertEqual(strip("I10, I11, I8, I9"), "I10, I11, I8, I9")
    }

    func testKeepsAQualifierThatIsPartOfTheTime() {
        // "Boards" and "Doors" say WHICH time this is, so they belong to the value.
        // They survive because the model returns them without a colon.
        XCTAssertEqual(strip("Boards 18:20"), "Boards 18:20")
    }

    func testKeepsASentenceBeforeAColon() {
        // Two words before the colon is prose, not a label.
        XCTAssertEqual(strip("Doors open: 18:30"), "Doors open: 18:30")
    }

    // MARK: - Degenerate input

    func testEmptyAndNilCollapseToNil() {
        XCTAssertNil(strip(nil))
        XCTAssertNil(strip(""))
        XCTAssertNil(strip("   "))
        XCTAssertNil(strip("null"))
    }
}
