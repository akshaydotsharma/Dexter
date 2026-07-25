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
}

/// The app's menu bar contributions.
struct DexterCommands: Commands {
    @FocusedValue(\.appRouter) private var router: AppRouter?

    /// Sections offered in the Go menu, in sidebar order. The first nine take
    /// ⌘1 through ⌘9, matching the convention Mail and Finder use for
    /// switching between top-level places.
    private static let sections: [AppSection] = [
        .chat, .today, .tasks, .notes, .lists,
        .itineraries, .finance, .vocabulary, .activity,
        .settings, .helpCenter,
    ]

    var body: some Commands {
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
