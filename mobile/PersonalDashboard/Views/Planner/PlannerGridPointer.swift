import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Drag-to-create on the empty space of a day column (#687 round 3).
///
/// The layer sits UNDER the tiles, so a click or tap on a tile still reaches
/// the tile's own button. On empty space:
/// - Mac: mouse down, drag up or down, release. A click with no drag makes a
///   30 minute draft.
/// - iPhone: press and hold for 0.3 s (with a haptic), then drag. A plain tap
///   makes a 30 minute draft. A normal swipe still scrolls, because the hold
///   fails as soon as the finger moves before 0.3 s.
///
/// Both platforms are native pointer code, not SwiftUI gestures. On the Mac
/// that is what makes the drag testable headlessly (`mouseDown` and friends
/// are called directly in `DexterMacTests`), and on the iPhone it is what lets
/// the hold switch the scroll view's pan off for the length of the drag. The
/// geometry itself is `PlannerDragGeometry`, which is pure and unit-tested.
struct PlannerGridPointerLayer: View {
    let hourHeight: CGFloat
    /// The draft range while the pointer moves.
    let onChange: (PlannerDragGeometry.Range) -> Void
    /// The final range, on release, or for a plain click or tap.
    let onCommit: (PlannerDragGeometry.Range) -> Void

    var body: some View {
        Representable(hourHeight: hourHeight, onChange: onChange, onCommit: onCommit)
    }
}

#if os(macOS)

/// The Mac pointer view. `isFlipped`, so y grows downward like the grid.
final class PlannerGridPointerView: NSView {
    var hourHeight: CGFloat = PlannerGridMetrics.hourHeight
    var onChange: ((PlannerDragGeometry.Range) -> Void)?
    var onCommit: ((PlannerDragGeometry.Range) -> Void)?

    private(set) var anchor: CGPoint?
    private(set) var isDragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// With a window, convert from window space. Without one (the headless
    /// tests), `locationInWindow` already IS view space.
    func localPoint(for event: NSEvent) -> CGPoint {
        guard window != nil else { return event.locationInWindow }
        return convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        // Taking first responder resigns any field that held the caret, so a
        // half-typed quick-create title commits before a new draft starts
        // (see project_macos_inline_edit_caret_and_resign).
        window?.makeFirstResponder(self)
        anchor = localPoint(for: event)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = localPoint(for: event)
        if !isDragging, PlannerDragGeometry.isDrag(from: anchor, to: p) { isDragging = true }
        guard isDragging else { return }
        onChange?(PlannerDragGeometry.range(anchorY: anchor.y, currentY: p.y, hourHeight: hourHeight))
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor else { return }
        let p = localPoint(for: event)
        let range = isDragging
            ? PlannerDragGeometry.range(anchorY: anchor.y, currentY: p.y, hourHeight: hourHeight)
            : PlannerDragGeometry.tapRange(atY: anchor.y, hourHeight: hourHeight)
        self.anchor = nil
        isDragging = false
        onCommit?(range)
    }
}

private struct Representable: NSViewRepresentable {
    let hourHeight: CGFloat
    let onChange: (PlannerDragGeometry.Range) -> Void
    let onCommit: (PlannerDragGeometry.Range) -> Void

    func makeNSView(context: Context) -> PlannerGridPointerView {
        let v = PlannerGridPointerView()
        update(v)
        return v
    }

    func updateNSView(_ v: PlannerGridPointerView, context: Context) { update(v) }

    private func update(_ v: PlannerGridPointerView) {
        v.hourHeight = hourHeight
        v.onChange = onChange
        v.onCommit = onCommit
    }
}

#else

/// The iPhone pointer view: a hold-then-drag recogniser and a tap recogniser.
final class PlannerGridPointerView: UIView {
    var hourHeight: CGFloat = PlannerGridMetrics.hourHeight
    var onChange: ((PlannerDragGeometry.Range) -> Void)?
    var onCommit: ((PlannerDragGeometry.Range) -> Void)?

    private var anchorY: CGFloat?
    private weak var pausedScroll: UIScrollView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.3
        addGestureRecognizer(hold)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: hold)
        addGestureRecognizer(tap)
        isAccessibilityElement = true
        accessibilityLabel = "Empty time"
        accessibilityHint = "Double tap to add a block here. Touch and hold, then drag, to set its length."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        onCommit?(PlannerDragGeometry.tapRange(atY: g.location(in: self).y, hourHeight: hourHeight))
    }

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        let y = g.location(in: self).y
        switch g.state {
        case .began:
            anchorY = y
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            // The hold owns the finger now: stop the scroll view panning until
            // the drag ends, so dragging sets the length and does not scroll.
            if let scroll = enclosingScrollView() {
                scroll.panGestureRecognizer.isEnabled = false
                pausedScroll = scroll
            }
            onChange?(PlannerDragGeometry.range(anchorY: y, currentY: y + 1, hourHeight: hourHeight))
        case .changed:
            guard let a = anchorY else { return }
            onChange?(PlannerDragGeometry.range(anchorY: a, currentY: y, hourHeight: hourHeight))
        case .ended:
            guard let a = anchorY else { return }
            finish()
            let moved = abs(y - a) >= PlannerDragGeometry.dragThreshold
            onCommit?(moved
                ? PlannerDragGeometry.range(anchorY: a, currentY: y, hourHeight: hourHeight)
                : PlannerDragGeometry.tapRange(atY: a, hourHeight: hourHeight))
        case .cancelled, .failed:
            finish()
        default:
            break
        }
    }

    private func finish() {
        anchorY = nil
        pausedScroll?.panGestureRecognizer.isEnabled = true
        pausedScroll = nil
    }

    private func enclosingScrollView() -> UIScrollView? {
        var v = superview
        while let current = v {
            if let s = current as? UIScrollView { return s }
            v = current.superview
        }
        return nil
    }
}

private struct Representable: UIViewRepresentable {
    let hourHeight: CGFloat
    let onChange: (PlannerDragGeometry.Range) -> Void
    let onCommit: (PlannerDragGeometry.Range) -> Void

    func makeUIView(context: Context) -> PlannerGridPointerView {
        let v = PlannerGridPointerView()
        update(v)
        return v
    }

    func updateUIView(_ v: PlannerGridPointerView, context: Context) { update(v) }

    private func update(_ v: PlannerGridPointerView) {
        v.hourHeight = hourHeight
        v.onChange = onChange
        v.onCommit = onCommit
    }
}

#endif
