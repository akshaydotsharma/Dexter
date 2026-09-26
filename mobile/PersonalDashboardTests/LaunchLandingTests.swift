import XCTest
@testable import PersonalDashboard

/// Where a cold launch lands, and where the Today card's streak pill sits
/// (#665).
final class LaunchLandingTests: XCTestCase {

    // MARK: - The launch default

    /// No `LAUNCH_SECTION`: Today, not Chat. Chat stays the stack's root, so
    /// the path holds exactly one section over it.
    func testAColdLaunchOpensOnToday() {
        XCTAssertEqual(AppRouter.launchPath(launchSection: nil), [.today])
    }

    /// A launch target still overrides the default.
    func testALaunchSectionStillWins() {
        XCTAssertEqual(AppRouter.launchPath(launchSection: "habits"), [.habits])
        XCTAssertEqual(AppRouter.launchPath(launchSection: "MEALS"), [.meals])
    }

    /// `LAUNCH_SECTION=chat` is the empty stack, which IS chat. Without this
    /// case the new default would make Chat unreachable by script.
    func testLaunchSectionChatIsTheEmptyStack() {
        XCTAssertEqual(AppRouter.launchPath(launchSection: "chat"), [])
    }

    /// The hidden dashboard still redirects, and junk falls back to Today.
    func testDashboardRedirectsAndJunkFallsBackToToday() {
        XCTAssertEqual(AppRouter.launchPath(launchSection: "dashboard"), [.activity])
        XCTAssertEqual(AppRouter.launchPath(launchSection: "nope"), [.today])
    }

    // MARK: - The streak pill over today's column

    /// `HabitWeekTrend` splits its width into 7 equal columns; the pill is
    /// centred on the last one by the same arithmetic.
    func testThePillCentreIsTheLastColumnCentre() {
        // 358pt is a phone card's inner width; 7 columns of 51.14pt.
        let centre = LastColumnLayout.lastColumnCentre(width: 358, columns: 7)
        XCTAssertEqual(centre, 358 - (358.0 / 7) / 2, accuracy: 0.001)
        // At any width, the centre is half a column in from the trailing edge.
        for width in [300.0, 420.0, 686.0] {
            let c = LastColumnLayout.lastColumnCentre(width: width, columns: 7)
            XCTAssertEqual(width - c, width / 14, accuracy: 0.001)
        }
    }
}
