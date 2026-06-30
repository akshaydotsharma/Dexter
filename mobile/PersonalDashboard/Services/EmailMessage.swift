import Foundation

/// Parsed view of a raw RFC 822 email: the headers we care about plus a
/// best-effort plain-text body. Booking-confirmation emails are almost always
/// multipart/alternative (text + HTML); forwarded copies wrap the real
/// content in a "Forwarded message" block or attach the original as a nested
/// message/rfc822 part. This parser digs the actual booking content out of all
/// of those shapes, decodes quoted-printable / base64, and strips HTML.
///
/// Pragmatic, not a full MIME implementation — it just needs to hand the
/// on-device LLM enough readable text to identify dates, a destination, and
/// booking details.
struct EmailMessage: Sendable {
    let messageId: String?
    let subject: String
    let from: String
    let date: String
    /// Best-effort plain-text body, decoded and tag-stripped, length-capped.
    let body: String
    /// Decoded attachments (PDF / image / calendar / etc.) found in the MIME
    /// tree (#143). Bookings frequently arrive as a PDF with a near-empty body.
    let attachments: [Attachment]

    /// One decoded attachment from the MIME tree.
    struct Attachment: Sendable {
        let filename: String
        /// Lowercased MIME type, e.g. "application/pdf", "image/png",
        /// "text/calendar".
        let contentType: String
        let data: Data

        var isPDF: Bool { contentType.contains("application/pdf") || filename.lowercased().hasSuffix(".pdf") }
        var isImage: Bool { contentType.hasPrefix("image/") }
        var isCalendar: Bool { contentType.contains("text/calendar") || filename.lowercased().hasSuffix(".ics") }
    }

    /// Stable identity for the idempotency ledger: the Message-Id header when
    /// present, else nil (caller falls back to uidvalidity:uid).
    var stableKey: String? { messageId }

    /// Parse a raw RFC 822 source string. Never throws — missing pieces just
    /// come back empty.
    static func parse(_ raw: String) -> EmailMessage {
        let (headerText, bodyText) = splitHeadersAndBody(raw)
        let headers = parseHeaders(headerText)

        let messageId = headers["message-id"].map { cleanAngleBrackets($0) }
        var subject = decodeMIMEEncodedWord(headers["subject"] ?? "")
        var from = decodeMIMEEncodedWord(headers["from"] ?? "")
        let date = headers["date"] ?? ""

        let contentType = headers["content-type"] ?? "text/plain"
        let transferEncoding = (headers["content-transfer-encoding"] ?? "").lowercased()

        var body = extractBestBody(
            bodyText: bodyText,
            contentType: contentType,
            transferEncoding: transferEncoding
        )

        // FORWARDED-MAIL HANDLING. When the user forwards a booking, the real
        // content is the quoted original, not the (often empty) top section.
        // If the body contains a "Forwarded message" block, pull the original
        // headers (Subject / From / Date) and the original body out of it.
        if let fwd = extractForwardedOriginal(from: body) {
            if !fwd.body.isEmpty { body = fwd.body }
            if let s = fwd.subject, !s.isEmpty,
               (subject.isEmpty || isForwardedSubject(subject)) {
                subject = s
            }
            if let f = fwd.from, !f.isEmpty {
                from = f  // surface the real sender (airline/hotel) for matching
            }
        }

        // Normalise a "Fwd:/Fw:" prefix away so it doesn't read as part of the
        // destination, but only if we couldn't recover the original subject.
        subject = stripForwardPrefix(subject)

        // ATTACHMENTS. Walk the MIME tree collecting decoded attachment bytes
        // (PDF / image / calendar). Bounded: at most 5, each <= 10MB.
        let attachments = collectAttachments(bodyText: bodyText, contentType: contentType)

        // Cap to keep the LLM prompt bounded. Booking emails rarely need more
        // than a few KB of meaningful text.
        let capped = String(body.prefix(8000))

        return EmailMessage(
            messageId: messageId,
            subject: subject,
            from: from,
            date: date,
            body: capped,
            attachments: attachments
        )
    }

    // MARK: - Attachment collection

    static let maxAttachments = 5
    static let maxAttachmentBytes = 10 * 1024 * 1024  // 10 MB

