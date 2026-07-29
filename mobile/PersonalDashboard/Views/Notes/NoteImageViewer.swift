import SwiftUI

/// Full-size view of one inline note image (#395), opened by tapping it in the
/// note's preview mode.
///
/// Takes the relative path rather than a resolved image so it can render the
/// not-on-this-device case itself: a row can outlive its bytes, since sync moves
/// the note but not the picture.
struct NoteImageViewer: View {
    let relativePath: String

    @Environment(\.dismiss) private var dismiss

    private var fileURL: URL? {
        ReceiptStorage.noteImages.load(relativePath: relativePath)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                if let fileURL, let platformImage = PlatformImage(contentsOfFile: fileURL.path) {
                    Image(platformImage: platformImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(Space.md)
                } else {
                    missingState
                }
            }
            .navigationTitle("Image")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    private var missingState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Tokens.mutedSoft)
            Text("This image is on your other device")
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
            Text("Sync moves the note but not its pictures. Bring them across with Export & import.")
                .font(.edFootnote)
                .foregroundStyle(Tokens.mutedSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
        }
    }
}
