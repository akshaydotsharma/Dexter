import SwiftUI

/// Full-size view of one inline note image (#395), opened by tapping it in the
/// note's preview mode.
///
/// Takes the relative path rather than a resolved image so it can render the
/// not-on-this-device case itself: a row can outlive its bytes. Since #471 the
/// picture follows the note, so that case is usually transient — the viewer says
/// which of the two it is looking at.
///
/// Zoomable, because a fitted photo is often too small to read — a whiteboard
/// shot or a scanned page is the whole reason the image is in the note. Pinch and
/// double-tap work, and the explicit controls exist because a trackpad pinch is
/// the only gesture route on macOS and a mouse has none.
struct NoteImageViewer: View {
    let relativePath: String

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = PinchZoomImageView.minScale

    private var fileURL: URL? {
        ReceiptStorage.noteImages.load(relativePath: relativePath)
    }

    /// A peer has published these bytes and they have not landed here yet (#471),
    /// so the empty state is a wait rather than a dead end.
    private var isArriving: Bool {
        SyncAssetInbox.shared.isArriving(relativePath)
    }

    var body: some View {
        // The app's own header rather than a `NavigationStack` toolbar: on macOS
        // that renders as a grey system band plus an accent-blue button bar, which
        // reads as a different app bolted onto this one.
        VStack(spacing: 0) {
            header
            Rectangle().fill(Tokens.divider).frame(height: 0.5)

            ZStack {
                Tokens.paper
                if let fileURL, let platformImage = PlatformImage(contentsOfFile: fileURL.path) {
                    PinchZoomImageView(image: platformImage, scale: $scale)
                } else {
                    missingState
                }
            }
        }
        .background(Tokens.paper)
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 520)
        #endif
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Text("Image")
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)

            Spacer(minLength: Space.md)

            if fileURL != nil {
                ZoomControls(scale: $scale)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(EdIconButtonStyle())
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
    }

    private var missingState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Tokens.mutedSoft)
            Text(SyncAssetMessage.missing("Image", isArriving: isArriving))
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
            Text(isArriving
                 ? "Sync is bringing the picture across. It appears here once it lands."
                 : "No other device has published this picture. Bring it across with Export & import.")
                .font(.edFootnote)
                .foregroundStyle(Tokens.mutedSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
        }
    }
}
