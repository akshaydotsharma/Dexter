import XCTest
import AppKit
import SwiftUI
@testable import DexterMac

/// Single click versus double click on the Planner (#687 round 6), driven with
/// real `NSEvent` click counts on REAL hosted views: a day column with its
/// tiles, and the To-plan inspector with its rows.
///
/// One model for every item since #695: the first click on a tile, an All
/// Day pill or a To-plan row opens its quick view at once, and a double click
/// lands on the same quick view, never on the editor and never needing a
/// prior select. Edit is one click away in the card. A press plus a move on a
/// To-plan row lifts the card; a double click must never lift, and a drag must
/// never open anything.
@MainActor
final class PlannerClickCountTests: XCTestCase {

    private let hour: CGFloat = 50

    private final class Flipped: NSView { override var isFlipped: Bool { true } }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// What the Planner holds, reduced to the two fields these tests are about.
    /// `select` and `open` do exactly what `PlannerView.tapped` / `openItem` do
    /// to them: one click shows the quick view, opening clears it.
    private final class State {
        var quickViewID: String?
        var editorID: String?
        var log: [String] = []
        func select(_ id: String) { quickViewID = id; log.append("select \(id)") }
        func open(_ id: String) { quickViewID = nil; editorID = id; log.append("open \(id)") }
    }

    // MARK: - Tiles

    private struct TileHarness {
        let window: NSWindow
        let host: NSView
        let click: PlannerTileClickView
        var wn: Int { window.windowNumber }
    }

