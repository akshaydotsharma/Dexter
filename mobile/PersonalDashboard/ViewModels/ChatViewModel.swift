import Foundation
import Observation

struct ChatTurn: Identifiable, Hashable {
    let id: UUID
    var role: Role
    var text: String
    /// Auto-executed action results for this turn. Each item represents a
    /// tool call the model issued that we already applied to SwiftData.
    var results: [ChatActionResult]
    var isStreaming: Bool

    init(id: UUID = UUID(), role: Role, text: String, results: [ChatActionResult] = [], isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.results = results
        self.isStreaming = isStreaming
    }

    enum Role: Hashable {
        case user
        case assistant
    }
}

@Observable
@MainActor
final class ChatViewModel {
    private(set) var turns: [ChatTurn] = []
    private(set) var isSending = false
    var errorMessage: String?
    var draftInput: String = ""

    private let streamingService: AIStreamingService
    private let executor: ExecuteDraftAction
    private let sessionId: String

    init(
        streamingService: AIStreamingService? = nil,
        executor: ExecuteDraftAction? = nil
    ) {
        self.streamingService = streamingService ?? AIStreamingService()
        self.executor = executor ?? ExecuteDraftAction.default()
        self.sessionId = UUID().uuidString

        // Optional QA seeding: if SEED_CHAT=1 is in the launch env we render
        // a deterministic conversation for screenshot capture. The seeded
        // result is rendered as if it had already executed successfully.
        if ProcessInfo.processInfo.environment["SEED_CHAT"] == "1" {
            let demoInput: AnthropicJSONValue = .object([
                "title": .string("Call John"),
                "description": .string(""),
                "due_at": .string(Self.demoDueISO),
                "tag": .string("Work")
            ])
            let demoOutcome = DraftActionOutcome(
                type: "todo",
                action: ActionString.created,
                id: UUID().uuidString.lowercased(),
                title: "Call John",
                dueDate: Self.parseDemoDue(),
                addedNames: nil
            )
            let demoResult = ChatActionResult(
                actionType: .createTodo,
                input: demoInput,
                outcome: demoOutcome
            )
            self.turns = [
                ChatTurn(role: .user, text: "remind me to call John tomorrow at 3"),
                ChatTurn(role: .assistant, text: "Done — added that task.", results: [demoResult])
            ]
        }
    }

    /// Wipe conversation state so the next `send()` replays NO prior history.
    /// Used by the voice-capture overlay, where each spoken utterance must be a
    /// fully independent, stateless capture (issue #156): without this, `send()`
    /// snapshots the accumulated `turns` into its history array and replays the
    /// whole session to Claude, which then re-issues earlier tool calls and
    /// duplicates items. The regular chat surface never calls this — it keeps
    /// its multi-turn history.
    func reset() {
        turns = []
        isSending = false
        errorMessage = nil
        draftInput = ""
    }

    func send() async {
        let input = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        draftInput = ""

        // Snapshot conversation history BEFORE appending the new user turn,
        // so the stateless Anthropic API sees what was said earlier (and we
        // don't double-count the current input). Auto-executed action
        // results aren't replayed — the system prompt's EXISTING items
        // context block is the source of truth for current device state.
        let history: [ChatStream.PriorTurn] = turns.compactMap { turn in
            let trimmed = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ChatStream.PriorTurn(
                role: turn.role == .user ? "user" : "assistant",
                text: trimmed
            )
        }

        turns.append(ChatTurn(role: .user, text: input))
        isSending = true
        errorMessage = nil

        // Add an empty assistant turn that streaming will fill in. While
        // isStreaming=true the chat surface won't show the standalone typing
        // indicator — the empty turn itself shows the cursor effect.
        let assistantTurnId = UUID()
        turns.append(ChatTurn(id: assistantTurnId, role: .assistant, text: "", isStreaming: true))

        do {
            for try await event in streamingService.parseStream(history: history, input: input, sessionId: sessionId) {
                guard let idx = turns.firstIndex(where: { $0.id == assistantTurnId }) else { break }
                switch event {
                case .draft(let d):
                    // Auto-execute: drafts arrive one-at-a-time as the model
                    // closes each tool block. Run the executor on each and
                    // append the success / failure record so the user sees
                    // a stable card stream alongside the streaming prose.
                    let result = await execute(draft: d)
                    turns[idx].results.append(result)
                case .textChunk(let chunk):
                    turns[idx].text += chunk
                case .done:
                    turns[idx].isStreaming = false
                case .error(let message):
                    errorMessage = message
                    turns[idx].isStreaming = false
                }
            }
        } catch {
            // No fallback: Anthropic is the only path now. Surface the error
            // verbatim so the user can see API key / network / quota failures.
            errorMessage = error.localizedDescription
        }

        if let idx = turns.firstIndex(where: { $0.id == assistantTurnId }) {
            turns[idx].isStreaming = false
            // Drop empty assistant turn (no text and no results) — happens on
            // pure follow-up questions where the model returns nothing.
            if turns[idx].text.isEmpty && turns[idx].results.isEmpty {
                turns.remove(at: idx)
            }
        }

        isSending = false
    }

    /// Run the executor against one draft and turn the outcome / error into
    /// a `ChatActionResult` for the UI. Mirrors the capture path's handling
    /// in `ChatToDrafts`, but per-card instead of batched.
    private func execute(draft: ChatDraft) async -> ChatActionResult {
        let dict = draft.input.objectValue ?? [:]
        do {
            let outcome = try await executor.run(actionType: draft.actionType, input: dict)
            return ChatActionResult(
                id: draft.id,
                actionType: draft.actionType,
                input: draft.input,
                outcome: outcome
            )
        } catch let err as DraftExecutionError {
            return ChatActionResult(
                id: draft.id,
                actionType: draft.actionType,
                input: draft.input,
                errorMessage: err.errorDescription ?? "Action failed"
            )
        } catch {
            return ChatActionResult(
                id: draft.id,
                actionType: draft.actionType,
                input: draft.input,
                errorMessage: error.localizedDescription
            )
        }
    }

    private static let demoDueISO: String = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(3 * 3600))
    }()

    private static func parseDemoDue() -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: demoDueISO) ?? Date().addingTimeInterval(3 * 3600)
    }
}
