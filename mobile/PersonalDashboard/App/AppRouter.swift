import SwiftUI
import Observation

/// Holds navigation state for the chat-rooted stack and the drawer.
@Observable
@MainActor
final class AppRouter {
    var path: [AppSection] = {
        if let raw = ProcessInfo.processInfo.environment["LAUNCH_SECTION"]?.lowercased(),
           let s = AppSection(rawValue: raw),
           s != .chat {
            return [s]
        }
        return []
    }()
    var drawerOpen: Bool = (ProcessInfo.processInfo.environment["LAUNCH_DRAWER"] == "1")

    /// Push a section into the chat-rooted stack and close the drawer.
    func go(to section: AppSection) {
        // Chat is the root, so an explicit chat tap means "pop to root".
        if section == .chat {
            path.removeAll()
        } else {
            // Replace the stack so we don't pile up sibling sections.
            path = [section]
        }
        // Close the drawer with a small delay so the navigation isn't jarring.
        withAnimation(.easeOut(duration: 0.2)) {
            drawerOpen = false
        }
    }

    /// Pop everything back to the chat root.
    func popToChat() {
        path.removeAll()
    }

    /// The currently active section (top of the stack, or chat when empty).
    var currentSection: AppSection { path.last ?? .chat }
}
