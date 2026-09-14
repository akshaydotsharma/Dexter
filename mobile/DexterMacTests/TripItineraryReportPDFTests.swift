import PDFKit
import XCTest
@testable import DexterMac

/// The itinerary report actually becomes a PDF (#532).
///
/// The model tests prove what the document says; this proves it can be handed
/// to someone. `ImageRenderer` into a PDF `CGContext` fails in ways a compile
/// cannot catch — a zero-size media box, a page that never begins — and all of
/// them produce a file rather than an error.
///
/// Set `DEXTER_REPORT_PDF_OUT` to a directory to keep a copy for eyeballing.
@MainActor
final class TripItineraryReportPDFTests: XCTestCase {

    private let tripID = UUID()

    private func day(_ value: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = value
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components) ?? Date()
    }

    private func time(_ dayOfMonth: Int, _ hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = dayOfMonth
        components.hour = hour
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components) ?? Date()
    }

    /// A trip long enough to run past one page, with the awkward stops in it: a
    /// ticketed flight, a multi-day stay, untimed activities, and long notes.
    private func fixture(stops: Int) -> [LocalItineraryItem] {
        var meta = TicketMeta()
        meta.airline = "Singapore Airlines"
        meta.flightNumber = "SQ 366"
        meta.originCode = "SIN"
        meta.destinationCode = "FCO"

        var items: [LocalItineraryItem] = [
            LocalItineraryItem(
                tripUUID: tripID,
                dayDate: day(3),
                kind: .transport,
                transportMode: .flight,
                title: "Singapore to Rome",
                startTime: time(3, 10),
                arrivalTime: time(3, 17),
                seat: "12A",
                gate: "B22",
                ticketMetaJSON: meta.encodedString()
            ),
            LocalItineraryItem(
                tripUUID: tripID,
                dayDate: day(3),
                kind: .stay,
                title: "207 Inn",
                startTime: time(3, 19),
                endDate: day(9),
                endTime: time(9, 11),
                address: "Via Nazionale 207, Rome"
            )
        ]

        items.append(contentsOf: (0..<stops).map { index in
            LocalItineraryItem(
                tripUUID: tripID,
                dayDate: day(3 + index % 7),
                kind: [.activity, .place, .restaurant][index % 3],
                title: "Stop \(index)",
                notes: index % 4 == 0
                    ? "Booked for two. The entrance is on the far side of the square, past the fountain, and the staff will ask for the name on the reservation."
                    : "",
                startTime: index % 3 == 0 ? time(3 + index % 7, 9 + index % 8) : nil,
                address: index % 2 == 0 ? "Piazza \(index), Rome" : ""
            )
        })
        return items
    }

    private func report(stops: Int, notes: Bool = true, references: Bool = true) -> TripItineraryReport {
        let items = fixture(stops: stops)
        var buckets: [Date: [TimelineEntry]] = [:]
        for item in items {
            let inDay = WallClock.startOfStoredDay(item.dayDate)
            if item.kindEnum == .stay, let end = item.endDate {
                let outDay = WallClock.startOfStoredDay(end)
                buckets[inDay, default: []].append(.stayCheckIn(item: item))
                if outDay != inDay { buckets[outDay, default: []].append(.stayCheckOut(item: item)) }
            } else {
                buckets[inDay, default: []].append(.single(item: item))
            }
        }
        // Sorted the way the timeline sorts a day: untimed first, then by time.
        let days = buckets.keys.sorted().map { day -> (day: Date, entries: [TimelineEntry]) in
            let entries = buckets[day] ?? []
            let sorted = entries.sorted { lhs, rhs in
                switch (lhs.effectiveTime, rhs.effectiveTime) {
                case (nil, nil):   return lhs.item.sortOrder < rhs.item.sortOrder
                case (nil, _):     return true
                case (_, nil):     return false
                case let (l?, r?): return l < r
                }
            }
            return (day: day, entries: sorted)
        }

        return TripItineraryReport.make(
            TripItineraryReportInput(
                tripName: "Italy",
                startDate: day(3),
                endDate: day(9),
                days: days,
                includeNotes: notes,
                includeReferences: references,
                exportDate: day(14)
            )
        )
    }

    // MARK: - Tests

    func testEveryReportOpensWithACoverPage() throws {
        let data = try TripItineraryReportPDF.data(for: report(stops: 6))
        let document = try XCTUnwrap(PDFDocument(data: data), "Not a readable PDF")
        XCTAssertGreaterThanOrEqual(document.pageCount, 2, "A cover, then at least one body page")

        let cover = try XCTUnwrap(document.page(at: 0)).string ?? ""
        XCTAssertTrue(cover.contains("Italy"))
        XCTAssertTrue(cover.uppercased().contains("TRIP ITINERARY"))
        XCTAssertTrue(cover.uppercased().contains("DAYS"))
        XCTAssertTrue(cover.uppercased().contains("WHAT'S ON IT"))
        XCTAssertFalse(cover.uppercased().contains("DAY BY DAY"), "The plan starts on its own page")
    }

    /// A4 at 72 points per inch. A reader that resizes the page would reflow
    /// nothing, because the layout is baked, so the media box has to be right.
    func testEveryPageIsA4() throws {
        let data = try TripItineraryReportPDF.data(for: report(stops: 60))
        let document = try XCTUnwrap(PDFDocument(data: data))

        for index in 0..<document.pageCount {
            let bounds = try XCTUnwrap(document.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, ReportPageMetrics.width, accuracy: 0.5)
            XCTAssertEqual(bounds.height, ReportPageMetrics.height, accuracy: 0.5)
        }
    }

    /// The text stays text. A screenshot-per-page export would still open, look
    /// fine, and be unsearchable — which is only detectable by asking for the
    /// string back. It matters more here than in the ledger: what people look
    /// for in an itinerary is one line of it.
    func testTheReportIsSelectableTextNotAPictureOfText() throws {
        let made = report(stops: 24)
        let data = try TripItineraryReportPDF.data(for: made)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = document.string ?? ""
        let upper = text.uppercased()

        XCTAssertTrue(text.contains("Italy"), "The trip name should be readable text")
        XCTAssertTrue(upper.contains("DAY BY DAY"), "Headings must survive extraction")
        XCTAssertTrue(upper.contains("STAYS"))
        XCTAssertTrue(upper.contains("TRAVEL"))
        XCTAssertTrue(text.contains("207 Inn"))
        XCTAssertTrue(text.contains("SIN → FCO"))
        XCTAssertTrue(text.contains("Via Nazionale 207"))
        // Times and dates are the reason `.monospacedDigit()` is off in the
        // page views: with it on, these render but extract blank.
        XCTAssertTrue(text.contains("Check-in"), "Stay times must be selectable text")
        XCTAssertTrue(text.contains("Seat 12A"), "Booking details must be selectable text")

        if let out = ProcessInfo.processInfo.environment["DEXTER_REPORT_PDF_OUT"] {
            let url = URL(fileURLWithPath: out).appendingPathComponent(made.fileName)
            try? data.write(to: url)
        }
    }

    func testTheTogglesDecideWhatTheFileCarries() throws {
        let quiet = try TripItineraryReportPDF.data(for: report(stops: 24, notes: false, references: false))
        let text = try XCTUnwrap(PDFDocument(data: quiet)).string ?? ""

        XCTAssertFalse(text.contains("Seat 12A"), "Seats were turned off")
        XCTAssertFalse(text.contains("past the fountain"), "Notes were turned off")
        // The plan itself is still all there.
        XCTAssertTrue(text.contains("207 Inn"))
        XCTAssertTrue(text.contains("Via Nazionale 207"))
    }

    func testALongTripPaginatesRatherThanTruncating() throws {
        let short = try TripItineraryReportPDF.data(for: report(stops: 6))
        let long = try TripItineraryReportPDF.data(for: report(stops: 120))

        let shortPages = try XCTUnwrap(PDFDocument(data: short)).pageCount
        let longPages = try XCTUnwrap(PDFDocument(data: long)).pageCount
        XCTAssertGreaterThan(longPages, shortPages)

        // The last stop has to be in the file, not off the bottom of page 1.
        let text = try XCTUnwrap(PDFDocument(data: long)).string ?? ""
        XCTAssertTrue(text.contains("Stop 119"))
    }

    func testTheFileIsWrittenUnderItsOwnName() throws {
        let made = report(stops: 4)
        let url = try TripItineraryReportPDF.write(made)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.lastPathComponent, made.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(PDFDocument(url: url))
    }
}
