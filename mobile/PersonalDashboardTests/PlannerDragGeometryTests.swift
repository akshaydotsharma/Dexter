import XCTest
@testable import PersonalDashboard

/// Drag-to-create geometry (#687 round 3): y to time, snapping, drag down and
/// up, the 15 minute minimum, and clamping to the day.
final class PlannerDragGeometryTests: XCTestCase {
    private let h: CGFloat = 60   // one point per minute, so y reads as minutes
    private typealias G = PlannerDragGeometry

    private func y(_ hour: Int, _ minute: Int) -> CGFloat { CGFloat(hour * 60 + minute) }

    func testYMapsToMinutesAndClampsToTheDay() {
        XCTAssertEqual(G.minute(atY: 90, hourHeight: h), 90)
        XCTAssertEqual(G.minute(atY: -40, hourHeight: h), 0)
        XCTAssertEqual(G.minute(atY: 99_999, hourHeight: h), 1440)
        XCTAssertEqual(G.minute(atY: 26, hourHeight: 52), 30, accuracy: 0.001, "half of a 52pt hour")
    }

    func testDragDownSnapsTheEndToTheNearestQuarterHour() {
        let r = G.range(anchorY: y(14, 5), currentY: y(15, 20), hourHeight: h)
        XCTAssertEqual(r, .init(start: 14 * 60, end: 15 * 60 + 15), "press at 2:05 starts at 2:00; 3:20 rounds to 3:15")
    }

    func testTheStartSnapsDownWhereverThePressLands() {
        XCTAssertEqual(G.range(anchorY: y(14, 14), currentY: y(15, 0), hourHeight: h).start, 14 * 60)
    }

    func testAShortDragDownIsAtLeastOneStep() {
        let r = G.range(anchorY: y(9, 0), currentY: y(9, 5), hourHeight: h)
        XCTAssertEqual(r, .init(start: 9 * 60, end: 9 * 60 + 15))
        XCTAssertEqual(r.minutes, 15)
    }

    func testDragUpMovesTheStartAndKeepsThePressStep() {
        let r = G.range(anchorY: y(14, 5), currentY: y(13, 10), hourHeight: h)
        XCTAssertEqual(r, .init(start: 13 * 60 + 15, end: 14 * 60 + 15), "Google Calendar: 1:15 to 2:15")
    }

    func testDragAboveMidnightClampsToTheDayStart() {
        let r = G.range(anchorY: y(0, 30), currentY: -200, hourHeight: h)
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, 45)
    }

    func testDragPastMidnightClampsToTheDayEnd() {
        let r = G.range(anchorY: y(23, 0), currentY: 99_999, hourHeight: h)
        XCTAssertEqual(r, .init(start: 23 * 60, end: 1440))
    }

    func testAPressInTheLastQuarterStillMakesAValidRange() {
        let r = G.range(anchorY: y(23, 55), currentY: y(23, 56), hourHeight: h)
        XCTAssertEqual(r, .init(start: 23 * 60 + 45, end: 1440))
    }

    func testATapMakesThirtyMinutesFromTheSnappedPoint() {
        XCTAssertEqual(G.tapRange(atY: y(10, 40), hourHeight: h), .init(start: 10 * 60 + 30, end: 11 * 60))
    }

    func testATapNearMidnightIsPulledBackIntoTheDay() {
        XCTAssertEqual(G.tapRange(atY: y(23, 50), hourHeight: h), .init(start: 23 * 60 + 30, end: 1440))
    }

    func testRangesAreAlwaysAtLeastFifteenMinutes() {
        for a in stride(from: CGFloat(0), through: 1440, by: 7) {
            for c in stride(from: CGFloat(-30), through: 1470, by: 11) {
                let r = G.range(anchorY: a, currentY: c, hourHeight: h)
                XCTAssertGreaterThanOrEqual(r.minutes, 15, "anchor \(a) current \(c)")
                XCTAssertGreaterThanOrEqual(r.start, 0)
                XCTAssertLessThanOrEqual(r.end, 1440)
                XCTAssertEqual(r.start % 15, 0)
                XCTAssertEqual(r.end % 15, 0)
            }
        }
    }

    func testDatesAreOffsetsFromTheDayStart() {
        let dayStart = Date(timeIntervalSince1970: 1_800_000_000)
        let d = G.dates(.init(start: 90, end: 150), dayStart: dayStart)
        XCTAssertEqual(d.start, dayStart.addingTimeInterval(5400))
        XCTAssertEqual(d.end, dayStart.addingTimeInterval(9000))
    }

    func testDragThreshold() {
        XCTAssertFalse(G.isDrag(from: .zero, to: CGPoint(x: 2, y: 2)))
        XCTAssertTrue(G.isDrag(from: .zero, to: CGPoint(x: 0, y: 5)))
    }
}
