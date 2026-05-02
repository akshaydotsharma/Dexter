import Foundation
import Observation

struct ChatTurn: Identifiable, Hashable {
    let id: UUID
    var role: Role
    var text: String
    var drafts: [Draft]
    var isStreaming: Bool

    init(id: UUID = UUID(), role: Role, text: String, drafts: [Draft], isStreaming: Bool = false) {
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

    private let service: AIService
    private let streamingService: AIStreamingService
    private let sessionId: String

    init(service: AIService = AIService(), streamingService: AIStreamingService = AIStreamingService()) {
        self.service = service
        self.streamingService = streamingService
        self.sessionId = UUID().uuidString
        // Optional QA seeding: if SEED_CHAT=1 is in the launch env we render
        // a deterministic conversation for screenshot capture.
        if ProcessInfo.processInfo.environment["SEED_CHAT"] == "1" {
            let demo: Draft = Draft(
                id: -1,
                actionType: .createTodo,
                draftData: DraftPayload(
                    id: nil,
                    listId: nil,
                    itemIndex: nil,
                    title: "Call John",
                    content: nil,
                    description: nil,
                    dueDate: Date().addingTimeInterval(3 * 3600),
                    tag: "work",
                    folderId: nil,
                    name: nil,
                    items: nil,
                    newItems: nil,
                    text: nil,
                    checked: nil,
                    completed: nil
                ),
                preview: "Call John",
                status: "draft"
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
                case .drafts(let drafts):
                    turns[idx].drafts = drafts
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
            // Streaming failed (network, server 404, decoder). Fall back to the
            // single-shot endpoint so chat still works on older deployments.
            await fallbackToNonStreaming(input: input, assistantTurnId: assistantTurnId, originalError: error)
        }

        if let idx = turns.firstIndex(where: { $0.id == assistantTurnId }) {
            turns[idx].isStreaming = false
            // Drop empty assistant turn (no text and no drafts) — happens on
            // pure follow-up questions where the server returns nothing.
            if turns[idx].text.isEmpty && turns[idx].drafts.isEmpty {
                turns.remove(at: idx)
            }
        }

        isSending = false
    }

    private func fallbackToNonStreaming(input: String, assistantTurnId: UUID, originalError: Error) async {
        do {
            let response = try await service.parse(input: input, sessionId: sessionId)
            let text = response.assistantText ?? response.followUpQuestion ?? ""
            if let idx = turns.firstIndex(where: { $0.id == assistantTurnId }) {
                turns[idx].text = text
                turns[idx].drafts = response.drafts
                turns[idx].isStreaming = false
            }
        } catch {
            errorMessage = (originalError as? APIError)?.localizedDescription ?? originalError.localizedDescription
        }
    }

    func confirm(_ draft: Draft) async -> Bool {
        do {
            _ = try await service.execute(draftId: draft.id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reject(_ draft: Draft) async {
        do {
            try await service.rejectDraft(draftId: draft.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
