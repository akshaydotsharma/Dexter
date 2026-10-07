#if os(iOS)
import SwiftUI
import UIKit

/// Pick up a Dexter tile on the iPhone grid and move it to another time (#693).
///
/// The layer covers the tile's face. It holds the tile's two touch
/// behaviours, so they cannot fight each other:
/// - A tap opens the tile's quick view, as the old Button did.
/// - Touch and hold (0.3 s, with a haptic) lifts the tile. The grid's scroll
///   pan stops for the length of the drag, the tile follows the finger,
///   snapped to the quarter hour, and release moves it there.
///
/// The bottom-edge resize strip is a SIBLING drawn above this layer, so a
/// touch on the edge is hit-tested to the strip and never reaches the hold
/// here. The grid's create-by-hold layer sits UNDER the tiles, so a hold on
/// a tile never makes a draft.
///
/// Native UIKit recognisers, not SwiftUI gestures, for the same reasons as
/// `PlannerGridPointerLayer`: the hold can switch the scroll pan off, and the
/// arbitration between hold, tap and scroll is UIKit's own, which XCUITest
/// drives the same way a finger does.
struct PlannerTileMoveLayer: View {
    let identifier: String
    let onTap: () -> Void
    /// The drag distance in points, downward positive, in WINDOW space.
    let onChange: (CGFloat) -> Void
    /// The final distance. 0 for a hold released in place or cancelled.
    let onCommit: (CGFloat) -> Void
    var onBegin: () -> Void = {}

    var body: some View {
        MoveRepresentable(identifier: identifier, onTap: onTap, onBegin: onBegin,
                          onChange: onChange, onCommit: onCommit)
    }
}

final class PlannerTileMoveView: UIView {
    var onTap: (() -> Void)?
    var onBegin: (() -> Void)?
    var onChange: ((CGFloat) -> Void)?
    var onCommit: ((CGFloat) -> Void)?
    private var anchorY: CGFloat?
    private weak var pausedScroll: UIScrollView?

    static let holdDuration: TimeInterval = 0.3

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = Self.holdDuration
        addGestureRecognizer(hold)
        // A tap waits for the hold to fail, so a hold never also opens the
        // quick view. A short tap fails the hold on touch-up, so it is not
        // delayed.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: hold)
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func handleTap() { onTap?() }

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        // Window space: the tile moves under the finger while it is dragged,
        // so a distance measured in this view's own space would feed back
        // into itself (the #687 round 5 resize flicker).
        let y = g.location(in: nil).y
        switch g.state {
        case .began:
            anchorY = y
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if let scroll = enclosingScrollView() {
                scroll.panGestureRecognizer.isEnabled = false
                pausedScroll = scroll
            }
            onBegin?()
            onChange?(0)
        case .changed:
            if let a = anchorY { onChange?(y - a) }
        case .ended:
            guard let a = anchorY else { return }
            finish()
            onCommit?(y - a)
        case .cancelled, .failed:
            guard anchorY != nil else { return }
            finish()
            onCommit?(0)
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

private struct MoveRepresentable: UIViewRepresentable {
    let identifier: String
    let onTap: () -> Void
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onCommit: (CGFloat) -> Void

    func makeUIView(context: Context) -> PlannerTileMoveView {
        let v = PlannerTileMoveView()
        update(v)
        return v
    }

    func updateUIView(_ v: PlannerTileMoveView, context: Context) { update(v) }

    private func update(_ v: PlannerTileMoveView) {
        v.onTap = onTap
        v.onBegin = onBegin
        v.onChange = onChange
        v.onCommit = onCommit
        v.accessibilityIdentifier = identifier
    }
}
#endif
