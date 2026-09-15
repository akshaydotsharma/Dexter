import Foundation

/// Direct Anthropic Messages API client. The phone calls this in place of
/// the retired Express backend; the API key is read from `AppConfig` and
/// must never be logged. Streaming variant is Phase 2.
struct AnthropicClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let model = "claude-sonnet-5"
    static let anthropicVersion = "2023-06-01"
    /// Shared output ceiling for every `send` / `stream` caller: the chat loop,
    /// the capture (Shortcut) loop, the email-ingest loop, both ticket
    /// extractors and the script normalizer.
    ///
    /// ## Measured, 2026-09-15, live API, `claude-sonnet-5` (#554)
    ///
    /// This was 1024, chosen before the model returned a `thinking` block.
    /// Thinking spends the SAME output budget the answer needs, so the old
    /// number was never measured against the model that runs today. Replayed
    /// through the SHIPPED system prompt and the SHIPPED 28 tools, against an
    /// in-memory library of 12 tasks / 8 notes / 2 lists
    /// (`LiveToolLoopTokenBudgetTests`), `output_tokens` came out as:
    ///
    ///   scenario                        n    min   mean   max
    ///   capture, one task              10    321    416    612
    ///   capture, three tool calls      10    615   1204   1781
    ///   capture, one meal               7   1423   1615   1866
    ///   capture, trip + itinerary       2    550      -   1177
    ///   loop turn 2 (tool_result)      16     29    145    567
    ///
    /// The headline is the first row. The SIMPLEST thing this path does — one
    /// task, one tool call — already needed 321 to 612 tokens, and the same
    /// input varied by nearly 2x between runs. Three tool calls reached 1781 and
    /// a meal reached 1866. So 1024 was not a comfortable ceiling being
    /// approached; it was a ceiling a routine multi-item capture went straight
    /// through, silently.
    ///
    /// 8192 is 4.4x the measured max. The margin is deliberate, not timid:
    /// #543 measured 1991 to 3361 on ONE identical meal description across four
    /// runs, so a distribution's observed max is not its ceiling. It also costs
    /// nothing. `max_tokens` is a ceiling, not a reservation — billing is on
    /// tokens generated, so raising it does not raise the bill for any turn
    /// that was already finishing. The only thing it buys is that a turn which
    /// needed a little more room gets it.
    ///
    /// The same figure as `AnthropicClient+EstimateMeal` and
    /// `AnthropicClient+DeriveTargets`, which reached it from their own
    /// measurements.
    ///
    /// Measured on the chat (streaming) path too, 15 Sep 2026, after #580:
    ///
    ///   scenario                        n    min    max
    ///   chat, long note                 5    444    655
    ///   chat, three tool calls          5    727   1784
    ///   chat, meal                      5   1266   1662
    ///
    /// Chat's maximum is 1784 against capture's 1866, so chat needs LESS
    /// headroom than capture, not more. 8192 stays right for both: it is about
    /// 4.4x the measured maximum across every scenario on either path. This
    /// note previously said the chat run was blocked on credit; it is not any
    /// more, and the numbers above replace that caveat.
    static let maxTokens = 8192
    // No `temperature`: Sonnet 5 rejects the field with
    // "`temperature` is deprecated for this model" (400). Any extraction rule
    // that relied on low-temperature determinism belongs in code, not sampling.

    let session: URLSession

    /// The session every real call runs on, replacing `URLSession.shared` (#594).
    ///
    /// `URLSession.shared` carries a `timeoutIntervalForRequest` of 60 s, and a
    /// session's configured value CAPS whatever an individual `URLRequest` asks
    /// for. So `request.timeoutInterval = 150` on a shared-session request is
    /// not a longer timeout, it is a 60 s timeout with a misleading line of code
    /// in front of it. That is exactly how #594's grounded estimate kept dying:
    /// the request said 150, the session said 60, and the call failed at 60.1 s
    /// with `NSURLErrorTimedOut`.
    ///
    /// The ceiling has to move here or it does not move. A request that would
    /// finish in 16 s still finishes in 16 s; this only changes how long a slow
    /// one is allowed to keep going before it is thrown away.
    ///
    /// For the streaming path this value means "time to wait for more data",
    /// not total duration, so a longer one does not let a finished stream hang:
    /// it lets a slow generation keep arriving.
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 150
        return URLSession(configuration: config)
    }()

    init(session: URLSession = AnthropicClient.defaultSession) {
        self.session = session
    }

    /// One `POST /v1/messages`.
    ///
    /// The system field is an `AnthropicSystemPrompt`, not a `String`, because
    /// prompt caching is a prefix match and this path's prompt ends in a
    /// timestamp and the whole SwiftData library (#580). The split names which
    /// half carries the `cache_control` breakpoint.
    ///
    /// Retries ONCE with every cache marker removed if the API rejects them.
    /// That retry is the only defence available to a change that could not be
    /// verified against the live API before it shipped: without it, a rejected
    /// marker would fail every AI call in the app instead of costing one
    /// duplicate request and a console line.
    func send(
        systemPrompt: AnthropicSystemPrompt,
        messages: [AnthropicMessage],
        tools: [AnthropicTool],
        maxTokens: Int = Self.maxTokens
    ) async throws -> AnthropicResponse {
        do {
            return try await sendOnce(
                systemPrompt: Self.promptCachingEnabled ? systemPrompt : systemPrompt.withoutCacheControl,
                messages: messages,
                tools: tools,
                maxTokens: maxTokens
            )
        } catch AnthropicError.http(let status, let body)
            where Self.isCacheControlRejection(status: status, body: body) {
            Self.disablePromptCaching()
            return try await sendOnce(
                systemPrompt: systemPrompt.withoutCacheControl,
                messages: messages,
                tools: tools,
                maxTokens: maxTokens
            )
        }
    }

    private func sendOnce(
        systemPrompt: AnthropicSystemPrompt,
        messages: [AnthropicMessage],
        tools: [AnthropicTool],
        maxTokens: Int
    ) async throws -> AnthropicResponse {
        guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
            throw AnthropicError.notConfigured
        }

        let body = AnthropicRequest(
            model: Self.model,
            max_tokens: maxTokens,
            system: systemPrompt,
            messages: messages,
            tools: tools
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw AnthropicError.decoding(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnthropicError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.http(0, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Body often contains a JSON error; surface a brief preview but
            // never leak the API key (it's a header, not in body).
            let preview = String(data: data.prefix(800), encoding: .utf8) ?? "<non-utf8 bytes>"
            throw AnthropicError.http(http.statusCode, preview)
        }

        do {
            let decoded = try Self.decoder.decode(AnthropicResponse.self, from: data)
            Self.logUsage(decoded.usage, path: "send")
            return decoded
        } catch {
            throw AnthropicError.decoding(error)
        }
    }

    /// Streaming variant of `send`. Yields incremental events the chat
    /// surface can render token-by-token, plus reconstructed tool-use blocks
    /// once their JSON input has been fully accumulated.
    ///
    /// Anthropic's SSE wire emits, per content block:
    ///   1. `content_block_start` with the block's `index` + initial shape
    ///   2. zero or more `content_block_delta` carrying either `text_delta`
    ///      (for prose) or `input_json_delta` (partial JSON for tool_use)
    ///   3. `content_block_stop` once the block is complete
    /// Tool inputs arrive as a stream of partial JSON strings keyed by index;
    /// we accumulate them and parse at `content_block_stop`.
    /// ## Isolation (#310)
    ///
    /// This used to be `@MainActor`, which put the entire SSE read loop and a
    /// JSON decode of every single delta on the main thread for the whole
    /// response. That annotation was not load-bearing — nothing in the body
    /// touches main-actor state: `AppConfig` is a plain enum, `session` is a
    /// `URLSession`, `Self.handle` is `static` with no `self` dependency, and
    /// the sibling `send` was already non-isolated and running off main. So the
    /// fix is to drop it rather than to work around it.
    ///
    /// Measured, under `-swift-version 5` and with the call coming from
    /// `@MainActor` as `ChatStream` makes it:
    ///
    ///   `@MainActor` func  + `Task {}`         -> parses ON main   (the bug)
    ///   nonisolated  func  + `Task {}`         -> parses off main
    ///   nonisolated  func  + `Task.detached`   -> parses off main  (this code)
    ///
    /// So removing the annotation is what actually fixes it, and is sufficient
    /// on its own — a plain `Task {}` here does NOT drag the loop back onto main
    /// today. `Task.detached` is kept anyway because it states the requirement
    /// independently of the enclosing declaration: an unstructured `Task {}`
    /// inherits whatever isolation surrounds it, so if this function or
    /// `AnthropicClient` ever picks up an actor annotation again, `Task {}`
    /// would silently re-inherit it and restore line 1 of that table while
    /// still compiling. `detached` cannot.
    ///
    /// Cancellation is unaffected by detaching. It does not arrive structurally
    /// here in either form (an unstructured `Task {}` is not a child task
    /// either); it arrives through `continuation.onTermination`, which fires
    /// when the consumer stops iterating — including when the consuming task is
    /// cancelled — and calls `task.cancel()`. The loop then breaks on its
    /// existing `Task.isCancelled` check.
    ///
    /// UI updates are unaffected too: this only produces events. Every consumer
    /// (`ChatStream`, `AIStreamingService`, `ChatViewModel`) is `@MainActor`, so
    /// rendering and all SwiftData writes still happen on the main actor.
    func stream(
        systemPrompt: AnthropicSystemPrompt,
        messages: [AnthropicMessage],
        tools: [AnthropicTool],
        maxTokens: Int = Self.maxTokens
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
                        throw AnthropicError.notConfigured
                    }

                    // Opens the SSE connection for one system-prompt shape.
                    // Separated out so the cache-rejection retry below can run
                    // the identical request with the markers stripped (#580).
                    func open(
                        _ prompt: AnthropicSystemPrompt
                    ) async throws -> URLSession.AsyncBytes {
                        let body = AnthropicStreamingRequest(
                            model: Self.model,
                            max_tokens: maxTokens,
                            system: prompt,
                            messages: messages,
                            tools: tools,
                            stream: true
                        )

                        var request = URLRequest(url: Self.endpoint)
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.setValue(key, forHTTPHeaderField: "x-api-key")
                        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
                        request.timeoutInterval = 120
                        request.httpBody = try Self.encoder.encode(body)

                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            throw AnthropicError.http(0, "non-HTTP response")
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            // Drain a small body preview to surface the API error.
                            var preview = ""
                            for try await line in bytes.lines {
                                preview += line + "\n"
                                if preview.count > 800 { break }
                            }
                            throw AnthropicError.http(http.statusCode, preview)
                        }
                        return bytes
                    }

                    let bytes: URLSession.AsyncBytes
                    do {
                        bytes = try await open(
                            Self.promptCachingEnabled ? systemPrompt : systemPrompt.withoutCacheControl
                        )
                    } catch AnthropicError.http(let status, let preview)
                        where Self.isCacheControlRejection(status: status, body: preview) {
                        Self.disablePromptCaching()
                        bytes = try await open(systemPrompt.withoutCacheControl)
                    }

                    // SSE parser ported from Services/AIStreamingService.swift.
                    // The flush-on-new-`event:` branch is load-bearing because
                    // URLSession.AsyncBytes.lines collapses consecutive
                    // newlines and never emits the blank record delimiter.
                    var currentEvent: String = "message"
                    var currentData: String = ""
                    var blocks: [Int: AccumulatingBlock] = [:]
                    // The turn's own content, rebuilt block by block, for the
                    // resume a `pause_turn` needs (#594).
                    var finished: [AnthropicJSONValue] = []
                    // `stop_reason` arrives on `message_delta`, one record
                    // BEFORE `message_stop`. It used to be dropped, so every
                    // `.done` reported `stopReason: nil` and no consumer could
                    // tell a finished turn from a truncated one (#554).
                    var terminal = TerminalSignal()

                    func flush() {
                        guard !currentData.isEmpty else {
                            currentEvent = "message"
                            return
                        }
                        Self.handle(
                            eventName: currentEvent,
                            dataLine: currentData,
                            blocks: &blocks,
                            finished: &finished,
                            terminal: &terminal,
                            continuation: continuation
                        )
                        currentEvent = "message"
                        currentData = ""
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            flush()
                            continue
                        }
                        if line.hasPrefix(":") {
                            continue
                        }
                        if line.hasPrefix("event:") {
                            if !currentData.isEmpty {
                                flush()
                            }
                            currentEvent = line.dropFirst("event:".count)
                                .trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let chunk = line.dropFirst("data:".count)
                                .trimmingCharacters(in: .whitespaces)
                            if currentData.isEmpty {
                                currentData = chunk
                            } else {
                                currentData += "\n" + chunk
                            }
                        }
                    }

                    flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Dispatch one decoded SSE record into the continuation. Kept static so
    /// the parsing has no `self` dependency and stays testable in isolation.
    private static func handle(
        eventName: String,
        dataLine: String,
        blocks: inout [Int: AccumulatingBlock],
        finished: inout [AnthropicJSONValue],
        terminal: inout TerminalSignal,
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) {
        guard let data = dataLine.data(using: .utf8) else { return }

        switch eventName {
        case "content_block_start":
            // Body: { type, index, content_block: { type, name?, ... } }
            //
            // The whole `content_block` is kept, not just its type and name: a
            // `web_search_tool_result` states its results here and nowhere else,
            // and a paused turn is replayed from these blocks (#594).
            struct Payload: Decodable {
                let index: Int
                let content_block: AnthropicJSONValue
            }
            guard let p = try? Self.decoder.decode(Payload.self, from: data),
                  let fields = p.content_block.objectValue,
                  let type = fields["type"]?.stringValue else { return }
            blocks[p.index] = AccumulatingBlock(
                type: type,
                name: fields["name"]?.stringValue,
                start: p.content_block,
                partialJSON: "",
                text: fields["text"]?.stringValue ?? ""
            )
            if type == WebSearchGrounding.resultBlockType {
                continuation.yield(
                    .webSearchResult(
                        sources: WebSearchGrounding.sources(inResultBlock: p.content_block)
                    )
                )
            }

        case "content_block_delta":
            // Body: { type, index, delta: { type, text?, partial_json? } }
            struct Payload: Decodable {
                struct Delta: Decodable {
                    let type: String
                    let text: String?
                    let partial_json: String?
                }
                let index: Int
                let delta: Delta
            }
            guard let p = try? Self.decoder.decode(Payload.self, from: data) else { return }
            switch p.delta.type {
            case "text_delta":
                if let text = p.delta.text, !text.isEmpty {
                    if var block = blocks[p.index] {
                        block.text += text
                        blocks[p.index] = block
                    }
                    continuation.yield(.textDelta(text))
                }
            case "input_json_delta":
                guard var block = blocks[p.index], let partial = p.delta.partial_json else { return }
                block.partialJSON += partial
                blocks[p.index] = block
            default:
                // Ignore unknown delta types (e.g. thinking_delta) — Phase 2
                // chat surface only consumes text + tool input.
                break
            }

        case "content_block_stop":
            struct Payload: Decodable { let index: Int }
            guard let p = try? Self.decoder.decode(Payload.self, from: data),
                  let block = blocks.removeValue(forKey: p.index) else { return }

            // Empty input is valid (zero-arg tool); fall back to {} when blank.
            let raw = block.partialJSON.isEmpty ? "{}" : block.partialJSON
            let input: AnthropicJSONValue? = raw.data(using: .utf8).flatMap {
                try? JSONDecoder().decode(AnthropicJSONValue.self, from: $0)
            }

            // Rebuild the block for the replay a paused turn needs (#594).
            // Blocks stop in the order they started, so appending preserves the
            // order the API stated them in. Thinking is deliberately absent, for
            // the reason `AnthropicMessage.assistantReplay` gives.
            switch block.type {
            case "text":
                if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finished.append(.object([
                        "type": .string("text"),
                        "text": .string(block.text)
                    ]))
                }
            case "tool_use", WebSearchGrounding.serverToolUseBlockType:
                if var fields = block.start.objectValue, let input {
                    fields["input"] = input
                    finished.append(.object(fields))
                }
            case WebSearchGrounding.resultBlockType:
                finished.append(block.start)
            default:
                break
            }

            // Only a CLIENT tool call is dispatched. A `server_tool_use` looks
            // like one and is not: Anthropic already ran it, and handing its
            // name to the draft mapper would report the turn as calling a tool
            // this app has never heard of (#594).
            guard block.type == "tool_use", let name = block.name else { return }
            guard let input else {
                NSLog("AnthropicClient.stream: dropped malformed tool input for %@", name)
                return
            }
            continuation.yield(.toolUse(name: name, input: input))

        case "message_delta":
            // Body: { type, delta: { stop_reason?, ... }, usage: { output_tokens } }
            // This is the ONLY record that carries `stop_reason` and the final
            // `output_tokens`. `message_stop` carries neither, so both are
            // cached here and yielded from the terminator below (#554).
            struct Payload: Decodable {
                struct Delta: Decodable { let stop_reason: String? }
                struct Usage: Decodable { let output_tokens: Int? }
                let delta: Delta?
                let usage: Usage?
            }
            guard let p = try? Self.decoder.decode(Payload.self, from: data) else { return }
            if let reason = p.delta?.stop_reason { terminal.stopReason = reason }
            if let tokens = p.usage?.output_tokens { terminal.outputTokens = tokens }

        case "message_start":
            // The ONLY record that carries the cache counters. `message_delta`
            // later restates `output_tokens` but not these, so they are cached
            // here and handed to the terminator (#580).
            struct Payload: Decodable {
                struct Message: Decodable { let usage: AnthropicUsage? }
                let message: Message?
            }
            guard let p = try? Self.decoder.decode(Payload.self, from: data) else { return }
            terminal.usage = p.message?.usage

        case "message_stop":
            let usage = terminal.usage?.mergingOutputTokens(terminal.outputTokens)
            Self.logUsage(usage, path: "stream")
            continuation.yield(.done(
                stopReason: terminal.stopReason,
                outputTokens: terminal.outputTokens,
                usage: usage,
                assistantContent: finished
            ))

        case "error":
            struct Payload: Decodable {
                struct Err: Decodable { let message: String? }
                let error: Err?
            }
            if let p = try? Self.decoder.decode(Payload.self, from: data) {
                continuation.yield(.error(p.error?.message ?? "Anthropic stream error"))
            } else {
                continuation.yield(.error(dataLine))
            }

        default:
            // ping / unknown: nothing to yield.
            break
        }
    }

    /// `.sortedKeys` is load-bearing for prompt caching, not cosmetic (#580).
    ///
    /// Every tool's `input_schema` is an `AnthropicJSONValue.object`, which is a
    /// Swift `Dictionary`. Swift seeds its hasher per PROCESS, so dictionary
    /// iteration order — and therefore the JSON key order `JSONEncoder` emits —
    /// is stable within one launch and different in the next one. The tool block
    /// renders at position 0 of the cached prefix, so without this the bytes
    /// would change on every app launch and the cache would miss every time the
    /// user reopened Dexter, with nothing in the response to say why.
    ///
    /// JSON objects are unordered, so sorting changes nothing the API reads.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}

