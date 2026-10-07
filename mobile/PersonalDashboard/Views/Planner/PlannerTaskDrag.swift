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
        /// The row's second line ("Due Fri · 30m"), for the lifted card.
        var meta: String = ""
        var priority: TaskPriority = .none
    }

    struct Target: Equatable {
        let dayStart: Date
        let start: Date
        let end: Date
    }

    /// The task being carried, or nil. While set, its row is OFF the list.
    private(set) var payload: Payload?
    /// Where it would land if released now, or nil (over nothing).
    private(set) var target: Target?
    /// The pointer in window space.
    private(set) var pointer: CGPoint?
    /// The row's frame in window space when it was picked up, and where in
    /// the row it was grabbed, so the card keeps that offset and can fly back.
    private(set) var sourceFrame: CGRect?
    private(set) var grabOffset: CGSize = .zero
    /// True between a cancelled release and the end of the fly-back.
    private(set) var isReturning = false

    @ObservationIgnored private var zones = NSHashTable<PlannerDropZoneView>.weakObjects()

    func register(_ zone: PlannerDropZoneView) { zones.add(zone) }

    func begin(_ payload: Payload, sourceFrame: CGRect? = nil, grabbedAt: CGPoint? = nil) {
        self.payload = payload
        self.sourceFrame = sourceFrame
        if let f = sourceFrame, let g = grabbedAt {
            grabOffset = CGSize(width: g.x - f.minX, height: g.y - f.minY)
        } else {
            grabOffset = .zero
        }
        target = nil
        isReturning = false
    }

    /// Move to a point in the window's coordinate space.
    func move(toWindowPoint p: CGPoint, in window: AnyObject?) {
        guard payload != nil, !isReturning else { return }
        pointer = p
        target = resolve(p, window: window, minutes: payload!.minutes)
    }

    /// Release. Over a slot: returns it and the drag is over. Anywhere else:
    /// returns nil and the drag goes into its fly-back; the caller animates
    /// the card to `sourceFrame` and then calls `finish()`, which is when the
    /// row reappears in the list.
    @discardableResult
    func end(atWindowPoint p: CGPoint?, in window: AnyObject?) -> (Payload, Target)? {
        guard let payload else { return nil }
        if let p, let t = resolve(p, window: window, minutes: payload.minutes) {
            finish()
            return (payload, t)
        }
        target = nil
        isReturning = true
        return nil
    }

    /// Esc, or a gesture the system took away: fly back, as for a miss.
    func cancel() {
        guard payload != nil else { return }
        target = nil
        isReturning = true
    }

    /// The fly-back is over: the row is back on the list.
    func finish() {
        payload = nil
        target = nil
        pointer = nil
        sourceFrame = nil
        grabOffset = .zero
        isReturning = false
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

/// The lifted copy of a To-plan row: the same card look, raised, with a shadow.
struct PlannerDragCard: View {
    let payload: PlannerTaskDragCoordinator.Payload
    /// Over a day column: the card fades toward the ghost tile, which reads
    /// as landing.
    var overSlot: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(PlannerStyle.priorityColor(payload.priority)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.title)
                    .font(.edSubheadline.weight(.medium))
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Text(payload.meta.isEmpty ? PlannerFormat.duration(payload.minutes) : payload.meta)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.trailing, 10).padding(.vertical, 8)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        .scaleEffect(overSlot ? 0.9 : 1.03)
        .opacity(overSlot ? 0.55 : 1)
        .animation(.easeOut(duration: 0.15), value: overSlot)
        .allowsHitTesting(false)
        .accessibilityIdentifier("planner.drag.card")
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
    /// A click that did not lift (#687 round 6). Mac: selects the row. iPhone: a
    /// tap, which opens the task editor.
    var onClick: () -> Void = {}
    /// Mac: a double click, which opens the task editor.
    var onDoubleClick: () -> Void = {}
    /// Mac: the right-click menu.
    var menuEntries: () -> [PlannerMenuEntry] = { [] }
    var onCommand: (PlannerTileCommand) -> Void = { _ in }
    /// iPhone: the trailing width a tap ignores, for a row's own button. An
    /// All Day pill (#693) has none.
    var tapExclusionWidth: CGFloat = 76
    /// The view's accessibility identifier; nil names it after the To-plan row.
    var identifier: String? = nil
    @Environment(\.plannerTaskDrag) private var coordinator

    var body: some View {
        SourceRepresentable(
            payload: payload, coordinator: coordinator, onBegin: onBegin, onEnd: onEnd,
            onClick: onClick, onDoubleClick: onDoubleClick, menuEntries: menuEntries, onCommand: onCommand,
            tapExclusionWidth: tapExclusionWidth, identifier: identifier
        )
    }
}

