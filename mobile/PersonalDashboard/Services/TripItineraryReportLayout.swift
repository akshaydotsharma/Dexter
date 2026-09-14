import CoreGraphics
import Foundation

/// Blocks and pagination for the trip itinerary report (#532).
///
/// Same shape as the expense report's layout: every block declares a fixed
/// height, and `ReportPager` packs them one page at a time. The heights here
/// are not all constants, because a stop carries a variable number of detail
/// lines — but the line COUNT is decided in `TripItineraryReport` (the wrapping
/// happens there), so every height is still known before anything renders.
///
/// Pure CoreGraphics + Foundation, no SwiftUI, so the pagination can be
/// asserted without rendering.
enum ItineraryReportBlock: Identifiable, ReportPagedBlock {
    case sectionHeader(title: String, note: String?)
    case dayHeader(title: String, subtitle: String, continued: Bool)
    case stopRow(TripItineraryReport.StopRow)
    case columnHeader(ItineraryReportColumns)
    case stayRow(TripItineraryReport.StayRow)
    case travelRow(TripItineraryReport.TravelRow)
    case note(String)
    case gap(CGFloat)

    var id: String {
        switch self {
        case .sectionHeader(let title, _):        return "section-\(title)"
        case .dayHeader(let title, _, let c):     return "day-\(title)-\(c)"
        case .stopRow(let row):                   return "stop-\(row.id)"
        case .columnHeader(let columns):          return "columns-\(columns.rawValue)"
        case .stayRow(let row):                   return "stay-\(row.id)"
        case .travelRow(let row):                 return "travel-\(row.id)"
        case .note(let text):                     return "note-\(text)"
        case .gap(let height):                    return "gap-\(height)"
        }
    }

    /// One printed line of a stop's detail (address, booking, notes).
    static let detailLineHeight: CGFloat = 13
    /// The stop's own line: time, title and kind.
    static let stopBaseHeight: CGFloat = 24

    var height: CGFloat {
        switch self {
        case .sectionHeader(_, let note): return note == nil ? 32 : 58
        case .dayHeader:                  return 28
        case .stopRow(let row):
            return Self.stopBaseHeight + CGFloat(row.details.count) * Self.detailLineHeight + 6
        case .columnHeader:               return 18
        case .stayRow(let row):           return row.detail.isEmpty ? 24 : 34
        case .travelRow(let row):         return row.detail.isEmpty ? 24 : 34
        case .note:                       return 20
        case .gap(let height):            return height
        }
    }

    var keepsWithNext: Bool {
        switch self {
        case .sectionHeader, .columnHeader, .dayHeader: return true
        default:                                        return false
        }
    }

    var isGap: Bool {
        if case .gap = self { return true }
        return false
    }

    var continuedRunHeader: ItineraryReportBlock? {
        if case .dayHeader(let title, let subtitle, _) = self {
            return .dayHeader(title: title, subtitle: subtitle, continued: true)
        }
        return nil
    }

    var continuesOpenRun: Bool {
        if case .stopRow = self { return true }
        return false
    }
}

/// Which table a `columnHeader` labels.
enum ItineraryReportColumns: String {
    case stays
    case travel

    var titles: [String] {
        switch self {
        case .stays:  return ["Stay", "Dates", "Nights"]
        case .travel: return ["Date", "Mode", "Route", "Times"]
        }
    }
}

enum TripItineraryReportPaginator {

    /// The report's three sections flattened into one ordered block stream.
    static func blocks(for report: TripItineraryReport) -> [ItineraryReportBlock] {
        var blocks: [ItineraryReportBlock] = []

        // 1. Day by day — the itinerary itself.
        blocks.append(.sectionHeader(title: "Day by day", note: TripItineraryReport.timeSentence))
        if report.days.isEmpty {
            blocks.append(.note("This trip has no stops yet."))
        }
        for day in report.days {
            blocks.append(.dayHeader(title: day.title, subtitle: day.subtitle, continued: false))
            if day.rows.isEmpty {
                // A free day still prints. An itinerary that silently skips a
                // date reads as a booking that went missing.
                blocks.append(.note("Nothing planned."))
            } else {
                blocks.append(contentsOf: day.rows.map { ItineraryReportBlock.stopRow($0) })
            }
            blocks.append(.gap(10))
        }

        // 2. Stays. Repeated out of the timeline deliberately: "which hotel,
        // which nights" is the question asked at a front desk, and answering it
        // from a day-by-day plan means reading the whole trip.
        if !report.stays.isEmpty {
            blocks.append(.gap(14))
            blocks.append(.sectionHeader(title: "Stays", note: "Where you sleep, and for how long."))
            blocks.append(.columnHeader(.stays))
            blocks.append(contentsOf: report.stays.map { ItineraryReportBlock.stayRow($0) })
        }

        // 3. Travel.
        if !report.travel.isEmpty {
            blocks.append(.gap(18))
            blocks.append(.sectionHeader(title: "Travel", note: "Every leg, in departure order."))
            blocks.append(.columnHeader(.travel))
            blocks.append(contentsOf: report.travel.map { ItineraryReportBlock.travelRow($0) })
        }

        return blocks
    }

    /// Packs the block stream into pages. A day broken across a page boundary
    /// gets its header repeated at the top of the next page, marked as a
    /// continuation, so no page of the plan is undated.
    static func pages(
        for report: TripItineraryReport,
        pageHeight: CGFloat = ReportPageMetrics.contentHeight
    ) -> [[ItineraryReportBlock]] {
        pack(blocks(for: report), pageHeight: pageHeight)
    }

    static func pack(
        _ blocks: [ItineraryReportBlock],
        pageHeight: CGFloat
    ) -> [[ItineraryReportBlock]] {
        ReportPager.pack(blocks, pageHeight: pageHeight)
    }
}
