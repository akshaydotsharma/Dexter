import XCTest
@testable import DexterMac

/// Which card a document attached to a task or a trip stop draws (#520).
///
/// The layout used to be hard-coded to `.event` for every `LocalTaskTicket`, so
/// four Emirates boarding passes on one trip were drawn as concert tickets: event
/// colour, ticket glyph, and no route hero, while each row carried a full IATA
/// BCBP payload naming both airports.
///
/// The rule is now a decision in code, and a decision in code needs a test. The
/// two halves matter equally: a real pass must be promoted, and everything that
/// is NOT a pass must be left exactly where it was. The payloads below are the
/// real ones off those rows.
final class WalletBoardingPassLayoutTests: XCTestCase {

    /// EK348 DXB→SIN, seat 18D. An Aztec pass off the return leg.
    private let ek348 = "M1SHARMA/AKSHAYMR     EIZDHBW DXBSINEK 0348 256Y018D0285 33F>60B1MM6254BEK 2A17622047133340                        25K ^100"
    /// EK091 DXB→MXP, seat 58G. Flight number 091 — the padding case.
    private let ek091 = "M1SHARMA/AKSHAYMR     EIZDHBW DXBMXPEK 0091 245Y058G0379 33F>60B1WM6243BEK 2A17622047133330                        25K ^100"

    private func ticket(
        payload: String,
        title: String = "",
        seat: String = "",
        metaJSON: String = ""
    ) -> LocalTaskTicket {
        LocalTaskTicket(
            todoClientUUID: UUID(),
            barcodePayload: payload,
            eventTitle: title,
            seat: seat,
            ticketMetaJSON: metaJSON
        )
    }

    // MARK: - Promoted

    func testBoardingPassPayloadDrawsTheBoardingPassCard() {
        let card = TicketCardData(ticket(payload: ek348, title: "EK348 · DXB→SIN", seat: "18D"), ownerTitle: "Flight home")

        XCTAssertEqual(card.layout, .boardingPass)
        XCTAssertEqual(card.eyebrow, "BOARDING PASS")
        XCTAssertEqual(card.heroGlyph, "airplane")
        XCTAssertEqual(card.meta?.originCode, "DXB")
        XCTAssertEqual(card.meta?.destinationCode, "SIN")
        XCTAssertEqual(card.seat, "18D")
        XCTAssertEqual(card.meta?.isBoardingPass, true)
    }

    /// The card is read against a departure board, and the board says EK091.
    /// `BCBPTicket.flightLabel` strips the barcode's leading zero and gives EK91.
    func testFlightNumberKeepsItsLeadingZero() {
        let card = TicketCardData(ticket(payload: ek091), ownerTitle: "Milan")
        XCTAssertEqual(card.meta?.flightNumber, "EK091")
    }

    /// The extractor read the printed document and knows things BCBP does not
    /// carry at all. Where both have an answer, the document's wins.
    func testStoredMetaIsNotOverwrittenByTheBarcode() {
        var stored = TicketMeta()
        stored.originCode = "DXB"
        stored.destinationCode = "SIN"
        stored.flightNumber = "EK 348"
        stored.airline = "Emirates"
        let json = stored.encodedString()

        let card = TicketCardData(ticket(payload: ek348, metaJSON: json), ownerTitle: "Flight home")

        XCTAssertEqual(card.layout, .boardingPass)
        XCTAssertEqual(card.meta?.flightNumber, "EK 348")
        XCTAssertEqual(card.meta?.airline, "Emirates")
    }

    /// The Wallet's own colour and label follow the card, rather than being
    /// decided a second time and disagreeing with it.
    func testWalletKindFollowsTheLayout() {
        let card = TicketCardData(ticket(payload: ek348), ownerTitle: "Flight home")
        XCTAssertEqual(WalletEntry.kind(for: card.layout), .boardingPass)
        XCTAssertEqual(WalletCardKind.boardingPass.displayName, "Boarding pass")
    }

    // MARK: - Left alone

    /// The Trenord day pass: a real, scannable code that is not a boarding pass.
    func testNonBoardingPassBarcodeKeepsTheEventCard() {
        let card = TicketCardData(ticket(payload: "AYXRPIWTZ", title: "TRENORD DAY PASS"), ownerTitle: "Monza")
        XCTAssertEqual(card.layout, .event)
        XCTAssertEqual(card.heroGlyph, "ticket")
    }

    func testCheckInLinkKeepsTheEventCard() {
        let card = TicketCardData(
            ticket(payload: "https://luma.com/check-in/evt-abc123", title: "Vibe Coders SG #2"),
            ownerTitle: "Vibe Coders"
        )
        XCTAssertEqual(card.layout, .event)
    }

    func testNoBarcodeKeepsTheEventCard() {
        let card = TicketCardData(ticket(payload: "", title: "PADEL"), ownerTitle: "Padel")
        XCTAssertEqual(card.layout, .event)
        XCTAssertEqual(WalletEntry.kind(for: card.layout), .event)
    }

    /// A route hero with one end blank reads worse than the event card it would
    /// replace, so a pass that names only one airport is not promoted. The
    /// payload below is `ek348` with its destination field blanked.
    func testPassWithOneEndpointKeepsTheEventCard() {
        let oneEnded = ek348.replacingOccurrences(of: "DXBSINEK", with: "DXB   EK")
        let card = TicketCardData(ticket(payload: oneEnded), ownerTitle: "Flight home")
        XCTAssertEqual(card.layout, .event)
    }
}
