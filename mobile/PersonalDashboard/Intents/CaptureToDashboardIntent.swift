import AppIntents
import Foundation

/// Adds a task / note / list to the personal dashboard from a free-text or
/// dictated phrase, without opening the app.
///
/// Wired into Shortcuts so the iPhone Action Button (or back-tap / Lock
/// Screen / Siri) can trigger:
///   Dictate Text -> CaptureToDashboard(input: $dictation) -> Show Notification
///
/// The server's smart auto-confirm rule decides what happens to the input:
///   - one CREATE_TODO/NOTE/LIST draft -> created and persisted, dialog
///     reports what was added.
///   - multiple drafts or any edit/delete draft -> left pending, dialog
///     asks the user to open Dashboard to confirm.
///   - LLM follow-up question -> dialog surfaces the question, nothing
///     persisted.
struct CaptureToDashboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture to Dashboard"
    static var description = IntentDescription(
        "Add a task, note, or list to your dashboard from text or voice. Nothing risky is auto-saved — edits and multi-item captures are queued for review in the app."
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
        case .created:
            let summary = Self.createdDialog(for: response.created ?? [])
            return .result(dialog: IntentDialog(stringLiteral: summary))
        case .needsClarification:
            let q = response.followUpQuestion ?? "I need a bit more detail."
            return .result(dialog: IntentDialog(stringLiteral: q))
        case .needsReview:
            let count = response.pendingDrafts?.count ?? 0
            let plural = count == 1 ? "item" : "items"
            return .result(dialog: IntentDialog(stringLiteral:
                "Drafted \(count) \(plural) — open Dashboard to review and confirm."
            ))
        case .error:
            let first = response.errors?.first?.message ?? "something went wrong"
            return .result(dialog: IntentDialog(stringLiteral: "Couldn't capture — \(first)"))
        }
    }

    private static func createdDialog(for items: [CapturedItem]) -> String {
        guard let item = items.first else { return "Captured." }
        let typeLabel: String
        switch item.type {
        case "todo": typeLabel = "task"
        case "note": typeLabel = "note"
        case "list": typeLabel = "list"
        default: typeLabel = item.type
        }
        if let due = item.dueDate {
            return "Added \(typeLabel) \"\(item.title)\" — due \(Self.dueFormatter.string(from: due))."
        }
        return "Added \(typeLabel) \"\(item.title)\"."
    }

    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
