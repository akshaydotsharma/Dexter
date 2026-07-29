import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A pan-and-zoom image view, backed by the platform's own scroll view so the
/// gestures are the real ones: pinch and double-tap on iOS, pinch and
/// scroll-to-zoom on macOS.
///
/// Extracted from the ticket viewer (#319) so note images get the same behaviour
/// rather than a second implementation (#395). The optional `scale` binding is the
/// only addition: it lets a host drive magnification from buttons, because on
/// macOS a trackpad pinch is the only discoverable way in and a mouse user has
/// none at all.
///
/// ⚠️ Finance still carries its OWN viewer, private inside `AddExpenseSheet`, and
/// that one is more capable: a centring scroll view plus a fit-derived minimum
/// zoom, which handles an image larger than the viewport better than this does.
/// The right end state is one implementation built on that, used by all three
/// callers. It is deliberately NOT done here: receipts are a working surface and
/// swapping their viewer to get note zoom would put a regression there on the
/// wrong ticket. Hence the distinct name rather than a shadowed one.
struct PinchZoomImageView: View {
    let image: PlatformImage
    /// Current magnification, when the host wants to drive or observe it. The
    /// backing scroll view stays the source of truth and writes changes back, so
    /// a pinch and a button press cannot disagree.
    var scale: Binding<CGFloat>? = nil

    static let minScale: CGFloat = 1.0
    static let maxScale: CGFloat = 6.0

    var body: some View {
        PinchZoomRepresentable(image: image, scale: scale)
    }
}

// MARK: - iOS

#if canImport(UIKit)
private struct PinchZoomRepresentable: UIViewRepresentable {
    let image: UIImage
    var scale: Binding<CGFloat>?

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = PinchZoomImageView.minScale
        scrollView.maximumZoomScale = PinchZoomImageView.maxScale
        scrollView.bouncesZoom = true

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scale = scale

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.scale = scale
        (uiView.subviews.first as? UIImageView)?.image = image
        // Apply a host-driven change, but only a real one: assigning the value the
        // scroll view already has would fight an in-flight pinch.
        if let target = scale?.wrappedValue,
           abs(uiView.zoomScale - target) > 0.01 {
            uiView.setZoomScale(target, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var scale: Binding<CGFloat>?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let scale, abs(scale.wrappedValue - scrollView.zoomScale) > 0.01 else { return }
            scale.wrappedValue = scrollView.zoomScale
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                scrollView.setZoomScale(min(scrollView.maximumZoomScale, 2.5), animated: true)
            }
        }
    }
}

// MARK: - macOS

#elseif canImport(AppKit)
private struct PinchZoomRepresentable: NSViewRepresentable {
    let image: NSImage
    var scale: Binding<CGFloat>?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = PinchZoomImageView.minScale
        scrollView.maxMagnification = PinchZoomImageView.maxScale

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        scrollView.documentView = imageView

        context.coordinator.observe(scrollView, scale: scale)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.scale = scale
        (nsView.documentView as? NSImageView)?.image = image
        // At magnification 1 the document tracks the viewport, so the image fits.
        // Once magnified, resizing it back would cancel the zoom.
        if abs(nsView.magnification - PinchZoomImageView.minScale) < 0.01 {
            nsView.documentView?.frame = nsView.contentView.bounds
        }
        if let target = scale?.wrappedValue,
           abs(nsView.magnification - target) > 0.01 {
            // Anchored to the visible centre so zooming with the buttons keeps
            // whatever the user was looking at, rather than jumping to a corner.
            let bounds = nsView.contentView.bounds
            nsView.setMagnification(
                target,
                centeredAt: CGPoint(x: bounds.midX, y: bounds.midY)
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var scale: Binding<CGFloat>?
        private weak var scrollView: NSScrollView?

        func observe(_ scrollView: NSScrollView, scale: Binding<CGFloat>?) {
            self.scrollView = scrollView
            self.scale = scale
            // A live pinch has to write back, or the buttons would keep operating
            // on a stale value and the first press would jump.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(magnificationChanged),
                name: NSScrollView.didEndLiveMagnifyNotification,
                object: scrollView
            )
        }

        @objc private func magnificationChanged() {
            guard let scrollView, let scale,
                  abs(scale.wrappedValue - scrollView.magnification) > 0.01 else { return }
            scale.wrappedValue = scrollView.magnification
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
#endif

// MARK: - Zoom controls

/// Plus / minus / reset for a `PinchZoomImageView`, for when a gesture is not
/// obvious or not available (a mouse on macOS has no pinch).
struct ZoomControls: View {
    @Binding var scale: CGFloat
    /// Multiplier per press. 1.5 gets from fit to legible in two taps without
    /// overshooting on the first.
    private let step: CGFloat = 1.5

    var body: some View {
        HStack(spacing: 2) {
            button(systemName: "minus.magnifyingglass", label: "Zoom out") {
                set(scale / step)
            }
            .disabled(scale <= PinchZoomImageView.minScale + 0.01)

            Button {
                set(PinchZoomImageView.minScale)
            } label: {
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.edFootnote)
                    .monospacedDigit()
                    .frame(minWidth: 46)
            }
            .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
            .help("Reset to fit")
            .accessibilityLabel("Reset zoom to fit")

            button(systemName: "plus.magnifyingglass", label: "Zoom in") {
                set(scale * step)
            }
            .disabled(scale >= PinchZoomImageView.maxScale - 0.01)
        }
    }

    private func button(
        systemName: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
        }
        .buttonStyle(EdIconButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func set(_ value: CGFloat) {
        scale = min(max(value, PinchZoomImageView.minScale), PinchZoomImageView.maxScale)
    }
}
