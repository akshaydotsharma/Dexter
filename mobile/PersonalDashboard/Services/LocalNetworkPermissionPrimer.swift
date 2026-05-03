import Foundation
import Network

/// Forces iOS to show the "Find devices on local network" permission
/// prompt early in the app lifecycle. Apple's recommended trigger is a
/// brief Bonjour browse — a plain URLSession to a private IP does not
/// reliably surface the prompt across iOS versions.
///
/// Without this, the App Intent (which runs in a background context) tries
/// to reach the LAN-baked dev server, gets denied silently, and surfaces a
/// misleading "A server with the specified hostname could not be found"
/// error to the user.
@MainActor
final class LocalNetworkPermissionPrimer {
    static let shared = LocalNetworkPermissionPrimer()
    private var browser: NWBrowser?
    private var hasPrimed = false

    func prime() {
        guard !hasPrimed else { return }
        hasPrimed = true

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_http._tcp", domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { _ in }
        browser.browseResultsChangedHandler = { _, _ in }
        browser.start(queue: .main)
        self.browser = browser

        // The browse only needs to live long enough for iOS to register the
        // local-network attempt. A few seconds is plenty.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            browser.cancel()
            self.browser = nil
        }
    }
}
