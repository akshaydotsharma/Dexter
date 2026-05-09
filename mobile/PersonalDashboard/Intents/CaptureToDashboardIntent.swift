import AppIntents
import Foundation

/// Adds a task / note / list to the personal dashboard from a free-text or
/// dictated phrase, without opening the app.
///
/// Wired into Shortcuts so the iPhone Action Button (or back-tap / Lock
/// Screen / Siri) can trigger:
///   Dictate Text -> CaptureToDashboard(input: $dictation) -> Show Notification
///
/// The on-device pipeline applies tool calls directly to SwiftData and
/// reports outcomes:
///   - executed actions -> dialog summarises what was applied.
///   - LLM follow-up question -> dialog surfaces the question, nothing
///     persisted.
///   - failure -> dialog surfaces a brief error.
struct CaptureToDashboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture to Dexter"
    static var description = IntentDescription(
        "Add a task, note, or list to Dexter from text or voice. Runs on-device against your local data, no server hop."
    )

    /// Stay backgrounded so the side button feels instant and the user
    /// doesn't lose their current context. Action Button + Shortcut +
    /// Show Notification is the intended runtime path.
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

    func perform() async throws -> some IntentResult & ProvidesDialog {
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
            let summary = Self.executedDialog(for: response.executed ?? [])
            return .result(dialog: IntentDialog(stringLiteral: summary))
        case .needsClarification:
            let q = response.followUpQuestion ?? "I need a bit more detail."
            return .result(dialog: IntentDialog(stringLiteral: q))
        case .error:
            let first = response.errors?.first?.message ?? "something went wrong"
            return .result(dialog: IntentDialog(stringLiteral: "Couldn't capture — \(first)"))
        }
    }

    // MARK: - Dialog formatting

    /// Build the dialog string from the list of applied actions. Single
    /// action gets a focused sentence; multiple actions get a tally.
    private static func executedDialog(for items: [ExecutedDraft]) -> String {
        guard !items.isEmpty else { return "Done." }
        if items.count == 1 {
            return sentence(for: items[0])
        }
        // Multi-action: short summary by type.
        let creates = items.filter { $0.action == "created" }.count
        let updates = items.filter {
            $0.action == "updated" || $0.action == "completed" || $0.action == "reopened" ||
            $0.action == "items_added" || $0.action == "item_updated" || $0.action == "item_removed"
        }.count
        let deletes = items.filter { $0.action == "deleted" }.count
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
        default: return type
        }
    }

    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