// MARK: - Prompt caching (#580)

/// How long a written cache entry stays warm.
///
/// The choice is arithmetic, not taste. A write costs 1.25x the input price at
/// five minutes and 2x at one hour; a read costs about 0.1x either way, and a
/// read restarts the entry's clock for free. So the question is only how long
/// the gap between two requests that share a prefix usually is.
/// Every path ships on `fiveMinutes` today. See the note above
/// `ChatToDrafts.systemPrompt` for the table that decided it: the tool loop is
/// never fewer than two calls, so a five-minute entry already pays for itself
/// inside one capture, while an hour-long entry doubles the write price and
/// makes an isolated capture cost MORE than sending no markers at all.
enum AnthropicCacheTTL: Sendable, Equatable {
    /// The API default, so nothing is written on the wire for it.
    case fiveMinutes
    /// For a prefix that comes back 5 to 60 minutes later rather than in a
    /// burst. Nothing uses it yet; it is here so the switch is one word once
    /// `cache_read_input_tokens` says how often the prefix goes cold.
    case oneHour

    /// `nil` means "send no `ttl` field", which the API reads as five minutes.
    var wireValue: String? {
        switch self {
        case .fiveMinutes: return nil
        case .oneHour: return "1h"
        }
    }
}

/// The `system` field of a Messages request, split at the prompt-cache
/// breakpoint (#580).
///
/// Caching is a prefix match and the render order is `tools`, then `system`,
/// then `messages`. This app's assistant prompt ends in the current timestamp
/// and the user's whole SwiftData library, so a single `cache_control` marker
/// on the prompt as one string would miss on every request: `nowIso` differs
/// each time. Splitting the prompt is therefore the change; the marker is only
/// the consequence.
///
/// - `stable` is byte-identical on every request on its path and carries the
///   marker, so the cached prefix is the 28-tool block PLUS this text.
/// - `volatile` renders after the breakpoint at full price and invalidates
///   nothing, which is exactly what a timestamp should cost.
///
/// ## The split, measured 2026-09-15 (capture path)
///
///   part                       bytes    approx tokens
///   28-tool JSON block        47,545          19,000
///   stable system text        14,101           5,600
///   ---- cache breakpoint ----------------------------
///   volatile tail              2,860           1,100
///
/// Bytes are exact, from `PromptCacheShapeTests`, which encodes the SHIPPED
/// tool array and the SHIPPED prompt against a 12-task / 8-note / 1-list
/// library. Tokens are derived, not measured: `count_tokens` was not called
/// because the account balance was zero while this was built. The conversion
/// uses 2.5 bytes per token, which is what the Console request log's
/// 25,248-to-26,152 input tokens for this same request on 15 Sep 2026 implies.
///
/// So the cached prefix is about 96% of every request on this path. Once it is
/// warm, a call bills roughly 1,100 fresh tokens plus 24,600 at a tenth of the
/// input rate, in place of 25,700 at full rate.
///
/// ## One capture loop, in billed-equivalent input tokens
///
///   no cache                  51,400
///   five-minute TTL, cold     35,410   <- what ships
///   one-hour TTL, cold        53,860
///   either TTL, already warm   7,120
///
/// The loop is never fewer than two calls, so the second call reads what the
/// first one wrote and the saving lands on the very first capture.
struct AnthropicSystemPrompt: Sendable, Equatable {
    let stable: String
    let volatile: String?
    /// `nil` places no breakpoint at all. Used by callers whose prompt is too
    /// short to reach the model's minimum cacheable prefix.
    let ttl: AnthropicCacheTTL?

