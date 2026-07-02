import Foundation

/// Outcome of a single auto-executed tool call as the chat surface should
/// render it. Carries enough state for one card to handle all four states
/// (created / updated / deleted / failed) without duplicating layout. The
/// `input` snapshot powers chips + item previews; the `outcome` carries the
/// resolved title / id / due date the executor produced.
struct ChatActionResult: Identifiable, Hashable, Sendable {
    let id: UUID
    let actionType: DraftActionType
    /// Raw tool input from the model. Used by the card to render chips
    /// (due, tag) and list-item previews — same shape `ChatDraft` consumed.
    let input: AnthropicJSONValue
    /// Present on success. The executor's resolved view of the change
    /// (title, id, due date, added item names).
    let outcome: DraftActionOutcome?
    /// Present on failure. Human-readable message from
    /// `DraftExecutionError.errorDescription` or `localizedDescription`.
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        actionType: DraftActionType,
        input: AnthropicJSONValue,
        outcome: DraftActionOutcome? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.actionType = actionType
        self.input = input
        self.outcome = outcome
        self.errorMessage = errorMessage
    }

    var isFailure: Bool { errorMessage != nil }

    /// One of `created`, `updated`, `deleted`, or `error`. Drives eyebrow
    /// tone and the bottom-row affordance (open / none / retry-none).
    enum State { case created, updated, deleted, error }

    var state: State {
        if isFailure { return .error }
        guard let outcome else { return .updated }
        switch outcome.action {
        case ActionString.created:
            return .created
        case ActionString.deleted, ActionString.cleared:
            // A bulk clear reads as a removal in the card vocabulary.
            return .deleted
        default:
            // completed / reopened / updated / items_added / item_updated /
            // item_removed all collapse to "updated" for the card vocabulary.
            return .updated
        }
    }
}

// Hashable conformance: AnthropicJSONValue and DraftActionOutcome aren't
// Hashable, but SwiftUI's `ForEach` only needs identity. We use `id` for
// equality and hashing so the card view can diff cleanly across stream
// updates without dragging the entire payload through Hashable.
extension ChatActionResult {
    static func == (lhs: ChatActionResult, rhs: ChatActionResult) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension ChatActionResult {
    // MARK: - View accessors (mirror ChatDraft so the card stays declarative)

    /// Title to render, preferring the executor's resolved title. Falls back
    /// to the input snapshot for delete cases where the executor still has
    /// the row's title from the fetch.
    var title: String? {
        if let t = outcome?.title, !t.isEmpty { return t }
        let dict = input.objectValue ?? [:]
        if let t = dict["title"]?.stringValue, !t.isEmpty, t != "null" { return t }
        if let n = dict["name"]?.stringValue, !n.isEmpty, n != "null" { return n }
        return nil
    }

    /// Body / description / content blob from the input snapshot.
    var bodyPreview: String? {
        let dict = input.objectValue ?? [:]
        for key in ["body", "description", "content"] {
            if let v = dict[key]?.stringValue, !v.isEmpty, v != "null" {
                return v
            }
        }
        return nil
    }

    /// Items array for `draft_list` / `add_to_list` previews.
    var itemTexts: [String]? {
        let dict = input.objectValue ?? [:]
        let raw = dict["items"]?.arrayValue ?? dict["new_items"]?.arrayValue ?? []
        guard !raw.isEmpty else { return nil }
        return raw.compactMap { $0.objectValue?["text"]?.stringValue }
    }

    /// Due date — prefer the executor's resolved date (handles updates that
    /// kept the existing date), fall back to parsing the input string.
    var dueDate: Date? {
        if let d = outcome?.dueDate { return d }
        guard let raw = input.objectValue?["due_at"]?.stringValue,
              !raw.isEmpty, raw != "null" else { return nil }
        return Self.parseISODate(raw)
    }

    /// Tag chip from input.
    var tag: String? {
        guard let t = input.objectValue?["tag"]?.stringValue,
              !t.isEmpty, t != "null" else { return nil }
        return t
    }

    /// Section to deep-link into. Folders live under Notes.
    var deepLinkSection: AppSection? {
        guard let outcome else { return nil }
        switch outcome.type {
        case "todo": return .tasks
        case "note": return .notes
        case "list": return .lists
        case "folder": return .notes
        case "trip", "itinerary_item": return .itineraries
        default: return nil
        }
    }

    /// True when we have a usable id + section to focus a row. Folders +
    /// itinerary items skip the affordance (their destination views don't
    /// support row-level focus yet — tracked as follow-up for #104).
    var supportsDeepLink: Bool {
        guard let outcome, !isFailure, state != .deleted else { return false }
        if outcome.type == "folder" || outcome.type == "itinerary_item" { return false }
        return UUID(uuidString: outcome.id) != nil && deepLinkSection != nil
    }

    private static func parseISODate(_ raw: String) -> Date? {
        if let d = iso8601Fractional.date(from: raw) { return d }
        return iso8601.date(from: raw)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