#if os(macOS)
/// The Mac row. Mouse down plus a 3pt move PICKS THE ROW UP: a floating copy
/// follows the cursor everywhere (over the inspector, the gap and the grid),
/// keeping the grab offset, and the row leaves the list. Release over a day
/// column plans the task; release anywhere else, or Esc, flies the card back
/// and the row returns.
///
/// The card is a borderless, mouse-transparent child window, because it must
/// draw above every column of the split view, which a view inside the
/// inspector cannot do.
final class PlannerTaskDragSourceView: NSView {
    var payload: PlannerTaskDragCoordinator.Payload?
    weak var coordinator: PlannerTaskDragCoordinator?
    var onBegin: () -> Void = {}
    var onEnd: (PlannerTaskDragCoordinator.Target?) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var menuEntries: () -> [PlannerMenuEntry] = { [] }
    var onCommand: (PlannerTileCommand) -> Void = { _ in }
    private var anchor: CGPoint?
    private(set) var isDragging = false
    /// The lifted card, while a row is picked up. Visible to tests.
    private(set) var floatingCard: NSWindow?
    private var cardHost: NSHostingView<PlannerDragCard>?
    private var rowScreenRect: CGRect = .zero
    private var grabInScreen: CGSize = .zero

    /// Room around the card for its shadow.
    static let cardInset: CGFloat = 16
    static let pickUpDistance: CGFloat = 3

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        anchor = event.locationInWindow
        isDragging = false
        // First responder so Esc reaches `cancelOperation` during the drag.
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let a = anchor, let payload, let coordinator else { return }
        let p = event.locationInWindow
        if !isDragging {
            guard hypot(p.x - a.x, p.y - a.y) >= Self.pickUpDistance else { return }
            isDragging = true
            let rowInWindow = convert(bounds, to: nil)
            coordinator.begin(payload, sourceFrame: rowInWindow, grabbedAt: a)
            liftCard(rowInWindow: rowInWindow, grabbedAt: a)
            NSCursor.closedHand.push()
            onBegin()
        }
        guard !coordinator.isReturning else { return }
        coordinator.move(toWindowPoint: p, in: window)
        moveCard(toWindowPoint: p)
    }

    override func mouseUp(with event: NSEvent) {
        defer { anchor = nil }
        // A press that never moved 3pt is a click, never a lift (#687 round 6):
        // one click selects, the second click of a double click opens the editor.
        if !isDragging {
            guard anchor != nil else { return }
            if event.clickCount >= 2 { onDoubleClick() } else { onClick() }
            return
        }
        guard let coordinator else { return }
        isDragging = false
        NSCursor.pop()
        if coordinator.isReturning { return }   // already cancelled with Esc
        if let landed = coordinator.end(atWindowPoint: event.locationInWindow, in: window) {
            dropCard()
            onEnd(landed.1)
        } else {
            returnCard()
            onEnd(nil)
        }
    }

    /// Esc during a drag: fly the card back.
    override func cancelOperation(_ sender: Any?) {
        guard isDragging, let coordinator else { return }
        coordinator.cancel()
        returnCard()
        onEnd(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let entries = menuEntries()
        guard !entries.isEmpty else { return nil }
        return PlannerNSMenu.build(entries, run: onCommand)
    }

    // MARK: The floating card

    private func screenPoint(_ windowPoint: CGPoint) -> CGPoint {
        window?.convertPoint(toScreen: windowPoint) ?? windowPoint
    }

    private func liftCard(rowInWindow: CGRect, grabbedAt a: CGPoint) {
        guard let payload else { return }
        let origin = screenPoint(rowInWindow.origin)
        rowScreenRect = CGRect(origin: origin, size: rowInWindow.size)
        let grab = screenPoint(a)
        grabInScreen = CGSize(width: grab.x - origin.x, height: grab.y - origin.y)

        let inset = Self.cardInset
        let host = NSHostingView(rootView: PlannerDragCard(payload: payload))
        host.frame = CGRect(x: inset, y: inset, width: rowInWindow.width, height: rowInWindow.height)
        let content = NSView(frame: rowScreenRect.insetBy(dx: -inset, dy: -inset))
        content.addSubview(host)
        let card = NSWindow(
            contentRect: rowScreenRect.insetBy(dx: -inset, dy: -inset),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = false
        card.ignoresMouseEvents = true
        card.level = .floating
        card.isReleasedWhenClosed = false
        card.contentView = content
        window?.addChildWindow(card, ordered: .above)
        card.orderFront(nil)
        floatingCard = card
        cardHost = host
    }

    /// Keep the grab offset: the card's row origin sits at pointer - offset.
    private func moveCard(toWindowPoint p: CGPoint) {
        guard let card = floatingCard, let payload else { return }
        let s = screenPoint(p)
        let inset = Self.cardInset
        card.setFrameOrigin(CGPoint(x: s.x - grabInScreen.width - inset, y: s.y - grabInScreen.height - inset))
        cardHost?.rootView = PlannerDragCard(payload: payload, overSlot: coordinator?.target != nil)
    }

    /// Dropped on a slot: the card fades into the ghost tile, which becomes the block.
    private func dropCard() {
        guard let card = floatingCard else { return }
        floatingCard = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            card.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            card.parent?.removeChildWindow(card)
            card.orderOut(nil)
            _ = self
        })
    }

    /// Missed, or Esc: the card flies back to the row's slot, then the row
    /// returns to the list.
    private func returnCard() {
        let coordinator = self.coordinator
        guard let card = floatingCard else { coordinator?.finish(); return }
        let inset = Self.cardInset
        let home = rowScreenRect.insetBy(dx: -inset, dy: -inset)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            card.animator().setFrame(home, display: true)
        }, completionHandler: { [weak self] in
            card.parent?.removeChildWindow(card)
            card.orderOut(nil)
            self?.floatingCard = nil
            coordinator?.finish()
        })
    }
}

