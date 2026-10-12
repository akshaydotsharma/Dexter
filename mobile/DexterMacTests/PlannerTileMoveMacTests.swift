import XCTest
import AppKit
import SwiftUI
@testable import DexterMac

/// Drag a tile's body to a new time on the Mac (#697), driven with real
/// `NSEvent`s on the click layer of a REAL hosted day column, the way
/// `PlannerClickCountTests` drives clicks. A background-launched app never
/// becomes key, so this is the only agent-run proof of the drag
/// (`project_macos_gestures_untestable_headlessly`).
@MainActor
final class PlannerTileMoveMacTests: XCTestCase {

    private let hour: CGFloat = 50
    private let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    private func at(_ h: Double) -> Date { dayStart.addingTimeInterval(h * 3600) }

    private func item(_ id: String, _ origin: PlannerItem.Origin, _ source: PlannerSource, _ sh: Double, _ eh: Double,
                      task: String? = nil) -> PlannerItem {
        PlannerItem(
            id: id, title: id, detail: "", source: source, start: at(sh), end: at(eh),
            durationMinutes: Int((eh - sh) * 60), origin: origin, taskUUID: task,
            priority: .none, overdueDays: 0, completed: false
        )
    }

    private final class Log {
        var moves: [(id: String, start: Date, end: Date)] = []
        var clicks: [String] = []
        var begins = 0
    }

    private struct Harness {
        let window: NSWindow
        let host: NSView
        func layer(_ title: String) -> PlannerTileClickView? {
            host.moveTestSubviews(of: PlannerTileClickView.self).first { $0.label == title }
        }
        var wn: Int { window.windowNumber }
    }

