#if os(iOS)
import SwiftUI
import PassKit

/// Hands a stored `.pkpass` back to Apple Wallet (#420).
///
/// Attaching a pass to a task stores the archive verbatim, which leaves one loose end:
/// there is nothing to LOOK at. An image or a PDF opens in the original-ticket viewer;
/// a pass is a signed data bundle, so that viewer has nothing to render and would show
/// its "unavailable" state on a file that is perfectly intact.
///
/// The right affordance for a pass is not a viewer at all — it is the system's own
/// Wallet, which draws the issuer's artwork, keeps the barcode bright at the gate and
/// fires the pass's location and time alerts. So the action becomes "Apple Wallet", and
/// this is the sheet behind it.
///
/// iOS-only, and not because of a shim: `PKAddPassesViewController` does not exist on
/// macOS and neither does Wallet, so the Mac hides the action instead. Adding an
/// already-added pass is handled by PassKit itself, which shows it as already present
/// rather than duplicating it.
struct AddPassToAppleWallet: UIViewControllerRepresentable {
    /// The `.pkpass` bytes, exactly as they were stored.
    let data: Data
    let onFinish: () -> Void

    /// `nil` when the bytes are not a pass PassKit will accept — an unsigned or
    /// truncated archive. Callers use this to hide the action rather than present a
    /// sheet that cannot come up.
    static func pass(from data: Data) -> PKPass? {
        try? PKPass(data: data)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard let pass = Self.pass(from: data),
              let controller = PKAddPassesViewController(pass: pass) else {
            // Should not be reachable — the caller checks `pass(from:)` before
            // presenting — but an empty controller beats a crash if it ever is.
            return UIViewController()
        }
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, PKAddPassesViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
            onFinish()
        }
    }
}
#endif
