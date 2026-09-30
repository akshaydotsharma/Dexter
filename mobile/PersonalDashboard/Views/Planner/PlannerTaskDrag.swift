import SwiftUI
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Drag a task from "To plan" into a time slot on the grid (#687 fix).
///
/// Native pointer code on both platforms, for the same reason as the create
/// and resize layers: it can be driven in tests. There is no system
/// drag-and-drop here. The source view keeps the pointer from press to
/// release (AppKit and UIKit both deliver every move to the view that got the
/// press), and on each move asks this coordinator which day column is under
/// the pointer. Each column registers an invisible `PlannerDropZoneView`, so
/// the answer is always computed against where the column is NOW, scrolled
/// or not, and a drop over a tile works as well as a drop on empty time.
@MainActor
@Observable
final class PlannerTaskDragCoordinator {
    static let shared = PlannerTaskDragCoordinator()

    struct Payload: Equatable {
        let taskID: String
        let title: String
        let minutes: Int
    }

    struct Target: Equatable {
        let dayStart: Date
        let start: Date
        let end: Date
    }

    /// The task being dragged, or nil.
    private(set) var payload: Payload?
    /// Where it would land if released now, or nil (over nothing).
    private(set) var target: Target?
    /// The pointer in window space, for the chip that follows the finger.
    private(set) var pointer: CGPoint?

    @ObservationIgnored private var zones = NSHashTable<PlannerDropZoneView>.weakObjects()

    func register(_ zone: PlannerDropZoneView) { zones.add(zone) }

    func begin(_ payload: Payload) {
        self.payload = payload
        target = nil
    }

    /// Move to a point in the window's coordinate space.
    func move(toWindowPoint p: CGPoint, in window: AnyObject?) {
        pointer = p
        guard let payload else { return }
        target = resolve(p, window: window, minutes: payload.minutes)
    }

    /// End the drag. Returns where it landed, or nil for a cancel.
    @discardableResult
    func end(atWindowPoint p: CGPoint?, in window: AnyObject?) -> (Payload, Target)? {
        defer { payload = nil; target = nil; pointer = nil }
        guard let payload else { return nil }
        guard let p, let t = resolve(p, window: window, minutes: payload.minutes) else { return nil }
        return (payload, t)
    }

    func cancel() {
        payload = nil
        target = nil
        pointer = nil
    }

    /// The zone under a window point, and the snapped range there.
    func resolve(_ windowPoint: CGPoint, window: AnyObject?, minutes: Int) -> Target? {
        for zone in zones.allObjects {
            guard let local = zone.localPoint(forWindowPoint: windowPoint, in: window) else { continue }
            let r = PlannerDragGeometry.dropRange(atY: local.y, hourHeight: zone.hourHeight, length: minutes)
            let d = PlannerDragGeometry.dates(r, dayStart: zone.dayStart)
            return Target(dayStart: zone.dayStart, start: d.start, end: d.end)
        }
        return nil
    }
}

private struct PlannerTaskDragKey: EnvironmentKey {
    @MainActor static var defaultValue: PlannerTaskDragCoordinator { .shared }
}

extension EnvironmentValues {
    var plannerTaskDrag: PlannerTaskDragCoordinator {
        get { self[PlannerTaskDragKey.self] }
        set { self[PlannerTaskDragKey.self] = newValue }
    }
}

// MARK: - Drop zone (one per day column)

/// An invisible view the size of a day column. It never takes a click
/// (`hitTest` is nil); it only answers "is this window point over me, and at
/// what y". A point in the part of the column scrolled out of view is not
/// over it.
#if os(macOS)
final class PlannerDropZoneView: NSView {
    var dayStart = Date()
    var hourHeight: CGFloat = PlannerGridMetrics.hourHeight
    weak var coordinator: PlannerTaskDragCoordinator?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { coordinator?.register(self) }
    }

    func localPoint(forWindowPoint p: CGPoint, in window: AnyObject?) -> CGPoint? {
        guard let w = self.window, window == nil || (window as? NSWindow) === w else { return nil }
        let local = convert(p, from: nil)
        // Inside this column, AND inside the part of it that is on screen.
        // `visibleRect` alone is not enough: measured wider than the view
        // itself (400pt for a 200pt column) when the host does not clip.
        return bounds.contains(local) && visibleRect.contains(local) ? local : nil
    }
}

