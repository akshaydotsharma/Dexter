import SwiftUI

// MARK: - MarkdownView
//
// Lightweight block-level markdown renderer used wherever assistant prose or
// note bodies are displayed (chat, draft preview cards, notes preview mode).
//
// Supported blocks:
//   - Headings: `#`, `##`, `###`
//   - Paragraphs (with inline formatting below)
//   - Unordered lists: `- `, `* `, `+ `, nested by indentation
//   - Ordered lists: `1. `, nested by indentation
//   - Blockquotes: `> `
//   - Fenced code blocks: ``` ```
//   - Thematic break: `---`, `***`, `___`
//   - Tables: GFM pipe tables (see `MarkdownTable`)
//
// Inline formatting uses Foundation's `AttributedString(markdown:)` so
// `**bold**`, `*italic*`, `` `code` `` and `[link](url)` Just Work inside
// every block type that renders inline text.

struct MarkdownView: View {
    let text: String
    var lineLimit: Int? = nil
    var bodyFont: Font = .edBody
    var bodyColor: Color = Tokens.inkSoft
    var headingColor: Color = Tokens.ink
    /// Tapping an inline image, when the host wants a full-size viewer. Nil in
    /// chat and draft previews, where an image is just something to look at.
    var onImageTap: ((String) -> Void)? = nil

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blockSpacing: CGFloat { lineLimit == nil ? 10 : 4 }

    /// Width-to-height ratio of a loaded image, falling back to square for a
    /// degenerate size so the layout cannot divide by zero.
    private func imageRatio(_ image: PlatformImage) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    /// An inline note image in rendered (preview) mode.
    ///
    /// Capped in height for the same reason the editor's attachment is: one
    /// photo should not push the rest of a note off the screen. A file that is
    /// not on this device gets an explicit tile rather than blank space, so the
    /// note still shows that something belongs there.
    @ViewBuilder
    private func inlineImage(path: String, alt: String) -> some View {
        if let url = ReceiptStorage.noteImages.load(relativePath: path),
           let platformImage = PlatformImage(contentsOfFile: url.path) {
            // The border has to hug the photo, so the photo needs a real width.
            //
            // `.resizable().aspectRatio(contentMode: .fit)` claims every point of
            // width it is offered and letterboxes itself inside, so the border ends
            // up wrapping the whole text column with the image floating in it. An
            // EXPLICIT ratio plus a height cap gives the image an ideal size, and
            // the trailing Spacer absorbs the remaining width instead of the image.
            // A photo too wide for the column still shrinks: the ratio is kept and
            // the height comes down.
            HStack(spacing: 0) {
                Image(platformImage: platformImage)
                    .resizable()
                    .aspectRatio(imageRatio(platformImage), contentMode: .fit)
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .paperBorder(Tokens.border, radius: Radius.md)
                    .accessibilityLabel(alt.isEmpty ? "Note image" : alt)
                    .onTapGesture { onImageTap?(path) }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: Space.sm) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
                Text("Image on your other device")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let inline):
            inlineText(inline)
                .font(headingFont(level: level))
                .foregroundStyle(headingColor)
                .padding(.top, 2)

        case .paragraph(let inline):
            inlineText(inline)
                .font(bodyFont)
                .foregroundStyle(bodyColor)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let items):
            // One block for the whole list, nested levels included (#459). The
            // gutter marker carries a minimum width so item text lines up down a
            // level whether the marker is a glyph or "10.".
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .foregroundStyle(Tokens.muted)
                            .monospacedDigit()
                            .frame(minWidth: 14, alignment: .leading)
                        inlineText(item.text)
                            .foregroundStyle(bodyColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
            .font(bodyFont)
            .lineLimit(lineLimit)

        case .blockquote(let inline):
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Tokens.borderStrong)
                    .frame(width: 3)
                inlineText(inline)
                    .font(bodyFont)
                    .foregroundStyle(Tokens.muted)
                    .padding(.leading, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.edMono)
                    .foregroundStyle(Tokens.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .paperBorder(Tokens.border, radius: 8)

        case .divider:
            Rectangle()
                .fill(Tokens.divider)
                .frame(height: 0.5)
                .padding(.vertical, 4)

        case .image(let path, let alt):
            inlineImage(path: path, alt: alt)

        case .table(let table):
            MarkdownTableView(
                table: table,
                bodyFont: bodyFont,
                bodyColor: bodyColor,
                headingColor: headingColor,
                rowLimit: lineLimit
            )

        case .spacer(let lines):
            // Intentional blank lines the user typed. ~18pt per blank line
            // beyond the first, on top of the normal inter-block spacing.
            Color.clear.frame(height: CGFloat(lines) * 18)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:  return .edDisplay
        case 2:  return .edTitle
        default: return .edHeading
        }
    }

    /// Render an inline string (paragraph contents, list item, heading text)
    /// with Foundation markdown applied. Falls back to plain Text if parsing
    /// fails so we never crash on malformed inline syntax.
    private func inlineText(_ source: String) -> Text {
        markdownInlineText(source)
    }
}

