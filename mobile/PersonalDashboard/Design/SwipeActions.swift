import SwiftUI
import UIKit

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
/// `.failed`, freeing the parent List's pan to begin. Tap
/// arbitration is preserved by `cancelsTouchesInView = false` plus
/// `shouldRecognizeSimultaneouslyWith` returning true — short
/// touches never reach the pan threshold, so the underlying SwiftUI
/// Button's tap fires normally.
extension View {
    func swipeToDeleteTrash(perform action: @escaping () -> Void) -> some View {
        modifier(SwipeToDeleteWithTint(onDelete: action))
    }
}

private struct SwipeToDeleteWithTint: ViewModifier {
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isOpen: Bool = false

    private let buttonSize: CGFloat = 52
    private let revealedWidth: CGFloat = 60
    private let cardCornerRadius: CGFloat = 14
    private let tintColor: Color = Tokens.borderStrong
    private let trashColor: Color = Color(.sRGB, red: 1.0, green: 0.231, blue: 0.188, opacity: 1.0)

    func body(content: Content) -> some View {
        let dragDistance = -offset
        let linear = min(1.0, max(0.0, Double(dragDistance / revealedWidth)))
        let progress = 0.5 - 0.5 * cos(.pi * linear)

        ZStack(alignment: .trailing) {
            Button(action: commit) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Circle().fill(trashColor))
            }
            .buttonStyle(.plain)
            .opacity(min(1.0, dragDistance / 20))
            .allowsHitTesting(dragDistance >= revealedWidth * 0.6)
            .accessibilityLabel("Delete")

            HorizontalPanCapture(
                onChanged: { dx in
                    let raw = (isOpen ? -revealedWidth : 0) + dx
                    offset = applyRubberBand(to: raw)
                },
                onEnded: { dx in
                    let endRaw = (isOpen ? -revealedWidth : 0) + dx
                    if -endRaw > UIScreen.main.bounds.width * 0.7 {
                        commit()
                    } else if -endRaw > revealedWidth * 0.4 {
                        open()
                    } else {
                        close()
                    }
                }
            ) {
                content
                    .background(
                        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                            .fill(tintColor)
                            .opacity(progress)
                    )
                    .overlay(closeOverlay)
                    .offset(x: offset)
            }
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

    private func applyRubberBand(to raw: CGFloat) -> CGFloat {
        if raw >= 0 { return 0 }
        if -raw <= revealedWidth { return raw }
        let overshoot = -raw - revealedWidth
        return -(revealedWidth + overshoot * 0.4)
    }

    private func open() {
        isOpen = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            offset = -revealedWidth
        }
    }

    private func close() {
        isOpen = false
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            offset = 0
        }
    }

    private func commit() {
        Haptics.destructive()
        withAnimation(.easeOut(duration: 0.22)) {
            offset = -UIScreen.main.bounds.width
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            onDelete()
        }
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
    let onEnded: (CGFloat) -> Void
    let content: Content

    init(
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping (CGFloat) -> Void,
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
        pan.cancelsTouchesInView = false
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
        let proposedWidth = proposal.width ?? UIView.layoutFittingCompressedSize.width
        let measured = host.sizeThatFits(
            in: CGSize(width: proposedWidth, height: UIView.layoutFittingCompressedSize.height)
        )
        return CGSize(width: proposedWidth, height: measured.height)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat) -> Void

        init(
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat) -> Void
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
                onEnded(t)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y) * 1.5
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
