#if os(macOS)
import SwiftUI

/// Menu bar commands for the macOS app (issue #295).
///
/// Before this, the app declared no `.commands` and no `keyboardShortcut`
/// anywhere, so the menu bar was stock AppKit defaults: no way to change
/// section from the keyboard, and nothing in the menus advertising that the
/// app could do anything at all. That is the largest single "this is not a Mac
/// app" gap in the audit.
///
/// ## Why a focused scene value rather than a shared singleton
///
/// Each window owns its own `AppRouter` (see `MacRootView`), because a
/// `WindowGroup` builds its content once per window while `@State` on the
/// `App` is created once per process. Commands are declared once for the whole
/// scene, so a menu item has to act on **whichever window is focused**, not on
/// some global. `focusedSceneValue` is exactly that: the focused window
/// publishes its router, the menu reads it, and the item disables itself when
/// no window is focused.
///
/// This is the plumbing that per-section ⌘N and ⌘F will hang off later. Adding
/// `keyboardShortcut` directly to in-view buttons instead would be wrong twice
/// over: a shortcut absent from the menu bar is undiscoverable, and two
/// sections claiming the same key conflict silently.
struct AppRouterFocusedValueKey: FocusedValueKey {
    typealias Value = AppRouter
}

extension FocusedValues {
    /// The `AppRouter` belonging to the currently focused window.
    var appRouter: AppRouter? {
        get { self[AppRouterFocusedValueKey.self] }
        set { self[AppRouterFocusedValueKey.self] = newValue }
    }

    /// The on-screen section's "create a new record" action, or nil when the
    /// section owns no record type.
    var newItemAction: NewItemAction? {
        get { self[NewItemActionKey.self] }
        set { self[NewItemActionKey.self] = newValue }
    }
}

/// A section's create action, published so ⌘N can invoke whichever section is
/// on screen (issue #295).
///
/// `title` names the record rather than reusing a generic "New", so the File
/// menu reads "New Task" in Tasks and "New Trip" in Trips. A menu item whose
/// label does not say what it makes is a worse affordance than one that does.
struct NewItemAction {
    /// Menu item title, e.g. "New Task".
    let title: String
    let perform: () -> Void
}

struct NewItemActionKey: FocusedValueKey {
    typealias Value = NewItemAction
}

/// Identity of the main `WindowGroup`, so `openWindow(id:)` can reopen one after
/// the last window is closed. Needed because taking ⌘N for record creation
/// replaces the group that supplied the free New Window item.
enum MacRootWindow {
    static let id = "dexter.main"
}

/// The app's menu bar contributions.
struct DexterCommands: Commands {
    @FocusedValue(\.appRouter) private var router: AppRouter?
    @FocusedValue(\.newItemAction) private var newItem: NewItemAction?
    @Environment(\.openWindow) private var openWindow

    /// Sections offered in the Go menu, in sidebar order. The first nine take
    /// ⌘1 through ⌘9, matching the convention Mail and Finder use for
    /// switching between top-level places.
    private static let sections: [AppSection] = [
        .chat, .today, .tasks, .notes, .lists,
        .itineraries, .finance, .vocabulary, .activity,
        .settings, .helpCenter,
    ]

    var body: some Commands {
        // ⌘N creates the focused section's own record, the way Reminders and
        // Notes behave. Dexter is not a document app, so "new window" is not
        // what a user means by ⌘N here.
        //
        // This REPLACES the `.newItem` group, which is where `WindowGroup` puts
        // its free "New Window" item and its ⌘N. That item is the only way back
        // from an app running with no windows, which is standard macOS behaviour
        // and something two of us hit during this project. So New Window is
        // re-added here on ⇧⌘N rather than being silently dropped: taking a
        // shortcut is fine, removing a recovery path is not.
        CommandGroup(replacing: .newItem) {
            Button(newItem?.title ?? "New") {
                newItem?.perform()
            }
            .keyboardShortcut("n", modifiers: .command)
            // Sections that own no record type publish nothing, so the item
            // disables rather than doing something surprising. Today, Activity,
            // Chat, Settings and Help center are deliberately in this state.
            .disabled(newItem == nil)

            Divider()

            Button("New Window") {
                openWindow(id: MacRootWindow.id)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Go") {
            ForEach(Array(Self.sections.enumerated()), id: \.element) { index, section in
                Button(section.displayName) {
                    router?.go(to: section)
                }
                // ⌘1…⌘9 for the first nine. The remainder stay in the menu
                // without a shortcut rather than spilling into ⌘0 or modifier
                // combinations users would not guess.
                .keyboardShortcut(shortcut(for: index))
                // Disabled when no window is focused, so the menu tells the
                // truth instead of silently doing nothing.
                .disabled(router == nil)
            }
        }
    }

    /// ⌘1 through ⌘9 for the first nine entries, no shortcut beyond that.
    private func shortcut(for index: Int) -> KeyboardShortcut? {
        guard index < 9, let digit = "\(index + 1)".first else { return nil }
        return KeyboardShortcut(KeyEquivalent(digit), modifiers: .command)
    }
}

extension View {
    /// Publishes this window's router so `DexterCommands` can act on the
    /// focused window. No-op on iOS, which has no menu bar.
    func publishRouterToCommands(_ router: AppRouter) -> some View {
        focusedSceneValue(\.appRouter, router)
    }
}
#endif
