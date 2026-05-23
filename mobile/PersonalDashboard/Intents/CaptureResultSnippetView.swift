import SwiftUI

/// Rendered next to the dialog in the Shortcuts result sheet after a
/// `CaptureToDashboardIntent` run.
///
/// The dialog above the snippet already names what was added (e.g.
/// *"Added task 'Buy milk' — due May 24"* or *"Logged expense 'Cab'"*),
/// so the snippet stops echoing titles. Its job is to offer a quiet
/// "Go to app" hyperlink and, for multi-action captures, give the user
/// a quick visual sense of what types of things were touched.
///
/// Design rationale: an actual button (filled, bordered, or otherwise)
/// reads as a competing CTA next to the system "Done" button that
/// Shortcuts owns at the bottom of the sheet. A plain hyperlink in
/// system blue is a soft secondary affordance — it sits below the
/// dialog without fighting the primary dismissal action.
///
/// Snippet runtime constraints (iOS App Intents):
///   - The view runs outside the main app process. Arbitrary `Button(action:)`
///     closures are ignored — only `Link(destination:)` reliably hands
///     control back to the host app.
///   - The snippet has no knowledge of the Shortcuts host appearance and
///     does NOT reliably inherit it. We pick colors that read on both
///     light and dark chrome (system blue for the link, accent tints
///     for the type circles).
///   - Animations, gestures, and `@Environment` values from the main app
///     are not in scope.
struct CaptureResultSnippetView: View {
    /// Up to N circles shown explicitly in the multi-action row; the rest
    /// collapse into a `+N` chip.
    static let maxVisibleCircles: Int = 4

    let items: [ExecutedDraft]
    /// Where the "Go to app" hyperlink points. `nil` hides the entire
    /// snippet — used for clarification / error / unrecoverable-id cases.
    let deepLink: URL?
    /// Label rendered on the hyperlink. Defaults to "Go to app" but
    /// kept as a parameter to make future variations easy.
    let deepLinkLabel: String

    var body: some View {
        if let url = deepLink {
            VStack(spacing: Space.md) {
                contextRow
                hyperlink(url: url)
            }
            // Centered so the tap target sits in the thumb-reachable
            // middle of the sheet, and so the affordance reads as
            // intentional rather than wedged against the left edge.
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
        } else {
            EmptyView()
        }
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
                    .foregroundStyle(Color.white.opacity(0.7))
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
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(.leading, Space.xxs)
                }
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

    /// Plain hyperlink — no button chrome, no card. Reads as a soft
    /// affordance below the dialog so it doesn't compete visually with
    /// the system Done button at the bottom of the Shortcuts sheet.
    ///
    /// Sized close to the system dialog text so it doesn't disappear
    /// under it, and rendered in white because the Shortcuts result
    /// sheet on iOS 26 always uses a dark frosted host (system blue
    /// reads as too utilitarian against that material).
    @ViewBuilder
    private func hyperlink(url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: Space.xs) {
                Text(deepLinkLabel)
                    .font(.headline)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Color.white)
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
