import XCTest
import AppKit
import SwiftUI
@testable import DexterMac

/// Pick up a To-plan row and drop it on the grid (#687 rounds 4 and 5),
/// driven through AppKit mouse events on the REAL inspector row, over the
/// REAL hosted day columns, in one window.
@MainActor
final class PlannerTaskDragTests: XCTestCase {

    private let hour: CGFloat = 50
    private let columnWidth: CGFloat = 200

    private final class Flipped: NSView { override var isFlipped: Bool { true } }

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
        let grid: NSView
        let inspector: NSView
        let coordinator: PlannerTaskDragCoordinator
        let source: PlannerTaskDragSourceView
        var wn: Int { window.windowNumber }
    }

    private func candidate(_ id: String, _ title: String, minutes: Int) -> PlannerEngine.Candidate {
        PlannerEngine.Candidate(task: PlannerTask(id: id, title: title, priority: .p1, due: nil, completed: false),
                                estimateMinutes: minutes, overdueDays: 0)
    }

    /// Day columns on the left, the real To-plan inspector on the right.
    private func harness(days: [Date], minutes: Int, dropped: @escaping (PlannerEngine.Candidate, PlannerTaskDragCoordinator.Target) -> Void) throws -> Harness {
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
        let hour = self.hour, columnWidth = self.columnWidth
        let columns = HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                PlannerDayColumn(
                    day: PlannerDay(day: d, allDay: [], timed: i == 0 ? [busy] : []),
                    visible: Set(PlannerSource.allCases), now: d, hourHeight: hour,
                    onTapItem: { _ in }, draft: handlers
                )
                .frame(width: columnWidth, height: hour * 24)
            }
        }
        .environment(\.plannerTaskDrag, coordinator)
        let gridHost = NSHostingView(rootView: columns)
        gridHost.frame = CGRect(x: 0, y: 0, width: CGFloat(days.count) * columnWidth, height: hour * 24)

        let list = [candidate("t-okrs", "Draft OKRs", minutes: minutes), candidate("t-bali", "Book flights", minutes: 30)]
        let inspector = PlannerInspector(candidates: list, onPlan: { _ in }, onDrop: dropped)
            .frame(width: 270, height: 600)
            .environment(\.plannerTaskDrag, coordinator)
        let inspectorHost = NSHostingView(rootView: inspector)
        inspectorHost.frame = CGRect(x: gridHost.frame.maxX + 40, y: 0, width: 270, height: 600)

        let root = Flipped(frame: CGRect(x: 0, y: 0, width: inspectorHost.frame.maxX, height: hour * 24))
        root.addSubview(gridHost)
        root.addSubview(inspectorHost)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        let sources = inspectorHost.allSubviews(of: PlannerTaskDragSourceView.self)
        XCTAssertEqual(sources.count, 2, "each To-plan row has a pick-up view")
        let source = try XCTUnwrap(sources.first { $0.payload?.taskID == "t-okrs" })
        return Harness(window: window, grid: gridHost, inspector: inspectorHost, coordinator: coordinator, source: source)
    }

    /// Window point for a grid y in the column at `columnIndex`.
    private func gridPoint(_ h: Harness, column: Int = 0, x: CGFloat = 100, gridY: CGFloat) -> CGPoint {
        h.grid.convert(CGPoint(x: CGFloat(column) * columnWidth + x, y: gridY), to: nil)
    }

    /// When `PLANNER_TEST_SHOTS` names a folder, write what the window and
    /// the floating card show at this moment into one PNG, for review.
    private func saveMidDragShot(_ h: Harness, card: NSWindow, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PLANNER_TEST_SHOTS"],
              let root = h.window.contentView, let cardView = card.contentView else { return }
        settle(0.3)
        root.layoutSubtreeIfNeeded()
        func bitmap(_ v: NSView) -> NSBitmapImageRep? {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep
        }
        guard let base = bitmap(root), let top = bitmap(cardView) else { return }
        let size = root.bounds.size
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        base.draw(in: NSRect(origin: .zero, size: size))
        // The card's frame in the window's space.
        let inWindow = h.window.convertFromScreen(card.frame)
        top.draw(in: inWindow)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func y(_ hh: Int, _ mm: Int) -> CGFloat { CGFloat(hh * 60 + mm) / 60 * hour }

    /// Spin the run loop, for the fly-back animation to finish.
    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The row BELOW the lifted one, in the inspector's space. When the
    /// lifted row leaves the list, the list closes the gap and this moves up.
    private func nextRowY(_ h: Harness) -> CGFloat {
        settle(0.35)   // SwiftUI applies the observed change, then animates the gap closed
        h.inspector.layoutSubtreeIfNeeded()
        let next = h.inspector.allSubviews(of: PlannerTaskDragSourceView.self).first { $0.payload?.taskID == "t-bali" }!
        return next.convert(next.bounds, to: h.inspector).minY
    }

    func testPickUpFollowsTheCursorLeavesTheListAndDropPlans() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        var dropped: [(String, PlannerTaskDragCoordinator.Target)] = []
        let h = try harness(days: [day], minutes: 45) { c, t in dropped.append((c.task.id, t)) }
        let press = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        let restingY = nextRowY(h)

        h.source.mouseDown(with: mouse(.leftMouseDown, at: press, windowNumber: h.wn))
        XCTAssertNil(h.source.floatingCard, "a press alone lifts nothing")

        // 3 points: picked up at once.
        let lift = CGPoint(x: press.x - 3, y: press.y)
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: lift, windowNumber: h.wn))
        let card = try XCTUnwrap(h.source.floatingCard, "the row is lifted into a floating card")
        XCTAssertTrue(card.isVisible)
        XCTAssertTrue(card.ignoresMouseEvents, "the card never takes a click")
        XCTAssertEqual(h.coordinator.payload?.taskID, "t-okrs")
        let liftedY = nextRowY(h)
        XCTAssertLessThan(liftedY, restingY - 30, "the lifted row leaves the list and the gap closes (\(restingY) -> \(liftedY))")

        // It follows the cursor, keeping the grab offset.
        let before = card.frame.origin
        let mid = CGPoint(x: lift.x - 60, y: lift.y - 30)   // over the gap between the grid and the list
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: mid, windowNumber: h.wn))
        XCTAssertEqual(card.frame.origin.x - before.x, -60, accuracy: 0.5)
        XCTAssertEqual(card.frame.origin.y - before.y, -30, accuracy: 0.5)
        XCTAssertNil(h.coordinator.target, "not over a column yet")

        // Over 2:10 PM, on top of a calendar tile: a valid slot, the ghost at 2:00.
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: gridPoint(h, gridY: y(14, 10)), windowNumber: h.wn))
        XCTAssertEqual(h.coordinator.target?.start, day.addingTimeInterval(14 * 3600))
        XCTAssertEqual(h.coordinator.target?.end, day.addingTimeInterval(14 * 3600 + 45 * 60), "the task's 45 minutes")
        saveMidDragShot(h, card: card, name: "mac-mid-drag")

        h.source.mouseUp(with: mouse(.leftMouseUp, at: gridPoint(h, gridY: y(16, 20)), windowNumber: h.wn))
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped.first?.0, "t-okrs")
        XCTAssertEqual(dropped.first?.1.start, day.addingTimeInterval(16 * 3600 + 15 * 60), "released at 4:20, lands at 4:15")
        XCTAssertNil(h.coordinator.payload, "the drag is over")
        settle(0.3)
        XCTAssertFalse(card.isVisible, "the card is gone after the drop")
        h.window.contentView = nil
    }

    func testReleasingOffTheGridFliesTheCardBackAndTheRowReturns() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        var dropped = 0
        let h = try harness(days: [day], minutes: 30) { _, _ in dropped += 1 }
        let press = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        let restingY = nextRowY(h)
        h.source.mouseDown(with: mouse(.leftMouseDown, at: press, windowNumber: h.wn))
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: press.x - 50, y: press.y - 40), windowNumber: h.wn))
        let card = try XCTUnwrap(h.source.floatingCard)
        let home = card.frame.offsetBy(dx: 50, dy: 40)
        h.source.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: press.x - 50, y: press.y - 40), windowNumber: h.wn))
        XCTAssertTrue(h.coordinator.isReturning, "a miss flies back")
        XCTAssertNotNil(h.coordinator.payload, "the row stays off the list until the card lands back")
        settle()
        XCTAssertEqual(card.frame.origin.x, home.origin.x, accuracy: 1, "the card flew back to the row's slot")
        XCTAssertEqual(card.frame.origin.y, home.origin.y, accuracy: 1)
        XCTAssertNil(h.coordinator.payload)
        XCTAssertEqual(nextRowY(h), restingY, accuracy: 1, "the row is back on the list")
        XCTAssertEqual(dropped, 0, "nothing was planned")
        h.window.contentView = nil
    }

    func testEscCancelsMidDrag() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        var dropped = 0
        let h = try harness(days: [day], minutes: 30) { _, _ in dropped += 1 }
        let press = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        h.source.mouseDown(with: mouse(.leftMouseDown, at: press, windowNumber: h.wn))
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: gridPoint(h, gridY: y(10, 0)), windowNumber: h.wn))
        XCTAssertNotNil(h.coordinator.target, "over a slot")
        h.source.cancelOperation(nil)                       // Esc
        h.source.mouseUp(with: mouse(.leftMouseUp, at: gridPoint(h, gridY: y(10, 0)), windowNumber: h.wn))
        settle()
        XCTAssertEqual(dropped, 0, "Esc wins even though the pointer is over a slot")
        XCTAssertNil(h.coordinator.payload)
        h.window.contentView = nil
    }

    func testADropOnTheSecondColumnLandsOnThatDay() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        var dropped: [PlannerTaskDragCoordinator.Target] = []
        let h = try harness(days: [day, next], minutes: 30) { _, t in dropped.append(t) }
        let press = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        h.source.mouseDown(with: mouse(.leftMouseDown, at: press, windowNumber: h.wn))
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: gridPoint(h, column: 1, gridY: y(9, 0)), windowNumber: h.wn))
        h.source.mouseUp(with: mouse(.leftMouseUp, at: gridPoint(h, column: 1, gridY: y(9, 0)), windowNumber: h.wn))
        XCTAssertEqual(dropped.first?.dayStart, next)
        XCTAssertEqual(dropped.first?.start, next.addingTimeInterval(9 * 3600))
        h.window.contentView = nil
    }

    func testAClickWithoutAMoveLiftsNothing() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let h = try harness(days: [day], minutes: 30) { _, _ in }
        let press = h.source.convert(CGPoint(x: 40, y: 12), to: nil)
        h.source.mouseDown(with: mouse(.leftMouseDown, at: press, windowNumber: h.wn))
        h.source.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: press.x + 1, y: press.y), windowNumber: h.wn))
        h.source.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: press.x + 1, y: press.y), windowNumber: h.wn))
        XCTAssertNil(h.source.floatingCard)
        XCTAssertNil(h.coordinator.payload)
        h.window.contentView = nil
    }
}

private extension NSView {
    func allSubviews<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + sub.allSubviews(of: type) }
    }
}
