import Foundation

struct CaptureRequest: Encodable {
    let input: String
    let sessionId: String?
    let timezone: String?
}

/// Server's per-draft summary after auto-execution. The same shape covers
/// creates, updates, deletes, and add-to-list intents — `action` tells the
/// dialog builder which sentence to emit.
struct ExecutedDraft: Decodable, Sendable {
    let type: String
    let action: String
    let id: Int
    let title: String?
    let dueDate: Date?
    let addedNames: String?
}

struct FailedDraft: Decodable, Sendable {
    let id: Int
    let actionType: String
    let title: String?
    let reason: String

    enum CodingKeys: String, CodingKey {
        case id
        case actionType
        case title
        case reason
    }
}

struct CaptureErrorEntry: Decodable, Sendable {
    let tool: String?
    let message: String?
}

struct CaptureResponse: Decodable, Sendable {
    let status: Status
    let executed: [ExecutedDraft]?
    let failed: [FailedDraft]?
    let assistantText: String?
    let followUpQuestion: String?
    let errors: [CaptureErrorEntry]?

    enum Status: String, Decodable, Sendable {
        case executed
        case needsClarification = "needs_clarification"
        case error
    }
}

struct CaptureService: Sendable {
    let api: APIClient

    init(api: APIClient = .shared) {
        self.api = api
    }

    func capture(
        input: String,
        sessionId: String? = nil,
        timezone: String? = TimeZone.current.identifier
    ) async throws -> CaptureResponse {
        let request = CaptureRequest(input: input, sessionId: sessionId, timezone: timezone)
        return try await api.post("ai/capture", body: request)
    }
}
