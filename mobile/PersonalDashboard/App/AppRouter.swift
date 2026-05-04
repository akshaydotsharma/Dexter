import SwiftUI
import Observation

/// Activity timeline deep-link payload. The Activity surface sets this when
/// the user taps a row, then pushes the destination section. The destination
/// view consumes the focus on appearance: scrolls the matching item into
/// view, plays the 600ms accent pulse, then clears the field. Folder
/// deep-links re-use the `id` slot for the folder identifier; section
/// disambiguates the meaning.
struct ActivityFocus: Equatable {
    /// Where the focus should land. Determines which destination view reads it.
    let section: AppSection
    /// Server-side integer id of the row (or folder) to focus.
    let id: Int
    /// True for a folder deep-link (section is .notes, but the id is a folder).
    let isFolder: Bool

    init(section: AppSection, id: Int, isFolder: Bool = false) {
        self.section = section
        self.id = id
        self.isFolder = isFolder
    }
}

/// Holds navigation state for the chat-rooted stack and the drawer.
@Observable
@MainActor
final class AppRouter {
    var path: [AppSection] = {
        if let raw = ProcessInfo.processInfo.environment["LAUNCH_SECTION"]?.lowercased(),
           let s = AppSection(rawValue: raw),
           s != .chat {
            // Dashboard is hidden (issue #30). Redirect any deep-link that
            // targets it to Activity, the closest replacement surface.
            if s == .dashboard { return [.activity] }
            return [s]
        }
        return []
    }()
    var drawerOpen: Bool = (ProcessInfo.processInfo.environment["LAUNCH_DRAWER"] == "1")

    /// Live drag delta for the drawer, in points. Positive while the user is
    /// pulling the drawer open from the left edge; negative while pulling it
    /// closed. Reset to 0 once the gesture ends and the drawer snaps to its
    /// final state. SideDrawer reads this to render the panel mid-drag so it
    /// follows the finger.
    var drawerDragOffset: CGFloat = 0

    /// Pending Activity timeline deep-link target. The destination view reads
    /// this on `task` / `onAppear`, applies the scroll + pulse, then sets it
    /// back to nil so it doesn't fire again on the next appearance.
    var focus: ActivityFocus?

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
