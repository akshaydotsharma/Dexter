import SwiftUI
import UniformTypeIdentifiers

/// `.fileImporter` wrapper for PDF receipts. Modelled as a ViewModifier so
/// FinanceView drives it from a `Binding<Bool>` matching the camera and
/// photo-library flags.
///
/// Reads the file with security-scoped resource access (required because
/// the user picks from Files / iCloud Drive, which is outside the app's
/// sandbox). Hands the `Data` and the picked file name to `onPick`; both nil
/// on cancel or read failure. The file name (`url.lastPathComponent`, e.g.
/// "Citi_May2026.pdf") lets callers label the processing banner (#189).
struct PDFPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: (Data?, String?) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        onPick(nil, nil)
                        return
                    }
                    onPick(Self.readSecurely(from: url), url.lastPathComponent)
                case .failure:
                    onPick(nil, nil)
                }
            }
    }

    /// Read a security-scoped URL into memory. iOS gates Files/iCloud reads
    /// behind `startAccessingSecurityScopedResource()`; skipping it returns
    /// "operation not permitted" on physical devices.
    private static func readSecurely(from url: URL) -> Data? {
        let needsRelease = url.startAccessingSecurityScopedResource()
        defer {
            if needsRelease { url.stopAccessingSecurityScopedResource() }
        }
        return try? Data(contentsOf: url)
    }
}

extension View {
    /// Present the system file picker constrained to PDFs. Returns the raw
    /// PDF `Data` plus the picked file name (e.g. "Citi_May2026.pdf"), or both
    /// nil on cancel/failure.
    func pdfPicker(
        isPresented: Binding<Bool>,
        onPick: @escaping (Data?, String?) -> Void
    ) -> some View {
        modifier(PDFPickerModifier(isPresented: isPresented, onPick: onPick))
    }
}
