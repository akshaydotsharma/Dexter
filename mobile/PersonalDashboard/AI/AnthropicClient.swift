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

    // TODO: streaming variant for Phase 2 (chat tokens + tool-use deltas).

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
indirect enum AnthropicJSONValue: Codable, Sendable {
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
