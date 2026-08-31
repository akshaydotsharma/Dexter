import XCTest
import PDFKit
@testable import DexterMac

/// Live verification of the multi-pass read (#500, #501), against the real
/// document and the real prompt.
///
/// Skipped unless both `DEXTER_LIVE_TICKET_PDF` and `ANTHROPIC_API_KEY` are set, so
/// an ordinary run never spends money or needs a network. It exists because the two
/// things that broke here cannot be proved by a stub:
///
///  - Whether the model actually returns one segment per pass, and reports the page
///    it read each off, when handed the pages of a real Emirates download. Stub
///    descriptions gave measurably worse output on the itinerary path in #475 and
///    would have hidden a live finding, so this replays the shipped prompt and the
///    shipped schema rather than a copy of them.
///  - Whether the boarding group is read at all. It is printed sideways in a grey
///    block and was skipped by four earlier prompts.
///
/// Hosted on the MAC rather than in the iOS suite on purpose: `VNDetectBarcodesRequest`
/// fails in the iOS Simulator for every input, so the per-page barcode decode — the
/// half of this that decides what a card presents at a gate — can only be exercised
/// here.
@MainActor
final class LiveBoardingPassReadTests: XCTestCase {

    func testARealTwoLegDownloadReadsBothPassesWithTheirOwnBarcodes() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DEXTER_LIVE_TICKET_PDF"] else {
            throw XCTSkip("set DEXTER_LIVE_TICKET_PDF to the boarding-pass PDF to run this")
        }
        try XCTSkipIf(env["ANTHROPIC_API_KEY"] == nil, "no API key in the environment")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        // The barcodes first, on their own: this is the deterministic half and it
        // must see one code per page before anything else is worth asserting.
        let pageBarcodes = BarcodeService.decodePages(
            pdfData: data,
            maxPages: TaskTicketExtraction.extractionPageCap
        )
        let decoded = pageBarcodes.compactMap { $0?.payload }
        XCTAssertGreaterThanOrEqual(decoded.count, 2, "one PDF417 per pass should decode")
        XCTAssertEqual(Set(decoded).count, decoded.count, "the pages must not decode to one shared payload")

        let set = try await TaskTicketExtraction().read(
            data: data,
            isPDF: true,
            context: TaskTicketContext(title: "Flight EK315 SIN→DXB")
        )
        addTeardownBlock {
            for stored in set.attachmentPaths {
                try? TicketStorage.taskTickets.delete(relativePath: stored)
            }
        }

        XCTAssertEqual(set.reads.count, 2, "a two-pass download must read as two tickets")

        let titles = set.reads.compactMap { $0.extracted?.eventTitle }
        let flights = Set(titles.compactMap { TaskTicketReadSet.flightDesignator($0) })
        XCTAssertEqual(flights.count, 2, "the two passes must not be the same flight: \(titles)")

        let seats = set.reads.compactMap { $0.extracted?.seat }
        XCTAssertEqual(Set(seats).count, 2, "each pass carries its own seat: \(seats)")

        let payloads = set.reads.map(\.barcodePayload).filter { !$0.isEmpty }
        XCTAssertEqual(payloads.count, 2, "each pass carries a barcode")
        XCTAssertEqual(Set(payloads).count, 2, "no two cards may share one payload")

        // #501: the group is printed on both passes of this download.
        let groups = set.reads.compactMap {
            $0.ticket(owner: .task(UUID())).ticketMeta?.boardingGroup
        }
        XCTAssertEqual(groups.count, 2, "the boarding group must be read off both passes")

        // And the leg matching the stop it was attached to is the one surfaced.
        let outbound = try XCTUnwrap(set.matching(flight: "Flight EK315 SIN→DXB"))
        XCTAssertEqual(TaskTicketReadSet.flightDesignator(outbound.extracted?.eventTitle), "EK0315")
        let inbound = try XCTUnwrap(set.matching(flight: "Flight EK091 DXB→MXP"))
        XCTAssertEqual(TaskTicketReadSet.flightDesignator(inbound.extracted?.eventTitle), "EK0091")
        XCTAssertNotEqual(outbound.barcodePayload, inbound.barcodePayload)
    }
}
