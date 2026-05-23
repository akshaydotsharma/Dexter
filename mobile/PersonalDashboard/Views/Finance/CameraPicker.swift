import SwiftUI
import UIKit

/// Thin SwiftUI wrapper around `UIImagePickerController(sourceType: .camera)`.
/// Used by the Finance "+" menu's "Scan receipt" path.
///
/// Returns JPEG `Data` via `onCapture(data)`; passes `nil` if the user
/// cancels. The picker is presented as a `.fullScreenCover` from FinanceView
/// because UIKit's camera UI is itself full-screen and doesn't play nicely
/// with sheet detents.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Falls back to .photoLibrary if the device has no camera (simulator).
        // The menu item is hidden when this is the case (see FinanceView).
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera
            : .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        // No reactive state to push down.
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void
        /// One-shot guard. UIImagePickerController is known to deliver the
        /// finish callback twice on some iOS versions when the user taps
        /// "Use Photo" quickly; this stops downstream from firing twice.
        private var fired = false

        init(onCapture: @escaping (Data?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard !fired else { return }
            fired = true
            let image = info[.originalImage] as? UIImage
            // jpegData(0.9) here is "lossy but high quality" — ReceiptStorage
            // will re-encode at 0.8 anyway, so the double-encode is one-time
            // and acceptable.
            let data = image?.jpegData(compressionQuality: 0.9)
            picker.dismiss(animated: true) { [onCapture] in
                onCapture(data)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !fired else { return }
            fired = true
            picker.dismiss(animated: true) { [onCapture] in
                onCapture(nil)
            }
        }
    }
}
