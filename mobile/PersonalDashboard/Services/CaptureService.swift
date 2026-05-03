import Foundation

struct CaptureRequest: Encodable {
    let input: String
    let sessionId: String?
    let timezone: String?
}

struct CapturedItem: Decodable, Sendable {
    let type: String
    let title: String
    let id: Int
    let dueDate: Date?
}

struct PendingDraftSummary: Decodable, Sendable {
    let id: Int
    let type: String
    let title: String
}

struct CaptureErrorEntry: Decodable, Sendable {
    let tool: String?
    let message: String?
}

struct CaptureResponse: Decodable, Sendable {
    let status: Status
    let created: [CapturedItem]?
    let pendingDrafts: [PendingDraftSummary]?
    let assistantText: String?
    let followUpQuestion: String?
    let errors: [CaptureErrorEntry]?

    enum Status: String, Decodable, Sendable {
        case created
        case needsReview = "needs_review"
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
