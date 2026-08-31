import XCTest
import SwiftData
@testable import PersonalDashboard

/// Deleting a card from the Wallet, whatever made it (#503).
///
/// Before this, "Delete card" appeared in a card's long-press menu only when the
/// Wallet owned the row: `walletCardID(of:)` returned nil for a trip's ticket, a
/// task's document and a stop's document, so `onDelete` was nil and the menu had no
/// Delete in it. The two wrong EK315 cards from #500 could not be cleared from the
/// Wallet at all.
///
/// What these pin is not that a delete exists — it is that each source deletes the
/// RIGHT thing. Three of the four have a row to remove. The fourth does not: a
/// stop's inline ticket is fields ON an itinerary row, so removing the pass must
/// leave the stop, its day and its time on the trip.
@MainActor
final class WalletCardDeletionTests: XCTestCase {

    // MARK: - What each source deletes

    func testAWalletCardDeletesItsOwnRow() {
        let id = UUID()
        XCTAssertEqual(WalletEntry.Source.wallet(cardID: id).deletion, .walletCard(id))
    }

    func testATaskDocumentDeletesTheDocumentNotTheTask() {
        let ticketID = UUID()
        let source = WalletEntry.Source.task(ticketID: ticketID, todoID: UUID(), taskTitle: "Padel")
        XCTAssertEqual(source.deletion, .document(ticketID: ticketID))
    }

    func testATripDocumentDeletesTheDocumentNotTheStop() {
        let ticketID = UUID()
        let source = WalletEntry.Source.tripDocument(
            ticketID: ticketID, itemID: UUID(), tripID: UUID(), tripName: "Italy"
        )
        XCTAssertEqual(source.deletion, .document(ticketID: ticketID))
    }

    /// The one that must NOT remove a row. A stop's inline ticket has no row of its
    /// own, so deleting the card can only mean clearing the pass off the stop.
    func testAStopsInlineTicketClearsTheStopRatherThanRemovingIt() {
        let itemID = UUID()
        let source = WalletEntry.Source.trip(itemID: itemID, tripID: UUID(), tripName: "Italy")
        XCTAssertEqual(source.deletion, .stopTicket(itemID: itemID))
    }

    /// Every source has an answer. A new source added without one would land here
    /// rather than shipping a card with no delete, which is the defect itself.
    func testEverySourceCanBeDeleted() {
        let sources: [WalletEntry.Source] = [
            .wallet(cardID: UUID()),
            .trip(itemID: UUID(), tripID: UUID(), tripName: "Italy"),
            .task(ticketID: UUID(), todoID: UUID(), taskTitle: "Padel"),
            .tripDocument(ticketID: UUID(), itemID: UUID(), tripID: UUID(), tripName: "Italy")
        ]
        for source in sources {
            XCTAssertFalse(source.deletionTitle.isEmpty, "\(source) has no confirmation title")
            XCTAssertFalse(source.deletionMessage.isEmpty, "\(source) has no confirmation message")
        }
    }

    // MARK: - What the confirmation promises

    /// The half that matters: someone about to remove a boarding pass from a trip
    /// stop has to be told the flight stays on the itinerary BEFORE they tap.
    func testTheConfirmationNamesWhatSurvives() {
        let stop = WalletEntry.Source.trip(itemID: UUID(), tripID: UUID(), tripName: "Italy")
        XCTAssertEqual(stop.deletionTitle, "Remove this pass?")
        XCTAssertEqual(stop.deletionConfirmLabel, "Remove")
        XCTAssertTrue(stop.deletionMessage.contains("stop stays"), stop.deletionMessage)

        let document = WalletEntry.Source.tripDocument(
            ticketID: UUID(), itemID: UUID(), tripID: UUID(), tripName: "Italy"
        )
        XCTAssertEqual(document.deletionTitle, "Delete this card?")
        XCTAssertEqual(document.deletionConfirmLabel, "Delete")
        XCTAssertTrue(document.deletionMessage.contains("Italy"), document.deletionMessage)
        XCTAssertTrue(document.deletionMessage.contains("stop it was attached to stays"),
                      document.deletionMessage)

        let task = WalletEntry.Source.task(ticketID: UUID(), todoID: UUID(), taskTitle: "Padel")
        XCTAssertTrue(task.deletionMessage.contains("Padel"), task.deletionMessage)
        XCTAssertTrue(task.deletionMessage.contains("task itself stays"), task.deletionMessage)
    }

