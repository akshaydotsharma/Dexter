import Foundation

/// Outcome of one applied draft action. Surfaced to the App Intent dialog
/// so the side-button capture can report what was added/updated/deleted.
/// `id` is a UUID string (the SwiftData `clientUUID`) — the on-device
/// pipeline has no integer IDs.
struct ExecutedDraft: Sendable {
    let type: String        // "todo" | "note" | "list" | "folder"
    let action: String      // "created" | "completed" | "reopened" | "updated" | "deleted" | "items_added" | "item_updated" | "item_removed"
    let id: String
    let title: String?
    let dueDate: Date?
    let addedNames: String?
}

/// One tool call the LLM issued that we couldn't apply (bad UUID, missing
/// argument, persistence failure). Same UUID-string identity as the
/// executed counterpart.
struct FailedDraft: Sendable {
    let tool: String
    let id: String?
    let message: String
}

struct CaptureErrorEntry: Sendable {
    let tool: String?
    let message: String?
}

/// Aggregate response handed back to the App Intent. Status drives the
/// dialog-formatting branch; `executed` / `failed` carry the per-action
/// detail.
struct CaptureResponse: Sendable {
    let status: Status
    let executed: [ExecutedDraft]?
    let failed: [FailedDraft]?
    let assistantText: String?
    let followUpQuestion: String?
    let errors: [CaptureErrorEntry]?

    enum Status: String, Sendable {
        case executed
        case needsClarification
        case error
    }
}

/// Capture service runs the on-device chat-to-drafts pipeline. There is no
/// HTTP transport anymore — Anthropic is reached directly from the phone.
struct CaptureService: Sendable {

    /// Hard upper bound — the App Intent's overall budget is ~30 s and we
    /// want to surface a clean error well before the system kills us.
    static let timeoutSeconds: UInt64 = 22

    init() {}

    func capture(
        input: String,
        sessionId: String? = nil,
        timezone: String? = TimeZone.current.identifier
    ) async throws -> CaptureResponse {
        let tz = timezone ?? TimeZone.current.identifier

        // Wrap the on-device call so a hung LLM request doesn't blow past
        // the App Intent budget.
        return try await withThrowingTaskGroup(of: CaptureResponse.self) { group in
            group.addTask {
                await Self.runCapture(input: input, timezone: tz)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
                return CaptureResponse(
                    status: .error,
                    executed: nil,
                    failed: nil,
                    assistantText: nil,
                    followUpQuestion: nil,
                    errors: [CaptureErrorEntry(tool: nil, message: "Capture timed out after \(Self.timeoutSeconds)s.")]
                )
            }
            // First task to return wins; cancel the loser.
            guard let first = try await group.next() else {
                throw AnthropicError.transport(URLError(.unknown))
            }
            group.cancelAll()
            return first
        }
    }

    @MainActor
    private static func runCapture(input: String, timezone: String) async -> CaptureResponse {
        let pipeline = ChatToDrafts.default()
        do {
            let result = try await pipeline.run(input: input, timezone: timezone)

            let executed = result.executed.map { outcome in
                ExecutedDraft(
                    type: outcome.type,
                    action: outcome.action,
                    id: outcome.id,
                    title: outcome.title,
                    dueDate: outcome.dueDate,
                    addedNames: outcome.addedNames
                )
            }
            let failed = result.failed.map { rec in
                FailedDraft(tool: rec.tool, id: rec.id, message: rec.message)
            }

            if !executed.isEmpty {
                return CaptureResponse(
                    status: .executed,
                    executed: executed,
                    failed: failed.isEmpty ? nil : failed,
                    assistantText: result.assistantText,
                    followUpQuestion: nil,
                    errors: nil
                )
            }
            if let q = result.followUpQuestion {
                return CaptureResponse(
                    status: .needsClarification,
                    executed: nil,
                    failed: nil,
                    assistantText: result.assistantText,
                    followUpQuestion: q,
                    errors: nil
                )
            }
            // No actions and no clarification — surface failures (if any)
            // or fall back to the assistant text.
            if !failed.isEmpty {
                let entries = failed.map { CaptureErrorEntry(tool: $0.tool, message: $0.message) }
                return CaptureResponse(
                    status: .error,
                    executed: nil,
                    failed: failed,
                    assistantText: result.assistantText,
                    followUpQuestion: nil,
                    errors: entries
                )
            }
            return CaptureResponse(
                status: .needsClarification,
                executed: nil,
                failed: nil,
                assistantText: result.assistantText,
                followUpQuestion: result.assistantText ?? "I need a bit more detail.",
                errors: nil
            )
        } catch let err as AnthropicError {
            return CaptureResponse(
                status: .error,
                executed: nil,
                failed: nil,
                assistantText: nil,
                followUpQuestion: nil,
                errors: [CaptureErrorEntry(tool: nil, message: err.errorDescription)]
            )
        } catch {
            return CaptureResponse(
                status: .error,
                executed: nil,
                failed: nil,
                assistantText: nil,
                followUpQuestion: nil,
                errors: [CaptureErrorEntry(tool: nil, message: error.localizedDescription)]
            )
        }
    }
}
