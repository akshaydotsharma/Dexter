import Foundation

struct AIService: Sendable {
    let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func parse(input: String, sessionId: String? = nil, timezone: String? = TimeZone.current.identifier) async throws -> ChatResponse {
        let request = ChatRequest(input: input, sessionId: sessionId, timezone: timezone)
        return try await api.post("ai/parse", body: request)
    }

    func execute(draftId: Int, updatedData: DraftPayload? = nil) async throws -> ExecuteDraftResponse {
        let request = ExecuteDraftRequest(draftId: draftId, updatedData: updatedData)
        return try await api.post("ai/execute", body: request)
    }

    func confirmDraft(draftId: Int) async throws -> ExecuteDraftResponse {
        struct EmptyBody: Encodable {}
        return try await api.post("drafts/\(draftId)/confirm", body: EmptyBody())
    }

    func rejectDraft(draftId: Int) async throws {
        struct EmptyBody: Encodable {}
        let _: ExecuteDraftResponse = try await api.post("drafts/\(draftId)/reject", body: EmptyBody())
    }
}