    private func tileHarness(_ state: State, commands: @escaping (PlannerTileCommand, PlannerItem) -> Void = { _, _ in }) throws -> TileHarness {
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let block = PlannerItem(
            id: "b-focus", title: "Focus", detail: "Dexter block", source: .manual,
            start: dayStart.addingTimeInterval(10 * 3600), end: dayStart.addingTimeInterval(12 * 3600),
            durationMinutes: 120, origin: .block("b1"), taskUUID: nil,
            priority: .none, overdueDays: 0, completed: false
        )
        let handlers = PlannerDraftHandlers(
            draft: nil, onChange: { _, _ in }, onCommit: { _, _ in },
            popoverPresented: .constant(false), quickCreate: { AnyView(EmptyView()) }
        )
        let actions = PlannerTileActions(quickViewID: nil, event: { _ in nil }, run: commands, dismissQuickView: {})
        let column = PlannerDayColumn(
            day: PlannerDay(day: dayStart, allDay: [], timed: [block]),
            visible: Set(PlannerSource.allCases), now: dayStart, hourHeight: hour,
            onTapItem: { state.select($0.id) }, draft: handlers,
            onOpenItem: { state.open($0.id) }
        )
        .environment(\.plannerTileActions, actions)
        .frame(width: 300, height: hour * 24)
        let host = NSHostingView(rootView: column)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: hour * 24)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let clicks = host.allSubviews(of: PlannerTileClickView.self)
        XCTAssertEqual(clicks.count, 1, "the tile has one click layer")
        return TileHarness(window: window, host: host, click: try XCTUnwrap(clicks.first))
    }

    /// A press and release with a click count, at a point in the click view.
    private func click(_ h: TileHarness, count: Int) {
        let p = h.click.convert(CGPoint(x: 40, y: 30), to: nil)
        h.click.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn, clicks: count))
        h.click.mouseUp(with: mouse(.leftMouseUp, at: p, windowNumber: h.wn, clicks: count))
    }

    func testTheTileBodyReachesTheClickLayerAndTheEdgeStillReachesTheResizeStrip() throws {
        let h = try tileHarness(State())
        let body = h.click.convert(CGPoint(x: h.click.bounds.midX, y: 30), to: h.host.superview)
        XCTAssertTrue(h.host.hitTest(body) is PlannerTileClickView, "a click on the tile body reaches the click layer")
        let handle = try XCTUnwrap(h.host.allSubviews(of: PlannerResizeHandleView.self).first)
        let edge = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: h.host.superview)
        XCTAssertTrue(h.host.hitTest(edge) is PlannerResizeHandleView, "the bottom edge still reaches the resize strip")
        let empty = h.host.convert(CGPoint(x: 150, y: hour * 18), to: h.host.superview)
        XCTAssertTrue(h.host.hitTest(empty) is PlannerGridPointerView, "empty time still reaches the create layer")
        h.window.contentView = nil
    }

    func testASingleClickOpensTheQuickView() throws {
        let state = State()
        let h = try tileHarness(state)
        click(h, count: 1)
        XCTAssertEqual(state.quickViewID, "b-focus")
        XCTAssertNil(state.editorID, "one click does not open the editor")
        h.window.contentView = nil
    }

    /// AppKit delivers a double click as a count-1 click, then a count-2 click.
    /// Both land on the quick view (#695); neither opens the editor.
    func testADoubleClickOpensTheQuickViewNotTheEditor() throws {
        let state = State()
        let h = try tileHarness(state)
        click(h, count: 1)
        click(h, count: 2)
        XCTAssertEqual(state.log, ["select b-focus", "select b-focus"])
        XCTAssertEqual(state.quickViewID, "b-focus", "the double click shows the options")
        XCTAssertNil(state.editorID, "a double click does not skip to the editor")
        h.window.contentView = nil
    }

    /// A count-2 click alone (the window was not key for the first one, or the
    /// first went elsewhere) still opens the quick view, with no select first.
    func testADoubleClickWithNoPriorClickStillOpensTheQuickView() throws {
        let state = State()
        let h = try tileHarness(state)
        XCTAssertTrue(h.click.acceptsFirstMouse(for: nil), "the first click counts in a window that is not key")
        click(h, count: 2)
        XCTAssertEqual(state.quickViewID, "b-focus")
        XCTAssertNil(state.editorID)
        h.window.contentView = nil
    }

    // MARK: - Clicks over the TEXT (#695 round 3)

    /// Hit-test from the window's content view at a point, then deliver a
    /// double click to whatever the hit test returns, as AppKit would.
    @discardableResult
    private func doubleClick(at windowPoint: CGPoint, in window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        // `hitTest` takes a point in the SUPERVIEW's coordinates.
        guard let hit = content.hitTest(content.superview?.convert(windowPoint, from: nil) ?? windowPoint) else { return nil }
        for count in 1...2 {
            hit.mouseDown(with: mouse(.leftMouseDown, at: windowPoint, windowNumber: window.windowNumber, clicks: count))
            hit.mouseUp(with: mouse(.leftMouseUp, at: windowPoint, windowNumber: window.windowNumber, clicks: count))
        }
        return hit
    }

    func testADoubleClickOnATileTitleOpensItsQuickView() throws {
        let state = State()
        let h = try tileHarness(state)
        // Over the title text: the stripe is 3pt and the text column is
        // padded 5pt, so (14, 7) is on the first glyphs of "Focus".
        let title = h.click.convert(CGPoint(x: 14, y: 7), to: nil)
        let hit = doubleClick(at: title, in: h.window)
        XCTAssertTrue(hit is PlannerTileClickView, "a click on the title reaches the click layer, got \(String(describing: hit))")
        XCTAssertEqual(state.quickViewID, "b-focus")
        XCTAssertNil(state.editorID)
        h.window.contentView = nil
    }

    func testADoubleClickOnAPillTitleOpensItsQuickView() throws {
        let state = State()
        let pill = PlannerItem(
            id: "d-bank", title: "Call the bank", detail: "Task · due today", source: .task,
            start: nil, end: nil, durationMinutes: 0, origin: .taskDue, taskUUID: "t-bank",
            priority: .none, overdueDays: 0, completed: false
        )
        let actions = PlannerTileActions(quickViewID: nil, event: { _ in nil }, run: { _, _ in }, dismissQuickView: {})
        let row = PlannerAllDayRow(items: [pill], onTap: { state.select($0.id) })
            .environment(\.plannerTileActions, actions)
            .frame(width: 400, height: 40)
        let host = NSHostingView(rootView: row)
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let layer = try XCTUnwrap(host.allSubviews(of: PlannerTileClickView.self).first)
        // Glyph at ~8pt, text from ~20pt: aim at the text.
        for x: CGFloat in [10, 30, 50] {
            state.log.removeAll(); state.quickViewID = nil
            let p = layer.convert(CGPoint(x: x, y: layer.bounds.midY), to: nil)
            let hit = doubleClick(at: p, in: window)
            XCTAssertTrue(hit is PlannerTileClickView, "x=\(x): a click on the pill's glyph or text reaches the click layer, got \(String(describing: hit))")
            XCTAssertEqual(state.quickViewID, "d-bank", "x=\(x)")
        }
        window.contentView = nil
    }

    func testADoubleClickOnAToPlanRowTitleOpensItsQuickView() throws {
        let state = State()
        let h = try rowHarness(state)
        // The row's title starts after the 3pt priority stripe and 8pt gap.
        for x: CGFloat in [16, 40, 80] {
            state.log.removeAll(); state.quickViewID = nil
            let p = h.source.convert(CGPoint(x: x, y: 12), to: nil)
            let hit = doubleClick(at: p, in: h.window)
            XCTAssertTrue(hit is PlannerTaskDragSourceView, "x=\(x): a click on the row's title reaches the row, got \(String(describing: hit))")
            XCTAssertEqual(state.quickViewID, "t-okrs", "x=\(x)")
        }
        // The Plan button sits ABOVE the click layer, so it keeps its click.
        let content = try XCTUnwrap(h.window.contentView)
        let plan = h.source.convert(CGPoint(x: h.source.bounds.maxX - 35, y: h.source.bounds.midY), to: nil)
        let planHit = content.hitTest(content.superview?.convert(plan, from: nil) ?? plan)
        XCTAssertFalse(planHit is PlannerTaskDragSourceView, "a click on Plan reaches the button, not the row's click layer")
        h.window.contentView = nil
    }

    // MARK: - All Day pills

    func testOneOrTwoClicksOnAnAllDayPillOpenItsQuickView() throws {
        let state = State()
        let pill = PlannerItem(
            id: "d-bank", title: "Call the bank", detail: "Task · due today", source: .task,
            start: nil, end: nil, durationMinutes: 0, origin: .taskDue, taskUUID: "t-bank",
            priority: .none, overdueDays: 0, completed: false
        )
        let actions = PlannerTileActions(quickViewID: nil, event: { _ in nil }, run: { _, _ in }, dismissQuickView: {})
        let row = PlannerAllDayRow(items: [pill], onTap: { state.select($0.id) })
            .environment(\.plannerTileActions, actions)
            .frame(width: 400, height: 40)
        let host = NSHostingView(rootView: row)
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let layer = try XCTUnwrap(host.allSubviews(of: PlannerTileClickView.self).first, "the pill has the tile's click layer")
        XCTAssertTrue(layer.acceptsFirstMouse(for: nil))
        let p = layer.convert(CGPoint(x: 10, y: 8), to: nil)
        for count in [1, 2] {
            layer.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: window.windowNumber, clicks: count))
            layer.mouseUp(with: mouse(.leftMouseUp, at: p, windowNumber: window.windowNumber, clicks: count))
        }
        XCTAssertEqual(state.log, ["select d-bank", "select d-bank"])
        XCTAssertEqual(state.quickViewID, "d-bank")
        XCTAssertNil(state.editorID, "a pill does not open the editor on a click")
        let menu = try XCTUnwrap(layer.menu(for: mouse(.rightMouseDown, at: p, windowNumber: window.windowNumber)))
        XCTAssertEqual(menu.items.first?.title, "Mark complete", "right click on a task pill offers completion first")
        window.contentView = nil
    }

    func testARightClickOffersEditAndDeleteAndRunsThem() throws {
        var ran: [PlannerTileCommand] = []
        let h = try tileHarness(State()) { cmd, _ in ran.append(cmd) }
        let p = h.click.convert(CGPoint(x: 40, y: 30), to: nil)
        let menu = try XCTUnwrap(h.click.menu(for: mouse(.rightMouseDown, at: p, windowNumber: h.wn)))
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["Edit…", "Delete…"])
        for item in menu.items where !item.isSeparatorItem {
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
        }
        XCTAssertEqual(ran, [.edit, .delete])
        h.window.contentView = nil
    }

    // MARK: - To-plan rows

    private struct RowHarness {
        let window: NSWindow
        let source: PlannerTaskDragSourceView
        let coordinator: PlannerTaskDragCoordinator
        var wn: Int { window.windowNumber }
    }

    private func rowHarness(_ state: State, commands: @escaping (PlannerTileCommand) -> Void = { _ in }) throws -> RowHarness {
        let coordinator = PlannerTaskDragCoordinator()
        let c = PlannerEngine.Candidate(
            task: PlannerTask(id: "t-okrs", title: "Draft OKRs", priority: .p1, due: nil, completed: false),
            estimateMinutes: 45, overdueDays: 0
        )
        let inspector = PlannerInspector(
            candidates: [c], onPlan: { _ in },
            onSelect: { state.log.append("select \($0.task.id)") },
            onQuickView: { state.select($0.task.id) },
            onCommand: { cmd, _ in commands(cmd) }
        )
        .frame(width: 270, height: 400)
        .environment(\.plannerTaskDrag, coordinator)
        let host = NSHostingView(rootView: inspector)
        host.frame = CGRect(x: 0, y: 0, width: 270, height: 400)
        let root = Flipped(frame: host.frame)
        root.addSubview(host)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        let source = try XCTUnwrap(host.allSubviews(of: PlannerTaskDragSourceView.self).first)
        return RowHarness(window: window, source: source, coordinator: coordinator)
    }

    func testOneClickOnARowOpensItsQuickViewAndLiftsNothing() throws {
        let state = State()
        let h = try rowHarness(state)
        XCTAssertTrue(h.source.acceptsFirstMouse(for: nil), "the first click counts in a window that is not key")
        let p = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        h.source.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn))
        h.source.mouseUp(with: mouse(.leftMouseUp, at: p, windowNumber: h.wn))
        XCTAssertEqual(state.log, ["select t-okrs", "select t-okrs"], "highlight, then the quick view, in one click")
        XCTAssertEqual(state.quickViewID, "t-okrs")
        XCTAssertNil(state.editorID)
        XCTAssertNil(h.coordinator.payload, "a click lifts nothing")
        h.window.contentView = nil
    }

    func testADoubleClickOnARowOpensItsQuickViewAndLiftsNoCard() throws {
        let state = State()
        let h = try rowHarness(state)
        let p = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        for count in 1...2 {
            h.source.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn, clicks: count))
            // A hand is never perfectly still: 1pt of jitter, under the 3pt pick-up.
            h.source.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: p.x + 1, y: p.y), windowNumber: h.wn, clicks: count))
            h.source.mouseUp(with: mouse(.leftMouseUp, at: p, windowNumber: h.wn, clicks: count))
        }
        XCTAssertEqual(state.quickViewID, "t-okrs", "the double click shows the options")
        XCTAssertNil(state.editorID, "a double click does not skip to the editor")
        XCTAssertNil(h.coordinator.payload, "no card was lifted")
        XCTAssertNil(h.source.floatingCard, "no floating card window")
        XCTAssertFalse(h.source.isDragging)
        h.window.contentView = nil
    }

    func testADragLiftsTheCardAndOpensNoEditor() throws {
        let state = State()
        let h = try rowHarness(state)
        let p = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        h.source.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn))
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: p.x - 30, y: p.y), windowNumber: h.wn))
        XCTAssertEqual(h.coordinator.payload?.taskID, "t-okrs", "a press plus a move lifts the card")
        XCTAssertNotNil(h.source.floatingCard)
        h.source.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: p.x - 60, y: p.y), windowNumber: h.wn, clicks: 2))
        settle(0.5)
        XCTAssertTrue(state.log.isEmpty, "a drag neither selects nor opens: \(state.log)")
        XCTAssertNil(state.editorID)
        h.window.contentView = nil
    }

    func testARightClickOnARowOffersCompleteEditAndDelete() throws {
        var ran: [PlannerTileCommand] = []
        let h = try rowHarness(State()) { ran.append($0) }
        let p = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        let menu = try XCTUnwrap(h.source.menu(for: mouse(.rightMouseDown, at: p, windowNumber: h.wn)))
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Mark complete", "Edit…", "Delete…"])
        for item in menu.items where !item.isSeparatorItem {
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
        }
        XCTAssertEqual(ran, [.toggleComplete, .edit, .delete])
        h.window.contentView = nil
    }
}

private extension NSView {
    func allSubviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { v -> [T] in ((v as? T).map { [$0] } ?? []) + v.allSubviews(of: type) }
    }
}
