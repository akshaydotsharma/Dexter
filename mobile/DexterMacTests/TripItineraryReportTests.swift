import XCTest
@testable import DexterMac

/// The trip itinerary report, asserted as data (#532).
///
/// The report's whole value is that it agrees with the timeline it was exported
/// from, and that nothing on the trip goes missing on the way to paper. So the
/// tests are agreement tests: the days against the grouping handed in, the
/// stays and travel tables against the stops behind them, and the two export
/// toggles against what actually prints.
///
/// One fixture trip carries the cases the feature has to survive: a stay
/// spanning three days, a flight with an arrival time and a boarding pass, an
/// untimed stop, a free day in the middle of the trip, a stop outside the
/// trip's own range, and notes long enough to need wrapping.
final class TripItineraryReportTests: XCTestCase {

    private let tripID = UUID()

    // MARK: - Fixture

    /// A UTC-anchored trip day, the shape every itinerary day field carries
    /// (#506).
    private func day(_ value: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = value
        components.hour = 0
        components.minute = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components) ?? Date()
    }

    /// A UTC wall-clock time on a day: its UTC hour:minute is what the booking
    /// states (#168).
    private func time(_ dayOfMonth: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = dayOfMonth
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components) ?? Date()
    }

    private func item(
        _ title: String,
        day dayOfMonth: Int,
        kind: ItineraryKind,
        mode: TransportMode? = nil,
        start: Date? = nil,
        arrival: Date? = nil,
        endDay: Int? = nil,
        endTime: Date? = nil,
        notes: String = "",
        address: String = "",
        venue: String = "",
        seat: String = "",
        gate: String = "",
        confirmation: String = "",
        meta: TicketMeta? = nil
    ) -> LocalItineraryItem {
        let row = LocalItineraryItem(
            tripUUID: tripID,
            dayDate: day(dayOfMonth),
            kind: kind,
            transportMode: mode,
            title: title,
            notes: notes,
            startTime: start,
            endDate: endDay.map { day($0) },
            endTime: endTime,
            arrivalTime: arrival,
            address: address,
            seat: seat,
            gate: gate,
            venue: venue,
            ticketMetaJSON: meta?.encodedString() ?? ""
        )
        // Not an init parameter on the model — it is an additive field (#143).
        row.sourceConfirmation = confirmation
        return row
    }

    private var flight: LocalItineraryItem {
        var meta = TicketMeta()
        meta.airline = "Singapore Airlines"
        meta.flightNumber = "SQ 366"
        meta.originCode = "SIN"
        meta.destinationCode = "FCO"
        meta.isBoardingPass = true
        return item(
            "Singapore to Rome",
            day: 3,
            kind: .transport,
            mode: .flight,
            start: time(3, 10, 35),
            arrival: time(3, 17, 40),
            seat: "12A",
            gate: "B22",
            confirmation: "HM84R8",
            meta: meta
        )
    }

    private var hotel: LocalItineraryItem {
        item(
            "207 Inn",
            day: 3,
            kind: .stay,
            start: time(3, 19, 0),
            endDay: 6,
            endTime: time(6, 11, 0),
            address: "Via Nazionale 207, Rome",
            confirmation: "ROMESTAY1"
        )
    }

    private var colosseum: LocalItineraryItem {
        item(
            "Colosseum",
            day: 4,
            kind: .activity,
            notes: "Tickets are timed entry. The queue for the ticket office is long, so go straight to the group entrance on the north side and show the pass on the phone.",
            address: "Piazza del Colosseo, Rome"
        )
    }

    /// A stop the day AFTER the trip's own end date.
    private var lateReturn: LocalItineraryItem {
        item("Train home", day: 8, kind: .transport, mode: .train, start: time(8, 9, 15))
    }

    /// The timeline's own grouping, built the way `TripDetailView.grouped`
    /// builds it: a stay becomes a check-in entry and a check-out entry.
    private func days(
        _ items: [LocalItineraryItem]
    ) -> [(day: Date, entries: [TimelineEntry])] {
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
        return buckets.keys.sorted().map { day in
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
    }

    private func report(
        items: [LocalItineraryItem]? = nil,
        notes: Bool = true,
        references: Bool = true,
        start: Int = 3,
        end: Int = 7
    ) -> TripItineraryReport {
        let rows = items ?? [flight, hotel, colosseum, lateReturn]
        return TripItineraryReport.make(
            TripItineraryReportInput(
                tripName: "Italy",
                startDate: day(start),
                endDate: day(end),
                days: days(rows),
                includeNotes: notes,
                includeReferences: references,
                exportDate: Date(timeIntervalSince1970: 1_789_000_000)
            )
        )
    }

    private func rows(_ report: TripItineraryReport) -> [TripItineraryReport.StopRow] {
        report.days.flatMap(\.rows)
    }

    // MARK: - The plan is complete

    func testEveryDayOfTheTripPrintsEvenWhenNothingIsOnIt() {
        let titles = report().days.map(\.title)
        // 3–7 June is the trip; 8 June carries the train home.
        XCTAssertEqual(titles.count, 6)
        XCTAssertTrue(titles[0].hasPrefix("Day 1 · "), titles[0])
        XCTAssertTrue(titles[4].hasPrefix("Day 5 · "), titles[4])
        // The stop outside the range keeps its date and loses the day number.
        XCTAssertFalse(titles[5].contains("Day "), titles[5])
    }

    func testAFreeDayInsideTheTripSaysSo() {
        let free = report().days.first { $0.rows.isEmpty }
        XCTAssertEqual(free?.subtitle, "Nothing planned")
    }

    func testADayWithStopsCountsThem() {
        let first = report().days.first
        // 3 June: the flight and the hotel check-in.
        XCTAssertEqual(first?.subtitle, "2 stops")
        XCTAssertEqual(first?.rows.count, 2)
    }

    func testAStayAppearsOnItsCheckInAndItsCheckOutDay() {
        let stay = rows(report()).filter { $0.title == "207 Inn" }
        XCTAssertEqual(stay.count, 2)
        XCTAssertTrue(stay[0].time.hasPrefix("Check-in"), stay[0].time)
        XCTAssertTrue(stay[1].time.hasPrefix("Check-out"), stay[1].time)
    }

    func testTheStopCountMatchesTheTimelineEntries() {
        // Four stops, one of them a stay that shows up twice.
        XCTAssertEqual(report().cover.stopCount, 5)
        XCTAssertEqual(report().cover.stopCount, rows(report()).count)
    }

    func testTheDayCountIsTheTripsOwnLength() {
        XCTAssertEqual(report().cover.dayCount, 5)
    }

    // MARK: - What a stop says

    func testATimedStopPrintsItsDepartureAndArrival() {
        let row = rows(report()).first { $0.title == "Singapore to Rome" }
        XCTAssertEqual(row?.time.contains("→"), true, row?.time ?? "")
    }

    func testAnUntimedStopReadsAsAnytime() {
        let row = rows(report()).first { $0.title == "Colosseum" }
        XCTAssertEqual(row?.time, "Anytime")
    }

    func testATransportStopIsNamedByItsMode() {
        let row = rows(report()).first { $0.title == "Singapore to Rome" }
        XCTAssertEqual(row?.kind, "Flight")
        let train = rows(report()).first { $0.title == "Train home" }
        XCTAssertEqual(train?.kind, "Train")
    }

    func testAStopWithAPassOrAReferenceIsMarkedBooked() {
        let booked = rows(report()).first { $0.title == "Singapore to Rome" }
        XCTAssertEqual(booked?.isBooked, true)
        let unbooked = rows(report()).first { $0.title == "Colosseum" }
        XCTAssertEqual(unbooked?.isBooked, false)
    }

    func testAnAddressPrintsUnderTheStop() {
        let row = rows(report()).first { $0.title == "Colosseum" }
        XCTAssertEqual(row?.details.contains { $0.contains("Piazza del Colosseo") }, true)
    }

    // MARK: - The toggles decide what leaves the device

    func testReferencesPrintWhenTheyAreAskedFor() {
        let row = rows(report()).first { $0.title == "Singapore to Rome" }
        let joined = row?.details.joined(separator: " ") ?? ""
        XCTAssertTrue(joined.contains("Seat 12A"), joined)
        XCTAssertTrue(joined.contains("Gate B22"), joined)
        XCTAssertTrue(joined.contains("Ref HM84R8"), joined)
        XCTAssertTrue(joined.contains("SQ 366"), joined)
    }

    func testReferencesAreGoneWhenTheyAreTurnedOff() {
        let quiet = report(references: false)
        let joined = rows(quiet).flatMap(\.details).joined(separator: " ")
        XCTAssertFalse(joined.contains("HM84R8"), joined)
        XCTAssertFalse(joined.contains("Seat 12A"), joined)
        // And the stays / travel tables obey the same switch.
        XCTAssertFalse(quiet.stays.map(\.detail).joined().contains("ROMESTAY1"))
        XCTAssertFalse(quiet.travel.map(\.detail).joined().contains("HM84R8"))
        XCTAssertEqual(quiet.cover.omissionSentence?.isEmpty, false)
    }

    func testNotesAreGoneWhenTheyAreTurnedOff() {
        let joined = rows(report(notes: false)).flatMap(\.details).joined(separator: " ")
        XCTAssertFalse(joined.contains("timed entry"), joined)
    }

    func testAFullExportSaysNothingWasLeftOut() {
        XCTAssertNil(report().cover.omissionSentence)
    }

    func testLongNotesWrapRatherThanRunOffThePage() {
        let row = rows(report()).first { $0.title == "Colosseum" }
        let details = row?.details ?? []
        XCTAssertGreaterThan(details.count, 2)
        for line in details {
            XCTAssertLessThanOrEqual(line.count, TripItineraryReport.detailBudget, line)
        }
    }

    // MARK: - Stays

    func testAStayIsSummarisedOnceWithItsNights() {
        let stays = report().stays
        XCTAssertEqual(stays.count, 1)
        XCTAssertEqual(stays.first?.name, "207 Inn")
        XCTAssertEqual(stays.first?.nights, "3 nights")
        XCTAssertEqual(stays.first?.dates.contains("→"), true)
        XCTAssertEqual(stays.first?.detail.contains("Via Nazionale 207"), true)
    }

    func testAStayWithNoCheckOutDayClaimsNoNights() {
        let overnight = item("Airport hotel", day: 3, kind: .stay)
        let stays = report(items: [overnight]).stays
        XCTAssertEqual(stays.first?.nights, "")
    }

    // MARK: - Travel

    func testATicketedLegPrintsItsRouteCodes() {
        let leg = report().travel.first
        XCTAssertEqual(leg?.route, "SIN → FCO")
        XCTAssertEqual(leg?.mode, "Flight")
        XCTAssertEqual(leg?.times.contains("→"), true)
        XCTAssertEqual(leg?.detail.contains("Singapore to Rome"), true)
    }

    /// An imported flight is titled after its own number and route, and the
    /// row used to print both twice.
    func testALegNeverRepeatsWhatItsTitleAlreadySays() {
        var meta = TicketMeta()
        meta.airline = "Scoot"
        meta.flightNumber = "TR 280"
        meta.originCode = "SIN"
        meta.destinationCode = "DPS"
        let imported = item(
            "TR 280 · SIN→DPS",
            day: 3,
            kind: .transport,
            mode: .flight,
            start: time(3, 7, 30),
            confirmation: "VBKTRZ",
            meta: meta
        )
        let leg = report(items: [imported]).travel.first
        XCTAssertEqual(leg?.route, "SIN → DPS")
        // The title is gone, and the flight number appears once.
        XCTAssertFalse(leg?.detail.contains("SIN→DPS") ?? true, leg?.detail ?? "")
        XCTAssertEqual(leg?.detail.components(separatedBy: "TR 280").count, 1, leg?.detail ?? "")
        XCTAssertEqual(leg?.detail.contains("Ref VBKTRZ"), true, leg?.detail ?? "")

        // And the same on its day-by-day row, where the title IS printed.
        let row = report(items: [imported]).days.flatMap(\.rows).first
        let joined = row?.details.joined(separator: " ") ?? ""
        XCTAssertFalse(joined.contains("TR 280"), joined)
        XCTAssertTrue(joined.contains("Ref VBKTRZ"), joined)
    }

    func testALegWithoutCodesFallsBackToItsTitle() {
        let leg = report().travel.first { $0.mode == "Train" }
        XCTAssertEqual(leg?.route, "Train home")
    }

    func testTravelIsInDepartureOrder() {
        let dates = report().travel.map(\.date)
        XCTAssertEqual(dates, dates.sorted { lhs, rhs in
            // Both are "d MMM" in June, so a numeric compare on the day is enough.
            (Int(lhs.prefix(while: \.isNumber)) ?? 0) < (Int(rhs.prefix(while: \.isNumber)) ?? 0)
        })
    }

    func testTheTravelAndStaysTablesAreOmittedWhenTheTripHasNeither() {
        let plain = report(items: [colosseum])
        XCTAssertTrue(plain.stays.isEmpty)
        XCTAssertTrue(plain.travel.isEmpty)
    }

    // MARK: - Cover

    func testTheCoverCountsWhatTheTripIsMadeOf() {
        let counts = report().cover.kindCounts
        XCTAssertEqual(counts.first { $0.label == "Flight" }?.count, 1)
        XCTAssertEqual(counts.first { $0.label == "Stay" }?.count, 1)
        XCTAssertEqual(counts.first { $0.label == "Activity" }?.count, 1)
        // A stay counts once here, not twice: this is what the trip HOLDS, not
        // what the timeline shows.
        XCTAssertEqual(counts.reduce(0) { $0 + $1.count }, 4)
    }

    func testTheFileNameNamesTheTripAndTheDay() {
        XCTAssertTrue(report().fileName.hasPrefix("Italy itinerary "), report().fileName)
        XCTAssertTrue(report().fileName.hasSuffix(".pdf"))
    }

    func testATripNameAFileSystemWouldRejectStillSaves() {
        let name = TripItineraryReport.fileName(tripName: "Rome / Milan", on: Date())
        XCTAssertFalse(name.contains("/"), name)
        XCTAssertTrue(name.contains("Rome Milan itinerary"), name)
    }

    // MARK: - An empty trip

    func testATripWithNoStopsStillProducesAReadableReport() {
        let empty = report(items: [])
        XCTAssertEqual(empty.cover.stopCount, 0)
        XCTAssertEqual(empty.days.allSatisfy { $0.rows.isEmpty }, true)
        XCTAssertEqual(empty.days.count, 5)
    }

    // MARK: - Wrapping

    func testWrapKeepsWholeWordsAndMarksWhatItDropped() {
        let long = String(repeating: "alpha ", count: 200)
        let lines = TripItineraryReport.wrap(long, lines: 2)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasSuffix("…"), lines[1])
        for line in lines { XCTAssertLessThanOrEqual(line.count, TripItineraryReport.detailBudget) }
    }

    func testWrapBreaksAWordWiderThanTheLine() {
        let lines = TripItineraryReport.wrap(String(repeating: "x", count: 200), lines: 4)
        XCTAssertGreaterThan(lines.count, 1)
        for line in lines { XCTAssertLessThanOrEqual(line.count, TripItineraryReport.detailBudget) }
    }

    func testWrapReturnsNothingForEmptyText() {
        XCTAssertTrue(TripItineraryReport.wrap("   \n  ", lines: 3).isEmpty)
    }
}
