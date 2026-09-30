import XCTest
import AppKit
import SwiftUI
@testable import DexterMac

/// The resize strip on the bottom edge of a Dexter tile (#687 fix), driven
/// headlessly with synthesised `NSEvent`s, like `PlannerGridPointerViewTests`.
@MainActor
final class PlannerResizeHandleViewTests: XCTestCase {

    private let hour: CGFloat = 50

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int = 0) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    func testTheHandleReportsLiveAndFinalDragDistances() {
        let handle = PlannerResizeHandleView(frame: CGRect(x: 0, y: 0, width: 200, height: 6))
        var live: [CGFloat] = []
        var final: [CGFloat] = []
        handle.onChange = { live.append($0) }
        handle.onCommit = { final.append($0) }

        handle.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 3)))
        handle.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 50, y: 30)))
        handle.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 50, y: 78)))
        handle.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 78)))

        XCTAssertEqual(live, [27, 75])
        XCTAssertEqual(final, [75])
        XCTAssertNil(handle.anchorY)
        XCTAssertTrue(handle.acceptsFirstMouse(for: nil))
        XCTAssertTrue(handle.isFlipped)
    }

    func testAStrayMouseUpDoesNothing() {
        let handle = PlannerResizeHandleView(frame: CGRect(x: 0, y: 0, width: 200, height: 6))
        var final: [CGFloat] = []
        handle.onCommit = { final.append($0) }
        handle.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 5, y: 5)))
        XCTAssertTrue(final.isEmpty)
    }

    /// The handle inside the REAL column: a block tile gets one and an event
    /// tile does not; a drag on it reports the snapped new end through
    /// `onResize` and never starts a draft; the tile body keeps its click.
    func testTheColumnResizesADexterTileAndLeavesEventsAlone() throws {
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        func item(_ id: String, _ origin: PlannerItem.Origin, _ source: PlannerSource, _ sh: Double, _ eh: Double) -> PlannerItem {
            PlannerItem(
                id: id, title: id, detail: "", source: source,
                start: dayStart.addingTimeInterval(sh * 3600), end: dayStart.addingTimeInterval(eh * 3600),
                durationMinutes: Int((eh - sh) * 60), origin: origin, taskUUID: nil,
                priority: .none, overdueDays: 0, completed: false
            )
        }
        let block = item("Focus", .block("b1"), .manual, 10, 11)
        let meeting = item("Standup", .event(calendarID: "c"), .work, 14, 15)
        let day = PlannerDay(day: dayStart, allDay: [], timed: [block, meeting])

        var resized: [(String, Date)] = []
        var drafts = 0
        var taps: [String] = []
        let handlers = PlannerDraftHandlers(
            draft: nil,
            onChange: { _, _ in drafts += 1 },
            onCommit: { _, _ in drafts += 1 },
            popoverPresented: .constant(false),
            quickCreate: { AnyView(EmptyView()) },
            onResize: { i, end in resized.append((i.id, end)) }
        )
        let column = PlannerDayColumn(
            day: day, visible: Set(PlannerSource.allCases), now: dayStart,
            hourHeight: hour, onTapItem: { taps.append($0.id) }, draft: handlers
        )
        .frame(width: 300, height: hour * 24)
        let host = NSHostingView(rootView: column)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: hour * 24)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let handles = host.allSubviews(of: PlannerResizeHandleView.self)
        XCTAssertEqual(handles.count, 1, "only the Dexter block has a handle; the calendar event has none")
        let handle = try XCTUnwrap(handles.first)

        // AppKit routes a click on the tile's bottom edge to the handle.
        let edge = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: host.superview)
        XCTAssertTrue(host.hitTest(edge) is PlannerResizeHandleView, "the bottom edge reaches the resize strip")

        // Drag the edge 77 points down: 92 minutes at 50pt/h, so 11:00 + 1:32 = 12:32, snapped to 12:30.
        let wn = window.windowNumber
        let start = handle.convert(CGPoint(x: 10, y: 3), to: nil)
        handle.mouseDown(with: mouse(.leftMouseDown, at: start, windowNumber: wn))
        handle.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: start.x, y: start.y - 40), windowNumber: wn))
        handle.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: start.x, y: start.y - 77), windowNumber: wn))

        XCTAssertEqual(resized.count, 1)
        XCTAssertEqual(resized.first?.0, block.id)
        XCTAssertEqual(resized.first?.1, dayStart.addingTimeInterval(12.5 * 3600))
        XCTAssertEqual(drafts, 0, "a resize never starts a new draft")
        XCTAssertTrue(taps.isEmpty, "a resize is not a tap")
        window.contentView = nil
    }
}

/// The resize must not jitter (#687 round 5). The tile grows under a live
/// resize, which MOVES the handle; a pointer that stays still must keep
/// reporting the same end, however many times the layout runs in between.
@MainActor
final class PlannerResizeStabilityTests: XCTestCase {
    private let hour: CGFloat = 60   // one point per minute

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    /// A flipped container, like the grid column the handle lives in.
    private final class Flipped: NSView { override var isFlipped: Bool { true } }

    /// The handle sits on the tile's bottom edge, so a live resize MOVES it.
    /// With the pointer held still, the distance it reports must not change
    /// when it moves. Before the round 5 fix it measured in its own space, so
    /// every move fed back into the distance: 9, then -6, then 9, then -6.
    func testAStillPointerReportsTheSameDistanceWhileTheHandleMoves() {
        let container = Flipped(frame: CGRect(x: 0, y: 0, width: 300, height: 1440))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = container
        // The handle of a 10:00-10:15 tile at 60pt/h: its strip at y = 615.
        let handle = PlannerResizeHandleView(frame: CGRect(x: 0, y: 615, width: 300, height: 6))
        container.addSubview(handle)
        var reported: [CGFloat] = []
        handle.onChange = { reported.append($0) }

        func windowPoint(gridY: CGFloat) -> CGPoint { container.convert(CGPoint(x: 50, y: gridY), to: nil) }
        let wn = window.windowNumber
        handle.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(gridY: 618), windowNumber: wn))

        // Pointer moves 9 points down and then stays still. After each report
        // the tile re-lays out to the snapped end, which moves the handle.
        var ends: [Int] = []
        for _ in 0..<6 {
            handle.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(gridY: 627), windowNumber: wn))
            let end = PlannerDragGeometry.resizedEnd(start: 600, originalEnd: 615, deltaY: reported.last ?? 0, hourHeight: hour)
            ends.append(end)
            handle.setFrameOrigin(CGPoint(x: 0, y: CGFloat(end)))   // the strip follows the tile's new bottom
        }
        XCTAssertEqual(Set(reported), [9], "the distance is measured from where the pointer went down, not from the moving handle: \(reported)")
        XCTAssertEqual(Set(ends).count, 1, "one end while the pointer is still: \(ends)")
        window.contentView = nil
    }
}

private extension NSView {
    func allSubviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + sub.allSubviews(of: type) }
    }
}
