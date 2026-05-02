import Foundation
import Observation

struct ChatTurn: Identifiable, Hashable {
    let id = UUID()
    let role: Role
    let text: String
    let drafts: [Draft]

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
    private let sessionId: String

    init(service: AIService = AIService()) {
        self.service = service
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
        do {
            let response = try await service.parse(input: input, sessionId: sessionId)
            let assistantText = response.assistantText ?? response.followUpQuestion ?? ""
            turns.append(ChatTurn(role: .assistant, text: assistantText, drafts: response.drafts))
        } catch {
            errorMessage = error.localizedDescription
        }
        isSending = false
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
