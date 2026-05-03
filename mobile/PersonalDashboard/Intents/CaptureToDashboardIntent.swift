import AppIntents
import Foundation

/// Adds a task / note / list (or edits one) on the personal dashboard from
/// a free-text or dictated phrase, without opening the app.
///
/// Wired into Shortcuts so the iPhone Action Button (or back-tap, Lock
/// Screen, Siri) can trigger:
///   Dictate Text -> CaptureToDashboard(input: $dictation) -> Show Notification
///
/// Server behaviour: every draft the LLM produces from the dictated input
/// is auto-executed. Single create, multi-create, add-to-list, edit, even
/// delete — all run autonomously. The dialog reports what changed, item by
/// item, so the user gets confirmation without opening the app.
struct CaptureToDashboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture to Dashboard"
    static var description = IntentDescription(
        "Add or update a task, note, or list on your dashboard from text or voice. Runs autonomously — the dictated phrase is parsed and applied without opening the app."
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
        description: "What you want to add or change — for example 'remind me to call John tomorrow at 3', 'add milk and eggs to my groceries list', 'mark the dentist task as done'.",
        requestValueDialog: "What do you want to capture?"
    )
    var input: String

    static var parameterSummary: some ParameterSummary {
        Summary("Capture \(\.$input) to Dashboard")
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
            let detail = (error as? APIError)?.localizedDescription ?? error.localizedDescription
            return .result(dialog: "Couldn't capture — \(detail)")
        }

        switch response.status {
        case .executed:
            let summary = Self.executedDialog(executed: response.executed ?? [], failed: response.failed ?? [])
            return .result(dialog: IntentDialog(stringLiteral: summary))
        case .needsClarification:
            let q = response.followUpQuestion ?? "I need a bit more detail."
            return .result(dialog: IntentDialog(stringLiteral: q))
        case .error:
            let first = response.errors?.first?.message ?? "something went wrong"
            return .result(dialog: IntentDialog(stringLiteral: "Couldn't capture — \(first)"))
        }
    }

    // MARK: - Dialog builder

    private static func executedDialog(executed: [ExecutedDraft], failed: [FailedDraft]) -> String {
        let lines = executed.map(sentence(for:))
        var text: String
        switch lines.count {
        case 0: text = "Nothing to apply."
        case 1: text = lines[0]
        default: text = lines.joined(separator: " ")
        }
        if !failed.isEmpty {
            let plural = failed.count == 1 ? "item" : "items"
            text += " (\(failed.count) \(plural) couldn't be applied.)"
        }
        return text
    }

    private static func sentence(for item: ExecutedDraft) -> String {
        let title = item.title ?? ""
        switch (item.type, item.action) {
        case ("todo", "created"):
            if let due = item.dueDate {
                return "Added task \"\(title)\" — due \(dueFormatter.string(from: due))."
            }
            return "Added task \"\(title)\"."
        case ("todo", "completed"):
            return "Marked \"\(title)\" complete."
        case ("todo", "reopened"):
            return "Reopened \"\(title)\"."
        case ("todo", "updated"):
            return "Updated task \"\(title)\"."
        case ("todo", "deleted"):
            return "Deleted task \"\(title)\"."
        case ("note", "created"):
            return "Added note \"\(title)\"."
        case ("note", "updated"):
            return "Updated note \"\(title)\"."
        case ("note", "deleted"):
            return "Deleted note \"\(title)\"."
        case ("list", "created"):
            return "Created list \"\(title)\"."
        case ("list", "items_added"):
            if let added = item.addedNames, !added.isEmpty {
                return "Added \(added) to \"\(title)\"."
            }
            return "Added items to \"\(title)\"."
        case ("list", "item_updated"):
            return "Updated an item in \"\(title)\"."
        case ("list", "item_removed"):
            return "Removed an item from \"\(title)\"."
        case ("list", "updated"):
            return "Updated list \"\(title)\"."
        case ("list", "deleted"):
            return "Deleted list \"\(title)\"."
        case ("folder", "updated"):
            return "Renamed folder \"\(title)\"."
        case ("folder", "deleted"):
            return "Deleted folder \"\(title)\"."
        default:
            return "Done."
        }
    }

    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
