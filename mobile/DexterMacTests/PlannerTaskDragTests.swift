import XCTest
import AppKit
import SwiftUI
@testable import DexterMac

/// Drag a To-plan task onto the grid (#687 fix), driven through AppKit
/// mouse events on the real source view, over the REAL hosted day columns.
@MainActor
final class PlannerTaskDragTests: XCTestCase {

    private let hour: CGFloat = 50

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    private struct Harness {
        let window: NSWindow
        let host: NSView
        let source: PlannerTaskDragSourceView
        let coordinator: PlannerTaskDragCoordinator
    }

    /// Two day columns side by side (a Week grid in miniature), a To-plan row
    /// source in the same window, and a test coordinator.
    private func harness(days: [Date], minutes: Int, landed: @escaping (PlannerTaskDragCoordinator.Target?) -> Void) -> Harness {
        let coordinator = PlannerTaskDragCoordinator()
        let handlers = PlannerDraftHandlers(
            draft: nil, onChange: { _, _ in }, onCommit: { _, _ in },
            popoverPresented: .constant(false), quickCreate: { AnyView(EmptyView()) }
        )
        let busy = PlannerItem(
            id: "e-busy", title: "Busy", detail: "", source: .work,
            start: days[0].addingTimeInterval(14 * 3600), end: days[0].addingTimeInterval(15 * 3600),
            durationMinutes: 60, origin: .event(calendarID: "c"), taskUUID: nil,
            priority: .none, overdueDays: 0, completed: false
        )
        let hour = self.hour
        let columns = HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                PlannerDayColumn(
                    day: PlannerDay(day: d, allDay: [], timed: i == 0 ? [busy] : []),
                    visible: Set(PlannerSource.allCases), now: d, hourHeight: hour,
                    onTapItem: { _ in }, draft: handlers
                )
                .frame(width: 200, height: hour * 24)
            }
        }
        .environment(\.plannerTaskDrag, coordinator)
        let host = NSHostingView(rootView: columns)
        host.frame = CGRect(x: 0, y: 0, width: CGFloat(days.count) * 200, height: hour * 24)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let source = PlannerTaskDragSourceView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        source.payload = .init(taskID: "t-okrs", title: "Draft OKRs", minutes: minutes)
        source.coordinator = coordinator
        source.onEnd = landed
        return Harness(window: window, host: host, source: source, coordinator: coordinator)
    }

    /// Window point (origin bottom left) for a column x and a grid y.
    private func windowPoint(_ h: Harness, x: CGFloat, gridY: CGFloat) -> CGPoint {
        CGPoint(x: x, y: h.host.bounds.height - gridY)
    }

    private func y(_ hh: Int, _ mm: Int) -> CGFloat { CGFloat(hh * 60 + mm) / 60 * hour }

    func testDraggingOverTheGridShowsTheSlotAndADropPlansIt() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        var landed: [PlannerTaskDragCoordinator.Target?] = []
        let h = harness(days: [day], minutes: 45) { landed.append($0) }
        let wn = h.window.windowNumber

        // Every day column registered a drop zone.
        XCTAssertNotNil(h.coordinator.resolve(windowPoint(h, x: 100, gridY: y(9, 0)), window: nil, minutes: 30))

        h.source.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: -300, y: 20), windowNumber: wn))
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: -250, y: 60), windowNumber: wn))
        XCTAssertEqual(h.coordinator.payload?.taskID, "t-okrs", "the drag has started")
        XCTAssertNil(h.coordinator.target, "not over the grid yet")

        // Over 2:10 PM, which is on top of a calendar tile: still a valid slot.
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(h, x: 100, gridY: y(14, 10)), windowNumber: wn))
        XCTAssertEqual(h.coordinator.target?.start, day.addingTimeInterval(14 * 3600), "the ghost snaps to 2:00")
        XCTAssertEqual(h.coordinator.target?.end, day.addingTimeInterval(14 * 3600 + 45 * 60), "for the task's 45 minutes")

        h.source.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(h, x: 100, gridY: y(16, 20)), windowNumber: wn))
        XCTAssertEqual(landed.count, 1)
        XCTAssertEqual(landed.first??.start, day.addingTimeInterval(16 * 3600 + 15 * 60), "released at 4:20, lands at 4:15")
        XCTAssertNil(h.coordinator.payload, "the drag is over")
        h.window.contentView = nil
    }

    func testADropOnTheSecondColumnLandsOnThatDay() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        var landed: [PlannerTaskDragCoordinator.Target?] = []
        let h = harness(days: [day, next], minutes: 30) { landed.append($0) }
        let wn = h.window.windowNumber
        XCTAssertEqual(h.host.zonesForTests().count, 2, "one drop zone per column")
        h.source.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: -300, y: 20), windowNumber: wn))
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(h, x: 300, gridY: y(9, 0)), windowNumber: wn))
        h.source.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(h, x: 300, gridY: y(9, 0)), windowNumber: wn))
        XCTAssertEqual(landed.first??.dayStart, next)
        XCTAssertEqual(landed.first??.start, next.addingTimeInterval(9 * 3600))
        h.window.contentView = nil
    }

    func testReleasingOutsideTheGridCancels() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        var landed: [PlannerTaskDragCoordinator.Target?] = []
        let h = harness(days: [day], minutes: 30) { landed.append($0) }
        let wn = h.window.windowNumber
        h.source.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: -300, y: 20), windowNumber: wn))
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(h, x: 100, gridY: y(10, 0)), windowNumber: wn))
        h.source.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: -400, y: 20), windowNumber: wn))
        XCTAssertEqual(landed.count, 1)
        XCTAssertNil(landed.first!, "no slot under the pointer: nothing is planned")
        XCTAssertNil(h.coordinator.payload)
        h.window.contentView = nil
    }

    func testAClickWithoutADragDoesNotStartOne() {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        var landed: [PlannerTaskDragCoordinator.Target?] = []
        let h = harness(days: [day], minutes: 30) { landed.append($0) }
        let wn = h.window.windowNumber
        h.source.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 10, y: 10), windowNumber: wn))
        h.source.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 11, y: 10), windowNumber: wn))
        XCTAssertTrue(landed.isEmpty)
        XCTAssertNil(h.coordinator.payload)
        h.window.contentView = nil
    }
}

private extension NSView {
    func zonesForTests() -> [PlannerDropZoneView] {
        subviews.flatMap { ($0 as? PlannerDropZoneView).map { [$0] } ?? [] + $0.zonesForTests() }
    }
}
