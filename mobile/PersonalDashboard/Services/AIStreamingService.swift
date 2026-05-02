import Foundation

/// Streaming consumer for `POST /api/ai/parse/stream`.
///
/// SSE wire format produced by the server:
///   event: drafts   data: {"drafts": [...]}
///   event: text     data: {"chunk": "..."}     (zero or more)
///   event: done     data: {"followUpQuestion": "...", "errors": [...]}
///   event: error    data: {"message": "..."}
///
/// The chat view model registers callbacks for each event kind. Drafts arrive
/// before the first text chunk, so the UI can render the preview cards while
/// the assistant text is still streaming in.
struct AIStreamingService: Sendable {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = AppConfig.apiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    enum StreamEvent: Sendable {
        case drafts([Draft])
        case textChunk(String)
        case done(followUpQuestion: String?, errors: [String])
        case error(String)
    }

    func parseStream(
        input: String,
        sessionId: String? = nil,
        timezone: String? = TimeZone.current.identifier
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("ai/parse/stream")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 120

                    let body = ChatRequest(input: input, sessionId: sessionId, timezone: timezone)
                    request.httpBody = try APIClient.encoder.encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw APIError.http(status: http.statusCode, message: "stream endpoint returned \(http.statusCode)")
                    }

                    // SSE record buffer. We flush on a blank line (canonical
                    // SSE delimiter), at end of stream, or when a new `event:`
                    // arrives while we already have a complete record buffered
                    // — the latter is necessary because `URLSession.AsyncBytes
                    // .lines` collapses consecutive newlines and never emits
                    // the blank line that should separate records.
                    var currentEvent: String = "message"
                    var currentData: String = ""

                    func flush() {
                        guard !currentData.isEmpty else {
                            currentEvent = "message"
                            return
                        }
                        if let event = decodeSSE(event: currentEvent, dataLine: currentData) {
                            continuation.yield(event)
                        }
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
                            // A new event header while we already have data
                            // means the prior record's blank-line delimiter
                            // was elided — dispatch what we have first.
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

                    // Flush any unterminated final record.
                    flush()

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - SSE record parsing

    private func decodeSSE(event: String, dataLine: String) -> StreamEvent? {
        guard let data = dataLine.data(using: .utf8) else { return nil }

        switch event {
        case "drafts":
            struct Payload: Decodable { let drafts: [Draft] }
            if let p = try? APIClient.decoder.decode(Payload.self, from: data) {
                return .drafts(p.drafts)
            }
        case "text":
            struct Payload: Decodable { let chunk: String }
            if let p = try? APIClient.decoder.decode(Payload.self, from: data) {
                return .textChunk(p.chunk)
            }
        case "done":
            struct Payload: Decodable {
                let followUpQuestion: String?
                let errors: [String]?
            }
            if let p = try? APIClient.decoder.decode(Payload.self, from: data) {
                return .done(followUpQuestion: p.followUpQuestion, errors: p.errors ?? [])
            }
            return .done(followUpQuestion: nil, errors: [])
        case "error":
            struct Payload: Decodable { let message: String }
            if let p = try? APIClient.decoder.decode(Payload.self, from: data) {
                return .error(p.message)
            }
            return .error(dataLine)
        default:
            return nil
        }
        return nil
    }
}