    /// Recursively walk the MIME tree and decode attachment parts. A part is
    /// an attachment when it has `Content-Disposition: attachment`, OR a
    /// non-text content-type with a filename (inline PDFs/images often lack an
    /// explicit disposition). Bounded by `maxAttachments` / `maxAttachmentBytes`;
    /// anything dropped is logged, never silent.
    static func collectAttachments(bodyText: String, contentType: String) -> [Attachment] {
        var out: [Attachment] = []
        walkForAttachments(bodyText: bodyText, contentType: contentType, transferEncoding: "", disposition: "", filename: nil, into: &out)
        if out.count > maxAttachments {
            NSLog("EmailMessage: capping attachments %d -> %d", out.count, maxAttachments)
            out = Array(out.prefix(maxAttachments))
        }
        return out
    }

    private static func walkForAttachments(
        bodyText: String,
        contentType: String,
        transferEncoding: String,
        disposition: String,
        filename: String?,
        into out: inout [Attachment]
    ) {
        let lowerType = contentType.lowercased()

        if lowerType.contains("multipart/") {
            guard let boundary = boundary(from: contentType) else { return }
            for part in splitMultipart(bodyText, boundary: boundary) {
                let (partHeaders, partBody) = splitHeadersAndBody(part)
                let h = parseHeaders(partHeaders)
                let ct = h["content-type"] ?? "text/plain"
                let enc = (h["content-transfer-encoding"] ?? "").lowercased()
                let disp = (h["content-disposition"] ?? "").lowercased()
                let name = filenameFromHeaders(h)
                walkForAttachments(bodyText: partBody, contentType: ct, transferEncoding: enc, disposition: disp, filename: name, into: &out)
            }
            return
        }

        guard out.count < maxAttachments else { return }

        let isAttachmentDisposition = disposition.contains("attachment")
        let isNonTextWithName = !lowerType.hasPrefix("text/")
            && !lowerType.contains("multipart/")
            && !lowerType.contains("message/rfc822")
            && filename != nil
        // Calendar invites are text/* but we want them as structured input.
        let isCalendar = lowerType.contains("text/calendar")

        guard isAttachmentDisposition || isNonTextWithName || isCalendar else { return }

        // Decode bytes. base64 is the common case for binary; quoted-printable
        // and 7bit/8bit fall back to raw UTF-8 bytes.
        let data: Data?
        switch transferEncoding {
        case "base64":
            let cleaned = bodyText.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
            data = Data(base64Encoded: String(String.UnicodeScalarView(cleaned)), options: .ignoreUnknownCharacters)
        case "quoted-printable":
            data = decodeQuotedPrintable(bodyText).data(using: .utf8)
        default:
            data = bodyText.data(using: .utf8)
        }

        guard let bytes = data, !bytes.isEmpty else {
            NSLog("EmailMessage: dropped attachment (decode failed): %@", filename ?? lowerType)
            return
        }
        guard bytes.count <= maxAttachmentBytes else {
            NSLog("EmailMessage: dropped oversize attachment %@ (%d bytes)", filename ?? lowerType, bytes.count)
            return
        }

        let name = filename ?? defaultName(for: lowerType)
        out.append(Attachment(filename: name, contentType: lowerType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? lowerType, data: bytes))
    }

    /// Pull a filename from Content-Disposition or Content-Type name= param.
    static func filenameFromHeaders(_ h: [String: String]) -> String? {
        for key in ["content-disposition", "content-type"] {
            guard let value = h[key] else { continue }
            if let r = value.range(of: "filename=", options: .caseInsensitive) ?? value.range(of: "name=", options: .caseInsensitive) {
                var v = String(value[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("\"") {
                    v.removeFirst()
                    if let end = v.firstIndex(of: "\"") { v = String(v[..<end]) }
                } else if let end = v.firstIndex(where: { $0 == ";" || $0 == " " }) {
                    v = String(v[..<end])
                }
                let decoded = decodeMIMEEncodedWord(v)
                if !decoded.isEmpty { return decoded }
            }
        }
        return nil
    }

    private static func defaultName(for contentType: String) -> String {
        if contentType.contains("pdf") { return "attachment.pdf" }
        if contentType.contains("png") { return "image.png" }
        if contentType.contains("jpeg") || contentType.contains("jpg") { return "image.jpg" }
        if contentType.contains("calendar") { return "invite.ics" }
        return "attachment"
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

            // Collect candidate texts from every leaf/nested part, then pick
            // the richest one. A forwarded booking often leaves text/plain
            // nearly empty (just the forwarder's intro + signature) while the
            // real content sits in the HTML or the nested message/rfc822 part,
            // so "prefer text/plain unconditionally" is wrong — score instead.
            var candidates: [String] = []

            for part in parts {
                let (partHeaders, partBody) = splitHeadersAndBody(part)
                let h = parseHeaders(partHeaders)
                let ct = (h["content-type"] ?? "text/plain").lowercased()
                let enc = (h["content-transfer-encoding"] ?? "").lowercased()

                if ct.contains("multipart/") {
                    let nested = extractBestBody(bodyText: partBody, contentType: ct, transferEncoding: enc)
                    if !nested.isEmpty { candidates.append(nested) }
                } else if ct.contains("message/rfc822") {
                    // The whole original email is attached here — re-parse it
                    // and take its (already best-extracted) body.
                    let inner = EmailMessage.parse(decodeBody(partBody, encoding: enc))
                    var innerText = inner.body
                    if !inner.subject.isEmpty {
                        innerText = "Subject: \(inner.subject)\n\(innerText)"
                    }
                    if !innerText.isEmpty { candidates.append(innerText) }
                } else if ct.contains("text/plain") {
                    let t = decodeBody(partBody, encoding: enc)
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        candidates.append(t)
                    }
                } else if ct.contains("text/html") {
                    let t = stripHTML(decodeBody(partBody, encoding: enc))
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        candidates.append(t)
                    }
                }
            }

            return pickRichest(candidates)
        }