private struct SourceRepresentable: NSViewRepresentable {
    let payload: PlannerTaskDragCoordinator.Payload
    let coordinator: PlannerTaskDragCoordinator
    let onBegin: () -> Void
    let onEnd: (PlannerTaskDragCoordinator.Target?) -> Void
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let menuEntries: () -> [PlannerMenuEntry]
    let onCommand: (PlannerTileCommand) -> Void
    var tapExclusionWidth: CGFloat = 0
    var identifier: String? = nil

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
        v.onClick = onClick
        v.onDoubleClick = onDoubleClick
        v.menuEntries = menuEntries
        v.onCommand = onCommand
    }
}
#else
/// The iPhone row: hold (0.3 s), and the row lifts out of the panel. The
/// panel slides away, a copy of the row follows the finger (drawn by
/// `PlannerView`), and release drops it on a slot or flies it back.
final class PlannerTaskDragSourceView: UIView {
    var payload: PlannerTaskDragCoordinator.Payload?
    weak var coordinator: PlannerTaskDragCoordinator?
    var onBegin: () -> Void = {}
    var onEnd: (PlannerTaskDragCoordinator.Target?) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var menuEntries: () -> [PlannerMenuEntry] = { [] }
    var onCommand: (PlannerTileCommand) -> Void = { _ in }
    /// The trailing width a tap ignores (the To-plan row's Plan button).
    var tapExclusionWidth: CGFloat = PlannerTaskDragSourceView.trailingButtonWidth

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        hold.minimumPressDuration = 0.3
        addGestureRecognizer(hold)
        // A tap opens the task (#687 round 6). It waits for the hold to fail, so
        // a hold always lifts and never also opens the editor.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: hold)
        addGestureRecognizer(tap)
    }

    /// The row's trailing Plan button. UIKit hit-tests this view under the
    /// whole row, so a tap on the button would also reach the recogniser here;
    /// the button keeps its own tap.
    static let trailingButtonWidth: CGFloat = 76

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard g.location(in: self).x < bounds.width - tapExclusionWidth else { return }
        onClick()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func handle(_ g: UILongPressGestureRecognizer) {
        guard let coordinator else { return }
        let p = g.location(in: nil)
        switch g.state {
        case .began:
            guard let payload else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            coordinator.begin(payload, sourceFrame: convert(bounds, to: nil), grabbedAt: p)
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
    let onClick: () -> Void
    let onDoubleClick: () -> Void
    let menuEntries: () -> [PlannerMenuEntry]
    let onCommand: (PlannerTileCommand) -> Void
    let tapExclusionWidth: CGFloat
    let identifier: String?

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
        v.onClick = onClick
        v.onDoubleClick = onDoubleClick
        v.menuEntries = menuEntries
        v.onCommand = onCommand
        v.tapExclusionWidth = tapExclusionWidth
        v.accessibilityIdentifier = identifier ?? "planner.toplan.drag.\(payload.title)"
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
