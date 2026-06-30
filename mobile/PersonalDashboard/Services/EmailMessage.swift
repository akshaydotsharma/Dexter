import Foundation

/// Parsed view of a raw RFC 822 email: the headers we care about plus a
/// best-effort plain-text body. Booking-confirmation emails are almost always
/// multipart/alternative (text + HTML); we prefer the text part, fall back to
/// stripping tags from the HTML part, and decode quoted-printable / base64.
///
/// This is intentionally a pragmatic parser, not a full MIME implementation —
/// it just needs to hand the on-device LLM enough readable text to identify
/// dates, a destination, and booking details.
struct EmailMessage: Sendable {
    let messageId: String?
    let subject: String
    let from: String
    let date: String
    /// Best-effort plain-text body, decoded and tag-stripped, length-capped.
    let body: String

    /// Stable identity for the idempotency ledger: the Message-Id header when
    /// present, else nil (caller falls back to uidvalidity:uid).
    var stableKey: String? { messageId }

    /// Parse a raw RFC 822 source string. Never throws — missing pieces just
    /// come back empty.
    static func parse(_ raw: String) -> EmailMessage {
        let (headerText, bodyText) = splitHeadersAndBody(raw)
        let headers = parseHeaders(headerText)

        let messageId = headers["message-id"].map { cleanAngleBrackets($0) }
        let subject = decodeMIMEEncodedWord(headers["subject"] ?? "")
        let from = decodeMIMEEncodedWord(headers["from"] ?? "")
        let date = headers["date"] ?? ""

        let contentType = headers["content-type"] ?? "text/plain"
        let transferEncoding = (headers["content-transfer-encoding"] ?? "").lowercased()

        let body = extractBestBody(
            bodyText: bodyText,
            contentType: contentType,
            transferEncoding: transferEncoding
        )

        // Cap to keep the LLM prompt bounded. Booking emails rarely need more
        // than a few KB of meaningful text.
        let capped = String(body.prefix(8000))

        return EmailMessage(
            messageId: messageId,
            subject: subject,
            from: from,
            date: date,
            body: capped
        )
    }

    // MARK: - Header / body split

    static func splitHeadersAndBody(_ raw: String) -> (headers: String, body: String) {
        // Normalise CRLF then split on the first blank line.
        let normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if let range = normalised.range(of: "\n\n") {
            let headers = String(normalised[..<range.lowerBound])
            let body = String(normalised[range.upperBound...])
            return (headers, body)
        }
        return (normalised, "")
    }

