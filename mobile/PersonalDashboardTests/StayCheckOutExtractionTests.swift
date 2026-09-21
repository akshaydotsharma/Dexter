import XCTest
@testable import PersonalDashboard

/// A scanned accommodation voucher keeps its check-out (#649).
///
/// The defect these pin, reproduced from the live store: an Airbnb villa scanned
/// onto a Bali trip landed with `kind = stay` and `startTime = 15:00`, which is
/// correct, and with `endDate = nil`, `endTime = nil` and `arrivalTime = 11:00`
/// on the CHECK-IN day, which is not. The model had read the check-out perfectly
/// and written it into `other_fields` as prose, because `extract_booking` had no
/// field for it and `buildItem` hardcoded `endDate: nil` regardless.
///
/// Three separate things had to be true for that row to come out wrong, so each
/// gets its own test: the schema has to carry the field, the resolver has to
/// accept it, and the builder has to persist it. A test of only the first would
/// have passed against the broken app.
@MainActor
final class StayCheckOutExtractionTests: XCTestCase {

    // MARK: - Helpers

    /// A stay segment as the model returns it.
    private func staySegment(
        checkIn: String = "2026-10-08",
        checkOut: String? = "2026-10-11",
        checkInTime: String? = "15:00",
        checkOutTime: String? = "11:00",
        arrival: String? = nil
    ) -> [String: AnthropicJSONValue] {
        var fields: [String: AnthropicJSONValue] = [
            "title": .string("Luxury 2BR Villa | Rooftop Pool | Canggu, Bali"),
            "kind": .string("stay"),
            "day_date": .string(checkIn),
            "confirmation": .string("HMT9KREHH3")
        ]
        if let checkOut { fields["end_date"] = .string(checkOut) }
        if let checkInTime { fields["start_time"] = .string(checkInTime) }
        if let checkOutTime { fields["end_time"] = .string(checkOutTime) }
        if let arrival { fields["arrival_time"] = .string(arrival) }
        return fields
    }

    private func trip() -> LocalTrip {
        LocalTrip(
            name: "Bali",
            startDate: WallClock.dayAnchor(fromISO: "2026-10-08")!,
            endDate: WallClock.dayAnchor(fromISO: "2026-10-11")!
        )
    }

