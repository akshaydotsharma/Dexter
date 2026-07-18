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

    /// Makes a `TextField`'s underlying `NSTextField` background fully
    /// transparent on macOS. `.textFieldStyle(.plain)` drops the border but the
    /// focused field editor still fills `NSColor.textBackgroundColor` (an opaque
    /// white box). A SwiftUI `.background(.clear)` can't reach that fill — it
    /// lives on the AppKit `NSTextField` / its field editor. This walks to the
    /// enclosing `NSTextField` and clears its fill, border, and focus ring so
    /// inline editing blends into the paper row (issue #287). Caret + typed text
    /// are untouched. No-op on iOS. Pair with `plainFieldStyleOnMac()`.
    @ViewBuilder
    func clearTextFieldBackgroundOnMac() -> some View {
        #if os(macOS)
        self.background(ClearTextFieldBackground())
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

/// Transparent-background enforcer for a SwiftUI `TextField` on macOS.
///
/// Installed as a `.background(...)` behind the field, it drops a zero-size
/// `NSView` into the same AppKit subtree as the field's `NSTextField`, then
/// walks up to that `NSTextField` and clears its fill, border, and focus ring.
/// The reconfigure runs on `makeNSView` and every `updateNSView`, so it also
/// re-applies when the field gains focus (SwiftUI re-renders on focus change)
/// and the field editor is swapped in. Scoped, safe, and a no-op away from
/// macOS (the whole type is compiled out on iOS).
private struct ClearTextFieldBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.clearEnclosingTextField(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.clearEnclosingTextField(from: nsView) }
    }

    /// Walk up from our anchor view; at each ancestor search its subtree for the
    /// nearest `NSTextField` and neutralise its background chrome. Stops at the
    /// first field found so we only ever touch the field we're backing.
    private static func clearEnclosingTextField(from anchor: NSView) {
        var ancestor: NSView? = anchor.superview
        while let current = ancestor {
            if let field = firstTextField(in: current) {
                field.drawsBackground = false
                field.backgroundColor = .clear
                field.isBordered = false
                field.isBezeled = false
                field.focusRingType = .none
                if let cell = field.cell as? NSTextFieldCell {
                    cell.drawsBackground = false
                    cell.backgroundColor = .clear
                }
                // When focused, the live field editor draws its own fill — clear
                // that too so the white box doesn't reappear while typing.
                if let editor = field.currentEditor() as? NSTextView {
                    editor.drawsBackground = false
                    editor.backgroundColor = .clear
                }
                return
            }
            ancestor = current.superview
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        for sub in view.subviews {
            if let field = sub as? NSTextField { return field }
            if let found = firstTextField(in: sub) { return found }
        }
        return nil
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