/// Inline markdown as a `Text`, shared by `MarkdownView`'s blocks and by the
/// table's cells. Falls back to plain text so malformed inline syntax cannot
/// crash a note.
func markdownInlineText(_ source: String) -> Text {
    if let attributed = try? AttributedString(
        markdown: source,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
    ) {
        return Text(attributed)
    }
    return Text(source)
}

// MARK: - Single-line snippet
//
// For rows where we want a one-line preview of markdown body text without
// the raw syntax bleeding through (`**bold**`, `## Heading`, `- item`).
// Picks the first non-empty line, strips block-level prefixes, then runs
// the rest through Foundation's inline markdown parser so inline
// formatting renders as styled text.

func markdownSnippetAttributed(_ source: String) -> AttributedString {
    let firstLine = source
        .components(separatedBy: .newlines)
        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        ?? source
    let stripped = stripMarkdownBlockPrefix(firstLine)
    if let attr = try? AttributedString(
        markdown: stripped,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
    ) {
        return attr
    }
    return AttributedString(stripped)
}

private func stripMarkdownBlockPrefix(_ line: String) -> String {
    var s = line.trimmingCharacters(in: .whitespaces)
    while s.hasPrefix("#") { s.removeFirst() }
    s = s.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("> ") { s.removeFirst(2) }
    else if s == ">" { s = "" }
    if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") { s.removeFirst(2) }
    else if let dot = s.firstIndex(of: "."),
            s[s.startIndex..<dot].allSatisfy({ $0.isNumber }),
            s.distance(from: s.startIndex, to: dot) >= 1 {
        let after = s.index(after: dot)
        if after < s.endIndex, s[after] == " " {
            s = String(s[s.index(after: after)...])
        }
    }
    return s
}

// MARK: - Block model

/// One line of a list, with its nesting already resolved (#459).
///
/// `marker` is what gets drawn in the gutter: a glyph for a bullet, the number
/// for an ordered item. Resolving it at parse time keeps the numbering rules
/// (restart inside a sub-list, carry on after one) in a single place rather than
/// spread across the view.
struct MarkdownListItem: Hashable {
    /// 0 for a top-level item.
    let depth: Int
    let marker: String
    /// The item's text, marker stripped, inline markdown intact.
    let text: String
}

enum MarkdownBlock: Hashable {
    case heading(level: Int, inline: String)
    case paragraph(String)
    /// A list: flat or nested, bullets or numbers or a mix of both (#459).
    case list([MarkdownListItem])
    case blockquote(String)
    case codeBlock(String)
    case divider
    case spacer(lines: Int)
    /// An inline note image (#395), referenced by its relative path.
    case image(path: String, alt: String)
    /// A GFM pipe table (#457).
    case table(MarkdownTable)
}

