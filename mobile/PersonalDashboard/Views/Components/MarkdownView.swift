import SwiftUI

// MARK: - MarkdownView
//
// Lightweight block-level markdown renderer used wherever assistant prose or
// note bodies are displayed (chat, draft preview cards, notes preview mode).
//
// Supported blocks:
//   - Headings: `#`, `##`, `###`
//   - Paragraphs (with inline formatting below)
//   - Unordered lists: `- `, `* `, `+ `
//   - Ordered lists: `1. `
//   - Blockquotes: `> `
//   - Fenced code blocks: ``` ```
//   - Thematic break: `---`, `***`, `___`
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

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(Tokens.muted)
                        inlineText(item)
                            .foregroundStyle(bodyColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(bodyFont)
            .lineLimit(lineLimit)

        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + idx).")
                            .foregroundStyle(Tokens.muted)
                            .monospacedDigit()
                        inlineText(item)
                            .foregroundStyle(bodyColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

enum MarkdownBlock: Hashable {
    case heading(level: Int, inline: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList(start: Int, items: [String])
    case blockquote(String)
    case codeBlock(String)
    case divider
    case spacer(lines: Int)
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

            if isUnorderedItem(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isUnorderedItem(t) else { break }
                    items.append(stripUnorderedMarker(t))
                    i += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if isOrderedItem(trimmed) {
                // Start from the number the user actually typed, so a list that
                // resumes at "2." after an intervening bullet sub-list renders
                // as 2. instead of restarting at 1.
                let start = orderedStartNumber(trimmed)
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isOrderedItem(t) else { break }
                    items.append(stripOrderedMarker(t))
                    i += 1
                }
                blocks.append(.orderedList(start: start, items: items))
                continue
            }

            // Paragraph: consume consecutive non-blank, non-special lines.
            var paragraphLines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if isSpecialLine(t) { break }
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

    private static func isUnorderedItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    private static func stripUnorderedMarker(_ line: String) -> String {
        guard line.count >= 2 else { return line }
        return String(line.dropFirst(2))
    }

    private static func isOrderedItem(_ line: String) -> Bool {
        var idx = line.startIndex
        var digits = 0
        while idx < line.endIndex, line[idx].isNumber, digits < 3 {
            digits += 1
            idx = line.index(after: idx)
        }
        guard digits >= 1, idx < line.endIndex, line[idx] == "." else { return false }
        let next = line.index(after: idx)
        return next < line.endIndex && line[next] == " "
    }

    private static func stripOrderedMarker(_ line: String) -> String {
        guard let dot = line.firstIndex(of: ".") else { return line }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return line }
        return String(line[line.index(after: after)...])
    }

    /// The leading integer of an ordered-list line ("2. foo" -> 2), or 1 if it
    /// can't be parsed. Only called on lines that already pass `isOrderedItem`.
    private static func orderedStartNumber(_ line: String) -> Int {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        return Int(line[line.startIndex..<idx]) ?? 1
    }

    private static func isSpecialLine(_ line: String) -> Bool {
        if line.isEmpty { return true }
        if line.hasPrefix("#") { return headingMatch(line) != nil }
        if line.hasPrefix(">") { return true }
        if isUnorderedItem(line) { return true }
        if isOrderedItem(line) { return true }
        if line.hasPrefix("```") { return true }
        if line == "---" || line == "***" || line == "___" { return true }
        return false
    }
}
