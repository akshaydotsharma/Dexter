import SwiftUI

extension DraftActionType {
    var eyebrowLabel: String {
        switch self {
        case .createTodo:     return "NEW TASK"
        case .updateTodo:     return "UPDATE TASK"
        case .completeTodo:   return "COMPLETE TASK"
        case .deleteTodo:     return "DELETE TASK"
        case .createNote:     return "NEW NOTE"
        case .updateNote:     return "UPDATE NOTE"
        case .deleteNote:     return "DELETE NOTE"
        case .createList:     return "NEW LIST"
        case .updateList:     return "UPDATE LIST"
        case .addToList:      return "ADD ITEMS"
        case .updateListItem: return "UPDATE ITEM"
        case .removeListItem: return "REMOVE ITEM"
        case .deleteList:     return "DELETE LIST"
        case .updateFolder:   return "UPDATE FOLDER"
        case .deleteFolder:   return "DELETE FOLDER"
        case .unknown:        return "ACTION"
        }
    }
}

struct DraftPreviewCard: View {
    let draft: ChatDraft
    var resolved: Resolution? = nil
    var onConfirm: () -> Void
    var onEdit: (() -> Void)? = nil
    var onCancel: () -> Void

    enum Resolution { case confirmed, cancelled }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text(draft.actionType.eyebrowLabel)
                .eyebrow()

            if let title = draft.title, !title.isEmpty {
                Text(title)
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
            } else if !draft.preview.isEmpty {
                Text(draft.preview)
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
            }

            if let body = draft.bodyPreview, !body.isEmpty {
                // Body previews can contain the same markdown the AI emits in
                // chat (lists, bold, etc.). Render through MarkdownView with
                // a small line-limit so the card stays preview-sized.
                MarkdownView(
                    text: body,
                    lineLimit: 4,
                    bodyFont: .edSubheadline,
                    bodyColor: Tokens.inkSoft
                )
            }

            // Chips
            chipRow

            // List items preview
            if let items = draft.itemTexts, !items.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { _, text in
                        HStack(spacing: 6) {
                            Image(systemName: "circle")
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(Tokens.muted)
                            Text(text)
                                .font(.edCaption)
                                .foregroundStyle(Tokens.inkSoft)
                        }
                    }
                    if items.count > 5 {
                        Text("+ \(items.count - 5) more")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                    }
                }
            }

            // Buttons row
            if let resolved {
                HStack(spacing: Space.sm) {
                    Image(systemName: resolved == .confirmed ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(resolved == .confirmed ? Tokens.success : Tokens.muted)
                    Text(resolved == .confirmed ? "Confirmed" : "Cancelled")
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.muted)
                }
            } else {
                HStack(spacing: Space.sm) {
                    Button {
                        onConfirm()
                    } label: {
                        Label("Confirm", systemImage: "checkmark")
                    }
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))

                    if let onEdit {
                        Button {
                            onEdit()
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                    }

                    Button {
                        onCancel()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                }
            }
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var chipRow: some View {
        let chips = makeChips()
        if !chips.isEmpty {
            HStack(spacing: Space.sm) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    HStack(spacing: 4) {
                        if let icon = chip.icon {
                            Image(systemName: icon)
                                .font(.system(size: 11, weight: .regular))
                        }
                        Text(chip.text)
                    }
                    .font(.edCaption)
                    .foregroundStyle(chip.warning ? Tokens.warning : Tokens.muted)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(
                        chip.warning ? Tokens.warningSoft : Tokens.paper2,
                        in: Capsule(style: .continuous)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Tokens.border, lineWidth: 0.5)
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }

    private struct DraftChip {
        let text: String
        let icon: String?
        let warning: Bool
    }

    private func makeChips() -> [DraftChip] {
        var chips: [DraftChip] = []
        if let due = draft.dueDate {
            let isWarning = due.timeIntervalSinceNow < 24 * 3600 && due.timeIntervalSinceNow > 0
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, h:mm a"
            chips.append(DraftChip(text: formatter.string(from: due), icon: "calendar", warning: isWarning))
        }
        if let tag = draft.tag {
            chips.append(DraftChip(text: tag, icon: "tag", warning: false))
        }
        return chips
    }
}
