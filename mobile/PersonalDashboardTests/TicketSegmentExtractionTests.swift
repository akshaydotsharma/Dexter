import XCTest
import PDFKit
@testable import PersonalDashboard

/// Round-trip ticket uploads (#475).
///
/// Before this, one uploaded file produced exactly one itinerary row, and only
/// page 1 of a PDF ever reached the model. A Singapore Airlines e-ticket for
/// SIN→HKG and back therefore landed the outbound leg and silently dropped the
/// return. These pin the three pieces that fix it: the `segments` array is
/// parsed, a decoded boarding pass is merged into the leg it actually describes,
/// and every page of a PDF is rendered for reading.
@MainActor
final class TicketSegmentExtractionTests: XCTestCase {

    // MARK: - Segment parsing

    private func segment(
        title: String,
        day: String,
        flight: String? = nil,
        origin: String? = nil,
        destination: String? = nil,
        start: String? = nil
    ) -> AnthropicJSONValue {
        var fields: [String: AnthropicJSONValue] = [
            "title": .string(title),
            "kind": .string("transport"),
            "mode": .string("flight"),
            "day_date": .string(day)
        ]
        if let flight { fields["flight_number"] = .string(flight) }
        if let origin { fields["origin_code"] = .string(origin) }
        if let destination { fields["destination_code"] = .string(destination) }
        if let start { fields["start_time"] = .string(start) }
        return .object(fields)
    }

    /// The defect itself: a return booking must survive as TWO segments.
    func testBothLegsOfAReturnBookingAreParsed() {
        let input: [String: AnthropicJSONValue] = [
            "segments": .array([
                segment(title: "SQ874 · SIN→HKG", day: "2026-11-12", flight: "SQ874",
                        origin: "SIN", destination: "HKG", start: "2026-11-12T07:20:00+08:00"),
                segment(title: "SQ872 · HKG→SIN", day: "2026-11-21", flight: "SQ872",
                        origin: "HKG", destination: "SIN", start: "2026-11-21T20:05:00+08:00")
            ])
        ]

        let segments = ExtractedTicket.segments(fromToolInput: input)

        XCTAssertEqual(segments.count, 2, "a return booking is two legs, not one")
        XCTAssertEqual(segments[0].flightNumber, "SQ874")
        XCTAssertEqual(segments[0].dayDate, "2026-11-12")
        XCTAssertEqual(segments[1].flightNumber, "SQ872")
        XCTAssertEqual(segments[1].dayDate, "2026-11-21")
        XCTAssertEqual(segments[1].destinationCode, "SIN", "the return leg flies home")
    }

    /// An ordinary one-way ticket must still be exactly one row.
    func testSingleSegmentTicketYieldsOneItem() {
        let input: [String: AnthropicJSONValue] = [
            "segments": .array([segment(title: "Coldplay", day: "2026-11-14")])
        ]
        XCTAssertEqual(ExtractedTicket.segments(fromToolInput: input).count, 1)
    }

