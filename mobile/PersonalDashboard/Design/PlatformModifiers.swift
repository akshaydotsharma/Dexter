import SwiftUI
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

/// Cross-platform shims for SwiftUI text/navigation modifiers that exist only
/// on iOS. Each applies the real modifier on iOS and is a no-op on macOS, so
/// shared views keep one fluent chain instead of `#if` islands mid-builder.
///
/// Added for the native macOS target (issue #281). As more surfaces are
/// ported, route their iOS-only cosmetic modifiers through here.
extension View {
    /// `.textInputAutocapitalization(.never)` on iOS; no-op on macOS
    /// (the modifier is absent from the macOS SwiftUI surface).
    @ViewBuilder
    func noAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// URL keyboard on iOS; no-op on macOS (hardware keyboard, no keyboard type).
    @ViewBuilder
    func urlKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.URL)
        #else
        self
        #endif
    }

    /// Decimal-pad keyboard on iOS; no-op on macOS (hardware keyboard, no
    /// keyboard type). Used by amount fields in the Finance surface (#281).
    @ViewBuilder
    func decimalKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    /// Inline nav-bar title on iOS; no-op on macOS, where the title renders in
    /// the window titlebar and there is no display-mode concept.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `.listSectionSpacing(_:)` on iOS; no-op on macOS (the modifier is
    /// unavailable there — macOS Lists space sections differently).
    @ViewBuilder
    func listSectionSpacingCompat(_ spacing: CGFloat) -> some View {
        #if os(iOS)
        self.listSectionSpacing(spacing)
        #else
        self
        #endif
    }
}

extension ToolbarItemPlacement {
    /// Trailing "Done"-style toolbar slot: `.topBarTrailing` on iOS (the
    /// navigation-bar trailing position), `.automatic` on macOS where there is
    /// no top bar and `.topBarTrailing` does not exist. iOS placement is
    /// unchanged. Added for the native macOS target (issue #281).
    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }
}

/// Ending a live text edit from outside the field that holds it.
///
/// On macOS a text field commits when it RESIGNS first responder
/// (`controlTextDidEndEditing` → `MacClearTextField.onFocusChange(false)`), and
/// that is the only path that reads the field's own live text — the `text`
/// binding is deliberately synced on submit and blur only, so anything else
/// reporting on the field's behalf reports what the row was seeded with.
///
/// The catch is that clicking a SwiftUI view which cannot take focus (an item
/// row, a label, the block body) does not resign anything. The field keeps the
/// caret, no commit fires, and if the caret is then released in state the field
/// is torn down with the typed text still only in AppKit. That is the defect in
/// #492: *"if I'm editing an item and I click on another item, the change does
/// not get saved."*
///
/// So whoever releases the caret asks for the edit to end first, here, and the
/// field commits itself the way it always has.
enum PlatformFieldEditing {

    /// Resign any live field editor, in whatever window holds it.
    ///
    /// Every window rather than `NSApp.keyWindow`, because a popover is its own
    /// window and is frequently NOT key — the overflow popover edits items too.
    /// A window with no text edit in flight has no `NSText` first responder, so
    /// this is a no-op there rather than a stray focus change.
    static func end() {
        #if canImport(AppKit) && os(macOS)
        for window in NSApplication.shared.windows where window.firstResponder is NSText {
            window.makeFirstResponder(nil)
        }
        #endif
    }
}
