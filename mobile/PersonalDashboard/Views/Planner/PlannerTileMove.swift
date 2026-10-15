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
    var onPointerBegin: ((CGPoint, AnyObject?) -> Void)? = nil
    var onPointerChange: ((CGPoint, AnyObject?) -> Void)? = nil
    var onPointerCommit: ((CGPoint, AnyObject?) -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        MoveRepresentable(identifier: identifier, onTap: onTap, onBegin: onBegin,
                          onChange: onChange, onCommit: onCommit, onPointerBegin: onPointerBegin,
                          onPointerChange: onPointerChange, onPointerCommit: onPointerCommit, onCancel: onCancel)
    }
}

final class PlannerTileMoveView: UIView, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?
    var onBegin: (() -> Void)?
    var onChange: ((CGFloat) -> Void)?
    var onCommit: ((CGFloat) -> Void)?
    var onPointerBegin: ((CGPoint, AnyObject?) -> Void)?
    var onPointerChange: ((CGPoint, AnyObject?) -> Void)?
    var onPointerCommit: ((CGPoint, AnyObject?) -> Void)?
    var onCancel: (() -> Void)?
    private var anchorY: CGFloat?
    private weak var pausedScroll: UIScrollView?
    private(set) var hold: UILongPressGestureRecognizer!

    static let holdDuration: TimeInterval = 0.3
    /// How far a finger may drift during the hold before it counts as a
    /// scroll (#697). UIKit's default is 10pt, which a resting thumb on a
    /// 120 Hz screen can cross while it waits; a little more keeps the hold.
    static let allowableMovement: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = Self.holdDuration
        hold.allowableMovement = Self.allowableMovement
        hold.delegate = self
        addGestureRecognizer(hold)
        self.hold = hold
        // A tap waits for the hold to fail, so a hold never also opens the
        // quick view. A short tap fails the hold on touch-up, so it is not
        // delayed.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: hold)
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func handleTap() { onTap?() }

    // MARK: Arbitration (#697)

    /// The hold must not run beside anything else. In particular not beside
    /// the grid's scroll pan, which on a real finger can begin first and
    /// carry the touch off as a scroll.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    /// For a touch that starts on a tile, the scroll pan (and any other pan or
    /// hold above the tile, such as SwiftUI's own) waits until the hold has
    /// failed. The hold fails at once when the finger moves more than
    /// `allowableMovement` or lifts, so a swipe that starts on a tile still
    /// scrolls; only a finger held still for 0.3 s keeps the tile. Without
    /// this, the order in which UIKit hands the touch to the recognisers
    /// decides, and that order is not the same on a device as in a test.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard g === hold, other.view !== self else { return false }
        let wait = other is UIPanGestureRecognizer || other is UILongPressGestureRecognizer
        if wait { PlannerMoveLog.line("hold blocks \(type(of: other)) on \(other.view.map { String(describing: type(of: $0)) } ?? "nil")") }
        return wait
    }

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        // Window space: the tile moves under the finger while it is dragged,
        // so a distance measured in this view's own space would feed back
        // into itself (the #687 round 5 resize flicker).
        let y = g.location(in: nil).y
        PlannerMoveLog.line("hold state=\(g.state.rawValue) y=\(Int(y))")
        switch g.state {
        case .began:
            anchorY = y
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if let scroll = enclosingScrollView() {
                scroll.panGestureRecognizer.isEnabled = false
                pausedScroll = scroll
            } else {
                PlannerMoveLog.line("no enclosing scroll view")
            }
            onBegin?()
            onPointerBegin?(g.location(in: nil), window)
            if onPointerChange == nil { onChange?(0) }
        case .changed:
            if let change = onPointerChange { change(g.location(in: nil), window) }
            else if let a = anchorY { onChange?(y - a) }
        case .ended:
            guard let a = anchorY else { return }
            finish()
            if let commit = onPointerCommit { commit(g.location(in: nil), window) }
            else { onCommit?(y - a) }
        case .cancelled, .failed:
            guard anchorY != nil else { return }
            finish()
            if let onCancel { onCancel() } else { onCommit?(0) }
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

/// Device evidence for the tile move (#697): `devicectl process launch
/// --console` streams stderr, so a hold on the phone prints which recogniser
/// won. One line per state change, only while a finger is on a tile.
enum PlannerMoveLog {
    static func line(_ s: String) {
        let text = "PlannerMove: \(s)\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}

private struct MoveRepresentable: UIViewRepresentable {
    let identifier: String
    let onTap: () -> Void
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onCommit: (CGFloat) -> Void
    let onPointerBegin: ((CGPoint, AnyObject?) -> Void)?
    let onPointerChange: ((CGPoint, AnyObject?) -> Void)?
    let onPointerCommit: ((CGPoint, AnyObject?) -> Void)?
    let onCancel: (() -> Void)?

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
        v.onPointerBegin = onPointerBegin
        v.onPointerChange = onPointerChange
        v.onPointerCommit = onPointerCommit
        v.onCancel = onCancel
        v.accessibilityIdentifier = identifier
    }
}
#endif
