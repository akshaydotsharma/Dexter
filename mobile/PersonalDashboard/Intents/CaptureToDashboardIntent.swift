import AppIntents
import Foundation
import SwiftUI

/// Adds a task / note / list to the personal dashboard from a free-text or
/// dictated phrase, without opening the app.
///
/// Wired into Shortcuts so the iPhone Action Button (or back-tap / Lock
/// Screen / Siri) can trigger:
///   Dictate Text -> CaptureToDashboard(input: $dictation) -> Show Notification
///
/// The on-device pipeline applies tool calls directly to SwiftData and
/// reports outcomes:
///   - executed actions -> dialog summarises what was applied, snippet view
///     lists each item with an icon and a deep-link back into the app.
///   - LLM follow-up question -> dialog surfaces the question, nothing
///     persisted, no snippet.
///   - failure -> dialog surfaces a brief error, no snippet.
struct CaptureToDashboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture to Dexter"
    static var description = IntentDescription(
        "Add a task, note, or list to Dexter from text or voice. Runs on-device against your local data, no server hop."
    )

    /// Stay backgrounded so the side button feels instant and the user
    /// doesn't lose their current context. Action Button + Shortcut +
    /// Show Notification is the intended runtime path. The result snippet
    /// renders inline in the Shortcuts sheet; the "Open in Dexter" Link
    /// inside it is the only way the user jumps into the app.
    static var openAppWhenRun: Bool = false

    /// The free-text phrase to capture. When invoked from a Shortcut with
    /// a Dictate Text step bound here, iOS skips the prompt and uses the
    /// dictated string. When run standalone from the Shortcuts app, iOS
    /// prompts the user with the keyboard.
    @Parameter(
        title: "Capture",
        description: "What you want to add — for example 'remind me to call John tomorrow at 3' or 'note: book ideas — Lisbon, Tokyo'.",
        requestValueDialog: "What do you want to capture?"
    )
    var input: String

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$input) to Dexter")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Nothing to capture.")
        }

        let service = CaptureService()
        let response: CaptureResponse
        do {
            response = try await service.capture(input: trimmed)
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: "Couldn't capture — \(error.localizedDescription)"))
        }

        switch response.status {
        case .executed:
            let items = response.executed ?? []
            let summary = Self.executedDialog(for: items)
            let openIntent = Self.openIntent(for: items)
            return .result(
                dialog: IntentDialog(stringLiteral: summary),
                view: CaptureResultSnippetView(
                    items: items,
                    openIntent: openIntent,
                    actionLabel: "Go to app"
                )
            )
        case .needsClarification:
            let q = response.followUpQuestion ?? "I need a bit more detail."
            return .result(dialog: IntentDialog(stringLiteral: q))
        case .error:
            let first = response.errors?.first?.message ?? "something went wrong"
            return .result(dialog: IntentDialog(stringLiteral: "Couldn't capture — \(first)"))
        }
    }

    // MARK: - Dialog formatting

    /// Build the dialog string from the list of applied actions.
    ///
    /// - Single action keeps the focused sentence (e.g. *Added task "Buy milk" — due May 24*).
    /// - Multi-action lists items by title, grouped by action verb, up to
    ///   `multiActionVisibleLimit`. Anything beyond that collapses to
    ///   "and N more" so the dialog stays one or two lines.
    /// - Empty / malformed inputs fall back to "Done." so the dialog never
    ///   reads blank.
    static func executedDialog(for items: [ExecutedDraft]) -> String {
        guard !items.isEmpty else { return "Done." }
        if items.count == 1 {
            return sentence(for: items[0])
        }
        return multiActionSentence(for: items)
    }

    /// Soft cap on titles named in the multi-action dialog. The snippet view
    /// renders the full list visually; the dialog stays terse so it reads
    /// well when Shortcuts speaks it (Siri, AirPods announcement).
    private static let multiActionVisibleLimit: Int = 3

    private static func multiActionSentence(for items: [ExecutedDraft]) -> String {
        // Bucket items by the verb we'd use in the dialog. Order matters —
        // "Added X" reads first, then "Updated Y", then "Deleted Z".
        var added: [String] = []
        var updated: [String] = []
        var deleted: [String] = []

        for item in items {
            guard let phrase = phrase(for: item) else { continue }
            switch verbBucket(for: item.action) {
            case .added:   added.append(phrase)
            case .updated: updated.append(phrase)
            case .deleted: deleted.append(phrase)
            }
        }

        var clauses: [String] = []
        if let clause = clause(verb: "Added", titles: added) { clauses.append(clause) }
        if let clause = clause(verb: "Updated", titles: updated) { clauses.append(clause) }
        if let clause = clause(verb: "Deleted", titles: deleted) { clauses.append(clause) }

        guard !clauses.isEmpty else {
            // No phrases survived — fall back to the legacy tally so the
            // user still gets a count even if titles were all empty.
            return legacyTally(for: items)
        }
        return clauses.joined(separator: ". ") + "."
    }

    private enum VerbBucket { case added, updated, deleted }

    private static func verbBucket(for action: String) -> VerbBucket {
        switch action {
        case "created", "items_added":
            return .added
        case "deleted":
            return .deleted
        default:
            // updated, completed, reopened, item_updated, item_removed, ...
            return .updated
        }
    }

    /// Short noun phrase used inside the dialog (e.g. *"Buy milk"*,
    /// *milk, eggs to "Groceries"*). `nil` if the item has no usable title.
    private static func phrase(for item: ExecutedDraft) -> String? {
        if item.action == "items_added", let names = item.addedNames, !names.isEmpty {
            if let parent = item.title, !parent.isEmpty {
                return "\(names) to \"\(parent)\""
            }
            return names
        }
        guard let title = item.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            return nil
        }
        return "\"\(title)\""
    }

    private static func clause(verb: String, titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        let visible = Array(titles.prefix(multiActionVisibleLimit))
        let overflow = titles.count - visible.count
        var joined: String
        switch visible.count {
        case 1:
            joined = visible[0]
        case 2:
            joined = "\(visible[0]) and \(visible[1])"
        default:
            // Oxford comma joins for 3+ items so it reads cleanly when spoken.
            let head = visible.dropLast().joined(separator: ", ")
            joined = "\(head), and \(visible.last!)"
        }
        if overflow > 0 {
            joined += " and \(overflow) more"
        }
        return "\(verb) \(joined)"
    }

    /// Fallback when every item lacked a usable title.
    private static func legacyTally(for items: [ExecutedDraft]) -> String {
        let creates = items.filter { verbBucket(for: $0.action) == .added }.count
        let updates = items.filter { verbBucket(for: $0.action) == .updated }.count
        let deletes = items.filter { verbBucket(for: $0.action) == .deleted }.count
        var parts: [String] = []
        if creates > 0 { parts.append("\(creates) added") }
        if updates > 0 { parts.append("\(updates) updated") }
        if deletes > 0 { parts.append("\(deletes) deleted") }
        return parts.isEmpty ? "Done." : "Done — " + parts.joined(separator: ", ") + "."
    }

    private static func sentence(for item: ExecutedDraft) -> String {
        let typeLabel = label(for: item.type)
        let title = item.title ?? ""
        let titleClause = title.isEmpty ? "" : " \"\(title)\""

        switch (item.type, item.action) {
        case ("todo", "created"):
            if let due = item.dueDate {
                return "Added task\(titleClause) — due \(dueFormatter.string(from: due))."
            }
            return "Added task\(titleClause)."
        case ("note", "created"):
            return "Added note\(titleClause)."
        case ("list", "created"):
            return "Added list\(titleClause)."
        case ("folder", "created"):
            return "Added folder\(titleClause)."
        case ("expense", "created"):
            return "Logged expense\(titleClause)."

        case ("todo", "completed"):
            return "Marked task\(titleClause) complete."
        case ("todo", "reopened"):
            return "Reopened task\(titleClause)."
        case (_, "updated"):
            return "Updated \(typeLabel)\(titleClause)."
        case ("list", "items_added"):
            let target = title.isEmpty ? "the list" : "\"\(title)\""
            if let names = item.addedNames, !names.isEmpty {
                return "Added \(names) to \(target)."
            }
            return "Added items to \(target)."
        case ("list", "item_updated"):
            let target = title.isEmpty ? "the list" : "\"\(title)\""
            return "Updated an item in \(target)."
        case ("list", "item_removed"):
            let target = title.isEmpty ? "the list" : "\"\(title)\""
            return "Removed an item from \(target)."

        case (_, "deleted"):
            return "Deleted \(typeLabel)\(titleClause)."

        default:
            return "Done."
        }
    }

    private static func label(for type: String) -> String {
        switch type {
        case "todo": return "task"
        case "note": return "note"
        case "list": return "list"
        case "folder": return "folder"
        case "expense": return "expense"
        default: return type
        }
    }

    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Open-app routing

    /// Decide where the snippet's "Go to app" button takes the user.
    ///
    /// Rules:
    ///  - Single item with a parseable UUID → focus that section + row.
    ///    `items_added` is single too (the `id` IS the parent list/trip
    ///    UUID per `ExecuteDraftAction`).
    ///  - Multiple items (regardless of section mix) → Activity feed.
    ///  - Single item with an unparseable id → `nil` (snippet hides the
    ///    affordance rather than landing the user on a broken focus).
    ///
    /// Returns an `OpenDexterIntent` instead of a URL so the snippet
    /// view can wire it into a `Button(intent:)` — the iOS-blessed
    /// pattern for snippet-view actions. Using `Link(destination:)`
    /// with our own URL scheme caused the system "Done" button to
    /// auto-open the app, because iOS treated the Link as the intent's
    /// implied primary action.
    static func openIntent(for items: [ExecutedDraft]) -> OpenDexterIntent? {
        guard !items.isEmpty else { return nil }
        if items.count > 1 {
            return OpenDexterIntent(section: AppSection.activity.rawValue, id: nil)
        }
        let item = items[0]
        guard let section = sectionPathComponent(for: item.type) else {
            return OpenDexterIntent(section: AppSection.activity.rawValue, id: nil)
        }
        guard UUID(uuidString: item.id) != nil else {
            // Defensive: don't render an affordance that would land on
            // garbage. Snippet view handles `nil` by hiding the button.
            return nil
        }
        return OpenDexterIntent(section: section, id: item.id)
    }

    /// Map the `ExecutedDraft.type` string to the section path component.
    /// Matches `AppSection.rawValue` so the receiver can rehydrate it.
    private static func sectionPathComponent(for type: String) -> String? {
        switch type {
        case "todo":                       return AppSection.tasks.rawValue
        case "note":                       return AppSection.notes.rawValue
        case "list":                       return AppSection.lists.rawValue
        case "trip", "itinerary_item":     return AppSection.itineraries.rawValue
        case "folder":                     return AppSection.notes.rawValue
        case "expense":                    return AppSection.finance.rawValue
        default:                           return nil
        }
    }
}
