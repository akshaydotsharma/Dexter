import XCTest
import PDFKit
@testable import PersonalDashboard

/// Multi-leg boarding-pass uploads and the boarding group (#500, #501).
///
/// The Wallet attach path is a second ingestion path for the same object as the
/// itinerary one, and it had drifted a whole fix behind. A two-page Emirates
/// download — EK315 SIN→DXB on page 1, EK091 DXB→MXP on page 2 — produced one
/// card, always page one's, whichever leg it was attached to. Both cards on the
/// Italy trip therefore read EK315 / seat 25J and carried the SIN→DXB barcode,
/// including the one hanging off the DXB→MXP stop.
///
/// These pin every piece of that: the `segments` array is parsed, a page of
/// baggage terms is not a ticket, each pass takes the barcode from its OWN page,
/// no two passes can ever share one payload, a leg is matched to its stop by
/// flight designator, and the boarding group survives as a typed field with a
/// slot on the card face.
@MainActor
final class MultiLegBoardingPassTests: XCTestCase {

    // MARK: - Fixtures

    private func pass(
        title: String,
        date: String = "2026-09-02",
        seat: String? = nil,
        group: String? = nil,
        page: Int? = nil,
        time: String? = nil,
        other: [(String, String)] = []
    ) -> AnthropicJSONValue {
        var fields: [String: AnthropicJSONValue] = [
            "event_title": .string(title),
            "event_date": .string(date),
            "year_was_printed": .string("yes")
        ]
        if let seat { fields["seat"] = .string(seat) }
        if let group { fields["boarding_group"] = .string(group) }
        if let page { fields["source_page"] = .int(page) }
        if let time { fields["start_time_text"] = .string(time) }
        if !other.isEmpty {
            fields["other_fields"] = .array(other.map { pair in
                .object([
                    "label_in_english": .string(pair.0),
                    "value_as_printed": .string(pair.1)
                ])
            })
        }
        return .object(fields)
    }

    private func barcode(_ payload: String) -> DecodedBarcode {
        DecodedBarcode(payload: payload, symbology: .pdf417, boundingBox: .zero)
    }

    /// The two payloads actually decoded off the Italy download.
    private let outboundPayload = "M1SHARMA/AKSHAYMR     EIZDHBW SINDXBEK 0315 245Y025J0265 337"
    private let returnPayload = "M1SHARMA/AKSHAYMR     EIZDHBW DXBMXPEK 0091 245Y058G0379 337"

    // MARK: - Segment parsing

    /// The defect itself: a two-pass download must survive as TWO tickets.
    func testBothLegsOfAConnectingBookingAreParsed() {
        let input: [String: AnthropicJSONValue] = [
            "segments": .array([
                pass(title: "EK315", seat: "25J", group: "5", page: 1, time: "10:35"),
                pass(title: "EK091", seat: "58G", group: "5", page: 2, time: "15:30")
            ])
        ]
        let segments = ExtractedTaskTicket.segments(fromToolInput: input)

        XCTAssertEqual(segments.count, 2, "a pass per leg, not one for the file")
        XCTAssertEqual(segments[0].eventTitle, "EK315")
        XCTAssertEqual(segments[0].seat, "25J")
        XCTAssertEqual(segments[0].sourcePage, 1)
        XCTAssertEqual(segments[1].eventTitle, "EK091")
        XCTAssertEqual(segments[1].seat, "58G", "the return leg keeps its own seat")
        XCTAssertEqual(segments[1].sourcePage, 2)
    }

