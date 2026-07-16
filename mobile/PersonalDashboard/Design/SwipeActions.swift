import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Swipe-left-to-delete with circular red trash + gray fade card,
/// keyed to a UIKit-bridged horizontal-only pan recognizer so the
/// parent List's vertical scroll is never starved.
///
/// SwiftUI gesture arbitration cannot filter by direction at the
/// recognizer level — `DragGesture(minimumDistance: 10)` claims the
/// touch as soon as movement crosses 10pt regardless of direction,
/// even with an `abs(width) > abs(height)` early-return inside
/// `onChanged`. The early-return suppresses visual changes but does
/// not release the gesture, so vertical drags over rows never reach
/// the List's UIScrollView pan and scroll dies.
///
/// UIKit's UIPanGestureRecognizer fixes this via
/// `gestureRecognizerShouldBegin`: returning false for
/// vertical-dominant velocity transitions the recognizer to
/// `.failed`, freeing the parent List's pan to begin. Inner buttons
/// (toggle, info icon) keep their tap behavior because short taps
/// never trigger the pan in the first place; once the pan does
/// claim a horizontal touch, `cancelsTouchesInView = true` cancels
/// the row's onTapGesture so the same swipe doesn't ALSO navigate
/// into the row.
extension View {
    func swipeToDeleteTrash(perform action: @escaping () -> Void) -> some View {
        #if canImport(UIKit)
        return modifier(SwipeToDeleteWithTint(onDelete: action))
        #else
        // macOS: the custom UIKit pan bridge below doesn't exist. Rows live
        // inside a `List`, so the native trailing swipe-to-delete gives the
        // same affordance with a real destructive full-swipe.
        return self.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: action) {
                Label("Delete", systemImage: "trash")
            }
        }
        #endif
    }
}

#if canImport(UIKit)
private struct SwipeToDeleteWithTint: ViewModifier {
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isOpen: Bool = false
    @State private var didCrossCommitThreshold: Bool = false

    private let buttonSize: CGFloat = 52
    private let revealedWidth: CGFloat = 60
    // Generous pill-leaning radius. On short single-line rows (~40pt
    // tall) SwiftUI clamps this to half the height and the swiped row
    // renders as a true pill; on multi-line rows it stays a strongly
    // rounded card. Applies uniformly to every surface using
    // `.swipeToDeleteTrash` (Tasks, Notes, Lists, Finance, Itineraries,
    // Vocabulary, side drawer) because every row above the modifier
    // sets `.listRowBackground(Color.clear)`, leaving this tint card as
    // the dominant visible fill during the swipe.
    private let cardCornerRadius: CGFloat = 26
    private let tintColor: Color = Tokens.borderStrong
    private let trashColor: Color = Color(.sRGB, red: 1.0, green: 0.231, blue: 0.188, opacity: 1.0)
    private let openCloseAnimation: Animation = .snappy(duration: 0.26, extraBounce: 0.04)
    // Leftward (negative) flick speed above which we treat the gesture
    // as "the user wants this open even if they didn't drag all the
    // way". Matches the velocity-aware completion native iOS Mail uses
    // — a small swipe + flick auto-opens.
    private let flickVelocityThreshold: CGFloat = 350

