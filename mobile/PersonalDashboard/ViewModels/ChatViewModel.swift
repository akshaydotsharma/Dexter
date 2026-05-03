import Foundation
import Observation

struct ChatTurn: Identifiable, Hashable {
    let id: UUID
    var role: Role
    var text: String
    var drafts: [ChatDraft]
    var isStreaming: Bool

    init(id: UUID = UUID(), role: Role, text: String, drafts: [ChatDraft], isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.drafts = drafts
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
        // a deterministic conversation for screenshot capture.
        if ProcessInfo.processInfo.environment["SEED_CHAT"] == "1" {
            let demoInput: AnthropicJSONValue = .object([
                "title": .string("Call John"),
                "description": .string(""),
                "due_at": .string(Self.demoDueISO),
                "tag": .string("Work")
            ])
            let demo = ChatDraft(
                actionType: .createTodo,
                input: demoInput,
                preview: ChatDraft.makePreview(actionType: .createTodo, input: demoInput)
            )
            self.turns = [
                ChatTurn(role: .user, text: "remind me to call John tomorrow at 3", drafts: []),
                ChatTurn(role: .assistant, text: "Got it. I'll draft that task for you to confirm.", drafts: [demo])
            ]
        }
    }

    func send() async {
        let input = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        draftInput = ""
        turns.append(ChatTurn(role: .user, text: input, drafts: []))
        isSending = true
        errorMessage = nil

        // Add an empty assistant turn that streaming will fill in. While
        // isStreaming=true the chat surface won't show the standalone typing
        // indicator — the empty turn itself shows the cursor effect.
        let assistantTurnId = UUID()
        turns.append(ChatTurn(id: assistantTurnId, role: .assistant, text: "", drafts: [], isStreaming: true))

        do {
            for try await event in streamingService.parseStream(input: input, sessionId: sessionId) {
                guard let idx = turns.firstIndex(where: { $0.id == assistantTurnId }) else { break }
                switch event {
                case .draft(let d):
                    turns[idx].drafts.append(d)
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
            // Drop empty assistant turn (no text and no drafts) — happens on
            // pure follow-up questions where the model returns nothing.
            if turns[idx].text.isEmpty && turns[idx].drafts.isEmpty {
                turns.remove(at: idx)
            }
        }

        isSending = false
    }

    /// Apply a draft on confirm. Runs the same on-device executor the Shortcut
    /// path uses, so chat and capture share one persistence path.
    func confirm(_ draft: ChatDraft) async -> Bool {
        let dict = draft.input.objectValue ?? [:]
        do {
            _ = try await executor.run(actionType: draft.actionType, input: dict)
            return true
        } catch let err as DraftExecutionError {
            errorMessage = err.errorDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Drop a draft card from its turn. Without server-side draft state,
    /// rejection is purely a UI operation.
    func reject(_ draft: ChatDraft) {
        for idx in turns.indices {
            if let cardIdx = turns[idx].drafts.firstIndex(of: draft) {
                turns[idx].drafts.remove(at: cardIdx)
                return
            }
        }
    }

    private static let demoDueISO: String = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(3 * 3600))
    }()
}
