import SwiftUI

#if os(macOS)
import AppKit

/// One line item inside a block (#446).
///
/// The deliberate opposite of `VisionTileRow` at every level of the visual
/// grammar, because the two sit in the same stack and the difference between
/// them is the whole idea. A tile is a bordered `surface2` card with a checkbox,
/// a priority wash and a due date, and it stands for a record that lives in
/// Tasks. A note is a dot, a line of text, and nothing else. It stands for
/// itself.
///
/// So: no fill, no border, no checkbox, 18pt rather than 26pt, and
/// `.edSubheadline` rather than `.edBody`. None of that is decoration. If a note
/// wore any of a tile's chrome the honest question "is this in my task list?"
/// would have to be answered by clicking it.
///
/// Editing state is owned by the CARD, not by this row. A row that owned it
/// would have to be told to stop when another one started, and the card is
/// already the thing that knows a note was just created and should open with a
/// caret in it.
struct VisionNoteRow: View {
    let note: VisionNote
    let isEditing: Bool
    let onBeginEdit: () -> Void
    /// Commit the edited text. Empty text deletes the note — see
    /// `VisionBoardService.setNoteText`.
    let onCommit: (String) -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.sm) {
            bullet
            text
            Spacer(minLength: Space.xs)
            removeButton
        }
        .padding(.horizontal, Space.sm)
        .frame(height: VisionBlockMetrics.noteRow)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete note", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Note. \(note.text)")
    }

    /// A 3pt dot in a 26pt box, so it lands on the same vertical line as the
    /// tile checkboxes above or below it. Notes and tasks are different kinds of
    /// thing, but they are still one list, and a ragged left edge would read as
    /// a layout bug rather than as a distinction.
    private var bullet: some View {
        Circle()
            .fill(Tokens.mutedSoft)
            .frame(width: 3, height: 3)
            .frame(width: 26 - Space.sm, alignment: .center)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var text: some View {
        if isEditing {
            MacClearTextField(
                placeholder: "Note",
                text: $draft,
                isFocused: Binding(get: { focused }, set: { focused = $0 }),
                onSubmit: { onCommit(draft) },
                // Clicking away commits too. A note left in edit because the
                // user's attention moved elsewhere would be lost on the next
                // reload, and losing typed text is never the safer default.
                onFocusChange: { isFocused in if !isFocused { onCommit(draft) } },
                placeholderColor: Tokens.mutedSoft,
                // The display text is `.edSubheadline`. Without this the field
                // would render at the body size and the note would grow 1pt the
                // instant it was clicked.
                pointSize: EdMetrics.subheadlinePointSize
            )
            .onAppear {
                draft = note.text
                focused = true
            }
            .visionPassThrough(cursor: .text)
        } else {
            Text(note.text.isEmpty ? "Note" : note.text)
                .font(.edSubheadline)
                .foregroundStyle(note.text.isEmpty ? Tokens.mutedSoft : Tokens.inkSoft)
                .lineLimit(1)
                .truncationMode(.tail)
                // Single click drops a caret in, the same as the block title and
                // every other rename surface in this app. Never a long press,
                // never a context-menu Rename.
                .onTapGesture(perform: onBeginEdit)
                .visionPassThrough(cursor: .text)
        }
    }

    /// Reserved always, revealed on hover. A note has no home outside this block,
    /// so this button is the only way it can leave — which is exactly why it is
    /// visible chrome and not just a context-menu item.
    private var removeButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Tokens.mutedSoft)
                .frame(width: VisionBlockMetrics.rowActionSlot, height: VisionBlockMetrics.noteRow)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0)
        .help("Delete note")
        .visionPassThrough()
        .accessibilityLabel("Delete note")
    }
}

#endif