private struct DropZoneRepresentable: NSViewRepresentable {
    let dayStart: Date
    let hourHeight: CGFloat
    let coordinator: PlannerTaskDragCoordinator

    func makeNSView(context: Context) -> PlannerDropZoneView {
        let v = PlannerDropZoneView()
        update(v)
        return v
    }
    func updateNSView(_ v: PlannerDropZoneView, context: Context) { update(v) }
    private func update(_ v: PlannerDropZoneView) {
        v.dayStart = dayStart
        v.hourHeight = hourHeight
        if v.coordinator !== coordinator {
            v.coordinator = coordinator
            if v.window != nil { coordinator.register(v) }
        }
    }
}
#else
final class PlannerDropZoneView: UIView {
    var dayStart = Date()
    var hourHeight: CGFloat = PlannerGridMetrics.hourHeight
    weak var coordinator: PlannerTaskDragCoordinator?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { coordinator?.register(self) }
    }

    func localPoint(forWindowPoint p: CGPoint, in window: AnyObject?) -> CGPoint? {
        guard let w = self.window, window == nil || (window as? UIWindow) === w else { return nil }
        let local = convert(p, from: nil)
        guard bounds.contains(local) else { return nil }
        // Only the part of the column the scroll view shows.
        var v = superview
        while let cur = v {
            if let scroll = cur as? UIScrollView {
                return scroll.bounds.contains(scroll.convert(p, from: nil)) ? local : nil
            }
            v = cur.superview
        }
        return local
    }
}

private struct DropZoneRepresentable: UIViewRepresentable {
    let dayStart: Date
    let hourHeight: CGFloat
    let coordinator: PlannerTaskDragCoordinator

    func makeUIView(context: Context) -> PlannerDropZoneView {
        let v = PlannerDropZoneView()
        v.isUserInteractionEnabled = false
        update(v)
        return v
    }
    func updateUIView(_ v: PlannerDropZoneView, context: Context) { update(v) }
    private func update(_ v: PlannerDropZoneView) {
        v.dayStart = dayStart
        v.hourHeight = hourHeight
        if v.coordinator !== coordinator {
            v.coordinator = coordinator
            if v.window != nil { coordinator.register(v) }
        }
    }
}
#endif

struct PlannerDropZone: View {
    let dayStart: Date
    let hourHeight: CGFloat
    @Environment(\.plannerTaskDrag) private var coordinator