    init(stable: String, volatile: String? = nil, ttl: AnthropicCacheTTL? = .fiveMinutes) {
        self.stable = stable
        self.volatile = volatile
        self.ttl = ttl
    }

    /// A prompt with no breakpoint. Name the reason at the call site.
    static func uncached(_ text: String) -> AnthropicSystemPrompt {
        AnthropicSystemPrompt(stable: text, volatile: nil, ttl: nil)
    }

    /// The same prompt with the marker removed. Sent on the one retry after the
    /// API rejects `cache_control`.
    var withoutCacheControl: AnthropicSystemPrompt {
        AnthropicSystemPrompt(stable: stable, volatile: volatile, ttl: nil)
    }
}

extension AnthropicSystemPrompt: Encodable {
    private enum BlockKeys: String, CodingKey {
        case type
        case text
        case cache_control
    }

    private enum CacheKeys: String, CodingKey {
        case type
        case ttl
    }

    /// Encodes as the array-of-blocks form the API takes for `system`. One
    /// block when there is nothing volatile, two when there is.
    func encode(to encoder: Encoder) throws {
        var array = encoder.unkeyedContainer()

        var first = array.nestedContainer(keyedBy: BlockKeys.self)
        try first.encode("text", forKey: .type)
        try first.encode(stable, forKey: .text)
        if let ttl {
            var cache = first.nestedContainer(keyedBy: CacheKeys.self, forKey: .cache_control)
            try cache.encode("ephemeral", forKey: .type)
            if let wire = ttl.wireValue {
                try cache.encode(wire, forKey: .ttl)
            }
        }

        if let volatile, !volatile.isEmpty {
            var second = array.nestedContainer(keyedBy: BlockKeys.self)
            try second.encode("text", forKey: .type)
            try second.encode(volatile, forKey: .text)
        }
    }
}

