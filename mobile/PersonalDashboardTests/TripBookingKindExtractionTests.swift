import XCTest
@testable import PersonalDashboard

/// A trip collects more than tickets, and each kind has to land in the right
/// row (#651).
///
/// The scanner was written for a ticket and named after one. Its `kind` enum
/// accepted five itinerary kinds and its description explained four, so nothing
/// reaching the model said a dinner reservation or a museum admission had a
/// home. `arrival_time` was described as a landing time and told to omit itself
/// for anything that was not a flight, which left a 09:00-17:00 day trip with no
/// end even though the timeline renders one.
///
/// These pin the mapping for each kind someone actually books, and the
/// structural rule that keeps the schema honest as `ItineraryKind` grows.
@MainActor
final class TripBookingKindExtractionTests: XCTestCase {

    private func trip() -> LocalTrip {
        LocalTrip(
            name: "Bali",
            startDate: WallClock.dayAnchor(fromISO: "2026-10-08")!,
            endDate: WallClock.dayAnchor(fromISO: "2026-10-11")!
        )
    }

    /// Build the row a single extracted segment produces, as the scan path does.
    private func row(_ fields: [String: AnthropicJSONValue]) -> LocalItineraryItem {
        var sortOrder: [Date: Int] = [:]
        return TicketExtraction().buildItem(
            trip: trip(),
            extracted: ExtractedTicket(input: fields),
            bcbp: nil,
            decoded: nil,
            attachmentPath: "tickets/booking.pdf",
            nextSortOrder: &sortOrder
        )
    }