    var body: some View {
        DropZoneRepresentable(dayStart: dayStart, hourHeight: hourHeight, coordinator: coordinator)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Drag source (a To-plan row)

/// Sits behind a To-plan row. Press and drag (Mac), or press and hold then
/// drag (iPhone), to carry the task over the grid.
struct PlannerTaskDragSource: View {
    let payload: PlannerTaskDragCoordinator.Payload
    /// Called once the drag starts (the iPhone slides the To-plan panel away).
    var onBegin: () -> Void = {}
    /// Called with the landing slot; nil means the drag was cancelled.
    let onEnd: (PlannerTaskDragCoordinator.Target?) -> Void
    @Environment(\.plannerTaskDrag) private var coordinator

    var body: some View {
        SourceRepresentable(payload: payload, coordinator: coordinator, onBegin: onBegin, onEnd: onEnd)
    }
}

#if os(macOS)
final class PlannerTaskDragSourceView: NSView {
    var payload: PlannerTaskDragCoordinator.Payload?
    weak var coordinator: PlannerTaskDragCoordinator?
    var onBegin: () -> Void = {}
    var onEnd: (PlannerTaskDragCoordinator.Target?) -> Void = { _ in }
    private var anchor: CGPoint?
    private(set) var isDragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        anchor = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let a = anchor, let payload, let coordinator else { return }
        let p = event.locationInWindow
        if !isDragging, PlannerDragGeometry.isDrag(from: a, to: p) {
            isDragging = true
            coordinator.begin(payload)
            NSCursor.closedHand.push()
            onBegin()
        }
        if isDragging { coordinator.move(toWindowPoint: p, in: window) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { anchor = nil }
        guard isDragging, let coordinator else { return }
        isDragging = false
        NSCursor.pop()
        let landed = coordinator.end(atWindowPoint: event.locationInWindow, in: window)
        onEnd(landed?.1)
    }
}

private struct SourceRepresentable: NSViewRepresentable {
    let payload: PlannerTaskDragCoordinator.Payload
    let coordinator: PlannerTaskDragCoordinator
    let onBegin: () -> Void
    let onEnd: (PlannerTaskDragCoordinator.Target?) -> Void

    func makeNSView(context: Context) -> PlannerTaskDragSourceView {
        let v = PlannerTaskDragSourceView()
        update(v)
        return v
    }
    func updateNSView(_ v: PlannerTaskDragSourceView, context: Context) { update(v) }
    private func update(_ v: PlannerTaskDragSourceView) {
        v.payload = payload
        v.coordinator = coordinator
        v.onBegin = onBegin
        v.onEnd = onEnd
    }
}
#else
final class PlannerTaskDragSourceView: UIView {
    var payload: PlannerTaskDragCoordinator.Payload?
    weak var coordinator: PlannerTaskDragCoordinator?
    var onBegin: () -> Void = {}
    var onEnd: (PlannerTaskDragCoordinator.Target?) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        hold.minimumPressDuration = 0.3
        addGestureRecognizer(hold)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func handle(_ g: UILongPressGestureRecognizer) {
        guard let coordinator else { return }
        let p = g.location(in: nil)
        switch g.state {
        case .began:
            guard let payload else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            coordinator.begin(payload)
            coordinator.move(toWindowPoint: p, in: window)
            onBegin()
        case .changed:
            coordinator.move(toWindowPoint: p, in: window)
        case .ended:
            let landed = coordinator.end(atWindowPoint: p, in: window)
            onEnd(landed?.1)
        case .cancelled, .failed:
            coordinator.cancel()
            onEnd(nil)
        default:
            break
        }
    }
}

private struct SourceRepresentable: UIViewRepresentable {
    let payload: PlannerTaskDragCoordinator.Payload
    let coordinator: PlannerTaskDragCoordinator
    let onBegin: () -> Void
    let onEnd: (PlannerTaskDragCoordinator.Target?) -> Void

    func makeUIView(context: Context) -> PlannerTaskDragSourceView {
        let v = PlannerTaskDragSourceView()
        update(v)
        return v
    }
    func updateUIView(_ v: PlannerTaskDragSourceView, context: Context) { update(v) }
    private func update(_ v: PlannerTaskDragSourceView) {
        v.payload = payload
        v.coordinator = coordinator
        v.onBegin = onBegin
        v.onEnd = onEnd
        v.accessibilityIdentifier = "planner.toplan.drag.\(payload.title)"
    }
}
#endif

// MARK: - Ghost tile

/// The tile a dragged task would become, drawn in the column under the
/// pointer with its live time range.
struct PlannerTaskGhost: View {
    let title: String
    let start: Date
    let end: Date
    var height: CGFloat

    var body: some View {
        let c = PlannerStyle.color(.task)
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
            Text(PlannerStyle.range(start, end))
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Tokens.inkSoft)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(c.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(c.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drop \(title) at \(PlannerStyle.range(start, end))")
        .accessibilityIdentifier("planner.drop.ghost")
    }
}
