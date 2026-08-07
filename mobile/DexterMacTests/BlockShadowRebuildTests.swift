import XCTest
import SwiftUI
import AppKit
@testable import DexterMac

/// Hovering a block must not rebuild the block (#446).
///
/// ### The bug this exists to prevent coming back
///
/// `BlockShadow` used to read `if dragging { content.shadowLg() } else if
/// hovering { content.shadowMd() } else { content.shadowSm() }`. That puts
/// `content` in three arms of a `_ConditionalContent`, and swapping arms means
/// SwiftUI destroys the subtree in the old arm and builds a fresh one in the
/// new. The whole card, every time the pointer arrives or leaves.
///
/// Views are values, so almost everything survived that invisibly. An
/// `NSViewRepresentable` did not: the rebuild ran `dismantleNSView` on the
/// coordinator holding the open attach popover, which closed it, and because a
/// teardown must not write to a binding whose view is going away the binding
/// stayed `true` — so the next re-render opened a second one. What the user saw
/// was *"I see the pop-up and then it disappears; when I move my mouse it comes
/// back"*, reported three times across three wrong diagnoses.
///
/// It was finally caught by a probe that logged `makeNSView` / `dismantleNSView`
/// and did nothing but set `hoveredBlock`:
///
/// ```
/// 3.018 probe hovering the block
/// 3.032 makeNSView c=168
/// 3.184 dismantleNSView c=801
/// ```
///
/// This test is that probe, without the app. The assertion is deliberately
/// about IDENTITY (one `makeNSView` across the flip) rather than about popovers,
/// because the popover was only the loudest casualty — a rebuild on every hover
/// silently discards `@State`, restarts `.task`, and drops first responder
/// anywhere else in the card too.
@MainActor
final class BlockShadowRebuildTests: XCTestCase {

    /// Counts how many times SwiftUI built the wrapped subtree.
    private final class BuildCount {
        var made = 0
        var dismantled = 0
    }

    /// Stands in for any `NSViewRepresentable` inside a card — the attach
    /// popover's anchor is the one that mattered.
    private struct CountingRepresentable: NSViewRepresentable {
        let counter: BuildCount

        func makeNSView(context: Context) -> NSView {
            counter.made += 1
            return NSView(frame: .zero)
        }

        func updateNSView(_ nsView: NSView, context: Context) {}

        static func dismantleNSView(_ nsView: NSView, coordinator: ()) {}
    }

    private struct Harness: View {
        let counter: BuildCount
        var dragging = false
        var hovering: Bool

        var body: some View {
            Color.clear
                .frame(width: 200, height: 120)
                .background(CountingRepresentable(counter: counter))
                .modifier(BlockShadow(dragging: dragging, hovering: hovering))
        }
    }

    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
    }

    override func tearDown() async throws {
        window = nil
        try await super.tearDown()
    }

    private func settle(_ view: NSView, turns: Int = 8) async {
        for _ in 0..<turns {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testHoveringDoesNotRebuildWhatTheShadowWraps() async throws {
        let counter = BuildCount()
        let view = NSHostingView(rootView: Harness(counter: counter, hovering: false))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView = view
        await settle(view)

        XCTAssertEqual(counter.made, 1, "built once to begin with")

        view.rootView = Harness(counter: counter, hovering: true)
        await settle(view)

        XCTAssertEqual(
            counter.made, 1,
            "hovering changed the shadow, so it must not have rebuilt the card underneath it"
        )
    }

    /// And back again, because the pointer leaving is the same swap in reverse
    /// and that is the half that fired while the popover was already open.
    func testUnhoveringDoesNotRebuildEither() async throws {
        let counter = BuildCount()
        let view = NSHostingView(rootView: Harness(counter: counter, hovering: true))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView = view
        await settle(view)

        view.rootView = Harness(counter: counter, hovering: false)
        await settle(view)

        XCTAssertEqual(counter.made, 1)
    }

    /// Dragging is the third arm the old code had, and a drag starting under an
    /// open popover would have rebuilt the card just the same.
    func testStartingADragDoesNotRebuildEither() async throws {
        let counter = BuildCount()
        let view = NSHostingView(rootView: Harness(counter: counter, hovering: true))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView = view
        await settle(view)

        view.rootView = Harness(counter: counter, dragging: true, hovering: true)
        await settle(view)

        XCTAssertEqual(counter.made, 1)
    }
}
