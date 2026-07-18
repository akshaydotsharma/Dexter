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
/// The "AS" profile coin in the macOS window toolbar, echoing the iOS top-bar
/// affordance. A single solid ink round with paper "AS" text — no surrounding
/// oval or button chrome (issue #285). Sized to sit cleanly in the toolbar
/// while reading as a proper account bubble (à la Reminders), not a faint
/// badge.
struct MacProfilePip: View {
    var body: some View {
        Text("AS")
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(Tokens.paper)
            .frame(width: 30, height: 30)
            .background(Tokens.ink, in: Circle())
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
            // Two DISTINCT toolbar items, not one group: a group renders the
            // secondary control and the AS coin inside a single bordered pill,
            // so they read as merged (issue #285). Separate items get macOS's
            // standard inter-item spacing and their own chrome.
            .toolbar {
                ToolbarItem(placement: .primaryAction) { trailing() }
                ToolbarItem(placement: .primaryAction) { MacProfilePip() }
            }
            // Consistent transparent title-bar across every section (issue
            // #285). Some sections lit the toolbar's scrolled-material band (a
            // grey stripe under the traffic lights) while others stayed clear,
            // depending on whether their content scrolled under the title bar.
            // Hiding the window-toolbar background everywhere makes the paper
            // canvas read straight up to the window edge in all sections.
            .toolbarBackground(.hidden, for: .windowToolbar)
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

    // MARK: - Reminders-like row + control polish (issue #285)

    /// Disables the `List`'s built-in row selection on macOS so a click no
    /// longer paints the hard full-bleed grey selection bar. Rows keep their
    /// own tap gestures and buttons; only the system selection chrome goes
    /// away. No-op on iOS, where List rows here are never selection-driven.
    @ViewBuilder
    func macTamedListSelection() -> some View {
        #if os(macOS)
        self.selectionDisabled(true)
        #else
        self
        #endif
    }

    /// Subtle, inset, rounded hover background for a `List` row on macOS — the
    /// soft Reminders-style highlight that replaces the system selection bar
    /// (paired with `macTamedListSelection()`). Owns its own hover state.
    /// No-op on iOS (touch has no hover; the iOS row render path is unchanged).
    @ViewBuilder
    func macRowHover() -> some View {
        #if os(macOS)
        modifier(MacRowHover())
        #else
        self
        #endif
    }

    /// Quiet, rounded background for an in-view header icon button on macOS,
    /// replacing the hard square default-bordered button chrome with a soft
    /// inset surface that lifts on hover (issue #285). Pair with
    /// `macPlainButtonStyle()`. No-op on iOS.
    @ViewBuilder
    func macHeaderIconChrome() -> some View {
        #if os(macOS)
        modifier(MacHeaderIconChrome())
        #else
        self
        #endif
    }

    /// `.buttonStyle(.plain)` on macOS only — strips the default bordered
    /// button chrome from in-view header controls. No-op on iOS so the phone
    /// button rendering is untouched.
    @ViewBuilder
    func macPlainButtonStyle() -> some View {
        #if os(macOS)
        self.buttonStyle(.plain)
        #else
        self
        #endif
    }

    /// `.textFieldStyle(.plain)` on macOS only, so a `TextField` inside a
    /// custom rounded surface doesn't draw its own default bordered box
    /// (the box-in-a-box on the chat input, issue #285). No-op on iOS, where
    /// the field already renders borderless.
    @ViewBuilder
    func plainFieldStyleOnMac() -> some View {
        #if os(macOS)
        self.textFieldStyle(.plain)
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Inset rounded hover highlight for a macOS List row. Sits behind the row
/// content (the row's own leading priority bar / glyphs stay on top) and is
/// inset from the row edges so the highlight reads as a soft rounded pill, the
/// way Reminders renders row hover — not a full-bleed bar.
private struct MacRowHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    // A whisper-subtle tint, not the solid `paper2` surface —
                    // `paper2` reads as a heavy dark box on a row (issue #285).
                    // `ink` at low opacity gives Reminders' barely-there hover:
                    // a faint light wash in dark mode, a faint grey in light.
                    .fill(hovering ? Tokens.ink.opacity(0.06) : Color.clear)
                    .padding(.horizontal, Space.xs)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Quiet rounded chrome for a header icon button on macOS: a soft inset
/// surface with a hairline, lifting to `paper2` on hover. Replaces the hard
/// square default-bordered macOS button background.
private struct MacHeaderIconChrome: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(hovering ? Tokens.paper2 : Tokens.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .stroke(Tokens.border, lineWidth: 0.5)
                    )
                    .padding(Space.xs)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
#endif