extension AnthropicClient {
    private static let cachingFlagLock = NSLock()
    nonisolated(unsafe) private static var _promptCachingEnabled = true

    /// False once the API has rejected the markers in this process. Every
    /// request built after that point omits them.
    static var promptCachingEnabled: Bool {
        cachingFlagLock.lock()
        defer { cachingFlagLock.unlock() }
        return _promptCachingEnabled
    }

    static func disablePromptCaching() {
        cachingFlagLock.lock()
        _promptCachingEnabled = false
        cachingFlagLock.unlock()
        NSLog("[anthropic] API rejected cache_control; prompt caching off for this process")
    }

    /// Restores the default. Tests only — nothing in the app turns caching back
    /// on, because a rejection is a property of the account or the API version,
    /// not of one request.
    static func resetPromptCachingForTesting() {
        cachingFlagLock.lock()
        _promptCachingEnabled = true
        cachingFlagLock.unlock()
    }

    /// True when this failure is the API refusing the cache markers rather than
    /// a real problem with the request.
    ///
    /// Deliberately narrow: a 400 only, and only one that names the field. A
    /// bad tool schema or an empty text block is also a 400 and must keep
    /// failing loudly.
    static func isCacheControlRejection(status: Int, body: String) -> Bool {
        guard status == 400, promptCachingEnabled else { return false }
        return body.lowercased().contains("cache_control")
    }

