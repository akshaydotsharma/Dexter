import SwiftUI

// MARK: - MarkdownTable (#457)
//
// GFM pipe tables for note bodies. The renderer in `MarkdownView` had no table
// case, so a table fell through to the paragraph rule and every row joined into
// one run-together line with literal `|` characters.
//
// A table is a header row, a separator row that declares the column alignments,
// and the data rows that follow:
//
//     | Bucket   | Question it answers          | Metrics |
//     |----------|:----------------------------:|--------:|
//     | Activity | Are users coming back?       | DAU     |
//
// Both the model and the view live here rather than in `MarkdownView` because
// the layout needs its own state (the measured container width), and a table is
// the only block that does.

// MARK: - Model

enum MarkdownTableAlignment: Hashable {
    case leading
    case center
    case trailing
}

struct MarkdownTable: Hashable {
    var headers: [String]
    var alignments: [MarkdownTableAlignment]
    var rows: [[String]]
}

// MARK: - Parsing

extension MarkdownTable {
    /// Is there a table starting at `index`?
    ///
    /// Requires a separator row on the very next line declaring exactly as many
    /// columns as the header. GFM demands that match, and holding to it is what
    /// keeps an ordinary sentence that happens to contain a pipe from turning
    /// the line below it into a table.
    static func isStart(_ lines: [String], at index: Int) -> Bool {
        guard index >= 0, index + 1 < lines.count else { return false }
        let header = lines[index]
        guard header.contains("|") else { return false }
        guard let alignments = alignments(fromSeparator: lines[index + 1]) else { return false }
        return splitCells(header).count == alignments.count
    }

    /// Parse the table starting at `index`, returning it with the index of the
    /// first line after it. Nil when `index` does not start a table.
    static func parse(_ lines: [String], from index: Int) -> (table: MarkdownTable, nextIndex: Int)? {
        guard isStart(lines, at: index),
              let alignments = alignments(fromSeparator: lines[index + 1])
        else { return nil }

        let headers = splitCells(lines[index])
        var rows: [[String]] = []
        var i = index + 2

        // The body runs until a blank line or a line that is not a table row.
        // Requiring a pipe is what stops the table from swallowing the prose
        // that follows it.
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|") else { break }
            rows.append(normalise(splitCells(lines[i]), toColumns: headers.count))
            i += 1
        }

