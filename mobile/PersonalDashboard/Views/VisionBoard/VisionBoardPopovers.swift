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
                            Button {
                                Task {
                                    await viewModel.attach(taskID: todo.id, to: blockID)
                                    onDone()
                                }
                            } label: {
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
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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

/// Every tile in a block, for the `+N more` button at medium.
///
/// A block that is showing three of nine tiles still has to make the other six
/// reachable without resizing it, and a popover is the one affordance that does
/// that without changing the board's layout.
struct VisionAllTilesPopover: View {
    let viewModel: VisionBoardViewModel
    let block: VisionBlock
    let onToggle: (Todo) -> Void

    var body: some View {
        let tiles = viewModel.tiles(for: block)

        VStack(alignment: .leading, spacing: Space.sm) {
            Text(block.title).eyebrow()

            ScrollView {
                VStack(alignment: .leading, spacing: VisionBlockMetrics.tileSpacing) {
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
}

#endif
