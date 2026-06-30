import Foundation
import Network

/// A deliberately small IMAP client built directly on `Network.framework`.
///
/// Why hand-rolled instead of an SPM library: this project has zero
/// third-party dependencies, the need is narrow (LOGIN, SELECT, UID SEARCH,
/// UID FETCH, UID STORE), and a personal dev-signed app benefits from no
/// extra supply-chain surface. We speak just enough of RFC 3501 to fetch
/// forwarded booking emails and mark them seen.
///
/// Connection lifecycle: `connectAndLogin()` opens a TLS connection to
/// imap.gmail.com:993 and authenticates. The caller then issues high-level
/// operations and finally `logoutAndClose()`. All methods are async and
/// throw `IMAPError` on failure. The app password is passed in by the caller
/// (read from the Keychain) and is never logged.
actor IMAPClient {

    struct Config: Sendable {
        let host: String
        let port: Int
        let email: String
        let appPassword: String
    }

    /// One fetched message: its UID plus the raw RFC 822 source. Header/body
    /// extraction happens in `EmailMessage` so this stays transport-only.
    struct RawMessage: Sendable {
        let uid: Int
        let rawSource: String
    }

    enum IMAPError: LocalizedError {
        case connectionFailed(String)
        case timeout
        case loginFailed
        case selectFailed
        case badResponse(String)
        case notConnected

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let m): return "IMAP connection failed: \(m)"
            case .timeout:                 return "IMAP operation timed out."
            case .loginFailed:             return "IMAP login failed. Check the email and app password."
            case .selectFailed:            return "Could not open the inbox."
            case .badResponse(let m):      return "Unexpected IMAP response: \(m)"
            case .notConnected:            return "IMAP client is not connected."
            }
        }
    }

    private let config: Config
    private var connection: NWConnection?
    private var tagCounter = 0

    /// UIDVALIDITY captured from the most recent SELECT. Combined with a UID it
    /// forms a stable fallback identity when a Message-Id header is absent.
    private(set) var uidValidity: Int = 0

    /// Per-operation read timeout. Gmail is usually sub-second; a forwarded
    /// email body fetch can be a few KB. 25s is generous and still well under
    /// any background-task budget.
    private let opTimeout: TimeInterval = 25

    init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    func connectAndLogin() async throws {
        try await openConnection()
        // Server greeting (untagged "* OK ...") arrives before any command.
        _ = try await readUntilGreeting()
        try await login()
    }

    func logoutAndClose() async {
        if connection != nil {
            // Best-effort logout; ignore errors on the way out.
            _ = try? await sendCommand("LOGOUT")
        }
        connection?.cancel()
        connection = nil
    }

    // MARK: - High-level operations

    /// SELECT INBOX. Captures UIDVALIDITY for idempotency keys.
    func selectInbox() async throws {
        let resp = try await sendCommand("SELECT INBOX")
        guard resp.tagged.lowercased().contains(" ok") else {
            throw IMAPError.selectFailed
        }
        // Parse "* OK [UIDVALIDITY 1234] ..." from the untagged lines.
        for line in resp.untagged {
            if let v = Self.parseBracketedInt(line, key: "UIDVALIDITY") {
                uidValidity = v
            }
        }
    }

    /// UID SEARCH for candidate messages. We search the whole inbox (`ALL`)
    /// and let the idempotency ledger filter out anything already processed —
    /// that's more robust than relying on the \Seen flag, which the user
    /// might toggle in the Gmail app. Returns ascending UIDs.
    func searchAllUIDs() async throws -> [Int] {
        let resp = try await sendCommand("UID SEARCH ALL")
        guard resp.tagged.lowercased().contains(" ok") else {
            throw IMAPError.badResponse(resp.tagged)
        }
        // Untagged "* SEARCH 1 2 3 4"
        var uids: [Int] = []
        for line in resp.untagged {
            let upper = line.uppercased()
            guard upper.contains("SEARCH") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " })
            for p in parts {
                if let n = Int(p) { uids.append(n) }
            }
        }
        return uids.sorted()
    }

    /// UID FETCH the full RFC 822 source for one message.
    func fetchMessage(uid: Int) async throws -> RawMessage {
        // BODY.PEEK[] returns the full source without setting \Seen.
        let resp = try await sendCommand("UID FETCH \(uid) (BODY.PEEK[])")
        guard resp.tagged.lowercased().contains(" ok") else {
            throw IMAPError.badResponse(resp.tagged)
        }
        let source = Self.extractLiteral(from: resp.rawText)
        return RawMessage(uid: uid, rawSource: source)
    }

    /// Mark a message \Seen so it visibly drops out of the unread list. The
    /// idempotency ledger is the real dedup; this is a nicety for the user's
    /// inbox. Failure here is non-fatal — callers ignore the throw.
    func markSeen(uid: Int) async throws {
        let resp = try await sendCommand("UID STORE \(uid) +FLAGS (\\Seen)")
        guard resp.tagged.lowercased().contains(" ok") else {
            throw IMAPError.badResponse(resp.tagged)
        }
    }

    // MARK: - Connection

    private func openConnection() async throws {
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls)
        guard let port = NWEndpoint.Port(rawValue: UInt16(config.port)) else {
            throw IMAPError.connectionFailed("invalid port \(config.port)")
        }
        let conn = NWConnection(
            host: NWEndpoint.Host(config.host),
            port: port,
            using: params
        )
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed(let err):
                    resumed = true
                    cont.resume(throwing: IMAPError.connectionFailed(err.localizedDescription))
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: IMAPError.connectionFailed("cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
    }

    private func login() async throws {
        // Quote the email and password per IMAP string rules. App passwords
        // are alphanumeric so simple double-quoting is sufficient; we still
        // escape backslash and quote defensively.
        let user = Self.quoted(config.email)
        let pass = Self.quoted(config.appPassword)
        let resp = try await sendCommand("LOGIN \(user) \(pass)")
        guard resp.tagged.lowercased().contains(" ok") else {
            throw IMAPError.loginFailed
        }
    }

    // MARK: - Command/response engine

    private struct CommandResponse {
        /// The full decoded text of everything read for this command.
        let rawText: String
        /// Untagged lines (starting with "* ").
        let untagged: [String]
        /// The final tagged line ("<tag> OK/NO/BAD ...").
        let tagged: String
    }

    /// Send one command with a fresh tag and read until that tag's completion
    /// line. Handles IMAP literals ({N}) in the response by reading exactly N
    /// bytes when announced.
    private func sendCommand(_ command: String) async throws -> CommandResponse {
        guard let conn = connection else { throw IMAPError.notConnected }
        tagCounter += 1
        let tag = String(format: "A%03d", tagCounter)
        let line = "\(tag) \(command)\r\n"

        guard let data = line.data(using: .utf8) else {
            throw IMAPError.badResponse("could not encode command")
        }
        try await send(data, on: conn)
        return try await readResponse(tag: tag, on: conn)
    }

    private func send(_ data: Data, on conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Read raw bytes from the connection (one receive). Returns the chunk or
    /// nil at clean EOF.
    private func receiveChunk(on conn: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                    return
                }
                if let content, !content.isEmpty {
                    cont.resume(returning: content)
                    return
                }
                if isComplete {
                    cont.resume(returning: nil)
                    return
                }
                // Empty, not complete — treat as nothing yet; caller loops.
                cont.resume(returning: Data())
            }
        }
    }

    /// Accumulate received bytes until we see the tagged completion line for
    /// `tag` at the start of a CRLF-delimited line that is not inside a
    /// literal. We track announced literals ({N}) so a literal that happens to
    /// contain the tag text doesn't end the read early.
    private func readResponse(tag: String, on conn: NWConnection) async throws -> CommandResponse {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(opTimeout)

        while true {
            if Date() > deadline { throw IMAPError.timeout }

            if let completion = Self.findTaggedCompletion(in: buffer, tag: tag) {
                let text = String(decoding: buffer, as: UTF8.self)
                let (untagged, tagged) = Self.splitLines(text, tag: tag, taggedLine: completion)
                return CommandResponse(rawText: text, untagged: untagged, tagged: tagged)
            }

            guard let chunk = try await receiveChunk(on: conn) else {
                // EOF before completion — surface what we have.
                let text = String(decoding: buffer, as: UTF8.self)
                throw IMAPError.badResponse("connection closed mid-response: \(text.prefix(200))")
            }
            buffer.append(chunk)
        }
    }

    // MARK: - Response parsing (static, pure)

    /// Returns the tagged completion line ("<tag> OK ...") if present in the
    /// buffer, accounting for IMAP literals so we don't match the tag inside a
    /// fetched body. Returns nil until the full completion line is buffered.
    static func findTaggedCompletion(in buffer: Data, tag: String) -> String? {
        let text = String(decoding: buffer, as: UTF8.self)
        // Walk the text tracking literal byte-counts. When not inside a
        // literal, a line beginning with "<tag> " that has a CRLF after it is
        // the completion.
        var pendingLiteral = 0

        // Split into raw lines on CRLF, but honour literals.
        let lines = text.components(separatedBy: "\r\n")
        // The last element after a trailing CRLF is "", meaning the previous
        // line was fully terminated.
        for (i, line) in lines.enumerated() {
            let isTerminated = i < lines.count - 1  // a CRLF followed this line
            if pendingLiteral > 0 {
                // Consume bytes of this line against the literal.
                let bytes = line.utf8.count + (isTerminated ? 2 : 0)
                pendingLiteral -= bytes
                if pendingLiteral < 0 { pendingLiteral = 0 }
                continue
            }
            // Detect a literal announcement at end of line: {N} or {N+}
            if let n = literalSize(at: line) {
                pendingLiteral = n
            }
            if isTerminated, line.hasPrefix("\(tag) ") {
                return line
            }
        }
        return nil
    }

    /// If a line ends with an IMAP literal announcement like "{1234}" or
    /// "{1234+}", returns the byte count.
    static func literalSize(at line: String) -> Int? {
        guard line.hasSuffix("}") else { return nil }
        guard let open = line.lastIndex(of: "{") else { return nil }
        var inner = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
        if inner.hasSuffix("+") { inner.removeLast() }
        return Int(inner)
    }

    /// Split the full response text into untagged lines and the tagged line.
    static func splitLines(_ text: String, tag: String, taggedLine: String) -> (untagged: [String], tagged: String) {
        var untagged: [String] = []
        for line in text.components(separatedBy: "\r\n") {
            if line.hasPrefix("* ") {
                untagged.append(String(line.dropFirst(2)))
            }
        }
        return (untagged, taggedLine)
    }

    /// Extract the first IMAP literal payload from a FETCH response. The wire
    /// looks like:
    ///   * 1 FETCH (UID 5 BODY[] {2345}\r\n<...2345 bytes...>)\r\n
    ///   A002 OK FETCH completed\r\n
    /// We find the "{N}\r\n" announcement and return the next N bytes.
    static func extractLiteral(from text: String) -> String {
        guard let braceOpen = text.range(of: "{"),
              let braceClose = text.range(of: "}", range: braceOpen.upperBound..<text.endIndex) else {
            return ""
        }
        var sizeStr = String(text[braceOpen.upperBound..<braceClose.lowerBound])
        if sizeStr.hasSuffix("+") { sizeStr.removeLast() }
        guard let size = Int(sizeStr) else { return "" }

        // Literal payload starts right after the CRLF that follows "}".
        guard let crlf = text.range(of: "\r\n", range: braceClose.upperBound..<text.endIndex) else {
            return ""
        }
        let payloadStart = crlf.upperBound

        // Take `size` UTF-8 bytes from payloadStart. Work on the byte view to
        // get an accurate count, then decode.
        let tail = String(text[payloadStart...])
        let bytes = Array(tail.utf8)
        let take = min(size, bytes.count)
        let slice = Array(bytes[0..<take])
        return String(decoding: slice, as: UTF8.self)
    }

    static func parseBracketedInt(_ line: String, key: String) -> Int? {
        // Matches "[UIDVALIDITY 1234]" anywhere in the line.
        guard let keyRange = line.range(of: key) else { return nil }
        let after = line[keyRange.upperBound...]
        var digits = ""
        for ch in after {
            if ch == " " && digits.isEmpty { continue }
            if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }

    /// Double-quote and escape a string for use as an IMAP quoted-string.
    static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func readUntilGreeting() async throws -> String {
        guard let conn = connection else { throw IMAPError.notConnected }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(opTimeout)
        while true {
            if Date() > deadline { throw IMAPError.timeout }
            let text = String(decoding: buffer, as: UTF8.self)
            if text.contains("\r\n"), text.uppercased().contains("* OK") {
                return text
            }
            guard let chunk = try await receiveChunk(on: conn) else {
                throw IMAPError.connectionFailed("closed before greeting")
            }
            buffer.append(chunk)
        }
    }
}
