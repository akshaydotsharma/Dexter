import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One action revealed by a row swipe (#374).
///
/// Array ORDER is leading-to-trailing in the revealed strip, so the last element
/// sits hard against the trailing edge. Delete goes last in every pair below,
/// which is what keeps the trash exactly where muscle memory already expects it
/// now that a second button shares the strip.
struct RowSwipeAction: Identifiable {
    /// SF Symbol name. Doubles as identity — no row reveals the same glyph twice.
    let icon: String
    let tint: Color
    /// Accessibility label, and the `contextMenu` title on macOS.
    let label: String
    /// Destructive actions get the warning thump and macOS's `.destructive` role;
    /// reversible ones get a soft impact and plain styling.
    let isDestructive: Bool
    let perform: () -> Void

    var id: String { icon }

    static func delete(_ perform: @escaping () -> Void) -> RowSwipeAction {
        RowSwipeAction(
            icon: "trash",
            // The literal sRGB red rather than `Tokens.danger`: this is the value
            // the trash circle has always used and it is deliberately the system
            // destructive red, not the paper palette's.
            tint: Color(.sRGB, red: 1.0, green: 0.231, blue: 0.188, opacity: 1.0),
            label: "Delete",
            isDestructive: true,
            perform: perform
        )
    }

    static func archive(_ perform: @escaping () -> Void) -> RowSwipeAction {
        RowSwipeAction(
            icon: "archivebox",
            // A warm neutral from the paper palette, mid-tone in both light and
            // dark so the white glyph stays legible either way. Reads as "put
            // away", clearly not as "destroy", beside the red trash.
            tint: Tokens.muted,
            label: "Archive",
            isDestructive: false,
            perform: perform
        )
    }

    static func unarchive(_ perform: @escaping () -> Void) -> RowSwipeAction {
        RowSwipeAction(
            icon: "tray.and.arrow.up",
            tint: Tokens.muted,
            label: "Unarchive",
            isDestructive: false,
            perform: perform
        )
    }
}

/// Swipe-left to reveal one or more circular action buttons over a gray fade
/// card, keyed to a UIKit-bridged horizontal-only pan recognizer so the
/// parent List's vertical scroll is never starved.
///
/// Originally delete-only; generalised to an ordered list of actions for the
/// Lists/Notes archive (#374). `swipeToDeleteTrash` is now a one-element case of
/// the general form, which is what guarantees every pre-existing surface keeps
/// identical behaviour — same 60pt reveal, same red trash, same full-swipe
/// commit — rather than relying on a second copy of the gesture code staying in
/// sync with this one.
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
    /// Swipe-left to delete. Unchanged behaviour for every surface that already
    /// used it (Tasks, Notes folders, Finance, Trips, Vocabulary, the side
    /// drawer): one button, a 60pt reveal, and full-swipe still commits.
    func swipeToDeleteTrash(perform action: @escaping () -> Void) -> some View {
        rowSwipeActions([.delete(action)])
    }

    /// Swipe-left to archive or delete, for an ACTIVE list or note row (#374).
    /// Archive is inboard, delete keeps the trailing edge.
    func swipeToArchiveOrDelete(
        onArchive: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        rowSwipeActions([.archive(onArchive), .delete(onDelete)])
    }

    /// The inverse pair, for a row inside the Archive (#374).
    func swipeToUnarchiveOrDelete(
        onUnarchive: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        rowSwipeActions([.unarchive(onUnarchive), .delete(onDelete)])
    }

    /// The general form: reveal `actions` on a left swipe, in order.
    ///
    /// Full-swipe-to-commit is enabled ONLY for a single action. With two or more
    /// buttons there is no non-arbitrary choice of what a long drag should mean,
    /// and guessing wrong would fire an irreversible delete on a gesture the user
    /// made to reach archive. So a multi-action row just holds open and waits for
    /// a tap (#374).
    func rowSwipeActions(_ actions: [RowSwipeAction]) -> some View {
        #if canImport(UIKit)
        return modifier(SwipeRevealActions(actions: actions))
        #else
        // macOS. Two affordances, because the swipe alone does not reach every
        // user or every container (issues #296, #297).
        //
        // The trailing swipe stays: inside a `List`, on a trackpad, it is the
        // Reminders-style red full-height button with a white trash glyph
        // (icon only — a Label stacks icon-over-text into an oversized pill on
        // tall rows), and full-swipe commits (issue #285).
        //
        // But it was the ONLY delete path, and it fails in two ways that
        // between them covered every expense surface in the app:
        //
        //  1. `.swipeActions` has no effect outside a `List`. The Finance
        //     expense list, Recurring Expenses, and Trip expenses all render
        //     rows in `ScrollView { VStack { ForEach } }`, so the modifier
        //     silently did nothing and those three surfaces had NO way to
        //     delete anything at all (#296). The comment previously here
        //     asserted "rows live inside a List", which was untrue for exactly
        //     those cases.
        //  2. A swipe needs a trackpad. With a mouse it is unreachable even
        //     where it does work (#297).
        //
        // A context menu has neither limitation: it works in any container and
        // it is the macOS-idiomatic home for a row's destructive action, which
        // is where Reminders puts it. This branch is macOS-only, so no
        // `.contextMenu` reaches iOS, where it would bind to long-press and
        // invent a phone gesture that the standing correction
        // `feedback_inline_edit_gestures.md` forbids.
        //
        // `.swipeActions` renders its buttons trailing-edge-first, i.e. the
        // REVERSE of the visual order the iOS strip uses. Reversing here means
        // one `actions` array describes both platforms and delete lands against
        // the window edge on each.
        return self
            // Full swipe only for a single action, matching iOS: with two
            // buttons a full trackpad swipe would otherwise commit whichever one
            // SwiftUI picked first.
            .swipeActions(edge: .trailing, allowsFullSwipe: actions.count == 1) {
                ForEach(actions.reversed()) { action in
                    if action.isDestructive {
                        Button(role: .destructive, action: action.perform) {
                            Image(systemName: action.icon)
                        }
                        .tint(.red)
                    } else {
                        Button(action: action.perform) {
                            Image(systemName: action.icon)
                        }
                        .tint(action.tint)
                    }
                }
            }
            .contextMenu {
                ForEach(actions) { action in
                    if action.isDestructive {
                        Button(role: .destructive, action: action.perform) {
                            Label(action.label, systemImage: action.icon)
                        }
                    } else {
                        Button(action: action.perform) {
                            Label(action.label, systemImage: action.icon)
                        }
                    }
                }
            }
        #endif
    }
}