    /// Prints the input split so a cache hit is observable rather than assumed.
    /// Counters only: no prompt text, no key.
    static func logUsage(_ usage: AnthropicUsage?, path: String) {
        guard let usage else { return }
        NSLog("[anthropic] %@ %@", path, usage.logLine)
    }
}

// MARK: - Error type

enum AnthropicError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Anthropic API key not configured."
        case .http(let status, let message):
            return "Anthropic API HTTP \(status): \(message)"
        case .decoding(let err):
            return "Could not parse Anthropic response. \(err.localizedDescription)"
        case .transport(let err):
            return err.localizedDescription
        }
    }
}

// MARK: - Wire types

/// Request body for `POST /v1/messages`.
struct AnthropicRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: AnthropicSystemPrompt
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]
}

/// Streaming variant of the request body. Identical to `AnthropicRequest`
/// plus the `stream: true` flag — kept as a separate struct so we don't
/// emit `stream: false` on non-streaming calls.
struct AnthropicStreamingRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: AnthropicSystemPrompt
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]
    let stream: Bool
}

/// One decoded event from the streaming endpoint. The chat surface only
/// needs four cases — text, completed tool block, terminator, error — so
/// internal SSE plumbing stays inside `AnthropicClient`.
enum AnthropicStreamEvent: Sendable {
    case textDelta(String)
    case toolUse(name: String, input: AnthropicJSONValue)
    /// A SERVER tool finished a web search inside this turn (#594).
    ///
    /// Separate from `.toolUse` on purpose: nothing on the device executes it,
    /// and a consumer that dispatched on it would look for a client tool of that
    /// name and report the turn as broken. Empty sources mean the search ran and
    /// returned nothing usable, which includes the failure shape the API answers
    /// with on an HTTP 200.
    case webSearchResult(sources: [WebSearchSource])
    /// Terminator. `stopReason` is Anthropic's own (`end_turn`, `tool_use`,
    /// `max_tokens`, `pause_turn`, …); `outputTokens` is the turn's billed
    /// output count, which the token-budget measurement in
    /// `LiveToolLoopTokenBudgetTests` reads (#554).
    ///
    /// `assistantContent` is the turn's own content array, rebuilt as raw JSON,
    /// which is what a `pause_turn` has to be handed back to be finished (#594).
    /// Thinking blocks are not in it, for the reason
    /// `AnthropicMessage.assistantReplay` states.
    case done(
        stopReason: String?,
        outputTokens: Int?,
        usage: AnthropicUsage?,
        assistantContent: [AnthropicJSONValue]
    )
    case error(String)
}

