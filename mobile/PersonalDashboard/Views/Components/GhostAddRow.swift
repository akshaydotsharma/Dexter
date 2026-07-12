import SwiftUI

/// A visible "ghost" add-row that replaces an invisible tap zone (#268).
///
/// Uses the app's checkbox grammar: an outline `plus.circle` sitting exactly on
/// the real checkbox column, plus a muted label ("Add task" / "Add item"). It
/// reads as a ghosted version of a row, not a centered button. Shared by the
/// Tasks and Lists surfaces so both feel like one system.
///
/// Divider alignment (#268 revision): the hairline is built with the *same*
/// construction as the "Completed" section separator in TasksView —
/// `Rectangle().fill(Tokens.border).frame(height: 1).padding(.horizontal, Space.lg)`
/// from a zero-inset base. Callers therefore apply `.listRowInsets(EdgeInsets())`
/// (zero) and this view owns all horizontal insets internally, so the divider's
/// leading x lands flush with the Completed separator rather than at the
/// priority-bar column.
///
/// Leading geometry: the divider starts at `Space.lg` (matches the Completed
/// hairline and the priority-bar column); the plus circle starts at
/// `Space.lg + Space.md`, exactly where TaskRow / ItemRow place their checkbox.
struct GhostAddRow: View {
    /// Row label — "New Task" on Tasks, "New Item" on Lists.
    var label: String = "New Task"
    /// Row height — matches each surface's inline-draft row so swapping
    /// ghost → draft doesn't shift layout (Tasks: 40, Lists: 44).
    var minHeight: CGFloat = 40
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                // Section-level hairline, identical construction to the Completed
                // separator so the two read as one system and align on the left.
                Rectangle()
                    .fill(Tokens.border)
                    .frame(height: 1)
                    .padding(.horizontal, Space.lg)

                HStack(spacing: Space.md) {
                    // Outline plus in the same 24×24 frame as the real checkbox,
                    // so it lines up on the checkbox column. Uses the lightest
                    // neutral (mutedSoft) + a light weight + a slightly smaller
                    // glyph so the whole row reads clearly quieter than a real
                    // item — present and tappable, not "disabled".
                    Image(systemName: "plus.circle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Tokens.mutedSoft)
                        .frame(width: 24, height: 24)

                    Text(label)
                        .font(.edBody)
                        .foregroundStyle(Tokens.mutedSoft)

                    Spacer(minLength: 0)
                }
                // Leading = Space.lg (divider/base column) + Space.md (checkbox
                // column) so the circle lands at the real checkbox x (28pt).
                .padding(.leading, Space.lg + Space.md)
                .padding(.trailing, Space.lg)
                .frame(maxHeight: .infinity)
            }
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(GhostRowButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

/// Subtle press feedback for the ghost add-row: a muted surface wash on press,
/// no scale/bounce. Keeps the row feeling tappable without drawing attention.
private struct GhostRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Tokens.surface2 : Color.clear)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
