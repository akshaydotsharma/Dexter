import SwiftUI

#if os(macOS)
import AppKit

/// Resigns the key window's first responder, ending any active inline-edit
/// session. Used by section headers / tap zones so clicking away from a
/// persistent `MacAddRow` field ends its edit → commit/dismiss (#287, bug 2).
/// Shared by the Tasks and Lists surfaces so both resign identically.
@MainActor
func macResignFirstResponder() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

/// macOS persistent "add" row, shared by the Tasks ("New Task") and Lists
/// ("New Item") surfaces so both add-rows are one system (#287).
///
/// Unlike the iOS ghost→draft swap, this field is ALWAYS present, so the user's
/// real mouse-down focuses it natively — one click, no programmatic-focus race
/// (that race was #287 bug 1). Focus, text, and commit are driven entirely by
/// the field's own AppKit events (`controlTextDidBeginEditing` /
/// `controlTextDidEndEditing` / `insertNewline`) surfaced through
/// `MacClearTextField.onFocusChange`, so there is no shared programmatic focus
/// state fighting the List.
///
/// - At rest (empty, unfocused): a muted placeholder + an outline `plus.circle`
///   on the checkbox column + the section hairline — visually the same as the
///   `GhostAddRow` it replaces on macOS.
/// - While editing: the bullet becomes an empty stroked circle (like an
///   unchecked task/item) and the field shows the transparent inline editor
///   (`ClearBackgroundTextField` already suppresses the grey field-editor box).
///
/// Commit paths:
/// - Return → create, clear the field, keep focus (chain a new entry).
/// - Blur (click another row / header / empty area, or Escape) → create if
///   non-empty, clear. Escape clears first, so it dismisses without creating.
struct MacAddRow: View {
    /// Row label — "New Task" on Tasks, "New Item" on Lists.
    let label: String
    /// Row height — matches each surface's row rhythm so the add-row aligns
    /// with the rows above it (Tasks: 40, Lists: 44).
    var minHeight: CGFloat = 40
    /// Called with the trimmed, non-empty entry on commit.
    let onCreate: (String) -> Void

    /// Editing-bullet inner diameter. Matches `TaskRowMetrics.circleInner` on
    /// macOS (21pt) so the stroked circle is identical to the Tasks add-row and
    /// a real unchecked row.
    private let circleInner: CGFloat = 21

    @State private var text: String = ""
    // Drives the bullet swap (plus.circle at rest → empty stroked circle while
    // editing). Set from the field's begin/end-editing events via
    // MacClearTextField's onFocusChange callback (AppKit-authoritative), NOT
    // programmatically — so it never forces focus and never races the click.
    @State private var isFocused: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Section hairline — identical construction to GhostAddRow and the
            // Completed separator so the add-row aligns and reads as one system.
            Rectangle()
                .fill(Tokens.border)
                .frame(height: 1)
                .padding(.horizontal, Space.lg)

            HStack(spacing: Space.md) {
                bullet
                    // Fixed 24×24 frame matching GhostAddRow / the real checkbox
                    // column so the bullet x-position never shifts on focus.
                    .frame(width: 24, height: 24)

                MacClearTextField(
                    placeholder: label,
                    text: $text,
                    isFocused: $isFocused,
                    onSubmit: { commit() },
                    onFocusChange: { focused in
                        // Drive the bullet swap off the field's own begin/end
                        // editing events directly. This is AppKit-authoritative
                        // and does not rely on the $isFocused binding round-trip
                        // landing — the earlier code only had the binding path,
                        // and the bullet stayed on `+` after a real click (#287).
                        isFocused = focused
                        if !focused { commit() }
                    },
                    placeholderColor: Tokens.mutedSoft
                )
                .accessibilityLabel(label)

                Spacer(minLength: 0)
            }
            // Leading = Space.lg (hairline/base column) + Space.md (checkbox
            // column) so the bullet lands at the real checkbox x — same as
            // GhostAddRow.
            .padding(.leading, Space.lg + Space.md)
            .padding(.trailing, Space.lg)
            .frame(maxHeight: .infinity)
        }
        .frame(minHeight: minHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var bullet: some View {
        if isFocused {
            // Editing: an empty stroked circle, matching an unchecked row.
            Circle()
                .stroke(Tokens.borderStrong, lineWidth: 2)
                .frame(width: circleInner, height: circleInner)
        } else {
            // At rest: the ghost's outline plus, lightest neutral + light weight.
            Image(systemName: "plus.circle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Tokens.mutedSoft)
        }
    }

    /// Promote the current text to a real entry (if non-empty) and reset the
    /// field. Called on Return (field stays focused to chain) and on blur.
    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onCreate(trimmed) }
        text = ""
    }
}
#endif