/// Per-block accumulator. We retain `type` + `name` from `content_block_start`
/// so that on `content_block_stop` we know whether to emit a `.toolUse` (for
/// `type == "tool_use"`) and have the tool's name without re-walking events.
/// What the stream learned from `message_delta` and must hand to the
/// terminator. Separate from `AccumulatingBlock` because it is per-message,
/// not per-content-block.
private struct TerminalSignal {
    var stopReason: String?
    var outputTokens: Int?
    /// Read from `message_start`, which is where the cache counters live (#580).
    var usage: AnthropicUsage?
}

private struct AccumulatingBlock {
    let type: String
    let name: String?
    /// The block exactly as `content_block_start` stated it, kept so a paused
    /// turn can be replayed verbatim (#594). For a `web_search_tool_result`
    /// this already holds the whole block: its results do not arrive as deltas.
    let start: AnthropicJSONValue
    var partialJSON: String
    /// Text accumulated from `text_delta`, which is the only part of a text
    /// block that ever arrives after its start.
    var text: String
}

/// One conversation turn. `role` is "user" or "assistant"; content is an
/// array of typed blocks (text, tool_use, tool_result).
struct AnthropicMessage: Codable {
    let role: String
    let content: [AnthropicContentBlock]
}

/// Sum type matching Anthropic's content-block tagged union. Encoder emits
/// the `{type: "...", ...}` shape; decoder accepts the same.
enum AnthropicContentBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: AnthropicJSONValue])
    case toolResult(toolUseId: String, content: String, isError: Bool)
    /// Native document block (base64). `mediaType` is "application/pdf".
    /// Used by the email path to send a PDF Claude can read when the on-device
    /// text layer is too sparse to extract (#143).
    case document(base64: String, mediaType: String)
    /// Native image block (base64). `mediaType` is e.g. "image/png".
    case image(base64: String, mediaType: String)
    /// A block replayed EXACTLY as the API stated it, carried as raw JSON
    /// (#594).
    ///
    /// Resuming a paused turn means handing the assistant's own content back
    /// unchanged, and the cases above are a lossy reading of it: a
    /// `server_tool_use` and its `web_search_tool_result` have no case here and
    /// must travel as a pair or the API rejects the replay. Round-tripping the
    /// raw value is the only shape that cannot drop a field this enum has not
    /// heard of. Never produced by the decoder, only by a caller that kept the
    /// response's own JSON.
    case raw(AnthropicJSONValue)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        // tool_result fields
        case tool_use_id
        case content
        case is_error
        // document / image fields
        case source
    }

    private enum SourceKeys: String, CodingKey {
        case type
        case media_type
        case data
    }

    func encode(to encoder: Encoder) throws {
        // Taken before the keyed container: an encoder may only hand out one
        // container, so a raw block cannot be written from inside the switch
        // below (#594).
        if case .raw(let value) = self {
            var single = encoder.singleValueContainer()
            try single.encode(value)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try c.encode("text", forKey: .type)
            try c.encode(value, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(AnthropicJSONValue.object(input), forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseId, forKey: .tool_use_id)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .is_error)
        case .document(let base64, let mediaType):
            try c.encode("document", forKey: .type)
            var src = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try src.encode("base64", forKey: .type)
            try src.encode(mediaType, forKey: .media_type)
            try src.encode(base64, forKey: .data)
        case .image(let base64, let mediaType):
            try c.encode("image", forKey: .type)
            var src = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try src.encode("base64", forKey: .type)
            try src.encode(mediaType, forKey: .media_type)
            try src.encode(base64, forKey: .data)
        case .raw:
            // Handled above, before any container was taken.
            break
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let value = try c.decode(String.self, forKey: .text)
            self = .text(value)
        case "tool_use":
            let id = try c.decode(String.self, forKey: .id)
            let name = try c.decode(String.self, forKey: .name)
            let input = try c.decode(AnthropicJSONValue.self, forKey: .input)
            if case .object(let dict) = input {
                self = .toolUse(id: id, name: name, input: dict)
            } else {
                self = .toolUse(id: id, name: name, input: [:])
            }
        case "tool_result":
            let id = try c.decode(String.self, forKey: .tool_use_id)
            let content = (try? c.decode(String.self, forKey: .content)) ?? ""
            let isError = (try? c.decode(Bool.self, forKey: .is_error)) ?? false
            self = .toolResult(toolUseId: id, content: content, isError: isError)
        default:
            // Unknown block type — treat as empty text rather than failing
            // the whole message decode.
            self = .text("")
        }
    }
}

