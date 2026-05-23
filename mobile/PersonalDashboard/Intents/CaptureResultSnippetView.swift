import SwiftUI

/// Rendered next to the dialog in the Shortcuts result sheet after a
/// `CaptureToDashboardIntent` run. Lists what was applied (icon + title per
/// row, grouped visually by the dialog string above) and offers a single
/// deep-link back into the app.
///
/// Snippet runtime constraints (iOS App Intents):
///   - The view runs outside the main app process. Arbitrary `Button(action:)`
///     closures are ignored — only `Link(destination:)` reliably hands control
///     back to the host app.
///   - Animations, gestures, and `@Environment` values from the main app are
///     not in scope. Stick to static layout (`VStack`, `HStack`, `Text`,
///     `Image(systemName:)`) plus `Link`.
///   - Tokens (colours, spacing, fonts) are reused from the main app design
///     system so the result sheet matches the in-app surfaces.
struct CaptureResultSnippetView: View {
    /// Up to N rows shown explicitly; the rest are summarised as "+N more".
    static let maxVisibleRows: Int = 3

    let items: [ExecutedDraft]
    /// Where the "Open in Dexter" button points. `nil` hides the button —
    /// used for clarification / error cases and for unrecoverable id parses.
    let deepLink: URL?
    /// Label rendered on the deep-link button. Always "Open in Dexter" today,
    /// kept as a parameter to make future variations (e.g. "Open list") easy.
    let deepLinkLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(row.tint)
                            .frame(width: 20, alignment: .center)
                        Text(row.label)
                            .font(.edBody)
                            .foregroundStyle(Tokens.ink)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if overflowCount > 0 {
                    Text("+\(overflowCount) more")
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.muted)
                        .padding(.leading, 20 + Space.sm)
                }
            }

            if let url = deepLink {
                Link(destination: url) {
                    HStack(spacing: Space.xs) {
                        Text(deepLinkLabel)
                            .font(.edFootnote)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Tokens.accentFg)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
                            .fill(Tokens.ink)
                    )
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .fill(Tokens.surface)
        )
        .paperBorder()
    }

    // MARK: - Row derivation

    private var visibleRows: [Row] {
        items.prefix(Self.maxVisibleRows).map(Row.init(executed:))
    }

    private var overflowCount: Int {
        max(0, items.count - Self.maxVisibleRows)
    }

    /// One row in the snippet. The mapping from `ExecutedDraft` to icon /
    /// label is centralised here so the dialog string and the snippet stay
    /// visually consistent.
    fileprivate struct Row {
        let symbol: String
        let tint: Color
        let label: String

        init(executed: ExecutedDraft) {
            self.symbol = Self.symbol(for: executed.type)
            self.tint = Self.tint(for: executed.type)
            self.label = Self.label(for: executed)
        }

        private static func symbol(for type: String) -> String {
            switch type {
            case "todo":           return "checkmark.square"
            case "note":           return "doc.text"
            case "list":           return "list.bullet"
            case "folder":         return "folder"
            case "trip":           return "suitcase"
            case "itinerary_item": return "airplane"
            default:               return "sparkles"
            }
        }

        private static func tint(for type: String) -> Color {
            switch type {
            case "todo":           return Tokens.accentTasks
            case "note":           return Tokens.accentNotes
            case "list":           return Tokens.accentLists
            case "folder":         return Tokens.accentNotes
            case "trip",
                 "itinerary_item": return Tokens.accentItineraries
            default:               return Tokens.ink
            }
        }

        /// Compact label per row. For `items_added` we prefer the names that
        /// were appended over the list/trip title — that's the new information.
        /// Everything else just uses the title.
        private static func label(for executed: ExecutedDraft) -> String {
            if executed.action == "items_added", let names = executed.addedNames, !names.isEmpty {
                if let parent = executed.title, !parent.isEmpty {
                    return "\(names) → \(parent)"
                }
                return names
            }
            let title = executed.title?.trimmingCharacters(in: .whitespaces) ?? ""
            return title.isEmpty ? defaultLabel(for: executed) : title
        }

        private static func defaultLabel(for executed: ExecutedDraft) -> String {
            switch executed.type {
            case "todo":           return "Task"
            case "note":           return "Note"
            case "list":           return "List"
            case "folder":         return "Folder"
            case "trip":           return "Trip"
            case "itinerary_item": return "Itinerary item"
            default:               return "Item"
            }
        }
    }
}

#Preview("Single task") {
    CaptureResultSnippetView(
        items: [
            ExecutedDraft(type: "todo", action: "created", id: "x", title: "Buy milk", dueDate: nil, addedNames: nil)
        ],
        deepLink: URL(string: "dexter://focus/tasks/00000000-0000-0000-0000-000000000000"),
        deepLinkLabel: "Open in Dexter"
    )
    .padding()
    .background(Tokens.paper)
}

#Preview("Multi action") {
    CaptureResultSnippetView(
        items: [
            ExecutedDraft(type: "todo", action: "created", id: "a", title: "Call John", dueDate: nil, addedNames: nil),
            ExecutedDraft(type: "note", action: "created", id: "b", title: "Book ideas", dueDate: nil, addedNames: nil),
            ExecutedDraft(type: "list", action: "items_added", id: "c", title: "Groceries", dueDate: nil, addedNames: "milk, eggs"),
            ExecutedDraft(type: "todo", action: "completed", id: "d", title: "Pay rent", dueDate: nil, addedNames: nil),
            ExecutedDraft(type: "todo", action: "created", id: "e", title: "Email Sara", dueDate: nil, addedNames: nil)
        ],
        deepLink: URL(string: "dexter://activity"),
        deepLinkLabel: "Open in Dexter"
    )
    .padding()
    .background(Tokens.paper)
}
