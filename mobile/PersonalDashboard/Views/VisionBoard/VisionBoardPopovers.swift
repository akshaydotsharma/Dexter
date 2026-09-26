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

/// Blocks put away with Archive, opened from the board's toolbar (#671).
///
/// Unarchive puts a block back where it was, or in the nearest free slot if
/// that spot has been filled since. Nothing here edits a block: an archived
/// block is out of the way on purpose, and the board is where it gets worked on.
struct VisionArchivedPopover: View {
    let viewModel: VisionBoardViewModel
    let onUnarchive: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Archived blocks").eyebrow()

            if viewModel.archivedBlocks.isEmpty {
                Text("Nothing archived. Archive a block from its menu to put it away here.")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.mutedSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, Space.xs)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        ForEach(viewModel.archivedBlocks) { block in
                            VisionArchivedRow(
                                block: block,
                                progress: progress(for: block)
                            ) {
                                onUnarchive(block.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(Space.md)
        .frame(width: 320)
        .background(Tokens.surface)
    }

    /// Same count the card shows, from the same rows, so a block does not
    /// change its `3/8` on the way back.
    private func progress(for block: VisionBlock) -> String? {
        let rows = viewModel.rows(for: block)
        guard !rows.isEmpty else { return nil }
        return "\(rows.filter(\.completed).count)/\(rows.count)"
    }
}

private struct VisionArchivedRow: View {
    let block: VisionBlock
    let progress: String?
    let onUnarchive: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: block.state.glyph)
                .font(.system(size: 11))
                .foregroundStyle(Tokens.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.title)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Text([block.state.displayName, progress].compactMap { $0 }.joined(separator: " · "))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }
            Spacer(minLength: Space.xs)
            Button("Unarchive", action: onUnarchive)
                .controlSize(.small)
                .help("Put this block back on the board")
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(hovering ? Tokens.surface2 : .clear)
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
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
/// Order comes from `rows(for:)`, the same call the card makes, so the list here
/// cannot disagree with the list you clicked to open it. When the two did their
/// own ordering they were one edit away from drifting, which reads as rows
/// jumping when a popover opens.
struct VisionAllTilesPopover: View {
    let viewModel: VisionBoardViewModel
    let editor: VisionItemEditor
    let block: VisionBlock

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(block.title).eyebrow()

            ScrollView {
                VStack(alignment: .leading, spacing: VisionBlockMetrics.tileSpacing) {
                    ForEach(viewModel.rows(for: block)) { row in
                        rowView(row)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(Space.md)
        .frame(width: 320)
        .background(Tokens.surface)
    }

    /// A deliberate plain function rather than a `@ViewBuilder`.
    ///
    /// Three of `VisionTileRow`'s callbacks are nil for one kind of row and a
    /// closure for the other, and `isTask ? { … } : nil` gives the type checker
    /// nothing to infer the closure's type from. Binding them as typed locals
    /// first needs statements, which a `@ViewBuilder` body will not take.
    private func rowView(_ row: VisionRow) -> some View {
        let isItem = !row.isTask
        var beginEdit: (() -> Void)?
        var commitText: ((String, Bool) -> Void)?
        var cancelEdit: (() -> Void)?
        var removeFromBoard: (() -> Void)?

        if isItem {
            beginEdit = { editor.begin(row.id, in: .popover) }
            commitText = { text, continuing in
                Task {
                    await editor.commit(
                        row.id, in: block.id, text: text,
                        continuing: continuing, surface: .popover
                    )
                }
            }
            cancelEdit = { Task { await editor.cancel(row.id, in: block.id) } }
        } else {
            removeFromBoard = {
                Task { await viewModel.detach(taskID: row.id, from: block.id) }
            }
        }

        return VisionTileRow(
            row: row,
            showsDue: true,
            isEditing: isItem && editor.editingID(in: .popover) == row.id,
            onToggle: { toggle(row) },
            onBeginEdit: beginEdit,
            onCommit: commitText,
            onCancel: cancelEdit,
            onRemoveFromBoard: removeFromBoard,
            onRemove: {
                Task {
                    if row.isTask {
                        await viewModel.deleteTask(row.id, from: block.id)
                    } else {
                        await viewModel.deleteItem(row.id, from: block.id)
                    }
                }
            }
        )
    }

    private func toggle(_ row: VisionRow) {
        Task {
            if row.isTask {
                await viewModel.toggleTask(row.id)
            } else {
                await viewModel.toggleItem(row.id, in: block.id)
            }
        }
    }
}

#endif
