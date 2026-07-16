import SwiftUI

/// Native macOS window chrome, shared across every ported section view
/// (issue #283).
///
/// The iOS build renders an in-view `TopBar` (hamburger + title + AS pip)
/// because the phone shell is a chat-rooted `ZStack` router with a floating
/// tab bar and an edge-swipe drawer — the title and profile affordance have
/// nowhere else to live. On macOS the shell is a `NavigationSplitView`: the
/// sidebar is always present, so the hamburger is meaningless and the title +
/// profile belong in the native window toolbar, not stacked inside the content.
///
/// These helpers keep the port DRY. Each section view drops its `TopBar`
/// behind `#if os(iOS)` and applies `.macSectionChrome(_:)`, which is a no-op
/// on iOS and installs the native title + toolbar on macOS. iOS rendering is
/// unchanged.

#if os(macOS)
/// The "AS" profile coin, lifted verbatim from `TopBar` so the macOS toolbar
/// carries the same affordance the iOS top bar does. A paper coin, not a
/// colored badge. Sized a touch smaller than the iOS pip to sit cleanly in
/// the ~28pt window toolbar.
struct MacProfilePip: View {
    var body: some View {
        Text("AS")
            .font(.edFootnote)
            .foregroundStyle(Tokens.ink)
            .frame(width: 24, height: 24)
            .background(Tokens.paper2, in: Circle())
            .overlay(Circle().stroke(Tokens.border, lineWidth: 0.5))
            .accessibilityLabel("Akshay")
    }
}
#endif

extension View {
    /// Native macOS section chrome: sets the window title and pins the AS
    /// profile pip to the toolbar's primary-action slot. No-op on iOS, where
    /// the in-view `TopBar` owns the title + pip (issue #283).
    @ViewBuilder
    func macSectionChrome(_ title: String) -> some View {
        macSectionChrome(title) { EmptyView() }
    }

    /// Variant that also injects a secondary trailing toolbar control (e.g.
    /// the Notes folder-add button) ahead of the profile pip. On iOS the
    /// `trailing` content is discarded — its iOS home is the in-view chrome —
    /// so iOS rendering is unchanged (issue #283).
    @ViewBuilder
    func macSectionChrome<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        #if os(macOS)
        self
            .navigationTitle(title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    trailing()
                    MacProfilePip()
                }
            }
        #else
        self
        #endif
    }

    /// Background fill for a section canvas. On iOS ignores every safe-area
    /// edge (full-bleed under the status bar / home indicator). On macOS keeps
    /// the top title-bar inset so the split view reserves the title-bar region
    /// and the sidebar keeps its top inset — ignoring the top there collapses
    /// the inset and slides content under the traffic lights (issue #283). The
    /// bottom edge is still released so the paper reaches the window edge.
    @ViewBuilder
    func canvasIgnoresSafeArea() -> some View {
        #if os(macOS)
        self.ignoresSafeArea(.container, edges: .bottom)
        #else
        self.ignoresSafeArea()
        #endif
    }
}
