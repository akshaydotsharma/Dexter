import XCTest
import SwiftData
@testable import PersonalDashboard

/// Hide and decline calendar events in Dexter (#689).
@MainActor
final class PlannerEventOverrideTests: XCTestCase {

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
        occurrence: Date? = nil, recurring: Bool = true, decline: PlannerDeclineState = .none,
        source: PlannerSource = .work
    ) -> PlannerEvent {
        PlannerEvent(
            id: "\(title)-\(day)", title: title, location: "", calendarID: "c", calendarTitle: "Work",
            source: source, start: at(sh, 0, day: day), end: at(eh, 0, day: day), isAllDay: false,
            eventKey: key, occurrenceDate: occurrence ?? at(sh, 0, day: day), isRecurring: recurring,
            decline: decline
        )
    }

    private func rule(_ action: EventOverrideAction, key: String = "uid-standup", occ: Date? = nil) -> EventOverrideRule {
        EventOverrideRule(id: "r", eventKey: key, occurrenceStart: occ, action: action)
    }

    private func dayOf(_ events: [PlannerEvent], rules: [EventOverrideRule] = [], day: Int = 0) -> PlannerDay {
        let ctx = PlannerContext(tasks: [], blocks: [], rawEvents: events, overrides: rules,
                                 now: at(8, 0), settings: settings, visible: Set(PlannerSource.allCases))
        return PlannerEngine.day(at(0, 0, day: day), events: ctx.events, blocks: [], tasks: [], now: at(8, 0), calendar: cal)
    }

    // MARK: - The key

    func testTheKeyIsTheExternalIDWithADeviceLocalFallback() {
        XCTAssertEqual(PlannerEventOverrides.eventKey(externalID: "ABC@google.com", localID: "local-1"), "ABC@google.com")
        XCTAssertEqual(PlannerEventOverrides.eventKey(externalID: "  ", localID: "local-1"), "local:local-1")
        XCTAssertEqual(PlannerEventOverrides.eventKey(externalID: nil, localID: "local-1"), "local:local-1")
        XCTAssertEqual(PlannerEventOverrides.eventKey(externalID: nil, localID: nil), "")
    }

    /// Measured in the simulator (#689): a moved occurrence reads
    /// `<UID>/RID=<n>`. It must key to the same series as the rest.
    func testAMovedOccurrenceKeysToItsSeries() {
        let series = "6104BF1C-5903-48F5-8267-B18B855B894E"
        let moved = "6104BF1C-5903-48F5-8267-B18B855B894E/RID=812536200"
        XCTAssertEqual(PlannerEventOverrides.eventKey(externalID: moved, localID: nil), series)
        XCTAssertEqual(PlannerEventOverrides.eventKey(externalID: series, localID: nil), series)
        XCTAssertEqual(
            PlannerEventOverrides.eventKey(externalID: nil, localID: "A30449FB:\(moved)"),
            "local:A30449FB:\(series)"
        )
        XCTAssertEqual(PlannerEventOverrides.seriesKey("abc@google.com"), "abc@google.com")
    }

    /// The end-to-end shape of the measurement: hide the whole series, and
    /// the moved occurrence (different raw id, original occurrence date) goes
    /// too; hide one occurrence, and only that one goes.
    func testTheMeasuredMovedOccurrenceFollowsItsSeries() {
        let series = "6104BF1C-5903-48F5-8267-B18B855B894E"
        let moved = PlannerEvent(
            id: "m", title: "Daily sync", location: "", calendarID: "c", calendarTitle: "Work",
            source: .work, start: at(17, 30, day: 1), end: at(17, 45, day: 1), isAllDay: false,
            eventKey: PlannerEventOverrides.eventKey(externalID: series + "/RID=812536200", localID: nil),
            occurrenceDate: at(16, 30, day: 1), isRecurring: true
        )
        XCTAssertTrue(EventOverrideRule(id: "s", eventKey: series, occurrenceStart: nil, action: .hidden).matches(moved))
        XCTAssertTrue(EventOverrideRule(id: "o", eventKey: series, occurrenceStart: at(16, 30, day: 1), action: .hidden).matches(moved))
        XCTAssertFalse(EventOverrideRule(id: "x", eventKey: series, occurrenceStart: at(16, 30, day: 2), action: .hidden).matches(moved))
    }

    func testTheOverrideIDIsDerivedFromTheDecision() {
        let a = EventOverrideID.make(action: .hidden, eventKey: "k", occurrenceStart: nil)
        XCTAssertEqual(a, EventOverrideID.make(action: .hidden, eventKey: "k", occurrenceStart: nil), "same decision, same id on every device")
        XCTAssertNotEqual(a, EventOverrideID.make(action: .declined, eventKey: "k", occurrenceStart: nil))
        XCTAssertNotEqual(a, EventOverrideID.make(action: .hidden, eventKey: "k", occurrenceStart: at(9, 0)))
    }

    // MARK: - Matching

    func testASeriesRuleMatchesEveryOccurrence() {
        let r = rule(.hidden)
        XCTAssertTrue(r.matches(event("Standup", 9, 10)))
        XCTAssertTrue(r.matches(event("Standup", 9, 10, day: 1)))
        XCTAssertFalse(r.matches(event("Other", 9, 10, key: "uid-other")))
    }

    func testAnOccurrenceRuleMatchesOnlyThatOccurrence() {
        let r = rule(.hidden, occ: at(9, 0, day: 1))
        XCTAssertFalse(r.matches(event("Standup", 9, 10)))
        XCTAssertTrue(r.matches(event("Standup", 9, 10, day: 1)))
    }

    func testAMovedOccurrenceStillMatchesByItsOriginalDate() {
        let r = rule(.declined, occ: at(9, 0, day: 1))
        // Wednesday's standup moved to 2 PM; EventKit keeps its occurrence date at 9 AM.
        let moved = event("Standup", 14, 15, day: 1, occurrence: at(9, 0, day: 1))
        XCTAssertTrue(r.matches(moved))
    }

    func testAnEmptyKeyNeverMatches() {
        XCTAssertFalse(rule(.hidden, key: "").matches(event("x", 9, 10, key: "")))
    }

    // MARK: - The gate

    func testHiddenRemovesDeclinedMarksAndHiddenWins() {
        let evs = [event("Standup", 9, 10), event("Review", 14, 15, key: "uid-review")]
        let out = PlannerEventOverrides.apply(evs, rules: [rule(.declined, key: "uid-review"), rule(.hidden)])
        XCTAssertEqual(out.map(\.title), ["Review"])
        XCTAssertEqual(out.first?.decline, .inDexter)
        let both = PlannerEventOverrides.apply([event("Standup", 9, 10)], rules: [rule(.declined), rule(.hidden)])
        XCTAssertTrue(both.isEmpty, "hidden wins over declined")
    }

    func testDeclinedAtTheSourceStaysDeclinedAtTheSource() {
        let out = PlannerEventOverrides.apply([event("Standup", 9, 10, decline: .atSource)], rules: [rule(.declined)])
        XCTAssertEqual(out.first?.decline, .atSource)
    }

    // MARK: - Declined in the engine

    func testADeclinedEventIsDrawnButNotCountedOrInConflict() {
        let review = event("Sprint review", 14, 15, key: "uid-review", recurring: false)
        let dentist = event("Dentist", 14, 15, key: "uid-dentist", recurring: false, decline: .atSource, source: .personal)
        let d = dayOf([review, dentist])
        XCTAssertEqual(d.timed.count, 2, "a declined event keeps its tile")
        XCTAssertTrue(d.timed.first { $0.title == "Dentist" }!.isDeclined)
        let c = PlannerEngine.capacity(of: d, settings: settings, calendar: cal)
        XCTAssertEqual(c.minutes(.personal), 0, "not in the meter")
        XCTAssertEqual(c.bookedMinutes, 60)
        XCTAssertTrue(PlannerEngine.conflicts(in: d).isEmpty, "a declined meeting cannot conflict")
        let lanes = PlannerEngine.lanes(d.timed)
        XCTAssertTrue(lanes.allSatisfy { !$0.inConflict }, "no danger ring")
        XCTAssertEqual(lanes.first?.count, 2, "but the tiles still sit side by side")
    }

    func testADeclinedEventLeavesItsTimeFree() {
        let d = dayOf([event("Dentist", 14, 15, recurring: false, decline: .inDexter)])
        let free = PlannerEngine.freeTime(on: d, settings: settings, calendar: cal)
        XCTAssertEqual(free.count, 1, "the whole workday is one free stretch")
    }

    func testDeclinedDoesNotCountTowardsOverflow() {
        let d = dayOf([
            event("A", 9, 13, key: "a", recurring: false), event("B", 13, 18, key: "b", recurring: false),
            event("C", 9, 12, key: "c", recurring: false, decline: .inDexter),
        ])
        XCTAssertFalse(PlannerEngine.capacity(of: d, settings: settings, calendar: cal).isOver)
    }

    // MARK: - Hidden in every aggregate

    func testAHiddenEventIsGoneFromTheDayTheMeterConflictsAndFreeTime() {
        let evs = [event("Standup", 9, 12), event("Review", 10, 11, key: "uid-review", recurring: false)]
        let d = dayOf(evs, rules: [rule(.hidden)])
        XCTAssertEqual(d.all.map(\.title), ["Review"])
        XCTAssertEqual(PlannerEngine.capacity(of: d, settings: settings, calendar: cal).bookedMinutes, 60)
        XCTAssertTrue(PlannerEngine.conflicts(in: d).isEmpty)
        XCTAssertTrue(PlannerEngine.freeTime(on: d, settings: settings, calendar: cal).contains { $0.start == at(9, 0) })
    }

    func testAHiddenAllDayEventIsGoneFromTheAllDayRow() {
        var allDay = event("Offsite", 0, 0, key: "uid-offsite", recurring: false)
        allDay = PlannerEvent(id: "off", title: "Offsite", location: "", calendarID: "c", calendarTitle: "Work",
                              source: .work, start: at(0, 0), end: at(0, 0, day: 1), isAllDay: true,
                              eventKey: "uid-offsite", occurrenceDate: at(0, 0), isRecurring: false)
        XCTAssertEqual(dayOf([allDay]).allDay.count, 1)
        XCTAssertTrue(dayOf([allDay], rules: [rule(.hidden, key: "uid-offsite")]).allDay.isEmpty)
    }

    func testHidingOneOccurrenceLeavesTheOthers() {
        let r = rule(.hidden, occ: at(9, 0, day: 1))
        XCTAssertEqual(dayOf([event("Standup", 9, 10)], rules: [r]).timed.count, 1)
        XCTAssertEqual(dayOf([event("Standup", 9, 10, day: 1)], rules: [r], day: 1).timed.count, 0)
    }

    // MARK: - The service

    func testTheScopeDecidesTheStoredOccurrence() {
        let ev = event("Standup", 9, 10, day: 1)
        XCTAssertNil(EventOverrideService.occurrenceStart(for: ev, scope: .series))
        XCTAssertEqual(EventOverrideService.occurrenceStart(for: ev, scope: .occurrence), at(9, 0, day: 1))
        let oneOff = event("Lunch", 12, 13, recurring: false)
        XCTAssertNil(EventOverrideService.occurrenceStart(for: oneOff, scope: .occurrence),
                     "a one-off is stored for the whole event, so moving it cannot lose the decision")
    }

    func testTheSameDecisionTwiceIsOneRecord() throws {
        let ev = event("Standup", 9, 10)
        let a = try service.set(.hidden, for: ev, scope: .series)
        let b = try service.set(.hidden, for: ev, scope: .series)
        XCTAssertEqual(a.clientUUID, b.clientUUID)
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<LocalEventOverride>()).count, 1)
        XCTAssertTrue(a.appliesToSeries)
    }

    func testUndoSoftDeletesAndARepeatRevivesTheSameRow() throws {
        let ev = event("Standup", 9, 10)
        let row = try service.set(.hidden, for: ev, scope: .occurrence)
        try service.remove(id: row.clientUUID)
        XCTAssertNotNil(row.deletedAt)
        XCTAssertTrue(try service.live().isEmpty)
        XCTAssertEqual(dayOf([ev], rules: try service.live().map(\.rule)).timed.count, 1, "undo brings it back")
        let again = try service.set(.hidden, for: ev, scope: .occurrence)
        XCTAssertEqual(again.clientUUID, row.clientUUID)
        XCTAssertNil(again.deletedAt)
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<LocalEventOverride>()).count, 1)
    }

    func testUndoDeclineClearsSeriesAndOccurrenceDeclines() throws {
        let ev = event("Standup", 9, 10)
        try service.set(.declined, for: ev, scope: .series)
        try service.set(.declined, for: ev, scope: .occurrence)
        try service.set(.hidden, for: event("Other", 9, 10, key: "uid-other"), scope: .series)
        try service.clearDecline(for: ev)
        let live = try service.live()
        XCTAssertEqual(live.map(\.actionEnum), [.hidden], "only the unrelated hide is left")
    }

    func testAnEventWithNoKeyCannotBeOverridden() {
        XCTAssertThrowsError(try service.set(.hidden, for: event("x", 9, 10, key: ""), scope: .series))
    }

    // MARK: - Backup and sync

    func testTheModelIsCarriedByTheArchiveAndSync() {
        XCTAssertTrue(SwiftDataStore.schemaModels.contains { ObjectIdentifier($0) == ObjectIdentifier(LocalEventOverride.self) })
        XCTAssertTrue(DataArchive.exportedModels.contains("LocalEventOverride"))
        XCTAssertTrue(SyncRecordMapper.syncedEntities.contains("LocalEventOverride"))
        XCTAssertNotNil(DataExportService.counts(for: .empty)["LocalEventOverride"])
        XCTAssertNotNil(DataImportService.actualCounts(for: .empty)["LocalEventOverride"])
    }

    func testAnArchiveRoundTripKeepsEveryDecision() async throws {
        let series = try service.set(.hidden, for: event("Standup", 9, 10), scope: .series)
        let one = try service.set(.declined, for: event("Standup", 9, 10, day: 1), scope: .occurrence)
        let undone = try service.set(.hidden, for: event("Review", 14, 15, key: "uid-review", recurring: false), scope: .occurrence)
        try service.remove(id: undone.clientUUID)

        let url = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: url) }
        let empty = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let importer = DataImportService(modelContext: empty.context)
        let preview = try importer.preview(url: url)
        XCTAssertEqual(preview.counts(for: .skipExisting)[.eventOverrides]?.new, 3)
        try importer.commit(preview: preview)

        let back = Dictionary(uniqueKeysWithValues: try empty.context.fetch(FetchDescriptor<LocalEventOverride>()).map { ($0.clientUUID, $0) })
        XCTAssertNil(back[series.clientUUID]?.occurrenceStart)
        XCTAssertEqual(back[series.clientUUID]?.actionEnum, .hidden)
        XCTAssertTrue(back[series.clientUUID]?.appliesToSeries ?? false)
        XCTAssertEqual(back[one.clientUUID]?.occurrenceStart, at(9, 0, day: 1))
        XCTAssertEqual(back[one.clientUUID]?.actionEnum, .declined)
        XCTAssertNotNil(back[undone.clientUUID]?.deletedAt, "an undo travels, so the other device un-hides too")
    }

    func testASyncedHideFromThePhoneHidesOnThisDevice() throws {
        var payload = DataArchive.Payload.empty
        let id = EventOverrideID.make(action: .hidden, eventKey: "uid-standup", occurrenceStart: nil)
        payload.eventOverrides = [DataArchive.EventOverrideDTO(clientUUID: id, eventKey: "uid-standup", action: "hidden", title: "Standup")]
        let records = try SyncRecordMapper.records(from: payload)
        XCTAssertEqual(records.filter { $0.entity == "LocalEventOverride" }.map(\.recordID), [id])
        let manifest = DataArchive.Manifest(schemaVersion: DataArchive.currentSchemaVersion, exportedAt: Date(), appVersion: "test", data: payload)
        let preview = DataImportService.Preview(manifest: manifest, archiveURL: URL(fileURLWithPath: "/dev/null"), entries: [:], counts: [:])
        try DataImportService(modelContext: store.context).commit(preview: preview, mode: .replaceMatching)
        let rules = try service.live().map(\.rule)
        XCTAssertTrue(dayOf([event("Standup", 9, 10)], rules: rules).timed.isEmpty)
    }
}
