import XCTest
@testable import PersonalDashboard

/// Live verification that a real accommodation voucher comes back with both of
/// its dates (#649), against the real document and the real prompt.
///
/// Skipped unless both `DEXTER_LIVE_STAY_PDF` and `ANTHROPIC_API_KEY` are set, so
/// an ordinary run spends nothing and needs no network.
///
/// It exists because a stub cannot answer the question this issue turned on. The
/// schema could not describe a check-out, so the model did the best thing left to
/// it and wrote "Check-out: 11:00 AM, Sun, Oct 11" into the catch-all array — a
/// perfect read of the document and an unusable row. Whether the widened schema
/// actually gets the model to put that date in `end_date` is a fact about the
/// model, not about our decoding, so it is replayed rather than reasoned about.
///
/// Unlike the other two live reads, this one is hosted on iOS rather than the Mac.
/// They sit in `DexterMacTests` because `VNDetectBarcodesRequest` fails in the iOS
/// Simulator and their subject is a barcode. A hotel voucher has none, so this can
/// stay off the Mac test host — which boots a real instance against the live store.
@MainActor
final class LiveStayVoucherReadTests: XCTestCase {

    func testARealAccommodationVoucherKeepsBothOfItsDates() async throws {
        // Both arrive through the scheme's `$(NAME)` environment variables, so an
        // unsupplied one stays literally "$(DEXTER_LIVE_STAY_PDF)". The
        // `TEST_RUNNER_` prefix does NOT reach an app-hosted simulator test — see
        // the note beside these in `project.yml`.
        let env = ProcessInfo.processInfo.environment
        let path = env["DEXTER_LIVE_STAY_PDF"] ?? ""
        guard !path.isEmpty, !path.hasPrefix("$("), FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("set DEXTER_LIVE_STAY_PDF to an accommodation voucher PDF to run this")
        }
        let key = env["ANTHROPIC_API_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty || key.hasPrefix("$("), "no API key in the environment")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        let images = BarcodeService
            .renderPages(pdfData: data, maxPages: TicketExtraction.extractionPageCap, targetLongEdge: 2200)
            .compactMap { $0.jpegDataCompat(quality: 0.85) }
        XCTAssertFalse(images.isEmpty, "the voucher must rasterise before it can be read")

        // The trip range is the context the scan path supplies, and it is what
        // resolves a voucher printing "Sun, Oct 11" with no year.
        let trip = LocalTrip(
            name: "Bali",
            startDate: WallClock.dayAnchor(fromISO: "2026-10-08")!,
            endDate: WallClock.dayAnchor(fromISO: "2026-10-11")!
        )
        let read = await TicketExtraction().read(
            bytes: data,
            isPDF: true,
            images: images,
            dateContext: TicketExtraction.tripDateContext(trip)
        )

        let segment = try XCTUnwrap(read.segments.first, "the voucher must read as at least one segment")
        XCTAssertEqual(segment.kind?.lowercased(), "stay", "a villa booking is a stay")

        // The issue itself: both dates, in their own fields.
        XCTAssertEqual(segment.dayDate, "2026-10-08", "day_date is the check-in")
        let checkOut = try XCTUnwrap(segment.endDate, "a stay without an end_date has been read wrong")
        XCTAssertEqual(checkOut, "2026-10-11", "end_date is the check-out")

        // And not in the fields it used to land in. An arrival on a stay is what
        // rendered the villa as "15:00 → 11:00" on the check-in day, and the
        // catch-all is where the check-out used to go as prose.
        XCTAssertNil(segment.arrivalTime, "a stay arrives at nothing")
        XCTAssertNil(segment.validThrough, "a check-out is not an expiry")
        for field in segment.otherFields {
            XCTAssertFalse(
                field.label.lowercased().contains("check-out")
                    || field.label.lowercased().contains("checkout"),
                "the check-out has a typed field now, so repeating it here writes it twice: \(field.label)"
            )
        }

        // A stay whose whole point is its length must survive the builder too, not
        // only the read. This is the row the timeline actually draws.
        var sortOrder: [Date: Int] = [:]
        let item = TicketExtraction().buildItem(
            trip: trip,
            extracted: segment,
            bcbp: read.bcbp,
            decoded: read.decoded,
            attachmentPath: "tickets/live.pdf",
            nextSortOrder: &sortOrder
        )
        XCTAssertEqual(item.kindEnum, .stay)
        XCTAssertNotNil(item.endDate, "the stop spans its nights")
        XCTAssertNil(item.arrivalTime)
    }
}