    /// `yyyy-MM-dd` of a stored day, read in UTC (days are UTC-anchored, #506).
    private func dayString(_ date: Date?) -> String? {
        guard let date else { return nil }
        let fmt = DateFormatter()
        fmt.calendar = WallClock.dayCalendar
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    /// `HH:mm` of a stored wall-clock time, read in UTC for the same reason.
    private func timeString(_ date: Date?) -> String? {
        guard let date else { return nil }
        let fmt = DateFormatter()
        fmt.calendar = WallClock.dayCalendar
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - The schema carries it

    func testTheCheckOutDateAndTimeAreParsedOffASegment() {
        let segments = ExtractedTicket.segments(
            fromToolInput: ["segments": .array([.object(staySegment())])]
        )

        XCTAssertEqual(segments.count, 1, "a stay of several nights is one entry, not one per night")
        XCTAssertEqual(segments[0].dayDate, "2026-10-08", "day_date is the check-in")
        XCTAssertEqual(segments[0].endDate, "2026-10-11", "end_date is the check-out")
        XCTAssertEqual(segments[0].endTime, "11:00")
    }

    // MARK: - The resolver accepts it

    func testTheResolverReturnsTheCheckOutDayAndTime() {
        let checkIn = WallClock.dayAnchor(fromISO: "2026-10-08")!
        let extracted = ExtractedTicket(input: staySegment())

        let out = TicketExtraction.stayCheckOut(isStay: true, extracted: extracted, checkIn: checkIn)

        XCTAssertEqual(dayString(out?.day), "2026-10-11")
        XCTAssertEqual(timeString(out?.time), "11:00")
    }

    func testANonStayNeverResolvesACheckOut() {
        let checkIn = WallClock.dayAnchor(fromISO: "2026-10-08")!
        let extracted = ExtractedTicket(input: staySegment())

        XCTAssertNil(
            TicketExtraction.stayCheckOut(isStay: false, extracted: extracted, checkIn: checkIn),
            "a flight that answered with an end_date is a misread, not a stay"
        )
    }

    /// A check-out that is not after the check-in is the shape a misread takes:
    /// the model echoing one date twice, or resolving the wrong year on a range.
    /// Storing it renders the check-out ABOVE its own check-in.
    func testACheckOutOnOrBeforeTheCheckInIsDropped() {
        let checkIn = WallClock.dayAnchor(fromISO: "2026-10-08")!

        for bad in ["2026-10-08", "2026-10-07", "2025-10-11"] {
            let extracted = ExtractedTicket(input: staySegment(checkOut: bad))
            XCTAssertNil(
                TicketExtraction.stayCheckOut(isStay: true, extracted: extracted, checkIn: checkIn),
                "\(bad) is not after the check-in and must not be stored"
            )
        }
    }

    // MARK: - The builder persists it

    /// The defect itself. Before this, these two lines read `endDate: nil`.
    func testAScannedStayLandsWithItsCheckOut() {
        var sortOrder: [Date: Int] = [:]
        let item = TicketExtraction().buildItem(
            trip: trip(),
            extracted: ExtractedTicket(input: staySegment()),
            bcbp: nil,
            decoded: nil,
            attachmentPath: "tickets/villa.pdf",
            nextSortOrder: &sortOrder
        )

        XCTAssertEqual(item.kindEnum, .stay)
        XCTAssertEqual(dayString(item.dayDate), "2026-10-08", "check-in")
        XCTAssertEqual(dayString(item.endDate), "2026-10-11", "check-out")
        XCTAssertEqual(timeString(item.startTime), "15:00")
        XCTAssertEqual(timeString(item.endTime), "11:00")
    }

    /// The second half of the same row's damage. The model put the check-out TIME
    /// in `arrival_time` because that was the only time-shaped field left, and the
    /// builder anchored it on the check-in day — so the villa rendered
    /// "15:00 → 11:00" on 8 October, like a flight landing before it departs.
    func testAStayNeverStoresAnArrivalTime() {
        var sortOrder: [Date: Int] = [:]
        let item = TicketExtraction().buildItem(
            trip: trip(),
            extracted: ExtractedTicket(input: staySegment(arrival: "11:00")),
            bcbp: nil,
            decoded: nil,
            attachmentPath: "tickets/villa.pdf",
            nextSortOrder: &sortOrder
        )

        XCTAssertNil(item.arrivalTime, "a stay arrives at nothing")
    }

    /// A voucher printing only its two dates still has to work: the timeline
    /// renders an untimed stay with a hollow marker, and that is a complete row.
    func testAStayWithNoPrintedTimesStillSpansItsDays() {
        var sortOrder: [Date: Int] = [:]
        let item = TicketExtraction().buildItem(
            trip: trip(),
            extracted: ExtractedTicket(input: staySegment(checkInTime: nil, checkOutTime: nil)),
            bcbp: nil,
            decoded: nil,
            attachmentPath: "tickets/villa.pdf",
            nextSortOrder: &sortOrder
        )

        XCTAssertEqual(dayString(item.endDate), "2026-10-11")
        XCTAssertNil(item.startTime)
        XCTAssertNil(item.endTime)
    }

    /// A stay the model answered without a check-out must still produce a row.
    /// Degrading to a single-day stay is what the editor can repair; throwing the
    /// upload away is not.
    func testAStayWithNoCheckOutStillBuilds() {
        var sortOrder: [Date: Int] = [:]
        let item = TicketExtraction().buildItem(
            trip: trip(),
            extracted: ExtractedTicket(input: staySegment(checkOut: nil)),
            bcbp: nil,
            decoded: nil,
            attachmentPath: "tickets/villa.pdf",
            nextSortOrder: &sortOrder
        )

        XCTAssertEqual(item.kindEnum, .stay)
        XCTAssertNil(item.endDate)
        XCTAssertEqual(dayString(item.dayDate), "2026-10-08", "the check-in survives regardless")
    }

    // MARK: - The Wallet path agrees

    /// The two builders read one tool output and have drifted three times (#475,
    /// #500, #522). A hotel voucher filed straight to the Wallet takes the same
    /// check-out, or the stay card loses its nights count and drops to Past on the
    /// morning of check-in.
    func testAStayFiledToTheWalletTakesTheSameCheckOut() {
        let card = TicketExtraction().buildWalletCard(
            extracted: ExtractedTicket(input: staySegment(arrival: "11:00")),
            bcbp: nil,
            decoded: nil,
            attachmentPath: "tickets/villa.pdf"
        )

        XCTAssertEqual(dayString(card.endDate), "2026-10-11")
        XCTAssertEqual(timeString(card.endTime), "11:00")
        XCTAssertNil(card.arrivalTime, "a stay arrives at nothing here either")
    }

    // MARK: - Dedupe parity with the forwarded email

    /// `EmailItemDedupe.segmentKey` puts a stay's check-out in its key. While the
    /// scanner could not read one, a scanned stay and the forwarded confirmation
    /// of the SAME booking produced different keys, so the email added a second
    /// villa instead of merging.
    func testAScannedStayGetsTheKeyTheEmailPathWouldProduce() {
        let tripRow = trip()
        var sortOrder: [Date: Int] = [:]
        let item = TicketExtraction().buildItem(
            trip: tripRow,
            extracted: ExtractedTicket(input: staySegment()),
            bcbp: nil,
            decoded: nil,
            attachmentPath: "tickets/villa.pdf",
            nextSortOrder: &sortOrder
        )

        let fromEmail = EmailItemDedupe.signature(
            tripUUID: tripRow.clientUUID,
            proposed: EmailItemDedupe.Proposed(
                kind: "stay",
                dayDate: WallClock.dayAnchor(fromISO: "2026-10-08")!,
                endDate: WallClock.dayAnchor(fromISO: "2026-10-11")!,
                title: "Luxury 2BR Villa | Rooftop Pool | Canggu, Bali",
                confirmation: "HMT9KREHH3",
                startTime: item.startTime
            )
        )

        XCTAssertEqual(item.dedupeKey, fromEmail, "the same booking read two ways is one row")
    }
}
