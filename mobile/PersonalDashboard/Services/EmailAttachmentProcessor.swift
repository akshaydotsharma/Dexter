import Foundation
import PDFKit

/// Turns decoded email attachments (#143) into the text + native content
/// blocks the on-device model can read. The strategy, in order of preference:
///
///  - PDF: pull the text layer with PDFKit on-device. For the Airbnb-style
///    booking PDFs this yields the full reservation in ~1-3 KB of text — cheap,
///    no big payload. Only when the text layer is too sparse (scanned /
///    image-only PDF) do we fall back to sending the PDF as a native document
///    block so Claude can read it directly. We never ship a multi-MB
///    text-bearing PDF when PDFKit already has the text.
///  - Calendar (.ics): parse VEVENT (DTSTART/DTEND/SUMMARY/LOCATION) into
///    readable lines — the cleanest structured source when present.
///  - Image (png/jpeg, e.g. a boarding pass): send as a native image block.
///
/// Output: a text supplement (appended to the email body the model sees) plus
/// any native blocks (document/image) to include in the user message.
struct EmailAttachmentProcessor {

    struct Output {
        /// Human-readable text extracted from attachments (PDF text, parsed
        /// .ics), to append to the body the model receives.
        var extractedText: String = ""
        /// Native content blocks (document / image) to include alongside text.
        var blocks: [AnthropicContentBlock] = []
        /// Notes about anything dropped/capped, surfaced in diagnostics.
        var notes: [String] = []
    }

    /// Minimum characters of PDF text we consider "good enough" to skip the
    /// native-document fallback. Below this we treat the PDF as image-only.
    static let pdfTextThreshold = 80

    /// Cap on native document/image blocks per email to bound tokens.
    static let maxNativeBlocks = 3

    static func process(_ attachments: [EmailMessage.Attachment]) -> Output {
        var output = Output()
        var nativeCount = 0

        for att in attachments {
            if att.isPDF {
                let text = pdfText(att.data)
                if text.count >= pdfTextThreshold {
                    output.extractedText += "\n\n--- ATTACHMENT: \(att.filename) (PDF text) ---\n\(text)"
                } else if nativeCount < maxNativeBlocks {
                    // Sparse/no text layer — send the PDF natively so Claude
                    // can read the image. Bounded by maxNativeBlocks.
                    let b64 = att.data.base64EncodedString()
                    output.blocks.append(.document(base64: b64, mediaType: "application/pdf"))
                    nativeCount += 1
                    output.extractedText += "\n\n--- ATTACHMENT: \(att.filename) (PDF, no text layer — sent as document) ---"
                    output.notes.append("\(att.filename): no text layer, sent natively")
                } else {
                    output.notes.append("\(att.filename): PDF skipped (native-block cap reached)")
                }
            } else if att.isCalendar {
                let text = parseICS(att.data)
                if !text.isEmpty {
                    output.extractedText += "\n\n--- ATTACHMENT: \(att.filename) (calendar) ---\n\(text)"
                } else {
                    output.notes.append("\(att.filename): calendar had no parseable event")
                }
            } else if att.isImage, nativeCount < maxNativeBlocks {
                let mediaType = imageMediaType(att)
                if let mediaType {
                    let b64 = att.data.base64EncodedString()
                    output.blocks.append(.image(base64: b64, mediaType: mediaType))
                    nativeCount += 1
                    output.extractedText += "\n\n--- ATTACHMENT: \(att.filename) (image — sent for you to read) ---"
                } else {
                    output.notes.append("\(att.filename): unsupported image type")
                }
            } else if att.isImage {
                output.notes.append("\(att.filename): image skipped (native-block cap reached)")
            } else {
                output.notes.append("\(att.filename): unsupported type \(att.contentType)")
            }
        }
        return output
    }

    // MARK: - PDF

    /// Extract and lightly normalise the text layer of a PDF. The normalisation
    /// repairs the intra-word/number line-splitting that Airbnb's PDF layout
    /// produces (e.g. "Che\nck-in", "HM84R8E\nPN\nF") so dates and the
    /// confirmation code reassemble, while preserving paragraph breaks.
    static func pdfText(_ data: Data) -> String {
        guard let doc = PDFDocument(data: data), let raw = doc.string else { return "" }
        return normalizePDFText(raw)
    }