    /// A model answering in the pre-#500 flat shape still yields one usable ticket,
    /// so a schema the model ignores degrades rather than losing the upload.
    func testAFlatAnswerIsReadAsASingleTicket() {
        guard case let .object(flat) = pass(title: "Coldplay", seat: "12A") else {
            return XCTFail("fixture shape changed")
        }
        let segments = ExtractedTaskTicket.segments(fromToolInput: flat)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].eventTitle, "Coldplay")
    }

    /// A page of baggage terms is not a ticket. It comes back with no title, no date
    /// and no time, and must not become a blank third card.
    func testAPageOfTermsIsNotATicket() {
        let input: [String: AnthropicJSONValue] = [
            "segments": .array([
                pass(title: "EK315", page: 1),
                .object(["other_fields": .array([])])
            ])
        ]
        XCTAssertEqual(ExtractedTaskTicket.segments(fromToolInput: input).count, 1)
    }

    /// Nothing readable at all means nothing to build, and the caller degrades.
    func testNoReadableTicketYieldsNoSegments() {
        XCTAssertTrue(ExtractedTaskTicket.segments(fromToolInput: [:]).isEmpty)
    }

    // MARK: - Barcode per page

    /// The gate-facing half of the bug: each pass must carry the barcode printed on
    /// its own page, not the first one found in the document.
    func testEachLegTakesTheBarcodeFromItsOwnPage() {
        let segments = ExtractedTaskTicket.segments(fromToolInput: [
            "segments": .array([
                pass(title: "EK315", page: 1),
                pass(title: "EK091", page: 2)
            ])
        ])
        let assigned = TaskTicketExtraction.barcodes(
            for: segments,
            pageBarcodes: [barcode(outboundPayload), barcode(returnPayload)]
        )

        XCTAssertEqual(assigned.count, 2)
        XCTAssertEqual(assigned[0]?.payload, outboundPayload)
        XCTAssertEqual(assigned[1]?.payload, returnPayload, "the return leg must not carry the outbound code")
    }

    /// With no `source_page` reported, position stands in for it.
    func testPositionStandsInForAMissingSourcePage() {
        let segments = ExtractedTaskTicket.segments(fromToolInput: [
            "segments": .array([pass(title: "EK315"), pass(title: "EK091")])
        ])
        let assigned = TaskTicketExtraction.barcodes(
            for: segments,
            pageBarcodes: [barcode(outboundPayload), barcode(returnPayload)]
        )

        XCTAssertEqual(assigned[0]?.payload, outboundPayload)
        XCTAssertEqual(assigned[1]?.payload, returnPayload)
    }

    /// The exact shape of the shipped defect: two cards holding one payload. When
    /// only page 1 decoded, the second leg gets NOTHING rather than page 1's code —
    /// a missing barcode is recoverable, a wrong one is not.
    func testTwoLegsNeverShareOneBarcode() {
        let segments = ExtractedTaskTicket.segments(fromToolInput: [
            "segments": .array([
                pass(title: "EK315", page: 1),
                pass(title: "EK091", page: 1)
            ])
        ])
        let assigned = TaskTicketExtraction.barcodes(
            for: segments,
            pageBarcodes: [barcode(outboundPayload), nil]
        )

        XCTAssertEqual(assigned[0]?.payload, outboundPayload)
        XCTAssertNil(assigned[1], "a wrong barcode reads as real and fails at the gate")
    }

    /// An ordinary one-ticket upload is untouched by all of this: it still takes the
    /// first barcode found anywhere in the document, which is what the old
    /// first-hit decode returned.
    func testASingleTicketTakesTheFirstBarcodeFound() {
        let segments = ExtractedTaskTicket.segments(fromToolInput: [
            "segments": .array([pass(title: "Coldplay")])
        ])
        let assigned = TaskTicketExtraction.barcodes(
            for: segments,
            pageBarcodes: [nil, barcode("QR-PAYLOAD")]
        )

        XCTAssertEqual(assigned.count, 1)
        XCTAssertEqual(assigned[0]?.payload, "QR-PAYLOAD")
    }

    /// A document with no barcode at all still yields one slot per ticket.
    func testNoBarcodeYieldsOneEmptySlotPerTicket() {
        let segments = ExtractedTaskTicket.segments(fromToolInput: [
            "segments": .array([pass(title: "EK315"), pass(title: "EK091")])
        ])
        let assigned = TaskTicketExtraction.barcodes(for: segments, pageBarcodes: [])

        XCTAssertEqual(assigned.count, 2)
        XCTAssertTrue(assigned.allSatisfy { $0 == nil })
    }

    // MARK: - Matching a leg to its stop

    func testFlightDesignatorIsFoundInAStopTitle() {
        XCTAssertEqual(TaskTicketReadSet.flightDesignator("Flight EK091 DXB→MXP"), "EK0091")
        XCTAssertEqual(TaskTicketReadSet.flightDesignator("EK315"), "EK0315")
        XCTAssertEqual(TaskTicketReadSet.flightDesignator("6E 1234 BOM→DEL"), "6E1234")
    }

    /// Zero-padded, because a BCBP prints EK0091 where a booking mail prints EK91.
    func testPaddingMakesTheSameFlightMatchAcrossSources() {
        XCTAssertEqual(
            TaskTicketReadSet.flightDesignator("EK91"),
            TaskTicketReadSet.flightDesignator("Flight EK091 DXB→MXP")
        )
    }

    /// The false matches that would put a boarding pass on a restaurant booking.
    func testOrdinaryTitlesAreNotFlights() {
        XCTAssertNil(TaskTicketReadSet.flightDesignator("Lunch at 12"))
        XCTAssertNil(TaskTicketReadSet.flightDesignator("Via De Amicis 43 - Leia Hospitality"))
        XCTAssertNil(TaskTicketReadSet.flightDesignator("Duomo di Milano"))
        XCTAssertNil(TaskTicketReadSet.flightDesignator("Terminal T2"))
        XCTAssertNil(TaskTicketReadSet.flightDesignator(nil))
        XCTAssertNil(TaskTicketReadSet.flightDesignator(""))
    }

    /// Attaching the file to the DXB→MXP stop must surface the DXB→MXP pass, which
    /// is precisely what failed: the second attach re-read page one.
    func testTheSetPicksTheLegMatchingTheStop() {
        let set = readSet(
            titles: ["EK315", "EK091"],
            payloads: [outboundPayload, returnPayload]
        )

        XCTAssertEqual(
            set.matching(flight: "Flight EK091 DXB→MXP")?.barcodePayload,
            returnPayload
        )
        XCTAssertEqual(
            set.matching(flight: "Flight EK315 SIN→DXB")?.barcodePayload,
            outboundPayload
        )
        XCTAssertNil(set.matching(flight: "Duomo di Milano"), "a stop naming no flight matches nothing")
    }

    /// Every stored copy has to be reclaimable, or a cancelled multi-leg upload
    /// strands a file per leg.
    func testTheSetExposesEveryStoredCopy() {
        let set = readSet(titles: ["EK315", "EK091"], payloads: ["a", "b"])

        XCTAssertTrue(set.isMultiple)
        XCTAssertEqual(set.attachmentPaths.count, 2)
        XCTAssertEqual(Set(set.attachmentPaths).count, 2, "one card per file copy, never a shared path")
    }

    private func readSet(titles: [String?], payloads: [String]) -> TaskTicketReadSet {
        TaskTicketReadSet(zip(titles, payloads).enumerated().map { index, pair in
            var extracted = ExtractedTaskTicket(input: [:])
            extracted.eventTitle = pair.0
            return TaskTicketRead(
                attachmentPath: "task-tickets/leg-\(index).pdf",
                barcodePayload: pair.1,
                barcodeSymbology: "pdf417",
                extracted: extracted,
                degradeMessage: nil
            )
        })
    }

    // MARK: - An untitled pass

    /// What the live read actually returns: both passes correct in every field and
    /// NEITHER carrying an event_title, because a boarding pass prints no event name.
    /// The barcode has to supply the flight, or routing has nothing to match on and
    /// both cards inherit the title of whichever stop the file was dropped on.
    func testAnUntitledPassIsIdentifiedByItsBarcode() {
        let set = readSet(titles: [nil, nil], payloads: [outboundPayload, returnPayload])

        XCTAssertEqual(set.reads[0].flightDesignator, "EK0315")
        XCTAssertEqual(set.reads[1].flightDesignator, "EK0091")
        XCTAssertEqual(
            set.matching(flight: "Flight EK091 DXB→MXP")?.barcodePayload,
            returnPayload,
            "the second leg must be findable with no title at all"
        )
    }

    /// And it is NAMED from the barcode rather than from the stop it was attached to.
    func testAnUntitledPassTakesItsNameFromTheBarcode() {
        var extracted = ExtractedTaskTicket(input: [:])
        extracted.eventDate = "2026-09-02"
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/leg-1.pdf",
            barcodePayload: returnPayload,
            barcodeSymbology: "pdf417",
            extracted: extracted,
            degradeMessage: nil,
            context: TaskTicketContext(title: "Flight EK315 SIN→DXB")
        )

        let title = read.ticket(owner: .task(UUID())).eventTitle
        // EK091, not EK91: the pass and the departure board both print three digits,
        // and the card is read against them.
        XCTAssertEqual(title, "EK091 \u{00B7} DXB\u{2192}MXP")
        XCTAssertFalse(title.contains("EK315"), "must not inherit the attached stop's flight")
    }

    /// A model-supplied title still wins: it can read a codeshare or a marketing name
    /// off the page that the barcode's operating flight does not carry.
    func testAModelTitleStillWins() {
        var extracted = ExtractedTaskTicket(input: [:])
        extracted.eventTitle = "Emirates EK315 to Dubai"
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/leg-0.pdf",
            barcodePayload: outboundPayload,
            barcodeSymbology: "pdf417",
            extracted: extracted,
            degradeMessage: nil
        )
        XCTAssertEqual(read.ticket(owner: .task(UUID())).eventTitle, "Emirates EK315 to Dubai")
    }

    /// A ticket with no barcode and no title falls back to the record it hangs off,
    /// exactly as before — the pass path must not change the ordinary one.
    func testANonPassStillFallsBackToTheOwnersTitle() {
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/a.jpg",
            barcodePayload: "",
            barcodeSymbology: "",
            extracted: nil,
            degradeMessage: nil,
            context: TaskTicketContext(title: "Dentist")
        )
        XCTAssertNil(read.bcbp)
        XCTAssertEqual(read.ticket(owner: .task(UUID())).eventTitle, "Dentist")
    }

    // MARK: - Boarding group (#501)

    /// The fact the extractor kept losing, now a typed field on the card.
    func testTheBoardingGroupIsKept() {
        let segments = ExtractedTaskTicket.segments(fromToolInput: [
            "segments": .array([pass(title: "EK315", seat: "25J", group: "5", page: 1)])
        ])
        let read = TaskTicketRead(
            attachmentPath: "task-tickets/a.pdf",
            barcodePayload: outboundPayload,
            barcodeSymbology: "pdf417",
            extracted: segments[0],
            degradeMessage: nil
        )
        XCTAssertEqual(read.ticket(owner: .task(UUID())).ticketMeta?.boardingGroup, "5")
    }

    /// A group printed with its own label is stored without it, the way every other
    /// short coded slot is.
    func testTheGroupIsStrippedOfItsLabel() {
        XCTAssertEqual(
            TicketField.group(TaskTicketRead.unlabelled("Group 5")),
            "5"
        )
    }

    /// A zone letter is a real value, unlike a lone "T" read off the word Terminal,
    /// so the group sanitizer keeps it where the code sanitizer would not.
    func testAZoneLetterSurvives() {
        XCTAssertEqual(TicketField.group("B"), "B")
        XCTAssertNil(TicketField.code("B"), "the code sanitizer is right to refuse this")
        XCTAssertNil(TicketField.group("-"), "a placeholder is still refused")
        XCTAssertNil(TicketField.group("   "))
    }

    /// The pass prints Group in the same block as Boarding, so the model can also
    /// return it generically. It must not then appear twice on one card.
    func testTheGroupIsNotAlsoRepeatedAsAGenericField() {
        let segments = ExtractedTaskTicket.segments(fromToolInput: [
            "segments": .array([
                pass(title: "EK315", group: "5", page: 1,
                     other: [("Group", "5"), ("Boarding", "09:05")])
            ])
        ])
        let meta = TaskTicketRead(
            attachmentPath: "task-tickets/a.pdf",
            barcodePayload: outboundPayload,
            barcodeSymbology: "pdf417",
            extracted: segments[0],
            degradeMessage: nil
        ).ticket(owner: .task(UUID())).ticketMeta

        XCTAssertEqual(meta?.boardingGroup, "5")
        XCTAssertEqual(meta?.fields?.count, 1, "the generic echo of the group is dropped")
        XCTAssertEqual(meta?.fields?.first?.label, "Boarding")
    }

    // MARK: - The card face

    /// On an itinerary row's own boarding-pass card, Group takes the face's third
    /// slot and the terminal it displaced is still readable on the back.
    func testGroupTakesTheThirdFaceSlotAndTerminalMovesToTheBack() {
        var meta = TicketMeta()
        meta.isBoardingPass = true
        meta.flightNumber = "EK315"
        meta.originCode = "SIN"
        meta.destinationCode = "DXB"
        meta.boardingGroup = "5"
        meta.terminal = "T3"
        let fields = TicketCardFields(card: boardingPassCard(meta: meta))

        XCTAssertEqual(fields.auxiliary.map(\.label), ["Seat", "Gate", "Group"])
        XCTAssertEqual(fields.auxiliary.last?.value, "5")
        XCTAssertTrue(fields.back.contains { $0.label == "Terminal" && $0.value == "T3" })
    }

    /// A pass with no group keeps exactly the face it has today.
    func testWithNoGroupTheFaceIsUnchanged() {
        var meta = TicketMeta()
        meta.isBoardingPass = true
        meta.flightNumber = "EK315"
        meta.originCode = "SIN"
        meta.destinationCode = "DXB"
        meta.terminal = "T3"
        let fields = TicketCardFields(card: boardingPassCard(meta: meta))

        XCTAssertEqual(fields.auxiliary.map(\.label), ["Seat", "Gate", "Terminal"])
        XCTAssertFalse(fields.back.contains { $0.label == "Group" })
    }

    /// The face is a fixed three slots whatever the pass prints, which is what keeps
    /// every card the same height.
    func testTheFaceStaysThreeWide() {
        var meta = TicketMeta()
        meta.isBoardingPass = true
        meta.flightNumber = "EK315"
        meta.originCode = "SIN"
        meta.destinationCode = "DXB"
        meta.boardingGroup = "5"
        meta.terminal = "T3"
        XCTAssertEqual(TicketCardFields(card: boardingPassCard(meta: meta)).auxiliary.count, 3)
    }

    /// The case that actually shipped: an Emirates pass attached to a trip stop is
    /// stored as a DOCUMENT, so it is drawn with the event layout rather than the
    /// boarding-pass one. The group has to reach that face too, or the fix looks
    /// applied and changes nothing on the card the person is holding.
    func testAnAttachedPassShowsTheGroupOnItsEventFace() {
        var meta = TicketMeta()
        meta.boardingGroup = "5"
        meta.guestName = "Akshay Sharma"
        let fields = TicketCardFields(card: attachedDocumentCard(meta: meta, seat: "25J"))

        XCTAssertTrue(
            fields.auxiliary.contains { $0.label == "Group" && $0.value == "5" },
            "the group must be on the face of the card an attached pass actually draws"
        )
    }

    /// A seated event ticket fills all three slots with its own facts, and the group
    /// then has to survive on the back rather than vanish.
    func testAFullEventFacePushesTheGroupToTheBack() {
        var meta = TicketMeta()
        meta.section = "26b"
        meta.row = "D"
        meta.boardingGroup = "5"
        let fields = TicketCardFields(card: attachedDocumentCard(meta: meta, seat: "312"))

        XCTAssertEqual(fields.auxiliary.map(\.label), ["Section", "Row", "Seat"])
        XCTAssertTrue(fields.back.contains { $0.label == "Group" && $0.value == "5" })
    }

    /// An event ticket with no group prints no empty group slot.
    func testAnEventTicketWithNoGroupShowsNoGroupSlot() {
        var meta = TicketMeta()
        meta.guestName = "Akshay Sharma"
        let fields = TicketCardFields(card: attachedDocumentCard(meta: meta, seat: "12A"))

        XCTAssertFalse(fields.auxiliary.contains { $0.label == "Group" })
        XCTAssertFalse(fields.back.contains { $0.label == "Group" })
    }

    /// A boarding pass on its own itinerary row, which is the `.boardingPass` layout.
    private func boardingPassCard(meta: TicketMeta) -> TicketCardData {
        let item = LocalItineraryItem(
            tripUUID: UUID(),
            dayDate: Date(),
            kind: .transport,
            transportMode: .flight,
            title: "EK315 \u{00B7} SIN\u{2192}DXB",
            attachmentPath: "tickets/a.pdf",
            barcodePayload: outboundPayload,
            barcodeSymbology: "pdf417",
            seat: "25J",
            ticketMetaJSON: meta.encodedString()
        )
        return TicketCardData(item)
    }

    /// A document attached to a task or a trip stop, which is the `.event` layout
    /// whatever the document turns out to be.
    private func attachedDocumentCard(meta: TicketMeta, seat: String) -> TicketCardData {
        let ticket = LocalTaskTicket(
            todoClientUUID: UUID(),
            itineraryItemUUID: UUID(),
            attachmentPath: "task-tickets/a.pdf",
            barcodePayload: outboundPayload,
            barcodeSymbology: "pdf417",
            eventTitle: "EK315",
            eventDate: Date(),
            venue: "Singapore",
            seat: seat,
            reference: "IZDHBW",
            ticketMetaJSON: meta.encodedString()
        )
        return TicketCardData(ticket, ownerTitle: "Flight EK315 SIN\u{2192}DXB")
    }
}
