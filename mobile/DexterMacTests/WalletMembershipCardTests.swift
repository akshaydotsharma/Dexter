import XCTest
import SwiftData
@testable import DexterMac

/// The code rules a membership card scanned into the Wallet depends on (#522).
///
/// The live read is covered by `LiveMembershipCardReadTests`, which needs a key and
/// a network. These are the decisions made in code around it, and each one shipped
/// wrong: the barcode was thrown away unless it was a boarding pass, a pass aged out
/// of the Wallet overnight, and the extractor's own "pass" answer had nowhere to go.
@MainActor
final class WalletMembershipCardTests: XCTestCase {

    // MARK: - The barcode belongs to a segment, not to a boarding pass

    /// The defect exactly: a Priority Pass reached the Wallet with its QR decoded,
    /// read, and then dropped, because the raw barcode was placed by asking which
    /// LEG of a flight it described.
    func testASingleSegmentTakesTheBarcodeEvenWhenItIsNotABoardingPass() {
        let index = TicketExtraction.barcodeSegmentIndex(nil, segmentCount: 1, in: [])
        XCTAssertEqual(index, 0)
    }

    /// A failed extraction still builds one record, and it must keep the code.
    func testADegradedReadStillTakesTheBarcode() {
        XCTAssertEqual(TicketExtraction.barcodeSegmentIndex(nil, segmentCount: 1, in: []), 0)
    }

    /// Several segments still need the boarding pass to tell them apart. Handing a
    /// wrong code to a leg is worse than handing it none (#500).
    func testSeveralSegmentsWithNoBoardingPassPlaceNoBarcode() {
        let segments = [
            ExtractedTicket(input: ["title": .string("Outbound"), "kind": .string("transport")]),
            ExtractedTicket(input: ["title": .string("Return"), "kind": .string("transport")]),
        ]
        XCTAssertNil(TicketExtraction.barcodeSegmentIndex(nil, segmentCount: 2, in: segments))
    }

    /// And when it can tell them apart, it still does.
    func testSeveralSegmentsMatchTheBoardingPassToItsOwnLeg() {
        let segments = [
            ExtractedTicket(input: ["title": .string("Out"), "kind": .string("transport"), "flight_number": .string("EK315")]),
            ExtractedTicket(input: ["title": .string("Back"), "kind": .string("transport"), "flight_number": .string("EK091")]),
        ]
        var pass = BCBPTicket()
        pass.carrier = "EK"
        pass.flightNumber = "91"
        XCTAssertEqual(TicketExtraction.barcodeSegmentIndex(pass, segmentCount: 2, in: segments), 1)
    }

    // MARK: - A card with no date

    /// `day_date` stopped being required, so a card answering with a title, a kind
    /// and an expiry is a complete read. It used to count as nothing at all.
    func testACardWithAnExpiryAndNoDateIsNotAnEmptyRead() {
        let segments = ExtractedTicket.segments(fromToolInput: [
            "segments": .array([.object([
                "title": .string("Priority Pass"),
                "kind": .string("pass"),
                "valid_through": .string("2026-12-31"),
            ])])
        ])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.validThrough, "2026-12-31")
        XCTAssertNil(segments.first?.dayDate)
    }

    func testAnExtractorPassBecomesAWalletPass() {
        XCTAssertEqual(
            WalletCardKind.infer(kind: "pass", mode: nil, isBoardingPass: false, hasFlightNumber: false),
            .pass
        )
    }

    /// A lounge card naming an airline must not be dragged into a boarding pass by
    /// the flight-number fallback in the default arm.
    func testAPassIsStillAPassWhenTheCardMentionsAFlight() {
        XCTAssertEqual(
            WalletCardKind.infer(kind: "pass", mode: nil, isBoardingPass: false, hasFlightNumber: true),
            .pass
        )
    }

    // MARK: - A pass does not fall into Past

    private func card(kind: WalletCardKind, day: Date, end: Date? = nil) -> LocalWalletCard {
        LocalWalletCard(kind: kind, title: "x", dayDate: day, endDate: end)
    }

    func testAPassWithNoExpiryNeverAgesOut() {
        let yesterday = WallClock.storedDay(WallClock.todayAnchor(), byAdding: -1)
        let entries = WalletEntry.build(cards: [card(kind: .pass, day: yesterday)], itineraryItems: [], trips: [])
        let groups = WalletEntry.grouped(entries, today: WallClock.todayAnchor())
        XCTAssertEqual(groups.upcoming.count, 1, "a membership card scanned yesterday is still valid today")
        XCTAssertTrue(groups.past.isEmpty)
    }

    func testAPassWithAnExpiryAgesOutOnIt() {
        let longAgo = WallClock.storedDay(WallClock.todayAnchor(), byAdding: -30)
        let entries = WalletEntry.build(cards: [card(kind: .pass, day: longAgo, end: longAgo)], itineraryItems: [], trips: [])
        let groups = WalletEntry.grouped(entries, today: WallClock.todayAnchor())
        XCTAssertEqual(groups.past.count, 1, "an expired membership card belongs in Past")
    }

    /// The other kinds keep the old rule exactly. A boarding pass that never left
    /// Upcoming would be the opposite defect.
    func testABoardingPassStillAgesOutOnItsDay() {
        let yesterday = WallClock.storedDay(WallClock.todayAnchor(), byAdding: -1)
        let entries = WalletEntry.build(cards: [card(kind: .boardingPass, day: yesterday)], itineraryItems: [], trips: [])
        let groups = WalletEntry.grouped(entries, today: WallClock.todayAnchor())
        XCTAssertEqual(groups.past.count, 1)
        XCTAssertTrue(groups.upcoming.isEmpty)
    }
}
