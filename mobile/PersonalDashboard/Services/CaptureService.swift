import Foundation

/// Outcome of one applied draft action. Surfaced to the App Intent dialog
/// so the side-button capture can report what was added/updated/deleted.
/// `id` is a UUID string (the SwiftData `clientUUID`) — the on-device
/// pipeline has no integer IDs.
struct ExecutedDraft: Sendable {
    let type: String        // "todo" | "note" | "list" | "folder" | "expense" | "meal"
    let action: String      // "created" | "completed" | "reopened" | "updated" | "deleted" | "items_added" | "item_updated" | "item_removed"
    let id: String
    let title: String?
    let dueDate: Date?
    let addedNames: String?
    /// Present only for a logged meal (#546). The App Intent speaks
    /// `MealLogSummary.dialogSentence()`, which always states either a number
    /// or the reason there is no number — a silent success is how a day
    /// quietly ends up half logged.
    var meal: MealLogSummary? = nil
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
    /// The model was cut off at its output ceiling part-way through a turn
    /// (#554). Nothing from that turn was applied. The dialog must say so: the
    /// Shortcut path has no conversation in which a silently dropped half of a
    /// request would ever be noticed.
    var truncated: Bool = false

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

    /// Spoken when a capture was cut off before anything was applied.
    ///
    /// It names the cause and the consequence in one sentence, because the only
    /// feedback this path has is the sentence Siri reads back.
    static let truncatedMessage =
        "the reply was cut off before it finished, so nothing was saved. Say it again, or one thing at a time."

    /// Appended to the dialog when SOME of a capture landed and a later turn
    /// was then cut off.
    static let partialTruncationNote =
        " The rest was cut off, so say it again if something is missing."


    /// Turn a pipeline result into the response the App Intent speaks.
    ///
    /// Lifted out of `runCapture` (#554) so the truncation branches can be
    /// tested. `runCapture` builds `ChatToDrafts.default()`, which is wired to
    /// the REAL SwiftData store, so a test that went through it would write to
    /// the user's own data. This function is pure.
    static func response(for result: ChatToDraftsResult) -> CaptureResponse {
        let executed = result.executed.map { outcome in
            ExecutedDraft(
                type: outcome.type,
                action: outcome.action,
                id: outcome.id,
                title: outcome.title,
                dueDate: outcome.dueDate,
                addedNames: outcome.addedNames,
                meal: outcome.meal
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
                errors: nil,
                truncated: result.truncated
            )
        }

        // Cut off before anything was applied. This is an error, not a
        // clarification: the user asked for something real and got nothing, and
        // the remedy is to repeat the request, not to answer a question.
        // Ordered ahead of the follow-up and failure branches so a truncated
        // turn never reports as "I need a bit more detail".
        if result.truncated {
            return CaptureResponse(
                status: .error,
                executed: nil,
                failed: failed.isEmpty ? nil : failed,
                assistantText: result.assistantText,
                followUpQuestion: nil,
                errors: [CaptureErrorEntry(tool: nil, message: truncatedMessage)],
                truncated: true
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
    }

    @MainActor
    private static func runCapture(input: String, timezone: String) async -> CaptureResponse {
        let pipeline = ChatToDrafts.default()
        do {
            return response(for: try await pipeline.run(input: input, timezone: timezone))
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