    /// An unnamed owner must not produce a message with an empty pair of quotes in it.
    func testAnUnnamedOwnerReadsAsAnOwner() {
        let task = WalletEntry.Source.task(ticketID: UUID(), todoID: UUID(), taskTitle: "   ")
        XCTAssertTrue(task.deletionMessage.contains("its task"), task.deletionMessage)
        XCTAssertFalse(task.deletionMessage.contains("\u{201C}\u{201D}"), task.deletionMessage)
    }

    /// Deleting is now offered everywhere; editing still is not. A record keeps one
    /// editor, and the two questions must not collapse back into one flag.
    func testDeletingIsOfferedMoreWidelyThanEditing() {
        let borrowed = WalletEntry.Source.tripDocument(
            ticketID: UUID(), itemID: UUID(), tripID: UUID(), tripName: "Italy"
        )
        XCTAssertFalse(borrowed.isEditableInWallet)
        XCTAssertEqual(borrowed.deletion, .document(ticketID: borrowed.documentID!))
    }

    // MARK: - Clearing a stop keeps the stop

    /// The destructive case, exercised on a real model: everything that identifies
    /// the stop has to survive, and everything that was the ticket has to go.
    func testClearingAStopsTicketKeepsThePlanAndDropsThePass() throws {
        let container = try ModelContainer(
            for: LocalItineraryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        var meta = TicketMeta()
        meta.boardingGroup = "5"
        let day = Calendar(identifier: .gregorian).startOfDay(for: Date())
        let departure = Date(timeIntervalSince1970: 1_756_000_000)
        let item = LocalItineraryItem(
            tripUUID: UUID(),
            dayDate: day,
            kind: .transport,
            transportMode: .flight,
            title: "Flight EK315 SIN\u{2192}DXB",
            notes: "Window seat",
            startTime: departure,
            sortOrder: 3,
            address: "Changi Airport",
            googleMapsLink: "https://maps.google.com/?q=Changi",
            attachmentPath: "tickets/pass.pdf",
            barcodePayload: "M1SHARMA/AKSHAYMR",
            barcodeSymbology: "pdf417",
            seat: "25J",
            gate: "B22",
            venue: "Terminal 3",
            ticketMetaJSON: meta.encodedString()
        )
        context.insert(item)
        try context.save()

        item.clearTicketFields()
        try context.save()

        // The pass is gone.
        XCTAssertEqual(item.attachmentPath, "")
        XCTAssertEqual(item.barcodePayload, "")
        XCTAssertEqual(item.barcodeSymbology, "")
        XCTAssertEqual(item.seat, "")
        XCTAssertEqual(item.gate, "")
        XCTAssertEqual(item.venue, "")
        XCTAssertEqual(item.ticketMetaJSON, "")
        XCTAssertNil(item.ticketMeta)
        XCTAssertFalse(item.hasTicket)

        // The plan is not.
        XCTAssertEqual(item.title, "Flight EK315 SIN\u{2192}DXB")
        XCTAssertEqual(item.notes, "Window seat")
        XCTAssertEqual(item.dayDate, day)
        XCTAssertEqual(item.startTime, departure)
        XCTAssertEqual(item.sortOrder, 3)
        XCTAssertEqual(item.address, "Changi Airport")
        XCTAssertEqual(item.googleMapsLink, "https://maps.google.com/?q=Changi")
        XCTAssertEqual(item.kindEnum, .transport)

        // And the row is still on the trip.
        let stops = try context.fetch(FetchDescriptor<LocalItineraryItem>())
        XCTAssertEqual(stops.count, 1)
    }

    /// Running it on a stop that never had a ticket changes nothing but the timestamp,
    /// so a double-tap on the confirmation cannot damage anything.
    func testClearingAStopWithNoTicketIsHarmless() {
        let item = LocalItineraryItem(
            tripUUID: UUID(),
            dayDate: Date(),
            kind: .place,
            title: "Duomo di Milano"
        )
        item.clearTicketFields()
        XCTAssertEqual(item.title, "Duomo di Milano")
        XCTAssertFalse(item.hasTicket)
    }
}

private extension WalletEntry.Source {
    /// The document id this source deletes, for a test that wants to name it.
    var documentID: UUID? {
        if case .document(let id) = deletion { return id }
        return nil
    }
}
