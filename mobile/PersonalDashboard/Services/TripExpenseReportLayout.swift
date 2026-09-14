import CoreGraphics
import Foundation

/// Page geometry and pagination for the trip expense report (#528).
///
/// The report is a document, not a scroll view, so the layout is decided here
/// rather than by SwiftUI. Every block declares a fixed height, the paginator
/// fills one page at a time, and a block that does not fit starts the next
/// page. Nothing is ever cut in half: the unit of packing IS the row.
///
/// Pure CoreGraphics + Foundation, no SwiftUI, so the pagination can be
/// asserted without rendering.
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

/// One fixed-height unit of the report body. The cover is not a block: it is
/// its own page with its own layout.
enum ReportBlock: Identifiable {
    case sectionHeader(title: String, note: String?)
    case caveat(String)
    case dayHeader(title: String, total: String, continued: Bool)
    case ledgerRow(TripExpenseReport.LedgerRow)
    case columnHeader(ReportColumns)
    case participantRow(TripExpenseReport.ParticipantRow)
    case transferRow(TripExpenseReport.TransferRow)
    case categoryRow(TripExpenseReport.CategoryRow)
    case currencyRow(TripExpenseReport.CurrencyRow)
    case note(String)
    case gap(CGFloat)

    var id: String {
        switch self {
        case .sectionHeader(let title, _):     return "section-\(title)"
        case .caveat(let text):                return "caveat-\(text)"
        case .dayHeader(let title, _, let c):  return "day-\(title)-\(c)"
        case .ledgerRow(let row):              return "row-\(row.id)"
        case .columnHeader(let columns):       return "columns-\(columns.rawValue)"
        case .participantRow(let row):         return "party-\(row.id)"
        case .transferRow(let row):            return "transfer-\(row.id)"
        case .categoryRow(let row):            return "category-\(row.id)"
        case .currencyRow(let row):            return "currency-\(row.id)"
        case .note(let text):                  return "note-\(text)"
        case .gap(let height):                 return "gap-\(height)"
        }
    }

    var height: CGFloat {
        switch self {
        // A note is allowed two lines: the settlement note is a full sentence
        // and clipping it mid-clause loses the half that matters.
        case .sectionHeader(_, let note):  return note == nil ? 32 : 58
        case .caveat:                      return 18
        case .dayHeader:                   return 26
        // Two lines: the bill on top, the category / payer / split beneath.
        case .ledgerRow:                   return 32
        case .columnHeader:                return 18
        case .participantRow:              return 22
        case .transferRow:                 return 22
        case .categoryRow:                 return 24
        case .currencyRow:                 return 22
        case .note:                        return 20
        case .gap(let height):             return height
        }
    }

    /// Blocks that must not be the last thing on a page. A section heading or a
    /// day heading alone at the foot of a page is an orphan: the reader turns
    /// over to find out what it introduced.
    var keepsWithNext: Bool {
        switch self {
        case .sectionHeader, .columnHeader, .dayHeader, .caveat: return true
        default:                                                 return false
        }
    }

    /// A gap at the very top of a fresh page is wasted space.
    var isGap: Bool {
        if case .gap = self { return true }
        return false
    }
}

/// Which table a `columnHeader` labels.
enum ReportColumns: String {
    case participants
    case categories
    case currencies

    var titles: [String] {
        switch self {
        case .participants: return ["Person", "Paid", "Spent", "Net"]
        case .categories:   return ["Category", "Share", "Total", "Count"]
        case .currencies:   return ["Currency", "Total", "Rate used"]
        }
    }
}

enum TripExpenseReportPaginator {

    /// The report's six sections flattened into one ordered block stream.
    static func blocks(for report: TripExpenseReport) -> [ReportBlock] {
        var blocks: [ReportBlock] = []

        // 2. Daily ledger.
        blocks.append(.sectionHeader(title: "Daily ledger", note: report.ledgerNote))
        if report.ledger.isEmpty {
            blocks.append(.note("No expenses match this filter."))
        }
        for day in report.ledger {
            blocks.append(.dayHeader(title: day.title, total: day.total, continued: false))
            blocks.append(contentsOf: day.rows.map { ReportBlock.ledgerRow($0) })
            blocks.append(.gap(10))
        }

        // 3. Participant breakdown.
        blocks.append(.gap(14))
        blocks.append(.sectionHeader(title: "Participant breakdown", note: report.settlementNote))
        if let caveat = report.settlementCaveat {
            blocks.append(.caveat(caveat))
        }
        blocks.append(.columnHeader(.participants))
        blocks.append(contentsOf: report.participants.map { ReportBlock.participantRow($0) })

        // 4. Who pays whom.
        blocks.append(.gap(18))
        blocks.append(.sectionHeader(title: "Who pays whom", note: "The smallest set of payments that clears every balance."))
        if report.transfers.isEmpty {
            blocks.append(.note("Everyone is settled up. No payments are needed."))
        } else {
            blocks.append(contentsOf: report.transfers.map { ReportBlock.transferRow($0) })
        }

        // 5. Category analysis.
        blocks.append(.gap(18))
        blocks.append(.sectionHeader(title: "Category analysis", note: "Every expense on the trip, by category."))
        blocks.append(.columnHeader(.categories))
        blocks.append(contentsOf: report.categories.map { ReportBlock.categoryRow($0) })

        // 6. Currency table. Omitted on a single-currency trip already written
        // in the report's currency.
        if !report.currencies.isEmpty {
            blocks.append(.gap(18))
            blocks.append(.sectionHeader(title: "Currencies", note: "What was spent in each currency, and the rate the trip converts it with."))
            blocks.append(.columnHeader(.currencies))
            blocks.append(contentsOf: report.currencies.map { ReportBlock.currencyRow($0) })
        }

        return blocks
    }

    /// Packs the block stream into pages. A day broken across a page boundary
    /// gets its header repeated at the top of the next page, marked as a
    /// continuation, so no page of the ledger is undated.
    static func pages(
        for report: TripExpenseReport,
        pageHeight: CGFloat = ReportPageMetrics.contentHeight
    ) -> [[ReportBlock]] {
        pack(blocks(for: report), pageHeight: pageHeight)
    }

    static func pack(_ blocks: [ReportBlock], pageHeight: CGFloat) -> [[ReportBlock]] {
        var pages: [[ReportBlock]] = []
        var page: [ReportBlock] = []
        var used: CGFloat = 0
        /// The day currently being listed, so a break mid-day can restate it.
        var openDay: (title: String, total: String)?

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

                // Carry the day heading over so a continuation page still says
                // which day its rows belong to.
                if case .ledgerRow = block, let day = openDay {
                    let header = ReportBlock.dayHeader(title: day.title, total: day.total, continued: true)
                    page.append(header)
                    used += header.height
                }
            }

            switch block {
            case .dayHeader(let title, let total, _): openDay = (title, total)
            case .ledgerRow:                          break
            case .gap:                                break
            default:                                  openDay = nil
            }

            page.append(block)
            used += block.height
            index += 1
        }

        if !page.isEmpty { pages.append(page) }
        return pages
    }
}
