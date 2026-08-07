import XCTest
@testable import DexterMac

/// When an `.applicationDefined` popover closes on a click (#446).
///
/// Stated as the experience, because this rule has now been wrong twice and both
/// times the user found it rather than the suite: first the popover would not
/// close for any click, then AppKit closed it while the pointer was still
/// travelling toward it. AppKit's own policy was never inspectable from here —
/// it only arms in a key window, which a background-launched app can never
/// get — so the board took the policy over. This is that policy.
final class PopoverDismissalTests: XCTestCase {

    /// The requirement, in the user's words: *"only when I click outside should
    /// the popover go away."*
    func testAClickOutsideCloses() {
        XCTAssertTrue(
            PopoverDismissal.shouldClose(clickedInsidePopover: false, clickedOnAnchor: false)
        )
    }

    /// *"I should be able to go inside the popover and edit the items."* A click
    /// in the popover is the user working in it, which is the entire reason it
    /// stays up.
    func testAClickInsideThePopoverKeepsItOpen() {
        XCTAssertFalse(
            PopoverDismissal.shouldClose(clickedInsidePopover: true, clickedOnAnchor: false)
        )
    }

    /// Clicking `+N more` again must not close-and-reopen in one click, which
    /// reads as a flicker rather than as a toggle.
    func testAClickOnTheControlThatOpenedItIsNotOutside() {
        XCTAssertFalse(
            PopoverDismissal.shouldClose(clickedInsidePopover: false, clickedOnAnchor: true)
        )
    }
}
