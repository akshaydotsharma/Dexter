import XCTest
@testable import DexterMac

/// The rules behind the trip chrome's single download (#536).
///
/// One control serves both tabs, so the interesting behaviour is not the
/// button — it is who may write what, and what the chrome reads while the tab
/// is changing. That decision lives in `TripExportControl` on purpose, away
/// from the two views, so it can be tested without a window.
final class TripExportControlTests: XCTestCase {

    // MARK: Per-document availability

    func testAFreshControlOffersNothing() {
        let control = TripExportControl()
        XCTAssertEqual(control.kind, .itinerary)
        XCTAssertFalse(control.isAvailable)
        XCTAssertFalse(control.isRunning)
    }

    func testTheChromeReadsTheOpenTabsOwnAvailability() {
        let control = TripExportControl()
        control.setAvailable(true, for: .itinerary)
        control.setAvailable(false, for: .expenses)

        control.kind = .itinerary
        XCTAssertTrue(control.isAvailable, "A trip with stops offers the itinerary download")

        control.kind = .expenses
        XCTAssertFalse(control.isAvailable, "An empty ledger offers nothing")
    }

    func testALedgerWithExpensesOffersTheDownloadOverAStoplessTrip() {
        let control = TripExportControl()
        control.setAvailable(false, for: .itinerary)
        control.setAvailable(true, for: .expenses)

        control.kind = .itinerary
        XCTAssertFalse(control.isAvailable)

        control.kind = .expenses
        XCTAssertTrue(control.isAvailable)
    }

    // MARK: The tab-switch seam

    /// SwiftUI gives no ordering guarantee between the parent's
    /// `.onChange(of: tab)` and the incoming child's `.onAppear`. With one
    /// shared flag, whichever ran last would win, and the Itinerary tab
    /// clearing itself on the way out could blank a download the Expenses tab
    /// had already published. Keyed on the document, the late write lands in a
    /// slot nobody is reading.
    func testTheLeavingTabCannotClearTheEnteringTabsDownload() {
        let control = TripExportControl()
        control.setAvailable(true, for: .itinerary)
        control.kind = .itinerary
        XCTAssertTrue(control.isAvailable)

        // The expenses tab appears and publishes first…
        control.setAvailable(true, for: .expenses)
        control.kind = .expenses
        // …then the itinerary tab's teardown runs, late.
        control.setAvailable(false, for: .itinerary)

        XCTAssertTrue(control.isAvailable, "The expenses download survives the itinerary tab leaving")
    }

    /// And the same in the other direction.
    func testTheExpensesTabLeavingLateCannotClearTheItinerary() {
        let control = TripExportControl()
        control.setAvailable(true, for: .expenses)
        control.kind = .expenses
        XCTAssertTrue(control.isAvailable)

        control.setAvailable(true, for: .itinerary)
        control.kind = .itinerary
        control.setAvailable(false, for: .expenses)

        XCTAssertTrue(control.isAvailable, "The itinerary download survives the expenses tab leaving")
    }

    /// The other half of the seam: nothing is INHERITED either. A tab whose own
    /// slot is false shows no download, however loudly the tab just left was
    /// offering one.
    func testSwitchingToAnEmptyTabInheritsNoDownload() {
        let control = TripExportControl()
        control.setAvailable(true, for: .itinerary)
        control.kind = .itinerary
        XCTAssertTrue(control.isAvailable)

        control.kind = .expenses
        XCTAssertFalse(control.isAvailable, "An empty ledger does not inherit the itinerary's download")
    }

    // MARK: Requests

    func testARequestBumpsTheCounterEachTime() {
        let control = TripExportControl()
        let start = control.request
        control.requestExport()
        control.requestExport()
        XCTAssertEqual(control.request, start + 2, "Each press is its own request, so a repeat export still runs")
    }

    // MARK: The spinner

    /// The button stays on screen through a render even when the tab it is
    /// exporting reports nothing available mid-flight, because the view draws
    /// on `isAvailable || isRunning`.
    func testARunningExportKeepsTheControlOnScreen() {
        let control = TripExportControl()
        control.kind = .expenses
        control.setAvailable(true, for: .expenses)
        control.isRunning = true
        control.setAvailable(false, for: .expenses)

        XCTAssertFalse(control.isAvailable)
        XCTAssertTrue(control.isRunning)
    }
}
