import SwiftUI
import UniformTypeIdentifiers

/// `.fileImporter` wrapper for PDF receipts. Modelled as a ViewModifier so
/// FinanceView drives it from a `Binding<Bool>` matching the camera and
/// photo-library flags.
///
/// Reads the file with security-scoped resource access (required because
/// the user picks from Files / iCloud Drive, which is outside the app's
/// sandbox). Hands `Data` to `onPick`; nil on cancel or read failure.
struct PDFPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: (Data?) -> Void

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
                        onPick(nil)
                        return
                    }
                    onPick(Self.readSecurely(from: url))
                case .failure:
                    onPick(nil)
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
    /// PDF `Data` or nil on cancel/failure.
    func pdfPicker(
        isPresented: Binding<Bool>,
        onPick: @escaping (Data?) -> Void
    ) -> some View {
        modifier(PDFPickerModifier(isPresented: isPresented, onPick: onPick))
    }
}