// MARK: - Parser

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Count the run of blank lines. A single blank is a normal block
                // separator (collapses, as in standard markdown). Two or more
                // consecutive blanks are treated as intentional vertical space —
                // the user pressed Return repeatedly — and preserved. Leading and
                // trailing blank runs are dropped so the preview has no stray
                // gap at the very top or bottom.
                var blanks = 0
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    blanks += 1
                    i += 1
                }
                if blanks >= 2, !blocks.isEmpty, i < lines.count {
                    blocks.append(.spacer(lines: blanks - 1))
                }
                continue
            }

            // Tables (#457). Checked before everything else on the line, because a
            // table is recognised by the pair of lines rather than by this one:
            // `MarkdownTable.parse` returns nil unless the next line is a real
            // separator row, which makes the check safe to run first.
            if let parsed = MarkdownTable.parse(lines, from: i) {
                blocks.append(.table(parsed.table))
                i = parsed.nextIndex
                continue
            }

            // Inline note images (#395). A line can hold text and images in any
            // order, because paste drops an image wherever the cursor happened to
            // be, so split the line into its runs rather than assuming an image
            // sits alone. Images are block-level here, as they are in Apple Notes.
            if trimmed.contains("](note-images/") {
                for segment in NoteBodyMarkdown.segments(in: raw) {
                    switch segment {
                    case .text(let run):
                        let t = run.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { blocks.append(.paragraph(t)) }
                    case .image(let path, let alt):
                        blocks.append(.image(path: path, alt: alt))
                    }
                }
                i += 1
                continue
            }

            // Fenced code block: consume until the closing fence (or EOF).
            if trimmed.hasPrefix("```") {
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
                i += 1
                continue
            }

            if let h = headingMatch(trimmed) {
                blocks.append(.heading(level: h.level, inline: h.text))
                i += 1
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    let stripped = t == ">" ? "" : String(t.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                    quoteLines.append(stripped)
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: " ")))
                continue
            }

            // Lists (#459). Parsed off the RAW line, because the leading
            // whitespace IS the nesting: trimming first is exactly what used to
            // flatten every sub-list into its parent.
            //
            // One block per run of list lines whatever the markers are. A
            // numbered sub-list belongs to the bullet above it, and starting a
            // new block at each change of marker would open a gap between them.
            if MarkdownListSyntax.parse(raw) != nil {
                var resolver = MarkdownListSyntax.DepthResolver()
                var counters: [Int: Int] = [:]
                var items: [MarkdownListItem] = []

                while i < lines.count {
                    guard let parsed = MarkdownListSyntax.parse(lines[i]) else {
                        // A SINGLE blank line between items does not end a list
                        // — it is a loose list, and it is how people actually
                        // write one. Ending the run there would restart the
                        // depth stack, so an indented item after a blank line
                        // came out at depth 0 with its indent read and then
                        // discarded one line later.
                        //
                        // Two or more blanks still close it: that is the
                        // deliberate vertical space handled at the top of this
                        // loop, and the note editor preserves it everywhere.
                        if lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                           i + 1 < lines.count,
                           MarkdownListSyntax.parse(lines[i + 1]) != nil {
                            i += 1
                            continue
                        }
                        break
                    }
                    let depth = resolver.depth(forWidth: parsed.indentWidth)
                    // Coming back out closes every sub-list deeper than this, so
                    // the next one to open there numbers from its own start.
                    counters = counters.filter { $0.key <= depth }

                    let marker: String
                    switch parsed.marker {
                    case .bullet:
                        marker = bulletGlyphs[depth % bulletGlyphs.count]
                        // A bullet at this level ends any numbering at it.
                        counters[depth] = nil
                    case .number(let typed):
                        // Seed from the number the user typed, so a list that
                        // resumes at "2." after an intervening sub-list carries
                        // on instead of restarting at 1.
                        let number = counters[depth] ?? typed
                        marker = "\(number)."
                        counters[depth] = number + 1
                    }

                    items.append(MarkdownListItem(
                        depth: depth, marker: marker, text: parsed.content
                    ))
                    i += 1
                }

                blocks.append(.list(items))
                continue
            }

            // Paragraph: consume consecutive non-blank, non-special lines.
            var paragraphLines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if isSpecialLine(t) { break }
                // A table header is an ordinary-looking line; only the separator
                // row below it gives the table away, so this needs the lookahead
                // that `isSpecialLine` cannot do on a single line (#457).
                if MarkdownTable.isStart(lines, at: i) { break }
                paragraphLines.append(t)
                i += 1
            }
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            }
        }

        return blocks
    }

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level >= 1, level <= 3 else { return nil }
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[line.index(after: idx)...])
            .trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    /// Gutter glyph per level, cycled so adjacent levels read apart at a glance.
    /// The three Apple Notes uses.
    private static let bulletGlyphs = ["•", "◦", "▪"]

    private static func isSpecialLine(_ line: String) -> Bool {
        if line.isEmpty { return true }
        if line.hasPrefix("#") { return headingMatch(line) != nil }
        if line.hasPrefix(">") { return true }
        if MarkdownListSyntax.parse(line) != nil { return true }
        if line.hasPrefix("```") { return true }
        if line == "---" || line == "***" || line == "___" { return true }
        return false
    }
}