    private func timeString(_ date: Date?) -> String? {
        guard let date else { return nil }
        let fmt = DateFormatter()
        fmt.calendar = WallClock.dayCalendar
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - The schema stays in step with the model layer

    /// The one rule that does not age: every kind a row can hold must be a kind
    /// the model is allowed to answer with. Adding a case to `ItineraryKind`
    /// without adding it here would leave the new kind unreachable by a scan,
    /// and nothing else in the app would notice.
    func testTheSchemaOffersEveryItineraryKind() throws {
        guard case let .object(schema) = TicketExtraction.extractBookingTool.input_schema,
              case let .object(properties) = try XCTUnwrap(schema["properties"]),
              case let .object(segments) = try XCTUnwrap(properties["segments"]),
              case let .object(items) = try XCTUnwrap(segments["items"]),
              case let .object(itemProperties) = try XCTUnwrap(items["properties"]),
              case let .object(kind) = try XCTUnwrap(itemProperties["kind"]) else {
            return XCTFail("extract_booking should expose a `kind` property")
        }
        let offered = Set((kind["enum"]?.arrayValue ?? []).compactMap { $0.stringValue })

        for itineraryKind in ItineraryKind.allCases {
            XCTAssertTrue(
                offered.contains(itineraryKind.rawValue),
                "the model cannot produce a \(itineraryKind.rawValue) it is never offered"
            )
        }
        // Plus the Wallet's own kind, which is not an itinerary row.
        XCTAssertTrue(offered.contains("pass"))
        XCTAssertEqual(offered.count, ItineraryKind.allCases.count + 1, "no invented kinds")
    }

    /// Every offered kind has to round-trip into a real `ItineraryKind`, or the
    /// builder silently falls back to `.activity` — which is how a misspelled
    /// enum value would reach a row looking like a correct read.
    func testEveryOfferedKindDecodesToARealKind() throws {
        guard case let .object(schema) = TicketExtraction.extractBookingTool.input_schema,
              case let .object(properties) = try XCTUnwrap(schema["properties"]),
              case let .object(segments) = try XCTUnwrap(properties["segments"]),
              case let .object(items) = try XCTUnwrap(segments["items"]),
              case let .object(itemProperties) = try XCTUnwrap(items["properties"]),
              case let .object(kind) = try XCTUnwrap(itemProperties["kind"]) else {
            return XCTFail("extract_booking should expose a `kind` property")
        }
        for value in (kind["enum"]?.arrayValue ?? []).compactMap({ $0.stringValue }) where value != "pass" {
            XCTAssertNotNil(ItineraryKind(rawValue: value), "\(value) is not an ItineraryKind")
        }
    }

    // MARK: - One test per thing someone books

    /// The day trip. Its whole shape is a start and an end, and `arrival_time`
    /// used to tell the model to omit itself for anything that was not a flight.
    func testAGuidedDayTripKeepsItsStartAndItsEnd() {
        let item = row([
            "title": .string("Mount Batur Sunrise Trek"),
            "kind": .string("activity"),
            "day_date": .string("2026-10-09"),
            "start_time": .string("02:30"),
            "arrival_time": .string("11:00"),
            "event_type": .string("Day trip"),
            "venue": .string("Ubud Palace car park")
        ])

        XCTAssertEqual(item.kindEnum, .activity)
        XCTAssertEqual(timeString(item.startTime), "02:30")
        XCTAssertEqual(timeString(item.arrivalTime), "11:00", "the timeline renders 02:30 → 11:00")
        XCTAssertEqual(item.venue, "Ubud Palace car park")
        XCTAssertNil(item.endDate, "only a stay spans days")
    }

    func testARestaurantReservationLandsAsARestaurant() {
        let item = row([
            "title": .string("Locavore NXT"),
            "kind": .string("restaurant"),
            "day_date": .string("2026-10-09"),
            "start_time": .string("19:30"),
            "confirmation": .string("LV-88213"),
            "address": .string("Jl. Raya Pengosekan, Ubud, Bali")
        ])

        XCTAssertEqual(item.kindEnum, .restaurant)
        XCTAssertEqual(timeString(item.startTime), "19:30")
        XCTAssertEqual(item.sourceConfirmation, "LV-88213")
        XCTAssertFalse(item.googleMapsLink.isEmpty, "an address gives the row its map link")
    }

    /// A car hire is a way of getting about, not an activity. The mode is what
    /// picks the row's icon, so a car landing on the flight default reads wrong.
    func testACarHireVoucherLandsAsTransportByCar() {
        let item = row([
            "title": .string("Sixt · Denpasar Airport"),
            "kind": .string("transport"),
            "mode": .string("car"),
            "day_date": .string("2026-10-08"),
            "start_time": .string("12:00")
        ])

        XCTAssertEqual(item.kindEnum, .transport)
        XCTAssertEqual(item.transportModeEnum, .car)
    }

    func testAnAttractionAdmissionLandsAsAPlace() {
        let item = row([
            "title": .string("Tirta Empul Temple"),
            "kind": .string("place"),
            "day_date": .string("2026-10-10")
        ])

        XCTAssertEqual(item.kindEnum, .place)
        XCTAssertNil(item.startTime, "a timed-entry-free admission is an untimed row")
    }

    // MARK: - No regression on what already worked

    func testAFlightAndAnEventStillReadAsTheyDid() {
        let flight = row([
            "title": .string("TR 280 · SIN→DPS"),
            "kind": .string("transport"),
            "mode": .string("flight"),
            "day_date": .string("2026-10-08"),
            "start_time": .string("07:30"),
            "arrival_time": .string("10:20"),
            "flight_number": .string("TR 280")
        ])
        XCTAssertEqual(flight.kindEnum, .transport)
        XCTAssertEqual(flight.transportModeEnum, .flight)
        XCTAssertEqual(timeString(flight.arrivalTime), "10:20")

        let event = row([
            "title": .string("Coldplay · Music of the Spheres"),
            "kind": .string("activity"),
            "day_date": .string("2026-10-10"),
            "start_time": .string("20:00"),
            "seat": .string("Block A Row 14 Seat 7")
        ])
        XCTAssertEqual(event.kindEnum, .activity)
        XCTAssertEqual(event.seat, "Block A Row 14 Seat 7")
    }

    /// An unreadable or invented kind still has to produce a row. The upload is
    /// never lost; `.activity` is the fallback the editor can correct.
    func testAnUnknownKindFallsBackToActivity() {
        let item = row([
            "title": .string("Something the model invented"),
            "kind": .string("excursion"),
            "day_date": .string("2026-10-09")
        ])

        XCTAssertEqual(item.kindEnum, .activity)
    }
}
