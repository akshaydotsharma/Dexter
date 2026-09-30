import XCTest
import AppKit
import SwiftUI
@testable import DexterMac

/// Drag-to-create on the Planner grid, driven headlessly (#687 round 3).
///
/// Same shape as `VisionPointerViewTests`, for the same reason: a SwiftUI
/// gesture on the Mac cannot be verified by an agent, and an `NSView` can.
/// These tests build `PlannerGridPointerView`, synthesise `NSEvent`s, call
/// `mouseDown` / `mouseDragged` / `mouseUp` by hand, and check the ranges the
/// view reports. No key window, no screen, no timing.
///
/// The last test hosts the view in an `NSWindow` so the window-to-view point
/// conversion (`convert(_:from: nil)` on a flipped view) is exercised too.
@MainActor
final class PlannerGridPointerViewTests: XCTestCase {

    private let hour: CGFloat = 50
    private var view: PlannerGridPointerView!
    private var changes: [PlannerDragGeometry.Range] = []
    private var commits: [PlannerDragGeometry.Range] = []

    override func setUp() async throws {
        try await super.setUp()
        view = PlannerGridPointerView(frame: CGRect(x: 0, y: 0, width: 300, height: hour * 24))
        view.hourHeight = hour
        changes = []
        commits = []
        view.onChange = { [weak self] in self?.changes.append($0) }
        view.onCommit = { [weak self] in self?.commits.append($0) }
    }

    /// y for a time of day in this view.
    private func y(_ h: Int, _ m: Int) -> CGFloat { CGFloat(h * 60 + m) / 60 * hour }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int = 0) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    func testDragDownReportsLiveRangesAndCommitsTheSnappedRange() {
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: y(14, 4))))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 100, y: y(14, 40))))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 100, y: y(15, 24))))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 100, y: y(15, 24))))

        XCTAssertEqual(changes, [
            .init(start: 14 * 60, end: 14 * 60 + 45),
            .init(start: 14 * 60, end: 15 * 60 + 30),
        ], "the draft follows the pointer, snapped to 15 minutes")
        XCTAssertEqual(commits, [.init(start: 14 * 60, end: 15 * 60 + 30)])
        XCTAssertFalse(view.isDragging)
        XCTAssertNil(view.anchor)
    }

    func testDragUpMovesTheStart() {
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 80, y: y(14, 5))))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 80, y: y(13, 10))))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 80, y: y(13, 10))))
        XCTAssertEqual(commits, [.init(start: 13 * 60 + 15, end: 14 * 60 + 15)])
    }

    func testAClickWithNoDragMakesAThirtyMinuteDraft() {
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: y(10, 40))))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: y(10, 40))))
        XCTAssertTrue(changes.isEmpty, "a click draws no live draft")
        XCTAssertEqual(commits, [.init(start: 10 * 60 + 30, end: 11 * 60)])
    }

    func testAJitterBelowTheThresholdIsStillAClick() {
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: y(9, 0))))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 51, y: y(9, 0) + 2)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 51, y: y(9, 0) + 2)))
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(commits, [.init(start: 9 * 60, end: 9 * 60 + 30)])
    }

    func testADragPastTheBottomIsClampedToMidnight() {
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: y(23, 0))))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 50, y: hour * 30)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: hour * 30)))
        XCTAssertEqual(commits, [.init(start: 23 * 60, end: 24 * 60)])
    }

    func testAMouseUpWithoutADownDoesNothing() {
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: y(9, 0))))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 50, y: y(10, 0))))
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(changes.isEmpty)
    }

    func testTheViewTakesTheFirstClickEvenWhenTheWindowIsNotKey() {
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertTrue(view.isFlipped)
    }

    /// Hosted in a window: events arrive in window space (origin bottom left)
    /// and the flipped view must turn them back into grid y.
    func testWindowCoordinatesAreConvertedToGridY() {
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.contentView = view
        let height = view.bounds.height
        func windowPoint(_ gridY: CGFloat) -> CGPoint { CGPoint(x: 100, y: height - gridY) }

        view.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(y(8, 0)), windowNumber: window.windowNumber))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(y(9, 30)), windowNumber: window.windowNumber))
        view.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(y(9, 30)), windowNumber: window.windowNumber))
        XCTAssertEqual(commits, [.init(start: 8 * 60, end: 9 * 60 + 30)])
        window.contentView = nil
    }

    // MARK: - Inside the real SwiftUI column

    /// The pointer view only works if SwiftUI hands it the clicks on EMPTY
    /// space and keeps the clicks on tiles for the tiles. This hosts the real
    /// `PlannerDayColumn` and asks AppKit which view a click would reach.
    func testEmptySpaceReachesThePointerViewAndTilesDoNot() throws {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let tileItem = PlannerItem(
            id: "e-x", title: "Standup", detail: "Work", source: .work,
            start: dayStart.addingTimeInterval(10 * 3600), end: dayStart.addingTimeInterval(11 * 3600),
            durationMinutes: 60, origin: .event(calendarID: "c"), taskUUID: nil,
            priority: .none, overdueDays: 0, completed: false
        )
        let day = PlannerDay(day: dayStart, allDay: [], timed: [tileItem])
        var committed: [(Date, Date)] = []
        let handlers = PlannerDraftHandlers(
            draft: nil,
            onChange: { _, _ in },
            onCommit: { s, e in committed.append((s, e)) },
            popoverPresented: .constant(false),
            quickCreate: { AnyView(EmptyView()) }
        )
        let column = PlannerDayColumn(
            day: day, visible: Set(PlannerSource.allCases), now: dayStart,
            hourHeight: hour, onTapItem: { _ in }, draft: handlers
        )
        .frame(width: 300, height: hour * 24)
        let host = NSHostingView(rootView: column)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: hour * 24)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        func hit(atGridY gy: CGFloat) -> NSView? {
            // `hitTest` takes a point in the SUPERVIEW's space (the window's
            // frame view, which is not flipped), so convert from the host.
            let local = host.isFlipped ? CGPoint(x: 150, y: gy) : CGPoint(x: 150, y: host.bounds.height - gy)
            return host.hitTest(host.convert(local, to: host.superview))
        }
        func isPointer(_ v: NSView?) -> Bool {
            var cur = v
            while let c = cur { if c is PlannerGridPointerView { return true }; cur = c.superview }
            return false
        }

        let pointer = try XCTUnwrap(host.findSubview(of: PlannerGridPointerView.self), "the column mounts the pointer view")
        XCTAssertEqual(pointer.hourHeight, hour)
        XCTAssertTrue(isPointer(hit(atGridY: y(14, 0))), "empty time at 2 PM reaches the drag layer")
        XCTAssertFalse(isPointer(hit(atGridY: y(10, 30))), "the 10 AM tile keeps its own click")

        // And the pointer view's commit reaches the column's handler as dates.
        pointer.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 10, y: y(14, 0)), windowNumber: window.windowNumber))
        pointer.onCommit?(PlannerDragGeometry.Range(start: 14 * 60, end: 15 * 60))
        XCTAssertEqual(committed.first?.0, dayStart.addingTimeInterval(14 * 3600))
        XCTAssertEqual(committed.first?.1, dayStart.addingTimeInterval(15 * 3600))
        window.contentView = nil
    }
}

private extension NSView {
    func findSubview<T: NSView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let t = sub as? T { return t }
            if let t = sub.findSubview(of: type) { return t }
        }
        return nil
    }
}