        return (MarkdownTable(headers: headers, alignments: alignments, rows: rows), i)
    }

    /// Split one row into its cells.
    ///
    /// The outer pipes are optional in GFM and carry no cell of their own, so
    /// they come off before the split. `\|` is an escaped pipe inside a cell,
    /// not a delimiter.
    static func splitCells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false

        for character in body {
            if escaped {
                // Only the pipe is escapable here. Any other backslash pair is
                // left as the user typed it, so inline markdown downstream still
                // sees its own escapes.
                if character == "|" {
                    current.append("|")
                } else {
                    current.append("\\")
                    current.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "|" {
                cells.append(current)
                current = ""
                continue
            }
            current.append(character)
        }

        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The column alignments a separator row declares, or nil if the line is not
    /// a separator row. `:---` is leading, `:---:` is center, `---:` is trailing.
    static func alignments(fromSeparator line: String) -> [MarkdownTableAlignment]? {
        let cells = splitCells(line)
        guard !cells.isEmpty else { return nil }

        var out: [MarkdownTableAlignment] = []
        for cell in cells {
            guard isSeparatorCell(cell) else { return nil }
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right {
                out.append(.center)
            } else if right {
                out.append(.trailing)
            } else {
                out.append(.leading)
            }
        }
        return out
    }

    private static func isSeparatorCell(_ cell: String) -> Bool {
        var body = cell
        if body.hasPrefix(":") { body.removeFirst() }
        if body.hasSuffix(":") { body.removeLast() }
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }

    /// Square a data row up against the header's column count.
    ///
    /// A short row is padded with empty cells. A long row's surplus is folded
    /// into its last column: GFM discards it, but a note is the user's own
    /// writing, so showing what they typed beats matching the spec exactly.
    static func normalise(_ cells: [String], toColumns count: Int) -> [String] {
        guard count > 0 else { return cells }
        if cells.count == count { return cells }
        if cells.count < count {
            return cells + Array(repeating: "", count: count - cells.count)
        }
        var out = Array(cells.prefix(count - 1))
        out.append(cells[(count - 1)...].joined(separator: " "))
        return out
    }
}

// MARK: - View

struct MarkdownTableView: View {
    let table: MarkdownTable
    var bodyFont: Font = .edBody
    var bodyColor: Color = Tokens.inkSoft
    var headingColor: Color = Tokens.ink
    /// Cap on data rows, for the preview cards that hand `MarkdownView` a line
    /// limit and have to stay preview-sized.
    var rowLimit: Int? = nil

    /// Width of the space the table is offered, measured from the scroll view's
    /// own frame rather than its content, so reading it cannot feed back into
    /// the column widths it decides.
    @State private var availableWidth: CGFloat = 0

    /// No column is squeezed below this, whatever its share works out to.
    private static let columnFloor: CGFloat = 64
    /// Width each column would like before the table starts scrolling.
    private static let columnTarget: CGFloat = 110
    /// Character counts outside this range stop pulling on a column's share, so
    /// one very long cell cannot starve every other column.
    private static let weightRange: ClosedRange<CGFloat> = 8...60

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            rows
                .frame(width: contentWidth, alignment: .leading)
        }
        .background(alignment: .topLeading) { widthProbe }
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    // MARK: Layout

    private var columnCount: Int { max(table.headers.count, 1) }

    private var visibleRows: [[String]] {
        guard let rowLimit else { return table.rows }
        return Array(table.rows.prefix(max(rowLimit, 1)))
    }

    private var hiddenRowCount: Int { table.rows.count - visibleRows.count }

    /// The table's own width. It takes the width on offer, and grows past it —
    /// scrolling horizontally — only when the columns cannot fit in it. Nil
    /// until the first measurement, so the very first pass lays out at the
    /// natural width instead of collapsing to nothing.
    private var contentWidth: CGFloat? {
        guard availableWidth > 0 else { return nil }
        return max(availableWidth, CGFloat(columnCount) * Self.columnTarget)
    }

    /// Share the width out by how much text each column actually holds, so a
    /// "Bucket" column does not take the same room as a column of sentences.
    /// Every column keeps `columnFloor` first, and only the remainder is split.
    private var columnWidths: [CGFloat]? {
        guard let total = contentWidth else { return nil }
        let weights = columnWeights
        let totalWeight = weights.reduce(0, +)
        let extra = max(0, total - CGFloat(columnCount) * Self.columnFloor)
        guard totalWeight > 0 else {
            return Array(repeating: total / CGFloat(columnCount), count: columnCount)
        }
        return weights.map { Self.columnFloor + extra * ($0 / totalWeight) }
    }

    private var columnWeights: [CGFloat] {
        (0..<columnCount).map { column in
            var longest = 0
            if table.headers.indices.contains(column) {
                longest = table.headers[column].count
            }
            for row in table.rows where row.indices.contains(column) {
                longest = max(longest, row[column].count)
            }
            return min(max(CGFloat(longest), Self.weightRange.lowerBound), Self.weightRange.upperBound)
        }
    }

    private func width(ofColumn column: Int) -> CGFloat? {
        guard let widths = columnWidths, widths.indices.contains(column) else { return nil }
        return widths[column]
    }

    /// Measures the viewport, not the content. `.task(id:)` runs after the view
    /// update, so assigning state here cannot mutate it mid-layout.
    private var widthProbe: some View {
        GeometryReader { geometry in
            Color.clear
                .task(id: geometry.size.width) { availableWidth = geometry.size.width }
        }
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 0) {
            row(cells: table.headers, isHeader: true)
            ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, cells in
                rule
                row(cells: cells, isHeader: false)
            }
            if hiddenRowCount > 0 {
                rule
                Text("+\(hiddenRowCount) more")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Tokens.border)
            .frame(height: 0.5)
    }

    private func row(cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { column in
                if column > 0 {
                    Rectangle()
                        .fill(Tokens.border)
                        .frame(width: 0.5)
                        .frame(maxHeight: .infinity)
                }
                cell(
                    text: cells.indices.contains(column) ? cells[column] : "",
                    column: column,
                    isHeader: isHeader
                )
            }
        }
        .background(isHeader ? Tokens.paper2 : Color.clear)
    }

    private func cell(text: String, column: Int, isHeader: Bool) -> some View {
        markdownInlineText(text)
            .font(isHeader ? .edBodyMedium : bodyFont)
            .foregroundStyle(isHeader ? headingColor : bodyColor)
            .multilineTextAlignment(textAlignment(ofColumn: column))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: width(ofColumn: column), alignment: frameAlignment(ofColumn: column))
    }

    private func alignment(ofColumn column: Int) -> MarkdownTableAlignment {
        table.alignments.indices.contains(column) ? table.alignments[column] : .leading
    }

    private func textAlignment(ofColumn column: Int) -> TextAlignment {
        switch alignment(ofColumn: column) {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(ofColumn column: Int) -> Alignment {
        switch alignment(ofColumn: column) {
        case .leading:  return .topLeading
        case .center:   return .top
        case .trailing: return .topTrailing
        }
    }
}
