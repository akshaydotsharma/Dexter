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
    /// Local `clientUUID` of the row (or folder) to focus.
    let id: UUID
    /// True for a folder deep-link (section is .notes, but the id is a folder).
    let isFolder: Bool

    init(section: AppSection, id: UUID, isFolder: Bool = false) {
        self.section = section
        self.id = id
        self.isFolder = isFolder
    }
}

/// Holds navigation state for the chat-rooted stack and the drawer.
@Observable
@MainActor
final class AppRouter {
    /// Process-wide router so the URL handler (.onOpenURL) and the
    /// notification-tap delegate can route into the same instance the views
    /// observe.
    static let shared = AppRouter()

    var path: [AppSection] = {
        if let raw = ProcessInfo.processInfo.environment["LAUNCH_SECTION"]?.lowercased(),
           let s = AppSection(rawValue: raw),
           s != .chat {
            return [s]
        }
        return []
    }()
    var drawerOpen: Bool = (ProcessInfo.processInfo.environment["LAUNCH_DRAWER"] == "1")

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

    // MARK: - Deeplinks

    /// Handle a `personaldashboard://` URL by navigating to the right surface
    /// and (if a UUID is present) setting `focus` so the destination view can
    /// scroll the row into view.
    ///
    /// Recognised forms:
    ///   personaldashboard://chat
    ///   personaldashboard://tasks[/<uuid>]
    ///   personaldashboard://notes[/<uuid>]    -- uuid may be a folder
    ///   personaldashboard://lists[/<uuid>]
    ///   personaldashboard://activity
    ///   personaldashboard://dashboard
    func handle(url: URL) {
        guard url.scheme == "personaldashboard" else { return }
        guard let host = url.host?.lowercased(), let section = AppSection(rawValue: host) else { return }

        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let uuid = trimmedPath.isEmpty ? nil : UUID(uuidString: trimmedPath)

        if let uuid {
            let isFolder = (section == .notes) && (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "folder" })?.value == "1")
            focus = ActivityFocus(section: section, id: uuid, isFolder: isFolder)
        }
        go(to: section)
    }
}
