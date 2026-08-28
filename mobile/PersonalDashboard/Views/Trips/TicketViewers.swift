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

    /// Driven by the zoom buttons, which are the only way in for a mouse user.
    @State private var scale: CGFloat = PinchZoomImageView.minScale

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("Original ticket")
            .inlineNavigationTitle()
            .toolbar {
                #if os(macOS)
                // A trackpad pinch is the only gesture into the zoom view on macOS
                // and a mouse has none at all, so the buttons are not optional here.
                ToolbarItem(placement: .automatic) {
                    if isZoomableImage { ZoomControls(scale: $scale) }
                }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
        #if os(macOS)
        // Without an explicit size a macOS sheet shrinks to its content's ideal
        // width, which for a scroll-view-backed image is next to nothing: the
        // original ticket came up as a thumbnail in a box barely taller than its own
        // toolbar. A ticket is a portrait document and this is the surface for
        // reading the small print on it, so it opens large.
        .frame(minWidth: 560, idealWidth: 720, minHeight: 560, idealHeight: 860)
        #endif
    }

    /// Whether the stored file is an image we hand to the zoom view, as opposed to a
    /// PDF (which does its own zooming) or a file that has gone missing.
    private var isZoomableImage: Bool {
        guard !TicketStorage.isPDF(attachmentPath),
              let url = TicketStorage.shared.load(relativePath: attachmentPath) else { return false }
        return loadReceiptPlatformImage(url) != nil
    }

    @ViewBuilder
    private var content: some View {
        if let url = TicketStorage.shared.load(relativePath: attachmentPath) {
            if TicketStorage.isPDF(attachmentPath) {
                TicketPDFView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .bottom)
            } else if let image = loadReceiptPlatformImage(url) {
                PinchZoomImageView(image: image, scale: $scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
/// a doc icon for a PDF or a pass, a placeholder when the file is gone. Used by
/// the item editor's ticket section and by every attachment row (#466).
struct TicketAttachmentThumbnail: View {
    let relativePath: String
    /// Tints the icon so a row reads as belonging to the section it was added
    /// from. Defaulted, so the pre-#466 call sites are unchanged.
    var accent: Color = Tokens.accent(for: .itineraries)

    var body: some View {
        Group {
            if let url = TicketStorage.shared.load(relativePath: relativePath) {
                // Checked before the PDF branch: a `.pkpass` is a zip, so it has
                // no page to render and would otherwise fall through to the
                // image branch and draw the grey "missing" placeholder for a
                // file that is present and perfectly valid.
                if TicketStorage.isPass(relativePath) {
                    icon("wallet.pass.fill", tint: accent)
                } else if TicketStorage.isPDF(relativePath) {
                    icon("doc.text.fill", tint: accent)
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
//
// Moved to `Views/Components/PinchZoomImageView.swift` (#395) so note images get
// the same pan-and-zoom rather than a second copy of it. Behaviour here is
// unchanged: the shared view keeps the same scroll-view backing, the same 1x-fit
// default, and the same double-tap toggle, and simply adds an optional
// magnification binding this caller does not use.
