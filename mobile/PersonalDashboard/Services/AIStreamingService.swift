import Foundation

/// Chat-side wrapper around the on-device `ChatStream`. Kept as a thin shim
/// so `ChatViewModel` doesn't need to know about Anthropic types directly.
/// All HTTP / SSE plumbing now lives in `AnthropicClient.stream`.
@MainActor
struct AIStreamingService {
    let chatStream: ChatStream

    init(chatStream: ChatStream? = nil) {
        self.chatStream = chatStream ?? ChatStream.default()
    }

    /// One event surfaced to the chat surface. Drafts arrive one-at-a-time
    /// because Anthropic emits each tool block as it closes.
    enum StreamEvent: Sendable {
        case draft(ChatDraft)
        case textChunk(String)
        case done(followUpQuestion: String?)
        case error(String)
    }

    /// Forwards `ChatStream.run` events into the local enum so callers stay
    /// decoupled from the Anthropic-flavored wire types.
    ///
    /// #310 named the `Task { @MainActor in }` below as compounding the
    /// main-actor problem. It stays on the main actor, deliberately, and the
    /// reason is worth recording so it is not "fixed" later:
    ///
    /// - `ChatStream` is a `@MainActor` type and its `run` reads SwiftData via
    ///   `AssistantContextBuilder`. A `ModelContext` is main-actor-confined, so
    ///   this loop cannot leave the main actor without a background context.
    /// - Once `AnthropicClient.stream` stopped being `@MainActor`, the expensive
    ///   work — the SSE read loop and the per-delta JSON decode — moved off
    ///   main at the source. What remains here is one enum-to-enum mapping per
    ///   already-parsed event, which is not the cost the ticket was about.
    ///
    /// The `onTermination` hook is load-bearing for cancellation: it propagates
    /// a cancelled consumer down through `ChatStream` to the client's detached
    /// SSE task, which is what stops tool calls executing after the chat view
    /// has gone away.
    func parseStream(
        history: [ChatStream.PriorTurn] = [],
        input: String,
        sessionId: String? = nil,
        timezone: String = TimeZone.current.identifier
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    for try await event in chatStream.run(history: history, input: input, timezone: timezone) {
                        switch event {
                        case .draft(let d):
                            continuation.yield(.draft(d))
                        case .textChunk(let c):
                            continuation.yield(.textChunk(c))
                        case .done(let q):
                            continuation.yield(.done(followUpQuestion: q))
                        case .error(let m):
                            continuation.yield(.error(m))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
