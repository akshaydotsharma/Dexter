import XCTest
@testable import PersonalDashboard

/// The instant a meal logged onto an earlier day is stamped with (#592).
///
/// The composer reaches every day the calendar reaches, and a day that has
/// ended has no "now" to stamp. Every retrospective meal used to be written at
/// 12:00, so `MealRow` printed "12:00" on a dinner and a whole day's meals sat
/// on one minute. The type answers instead.
///
/// ### Why this is pinned rather than eyeballed
///
/// Each way it can be wrong is quiet. A stamp outside the day would move the
/// meal to the wrong day while the row still reads correctly; a stamp that
/// infers back to a different type would reclassify the meal the next time it is
/// re-estimated without a hint; and four types landing within two hours of each
/// other would make one day's breakfast and lunch read as one meal entered
/// twice. None of those look wrong on screen.
///
/// `Calendar.current` throughout, deliberately. `MealEstimationService
/// .inferredType(at:)` reads the hour in the device time zone, so a fixed test
/// calendar in another zone would break the round trip for a reason that has
/// nothing to do with the rule.
///
/// `MealEstimationService` is main-actor isolated, as every service in the app
/// is, so the suite is annotated whole rather than hopping per call.
@MainActor
final class MealRetrospectiveStampTests: XCTestCase {

    private let calendar = Calendar.current

    /// A day well in the past, so nothing here depends on the hour the suite
    /// runs at.
    private var pastDay: Date {
        calendar.startOfDay(for: Date().addingTimeInterval(-5 * 24 * 60 * 60))
    }

    private func stamp(_ type: MealType, on day: Date? = nil) -> Date {
        MealEstimationService.retrospectiveInstant(
            for: type,
            on: day ?? pastDay,
            calendar: calendar
        )
    }

    private func hourAndMinute(_ date: Date) -> (Int, Int) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? -1, parts.minute ?? -1)
    }

    // MARK: - The hours themselves

    func testEachTypeStampsItsOwnHour() {
        XCTAssertEqual(hourAndMinute(stamp(.breakfast)).0, 8)
        XCTAssertEqual(hourAndMinute(stamp(.lunch)).0, 13)
        XCTAssertEqual(hourAndMinute(stamp(.dinner)).0, 19)
        XCTAssertEqual(hourAndMinute(stamp(.dinner)).1, 30)
        XCTAssertEqual(hourAndMinute(stamp(.snack)).0, 16)
    }

    func testNoTypeStampsMidday() {
        for type in MealType.allCases {
            XCTAssertNotEqual(
                hourAndMinute(stamp(type)).0, 12,
                "\(type.rawValue) is back on the midday stamp #592 removed"
            )
        }
    }

    // MARK: - The stamp stays inside its day

    func testEveryStampSitsInsideTheDayItWasDerivedFor() {
        let start = pastDay
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        for type in MealType.allCases {
            let at = stamp(type)
            XCTAssertGreaterThanOrEqual(at, start, "\(type.rawValue) fell before its day")
            XCTAssertLessThan(at, end, "\(type.rawValue) fell into the next day")
        }
    }

    /// The composer hands over a device-local midnight, but a caller with any
    /// instant inside the day must land on the same stamp.
    func testAnyInstantInsideTheDayGivesTheSameStamp() {
        let midnight = pastDay
        let evening = calendar.date(bySettingHour: 22, minute: 45, second: 0, of: midnight)!
        for type in MealType.allCases {
            XCTAssertEqual(stamp(type, on: midnight), stamp(type, on: evening))
        }
    }

    // MARK: - The round trip

    /// A row re-estimated later with no type hint falls back to the type its own
    /// stamp implies, so the stamp has to imply the type it came from.
    func testTheStampInfersBackToTheTypeItCameFrom() {
        for type in MealType.allCases {
            XCTAssertEqual(
                MealEstimationService.inferredType(at: stamp(type)),
                type,
                "\(type.rawValue) infers back as something else"
            )
        }
    }

    // MARK: - The duplicate window

    /// Two meal types on one retrospective day must not land inside the
    /// duplicate check's two-hour window, or a breakfast and a snack with
    /// similar words would flag each other.
    func testTypesAreFurtherApartThanTheDuplicateWindow() {
        let stamps = MealType.allCases.map { stamp($0) }
        for i in stamps.indices {
            for j in stamps.indices where j > i {
                XCTAssertGreaterThan(
                    abs(stamps[i].timeIntervalSince(stamps[j])),
                    MealDuplicateCheck.window,
                    "\(MealType.allCases[i].rawValue) and \(MealType.allCases[j].rawValue) "
                        + "are inside the duplicate window"
                )
            }
        }
    }

    /// The same meal logged onto the same earlier day twice DOES still land
    /// inside the window, which is the check the composer relies on: the stamp
    /// is deterministic per type, so the two instants are identical.
    func testTheSameMealTwiceOnAnEarlierDayStillFlags() {
        let at = stamp(.dinner)
        let anchor = WallClock.dayAnchor(from: pastDay)
        let first = MealDuplicateCandidate(
            id: "a",
            dayAnchor: anchor,
            mealType: .dinner,
            mealDescription: "Chicken rice and a soup",
            loggedAt: at
        )
        let second = MealDuplicateCandidate(
            id: "pending",
            dayAnchor: anchor,
            mealType: .dinner,
            mealDescription: "chicken rice with soup",
            loggedAt: stamp(.dinner)
        )
        XCTAssertEqual(MealDuplicateCheck.matches(for: second, among: [first]).count, 1)
    }
}
