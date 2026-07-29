import Foundation

/// Converts an Apple Notes body into Dexter markdown (#396).
///
/// Pure string work with no AppleScript and no SwiftData, which is the point: the
/// conversion is the part most likely to be subtly wrong, and this way it is
/// unit-testable without a Notes library or a store.
///
/// ## What the input actually looks like
///
/// Measured against a real 324-note library on 2026-07-30. The vocabulary is
/// small and regular, because Notes generates it rather than accepting arbitrary
/// HTML: `div` per line, `br`, `ul`/`ol`/`li`, `h1`–`h3`, `b`, `i`, `u`,
/// `strike`, `font`, and `img`. That library contained no `<a href>` and no
/// `<table>` at all, but both are handled anyway since they cost little.
///
/// Two findings drive the design:
///
/// 1. **Images are inlined as base64 data URIs, in document position.** So the
///    body alone carries both the picture and where it belongs, and there is no
///    need to walk `attachments` separately. It also means body size tracks
///    inlined image bytes: one note with five uncompressed TIFF scans came back
///    as 32 MB of HTML, while a note with twenty PDF attachments was 64 KB,
///    because PDFs are NOT inlined.
/// 2. **The leading `<h1>` repeats the note's own title.** Emitting it as body
///    text would leave every imported note with its title duplicated on line one.
enum AppleNotesHTMLConverter {

    /// One image pulled out of a note body, in document order.
    struct ExtractedImage: Equatable {
        /// Decoded bytes, still in the original encoding (often TIFF or PNG).
        let data: Data
        /// Zero-based position among the images in this note, which is what the
        /// caller uses to fill in the real relative path after saving.
        let index: Int
    }

    struct Result {
        /// Markdown body. Image positions hold `{{dexter-image-N}}` placeholders.
        let markdown: String
        /// The title lifted from a leading `<h1>`, when there was one.
        let title: String?
        let images: [ExtractedImage]
        /// Attachments referenced by the note that are not inline images, e.g.
        /// PDFs and scanned documents. Reported so the import can say what it
        /// could not bring across rather than silently dropping it.
        let nonImageAttachmentCount: Int
    }

    /// Placeholder written where an image belongs, replaced once the bytes have
    /// been compressed and saved and their relative path is known.
    ///
    /// Deliberately not markdown: if a later step fails, a leftover
    /// `{{dexter-image-0}}` is obviously a bug, where a leftover `![](…)`
    /// pointing at nothing would look like a broken image and could be mistaken
    /// for data loss.
    static func placeholder(_ index: Int) -> String { "{{dexter-image-\(index)}}" }

    // MARK: - Entry point

    static func convert(html: String, attachmentCount: Int = 0) -> Result {
        var working = html

        // 1. Pull images out FIRST, before any other rewriting. A base64 payload
        //    can be tens of megabytes and can contain sequences that look like
        //    markup to a later regex, so it must not still be present when the
        //    tag rewriting runs.
        var images: [ExtractedImage] = []
        working = extractImages(from: working, into: &images)

        // 2. Lift a leading <h1> as the title.
        var title: String?
        (working, title) = liftLeadingHeading(working)

        // 3. Structure, then inline styling, then entities.
        working = convertBlocks(working)
        working = convertInline(working)
        working = stripRemainingTags(working)
        working = decodeEntities(working)
        working = tidyWhitespace(working)

        return Result(
            markdown: working,
            title: title,
            images: images,
            // Every inline image is an attachment; anything left over is not an
            // image. Clamped at zero because the count is reported by Notes
            // separately and the two could disagree on a malformed note.
            nonImageAttachmentCount: max(0, attachmentCount - images.count)
        )
    }

    // MARK: - Images

    /// Replace every `<img src="data:image/…;base64,…">` with a placeholder,
    /// collecting the decoded bytes in document order.
    private static func extractImages(
        from html: String, into images: inout [ExtractedImage]
    ) -> String {
        // Scanned rather than regexed. A 32 MB base64 run inside a regex engine is
        // a pathological input for backtracking, and `NSRegularExpression` on a
        // string that size is both slow and memory-hungry; a single forward pass
        // is linear and predictable.
        var out = ""
        var cursor = html.startIndex
        var index = 0

        while let tagStart = html.range(of: "<img", range: cursor..<html.endIndex),
              let tagEnd = html.range(of: ">", range: tagStart.upperBound..<html.endIndex) {
            out += html[cursor..<tagStart.lowerBound]
            let tag = String(html[tagStart.lowerBound..<tagEnd.upperBound])

            if let data = base64Payload(in: tag) {
                images.append(ExtractedImage(data: data, index: index))
                out += placeholder(index)
                index += 1
            }
            // An <img> with no decodable payload contributes nothing rather than
            // leaving a dangling tag in the markdown.
            cursor = tagEnd.upperBound
        }
        out += html[cursor..<html.endIndex]
        return out
    }

