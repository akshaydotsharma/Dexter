import XCTest
import AppKit
import SwiftUI
@testable import DexterMac

/// Single click versus double click on the Planner (#687 round 6), driven with
/// real `NSEvent` click counts on REAL hosted views: a day column with its
/// tiles, and the To-plan inspector with its rows.
///
/// The Google Calendar model: one click on a tile opens its quick view, a
/// double click opens the editor and leaves no quick view behind. One click
/// on a To-plan row selects it, a double click opens the Tasks editor, and a
/// press plus a move lifts the card. A double click must never lift, and a
/// drag must never open the editor.
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
    /// The first opens the quick view; the second opens the editor and must
    /// leave no quick view behind.
    func testADoubleClickOpensTheEditorAndLeavesNoQuickView() throws {
        let state = State()
        let h = try tileHarness(state)
        click(h, count: 1)
        click(h, count: 2)
        XCTAssertEqual(state.log, ["select b-focus", "open b-focus"])
        XCTAssertEqual(state.editorID, "b-focus")
        XCTAssertNil(state.quickViewID, "no quick view is left open after a double click")
        h.window.contentView = nil
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
            onOpen: { state.open($0.task.id) },
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

    func testOneClickOnARowSelectsItAndLiftsNothing() throws {
        let state = State()
        let h = try rowHarness(state)
        let p = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        h.source.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn))
        h.source.mouseUp(with: mouse(.leftMouseUp, at: p, windowNumber: h.wn))
        XCTAssertEqual(state.log, ["select t-okrs"])
        XCTAssertNil(state.editorID)
        XCTAssertNil(h.coordinator.payload, "a click lifts nothing")
        h.window.contentView = nil
    }

    func testADoubleClickOnARowOpensTheEditorAndLiftsNoCard() throws {
        let state = State()
        let h = try rowHarness(state)
        let p = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        for count in 1...2 {
            h.source.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn, clicks: count))
            // A hand is never perfectly still: 1pt of jitter, under the 3pt pick-up.
            h.source.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: p.x + 1, y: p.y), windowNumber: h.wn, clicks: count))
            h.source.mouseUp(with: mouse(.leftMouseUp, at: p, windowNumber: h.wn, clicks: count))
        }
        XCTAssertEqual(state.editorID, "t-okrs", "the double click opens the Tasks editor")
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

    func testARightClickOnARowOffersEditAndDelete() throws {
        var ran: [PlannerTileCommand] = []
        let h = try rowHarness(State()) { ran.append($0) }
        let p = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        let menu = try XCTUnwrap(h.source.menu(for: mouse(.rightMouseDown, at: p, windowNumber: h.wn)))
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Edit…", "Delete…"])
        for item in menu.items where !item.isSeparatorItem {
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
        }
        XCTAssertEqual(ran, [.edit, .delete])
        h.window.contentView = nil
    }
}

private extension NSView {
    func allSubviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { v -> [T] in ((v as? T).map { [$0] } ?? []) + v.allSubviews(of: type) }
    }
}
