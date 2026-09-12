import XCTest
import SwiftData
@testable import DexterMac

/// Live verification that a membership card scanned into the Wallet lands with
/// what the card prints on it (#522), against the real image and the real prompt.
///
/// Skipped unless both `DEXTER_LIVE_PASS_IMAGE` and `ANTHROPIC_API_KEY` are set, so
/// an ordinary run spends nothing and needs no network.
///
/// It exists because a stub cannot answer the question this issue turned on. The
/// schema could describe a membership card only for travel and events, so the model
/// had no honest shape to reply with and returned nothing at all — title, kind,
/// date, every field a fallback. Whether the widened schema actually gets the model
/// to return the card's number, its holder and its expiry is a fact about the model,
/// not about our decoding, so it is replayed rather than reasoned about.
///
/// Hosted on the Mac for the same reason as `LiveBoardingPassReadTests`:
/// `VNDetectBarcodesRequest` fails in the iOS Simulator for every input, and the
/// QR on this card is the credential the lounge desk reads.
@MainActor
final class LiveMembershipCardReadTests: XCTestCase {

    func testARealMembershipCardKeepsItsNumberHolderAndExpiry() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DEXTER_LIVE_PASS_IMAGE"] else {
            throw XCTSkip("set DEXTER_LIVE_PASS_IMAGE to the membership card image to run this")
        }
        try XCTSkipIf(env["ANTHROPIC_API_KEY"] == nil, "no API key in the environment")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        // The deterministic half first. The QR is what admits the holder, so a read
        // that loses it has failed however well the text came back.
        let decoded = try XCTUnwrap(
            PlatformImage(data: data).flatMap { BarcodeService.decode(image: $0) },
            "the card's QR must decode"
        )
        XCTAssertFalse(decoded.payload.isEmpty)

        // The pipeline decodes the COMPRESSED copy, not the original, so the
        // compression step has to survive a barcode. Asserted separately because a
        // card that loses its code between these two lines looks identical to one
        // whose code never decoded.
        let compressed = try TicketStorage.shared.compress(imageData: data)
        let fromCompressed = PlatformImage(data: compressed).flatMap { BarcodeService.decode(image: $0) }
        XCTAssertEqual(fromCompressed?.payload, decoded.payload, "compression must not lose the barcode")

        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let result = try await TicketExtraction().runForWallet(
            data: data,
            isPDF: false,
            context: store.context
        )
        XCTAssertFalse(result.degraded, "a membership card is a complete read, not a degraded one")

        let card = try XCTUnwrap(
            try store.context.fetch(FetchDescriptor<LocalWalletCard>()).first(where: { $0.clientUUID == result.itemUUID })
        )
        // The PATH, not the model: the context is gone by teardown and touching a
        // reset model instance traps.
        let storedPath = card.attachmentPath
        addTeardownBlock {
            try? TicketStorage.shared.delete(relativePath: storedPath)
        }

        // Printed on the card, so all of it has to survive the trip.
        XCTAssertEqual(card.kindEnum, .pass, "a lounge card is a pass, not an event or a flight")
        XCTAssertNotEqual(card.title, "Ticket", "the title must be read off the card, not fall back")
        XCTAssertFalse(card.barcodePayload.isEmpty, "the QR payload must be stored")
        XCTAssertNotNil(card.endDate, "the printed expiry must land in endDate")

        let meta = try XCTUnwrap(card.ticketMeta)
        XCTAssertNotNil(meta.guestName, "the member name must be read")

        // The card number has no typed slot and reaches the card through the shared
        // other_fields array. It is the one fact you would read out at a desk.
        let values = (meta.fields ?? []).map(\.value).joined(separator: " | ")
        XCTAssertFalse(card.sourceConfirmation.isEmpty, "the card number must be captured")
        print("kind=\(card.kind) title=\(card.title) endDate=\(String(describing: card.endDate))")
        print("guest=\(meta.guestName ?? "-") fields=\(values)")
        print("barcode=\(card.barcodeSymbology) conf=\(card.sourceConfirmation)")
    }

    /// The card already in the Wallet is the one that matters: it was scanned
    /// before the schema could describe it, and re-scanning would throw away the
    /// title and date its owner typed to make it usable. "Read again" is the path
    /// that fixes it in place (#522).
    func testReadingAnAlreadyScannedCardAgainFillsItIn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DEXTER_LIVE_PASS_IMAGE"] else {
            throw XCTSkip("set DEXTER_LIVE_PASS_IMAGE to the membership card image to run this")
        }
        try XCTSkipIf(env["ANTHROPIC_API_KEY"] == nil, "no API key in the environment")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        let stored = try TicketStorage.shared.saveCompressedJpeg(
            try TicketStorage.shared.compress(imageData: data)
        )
        addTeardownBlock { try? TicketStorage.shared.delete(relativePath: stored) }

        // Exactly the row the shipped bug produced, plus the two values its owner
        // typed afterwards. Both must survive.
        let store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let card = LocalWalletCard(
            kind: .pass,
            title: "Priority Pass",
            dayDate: WallClock.todayAnchor(),
            notes: "mine",
            attachmentPath: stored
        )
        store.context.insert(card)
        try store.context.save()
        let id = card.clientUUID

        try await TicketExtraction().rereadWalletCard(cardUUID: id, context: store.context)

        let fresh = try XCTUnwrap(
            try store.context.fetch(FetchDescriptor<LocalWalletCard>()).first(where: { $0.clientUUID == id })
        )
        XCTAssertFalse(fresh.sourceConfirmation.isEmpty, "the card number must arrive on a re-read")
        XCTAssertFalse(fresh.barcodePayload.isEmpty, "the QR must arrive on a re-read")
        XCTAssertNotNil(fresh.endDate, "the expiry must arrive on a re-read")
        XCTAssertEqual(fresh.kindEnum, .pass)
        XCTAssertEqual(fresh.attachmentPath, stored, "the stored file is not replaced")
        XCTAssertEqual(fresh.notes, "mine", "a re-read never touches what the person wrote")
        print("reread: conf=\(fresh.sourceConfirmation) end=\(String(describing: fresh.endDate)) barcode=\(fresh.barcodeSymbology)")
    }
}
