import XCTest
import SwiftUI
import SwiftData
import AppKit
@testable import DexterMac

/// #597: an archived list opened from the Lists Archive rendered "List not
/// found" with an empty body, and the window toolbar drew THREE back chevrons
/// and three action runs.
///
/// One line caused both. `ListDetailContent` resolved the open list from
/// `viewModel.lists`, the ACTIVE collection, so an archived list fell through to
/// the fallback branch. That branch was three loose children (`Spacer`, `Text`,
/// `Spacer`), and a multi-statement `ViewBuilder` body flattens into the parent
/// `VStack` as separate views, so the `.macDetailChrome` applied to
/// `ListDetailContent` was distributed to each one. #374 made exactly this
/// lookup change in `ListsView`'s OUTER branch and left the inner copy behind,
/// which is why the window title read the list's name while its body said the
/// list did not exist.
///
/// ### Why these compare pixels
///
/// The obvious assertion, "the rendered tree contains the item text", cannot be
/// written here: SwiftUI DRAWS `Text` rather than backing it with an
/// `NSTextField`, and a hosted view with no assistive client attached reports an
/// empty accessibility tree, so both readers return nothing for a view that is
/// rendering correctly. Measured 2026-09-16: `subviews` and
/// `accessibilityChildren()` are both empty for this view in both states.
///
/// The invariant that matters is stateable without reading text at all. An
/// archived list must render exactly what the same list renders when it is
/// active. So each test renders both and compares the bitmaps. The fallback is
/// a different picture, which is what makes the comparison bite.
///
/// Everything here runs against an in-memory store. Nothing touches
/// `SwiftDataStore.shared` or the app's own rows.
@MainActor
final class ArchivedListDetailTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        // Off the visible screen: a test must never steal the desktop.
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 700, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    /// The regression. Restore `viewModel.lists.first(where:)` in
    /// `ListDetailContent` and this fails: the archived render becomes the
    /// fallback and stops matching the active one.
    func testAnArchivedListRendersExactlyWhatTheSameListRendersWhenActive() async throws {
        let archived = try await render(archived: true)
        let active = try await render(archived: false)

        XCTAssertEqual(
            archived, active,
            "an archived list opened from the Archive must render its items. It lives in "
            + "`archivedLists`, so the detail must resolve it through `viewModel.list(id:)` "
            + "and not through a search of `viewModel.lists` (#597)."
        )
    }

    /// The oracle's own control. If the fallback and a rendered list were the
    /// same picture, the test above would pass against the unfixed view and
    /// prove nothing.
    func testTheFallbackIsADifferentPictureFromARenderedList() async throws {
        let list = try await render(archived: false)
        let missing = try await render(archived: false, overrideId: UUID())

        XCTAssertNotEqual(
            list, missing,
            "an id in neither collection must reach the \"List not found\" fallback"
        )
    }

    // MARK: - Rendering

    /// Seeds one list holding one item, hosts the real `ListDetailContent`
    /// against it, and returns the rendered pixels.
    ///
    /// `overrideId` asks the detail for an id the store does not hold, which is
    /// the only deliberate way to reach the fallback branch.
    private func render(archived: Bool, overrideId: UUID? = nil) async throws -> Data {
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let id = UUID()
        store.context.insert(LocalList(
            clientUUID: id,
            title: "Envisso",
            items: [ChecklistItem(text: "Sign the lease")],
            archivedAt: archived ? Date() : nil
        ))
        try store.context.save()

        let viewModel = ListsViewModel(service: ChecklistService(store: store))
        await viewModel.load()
        // Guard the fixture, not the view. If the row landed in the wrong
        // collection the comparison above would be measuring the seed.
        if archived {
            XCTAssertTrue(viewModel.lists.isEmpty, "an archived list must not be in the active collection")
            XCTAssertEqual(viewModel.archivedLists.count, 1, "and it must be in the archived one")
        } else {
            XCTAssertEqual(viewModel.lists.count, 1)
        }

        let host = NSHostingView(rootView: AnyView(
            ListDetailContent(viewModel: viewModel, listId: overrideId ?? id)
        ))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 520)
        window.contentView = host
        window.setIsVisible(true)
        await settle(host)

        return try pixels(of: host)
    }

    private func settle(_ view: NSView, _ turns: Int = 20) async {
        for _ in 0..<turns {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// `cacheDisplay` rather than `ImageRenderer`: the latter does not render
    /// AppKit-backed views, and this hierarchy contains a `List`.
    private func pixels(of view: NSView) throws -> Data {
        let rep = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds),
            "the host must produce a bitmap"
        )
        view.cacheDisplay(in: view.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]), "and it must encode")
    }
}
