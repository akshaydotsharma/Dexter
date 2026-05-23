import SwiftUI

/// Rendered next to the dialog in the Shortcuts result sheet after a
/// `CaptureToDashboardIntent` run.
///
/// The dialog above the snippet already names what was added (e.g.
/// *"Added task 'Buy milk' — due May 24"* or *"Logged expense 'Cab'"*),
/// so the snippet stops echoing titles. Its job is to elevate the
/// "Open in Dexter" CTA and, for multi-action captures, give the user a
/// quick visual sense of what types of things were touched.
///
/// Snippet runtime constraints (iOS App Intents):
///   - The view runs outside the main app process. Arbitrary `Button(action:)`
///     closures are ignored — only `Link(destination:)` reliably hands
///     control back to the host app.
///   - The snippet has no knowledge of the Shortcuts host appearance and
///     does NOT reliably inherit it. `Color.primary` and `Material` both
///     resolve unpredictably — they were producing dark text on dark
///     chrome. We instead use the Dexter paper/ink tokens as fixed RGB so
///     the card has its own internal contrast regardless of host theme.
///   - Animations, gestures, and `@Environment` values from the main app
///     are not in scope.
struct CaptureResultSnippetView: View {
    /// Up to N circles shown explicitly in the multi-action row; the rest
    /// collapse into a `+N` chip.
    static let maxVisibleCircles: Int = 4

    let items: [ExecutedDraft]
    /// Where the "Open in Dexter" button points. `nil` hides the entire
    /// card — used for clarification / error / unrecoverable-id cases.
    let deepLink: URL?
    /// Label rendered on the deep-link button. Defaults to "Open in Dexter"
    /// but kept as a parameter to make future variations easy.
    let deepLinkLabel: String

    var body: some View {
        if let url = deepLink {
            card(url: url)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func card(url: URL) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            contextRow
            ctaButton(url: url)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Tokens.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Tokens.border, lineWidth: 1)
        )
    }

    // MARK: - Context row

    /// `EmptyView` for the common single-create case — the dialog already
    /// names the item and a context row would be redundant. Rendered for
    /// multi-action and `items_added` where the icons add information the
    /// dialog can't show visually.
    @ViewBuilder
    private var contextRow: some View {
        if isItemsAddedSingle, let only = items.first {
            HStack(spacing: Space.sm) {
                typeCircle(for: only)
                Text(itemsAddedLabel(for: only))
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if items.count > 1 {
            HStack(spacing: Space.xs) {
                ForEach(Array(visibleCircles.enumerated()), id: \.offset) { _, item in
                    typeCircle(for: item)
                }
                if overflowCount > 0 {
                    Text("+\(overflowCount)")
                        .font(.edFootnote.weight(.semibold))
                        .foregroundStyle(Tokens.muted)
                        .padding(.leading, Space.xxs)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Filled accent circle (20pt) with a white SF Symbol inside. The
    /// per-type icon is the only signal in the multi-action row, so the
    /// symbol choices matter — they have to read at 20pt.
    @ViewBuilder
    private func typeCircle(for item: ExecutedDraft) -> some View {
        ZStack {
            Circle()
                .fill(TypeStyle.tint(for: item.type))
            Image(systemName: TypeStyle.symbol(for: item.type))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.accentFg)
        }
        .frame(width: 20, height: 20)
    }

    // MARK: - CTA

    @ViewBuilder
    private func ctaButton(url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: Space.xs) {
                Text(deepLinkLabel)
                    .font(.edBody.weight(.semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Tokens.accentFg)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
                    .fill(Tokens.ink)
            )
        }
    }

    // MARK: - Derivations

    /// `items_added` capturing N items into a single list/trip is rendered
    /// as a *single* tinted destination circle plus a muted "N items added"
    /// label — not as multiple circles, because the items live as a row
    /// inside one container.
    private var isItemsAddedSingle: Bool {
        items.count == 1 && items[0].action == "items_added"
    }

    private var visibleCircles: [ExecutedDraft] {
        Array(items.prefix(Self.maxVisibleCircles))
    }

    private var overflowCount: Int {
        max(0, items.count - Self.maxVisibleCircles)
    }

    /// "milk, eggs, bread" → "3 items added". Falls back to "Items added"
    /// when the count can't be derived.
    private func itemsAddedLabel(for item: ExecutedDraft) -> String {
        guard let raw = item.addedNames?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return "Items added"
        }
        let count = raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
        if count <= 1 { return "Item added" }
        return "\(count) items added"
    }
}

/// Type-to-style mapping centralised so dialog formatting (in the intent)
/// and the snippet view stay visually in sync.
private enum TypeStyle {
    static func symbol(for type: String) -> String {
        switch type {
        case "todo":           return "checkmark"
        case "note":           return "note.text"
        case "list":           return "list.bullet"
        case "folder":         return "folder.fill"
        case "trip":           return "suitcase.fill"
        case "itinerary_item": return "airplane"
        case "expense":        return "creditcard.fill"
        default:               return "sparkle"
        }
    }

    static func tint(for type: String) -> Color {
        switch type {
        case "todo":           return Tokens.accentTasks
        case "note":           return Tokens.accentNotes
        case "list":           return Tokens.accentLists
        case "folder":         return Tokens.accentNotes
        case "trip",
             "itinerary_item": return Tokens.accentItineraries
        case "expense":        return Tokens.accentFinance
        default:               return Tokens.ink
        }
    }
}

#Preview("Single create (no context row)") {
    CaptureResultSnippetView(
        items: [
            ExecutedDraft(type: "todo", action: "created", id: "x", title: "Buy milk", dueDate: nil, addedNames: nil)
        ],
        deepLink: URL(string: "dexter://focus/tasks/00000000-0000-0000-0000-000000000000"),
        deepLinkLabel: "Open in Dexter"
    )
    .padding()
    .background(Color.black)
}

#Preview("Multi action") {
    CaptureResultSnippetView(
        items: [
            ExecutedDraft(type: "todo", action: "created", id: "a", title: "Call John", dueDate: nil, addedNames: nil),
            ExecutedDraft(type: "note", action: "created", id: "b", title: "Book ideas", dueDate: nil, addedNames: nil),
            ExecutedDraft(type: "list", action: "items_added", id: "c", title: "Groceries", dueDate: nil, addedNames: "milk, eggs"),
            ExecutedDraft(type: "expense", action: "created", id: "d", title: "Cab", dueDate: nil, addedNames: nil),
            ExecutedDraft(type: "todo", action: "created", id: "e", title: "Email Sara", dueDate: nil, addedNames: nil),
            ExecutedDraft(type: "note", action: "created", id: "f", title: "Travel ideas", dueDate: nil, addedNames: nil)
        ],
        deepLink: URL(string: "dexter://activity"),
        deepLinkLabel: "Open in Dexter"
    )
    .padding()
    .background(Color.black)
}

#Preview("Items added to a list") {
    CaptureResultSnippetView(
        items: [
            ExecutedDraft(type: "list", action: "items_added", id: "list-1", title: "Groceries", dueDate: nil, addedNames: "milk, eggs, bread")
        ],
        deepLink: URL(string: "dexter://focus/lists/00000000-0000-0000-0000-000000000000"),
        deepLinkLabel: "Open in Dexter"
    )
    .padding()
    .background(Color.black)
}
