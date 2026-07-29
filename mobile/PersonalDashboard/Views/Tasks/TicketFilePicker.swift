import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit) && !canImport(UIKit)
import AppKit
#endif

/// One file picker for ticket attachments, accepting an image OR a PDF (#399).
///
/// Replaces the original two-entry menu ("Choose a photo" / "Choose a PDF"). The
/// split was a false distinction: a ticket is a file, and whether it arrived as a
/// screenshot or an export is not a choice worth making the person make. The
/// pipeline already branches on the content itself.
///
/// ## Why macOS uses `NSOpenPanel` and not `PhotosPicker` or `.fileImporter`
///
/// `PhotosPicker` on macOS opens the **Photos library**, which on a Mac is
/// usually empty — the ticket is in Downloads or on the Desktop. It also opens as
/// a window sized independently of its presenter, and presented from the task
/// editor's `360x520` popover it ran off the bottom of the screen with its Cancel
/// button behind the Dock, leaving no way out. `.fileImporter` has the same
/// presentation problem from inside a popover, because SwiftUI attaches the sheet
/// to the presenting window.
///
/// `NSOpenPanel.begin` sidesteps both: it is a free-floating, correctly sized
/// panel owned by no window, so nothing can clip it. It is deliberately NOT
/// `runModal()` — a modal run loop starves every main-actor continuation, which
/// would deadlock the async ingest that runs immediately after picking.
struct TicketFilePickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    /// Receives the file bytes and whether they are a PDF. Both nil / false on
    /// cancel or a read failure.
    let onPick: (Data?, Bool) -> Void

    /// Images and PDFs. `UTType.image` covers PNG, JPEG, HEIC and the rest, so a
    /// screenshot and a camera export are both acceptable without listing them.
    static let acceptedTypes: [UTType] = [.image, .pdf]

    #if canImport(UIKit)
    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: Self.acceptedTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return onPick(nil, false) }
                    onPick(Self.readSecurely(from: url), Self.isPDF(url))
                case .failure:
                    onPick(nil, false)
                }
            }
    }
    #else
    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in
                guard presented else { return }
                // Reset immediately: the panel owns its own lifetime from here,
                // so leaving the flag true would block a second attempt.
                isPresented = false
                presentOpenPanel()
            }
    }

    @MainActor
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.acceptedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a ticket image or PDF"
        panel.prompt = "Attach"
        // `begin`, not `runModal`: see the type doc. The completion lands on the
        // main queue, so the caller's `Task { … }` ingest starts cleanly.
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                onPick(nil, false)
                return
            }
            onPick(Self.readSecurely(from: url), Self.isPDF(url))
        }
    }
    #endif

    /// Read a security-scoped URL into memory. iOS gates Files / iCloud reads
    /// behind `startAccessingSecurityScopedResource()`; skipping it returns
    /// "operation not permitted" on physical devices. Harmless on the unsandboxed
    /// Mac build, and correct if that ever changes.
    private static func readSecurely(from url: URL) -> Data? {
        let needsRelease = url.startAccessingSecurityScopedResource()
        defer {
            if needsRelease { url.stopAccessingSecurityScopedResource() }
        }
        return try? Data(contentsOf: url)
    }

    /// Decide PDF vs image from the file's declared type, falling back to the
    /// extension when the type is unavailable. Drives which branch of the ingest
    /// pipeline runs: PDFs are stored verbatim and rasterised for reading, images
    /// are normalised to a compressed JPEG.
    static func isPDF(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.lowercased() == "pdf"
    }
}

extension View {
    /// Present the system file picker for a ticket attachment: Finder on macOS,
    /// Files on iOS. Yields the bytes plus whether they are a PDF.
    func ticketFilePicker(
        isPresented: Binding<Bool>,
        onPick: @escaping (Data?, Bool) -> Void
    ) -> some View {
        modifier(TicketFilePickerModifier(isPresented: isPresented, onPick: onPick))
    }
}