#if canImport(UIKit)
private struct SwipeRevealActions: ViewModifier {
    let actions: [RowSwipeAction]

    @State private var offset: CGFloat = 0
    @State private var isOpen: Bool = false
    @State private var didCrossCommitThreshold: Bool = false

    private let buttonSize: CGFloat = 52
    /// Per-action slot. One action gives the 60pt reveal this modifier has always
    /// had, so single-action surfaces are pixel-identical (#374).
    private let slotWidth: CGFloat = 60
    private var revealedWidth: CGFloat { slotWidth * CGFloat(max(1, actions.count)) }

    /// Full-swipe-to-commit is a single-action affordance only — see
    /// `rowSwipeActions` for why.
    private var allowsFullSwipe: Bool { actions.count == 1 }
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
        // How much of the trailing strip the row has actually slid clear of.
        // Every pixel of every button is masked to this width, so a button can
        // only ever paint into the gap the row has left behind and never on top
        // of the row's own content (#378). Clamped at the reveal width so the
        // rubber-band overshoot doesn't keep extending the mask.
        let uncovered = max(0, min(dragDistance, revealedWidth))

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

                    // The threshold tick only means something when crossing it
                    // will actually commit something. On a multi-action row it
                    // would promise a commit that never comes.
                    guard allowsFullSwipe else { return }
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

                    if allowsFullSwipe, dragMag > commitThreshold, let only = actions.first {
                        commit(only)
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

            // One 60pt slot per action, laid out in `actions` order so the last
            // element ends up against the trailing edge. A single action
            // collapses to exactly the previous layout.
            //
            // The strip is revealed BY the row rather than fading in underneath
            // it (#378). Three things cooperate:
            //
            //  * the trailing-aligned mask, which is the hard guarantee — the
            //    strip simply does not render outside the vacated gap, so no
            //    icon can overlap the row's text or chevron the way it did when
            //    the whole strip fanned in on the global drag progress;
            //  * per-slot opacity and scale, so each button eases in over the
            //    60pt that uncovers IT (trash first, archive only once the row
            //    clears the trailing slot) instead of every button tracking the
            //    same number;
            //  * a partial slide, so the strip travels with the row's trailing
            //    edge and the reveal reads as the row dragging the buttons out
            //    rather than a wipe over static content.
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        let reveal = slotReveal(index, uncovered: uncovered)
                        Button { commit(action) } label: {
                            Image(systemName: action.icon)
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .background(Circle().fill(action.tint))
                                .scaleEffect(0.7 + 0.3 * reveal)
                        }
                        .buttonStyle(.plain)
                        .frame(width: slotWidth)
                        .opacity(reveal)
                        .accessibilityLabel(action.label)
                    }
                }
                // Inside the masked container, so the slide can never push a
                // circle out past the trailing edge and into the row's margin.
                .offset(x: (revealedWidth - uncovered) * 0.4)
            }
            .frame(width: revealedWidth)
            .mask(alignment: .trailing) {
                Rectangle().frame(width: uncovered)
            }
            // Only intercept taps once the swipe has clearly revealed
            // the buttons. Below that threshold we leave hit testing to
            // the underlying content so partial drags / scroll handoff
            // stay unaffected.
            .allowsHitTesting(isOpen && dragDistance >= revealedWidth * 0.6)
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

    /// How far along its own reveal a single button is, 0…1 eased.
    ///
    /// Slots are measured as distance leftward from the trailing edge, so slot
    /// `n-1` (the last element, e.g. delete) occupies the first 60pt and starts
    /// easing in immediately, while slot 0 (e.g. archive) doesn't begin until the
    /// row has already cleared every slot outboard of it. That staggering is what
    /// makes a slow swipe read the way Reminders does: one button at a time,
    /// each one appearing in space the row has genuinely left behind (#378).
    private func slotReveal(_ index: Int, uncovered: CGFloat) -> Double {
        let count = max(1, actions.count)
        let slotStart = CGFloat(count - 1 - index) * slotWidth
        let linear = min(1.0, max(0.0, Double((uncovered - slotStart) / slotWidth)))
        return 0.5 - 0.5 * cos(.pi * linear)
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

    private func commit(_ action: RowSwipeAction) {
        // Fire the action on the same runloop tick as the tap so the
        // List's native row-removal animation kicks in immediately.
        // The bespoke slide-off + 0.2s deferred call previously made
        // every confirmed delete feel ~250ms laggy and let the user
        // queue up a second tap mid-animation. (#94)
        //
        // Archive gets the soft impact rather than the warning thump: the
        // warning is the feel of "that was destructive", and archiving is not.
        if action.isDestructive {
            Haptics.destructive()
        } else {
            Haptics.light()
        }
        isOpen = false
        action.perform()
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
