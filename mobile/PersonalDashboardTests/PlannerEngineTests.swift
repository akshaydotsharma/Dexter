import XCTest
@testable import PersonalDashboard

/// The pure logic behind the Planner (#687): the rows of a day, free gaps,
/// capacity by source, overflow, conflicts, and which tasks fit a gap.
final class PlannerEngineTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return c
    }()

    /// Tuesday 29 September 2026, the design's sample day.
    private var day: Date { at(0, 0) }
    private let settings = WorkdaySettings(startMinute: 9 * 60, lengthMinutes: 9 * 60)

    private func at(_ h: Int, _ m: Int, dayOffset: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 29 + dayOffset; c.hour = h; c.minute = m
        return cal.date(from: c)!
    }

    private func event(_ id: String, _ sh: Int, _ sm: Int, _ eh: Int, _ em: Int, _ source: PlannerSource = .work, allDay: Bool = false, dayOffset: Int = 0) -> PlannerEvent {
        PlannerEvent(
            id: id, title: id, location: "", calendarID: source.rawValue, calendarTitle: source.rawValue,
            source: source, start: at(sh, sm, dayOffset: dayOffset), end: at(eh, em, dayOffset: dayOffset), isAllDay: allDay
        )
    }

    private func block(_ id: String, _ sh: Int, _ sm: Int, _ eh: Int, _ em: Int, kind: PlanBlockKind = .manual, task: String = "") -> PlannerBlock {
        PlannerBlock(id: id, kind: kind, title: id, day: day, start: at(sh, sm), end: at(eh, em),
                     durationMinutes: (eh * 60 + em) - (sh * 60 + sm), taskUUID: task)
    }

    private func dayBlock(_ id: String, minutes: Int, kind: PlanBlockKind = .manual, task: String = "", dayOffset: Int = 0) -> PlannerBlock {
        PlannerBlock(id: id, kind: kind, title: id, day: at(0, 0, dayOffset: dayOffset), start: nil, end: nil,
                     durationMinutes: minutes, taskUUID: task)
    }

    private func task(_ id: String, _ p: TaskPriority = .none, due: Date? = nil, done: Bool = false) -> PlannerTask {
        PlannerTask(id: id, title: id, priority: p, due: due, completed: done)
    }

    /// The design's Tuesday.
    private var sampleDay: PlannerDay {
        PlannerEngine.day(
            day,
            events: [
                event("Gym", 7, 0, 8, 0, .personal),
                event("Standup", 9, 30, 9, 45),
                event("1:1 Rajiv", 11, 0, 11, 30),
                event("Sprint review", 14, 0, 15, 0),
                event("Dentist", 14, 30, 15, 15, .personal),
                event("1:1 Priya", 16, 0, 16, 30),
                event("Q4 planning week", 0, 0, 0, 0, allDay: true, dayOffset: 0),
            ],
            blocks: [
                block("Focus PRD", 10, 0, 11, 0),
                block("Sprint board", 13, 0, 13, 30, kind: .task, task: "t-board"),
            ],
            tasks: [PlannerTask(id: "t-board", title: "Sprint board", priority: .p1, due: nil, completed: false)],
            now: at(8, 0),
            calendar: cal
        )
    }

    // MARK: - Rows

    func testTimedRowsAreOrderedAndAllDayEventsGoToTheAllDayRow() {
        let d = sampleDay
        XCTAssertEqual(d.timed.map(\.title), ["Gym", "Standup", "Focus PRD", "1:1 Rajiv", "Sprint board", "Sprint review", "Dentist", "1:1 Priya"])
        XCTAssertEqual(d.allDay.map(\.title), [], "an all-day event that ends at its own start covers no day")
    }

    func testAnAllDayEventCoveringTheDayIsInTheAllDayRow() {
        let d = PlannerEngine.day(day, events: [
            PlannerEvent(id: "wk", title: "Q4 planning week", location: "", calendarID: "w", calendarTitle: "w",
                         source: .work, start: at(0, 0, dayOffset: -1), end: at(0, 0, dayOffset: 3), isAllDay: true)
        ], blocks: [], tasks: [], now: at(8, 0), calendar: cal)
        XCTAssertEqual(d.allDay.map(\.title), ["Q4 planning week"])
        XCTAssertTrue(d.timed.isEmpty)
    }

    func testATaskPlannedToADayWithNoHourIsInTheAllDayRow() {
        let d = PlannerEngine.day(day, events: [], blocks: [dayBlock("b1", minutes: 120, kind: .task, task: "okrs")],
                                  tasks: [task("okrs", .p0)], now: at(8, 0), calendar: cal)
        XCTAssertEqual(d.allDay.count, 1)
        XCTAssertEqual(d.allDay[0].source, .task)
        XCTAssertTrue(d.allDay[0].detail.contains("planned, no time"))
        XCTAssertTrue(d.allDay[0].countsTowardCapacity)
    }

    func testDaylessDueTaskShowsTodayAndOverdueShowsInDanger() {
        let dueToday = cal.startOfDay(for: day)                   // midnight = no hour (#657)
        let dueYesterday = cal.startOfDay(for: at(0, 0, dayOffset: -1))
        let d = PlannerEngine.day(day, events: [], blocks: [], tasks: [
            task("Pay card", due: dueToday),
            task("Reply Tim", .p1, due: dueYesterday),
            task("Done one", due: dueYesterday, done: true),
        ], now: at(10, 0), calendar: cal)
        XCTAssertEqual(d.allDay.map(\.title), ["Reply Tim", "Pay card"], "overdue first; completed tasks never show")
        XCTAssertEqual(d.allDay[0].overdueDays, 1)
        XCTAssertEqual(d.allDay[1].overdueDays, 0)
    }

    func testOverdueOnlyShowsOnTheCurrentDay() {
        let dueYesterday = cal.startOfDay(for: at(0, 0, dayOffset: -1))
        let tomorrow = PlannerEngine.day(at(0, 0, dayOffset: 1), events: [], blocks: [],
                                         tasks: [task("Reply Tim", due: dueYesterday)], now: at(10, 0), calendar: cal)
        XCTAssertTrue(tomorrow.allDay.isEmpty)
    }

    func testATimedDueTaskIsAnOrdinaryThirtyMinuteTile() {
        let d = PlannerEngine.day(day, events: [], blocks: [], tasks: [task("Deck", .p0, due: at(17, 0))], now: at(8, 0), calendar: cal)
        XCTAssertEqual(d.timed.count, 1)
        XCTAssertTrue(d.timed[0].occupiesTime)
        XCTAssertEqual(d.timed[0].start, at(17, 0))
        XCTAssertEqual(d.timed[0].end, at(17, 30))
        XCTAssertEqual(PlannerEngine.capacity(of: d, settings: settings, calendar: cal).minutes(.task), 30,
                       "a tile takes grid space, so it counts like one")
    }

    func testADueTileIsClippedAtMidnight() {
        let d = PlannerEngine.day(day, events: [], blocks: [], tasks: [task("Late", due: at(23, 45))], now: at(8, 0), calendar: cal)
        XCTAssertEqual(d.timed[0].end, at(0, 0, dayOffset: 1))
    }

    func testAPlannedTaskShowsAsItsBlockNotAlsoAsItsDueDate() {
        let d = PlannerEngine.day(day, events: [], blocks: [block("b", 13, 0, 13, 30, kind: .task, task: "t")],
                                  tasks: [task("t", due: at(17, 0))], now: at(8, 0), calendar: cal)
        XCTAssertEqual(d.all.count, 1)
        XCTAssertTrue(d.all[0].isBlock)
    }

    // MARK: - Capacity

    func testCapacityCountsOnlyTheWorkdayAndSplitsBySource() {
        let c = PlannerEngine.capacity(of: sampleDay, settings: settings, calendar: cal)
        XCTAssertEqual(c.minutes(.work), 15 + 30 + 60 + 30, "standup, Rajiv, sprint review, Priya")
        XCTAssertEqual(c.minutes(.personal), 45, "the 7am gym is outside the 9:00 workday")
        XCTAssertEqual(c.minutes(.manual), 60)
        XCTAssertEqual(c.minutes(.task), 30)
        XCTAssertEqual(c.bookedMinutes, 135 + 45 + 60 + 30)
        XCTAssertEqual(c.capacityMinutes, 540)
        XCTAssertEqual(c.freeMinutes, 540 - 270)
        XCTAssertFalse(c.isOver)
    }

    func testHidingASourceTakesItOutOfTheMeter() {
        let c = PlannerEngine.capacity(of: sampleDay, settings: settings, visible: [.work, .task, .manual], calendar: cal)
        XCTAssertEqual(c.minutes(.personal), 0)
        XCTAssertEqual(c.bookedMinutes, 135 + 60 + 30)
    }

    func testMeterTotalEqualsTheSumOfItsParts() {
        let c = PlannerEngine.capacity(of: sampleDay, settings: settings, calendar: cal)
        XCTAssertEqual(c.bookedMinutes, PlannerSource.allCases.map(c.minutes).reduce(0, +))
    }

    func testAnOverloadedDayReportsItsOverflow() {
        let d = PlannerEngine.day(day, events: [
            event("A", 9, 0, 13, 0), event("B", 13, 0, 17, 0),
        ], blocks: [dayBlock("okrs", minutes: 180, kind: .task, task: "o")], tasks: [task("o")], now: at(8, 0), calendar: cal)
        let c = PlannerEngine.capacity(of: d, settings: settings, calendar: cal)
        XCTAssertEqual(c.bookedMinutes, 480 + 180)
        XCTAssertTrue(c.isOver)
        XCTAssertEqual(c.overflowMinutes, 120)
        XCTAssertEqual(c.freeMinutes, 0)
    }

    func testAWeekendHasNoCapacityAndNeverOverflows() {
        let saturday = at(0, 0, dayOffset: 4)
        let d = PlannerEngine.day(saturday, events: [event("Swim", 9, 0, 19, 0, .personal, dayOffset: 4)],
                                  blocks: [], tasks: [], now: at(8, 0), calendar: cal)
        let c = PlannerEngine.capacity(of: d, settings: settings, calendar: cal)
        XCTAssertFalse(c.isWorkday)
        XCTAssertEqual(c.capacityMinutes, 0)
        XCTAssertEqual(c.bookedMinutes, 540)
        XCTAssertFalse(c.isOver)
    }

    // MARK: - Gaps

    func testFreeTimeIsTheWorkdayMinusBusyTime() {
        let gaps = PlannerEngine.freeTime(on: sampleDay, settings: settings, calendar: cal)
        XCTAssertEqual(gaps.map { PlannerEngine.minutes(from: $0.start, to: $0.end) }, [30, 15, 90, 30, 45, 90])
        XCTAssertEqual(gaps[2].start, at(11, 30))
        XCTAssertEqual(gaps[2].end, at(13, 0))
        XCTAssertEqual(gaps.last?.end, at(18, 0))
    }

    func testGapsShorterThanFifteenMinutesAreDropped() {
        let window = DateInterval(start: at(9, 0), end: at(10, 0))
        let gaps = PlannerEngine.freeGaps(in: window, busy: [DateInterval(start: at(9, 10), end: at(9, 50))])
        XCTAssertTrue(gaps.isEmpty, "10 minutes either side is not worth a row")
    }

    func testPastFreeTimeIsDroppedAndTheCurrentGapStartsNow() {
        let gaps = PlannerEngine.freeTime(on: sampleDay, settings: settings, now: at(11, 42), calendar: cal)
        XCTAssertEqual(gaps.first?.start, at(11, 45), "rounded up to five minutes")
        XCTAssertEqual(gaps.first?.end, at(13, 0))
    }

    func testFreeTimeIgnoresAHiddenSource() {
        let gaps = PlannerEngine.freeTime(on: sampleDay, settings: settings, visible: [.work, .task, .manual], calendar: cal)
        XCTAssertTrue(gaps.contains { $0.start == at(15, 0) && $0.end == at(16, 0) }, "hiding Personal frees the dentist's 15 minutes")
    }

    func testOverlappingRowsFormOneConflictWithItsOverlap() {
        let conflicts = PlannerEngine.conflicts(in: sampleDay)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].items.map(\.title), ["Sprint review", "Dentist"])
        XCTAssertEqual(conflicts[0].overlapMinutes, 30)
        XCTAssertEqual(conflicts[0].overlapStart, at(14, 30))
        XCTAssertEqual(conflicts[0].overlapEnd, at(15, 0))
    }

    func testTouchingRowsDoNotConflict() {
        let d = PlannerEngine.day(day, events: [event("A", 9, 0, 10, 0), event("B", 10, 0, 11, 0)],
                                  blocks: [], tasks: [], now: at(8, 0), calendar: cal)
        XCTAssertTrue(PlannerEngine.conflicts(in: d).isEmpty)
    }

    func testHidingASourceRemovesItsConflict() {
        XCTAssertTrue(PlannerEngine.conflicts(in: sampleDay, visible: [.work, .task, .manual]).isEmpty)
    }

    // MARK: - Time grid geometry

    func testTileGeometryIsProportionalToTime() {
        let g = PlannerEngine.tileGeometry(start: at(9, 30), end: at(10, 0), dayStart: day, hourHeight: 60, minHeight: 20)
        XCTAssertEqual(g.y, 570, accuracy: 0.001, "9.5 hours down")
        XCTAssertEqual(g.height, 30, accuracy: 0.001, "30 minutes is half an hour row")
        let long = PlannerEngine.tileGeometry(start: at(14, 0), end: at(16, 30), dayStart: day, hourHeight: 52, minHeight: 20)
        XCTAssertEqual(long.y, 14 * 52, accuracy: 0.001)
        XCTAssertEqual(long.height, 2.5 * 52, accuracy: 0.001)
    }

    func testAShortTileKeepsItsMinimumHeight() {
        let g = PlannerEngine.tileGeometry(start: at(9, 30), end: at(9, 45), dayStart: day, hourHeight: 52, minHeight: 20)
        XCTAssertEqual(g.height, 20, "15 minutes would be 13pt, too small to tap")
    }

    func testATileRunningPastMidnightStopsAtTheDayEnd() {
        let g = PlannerEngine.tileGeometry(start: at(23, 0), end: at(1, 0, dayOffset: 1), dayStart: day, hourHeight: 50, minHeight: 20)
        XCTAssertEqual(g.y + g.height, 24 * 50, accuracy: 0.001)
    }

    func testATapIsReadAsATimeSnappedToFifteenMinutes() {
        XCTAssertEqual(PlannerEngine.time(atY: 15 * 52 + 20, dayStart: day, hourHeight: 52), at(15, 15), "20pt into the hour is 23 minutes")
        XCTAssertEqual(PlannerEngine.time(atY: 0, dayStart: day, hourHeight: 52), at(0, 0))
        XCTAssertEqual(PlannerEngine.time(atY: 99_999, dayStart: day, hourHeight: 52), at(23, 45), "clamped inside the day")
    }

    // MARK: - Lanes

    func testATileThatOverlapsNothingTakesTheFullWidth() {
        let lanes = PlannerEngine.lanes(sampleDay.timed)
        let standup = lanes.first { $0.itemID == "e-Standup" }
        XCTAssertEqual(standup?.count, 1)
        XCTAssertEqual(standup?.index, 0)
        XCTAssertEqual(standup?.inConflict, false)
    }

    func testTwoOverlappingTilesSitSideBySide() {
        let lanes = PlannerEngine.lanes(sampleDay.timed)
        let review = lanes.first { $0.itemID == "e-Sprint review" }
        let dentist = lanes.first { $0.itemID == "e-Dentist" }
        XCTAssertEqual(review?.count, 2)
        XCTAssertEqual(dentist?.count, 2)
        XCTAssertEqual(review?.index, 0)
        XCTAssertEqual(dentist?.index, 1)
        XCTAssertEqual(review?.inConflict, true)
    }

    func testALaneIsReusedOnceItsTileEnds() {
        // A 9-12 long block with two back-to-back meetings beside it needs two
        // lanes, not three: the second meeting reuses the first one's lane.
        let d = PlannerEngine.day(day, events: [
            event("Long", 9, 0, 12, 0), event("M1", 9, 0, 10, 0), event("M2", 10, 0, 11, 0),
        ], blocks: [], tasks: [], now: at(8, 0), calendar: cal)
        let lanes = Dictionary(uniqueKeysWithValues: PlannerEngine.lanes(d.timed).map { ($0.itemID, $0) })
        XCTAssertEqual(lanes["e-Long"]?.count, 2)
        XCTAssertEqual(lanes["e-M1"]?.index, lanes["e-M2"]?.index)
        XCTAssertNotEqual(lanes["e-Long"]?.index, lanes["e-M1"]?.index)
    }

    func testThreeWayOverlapNeedsThreeLanes() {
        let d = PlannerEngine.day(day, events: [
            event("A", 9, 0, 11, 0), event("B", 9, 30, 10, 30), event("C", 10, 0, 10, 45),
        ], blocks: [], tasks: [], now: at(8, 0), calendar: cal)
        let lanes = PlannerEngine.lanes(d.timed)
        XCTAssertEqual(Set(lanes.map(\.index)), [0, 1, 2])
        XCTAssertTrue(lanes.allSatisfy { $0.count == 3 && $0.inConflict })
    }

    // MARK: - Tasks that fit a gap

    func testCandidatesRankOverdueThenP0ThenDueDate() {
        let tasks = [
            task("P2 soon", .p2, due: at(0, 0, dayOffset: 1)),
            task("P0 later", .p0, due: at(0, 0, dayOffset: 3)),
            task("Overdue P1", .p1, due: at(0, 0, dayOffset: -1)),
            task("Very overdue", .none, due: at(0, 0, dayOffset: -4)),
            task("P0 sooner", .p0, due: at(0, 0, dayOffset: 1)),
            task("No date", .p1),
            task("Done", .p0, done: true),
        ]
        let ranked = PlannerEngine.candidates(tasks: tasks, blocks: [], today: at(9, 0), calendar: cal)
        XCTAssertEqual(ranked.map(\.id), ["Very overdue", "Overdue P1", "P0 sooner", "P0 later", "No date", "P2 soon"])
        XCTAssertEqual(ranked.first?.overdueDays, 4)
    }

    func testATaskAlreadyPlannedFromTodayOnIsNotACandidate() {
        let ranked = PlannerEngine.candidates(
            tasks: [task("a"), task("b")],
            blocks: [dayBlock("pb", minutes: 30, kind: .task, task: "a", dayOffset: 2)],
            today: at(9, 0), calendar: cal
        )
        XCTAssertEqual(ranked.map(\.id), ["b"])
    }

    func testAPlanInThePastDoesNotHideATask() {
        let ranked = PlannerEngine.candidates(
            tasks: [task("a")],
            blocks: [dayBlock("pb", minutes: 30, kind: .task, task: "a", dayOffset: -3)],
            today: at(9, 0), calendar: cal
        )
        XCTAssertEqual(ranked.map(\.id), ["a"])
    }

    func testOnlyTasksThatFitAreOfferedAndTheDefaultPickFillsInRankOrder() {
        let ranked = PlannerEngine.candidates(
            tasks: [
                task("Reply Tim", .p1, due: at(0, 0, dayOffset: -1)),
                task("Review PRD", .p0, due: at(0, 0, dayOffset: 1)),
                task("Book flights", .p2, due: at(0, 0, dayOffset: 3)),
                task("Draft OKRs", .p0, due: at(0, 0, dayOffset: 2)),
            ],
            blocks: [], today: at(9, 0),
            estimates: ["Reply Tim": 15, "Review PRD": 60, "Book flights": 30, "Draft OKRs": 120],
            calendar: cal
        )
        let fitting = PlannerEngine.fitting(ranked, gapMinutes: 90)
        XCTAssertEqual(fitting.map(\.id), ["Reply Tim", "Review PRD", "Book flights"], "the 2h task does not fit 1h 30m")
        let picked = PlannerEngine.defaultSelection(fitting, gapMinutes: 90)
        XCTAssertEqual(picked, ["Reply Tim", "Review PRD"], "15m + 1h leaves 15m, too little for the 30m task")
    }

    func testPlacementsRunBackToBackFromTheGapStart() {
        let ranked = PlannerEngine.candidates(tasks: [task("a", .p0), task("b", .p1)], blocks: [], today: at(9, 0),
                                              estimates: ["a": 15, "b": 60], calendar: cal)
        let placed = PlannerEngine.placements(for: ranked, in: DateInterval(start: at(11, 30), end: at(13, 0)))
        XCTAssertEqual(placed.map(\.start), [at(11, 30), at(11, 45)])
        XCTAssertEqual(placed.map(\.end), [at(11, 45), at(12, 45)])
    }

    func testPlacementsStopBeforeRunningPastTheGap() {
        let ranked = PlannerEngine.candidates(tasks: [task("a", .p0), task("b", .p1)], blocks: [], today: at(9, 0),
                                              estimates: ["a": 60, "b": 60], calendar: cal)
        let placed = PlannerEngine.placements(for: ranked, in: DateInterval(start: at(11, 30), end: at(13, 0)))
        XCTAssertEqual(placed.count, 1)
    }

    // MARK: - Moving off an overloaded day

    func testNearestDayWithRoomSkipsFullDaysAndWeekends() {
        let thursday = at(0, 0, dayOffset: 2)
        let free: (Date) -> Int = { d in
            let wd = self.cal.component(.weekday, from: d)
            return wd == 6 ? 60 : (wd == 2 ? 300 : 0)      // Fri 1h, Mon 5h, the rest full
        }
        let target = PlannerEngine.nearestDayWithRoom(after: thursday, minutes: 120, freeMinutes: free, settings: settings, calendar: cal)
        XCTAssertEqual(target.map { cal.component(.weekday, from: $0) }, 2, "Friday is too small, the weekend is not a workday")
    }

    // MARK: - Formatting

    func testDurationFormatting() {
        XCTAssertEqual(PlannerFormat.duration(45), "45m")
        XCTAssertEqual(PlannerFormat.duration(60), "1h")
        XCTAssertEqual(PlannerFormat.duration(150), "2h 30m")
    }
}