extension AnthropicMessage {
    /// An assistant turn replayed into the next request, with empty text
    /// blocks removed.
    ///
    /// Sonnet 5 thinks by default, so a response can open with a `thinking`
    /// block. The decoder maps any block it does not model to `.text("")`
    /// rather than failing the whole message, which is right for reading a
    /// response but wrong for sending one back: the API rejects the replay
    /// with `messages: text content blocks must be non-empty` (400), and the
    /// tool loop dies on its second iteration. Both live verified 2026-09-14.
    ///
    /// The thinking text itself is not recoverable here (the decoder never
    /// kept it), so the block is dropped rather than echoed. That is accepted
    /// on this model; a model that binds tool calls to their thinking blocks
    /// would need the decoder to carry them instead.
    static func assistantReplay(_ content: [AnthropicContentBlock]) -> AnthropicMessage {
        let kept = content.filter { block in
            if case .text(let value) = block {
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
        return AnthropicMessage(role: "assistant", content: kept)
    }
}

/// Tool advertised to the model. `input_schema` is a JSON Schema object;
/// kept as `AnthropicJSONValue` so we can build it in pure Swift literals
/// without dragging in a schema library.
///
/// ### Two kinds of tool, one array (#594)
///
/// A CLIENT tool is one this app executes: it carries a name, a description and
/// a schema, and the model's call comes back for `ExecuteDraftAction` to run. A
/// SERVER tool runs inside Anthropic's own infrastructure and is declared by
/// TYPE alone, because its schema, its description and its execution all live
/// on their side. Sending a server tool the three client keys is rejected, and
/// sending a client tool a `type` is meaningless, so the two encode differently
/// and the `serverToolType` is what decides which.
struct AnthropicTool: Codable {
    let name: String
    let description: String
    let input_schema: AnthropicJSONValue

    /// Anthropic's own type string for a server tool, e.g.
    /// `web_search_20250305`. Nil for every tool this app executes itself.
    let serverToolType: String?

    /// How many times the server may run this tool in one turn. Nil sends no
    /// cap, which the API reads as its own default.
    let maxUses: Int?

    init(
        name: String,
        description: String,
        input_schema: AnthropicJSONValue,
        serverToolType: String? = nil,
        maxUses: Int? = nil
    ) {
        self.name = name
        self.description = description
        self.input_schema = input_schema
        self.serverToolType = serverToolType
        self.maxUses = maxUses
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case input_schema
        case type
        case max_uses
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if let serverToolType {
            try c.encode(serverToolType, forKey: .type)
            if let maxUses { try c.encode(maxUses, forKey: .max_uses) }
            return
        }
        try c.encode(description, forKey: .description)
        try c.encode(input_schema, forKey: .input_schema)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        serverToolType = try c.decodeIfPresent(String.self, forKey: .type)
        maxUses = try c.decodeIfPresent(Int.self, forKey: .max_uses)
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        input_schema = (try? c.decode(AnthropicJSONValue.self, forKey: .input_schema))
            ?? .object([:])
    }
}

/// One message-completion response. We only consume `content` and
/// `stop_reason`; usage / id / role are ignored.
struct AnthropicResponse: Decodable {
    let content: [AnthropicContentBlock]
    let stop_reason: String?
    /// Billed token counts. Optional because every stub response in the test
    /// suite predates it. Read by the token-budget measurement (#554); the app
    /// itself only needs `stop_reason`.
    let usage: AnthropicUsage?
}

/// The `usage` object on a message response.
///
/// `output_tokens` is the number the output ceiling is set from (#554). The
/// three input counters are what make prompt caching observable rather than
/// assumed (#580): a request that reads the cache reports most of its prompt
/// under `cache_read_input_tokens` and only the tail under `input_tokens`. If
/// `cache_read_input_tokens` stays zero across repeated requests, something is
/// invalidating the prefix.
///
/// Total prompt size is the SUM of the three input fields, never `input_tokens`
/// alone.
struct AnthropicUsage: Decodable, Sendable, Equatable {
    let output_tokens: Int?
    let input_tokens: Int?
    let cache_creation_input_tokens: Int?
    let cache_read_input_tokens: Int?

    init(
        output_tokens: Int? = nil,
        input_tokens: Int? = nil,
        cache_creation_input_tokens: Int? = nil,
        cache_read_input_tokens: Int? = nil
    ) {
        self.output_tokens = output_tokens
        self.input_tokens = input_tokens
        self.cache_creation_input_tokens = cache_creation_input_tokens
        self.cache_read_input_tokens = cache_read_input_tokens
    }

    /// The streaming path learns the cache counters from `message_start` and
    /// the final `output_tokens` from `message_delta`. This joins the two.
    func mergingOutputTokens(_ tokens: Int?) -> AnthropicUsage {
        AnthropicUsage(
            output_tokens: tokens ?? output_tokens,
            input_tokens: input_tokens,
            cache_creation_input_tokens: cache_creation_input_tokens,
            cache_read_input_tokens: cache_read_input_tokens
        )
    }

    /// One console line. Carries counters only — no prompt text, no key.
    var logLine: String {
        "input=\(input_tokens ?? -1) cache_write=\(cache_creation_input_tokens ?? -1) "
            + "cache_read=\(cache_read_input_tokens ?? -1) output=\(output_tokens ?? -1)"
    }
}

/// Recursive JSON value. Load-bearing because tool inputs are arbitrary
/// JSON shapes and we need to round-trip them through `Codable` without
/// per-tool struct definitions.
indirect enum AnthropicJSONValue: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case object([String: AnthropicJSONValue])
    case array([AnthropicJSONValue])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null; return
        }
        // Order matters: try Bool before Int because true/false would
        // otherwise decode as 1/0 in some JSON libraries.
        if let v = try? c.decode(Bool.self) {
            self = .bool(v); return
        }
        if let v = try? c.decode(Int.self) {
            self = .int(v); return
        }
        if let v = try? c.decode(Double.self) {
            self = .double(v); return
        }
        if let v = try? c.decode(String.self) {
            self = .string(v); return
        }
        if let v = try? c.decode([AnthropicJSONValue].self) {
            self = .array(v); return
        }
        if let v = try? c.decode([String: AnthropicJSONValue].self) {
            self = .object(v); return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unsupported JSON value"
        )
    }

    // MARK: - Convenience accessors

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    var arrayValue: [AnthropicJSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
    var objectValue: [String: AnthropicJSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
