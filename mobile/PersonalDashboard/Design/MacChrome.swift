import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

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
                // Refresh sits in EVERY section rather than only the synced ones
                // (#363). Sync is process-global, so the button does the same
                // thing everywhere, and a control that appears and disappears as
                // you change section is a worse affordance than one that is
                // simply always where you left it. This is also the discoverable
                // half of the pair — ⌘R alone is invisible until you go looking
                // in a menu.
                ToolbarItem(placement: .primaryAction) { MacSyncRefreshButton() }
                ToolbarItem(placement: .primaryAction) { MacProfilePip() }
            }
            // NO `.toolbarBackground(.hidden, for: .windowToolbar)` here.
            //
            // #285 hid it to stop a grey stripe appearing under the traffic
            // lights in some sections and not others. That also switched off
            // the scroll-edge effect, so scrolling content ran straight over
            // the title with nothing behind it — visible in Chat as messages
            // colliding with the word "Chat" (issue #345).
            //
            // The default (`.automatic`) is the behaviour we actually want on
            // Tahoe: clear while the content sits below the title bar, Liquid
            // Glass once content scrolls under it. The #285 "inconsistency" was
            // that effect working correctly — static sections have nothing to
            // scroll under the bar, so they stay clear. Reminders and Notes
            // both read this way.
        #else
        self
        #endif
    }

    /// Native macOS chrome for a pushed DETAIL screen (an open list, trip,
    /// folder, or note), matching Apple Reminders/Notes on Tahoe. Instead of a
    /// hand-rolled in-view header row, the back control and the detail's action
    /// icons live in the native window toolbar, so macOS 26 draws them as a
    /// Liquid Glass group for free — correct glyphs, hover, and grouping. The
    /// window title/subtitle track the open item's name so the title bar no
    /// longer stays stuck on the section name.
    ///
    /// `actions` is a `ToolbarItemGroup`, so several icons read as ONE grouped
    /// glass pill; the AS profile coin sits to its right as its own element
    /// (the same split Reminders uses: a grouped action pill + a separate
    /// control). No-op on iOS, where the in-view detail header owns this chrome
    /// (issue #291).
    @ViewBuilder
    func macDetailChrome<Actions: View>(
        title: String,
        subtitle: String? = nil,
        onBack: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) -> some View {
        #if os(macOS)
        self
            .navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                    }
                    .help("Back")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    actions()
                }
                // Its own item, not inside the group above: the group is the
                // detail's OWN actions (rename, delete, share this note), and
                // refresh belongs to the app, not to the open record. Folding it
                // into that glass pill would read as a fourth thing you can do to
                // this note (#363).
                ToolbarItem(placement: .primaryAction) {
                    MacSyncRefreshButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    MacProfilePip()
                }
            }
            // Left on `.automatic` for the same reason as `macSectionChrome`
            // (issue #345): an open note or list scrolls under this title bar
            // too, and the scroll-edge glass is what keeps the title legible.
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

    /// Tahoe's soft scroll-edge effect on a scroll view, so content passing
    /// under a docked bar dissolves into a progressive blur instead of meeting
    /// a hard edge (issue #345).
    ///
    /// This is the correct tool for "invisible at rest, blurred once content is
    /// underneath". A `.ultraThinMaterial` fill cannot do it: a material is a
    /// uniform translucent slab, so it is equally visible whether or not
    /// anything is behind it, and over the dark paper theme it reads as a
    /// lighter grey panel with a hard top edge.
    ///
    /// The effect is drawn by the SCROLL VIEW over its safe-area inset region,
    /// so it belongs on the scroll view, not on the bar. Below macOS 26 there is
    /// no equivalent and this is a no-op; the caller supplies its own fallback.
    /// No-op on iOS regardless, so the phone rendering is untouched.
    @ViewBuilder
    func macSoftScrollEdge(_ edges: Edge.Set = .bottom) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Dock a custom bar to the bottom edge so the scroll view draws its
    /// scroll-edge effect under it (issue #345).
    ///
    /// `safeAreaInset` and `safeAreaBar` reserve the same space, but only the
    /// bar variant registers its content AS a bar, and the edge effect is drawn
    /// only under bars. With a plain inset, `scrollEdgeEffectStyle` is accepted
    /// and silently does nothing — the exact symptom that made the composer look
    /// like it had no blur at all.
    ///
    /// Falls back to `safeAreaInset` below macOS 26 and on iOS, which is the
    /// pre-existing behaviour, so nothing regresses where the bar API is absent.
    @ViewBuilder
    func macBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            self.safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
        #else
        self.safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        #endif
    }

    /// The chat content width (issue #345).
    ///
    /// iOS keeps the existing behaviour exactly: capped at 640, centred. A phone
    /// is narrower than the cap, so it never binds there anyway.
    ///
    /// macOS fills the detail pane. The 640 cap left roughly half a full-screen
    /// window empty on each side, and Akshay asked twice for that space to be
    /// used, so the reading-measure argument is settled: density wins. Both the
    /// conversation and the input box run to the same edges, separated from the
    /// window only by the standard `Space.lg` gutter their callers apply.
    ///
    /// Deliberately NOT `containerRelativeFrame`: the first attempt used it and
    /// resolved a different container for the scroll content than for the
    /// composer, so the two ended up different widths and the clamp did not bind
    /// where it should have. A plain `maxWidth` inherits whatever the parent
    /// offers, which is the same known-good mechanism the 640 cap always used.
    ///
    /// If long assistant replies ever read too wide, this is where a cap goes
    /// back — one `.frame(maxWidth:)` on the macOS branch, nothing else changes.
    @ViewBuilder
    func chatReadingWidth() -> some View {
        #if os(macOS)
        self.frame(maxWidth: .infinity)
        #else
        self
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity, alignment: .center)
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

    /// Reminders-style chrome for an in-view header icon button on macOS: the
    /// glyph sits on a clear background at rest (no box), and a soft rounded
    /// highlight fades in only on hover (issue #289). Replaces both the hard
    /// square default-bordered button chrome and the earlier resting surface
    /// box. Pair with `macPlainButtonStyle()`. No-op on iOS.
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
/// Row hover behaviour for a macOS List row. The background tint is gone
/// (issue #287) — the row stays flat on hover, matching a cleaner Reminders
/// read. Hovering instead switches the pointer to an I-beam to signal that the
/// title is click-to-edit text. Scoped to task rows only (does not touch
/// `MacHeaderIconChrome`, which keeps its own hover chrome).
private struct MacRowHover: ViewModifier {
    func body(content: Content) -> some View {
        content
            // macOS 14 min deployment target, so use NSCursor push/pop rather
            // than `.pointerStyle` (macOS 15+). Push on enter, pop on exit so
            // the cursor stack stays balanced.
            .onHover { hovering in
                if hovering {
                    NSCursor.iBeam.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

/// Reminders-style chrome for a header icon button on macOS: no resting
/// background (the bare glyph reads as a clean, glassy control), with a soft
/// rounded `paper2` highlight that fades in only on hover. Replaces the earlier
/// resting surface box and the hard square default-bordered macOS button
/// background (issue #289).
private struct MacHeaderIconChrome: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(hovering ? Tokens.paper2 : Color.clear)
                    .padding(Space.xs)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
#endif
