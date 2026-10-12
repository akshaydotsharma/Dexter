import XCTest
import SwiftData
@testable import PersonalDashboard

/// Move a calendar event in Dexter only (#697): a `moved` override, applied
/// through the one gate, kept by backup and sync, and safe against a peer on
/// an older build.
@MainActor
final class PlannerEventMoveTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return c
    }()
    private let settings = WorkdaySettings(startMinute: 9 * 60, lengthMinutes: 9 * 60)
    private var store: SwiftDataStore!
    private var service: EventOverrideService!

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = EventOverrideService(store: store)
    }

    override func tearDown() {
        service = nil
        store = nil
        super.tearDown()
    }

    /// Tuesday 29 September 2026 at h:m, plus whole days.
    private func at(_ h: Int, _ m: Int, day: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 29 + day, hour: h, minute: m))!
    }

    private func event(
        _ title: String, _ sh: Int, _ eh: Int, day: Int = 0, key: String = "uid-standup",
        recurring: Bool = true
    ) -> PlannerEvent {
        PlannerEvent(
            id: "\(title)-\(day)", title: title, location: "", calendarID: "c", calendarTitle: "Work",
            source: .work, start: at(sh, 0, day: day), end: at(eh, 0, day: day), isAllDay: false,
            eventKey: key, occurrenceDate: at(sh, 0, day: day), isRecurring: recurring
        )
    }

    private func shown(_ events: [PlannerEvent]) throws -> [PlannerEvent] {
        PlannerEventOverrides.apply(events, rules: try service.live().map(\.rule))
    }

    private func dayOf(_ events: [PlannerEvent], day: Int = 0) throws -> PlannerDay {
        let ctx = PlannerContext(tasks: [], blocks: [], rawEvents: events, overrides: try service.live().map(\.rule),
                                 now: at(8, 0), settings: settings, visible: Set(PlannerSource.allCases))
        return PlannerEngine.day(at(0, 0, day: day), events: ctx.events, blocks: [], tasks: [], now: at(8, 0), calendar: cal)
    }

    // MARK: - The gate

    func testAMoveShowsTheEventAtItsNewStartWithItsOwnLength() throws {
        let ev = event("Review", 14, 15, key: "uid-review", recurring: false)
        try service.move(ev, to: at(16, 30))
        let out = try XCTUnwrap(try shown([ev]).first)
        XCTAssertEqual(out.start, at(16, 30))
        XCTAssertEqual(out.end, at(17, 30), "same length")
        XCTAssertEqual(out.movedFrom, at(14, 0), "the calendar time is kept for the quick view")
        XCTAssertEqual(out.id, ev.id, "the row id does not change, so the tile keeps its identity")
        XCTAssertEqual(out.occurrenceDate, ev.occurrenceDate)
    }

    func testTheMeterConflictsAndFreeTimeSeeTheMovedTime() throws {
        let review = event("Review", 14, 15, key: "uid-review", recurring: false)
        let lunch = event("Lunch", 12, 13, key: "uid-lunch", recurring: false)
        XCTAssertTrue(PlannerEngine.conflicts(in: try dayOf([review, lunch])).isEmpty)
        try service.move(review, to: at(12, 30))
        let d = try dayOf([review, lunch])
        XCTAssertEqual(d.timed.first { $0.title == "Review" }?.start, at(12, 30))
        XCTAssertEqual(PlannerEngine.conflicts(in: d).count, 1, "the moved event now overlaps lunch")
        let free = PlannerEngine.freeTime(on: d, settings: settings, calendar: cal)
        XCTAssertTrue(free.contains { $0.start <= at(14, 0) && $0.end >= at(15, 0) }, "its calendar slot is free again")
    }

    func testARepeatingEventMovesOneOccurrenceOnly() throws {
        let mon = event("Standup", 9, 10)
        let tue = event("Standup", 9, 10, day: 1)
        try service.move(mon, to: at(11, 0))
        XCTAssertEqual(try shown([mon]).first?.start, at(11, 0))
        XCTAssertEqual(try shown([tue]).first?.start, at(9, 0, day: 1), "the next occurrence stays at its calendar time")
        let row = try XCTUnwrap(try service.live().first)
        XCTAssertEqual(row.occurrenceStart, at(9, 0))
        XCTAssertFalse(row.appliesToSeries)
    }

    func testHiddenStillWinsOverAMove() throws {
        let ev = event("Standup", 9, 10)
        try service.move(ev, to: at(11, 0))
        try service.set(.hidden, for: ev, scope: .series)
        XCTAssertTrue(try shown([ev]).isEmpty)
    }

    func testAMovedEventCanStillBeDeclined() throws {
        let ev = event("Standup", 9, 10)
        try service.move(ev, to: at(11, 0))
        try service.set(.declined, for: ev, scope: .occurrence)
        let out = try XCTUnwrap(try shown([ev]).first)
        XCTAssertEqual(out.decline, .inDexter)
        XCTAssertEqual(out.start, at(11, 0))
    }

    func testAnAllDayEventIsNeverMoved() {
        let allDay = PlannerEvent(id: "off", title: "Offsite", location: "", calendarID: "c", calendarTitle: "Work",
                                  source: .work, start: at(0, 0), end: at(0, 0, day: 1), isAllDay: true,
                                  eventKey: "uid-offsite", occurrenceDate: at(0, 0), isRecurring: false)
        let r = EventOverrideRule(id: "m", eventKey: "uid-offsite", occurrenceStart: nil, action: .moved, movedStart: at(9, 0))
        XCTAssertEqual(PlannerEventOverrides.apply([allDay], rules: [r]).first?.start, at(0, 0))
    }

    // MARK: - The service

    func testTheMoveIDIsOnePerOccurrence() throws {
        let ev = event("Standup", 9, 10)
        XCTAssertEqual(EventOverrideService.moveID(for: ev),
                       EventOverrideID.make(action: .moved, eventKey: "uid-standup", occurrenceStart: at(9, 0)))
        XCTAssertNotEqual(EventOverrideService.moveID(for: ev), EventOverrideService.moveID(for: event("Standup", 9, 10, day: 1)))
        XCTAssertNotEqual(EventOverrideService.moveID(for: ev),
                          EventOverrideID.make(action: .hidden, eventKey: "uid-standup", occurrenceStart: at(9, 0)),
                          "a move and a hide of the same occurrence are separate rows")
    }

    func testMovingAgainUpdatesTheOneRow() throws {
        let ev = event("Review", 14, 15, key: "uid-review", recurring: false)
        let a = try XCTUnwrap(try service.move(ev, to: at(16, 0)))
        // Moved again from the moved tile: the event the grid holds is already moved.
        let movedEv = try XCTUnwrap(try shown([ev]).first)
        let b = try XCTUnwrap(try service.move(movedEv, to: at(17, 0)))
        XCTAssertEqual(a.clientUUID, b.clientUUID)
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<LocalEventOverride>()).count, 1)
        XCTAssertEqual(try shown([ev]).first?.start, at(17, 0))
    }

    func testResetPutsItBackAtItsCalendarTime() throws {
        let ev = event("Review", 14, 15, key: "uid-review", recurring: false)
        try service.move(ev, to: at(16, 0))
        let movedEv = try XCTUnwrap(try shown([ev]).first)
        try service.resetMove(for: movedEv)
        let out = try XCTUnwrap(try shown([ev]).first)
        XCTAssertEqual(out.start, at(14, 0))
        XCTAssertNil(out.movedFrom)
        XCTAssertTrue(try service.live().isEmpty, "the reset is a soft delete")
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<LocalEventOverride>()).first?.deletedAt != nil, true)
    }

    func testDraggingBackToTheCalendarTimeIsAReset() throws {
        let ev = event("Review", 14, 15, key: "uid-review", recurring: false)
        try service.move(ev, to: at(16, 0))
        let movedEv = try XCTUnwrap(try shown([ev]).first)
        XCTAssertNil(try service.move(movedEv, to: at(14, 0)))
        XCTAssertTrue(try service.live().isEmpty)
        XCTAssertEqual(try shown([ev]).first?.start, at(14, 0))
    }

    func testAMoveIsStoredSoAnOlderBuildIgnoresIt() throws {
        let ev = event("Standup", 9, 10)
        let row = try XCTUnwrap(try service.move(ev, to: at(11, 0)))
        XCTAssertEqual(row.action, "moved")
        XCTAssertEqual(row.eventKey, "moved:uid-standup", "an older build matches keys exactly, so this matches nothing there")
        XCTAssertEqual(row.movedStart, at(11, 0))
        XCTAssertEqual(row.eventStart, at(11, 0), "the new start also rides in a column older builds round-trip")
        XCTAssertEqual(row.rule.eventKey, "uid-standup")
    }

    // MARK: - Backup and sync

    func testAnArchiveRoundTripKeepsTheMove() async throws {
        let ev = event("Standup", 9, 10)
        let row = try XCTUnwrap(try service.move(ev, to: at(11, 15)))
        let url = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: url) }
        let empty = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let importer = DataImportService(modelContext: empty.context)
        try importer.commit(preview: try importer.preview(url: url))
        let back = try XCTUnwrap(try empty.context.fetch(FetchDescriptor<LocalEventOverride>()).first { $0.clientUUID == row.clientUUID })
        XCTAssertEqual(back.actionEnum, .moved)
        XCTAssertEqual(back.movedStart, at(11, 15))
        XCTAssertEqual(back.occurrenceStart, at(9, 0))
        XCTAssertEqual(PlannerEventOverrides.apply([ev], rules: [back.rule]).first?.start, at(11, 15))
    }

    func testASyncedMoveFromThePhoneMovesOnThisDevice() throws {
        var payload = DataArchive.Payload.empty
        let id = EventOverrideID.make(action: .moved, eventKey: "uid-standup", occurrenceStart: at(9, 0))
        payload.eventOverrides = [DataArchive.EventOverrideDTO(
            clientUUID: id, eventKey: "moved:uid-standup", occurrenceStart: at(9, 0), action: "moved",
            title: "Standup", eventStart: at(10, 30), movedStart: at(10, 30)
        )]
        XCTAssertEqual(try SyncRecordMapper.records(from: payload).filter { $0.entity == "LocalEventOverride" }.map(\.recordID), [id])
        try commitAsPeer(payload)
        XCTAssertEqual(try shown([event("Standup", 9, 10)]).first?.start, at(10, 30))
    }

    /// What a peer on a build from before #697 sends back after it has seen a
    /// move: it rewrote the action it did not know to `hidden` and dropped
    /// `movedStart`. The event must NOT be hidden, and the move survives
    /// through `eventStart`.
    func testAnOlderPeersEchoNeitherHidesTheEventNorLosesTheMove() throws {
        var payload = DataArchive.Payload.empty
        let id = EventOverrideID.make(action: .moved, eventKey: "uid-standup", occurrenceStart: at(9, 0))
        payload.eventOverrides = [DataArchive.EventOverrideDTO(
            clientUUID: id, eventKey: "moved:uid-standup", occurrenceStart: at(9, 0), action: "hidden",
            title: "Standup", eventStart: at(10, 30)
        )]
        try commitAsPeer(payload)
        let row = try XCTUnwrap(try service.live().first)
        XCTAssertNil(row.movedStart, "the older peer dropped the new column")
        XCTAssertEqual(row.actionEnum, .moved, "the key prefix still says moved")
        let out = try shown([event("Standup", 9, 10)])
        XCTAssertEqual(out.count, 1, "never hidden")
        XCTAssertEqual(out.first?.start, at(10, 30), "the move came back through eventStart")
    }

    private func commitAsPeer(_ payload: DataArchive.Payload) throws {
        let manifest = DataArchive.Manifest(schemaVersion: DataArchive.currentSchemaVersion, exportedAt: Date(), appVersion: "test", data: payload)
        let preview = DataImportService.Preview(manifest: manifest, archiveURL: URL(fileURLWithPath: "/dev/null"), entries: [:], counts: [:])
        try DataImportService(modelContext: store.context).commit(preview: preview, mode: .replaceMatching)
    }

    // MARK: - Movable tiles

    func testATimedEventTileMovesAndACutOneDoesNot() {
        let ev = event("Review", 14, 15, key: "uid-review", recurring: false)
        func item(_ s: Date, _ e: Date) -> PlannerItem {
            PlannerItem(id: "e-\(ev.id)", title: ev.title, detail: "", source: .work, start: s, end: e,
                        durationMinutes: 60, origin: .event(calendarID: "c"), taskUUID: nil,
                        priority: .none, overdueDays: 0, completed: false)
        }
        XCTAssertTrue(PlannerDayColumn.isMovable(item(at(14, 0), at(15, 0)), event: ev))
        XCTAssertFalse(PlannerDayColumn.isResizable(item(at(14, 0), at(15, 0))), "an event still never resizes")
        XCTAssertFalse(PlannerDayColumn.isMovable(item(at(14, 0), at(15, 0)), event: nil))
        XCTAssertFalse(PlannerDayColumn.isMovable(item(at(14, 30), at(15, 0)), event: ev), "a tile cut at midnight shows part of the event")
    }
}
