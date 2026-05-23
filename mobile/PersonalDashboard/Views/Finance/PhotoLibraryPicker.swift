import SwiftUI
import PhotosUI

/// `PhotosPicker` wrapper, modelled as a `.photosPicker(isPresented:)`
/// modifier so FinanceView can drive it from a `@State` flag the same way
/// it drives the camera and PDF pickers.
///
/// Loads the selected image as raw `Data` via `loadTransferable(type:)`
/// and hands it to `onPick`. `nil` if the user cancels or the load fails.
///
/// Constrained to one image because the AddExpenseSheet only persists a
/// single receipt path per expense. Multi-receipt is deferred.
struct PhotoLibraryPickerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: (Data?) -> Void

    @State private var selection: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $isPresented,
                selection: $selection,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: selection) { _, newValue in
                guard let item = newValue else { return }
                Task {
                    let data: Data? = (try? await item.loadTransferable(type: Data.self)) ?? nil
                    // Clear so re-selecting the same photo still re-fires
                    // .onChange next time.
                    await MainActor.run {
                        selection = nil
                        onPick(data)
                    }
                }
            }
    }
}

extension View {
    /// Present the system photo picker constrained to a single image. The
    /// closure receives the JPEG/HEIC `Data` or nil on cancel/failure.
    func photoLibraryPicker(
        isPresented: Binding<Bool>,
        onPick: @escaping (Data?) -> Void
    ) -> some View {
        modifier(PhotoLibraryPickerModifier(isPresented: isPresented, onPick: onPick))
    }
}
