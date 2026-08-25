import Foundation

// MARK: - MarkdownListSyntax
//
// One place that understands how a list line is spelled in markdown, shared by
// the renderer (`MarkdownView`) and by both editors (`MarkdownEditor`, iOS and
// macOS). Before #459 each of them had its own half of this and none of them
// looked at indentation, which is why a note could only ever hold one flat level
// of bullets.
//
// ## Nesting is indentation, not the marker character
//
// `-`, `*` and `+` are three spellings of the same bullet. What puts an item a
// level down is the whitespace in front of it:
//
//     - Parent
//       - Child
//         - Grandchild
//
// The editors write `indentUnit` (two spaces) per level. Other producers use
// other widths — the Apple Notes importer emits four — so nothing here assumes a
// fixed width. `DepthResolver` derives depth from the ORDER of the widths it
// sees, which is what real markdown does, so a 2-space note and a 4-space note
// both nest correctly and a note that mixes them does not collapse.
enum MarkdownListSyntax {

    /// What the editors insert for one level of nesting.
    static let indentUnit = "  "

    /// How far the editors will indent. A cap only on what we WRITE: a deeper
    /// list arriving from elsewhere still renders at its own depth.
    static let maxDepth = 6

    /// Columns a tab is worth when measuring indentation.
    private static let tabWidth = 4

    enum Marker: Hashable {
        /// `-`, `*` or `+`, carrying which one was typed so it round-trips.
        case bullet(Character)
        case number(Int)
    }

    /// A parsed list line, split so any part can be rebuilt without disturbing
    /// the rest of it.
    struct Line: Hashable {
        /// Leading whitespace, kept verbatim rather than normalised: rewriting a
        /// line the user did not touch is an edit, and sync sees edits.
        let indent: String
        let marker: Marker
        /// The marker including its trailing space: `"- "`, `"12. "`.
        let raw: String
        /// Everything after the marker.
        let content: String

        /// Indent measured in columns, with tabs expanded.
        var indentWidth: Int { MarkdownListSyntax.indentWidth(of: indent) }

        /// True when the item has a marker but nothing written after it. This is
        /// the state Return acts on: it means the user is done with this level.
        var isEmpty: Bool { content.trimmingCharacters(in: .whitespaces).isEmpty }

        var isOrdered: Bool {
            if case .number = marker { return true }
            return false
        }

        /// The marker that opens the next item at this same depth. Bullets
        /// repeat; numbers increment.
        var nextMarker: String {
            switch marker {
            case .bullet(let char): return "\(char) "
            case .number(let value): return "\(value + 1). "
            }
        }

        /// The whole line, rebuilt.
        var text: String { indent + raw + content }

        /// A copy at a different indent, and optionally renumbered.
        func with(indent newIndent: String, number: Int? = nil) -> Line {
            guard let number, case .number = marker else {
                return Line(indent: newIndent, marker: marker, raw: raw, content: content)
            }
            return Line(
                indent: newIndent, marker: .number(number),
                raw: "\(number). ", content: content
            )
        }
    }

    // MARK: - Parsing

    /// Parse `line` as a list item, or nil if it is not one.
    ///
    /// A marker needs its trailing space: `"-"` alone is a line of text (and,
    /// on its own, a thematic break), not an empty bullet.
    static func parse(_ line: String) -> Line? {
        let indentEnd = line.firstIndex(where: { !$0.isWhitespace || $0.isNewline }) ?? line.endIndex
        let indent = String(line[line.startIndex..<indentEnd])
        let rest = line[indentEnd...]

        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            return Line(
                indent: indent,
                marker: .bullet(bullet.first!),
                raw: bullet,
                content: String(rest.dropFirst(bullet.count))
            )
        }