        let decoded = decodeBody(bodyText, encoding: transferEncoding)
        if lowerType.contains("text/html") {
            return stripHTML(decoded)
        }
        return decoded
    }

    /// Pick the most information-dense candidate. We score by the count of
    /// "booking-ish" signals (digits, dates, times, currency, keywords) rather
    /// than raw length, so a long HTML footer/signature doesn't beat a compact
    /// confirmation. Falls back to the longest non-empty candidate.
    static func pickRichest(_ candidates: [String]) -> String {
        let cleaned = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        if cleaned.count == 1 { return cleaned[0] }

        func score(_ s: String) -> Int {
            var n = 0
            let lower = s.lowercased()
            // Booking keywords.
            for kw in ["confirmation", "booking", "reservation", "check-in", "check in",
                       "checkout", "check-out", "departure", "arrival", "flight",
                       "hotel", "itinerary", "depart", "arrive", "gate", "terminal",
                       "pnr", "boarding", "nights", "room", "guest"] {
                if lower.contains(kw) { n += 3 }
            }
            // Digits (dates, times, prices, confirmation codes).
            n += s.filter { $0.isNumber }.count / 4
            // Time/date punctuation density.
            n += s.components(separatedBy: ":").count / 2
            // Don't let a giant signature win on length alone — cap the
            // length contribution.
            n += min(s.count, 2000) / 200
            return n
        }

        return cleaned.max(by: { score($0) < score($1) }) ?? cleaned[0]
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

    // MARK: - Forwarded-message handling

    struct ForwardedOriginal {
        var subject: String?
        var from: String?
        var body: String
    }

    private static let forwardedMarkers = [
        "---------- Forwarded message ---------",
        "---------- Forwarded message ----------",
        "Begin forwarded message:",
        "-------- Original Message --------",
        "-------- Forwarded Message --------",
    ]

    /// If `text` contains a forwarded-message block, return the original's
    /// recovered Subject/From plus the body that follows the block's header
    /// lines. Apple Mail and Gmail both emit a small header table
    /// (From:/Date:/Subject:/To:) right after the marker; we lift those and
    /// treat everything after the blank line as the real content. Returns nil
    /// when no forwarded block is present.
    static func extractForwardedOriginal(from text: String) -> ForwardedOriginal? {
        guard let markerRange = firstForwardedMarkerRange(in: text) else { return nil }

        // Everything after the marker. The marker match may stop mid-line
        // (e.g. our pattern has 9 trailing dashes but the email has 10), so
        // advance to the END of the marker's line before parsing the header
        // table — otherwise the leftover dashes look like a body line.
        var afterMarker = String(text[markerRange.upperBound...])
        if let nl = afterMarker.firstIndex(of: "\n") {
            afterMarker = String(afterMarker[afterMarker.index(after: nl)...])
        }
        // De-quote ">"-prefixed lines (some clients quote the forwarded body).
        let dequoted = dequoteForwarded(afterMarker)

        var subject: String?
        var from: String?
        var bodyLines: [String] = []
        var inHeaderTable = true
        var sawHeader = false

        let lines = dequoted.components(separatedBy: "\n")
        for (i, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if inHeaderTable {
                if line.isEmpty {
                    // Blank line ends the header table — but only once we've
                    // actually seen at least one header, else keep scanning.
                    if sawHeader || i > 8 {
                        inHeaderTable = false
                    }
                    continue
                }
                let lower = line.lowercased()
                if lower.hasPrefix("subject:") {
                    subject = decodeMIMEEncodedWord(String(line.dropFirst("subject:".count)).trimmingCharacters(in: .whitespaces))
                    sawHeader = true
                    continue
                }
                if lower.hasPrefix("from:") {
                    from = decodeMIMEEncodedWord(String(line.dropFirst("from:".count)).trimmingCharacters(in: .whitespaces))
                    sawHeader = true
                    continue
                }
                if lower.hasPrefix("date:") || lower.hasPrefix("to:") || lower.hasPrefix("sent:") || lower.hasPrefix("cc:") || lower.hasPrefix("reply-to:") {
                    sawHeader = true
                    continue
                }
                // Skip pure-noise leftovers (dashes/punctuation) that some
                // clients leave around the marker, without ending the table.
                if !sawHeader, line.allSatisfy({ "-–—=*_> \t".contains($0) }) {
                    continue
                }
                // A substantive non-header line: the header table is over.
                inHeaderTable = false
                bodyLines.append(rawLine)
            } else {
                bodyLines.append(rawLine)
            }
        }

        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Only treat this as a useful forwarded original if we recovered
        // something — otherwise let the caller keep the original parse.
        if body.isEmpty && subject == nil { return nil }
        return ForwardedOriginal(subject: subject, from: from, body: body)
    }

    private static func firstForwardedMarkerRange(in text: String) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for marker in forwardedMarkers {
            if let r = text.range(of: marker) {
                if best == nil || r.lowerBound < best!.lowerBound {
                    best = r
                }
            }
        }
        // Also catch a Gmail-style "On <date>, <name> wrote:" lead-in when no
        // explicit marker exists.
        if best == nil,
           let r = text.range(of: "wrote:\n", options: .regularExpression) {
            best = r
        }
        return best
    }

    private static func dequoteForwarded(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            // Strip a single leading "> " or ">" quote marker (one level).
            if l.hasPrefix("> ") { l.removeFirst(2) }
            else if l.hasPrefix(">") { l.removeFirst() }
            return l
        }
        return lines.joined(separator: "\n")
    }

    static func isForwardedSubject(_ subject: String) -> Bool {
        let lower = subject.lowercased()
        return lower.hasPrefix("fwd:") || lower.hasPrefix("fw:") || lower.hasPrefix("fwd ") || lower.hasPrefix("[fwd")
    }

    static func stripForwardPrefix(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        // Strip repeated Fwd:/Fw:/Re: prefixes.
        var changed = true
        while changed {
            changed = false
            for prefix in ["fwd:", "fw:", "re:"] {
                if s.lowercased().hasPrefix(prefix) {
                    s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }
        return s.isEmpty ? subject.trimmingCharacters(in: .whitespaces) : s
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
        // Drop script/style/head blocks wholesale.
        text = text.replacingOccurrences(
            of: "<(script|style|head)[^>]*>[\\s\\S]*?</\\1>",
            with: " ",
            options: .regularExpression
        )
        // HTML comments (Outlook conditionals etc.).
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        // Turn block-level closers into newlines so structure survives.
        text = text.replacingOccurrences(
            of: "</(p|div|tr|li|h[1-6]|table|td)\\s*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        // Strip all remaining tags.
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode the handful of entities that actually matter.
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—",
            "&ndash;": "–", "&rarr;": "→", "&#8594;": "→",
        ]
        for (k, v) in entities {
            text = text.replacingOccurrences(of: k, with: v)
        }
        // Decode numeric entities (&#1234;) best-effort.
        text = decodeNumericEntities(text)
        // Collapse runs of whitespace / blank lines.
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var output = text
        let pattern = "&#([0-9]{1,7});"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: ns.length)).reversed()
        for m in matches {
            let numStr = ns.substring(with: m.range(at: 1))
            if let code = UInt32(numStr), let scalar = Unicode.Scalar(code) {
                let replacement = String(Character(scalar))
                output = (output as NSString).replacingCharacters(in: m.range, with: replacement)
            }
        }
        return output
    }

    static func cleanAngleBrackets(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
    }
}
