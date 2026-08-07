import SwiftUI

#if os(macOS)

/// Attach an existing task to a block (#446).
///
/// Searches every live task that is not already on the board — not just tasks
/// outside THIS block — because a task may appear in at most one block, so a
/// task already filed elsewhere is not attachable, it is movable, and offering
/// it here would quietly relocate it from a block the user cannot see.
///
/// Hosted in an `NSPopover` via `macAnchoredPopover`, so `@Environment(\.dismiss)`
/// does nothing here and the caller closes it through `onDone`.
struct VisionAttachTaskPopover: View {
    let viewModel: VisionBoardViewModel
    let blockID: UUID
    let onDone: () -> Void

    @State private var query = ""

    var body: some View {
        let matches = viewModel.attachableTasks(matching: query)

        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Attach task").eyebrow()

            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.mutedSoft)
                TextField("Search tasks", text: $query)
                    .textFieldStyle(.plain)
                    .font(.edBody)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.sm)

            if matches.isEmpty {
                Text(query.isEmpty ? "Every task is already on the board." : "No matching task.")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.mutedSoft)
                    .padding(.vertical, Space.xs)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        ForEach(matches.prefix(40)) { todo in
                            VisionAttachRow(todo: todo) {
                                Task {
                                    await viewModel.attach(taskID: todo.id, to: blockID)
                                    onDone()
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(Space.md)
        .frame(width: 300)
        .background(Tokens.surface)
    }
}

/// One attachable task.
///
/// Its own view because a row in a list of things you are about to pick has to
/// say so before you commit: the list read as inert text, so it was not obvious
/// the rows were even selectable (#446 follow-up). A hover fill plus the
/// pointing hand is the smallest pair that reads as "this is a choice".
private struct VisionAttachRow: View {
    let todo: Todo
    let onPick: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: Space.sm) {
                Text(todo.title)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                if let due = todo.dueDate {
                    Text(due.formatted(date: .abbreviated, time: .omitted))
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering ? Tokens.surface2 : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            // `.set()` rather than push/pop: a push whose pop is lost to a view
            // being torn down mid-hover leaves the whole app holding the wrong
            // cursor, with no way back. Same reasoning as the board's canvas.
            (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
}

/// Everything in a block, for the `+N more` button.
///
/// A block showing three of nine rows still has to make the other six reachable
/// without resizing it, and a popover is the one affordance that does that
/// without changing the board's layout.
///
/// Notes as well as tiles, because `+N more` counts both and an overflowed note
/// would otherwise have no route at all — a task at least still exists in Tasks,
/// where a note exists nowhere else. They keep the card's order: notes first,
/// then tiles.
struct VisionAllTilesPopover: View {
    let viewModel: VisionBoardViewModel
    let block: VisionBlock
    let onToggle: (Todo) -> Void

    /// Which note holds a caret. Same ownership as on the card and for the same
    /// reason: one editor at a time, decided in one place.
    @State private var editingNoteID: UUID?

    var body: some View {
        let tiles = viewModel.tiles(for: block)

        VStack(alignment: .leading, spacing: Space.sm) {
            Text(block.title).eyebrow()

            ScrollView {
                VStack(alignment: .leading, spacing: VisionBlockMetrics.tileSpacing) {
                    if !block.notes.isEmpty {
                        VStack(alignment: .leading, spacing: VisionBlockMetrics.noteSpacing) {
                            ForEach(block.notes) { note in
                                VisionNoteRow(
                                    note: note,
                                    isEditing: editingNoteID == note.id,
                                    onBeginEdit: { editingNoteID = note.id },
                                    onCommit: { text in commit(note, to: text) },
                                    onDelete: {
                                        editingNoteID = nil
                                        Task { await viewModel.deleteNote(note.id, from: block.id) }
                                    }
                                )
                            }
                        }
                    }

                    ForEach(tiles) { todo in
                        VisionTileRow(
                            todo: todo,
                            showsDue: true,
                            onToggle: { onToggle(todo) },
                            onRemove: { Task { await viewModel.detach(taskID: todo.id, from: block.id) } },
                            onDelete: { Task { await viewModel.deleteTask(todo.id, from: block.id) } }
                        )
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(Space.md)
        .frame(width: 320)
        .background(Tokens.surface)
    }

    private func commit(_ note: VisionNote, to text: String) {
        editingNoteID = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != note.text else { return }
        Task { await viewModel.setNoteText(note.id, in: block.id, to: trimmed) }
    }
}

#endif