    /// Parse folded headers into a lowercased-key dictionary. Continuation
    /// lines (starting with whitespace) are unfolded onto the previous header.
    static func parseHeaders(_ headerText: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey: String?
        var currentVal = ""

        func commit() {
            if let key = currentKey {
                result[key.lowercased()] = currentVal.trimmingCharacters(in: .whitespaces)
            }
            currentKey = nil
            currentVal = ""
        }

        for line in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            let str = String(line)
            if let first = str.first, first == " " || first == "\t" {
                // Continuation of the previous header.
                currentVal += " " + str.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let colon = str.firstIndex(of: ":") {
                commit()
                currentKey = String(str[..<colon])
                currentVal = String(str[str.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        commit()
        return result
    }

    // MARK: - Body extraction

    static func extractBestBody(bodyText: String, contentType: String, transferEncoding: String) -> String {
        let lowerType = contentType.lowercased()

        if lowerType.contains("multipart/") {
            guard let boundary = boundary(from: contentType) else {
                return decodeBody(bodyText, encoding: transferEncoding)
            }
            let parts = splitMultipart(bodyText, boundary: boundary)
            // Prefer text/plain, then fall back to text/html (tag-stripped).
            var htmlFallback: String?
            for part in parts {
                let (partHeaders, partBody) = splitHeadersAndBody(part)
                let h = parseHeaders(partHeaders)
                let ct = (h["content-type"] ?? "text/plain").lowercased()
                let enc = (h["content-transfer-encoding"] ?? "").lowercased()

                if ct.contains("text/plain") {
                    return decodeBody(partBody, encoding: enc)
                }
                if ct.contains("text/html"), htmlFallback == nil {
                    htmlFallback = stripHTML(decodeBody(partBody, encoding: enc))
                }
                // Nested multipart (e.g. multipart/alternative inside
                // multipart/mixed): recurse one level.
                if ct.contains("multipart/") {
                    let nested = extractBestBody(bodyText: partBody, contentType: ct, transferEncoding: enc)
                    if !nested.isEmpty { return nested }
                }
            }
            if let html = htmlFallback { return html }
            return ""
        }

        let decoded = decodeBody(bodyText, encoding: transferEncoding)
        if lowerType.contains("text/html") {
            return stripHTML(decoded)
        }
        return decoded
    }

    static func boundary(from contentType: String) -> String? {
        // boundary="xxxx" or boundary=xxxx
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var value = String(contentType[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            value.removeFirst()
            if let end = value.firstIndex(of: "\"") {
                return String(value[..<end])
            }
            return value
        }
        // Unquoted: up to next ; or whitespace
        if let end = value.firstIndex(where: { $0 == ";" || $0 == " " }) {
            return String(value[..<end])
        }
        return value
    }

    static func splitMultipart(_ body: String, boundary: String) -> [String] {
        let delimiter = "--\(boundary)"
        var parts: [String] = []
        let chunks = body.components(separatedBy: delimiter)
        for chunk in chunks {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "--" { continue }
            // Leading "\n" after the boundary marker is part of the chunk.
            parts.append(chunk.hasPrefix("\n") ? String(chunk.dropFirst()) : chunk)
        }
        return parts
    }

    // MARK: - Decoding

    static func decodeBody(_ body: String, encoding: String) -> String {
        switch encoding {
        case "base64":
            let cleaned = body.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return body
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return body
        }
    }

    static func decodeQuotedPrintable(_ input: String) -> String {
        var result = ""
        // Join soft line breaks ("=\n").
        let unfolded = input.replacingOccurrences(of: "=\n", with: "")
            .replacingOccurrences(of: "=\r\n", with: "")
        var bytes: [UInt8] = []
        let chars = Array(unfolded)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "=", i + 2 < chars.count,
               let hi = chars[i + 1].hexDigitValue,
               let lo = chars[i + 2].hexDigitValue {
                bytes.append(UInt8(hi * 16 + lo))
                i += 3
            } else {
                bytes.append(contentsOf: Array(String(c).utf8))
                i += 1
            }
        }
        result = String(decoding: bytes, as: UTF8.self)
        return result
    }

    /// Decode RFC 2047 encoded-words in a header value
    /// ("=?UTF-8?B?...?=" / "=?UTF-8?Q?...?="). Best-effort; leaves anything
    /// it can't parse untouched.
    static func decodeMIMEEncodedWord(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var output = value
        // Repeatedly replace each encoded word.
        while let start = output.range(of: "=?"),
              let end = output.range(of: "?=", range: start.upperBound..<output.endIndex) {
            let token = String(output[start.lowerBound..<end.upperBound])
            let decoded = decodeSingleEncodedWord(token) ?? token
            output.replaceSubrange(start.lowerBound..<end.upperBound, with: decoded)
            // Avoid an infinite loop if decode produced another "=?".
            if decoded == token { break }
        }
        return output
    }

    private static func decodeSingleEncodedWord(_ token: String) -> String? {
        // =?charset?encoding?text?=
        let inner = token.dropFirst(2).dropLast(2)  // strip =? and ?=
        let parts = inner.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let encoding = parts[1].uppercased()
        let text = String(parts[2])
        if encoding == "B" {
            if let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        } else if encoding == "Q" {
            // Q-encoding: like quoted-printable but "_" means space.
            let qp = text.replacingOccurrences(of: "_", with: " ")
            return decodeQuotedPrintable(qp)
        }
        return nil
    }

    // MARK: - HTML stripping

    static func stripHTML(_ html: String) -> String {
        var text = html
        // Drop script/style blocks wholesale.
        text = text.replacingOccurrences(
            of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>",
            with: " ",
            options: .regularExpression
        )
        // Turn block-level closers into newlines so structure survives.
        text = text.replacingOccurrences(
            of: "</(p|div|tr|li|h[1-6]|table|br)\\s*/?>",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        // Strip all remaining tags.
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode the handful of entities that actually matter.
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        ]
        for (k, v) in entities {
            text = text.replacingOccurrences(of: k, with: v)
        }
        // Collapse runs of whitespace / blank lines.
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanAngleBrackets(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
    }
}
