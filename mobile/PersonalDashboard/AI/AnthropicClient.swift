import Foundation

/// Direct Anthropic Messages API client. The phone calls this in place of
/// the retired Express backend; the API key is read from `AppConfig` and
/// must never be logged. Streaming variant is Phase 2.
struct AnthropicClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let model = "claude-sonnet-4-5"
    static let anthropicVersion = "2023-06-01"
    static let maxTokens = 1024
    static let temperature = 0.3

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(
        systemPrompt: String,
        messages: [AnthropicMessage],
        tools: [AnthropicTool]
    ) async throws -> AnthropicResponse {
        guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
            throw AnthropicError.notConfigured
        }

        let body = AnthropicRequest(
            model: Self.model,
            max_tokens: Self.maxTokens,
            temperature: Self.temperature,
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
            return try Self.decoder.decode(AnthropicResponse.self, from: data)
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
    @MainActor
    func stream(
        systemPrompt: String,
        messages: [AnthropicMessage],
        tools: [AnthropicTool]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
                        throw AnthropicError.notConfigured
                    }

                    let body = AnthropicStreamingRequest(
                        model: Self.model,
                        max_tokens: Self.maxTokens,
                        temperature: Self.temperature,
                        system: systemPrompt,
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

                    // SSE parser ported from Services/AIStreamingService.swift.
                    // The flush-on-new-`event:` branch is load-bearing because
                    // URLSession.AsyncBytes.lines collapses consecutive
                    // newlines and never emits the blank record delimiter.
                    var currentEvent: String = "message"
                    var currentData: String = ""
                    var blocks: [Int: AccumulatingBlock] = [:]

                    func flush() {
                        guard !currentData.isEmpty else {
                            currentEvent = "message"
                            return
                        }
                        Self.handle(
                            eventName: currentEvent,
                            dataLine: currentData,
                            blocks: &blocks,
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
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) {
        guard let data = dataLine.data(using: .utf8) else { return }

        switch eventName {
        case "content_block_start":
            // Body: { type, index, content_block: { type, name?, ... } }
            struct Payload: Decodable {
                struct Block: Decodable {
                    let type: String
                    let name: String?
                }
                let index: Int
                let content_block: Block
            }
            guard let p = try? Self.decoder.decode(Payload.self, from: data) else { return }
            blocks[p.index] = AccumulatingBlock(
                type: p.content_block.type,
                name: p.content_block.name,
                partialJSON: ""
            )

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
            guard block.type == "tool_use", let name = block.name else { return }
            // Empty input is valid (zero-arg tool); fall back to {} when blank.
            let raw = block.partialJSON.isEmpty ? "{}" : block.partialJSON
            guard let inputData = raw.data(using: .utf8),
                  let value = try? JSONDecoder().decode(AnthropicJSONValue.self, from: inputData) else {
                NSLog("AnthropicClient.stream: dropped malformed tool input for %@", name)
                return
            }
            continuation.yield(.toolUse(name: name, input: value))

        case "message_delta":
            // Body: { type, delta: { stop_reason?, ... }, usage? }
            // We don't yield here — `message_stop` is the canonical terminator
            // and carries enough signal for our consumers.
            break

        case "message_stop":
            // No useful body fields for the chat surface; carry the stop_reason
            // through if we have one cached, otherwise nil.
            continuation.yield(.done(stopReason: nil))

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
            // message_start / ping / unknown: nothing to yield.
            break
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
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
    let temperature: Double
    let system: String
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]
}

/// Streaming variant of the request body. Identical to `AnthropicRequest`
/// plus the `stream: true` flag — kept as a separate struct so we don't
/// emit `stream: false` on non-streaming calls.
struct AnthropicStreamingRequest: Encodable {
    let model: String
    let max_tokens: Int
    let temperature: Double
    let system: String
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
    case done(stopReason: String?)
    case error(String)
}

/// Per-block accumulator. We retain `type` + `name` from `content_block_start`
/// so that on `content_block_stop` we know whether to emit a `.toolUse` (for
/// `type == "tool_use"`) and have the tool's name without re-walking events.
private struct AccumulatingBlock {
    let type: String
    let name: String?
    var partialJSON: String
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

/// Tool advertised to the model. `input_schema` is a JSON Schema object;
/// kept as `AnthropicJSONValue` so we can build it in pure Swift literals
/// without dragging in a schema library.
struct AnthropicTool: Codable {
    let name: String
    let description: String
    let input_schema: AnthropicJSONValue
}

/// One message-completion response. We only consume `content` and
/// `stop_reason`; usage / id / role are ignored.
struct AnthropicResponse: Decodable {
    let content: [AnthropicContentBlock]
    let stop_reason: String?
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