    func body(content: Content) -> some View {
        let dragDistance = -offset
        let linear = min(1.0, max(0.0, Double(dragDistance / revealedWidth)))
        let progress = 0.5 - 0.5 * cos(.pi * linear)
        let commitThreshold = UIScreen.main.bounds.width * 0.55

        // Z-order matters: the trash button is drawn IN FRONT of the
        // pan-capture wrapper so that its 52pt frame at the trailing
        // edge claims taps directly. Drawing it behind (the original
        // arrangement) meant the wrapper's full-width close-on-tap
        // overlay swallowed every tap on the visible trash — SwiftUI's
        // `.offset(x:)` translates content visually but does NOT shift
        // hit testing, so the overlay's hit area still covered the
        // trash region after the swipe revealed it. Result: 1st tap
        // closed the row, 2nd tap re-opened, 3rd tap finally deleted.
        // (#94)
        ZStack(alignment: .trailing) {
            HorizontalPanCapture(
                onChanged: { dx in
                    let raw = (isOpen ? -revealedWidth : 0) + dx
                    offset = applyRubberBand(to: raw)

                    let crossing = -offset > commitThreshold
                    if crossing && !didCrossCommitThreshold {
                        Haptics.tick()
                        didCrossCommitThreshold = true
                    } else if !crossing && didCrossCommitThreshold {
                        didCrossCommitThreshold = false
                    }
                },
                onEnded: { dx, vx in
                    let endRaw = (isOpen ? -revealedWidth : 0) + dx
                    let dragMag = -endRaw
                    didCrossCommitThreshold = false

                    // Velocity-aware completion gives the "slides itself"
                    // feel of native iOS Mail. A leftward flick on a
                    // short drag still commits to open; a rightward flick
                    // on a partially-open row still closes.
                    let leftFlick = vx <= -flickVelocityThreshold
                    let rightFlick = vx >= flickVelocityThreshold

                    if dragMag > commitThreshold {
                        commit()
                    } else if leftFlick && dragMag > revealedWidth * 0.25 {
                        // Strong leftward flick past a quarter of the
                        // reveal width: treat as intent to open even if
                        // the finger didn't make it all the way.
                        open()
                    } else if rightFlick {
                        close()
                    } else if dragMag > revealedWidth * 0.35 {
                        open()
                    } else {
                        close()
                    }
                }
            ) {
                content
                    // Commit to the proposed width and grow vertically to
                    // the wrapped height. `horizontal: false` means the row
                    // still uses the width the List proposes (no wide/unbounded
                    // natural width leaking out — the pill background keeps
                    // sizing to the row), while `vertical: true` stops the
                    // hosting controller from collapsing multiline `Text` to a
                    // single truncated line. Rows that set their own
                    // `.lineLimit` keep that line count; this only removes the
                    // forced single-line clamp.
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                            .fill(tintColor)
                            .opacity(progress)
                    )
                    .overlay(closeOverlay)
                    .offset(x: offset)
            }

            Button(action: commit) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Circle().fill(trashColor))
                    .scaleEffect(0.85 + 0.15 * progress)
            }
            .buttonStyle(.plain)
            .opacity(progress)
            // Only intercept taps once the swipe has clearly revealed
            // the trash. Below that threshold we leave hit testing to
            // the underlying content so partial drags / scroll handoff
            // stay unaffected.
            .allowsHitTesting(isOpen && dragDistance >= revealedWidth * 0.6)
            .accessibilityLabel("Delete")
        }
    }

    @ViewBuilder
    private var closeOverlay: some View {
        if isOpen {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { close() }
        }
    }

    // Loose asymptotic rubber-band — `f(x) = x / (1 + 0.005·x)`. f'(0)
    // = 1 (1:1 with finger at the boundary, no derivative kink), and
    // the asymptote is much further out (~200pt) than the prior 0.012
    // coefficient (~85pt). Result: the row keeps tracking the finger
    // almost freely past the reveal width, matching the "slides itself"
    // feel of native iOS swipe — most of the perceived "stiffness" of
    // the earlier curve came from the resistance being too aggressive
    // in the first 20–40pt of overshoot, exactly where users still feel
    // the gesture should be free.
    private func applyRubberBand(to raw: CGFloat) -> CGFloat {
        if raw >= 0 { return 0 }
        let mag = -raw
        if mag <= revealedWidth { return raw }
        let overshoot = mag - revealedWidth
        let damped = overshoot / (1.0 + overshoot * 0.005)
        return -(revealedWidth + damped)
    }

    private func open() {
        isOpen = true
        withAnimation(openCloseAnimation) {
            offset = -revealedWidth
        }
    }

    private func close() {
        isOpen = false
        withAnimation(openCloseAnimation) {
            offset = 0
        }
    }

    private func commit() {
        // Fire delete on the same runloop tick as the tap so the
        // List's native row-removal animation kicks in immediately.
        // The bespoke slide-off + 0.2s deferred call previously made
        // every confirmed delete feel ~250ms laggy and let the user
        // queue up a second tap mid-animation. (#94)
        Haptics.destructive()
        isOpen = false
        onDelete()
    }
}

