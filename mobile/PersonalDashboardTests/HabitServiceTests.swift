import XCTest
import SwiftData
@testable import PersonalDashboard

/// The write side of habits (#661): one row per habit per day, no future days,
/// and a backup and sync round trip that keeps every day on its date.
@MainActor
final class HabitServiceTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: HabitService!

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = HabitService(store: store)
    }

    override func tearDown() {
        service = nil
        store = nil
        super.tearDown()
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        WallClock.dayAnchor(fromISO: String(format: "%04d-%02d-%02d", y, m, d))!
    }

    private func checkIns() throws -> [LocalHabitCheckIn] {
        try store.context.fetch(FetchDescriptor<LocalHabitCheckIn>())
    }


    /// Due past days with nothing logged, counted through the ledger's own
    /// `state`. The app no longer shows this number (#661: a day is done or
    /// empty), but the rule behind it still ends streaks and still counts in
    /// the rate, so the tests keep checking it.
    private func notDoneCount(_ rule: HabitRule, entries: [Date: HabitDayEntry], from: Date, today: Date) -> Int {
        var count = 0
        var d = max(HabitLedger.key(from), HabitLedger.key(rule.startDay))
        while d < HabitLedger.key(today) {
            if HabitLedger.state(rule, entry: entries[d], on: d, today: today) == .missed { count += 1 }
            d = HabitLedger.adding(1, to: d)
        }
        return count
    }

    // MARK: - One row per day

    /// A second write for the same day updates the row. It never inserts a
    /// second one, and it keeps the row's identity and first `createdAt`
    /// (a same-id insert would REPLACE the row and reset both, #514).
    func testASecondWriteForTheSameDayUpdatesTheRow() throws {
        let today = day(2026, 9, 20)
        let habit = try service.create(name: "Water", targetCount: 8, unit: "glasses", startDay: day(2026, 9, 1))

        try service.tap(habit, today: today, now: Date(timeIntervalSince1970: 1_000))
        let first = try XCTUnwrap(checkIns().first)
        let firstCreated = first.createdAt

        try service.tap(habit, today: today, now: Date(timeIntervalSince1970: 2_000))
        try service.tap(habit, today: today, now: Date(timeIntervalSince1970: 3_000))
        try service.set(habit, on: today, to: .skipped, today: today, now: Date(timeIntervalSince1970: 4_000))
        try service.set(habit, on: today, to: .done, today: today, now: Date(timeIntervalSince1970: 5_000))

        let rows = try checkIns()
        XCTAssertEqual(rows.count, 1, "five writes on one day must leave one row")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.clientUUID, HabitCheckInID.make(habitUUID: habit.clientUUID, day: today))
        XCTAssertEqual(row.count, 8, "done sets the count to the target")
        XCTAssertEqual(row.statusEnum, .done)
        XCTAssertEqual(row.createdAt, firstCreated, "the row kept its first createdAt")
        XCTAssertEqual(row.updatedAt, Date(timeIntervalSince1970: 5_000))
    }

    /// A count habit adds one per tap; a yes/no habit toggles.
    func testTapCountsForACountHabitAndTogglesForAYesNoHabit() throws {
        let today = day(2026, 9, 20)
        let water = try service.create(name: "Water", targetCount: 3, startDay: day(2026, 9, 1))
        let read = try service.create(name: "Read", startDay: day(2026, 9, 1))

        try service.tap(water, today: today)
        try service.tap(water, today: today)
        XCTAssertEqual(try service.checkIn(habitUUID: water.clientUUID, day: today)?.count, 2)

        try service.tap(read, today: today)
        XCTAssertNil(try service.checkIn(habitUUID: read.clientUUID, day: today)?.deletedAt)
        try service.tap(read, today: today)
        XCTAssertNotNil(try service.checkIn(habitUUID: read.clientUUID, day: today)?.deletedAt,
                        "a second tap on a done yes/no habit clears it")
        try service.tap(read, today: today)
        let revived = try XCTUnwrap(service.checkIn(habitUUID: read.clientUUID, day: today))
        XCTAssertNil(revived.deletedAt, "a third tap revives the same row")
        XCTAssertEqual(try checkIns().filter { $0.habitUUID == read.clientUUID }.count, 1)
    }

    // MARK: - No future days

    func testAFutureDayIsRefused() throws {
        let today = day(2026, 9, 20)
        let habit = try service.create(name: "Read", startDay: day(2026, 9, 1))

        XCTAssertThrowsError(try service.set(habit, on: day(2026, 9, 21), to: .done, today: today)) { error in
            guard case HabitServiceError.futureDay = error else {
                return XCTFail("expected futureDay, got \(error)")
            }
        }
        XCTAssertThrowsError(try service.set(habit, on: day(2026, 9, 21), to: .skipped, today: today))
        XCTAssertEqual(try checkIns().count, 0, "nothing was written for tomorrow")

        XCTAssertNoThrow(try service.set(habit, on: day(2026, 9, 18), to: .done, today: today),
                         "a past day can be corrected")
    }

    /// A check on a day the habit is not due is an EXTRA day: allowed, drawn as
    /// done, and neutral (no streak, no rate).
    func testAnUnscheduledDayCanBeCheckedAsAnExtraDay() throws {
        let today = day(2026, 9, 20)   // Sunday
        let habit = try service.create(
            name: "Gym", schedule: .weekdays, weekdayMask: 1 << 1, startDay: day(2026, 9, 1)
        )
        XCTAssertNoThrow(try service.set(habit, on: today, to: .done, today: today))
        let entry = try XCTUnwrap(service.checkIn(habitUUID: habit.clientUUID, day: today)).entry
        XCTAssertEqual(HabitLedger.state(habit.rule, entry: entry, on: today, today: today), .extra)
    }

    // MARK: - Previous days (the startDay = today case)

    /// His real habits were all created with startDay = today, so every earlier
    /// day was locked. A check on a day before the start is a backfill: it is
    /// allowed and it moves the start day back to that day.
    func testABackfillBeforeTheStartMovesTheStartDayBack() throws {
        let today = day(2026, 9, 25)
        let habit = try service.create(name: "Cardio", startDay: today)

        try service.toggle(habit, on: day(2026, 9, 22), today: today)

        XCTAssertEqual(habit.startDay, day(2026, 9, 22), "the backfill moved the start day back")
        let entries = HabitLedger.group(try checkIns().map { ($0.habitUUID, $0.day, $0.entry) })[habit.clientUUID] ?? [:]
        XCTAssertEqual(HabitLedger.state(habit.rule, entry: entries[day(2026, 9, 22)], on: day(2026, 9, 22), today: today), .done)
        XCTAssertEqual(
            notDoneCount(habit.rule, entries: entries, from: day(2026, 9, 1), today: today), 2,
            "the 23rd and 24th are now honest misses"
        )

        // Clearing never moves the start day forward.
        try service.toggle(habit, on: day(2026, 9, 22), today: today)
        XCTAssertEqual(habit.startDay, day(2026, 9, 22))
    }

    /// A tap on a past day toggles done <-> cleared. For a count habit, done
    /// means count = target, and the second tap clears it. One row throughout.
    func testATapTogglesAPastDayDoneAndCleared() throws {
        let today = day(2026, 9, 25)
        let water = try service.create(name: "Water", targetCount: 8, startDay: day(2026, 9, 1))
        let past = day(2026, 9, 20)

        try service.toggle(water, on: past, today: today)
        var row = try XCTUnwrap(service.checkIn(habitUUID: water.clientUUID, day: past))
        XCTAssertNil(row.deletedAt)
        XCTAssertEqual(row.count, 8, "a tap in the review sets the full target")

        try service.toggle(water, on: past, today: today)
        row = try XCTUnwrap(service.checkIn(habitUUID: water.clientUUID, day: past))
        XCTAssertNotNil(row.deletedAt, "the second tap clears it")

        try service.toggle(water, on: past, today: today)
        XCTAssertNil(try service.checkIn(habitUUID: water.clientUUID, day: past)?.deletedAt)
        XCTAssertEqual(try checkIns().count, 1)

        // A partial day is not checked, so a tap completes it rather than clearing.
        try service.set(water, on: day(2026, 9, 21), to: .partial(3), today: today)
        try service.toggle(water, on: day(2026, 9, 21), today: today)
        XCTAssertEqual(try service.checkIn(habitUUID: water.clientUUID, day: day(2026, 9, 21))?.count, 8)
    }

    func testAToggleOnAFutureDayIsRefused() throws {
        let today = day(2026, 9, 25)
        let habit = try service.create(name: "Read", startDay: today)
        XCTAssertThrowsError(try service.toggle(habit, on: day(2026, 9, 26), today: today))
        XCTAssertEqual(try checkIns().count, 0)
        XCTAssertEqual(habit.startDay, today)
    }

    // MARK: - Validation

    func testAWeekdayHabitNeedsADay() {
        XCTAssertThrowsError(try service.create(name: "Gym", schedule: .weekdays, weekdayMask: 0))
        XCTAssertThrowsError(try service.create(name: "   "))
    }

    func testRenameIgnoresEmptyInput() throws {
        let habit = try service.create(name: "Read")
        try service.rename(habit, to: "   ")
        XCTAssertEqual(habit.name, "Read")
        try service.rename(habit, to: " Read 20 pages ")
        XCTAssertEqual(habit.name, "Read 20 pages")
    }

    // MARK: - Backup and sync

    /// Both models are in the archive and in sync. A model in the store but not
    /// in the archive is the #449 gap.
    func testBothHabitModelsAreCarriedByTheArchiveAndSync() {
        for name in ["LocalHabit", "LocalHabitCheckIn"] {
            XCTAssertTrue(DataArchive.exportedModels.contains(name), "\(name) is in no backup")
            XCTAssertTrue(SyncRecordMapper.syncedEntities.contains(name), "\(name) does not sync")
            XCTAssertNotNil(DataExportService.counts(for: .empty)[name])
            XCTAssertNotNil(DataImportService.actualCounts(for: .empty)[name])
        }
    }

    /// Seed a store, write a real archive, restore it into an EMPTY store, and
    /// check the habit and its days came back on the same anchors.
    func testAnArchiveRoundTripRestoresHabitsAndCheckIns() async throws {
        let today = day(2026, 9, 20)
        let habit = try service.create(
            name: "Water", emoji: "💧", colorKey: "azure",
            schedule: .weekdays, weekdayMask: 0b011_1110,
            targetCount: 8, unit: "glasses", startDay: day(2026, 9, 1)
        )
        try service.set(habit, on: day(2026, 9, 18), to: .partial(5), today: today)
        try service.set(habit, on: day(2026, 9, 17), to: .skipped, today: today)
        try service.set(habit, on: day(2026, 9, 16), to: .done, today: today)

        let archiveURL = try await DataExportService(modelContext: store.context).export()
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let empty = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        let importer = DataImportService(modelContext: empty.context)
        let preview = try importer.preview(url: archiveURL)
        XCTAssertEqual(preview.counts(for: .skipExisting)[.habits]?.new, 1)
        XCTAssertEqual(preview.counts(for: .skipExisting)[.habitCheckIns]?.new, 3)
        try importer.commit(preview: preview)

        let back = try XCTUnwrap(empty.context.fetch(FetchDescriptor<LocalHabit>()).first)
        XCTAssertEqual(back.clientUUID, habit.clientUUID)
        XCTAssertEqual(back.name, "Water")
        XCTAssertEqual(back.emoji, "💧")
        XCTAssertEqual(back.colorKey, "azure")
        XCTAssertEqual(back.scheduleEnum, .weekdays)
        XCTAssertEqual(back.weekdayMask, 0b011_1110)
        XCTAssertEqual(back.targetCount, 8)
        XCTAssertEqual(back.unit, "glasses")
        XCTAssertEqual(back.startDay, day(2026, 9, 1), "the start day comes back as the same anchor")

        let rows = try empty.context.fetch(FetchDescriptor<LocalHabitCheckIn>())
        let byDay = Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0) })
        XCTAssertEqual(byDay[day(2026, 9, 18)]?.count, 5)
        XCTAssertEqual(byDay[day(2026, 9, 17)]?.statusEnum, .skipped)
        XCTAssertEqual(byDay[day(2026, 9, 16)]?.count, 8)
        XCTAssertEqual(
            HabitLedger.state(back.rule, entry: byDay[day(2026, 9, 18)]?.entry, on: day(2026, 9, 18), today: today),
            .partial(count: 5, target: 8)
        )
    }

    /// A peer that wrote a day as a device-local midnight (the pre-#506 shape)
    /// is snapped back onto the day it meant on the way in.
    func testAnInboundDayIsReAnchored() throws {
        var payload = DataArchive.Payload.empty
        // Midnight in Singapore on 20 September is 16:00Z on the 19th.
        let singaporeMidnight = ISO8601DateFormatter().date(from: "2026-09-19T16:00:00Z")!
        payload.habits = [DataArchive.HabitDTO(clientUUID: "h1", name: "Read", startDay: singaporeMidnight)]
        payload.habitCheckIns = [DataArchive.HabitCheckInDTO(
            clientUUID: "h1-20260920", habitUUID: "h1", day: singaporeMidnight, count: 1
        )]

        let records = try SyncRecordMapper.records(from: payload)
        XCTAssertEqual(records.filter { $0.entity == "LocalHabit" }.map(\.recordID), ["h1"])
        XCTAssertEqual(records.filter { $0.entity == "LocalHabitCheckIn" }.map(\.recordID), ["h1-20260920"])

        let manifest = DataArchive.Manifest(
            schemaVersion: DataArchive.currentSchemaVersion, exportedAt: Date(), appVersion: "test", data: payload
        )
        // The same synthetic preview and mode `SyncApplier` commits through.
        let preview = DataImportService.Preview(
            manifest: manifest,
            archiveURL: URL(fileURLWithPath: "/dev/null"),
            entries: [:],
            counts: [:]
        )
        try DataImportService(modelContext: store.context).commit(preview: preview, mode: .replaceMatching)

        let habit = try XCTUnwrap(store.context.fetch(FetchDescriptor<LocalHabit>()).first)
        let row = try XCTUnwrap(store.context.fetch(FetchDescriptor<LocalHabitCheckIn>()).first)
        XCTAssertEqual(habit.startDay, day(2026, 9, 20))
        XCTAssertEqual(row.day, day(2026, 9, 20))
    }
}