    /// A block 10 to 12, a task due 14:00 to 14:30, a calendar event 16 to
    /// 17, and an event "Overnight" whose tile is cut at midnight.
    private func harness(_ log: Log) -> Harness {
        let block = item("Focus", .block("b1"), .manual, 10, 12)
        let task = item("Call", .taskDue, .task, 14, 14.5, task: "t1")
        let meeting = item("e-review", .event(calendarID: "c"), .work, 16, 17)
        let overnight = item("e-late", .event(calendarID: "c"), .work, 0, 1)
        let events: [String: PlannerEvent] = [
            "e-review": PlannerEvent(id: "review", title: "e-review", location: "", calendarID: "c", calendarTitle: "Work",
                                     source: .work, start: at(16), end: at(17), isAllDay: false, eventKey: "uid-review"),
            // Started the day before, so the tile shows only its last hour.
            "e-late": PlannerEvent(id: "late", title: "e-late", location: "", calendarID: "c", calendarTitle: "Work",
                                   source: .work, start: at(-2), end: at(1), isAllDay: false, eventKey: "uid-late"),
        ]
        let handlers = PlannerDraftHandlers(
            draft: nil, onChange: { _, _ in }, onCommit: { _, _ in },
            popoverPresented: .constant(false), quickCreate: { AnyView(EmptyView()) },
            onMove: { i, s, e in log.moves.append((i.id, s, e)) },
            onMoveBegin: { log.begins += 1 }
        )
        let actions = PlannerTileActions(quickViewID: nil, event: { events[$0.id] }, run: { _, _ in }, dismissQuickView: {})
        let column = PlannerDayColumn(
            day: PlannerDay(day: dayStart, allDay: [], timed: [overnight, block, task, meeting]),
            visible: Set(PlannerSource.allCases), now: dayStart, hourHeight: hour,
            onTapItem: { log.clicks.append($0.id) }, draft: handlers
        )
        .environment(\.plannerTileActions, actions)
        .frame(width: 300, height: hour * 24)
        let host = NSHostingView(rootView: column)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: hour * 24)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return Harness(window: window, host: host)
    }

    /// Press on the layer's body, drag DOWN by `dy` points (negative is up)
    /// in steps, and release. Window y grows upward, so down subtracts.
    private func drag(_ layer: PlannerTileClickView, by dy: CGFloat, in h: Harness, steps: Int = 4) {
        let p = layer.convert(CGPoint(x: 30, y: 8), to: nil)
        layer.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn))
        for i in 1...steps {
            let q = CGPoint(x: p.x, y: p.y - dy * CGFloat(i) / CGFloat(steps))
            layer.mouseDragged(with: mouse(.leftMouseDragged, at: q, windowNumber: h.wn))
        }
        layer.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: p.x, y: p.y - dy), windowNumber: h.wn))
    }

    func testDraggingABlockMovesItSnappedWithItsLength() throws {
        let log = Log()
        let h = harness(log)
        let layer = try XCTUnwrap(h.layer("Focus"))
        XCTAssertNotNil(layer.move, "a block moves")
        drag(layer, by: 1.5 * hour + 6, in: h)   // 1h 30m and a little: snaps to 11:30
        XCTAssertEqual(log.moves.count, 1)
        XCTAssertEqual(log.moves.first?.id, "Focus")
        XCTAssertEqual(log.moves.first?.start, at(11.5))
        XCTAssertEqual(log.moves.first?.end, at(13.5), "same two hours")
        XCTAssertEqual(log.begins, 1)
        XCTAssertTrue(log.clicks.isEmpty, "a drag never opens the quick view")
        XCTAssertNil(layer.anchor)
        XCTAssertFalse(layer.isMoving)
        h.window.contentView = nil
    }

    func testDraggingATaskTileUpMovesIt() throws {
        let log = Log()
        let h = harness(log)
        let layer = try XCTUnwrap(h.layer("Call"))
        drag(layer, by: -2 * hour, in: h)
        XCTAssertEqual(log.moves.first?.id, "Call")
        XCTAssertEqual(log.moves.first?.start, at(12))
        XCTAssertEqual(log.moves.first?.end, at(12.5))
        h.window.contentView = nil
    }

    func testDraggingACalendarEventMovesIt() throws {
        let log = Log()
        let h = harness(log)
        let layer = try XCTUnwrap(h.layer("e-review"))
        XCTAssertNotNil(layer.move, "a timed event moves, in Dexter only")
        drag(layer, by: hour / 4, in: h)
        XCTAssertEqual(log.moves.first?.id, "e-review")
        XCTAssertEqual(log.moves.first?.start, at(16.25))
        XCTAssertEqual(log.moves.first?.end, at(17.25))
        h.window.contentView = nil
    }

    func testAnEventCutAtMidnightDoesNotMove() throws {
        let log = Log()
        let h = harness(log)
        let layer = try XCTUnwrap(h.layer("e-late"))
        XCTAssertNil(layer.move)
        drag(layer, by: hour, in: h)
        XCTAssertTrue(log.moves.isEmpty)
        h.window.contentView = nil
    }

    func testAClickStillOpensTheQuickViewAndNeverMoves() throws {
        let log = Log()
        let h = harness(log)
        let layer = try XCTUnwrap(h.layer("Focus"))
        let p = layer.convert(CGPoint(x: 30, y: 8), to: nil)
        for count in 1...2 {
            layer.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn, clicks: count))
            layer.mouseUp(with: mouse(.leftMouseUp, at: p, windowNumber: h.wn, clicks: count))
        }
        XCTAssertEqual(log.clicks, ["Focus", "Focus"], "single and double click both open the quick view")
        XCTAssertTrue(log.moves.isEmpty)
        h.window.contentView = nil
    }

    /// A hand that wobbles a couple of points while clicking is a click.
    func testAWobbleUnderTheThresholdIsAClick() throws {
        let log = Log()
        let h = harness(log)
        let layer = try XCTUnwrap(h.layer("Focus"))
        let p = layer.convert(CGPoint(x: 30, y: 8), to: nil)
        layer.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn))
        layer.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: p.x + 1, y: p.y - 2), windowNumber: h.wn))
        layer.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: p.x + 1, y: p.y - 2), windowNumber: h.wn))
        XCTAssertEqual(log.clicks, ["Focus"])
        XCTAssertTrue(log.moves.isEmpty)
        XCTAssertEqual(log.begins, 0)
        h.window.contentView = nil
    }

    /// A drag released where it started (past the threshold and back) writes
    /// nothing: the start does not change.
    func testADragBackToTheStartWritesNothing() throws {
        let log = Log()
        let h = harness(log)
        let layer = try XCTUnwrap(h.layer("Focus"))
        let p = layer.convert(CGPoint(x: 30, y: 8), to: nil)
        layer.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn))
        layer.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: p.x, y: p.y - 30), windowNumber: h.wn))
        layer.mouseDragged(with: mouse(.leftMouseDragged, at: p, windowNumber: h.wn))
        layer.mouseUp(with: mouse(.leftMouseUp, at: p, windowNumber: h.wn))
        XCTAssertTrue(log.moves.isEmpty)
        XCTAssertTrue(log.clicks.isEmpty, "it was a drag, so no quick view either")
        h.window.contentView = nil
    }

    func testRightClickStillGivesTheMenuAndTheEdgeStillResizes() throws {
        let log = Log()
        let h = harness(log)
        let layer = try XCTUnwrap(h.layer("Focus"))
        let p = layer.convert(CGPoint(x: 30, y: 8), to: nil)
        XCTAssertNotNil(layer.menu(for: mouse(.rightMouseDown, at: p, windowNumber: h.wn)), "right click gives the menu")
        let handles = h.host.moveTestSubviews(of: PlannerResizeHandleView.self)
        XCTAssertEqual(handles.count, 2, "the block and the task keep their resize strips; events get none")
        // The topmost strip in the window (largest window y) is the block's.
        let handle = try XCTUnwrap(handles.max { a, b in
            a.convert(CGPoint.zero, to: nil as NSView?).y < b.convert(CGPoint.zero, to: nil as NSView?).y
        })
        let edge = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: h.host.superview)
        XCTAssertTrue(h.host.hitTest(edge) is PlannerResizeHandleView, "the bottom edge still reaches the resize strip")
        h.window.contentView = nil
    }

    /// Pixels in a band of the column (hours, from the top) that are not
    /// fully transparent. The column draws no background of its own, so an
    /// empty band reads 0.
    private func inkedPixels(_ h: Harness, from h0: Double, to h1: Double) -> Int {
        h.host.layoutSubtreeIfNeeded()
        guard let rep = h.host.bitmapImageRepForCachingDisplay(in: h.host.bounds) else { return -1 }
        h.host.cacheDisplay(in: h.host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / h.host.bounds.height
        // The host is not flipped for drawing into the rep: row 0 is the top.
        let y0 = Int(CGFloat(h0) * hour * scale), y1 = Int(CGFloat(h1) * hour * scale)
        var n = 0
        for y in stride(from: y0 + 2, to: y1 - 2, by: 2) {
            for x in stride(from: 4, to: rep.pixelsWide - 4, by: 3) {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.01 { n += 1 }
            }
        }
        return n
    }

    /// #697: while a tile is dragged, a ghost holds its original slot; it is
    /// gone once the move is committed.
    func testAGhostHoldsTheOriginalSlotOnlyWhileMoving() throws {
        let log = Log()
        let h = harness(log)
        let layer = try XCTUnwrap(h.layer("Focus"))
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        settle()
        XCTAssertEqual(inkedPixels(h, from: 5, to: 6), 0, "an empty band draws nothing")
        XCTAssertGreaterThan(inkedPixels(h, from: 10, to: 11), 0, "the tile at rest")
        let p = layer.convert(CGPoint(x: 30, y: 8), to: nil)
        layer.mouseDown(with: mouse(.leftMouseDown, at: p, windowNumber: h.wn))
        // Two hours down: the tile now covers 12 to 14, so 10 to 11 holds
        // only what is drawn at the original slot.
        layer.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: p.x, y: p.y - 2 * hour), windowNumber: h.wn))
        settle()
        XCTAssertGreaterThan(inkedPixels(h, from: 12.2, to: 13.8), 0, "the tile follows the pointer")
        XCTAssertGreaterThan(inkedPixels(h, from: 10, to: 11), 0, "a ghost holds the original slot")
        layer.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: p.x, y: p.y - 2 * hour), windowNumber: h.wn))
        settle()
        XCTAssertEqual(log.moves.first?.start, at(12))
        // The log does not write the move back, so the tile returns to 10.
        // What must be gone is the ghost: 12 to 14 is empty again.
        XCTAssertEqual(inkedPixels(h, from: 12.2, to: 13.8), 0, "no ghost and no lifted tile after the commit")
        h.window.contentView = nil
    }

    func testTheMoveDistanceIsMeasuredInWindowSpace() {
        let v = PlannerTileClickView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        // No window: the point is already in this flipped view's space.
        XCTAssertEqual(v.dragDistance(from: CGPoint(x: 0, y: 10), to: mouse(.leftMouseDragged, at: CGPoint(x: 0, y: 40), windowNumber: 0)), 30)
    }
}

private extension NSView {
    func moveTestSubviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { v -> [T] in ((v as? T).map { [$0] } ?? []) + v.moveTestSubviews(of: type) }
    }
}
