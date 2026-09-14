import CoreGraphics
import Foundation

/// Page geometry shared by every exported Dexter report (#528, #532).
///
/// Lived in `TripExpenseReportLayout.swift` until the itinerary report needed
/// the same page. Nothing about it was ever expense-specific.
enum ReportPageMetrics {
    /// A4 at 72 points per inch. The report is read on a phone and printed in
    /// Europe and Asia far more often than on US Letter.
    static let width: CGFloat = 595
    static let height: CGFloat = 842
    static let margin: CGFloat = 44
    static let footerHeight: CGFloat = 26

    static var contentWidth: CGFloat { width - margin * 2 }
    /// The vertical room a page has for blocks, once the footer is reserved.
    static var contentHeight: CGFloat { height - margin * 2 - footerHeight }
}

/// One fixed-height unit of a report body, as the pager needs to see it (#532).
///
/// A report declares its own block enum — the expense report's rows are
/// nothing like the itinerary's — and conforms it here. The packing itself is
/// the same problem both times, and it is the part with the traps in it: the
/// orphan rule, the gap-at-the-top rule, and restating a day header on the page
/// its rows spill onto. Written twice, those drift.
protocol ReportPagedBlock {
    /// The room this block takes. Fixed: the unit of packing is the row, so
    /// nothing is ever cut in half.
    var height: CGFloat { get }

    /// Blocks that must not be the last thing on a page. A section heading or a
    /// day heading alone at the foot of a page is an orphan: the reader turns
    /// over to find out what it introduced.
    var keepsWithNext: Bool { get }

    /// A gap at the very top of a fresh page is wasted space.
    var isGap: Bool { get }

    /// The form this block takes when the run it heads spills onto a second
    /// page ("Wed 3 Jun 2026 (continued)"). Nil for a block that heads no run.
    var continuedRunHeader: Self? { get }

    /// True for a row that belongs to the run the last header opened, so a page
    /// break in the middle of the run can restate that header.
    var continuesOpenRun: Bool { get }
}

/// Packs a block stream into pages (#528, #532).
enum ReportPager {

    static func pack<Block: ReportPagedBlock>(_ blocks: [Block], pageHeight: CGFloat) -> [[Block]] {
        var pages: [[Block]] = []
        var page: [Block] = []
        var used: CGFloat = 0
        /// The run currently being listed, already in its continued form, so a
        /// break mid-run can restate it.
        var openHeader: Block?

        var index = 0
        while index < blocks.count {
            let block = blocks[index]

            // A block that must stay with what follows it reserves room for the
            // whole run, so a heading never lands alone at the foot of a page.
            var needed = block.height
            var lookahead = index
            while blocks[lookahead].keepsWithNext, lookahead + 1 < blocks.count {
                lookahead += 1
                needed += blocks[lookahead].height
            }

            if used + needed > pageHeight, !page.isEmpty {
                pages.append(page)
                page = []
                used = 0

                // Never open a page with whitespace.
                if block.isGap { index += 1; continue }

                // Carry the run heading over so a continuation page still says
                // which day its rows belong to.
                if block.continuesOpenRun, let header = openHeader {
                    page.append(header)
                    used += header.height
                }
            }

            if let continued = block.continuedRunHeader {
                openHeader = continued
            } else if !block.continuesOpenRun, !block.isGap {
                openHeader = nil
            }

            page.append(block)
            used += block.height
            index += 1
        }

        if !page.isEmpty { pages.append(page) }
        return pages
    }
}

/// The name an exported report lands on disk with (#528, #532).
///
/// "Italy itinerary 2026-09-14.pdf". Anything a file system would object to is
/// collapsed, so a trip called "Rome / Milan" still saves.
enum ReportFileName {
    static func make(tripName: String, subject: String, on date: Date) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd"

        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = tripName
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let name = cleaned.isEmpty ? "Trip" : cleaned
        return "\(name) \(subject) \(stamp.string(from: date)).pdf"
    }
}