    static func normalizePDFText(_ raw: String) -> String {
        var s = raw
        // Join a newline that splits a word/number with no surrounding space
        // (the glyph-split artifact). Repeat to handle adjacent splits.
        let joinPattern = "([\\p{L}\\p{N}'’:])\\n([\\p{L}\\p{N}])"
        for _ in 0..<4 {
            s = s.replacingOccurrences(of: joinPattern, with: "$1$2", options: .regularExpression)
        }
        // Preserve paragraph (blank-line) breaks, collapse remaining single
        // newlines to spaces.
        s = s.replacingOccurrences(of: "\\n{2,}", with: "\u{0001}", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\u{0001}", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cap per-PDF text so a long document can't blow the prompt budget.
        return String(trimmed.prefix(6000))
    }

    // MARK: - Calendar (.ics)

    /// Parse the first VEVENT into readable lines. Handles RFC 5545 line
    /// folding (continuation lines start with a space/tab) and the common
    /// DTSTART/DTEND date formats.
    static func parseICS(_ data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8) else { return "" }
        // Unfold folded lines.
        let unfolded = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")

        var summary: String?
        var location: String?
        var start: String?
        var end: String?
        var inEvent = false

        for line in unfolded.components(separatedBy: "\n") {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VEVENT") { inEvent = true; continue }
            if upper.hasPrefix("END:VEVENT") { break }
            guard inEvent else { continue }
            // Property may have params: "DTSTART;TZID=...:20260907T140000"
            if upper.hasPrefix("SUMMARY") { summary = icsValue(line) }
            else if upper.hasPrefix("LOCATION") { location = icsValue(line) }
            else if upper.hasPrefix("DTSTART") { start = formatICSDate(icsValue(line)) }
            else if upper.hasPrefix("DTEND") { end = formatICSDate(icsValue(line)) }
        }

        guard summary != nil || start != nil else { return "" }
        var lines: [String] = []
        if let s = summary { lines.append("Event: \(s)") }
        if let s = start { lines.append("Start: \(s)") }
        if let e = end { lines.append("End: \(e)") }
        if let l = location { lines.append("Location: \(l)") }
        return lines.joined(separator: "\n")
    }

    private static func icsValue(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...])
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Render an iCal date (20260907 / 20260907T140000 / 20260907T140000Z)
    /// into a readable ISO-ish string. Falls back to the raw value.
    static func formatICSDate(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        let digits = v.replacingOccurrences(of: "Z", with: "")
        if digits.count >= 8 {
            let y = digits.prefix(4)
            let m = digits.dropFirst(4).prefix(2)
            let d = digits.dropFirst(6).prefix(2)
            if digits.contains("T") || digits.count >= 15 {
                let timePart = digits.contains("T")
                    ? String(digits.split(separator: "T").last ?? "")
                    : String(digits.dropFirst(8))
                if timePart.count >= 4 {
                    let hh = timePart.prefix(2)
                    let mm = timePart.dropFirst(2).prefix(2)
                    return "\(y)-\(m)-\(d) \(hh):\(mm)"
                }
            }
            return "\(y)-\(m)-\(d)"
        }
        return v
    }

    // MARK: - Image

    static func imageMediaType(_ att: EmailMessage.Attachment) -> String? {
        let ct = att.contentType
        if ct.contains("png") { return "image/png" }
        if ct.contains("jpeg") || ct.contains("jpg") { return "image/jpeg" }
        if ct.contains("gif") { return "image/gif" }
        if ct.contains("webp") { return "image/webp" }
        // Sniff by magic bytes as a fallback.
        let bytes = [UInt8](att.data.prefix(4))
        if bytes.count >= 4 {
            if bytes[0] == 0x89 && bytes[1] == 0x50 { return "image/png" }       // PNG
            if bytes[0] == 0xFF && bytes[1] == 0xD8 { return "image/jpeg" }       // JPEG
        }
        return nil
    }
}