    /// Decode the base64 body of a `data:` URI inside one `<img>` tag.
    private static func base64Payload(in tag: String) -> Data? {
        guard let base64Marker = tag.range(of: "base64,") else { return nil }
        let rest = tag[base64Marker.upperBound...]
        // The payload ends at the closing quote of the src attribute.
        let terminator = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) ?? rest.endIndex
        let encoded = rest[rest.startIndex..<terminator]
        // Notes emits unbroken base64, but tolerate whitespace so a hand-edited or
        // re-wrapped body still decodes.
        let cleaned = encoded.filter { !$0.isWhitespace }
        return Data(base64Encoded: String(cleaned), options: [.ignoreUnknownCharacters])
    }

    // MARK: - Title

    /// Take a leading `<h1>` out of the body and return it as the title.
    ///
    /// Only the FIRST heading, and only when nothing but markup precedes it. A
    /// later `<h1>` is a real section heading in the middle of a note and stays.
    private static func liftLeadingHeading(_ html: String) -> (String, String?) {
        guard let open = html.range(of: "<h1", options: [.caseInsensitive]),
              let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(
                of: "</h1>", options: [.caseInsensitive],
                range: openEnd.upperBound..<html.endIndex
              ) else {
            return (html, nil)
        }
        // Anything textual before the heading means this is not the title line.
        let prefix = String(html[html.startIndex..<open.lowerBound])
        guard tidyWhitespace(decodeEntities(stripRemainingTags(prefix))).isEmpty else {
            return (html, nil)
        }

        let inner = String(html[openEnd.upperBound..<close.lowerBound])
        let title = tidyWhitespace(decodeEntities(stripRemainingTags(inner)))
        var remainder = String(html[html.startIndex..<open.lowerBound])
        remainder += html[close.upperBound...]
        return (remainder, title.isEmpty ? nil : title)
    }

    // MARK: - Blocks

    private static func convertBlocks(_ html: String) -> String {
        var s = html

        // Headings. h1 here is a mid-note heading, since a leading one became the
        // title. Closing tags become a newline so the next block starts cleanly.
        for (tag, hashes) in [("h1", "#"), ("h2", "##"), ("h3", "###"),
                              ("h4", "####"), ("h5", "#####"), ("h6", "######")] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>", with: "\n\(hashes) ",
                options: [.regularExpression, .caseInsensitive]
            )
            s = s.replacingOccurrences(
                of: "</\(tag)>", with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Ordered vs unordered list items. Every `<li>` is marked with a sentinel
        // first, then numbered in a second pass, because the marker depends on
        // which list encloses it and a plain replacement cannot see that.
        s = markListItems(s)

        // Line and block breaks.
        s = s.replacingOccurrences(
            of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        // A `<div>` per line is how Notes writes paragraphs, so the CLOSING tag is
        // the line break. Opening tags would double every gap.
        s = s.replacingOccurrences(
            of: "</div>", with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: "</p>", with: "\n\n", options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: "<hr[^>]*>", with: "\n\n---\n\n", options: [.regularExpression, .caseInsensitive]
        )
        // Blockquotes: mark the lines inside so the prefix survives tag stripping.
        s = s.replacingOccurrences(
            of: "<blockquote[^>]*>", with: "\n> ", options: [.regularExpression, .caseInsensitive]
        )
        return s
    }

    /// Turn `<li>` into a markdown marker, choosing bullet or number by the
    /// enclosing list, and numbering ordered items as it goes.
    private static func markListItems(_ html: String) -> String {
        var out = ""
        var cursor = html.startIndex
        // Stack of enclosing lists, so a nested list restores its parent's kind on
        // close. Depth also sets the indent.
        struct ListContext {
            let ordered: Bool
            let checklist: Bool
            var counter: Int
        }
        var listStack: [ListContext] = []

        func nextTag(from index: String.Index) -> Range<String.Index>? {
            guard let open = html.range(of: "<", range: index..<html.endIndex),
                  let close = html.range(of: ">", range: open.upperBound..<html.endIndex)
            else { return nil }
            return open.lowerBound..<close.upperBound
        }

        while let tagRange = nextTag(from: cursor) {
            out += html[cursor..<tagRange.lowerBound]
            let tag = html[tagRange].lowercased()

            if tag.hasPrefix("<ul") {
                // A checklist is an unordered list carrying a class; only the item
                // marker differs, so the kind is recorded and used per item below.
                listStack.append(ListContext(
                    ordered: false,
                    checklist: isChecklist(String(html[tagRange])),
                    counter: 0
                ))
                out += "\n"
            } else if tag.hasPrefix("<ol") {
                listStack.append(ListContext(ordered: true, checklist: false, counter: 0))
                out += "\n"
            } else if tag.hasPrefix("</ul") || tag.hasPrefix("</ol") {
                if !listStack.isEmpty { listStack.removeLast() }
                out += "\n"
            } else if tag.hasPrefix("<li") {
                let depth = max(0, listStack.count - 1)
                let indent = String(repeating: "    ", count: depth)
                guard !listStack.isEmpty else {
                    // A stray `<li>` with no enclosing list. Treated as a bullet
                    // rather than dropped, so its text survives.
                    out += "\n- "
                    cursor = tagRange.upperBound
                    continue
                }
                var top = listStack.removeLast()
                top.counter += 1
                listStack.append(top)
                if top.checklist {
                    out += "\n\(indent)- [ ] "
                } else if top.ordered {
                    out += "\n\(indent)\(top.counter). "
                } else {
                    out += "\n\(indent)- "
                }
            } else if tag.hasPrefix("</li") {
                // Item text ends; the next marker supplies its own newline.
            } else {
                out += html[tagRange]
            }
            cursor = tagRange.upperBound
        }
        out += html[cursor..<html.endIndex]
        return out
    }

    private static func isChecklist(_ tag: String) -> Bool {
        tag.range(of: "checklist", options: [.caseInsensitive]) != nil
    }

    // MARK: - Inline styling

    private static func convertInline(_ html: String) -> String {
        var s = html
        // Links first: the pattern consumes the anchor's own text, so running it
        // after `<b>`/`<i>` stripping would lose emphasis inside a link.
        s = s.replacingOccurrences(
            of: "<a[^>]*href=[\"']([^\"']*)[\"'][^>]*>(.*?)</a>",
            with: "[$2]($1)",
            options: [.regularExpression, .caseInsensitive]
        )
        for (tag, marker) in [("b", "**"), ("strong", "**"), ("i", "*"), ("em", "*"),
                              ("code", "`"), ("strike", "~~"), ("s", "~~"), ("del", "~~")] {
            s = s.replacingOccurrences(
                of: "<\(tag)(\\s[^>]*)?>", with: marker,
                options: [.regularExpression, .caseInsensitive]
            )
            s = s.replacingOccurrences(
                of: "</\(tag)>", with: marker,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // `<u>` has no markdown equivalent and Dexter's renderer has no underline,
        // so the tag goes and the text stays rather than inventing syntax that
        // would render literally.
        return s
    }

    // MARK: - Cleanup

    private static func stripRemainingTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression])
    }

    /// Decode the named and numeric entities Notes might emit.
    ///
    /// The table is deliberately short. Scanning every text note in a real
    /// 324-note library (785 KB of HTML, 2026-07-30) turned up exactly ONE entity
    /// in total, a single `&quot;`: Notes writes accented letters, dashes and
    /// curly quotes as literal UTF-8 rather than escaping them. The accented
    /// entries below are therefore insurance for hand-edited or imported-from-
    /// elsewhere notes, not something the common path needs.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var s = text
        // `&amp;` LAST: decoding it first would turn `&amp;lt;` into `<`, letting
        // text that was escaped in the original become markup here.
        for (entity, replacement) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&hellip;", "…"), ("&mdash;", "—"),
            ("&ndash;", "–"), ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
            ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
            ("&eacute;", "é"), ("&egrave;", "è"), ("&agrave;", "à"),
            ("&ccedil;", "ç"), ("&ntilde;", "ñ"), ("&uuml;", "ü"),
            ("&ouml;", "ö"), ("&auml;", "ä"), ("&szlig;", "ß"),
            ("&copy;", "©"), ("&reg;", "®"), ("&trade;", "™"),
            ("&deg;", "°"), ("&pound;", "£"), ("&euro;", "€"),
            ("&bull;", "•"), ("&middot;", "·"),
            ("&amp;", "&")
        ] {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities, decimal and hex.
        s = decodeNumericEntities(s)
        return s
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        let pattern = "&#(x?)([0-9A-Fa-f]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isHex = ns.substring(with: match.range(at: 1)).lowercased() == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(value) {
                out.append(Character(scalar))
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Collapse the newline debris that per-line `<div>`s and list markup leave
    /// behind, without destroying the blank lines the user actually typed.
    private static func tidyWhitespace(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
        // Trailing spaces on a line are invisible but change markdown meaning
        // (two of them force a hard break).
        s = s.replacingOccurrences(
            of: "[ \\t]+\n", with: "\n", options: [.regularExpression]
        )
        // Three or more blank lines collapse to one blank line. Notes emits an
        // empty `<div>` per blank line and the block rules above add their own,
        // so runs build up quickly.
        s = s.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: [.regularExpression]
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
