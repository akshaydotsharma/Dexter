import Foundation

/// Parser + handler for the `dexter://` URL scheme.
///
/// Two routes are supported today:
///   - `dexter://focus/<section>/<uuid>` — push a section onto the router
///     stack and stash an `ActivityFocus` so the destination view scrolls /
///     pulses the matching row.
///   - `dexter://activity` — open the Activity timeline.
///
/// Unknown URLs are logged and ignored — never crash. The Shortcut snippet
/// view is the primary caller, but the scheme is registered globally so
/// any future deep-link source (notifications, share sheet, etc.) routes
/// through the same code path.
enum DexterDeepLink {

    @MainActor
    static func handle(_ url: URL, router: AppRouter) {
        // Accept both authority-style (dexter://focus/...) and path-style
        // URLs. `URLComponents` normalises both via `host` + `path`.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.scheme?.lowercased() == "dexter" else {
            log("ignored — wrong scheme", url: url)
            return
        }

        let host = components.host?.lowercased() ?? ""
        // Path begins with "/", strip it before splitting.
        let pathParts = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        switch host {
        case "activity":
            router.go(to: .activity)

        case "focus":
            // Expected: focus/<section>/<uuid>
            guard pathParts.count >= 2 else {
                log("focus missing components", url: url)
                return
            }
            let sectionRaw = pathParts[0].lowercased()
            let uuidRaw = pathParts[1]
            guard let section = AppSection(rawValue: sectionRaw) else {
                log("unknown section '\(sectionRaw)'", url: url)
                return
            }
            guard let id = UUID(uuidString: uuidRaw) else {
                // No focus to set, but the section itself is still a useful
                // landing — better than dropping the tap on the floor.
                log("invalid uuid; opening section without focus", url: url)
                router.go(to: section)
                return
            }
            router.focus = ActivityFocus(section: section, id: id, isFolder: false)
            router.go(to: section)

        default:
            log("unknown host '\(host)'", url: url)
        }
    }

    private static func log(_ message: String, url: URL) {
        #if DEBUG
        print("[DexterDeepLink] \(message): \(url.absoluteString)")
        #endif
    }
}
