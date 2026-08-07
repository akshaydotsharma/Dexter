import XCTest
import AppKit
@testable import DexterMac

/// The board-owned pull-down menu (#446).
///
/// The whole reason this exists instead of SwiftUI's `Menu` is a guarantee no
/// UI test can make on this machine: an `NSMenu` cannot be opened by an agent
/// (its tracking loop needs a key window, which a background-launched app never
/// gets), so the behaviour had to be moved somewhere assertable. It is here.
@MainActor
final class MacMenuButtonTests: XCTestCase {

    /// The bug, in the user's words: *"when I say 'Add an existing task', the
    /// popover shows and then hides and when I move my mouse the popover comes
    /// back."*
    ///
    /// An `NSPopover` shown from a menu item's action is shown while the menu is
    /// still dismissing, and goes down with it — leaving the SwiftUI binding
    /// reading `true`, so the next re-render (a mouse move, on this surface) put
    /// it straight back up. Parking the closure and running it after `popUp` has
    /// returned is what makes that impossible.
    func testChoosingAnItemParksTheActionRatherThanRunningIt() {
        var ran = false
        let target = MacMenuTarget()
        let item = MacMenuEntry
            .item(title: "Attach existing task…") { ran = true }
            .makeItem(target: target)

        target.pick(item)

        XCTAssertFalse(ran, "the action must not run while the menu is still on screen")
        target.chosen?()
        XCTAssertTrue(ran, "and must run once it is gone")
    }

    /// The parking above only happens if the item is actually wired to the
    /// target rather than to a closure AppKit would invoke itself.
    func testAnItemIsWiredToTheTargetNotToItsOwnHandler() {
        let target = MacMenuTarget()
        let item = MacMenuEntry.item(title: "Delete block") {}.makeItem(target: target)

        XCTAssertIdentical(item.target as AnyObject, target)
        XCTAssertEqual(item.action, #selector(MacMenuTarget.pick(_:)))
    }

    /// Nothing picked, nothing to run. Dismissing a menu with Escape must not
    /// fire whatever was chosen the last time it was open.
    func testDismissingWithoutChoosingLeavesNothingToRun() {
        XCTAssertNil(MacMenuTarget().chosen)
    }

    /// The state group renders as checkmarks in one list rather than as a
    /// submenu, so which state a block is in is readable without a second hop.
    func testTheOnEntryIsTheCheckedItem() {
        let target = MacMenuTarget()
        let on = MacMenuEntry.item(title: "Active", isOn: true) {}.makeItem(target: target)
        let off = MacMenuEntry.item(title: "Someday", isOn: false) {}.makeItem(target: target)

        XCTAssertEqual(on.state, .on)
        XCTAssertEqual(off.state, .off)
    }

    func testSeparatorsAndHeadersAreNotSelectable() {
        let target = MacMenuTarget()

        XCTAssertTrue(MacMenuEntry.separator.makeItem(target: target).isSeparatorItem)
        XCTAssertNil(MacMenuEntry.header("State").makeItem(target: target).action)
    }
}