    /// A model that ignores the array and answers in the old flat shape must
    /// still produce a row, or a schema change would strand every upload.
    func testFlatToolInputStillParsesAsOneSegment() {
        let flat: [String: AnthropicJSONValue] = [
            "title": .string("SQ874 · SIN→HKG"),
            "kind": .string("transport"),
            "day_date": .string("2026-11-12"),
            "flight_number": .string("SQ874")
        ]
        let segments = ExtractedTicket.segments(fromToolInput: flat)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].flightNumber, "SQ874")
    }

    /// Nothing readable must come back empty, so the caller degrades to one
    /// minimal item rather than inserting a blank row per junk entry.
    func testUnreadableToolInputYieldsNoSegments() {
        XCTAssertTrue(ExtractedTicket.segments(fromToolInput: [:]).isEmpty)
        XCTAssertTrue(ExtractedTicket.segments(fromToolInput: ["segments": .array([.object([:])])]).isEmpty)
    }

    /// A segment carrying only optional extras is not a segment. Without this an
    /// empty array entry would become a row titled "Ticket" on the trip's first day.
    func testSegmentWithNoTitleKindOrDateIsDropped() {
        let input: [String: AnthropicJSONValue] = [
            "segments": .array([
                segment(title: "SQ874 · SIN→HKG", day: "2026-11-12", flight: "SQ874"),
                .object(["seat": .string("12A")])
            ])
        ]
        XCTAssertEqual(ExtractedTicket.segments(fromToolInput: input).count, 1)
    }

    // MARK: - Boarding-pass merge

    /// `flightLabel` is computed from carrier + number, so a fixture sets those.
    private func bcbp(flight: String?, origin: String?, destination: String?) -> BCBPTicket {
        var ticket = BCBPTicket()
        if let flight {
            ticket.carrier = String(flight.prefix(2))
            ticket.flightNumber = String(flight.dropFirst(2))
        }
        ticket.originCode = origin
        ticket.destinationCode = destination
        return ticket
    }

    /// The seat and PNR from one scanned pass must land on the leg it describes.
    /// Applied to leg 0 blindly, the outbound seat would show on the return.
    func testBoardingPassMergesIntoTheMatchingLegByFlightNumber() {
        let segments = ExtractedTicket.segments(fromToolInput: [
            "segments": .array([
                segment(title: "out", day: "2026-11-12", flight: "SQ874"),
                segment(title: "back", day: "2026-11-21", flight: "SQ872")
            ])
        ])
        let index = TicketExtraction.bcbpSegmentIndex(
            bcbp(flight: "SQ872", origin: nil, destination: nil), in: segments)
        XCTAssertEqual(index, 1, "the pass is for the return leg")
    }

    /// Airlines print the flight number in several forms, so the route is the
    /// fallback signal.
    func testBoardingPassMergesByRouteWhenTheFlightNumberDoesNotMatch() {
        let segments = ExtractedTicket.segments(fromToolInput: [
            "segments": .array([
                segment(title: "out", day: "2026-11-12", origin: "SIN", destination: "HKG"),
                segment(title: "back", day: "2026-11-21", origin: "HKG", destination: "SIN")
            ])
        ])
        let index = TicketExtraction.bcbpSegmentIndex(
            bcbp(flight: nil, origin: "HKG", destination: "SIN"), in: segments)
        XCTAssertEqual(index, 1)
    }

    /// When a pass matches no leg, it must be dropped rather than stamped onto
    /// the first one: a wrong seat reads as real and is never questioned.
    func testBoardingPassMatchingNoLegIsNotApplied() {
        let segments = ExtractedTicket.segments(fromToolInput: [
            "segments": .array([
                segment(title: "out", day: "2026-11-12", flight: "SQ874"),
                segment(title: "back", day: "2026-11-21", flight: "SQ872")
            ])
        ])
        let index = TicketExtraction.bcbpSegmentIndex(
            bcbp(flight: "BA11", origin: "LHR", destination: "SIN"), in: segments)
        XCTAssertNil(index)
    }

    /// The ordinary boarding-pass case: one segment always takes the facts, even
    /// when the model read the flight number differently from the barcode.
    func testSingleSegmentAlwaysTakesTheBoardingPassFacts() {
        let segments = ExtractedTicket.segments(fromToolInput: [
            "segments": .array([segment(title: "out", day: "2026-11-12", flight: "SQ 874")])
        ])
        let index = TicketExtraction.bcbpSegmentIndex(
            bcbp(flight: "SQ874", origin: "SIN", destination: "HKG"), in: segments)
        XCTAssertEqual(index, 0)
    }

    /// Whitespace and case differ between a barcode and printed text.
    func testFlightNumberMatchIgnoresSpacingAndCase() {
        let segments = ExtractedTicket.segments(fromToolInput: [
            "segments": .array([
                segment(title: "out", day: "2026-11-12", flight: "sq 874"),
                segment(title: "back", day: "2026-11-21", flight: "SQ872")
            ])
        ])
        let index = TicketExtraction.bcbpSegmentIndex(
            bcbp(flight: "SQ874", origin: nil, destination: nil), in: segments)
        XCTAssertEqual(index, 0)
    }

    func testNoBoardingPassMeansNoMerge() {
        XCTAssertNil(TicketExtraction.bcbpSegmentIndex(nil, in: []))
    }

    // MARK: - Multi-page rendering

    /// Build a PDF with `pageCount` pages, each carrying its own line of text.
    private func makePDF(pageCount: Int) -> Data {
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            return Data()
        }
        for page in 1...pageCount {
            ctx.beginPDFPage(nil)
            let text = "Page \(page)" as CFString
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributed = NSAttributedString(
                string: text as String,
                attributes: [.font: font, .foregroundColor: UIColor.black])
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: 60, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// The second half of the defect: a return leg printed on page 2 was never
    /// sent to the model, because only page 1 was rendered.
    func testEveryPageOfAPDFIsRenderedForReading() throws {
        let pdf = makePDF(pageCount: 2)
        try XCTSkipIf(pdf.isEmpty, "could not build the fixture PDF")
        XCTAssertEqual(PDFDocument(data: pdf)?.pageCount, 2, "fixture should have two pages")

        let images = BarcodeService.renderPages(pdfData: pdf, targetLongEdge: 800)
        XCTAssertEqual(images.count, 2, "page 2 must reach the extraction call")
    }

    /// A long attachment must not turn into one image per page on one request.
    func testPageRenderingStopsAtTheCap() throws {
        let pdf = makePDF(pageCount: 6)
        try XCTSkipIf(pdf.isEmpty, "could not build the fixture PDF")

        let images = BarcodeService.renderPages(pdfData: pdf, maxPages: 3, targetLongEdge: 400)
        XCTAssertEqual(images.count, 3)
    }

    /// The cap the extraction call uses must match the barcode reader's, so both
    /// see the same slice of a document.
    func testExtractionPageCapMatchesTheBarcodeReader() {
        XCTAssertEqual(TicketExtraction.extractionPageCap, 3)
    }

    func testRenderingANonPDFYieldsNoPages() {
        XCTAssertTrue(BarcodeService.renderPages(pdfData: Data("not a pdf".utf8)).isEmpty)
    }

    // MARK: - Bare clock times

    private func utcComponents(_ date: Date?) -> (Int, Int, Int)? {
        guard let date else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.day, .hour, .minute], from: date)
        guard let d = c.day, let h = c.hour, let m = c.minute else { return nil }
        return (d, h, m)
    }

    private func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    /// A live run against the real model showed it answering `07:20` on a ticket
    /// that prints no timezone. That parsed to nil, so the leg reached the
    /// timeline with no departure time at all.
    func testBareClockTimeIsAnchoredOnTheSegmentDay() {
        let parsed = TicketExtraction.parseWallClockTime("07:20", onDay: day("2026-11-12"))
        XCTAssertEqual(utcComponents(parsed).map { [$0.0, $0.1, $0.2] }, [12, 7, 20])
    }

    /// The full ISO form must keep working exactly as before.
    func testFullISOTimeStillWins() {
        let parsed = TicketExtraction.parseWallClockTime("2026-11-21T20:05:00+08:00", onDay: day("2026-11-21"))
        XCTAssertEqual(utcComponents(parsed).map { [$0.1, $0.2] }, [20, 5])
    }

    /// Two legs must not collapse onto one time just because both were bare.
    func testTwoBareTimesAnchorOnTheirOwnDays() {
        let out = TicketExtraction.parseWallClockTime("07:20", onDay: day("2026-11-12"))
        let back = TicketExtraction.parseWallClockTime("20:05", onDay: day("2026-11-21"))
        XCTAssertEqual(utcComponents(out).map { [$0.0, $0.1] }, [12, 7])
        XCTAssertEqual(utcComponents(back).map { [$0.0, $0.1] }, [21, 20])
    }

    /// A misread time must be dropped, not wrapped into a plausible wrong one.
    func testJunkClockTimesAreRejected() {
        for junk in ["25:70", "7:2", "abc", "", "12:", ":30", "1200"] {
            XCTAssertNil(
                TicketExtraction.parseWallClockTime(junk, onDay: day("2026-11-12")),
                "\(junk) should not parse")
        }
    }

    /// With no day to anchor to, a bare time has no meaning and must stay nil.
    func testBareTimeWithoutADayIsNil() {
        XCTAssertNil(TicketExtraction.parseWallClockTime("07:20", onDay: nil))
    }

    // MARK: - Tool schema

    /// The schema must actually advertise the array, or the model has no way to
    /// report a second leg however well the prompt asks for one.
    func testToolSchemaAdvertisesASegmentsArray() throws {
        guard case let .object(schema) = TicketExtraction.extractTicketTool.input_schema,
              case let .object(properties) = try XCTUnwrap(schema["properties"]),
              case let .object(segments) = try XCTUnwrap(properties["segments"]) else {
            return XCTFail("extract_ticket should expose a `segments` property")
        }
        XCTAssertEqual(segments["type"]?.stringValue, "array")

        guard case let .object(items) = try XCTUnwrap(segments["items"]),
              case let .object(itemProperties) = try XCTUnwrap(items["properties"]) else {
            return XCTFail("`segments` should describe its item shape")
        }
        // The per-segment fields that make two legs distinguishable.
        for key in ["title", "day_date", "start_time", "arrival_time", "seat", "flight_number"] {
            XCTAssertNotNil(itemProperties[key], "each segment needs its own \(key)")
        }
        XCTAssertEqual(schema["required"]?.arrayValue?.first?.stringValue, "segments")
    }

    /// The prompt has to name the failure, because the schema alone does not stop
    /// a model from collapsing a return booking into one entry.
    func testSystemPromptAsksForEverySegment() {
        let prompt = TicketExtraction.systemPrompt.lowercased()
        XCTAssertTrue(prompt.contains("return"), "the return leg must be called out")
        XCTAssertTrue(prompt.contains("segments array") || prompt.contains("segments"))
    }

    /// A multi-page upload must tell the model there are later pages to read.
    func testUserPromptFlagsLaterPages() {
        let single = TicketExtraction.userPrompt(dateContext: "ctx", bcbp: nil, pageCount: 1)
        let multi = TicketExtraction.userPrompt(dateContext: "ctx", bcbp: nil, pageCount: 3)
        XCTAssertFalse(single.contains("3 pages"))
        XCTAssertTrue(multi.contains("3 pages"), "the model must know to check page 2 and 3")
    }
}
