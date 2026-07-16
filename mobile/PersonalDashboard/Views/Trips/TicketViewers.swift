import SwiftUI
import PDFKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Ticket viewers that must work on BOTH iOS and macOS (issue #281), relocated
/// here out of the iOS-only `TicketScanView.swift` (which is gated behind a
/// camera/brightness hardware path). These are reachable on macOS from the
/// non-camera flows: viewing an imported / emailed-in ticket's original file,
/// and the item editor's ticket thumbnail.
///
/// iOS behaviour is unchanged: on iOS every `#if canImport(UIKit)` branch below
/// compiles to the exact UIKit implementation these views had before the move
/// (a `PDFView`/`UIScrollView` representable pair). macOS gets equivalent AppKit
/// representables so the "View original" surface and the thumbnail both render.

// MARK: - Original file viewer

/// Full-screen viewer for the stored original ticket file, backed by
/// `TicketStorage`. Mirrors the Finance receipt viewer but reads from the
/// tickets directory. Native zoom on both platforms.
struct TicketOriginalViewer: View {
    let attachmentPath: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("Original ticket")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let url = TicketStorage.shared.load(relativePath: attachmentPath) {
            if TicketStorage.isPDF(attachmentPath) {
                TicketPDFView(url: url)
                    .ignoresSafeArea(edges: .bottom)
            } else if let image = loadReceiptPlatformImage(url) {
                TicketZoomableImageView(image: image)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                unavailable
            }
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        Text("The ticket file is no longer available.")
            .font(.edBody)
            .foregroundStyle(Tokens.muted)
    }
}

// MARK: - Attachment thumbnail

/// Small inline preview of a stored ticket file: the image for a photo/scan,
/// a doc icon for a PDF, a placeholder when the file is gone. Used by the item
/// editor's ticket section.
struct TicketAttachmentThumbnail: View {
    let relativePath: String

    var body: some View {
        Group {
            if let url = TicketStorage.shared.load(relativePath: relativePath) {
                if TicketStorage.isPDF(relativePath) {
                    icon("doc.text.fill", tint: Tokens.accent(for: .itineraries))
                } else if let image = Image(receiptFileURL: url) {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    icon("photo", tint: Tokens.muted)
                }
            } else {
                icon("photo", tint: Tokens.muted)
            }
        }
        .background(Tokens.surface2)
    }

    private func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PDF viewer

#if canImport(UIKit)
/// Thin `PDFView` wrapper with native pinch-zoom + page scrolling. Named
/// distinctly from Finance's `PDFKitView` (which is file-private) to avoid a
/// collision while keeping tickets self-contained.
private struct TicketPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
#else
/// macOS `PDFView` (AppKit-backed) wrapper. PDFKit is cross-platform; only the
/// SwiftUI representable protocol differs.
private struct TicketPDFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
#endif

// MARK: - Zoomable image

#if canImport(UIKit)
/// `UIScrollView` + `UIImageView` giving native pinch-to-zoom, pan, and
/// double-tap-to-toggle. A compact re-implementation (Finance's equivalent is
/// file-private).
private struct TicketZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

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
#else
/// macOS zoomable image: an `NSScrollView` hosting an `NSImageView` gives native
/// magnification (pinch / scroll-to-zoom) and pan, the AppKit analogue of the
/// iOS `UIScrollView` viewer.
private struct TicketZoomableImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 5.0

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        scrollView.documentView = imageView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        (nsView.documentView as? NSImageView)?.image = image
        nsView.documentView?.frame = nsView.contentView.bounds
    }
}
#endif