        var idx = rest.startIndex
        var digits = 0
        while idx < rest.endIndex, rest[idx].isNumber, digits < 3 {
            digits += 1
            idx = rest.index(after: idx)
        }
        guard digits >= 1, idx < rest.endIndex, rest[idx] == "." else { return nil }
        let space = rest.index(after: idx)
        guard space < rest.endIndex, rest[space] == " " else { return nil }
        guard let number = Int(rest[rest.startIndex..<idx]) else { return nil }
        return Line(
            indent: indent,
            marker: .number(number),
            raw: String(rest[rest.startIndex...space]),
            content: String(rest[rest.index(after: space)...])
        )
    }

    /// Indentation of `whitespace` in columns, tabs expanded.
    static func indentWidth(of whitespace: String) -> Int {
        whitespace.reduce(0) { total, char in
            total + (char == "\t" ? tabWidth : 1)
        }
    }

    // MARK: - Depth

    /// Turns the indent widths of a run of list lines into levels.
    ///
    /// Widths are read as a stack rather than divided by a fixed unit, so the
    /// same note nests correctly whether it was written with two spaces, four,
    /// or tabs. A width deeper than the current level opens one; a shallower one
    /// closes back to whichever level it matches.
    struct DepthResolver {
        private var widths: [Int] = []

        init() {}

        mutating func depth(forWidth width: Int) -> Int {
            while let last = widths.last, width < last { widths.removeLast() }
            if let last = widths.last {
                if width == last { return widths.count - 1 }
                widths.append(width)
                return widths.count - 1
            }
            widths.append(width)
            return 0
        }
    }

    // MARK: - Indent and outdent

    /// `line` moved one level deeper, or nil when it cannot move: it is not a
    /// list line, or it is already at `maxDepth`.
    ///
    /// The first item of a list stays put. Markdown has nothing for it to nest
    /// under, and CommonMark reads an indented first item as part of the
    /// preceding paragraph, so indenting it would change what the note means.
    static func indent(line: String, previous: String?) -> String? {
        guard let parsed = parse(line) else { return nil }
        guard let previous, let above = parse(previous) else { return nil }
        // Only one level deeper than the item above: markdown has no way to
        // express a jump, and a renderer would flatten it back anyway.
        guard parsed.indentWidth <= above.indentWidth else { return nil }
        guard parsed.indentWidth < indentWidth(of: String(repeating: indentUnit, count: maxDepth))
        else { return nil }
        return parsed.with(indent: parsed.indent + indentUnit).text
    }

    /// `line` moved one level out, or nil when it is not a list line or is
    /// already at the left margin.
    static func outdent(line: String) -> String? {
        guard let parsed = parse(line), !parsed.indent.isEmpty else { return nil }
        let trimmed: String
        if parsed.indent.hasSuffix(indentUnit) {
            trimmed = String(parsed.indent.dropLast(indentUnit.count))
        } else if parsed.indent.hasSuffix("\t") {
            trimmed = String(parsed.indent.dropLast())
        } else {
            // An indent we did not write (one space, three spaces). Drop all of
            // it rather than leaving a width nothing else in the note uses.
            trimmed = ""
        }
        return parsed.with(indent: trimmed).text
    }

    /// The number an ordered item sitting at `indentWidth` should carry, given
    /// the lines above it. Used after an indent or outdent, so a moved item
    /// takes its new siblings' numbering instead of keeping the one it had.
    ///
    /// Reads backwards past deeper items (a sub-list does not interrupt its
    /// parent's count) and stops at the first thing that ends the list.
    static func orderedNumber(at indentWidth: Int, linesAbove: ArraySlice<String>) -> Int {
        for line in linesAbove.reversed() {
            guard let parsed = parse(line) else { return 1 }
            if parsed.indentWidth > indentWidth { continue }
            if parsed.indentWidth < indentWidth { return 1 }
            if case .number(let value) = parsed.marker { return value + 1 }
            return 1  // A bullet sibling: numbering starts over after it.
        }
        return 1
    }

    /// Renumber `line` for the position it now occupies. Non-ordered lines and
    /// non-list lines come back untouched.
    static func renumbered(line: String, linesAbove: ArraySlice<String>) -> String {
        guard let parsed = parse(line), parsed.isOrdered else { return line }
        let number = orderedNumber(at: parsed.indentWidth, linesAbove: linesAbove)
        return parsed.with(indent: parsed.indent, number: number).text
    }

    // MARK: - Editing

    /// A whole-text replacement plus where the caret ends up. Both editors
    /// compute their list edits this way and then apply the result, so Return,
    /// Tab and the toolbar buttons behave identically on iOS and macOS and can
    /// be tested without a text view.
    struct Edit: Equatable {
        let text: String
        let selection: NSRange
    }

    /// What Return does when the caret sits on a list line: continue the list at
    /// the same depth, or step out of it when the item is empty.
    ///
    /// Returns nil when the line is not a list item, meaning the key should do
    /// its ordinary thing.
    static func returnPressed(in text: String, replacing range: NSRange) -> Edit? {
        let ns = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        guard let item = parse(line) else { return nil }

        guard !item.isEmpty else {
            // A marker with nothing after it: the user is finished at this
            // level. Return steps out one level, and drops out of the list
            // entirely from the left margin. That way a nested list can be
            // closed with Return presses instead of hand-deleting the indent.
            let prefix = item.indent + item.raw
            let prefixRange = NSRange(
                location: lineRange.location, length: (prefix as NSString).length
            )
            var replacement = ""
            if let stepped = outdent(line: line) {
                let fixed = renumbered(
                    line: stepped, linesAbove: linesAbove(in: ns, before: lineRange.location)
                )
                replacement = parse(fixed).map { $0.indent + $0.raw } ?? ""
            }
            return Edit(
                text: ns.replacingCharacters(in: prefixRange, with: replacement),
                selection: NSRange(
                    location: prefixRange.location + (replacement as NSString).length, length: 0
                )
            )
        }

        let insertion = "\n" + item.indent + item.nextMarker
        return Edit(
            text: ns.replacingCharacters(in: range, with: insertion),
            selection: NSRange(location: range.location + (insertion as NSString).length, length: 0)
        )
    }

    /// Move every list line the selection touches one level in (`direction` > 0)
    /// or out. Returns nil when nothing moved.
    ///
    /// List lines only. Indented plain text means something else in markdown —
    /// four spaces is a code block — so a press on an ordinary line does nothing
    /// rather than quietly changing what the note says.
    static func shiftIndent(in text: String, selection: NSRange, by direction: Int) -> Edit? {
        let ns = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: selection)
        var lines = ns.substring(with: lineRange).components(separatedBy: "\n")
        let originalFirst = lines.first ?? ""
        let preceding = Array(linesAbove(in: ns, before: lineRange.location))

        var changed = false
        for idx in lines.indices {
            let line = lines[idx]
            // `lineRange` leaves a trailing empty element on a multi-line
            // selection. That is a boundary, not a line to move.
            if idx == lines.count - 1, line.isEmpty { continue }
            let previous = idx == 0 ? preceding.last : lines[idx - 1]
            let moved = direction > 0
                ? indent(line: line, previous: previous)
                : outdent(line: line)
            guard let moved else { continue }
            // Renumber against the siblings it has now, not the ones it left.
            lines[idx] = renumbered(line: moved, linesAbove: (preceding + lines[..<idx])[...])
            changed = true
        }
        guard changed else { return nil }

        let replacement = lines.joined(separator: "\n")
        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        let newSelection: NSRange
        if selection.length == 0 {
            // Every change lands at a line start, so the caret moves by exactly
            // what its own line gained or lost.
            let delta = (lines[0] as NSString).length - (originalFirst as NSString).length
            newSelection = NSRange(
                location: max(lineRange.location, selection.location + delta), length: 0
            )
        } else {
            // Keep the block selected so the button can be pressed again.
            newSelection = NSRange(
                location: lineRange.location, length: (replacement as NSString).length
            )
        }
        return Edit(text: updated, selection: newSelection)
    }

    /// The complete lines before `location`, for numbering decisions.
    private static func linesAbove(in ns: NSString, before location: Int) -> ArraySlice<String> {
        var lines = ns.substring(to: location).components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines[...]
    }
}
