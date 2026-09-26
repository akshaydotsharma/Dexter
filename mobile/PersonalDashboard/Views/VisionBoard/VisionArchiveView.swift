import SwiftUI

#if os(macOS)

/// The vision board's Archive (#671): every archived block, in full.
///
/// A page, not a popover, because the reason to open it is to read what a block
/// held before deciding to bring it back — and the archive only grows. A popover
/// that lists titles answers neither: it hides the contents and it runs out of
/// room. So each block renders with every row it had, the newest archive first.
///
/// Read-only on purpose. An archived block is put away; the board is where it
/// gets worked on, and Unarchive is one click from here.
struct VisionArchiveView: View {
    let viewModel: VisionBoardViewModel
    let onUnarchive: (UUID) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 320, maximum: 520), spacing: Space.lg, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if viewModel.archivedBlocks.isEmpty {
                    emptyState("Nothing archived yet. Archive a block from its menu on the board to put it away here.")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Space.lg) {
                        ForEach(viewModel.archivedBlocks) { block in
                            VisionArchivedBlockCard(
                                block: block,
                                rows: viewModel.rows(for: block),
                                onUnarchive: { onUnarchive(block.id) },
                                onDelete: { Task { await viewModel.deleteBlock(block.id) } }
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: viewModel.archivedBlocks.map(\.id))
                }
            }
            .padding(Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Tokens.paper)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.edBody)
            .foregroundStyle(Tokens.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xxxl)
    }
}

/// One archived block, drawn with the board's own state edge so it reads as the
/// block it was, with every row visible instead of the three a small card shows.
private struct VisionArchivedBlockCard: View {
    let block: VisionBlock
    let rows: [VisionRow]
    let onUnarchive: () -> Void
    let onDelete: () -> Void

    private var style: VisionBlockStyle { VisionBlockStyle(state: block.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header

            if let intent = block.intent, !intent.isEmpty {
                Text(intent)
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if rows.isEmpty {
                Text("No items")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.mutedSoft)
            } else {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(rows) { row in
                        VisionArchivedRow(row: row)
                    }
                }
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.bodyFill, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(alignment: .top) {
            if style.rail != .absent {
                Rectangle()
                    .fill(style.hue)
                    .frame(height: 3)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: Radius.lg, topTrailingRadius: Radius.lg, style: .continuous
                    ))
            }
        }
        .paperBorder(style.borderColor, radius: Radius.lg)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: block.state.glyph)
                .font(.system(size: 11))
                .foregroundStyle(style.hue)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(block.title)
                    .font(.edHeading)
                    .foregroundStyle(style.titleColor)
                    .lineLimit(2)
                Text(metaLine)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }

            Spacer(minLength: Space.sm)

            Button("Unarchive", action: onUnarchive)
                .controlSize(.small)
                .help("Put this block back on the board")

            Menu {
                Button("Delete block", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More actions for \(block.title)")
        }
    }

    /// `Ongoing · 3/8 · Archived 2 days ago`. The count is the card's own, from
    /// the same rows, so a block does not change its number on the way back.
    private var metaLine: String {
        var parts = [block.state.displayName]
        if !rows.isEmpty {
            parts.append("\(rows.filter(\.completed).count)/\(rows.count)")
        }
        if let archivedAt = block.archivedAt {
            parts.append("Archived \(archivedAt.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

/// A row as it stood when the block was put away. No checkbox to click: the
/// tick is shown, not offered, because nothing here edits the block.
private struct VisionArchivedRow: View {
    let row: VisionRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: row.completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(row.completed ? Tokens.muted : Tokens.mutedSoft)
                .accessibilityHidden(true)
            Text(row.title)
                .font(.edBody)
                .foregroundStyle(row.completed ? Tokens.muted : Tokens.ink)
                .strikethrough(row.completed, color: Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.xs)
            if let due = row.dueDate {
                Text(due.formatted(date: .abbreviated, time: .omitted))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.completed ? "Done" : "Open")
    }
}

#endif
