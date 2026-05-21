import SwiftUI

/// One unified card that handles all four chat action states:
/// created / updated / deleted / failed. Layout mirrors the old draft
/// preview card so created items still show chips + item lines; failed and
/// deleted states reuse the same shell with restrained color/typography
/// shifts so a long chat still scans cleanly.
struct ChatResultCard: View {
    let result: ChatActionResult
    /// Wired by `ChatView` to set `router.focus = ActivityFocus(...)` and
    /// push the destination section. Called only when the bottom-row
    /// affordance is visible (success, non-deleted, has deep link).
    var onOpen: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            eyebrow

            if let title = result.title, !title.isEmpty {
                Text(title)
                    .font(.edBodyMedium)
                    .foregroundStyle(titleColor)
                    .strikethrough(result.state == .deleted, color: Tokens.muted)
            }

            if result.state != .error,
               let body = result.bodyPreview, !body.isEmpty {
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

            if result.state != .error {
                chipRow

                if let items = itemsToPreview, !items.isEmpty {
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
            }

            if result.state == .error, let message = result.errorMessage {
                Text(message)
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            bottomRow
        }
        .padding(Space.lg)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(borderColor, radius: Radius.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Eyebrow

    private var eyebrow: some View {
        HStack(spacing: Space.xs) {
            Text(eyebrowLabel)
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(eyebrowColor)
        }
    }

    /// "<STATE> · <ENTITY>", e.g. "ADDED · TASK". Failed cards include the
    /// entity so the user can scan a long thread and tell which row blew up.
    private var eyebrowLabel: String {
        let entity = entityWord.uppercased()
        switch result.state {
        case .created: return "ADDED · \(entity)"
        case .updated: return "\(updatedVerb.uppercased()) · \(entity)"
        case .deleted: return "REMOVED · \(entity)"
        case .error:   return "FAILED · \(entity)"
        }
    }

    /// "task" / "note" / "list" / "folder" / "item". List-item operations
    /// land on the list itself; surfacing "item" in the eyebrow keeps the
    /// scope tight when the user only nudged one row inside a list.
    private var entityWord: String {
        switch result.actionType {
        case .createTodo, .updateTodo, .completeTodo, .deleteTodo:
            return "task"
        case .createNote, .updateNote, .deleteNote:
            return "note"
        case .createList, .updateList, .deleteList:
            return "list"
        case .addToList:
            return "list"
        case .updateListItem, .removeListItem:
            return "item"
        case .updateFolder, .deleteFolder:
            return "folder"
        case .createTrip, .updateTrip, .deleteTrip:
            return "trip"
        case .addItineraryItems:
            return "trip"
        case .updateItineraryItem, .deleteItineraryItem:
            return "item"
        case .unknown:
            return "action"
        }
    }

    /// Differentiates `complete_task` from a generic update so the user sees
    /// "completed" or "reopened" instead of a flat "updated".
    private var updatedVerb: String {
        guard let action = result.outcome?.action else { return "updated" }
        switch action {
        case ActionString.completed:   return "completed"
        case ActionString.reopened:    return "reopened"
        case ActionString.itemsAdded:  return "added to"
        case ActionString.itemUpdated: return "updated"
        case ActionString.itemRemoved: return "removed from"
        default:                       return "updated"
        }
    }

    // MARK: - Chips

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

    private struct ResultChip {
        let text: String
        let icon: String?
        let warning: Bool
    }

    private func makeChips() -> [ResultChip] {
        var chips: [ResultChip] = []
        if let due = result.dueDate {
            let isWarning = due.timeIntervalSinceNow < 24 * 3600 && due.timeIntervalSinceNow > 0
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, h:mm a"
            chips.append(ResultChip(text: formatter.string(from: due), icon: "calendar", warning: isWarning))
        }
        if let tag = result.tag {
            chips.append(ResultChip(text: tag, icon: "tag", warning: false))
        }
        return chips
    }

    /// For `add_to_list` we want to show only the newly added items rather
    /// than the input "new_items" array fall-through. `result.itemTexts`
    /// already pulls from `new_items` first, so reuse it directly.
    private var itemsToPreview: [String]? {
        result.itemTexts
    }

    // MARK: - Bottom row

    @ViewBuilder
    private var bottomRow: some View {
        switch result.state {
        case .created, .updated:
            if result.supportsDeepLink, let onOpen {
                HStack {
                    Spacer(minLength: 0)
                    Button(action: onOpen) {
                        HStack(spacing: 4) {
                            Text("Go to \(entityWord)")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .regular))
                        }
                    }
                    .buttonStyle(EdButtonStyle(kind: .ghost, size: .sm))
                }
            }
        case .deleted:
            HStack(spacing: Space.xs) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Tokens.muted)
                Text("Removed")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                Spacer(minLength: 0)
            }
        case .error:
            EmptyView()
        }
    }

    // MARK: - State-driven styling

    /// Eyebrow color carries the state: muted for routine create/update/
    /// delete (no green-banner celebration), warning for failures. Stays
    /// inside the existing token vocabulary.
    private var eyebrowColor: Color {
        switch result.state {
        case .created, .updated: return Tokens.muted
        case .deleted:           return Tokens.muted
        case .error:             return Tokens.warning
        }
    }

    private var titleColor: Color {
        switch result.state {
        case .deleted: return Tokens.muted
        case .error:   return Tokens.ink
        default:       return Tokens.ink
        }
    }

    private var cardBackground: Color {
        // Surface for active states keeps the card lifted off the paper;
        // paper2 for deleted recedes it into the background; warningSoft
        // tint for errors reads as "needs attention" without shouting.
        switch result.state {
        case .deleted: return Tokens.paper2
        case .error:   return Tokens.warningSoft
        default:       return Tokens.surface
        }
    }

    private var borderColor: Color {
        switch result.state {
        case .error: return Tokens.warning.opacity(0.4)
        default:     return Tokens.border
        }
    }
}