/// UIKit-bridged horizontal-only pan recognizer wrapping arbitrary
/// SwiftUI content. The hosting view is an ancestor of the SwiftUI
/// content's hosting controller view, so the recognizer sees touches
/// that hit anywhere in the wrapped subtree. `cancelsTouchesInView
/// = false` plus `shouldRecognizeSimultaneouslyWith = true` keeps
/// tap-on-Button working; `gestureRecognizerShouldBegin` filtering
/// on velocity direction lets the parent List's vertical scroll
/// proceed when the user drags vertically.
private struct HorizontalPanCapture<Content: View>: UIViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let content: Content

    init(
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping (CGFloat, CGFloat) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onChanged = onChanged
        self.onEnded = onEnded
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> ContainerView {
        let host = UIHostingController(rootView: AnyView(content))
        host.view.backgroundColor = .clear
        // Do NOT use `host.sizingOptions = [.intrinsicContentSize]` —
        // SwiftUI text-heavy content reports a wide unbounded
        // natural width as its intrinsic size, which leaks through
        // the wrapper and makes some rows render edge-to-edge with
        // no pill background. We size via `sizeThatFits` instead so
        // the host always lays out at the width SwiftUI proposes.

        let container = ContainerView()
        container.backgroundColor = .clear
        container.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.host = host

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        pan.delegate = context.coordinator
        // Hold touches from the SwiftUI subtree until the pan decides
        // whether to begin. cancelsTouchesInView alone wasn't enough on
        // SwiftUI `Button(action:)` rows (Lists): the button's gesture
        // had already started tracking before the cancel arrived, so a
        // swipe still fired the button's action on touch-up. With
        // delaysTouchesBegan = true, the buffered touch is pushed
        // through only when the pan fails (vertical / no motion); taps
        // on rows still fire, and horizontal swipes never leak into the
        // row's tap. Same pattern UIScrollView's panGesture uses to
        // arbitrate scroll vs. tap.
        pan.delaysTouchesBegan = true
        pan.cancelsTouchesInView = true
        container.addGestureRecognizer(pan)

        return container
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.host?.rootView = AnyView(content)
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }



    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ContainerView,
        context: Context
    ) -> CGSize? {
        guard let host = uiView.host else { return nil }
        // Fall back to the screen width (not 0) when the List proposes no
        // width — a 0-width proposal would wrap the text to nothing and
        // report an absurd height.
        let proposedWidth = proposal.width ?? UIScreen.main.bounds.width
        // Measure at the concrete proposed width with an UNBOUNDED height.
        // The previous code proposed `layoutFittingCompressedSize.height`
        // (== 0), which asks the hosted content for its *smallest* height
        // at that width. A multiline `Text` with no `lineLimit` can shrink
        // to a single truncated line, so the row was measured (and then
        // laid out) one line tall and the text rendered with an ellipsis.
        // Proposing an expanded height lets the host report the fully
        // wrapped height, so rows without a `lineLimit` grow to fit.
        // Truncation-neutral: content that sets its own `.lineLimit(1)`
        // (e.g. NotesView) still measures one line because it cannot exceed
        // that regardless of the height offered here.
        let measured = host.sizeThatFits(
            in: CGSize(width: proposedWidth, height: UIView.layoutFittingExpandedSize.height)
        )
        return CGSize(width: proposedWidth, height: measured.height)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void

        init(
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handle(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view).x
            switch g.state {
            case .changed:
                onChanged(t)
            case .ended, .cancelled, .failed:
                let vx = g.velocity(in: g.view).x
                onEnded(t, vx)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            // Direction filter only — no magnitude gate. The pan
            // recognizer's own begin threshold ensures shouldBegin only
            // fires after enough motion to read direction; adding our
            // own minimum-x requirement risks permanently failing the
            // pan if shouldBegin is sampled at the wrong instant.
            // Check both velocity and translation: if EITHER says the
            // gesture is horizontal-dominant, claim. This tolerates
            // both fast flicks (high velocity, low translation) and
            // slow pulls (low velocity, accumulated translation).
            let v = pan.velocity(in: pan.view)
            let t = pan.translation(in: pan.view)
            let horizontalByVelocity = abs(v.x) > abs(v.y) * 1.5
            let horizontalByTranslation = abs(t.x) > abs(t.y) * 1.5
            return horizontalByVelocity || horizontalByTranslation
        }

        func gestureRecognizer(
            _ g: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            return true
        }
    }

    final class ContainerView: UIView {
        var host: UIHostingController<AnyView>?
    }
}
#endif
