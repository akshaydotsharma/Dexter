import XCTest
import SwiftData
@testable import PersonalDashboard

/// What a recurring template actually puts in the task list, and what stops it
/// putting the same thing there twice (#524).
///
/// Every case here is a silent failure in the app: a duplicate task, a missing
/// one, or a column of stale overdue rows after a week away. None of them shows
/// up in a build, and none of them shows up in a screenshot taken on the day the
/// template was made.
@MainActor
final class RecurringTaskMaterialisationTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: RecurringTaskService!
    private var todos: TodoService!

    /// A Saturday, so nothing lines up with a week boundary by accident.
    private let today = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = RecurringTaskService(store: store)
        todos = TodoService(store: store)
    }

    override func tearDown() async throws {
        todos = nil
        service = nil
        store = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func openTasks() throws -> [LocalTodo] {
        try store.context.fetch(
            FetchDescriptor<LocalTodo>(predicate: #Predicate { $0.deletedAt == nil && $0.completed == false })
        )
    }

    private func allTasks() throws -> [LocalTodo] {
        try store.context.fetch(FetchDescriptor<LocalTodo>())
    }

    /// A daily template starting today, so the first occurrence is always in range.
    @discardableResult
    private func makeDaily(leadDays: Int = 3) throws -> RecurringTask {
        try service.create(
            title: "Take the bins out",
            frequency: .daily,
            leadDays: leadDays,
            startDate: today
        )
    }

    private func days(_ count: Int, from date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: count, to: date)!
    }

    // MARK: - Creating the occurrence

    func testAPassCreatesTheFirstOccurrence() throws {
        try makeDaily()
        let created = service.materialize(reference: today)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(try openTasks().map(\.title), ["Take the bins out"])
    }

    /// The occurrence is a real task, carrying the template's identity so the row,
    /// the editor and the next pass can all recognise it.
    func testTheOccurrenceCarriesItsTemplate() throws {
        let template = try makeDaily()
        service.materialize(reference: today)
        let task = try XCTUnwrap(try openTasks().first)
        XCTAssertEqual(task.recurringTaskUUID, template.clientUUID)
        XCTAssertFalse(task.occurrenceKey.isEmpty)
        XCTAssertNotNil(task.dueDate)
    }

    /// The whole point of the lead time. A template whose next date is outside the
    /// window puts nothing in the list yet.
    func testNothingAppearsBeforeTheLeadWindowOpens() throws {
        // Monthly on the 1st, starting today, with no lead: nothing until the 1st.
        try service.create(
            title: "Pay rent",
            frequency: .monthly,
            dayOfMonth: 1,
            leadDays: 0,
            startDate: today
        )
        XCTAssertTrue(service.materialize(reference: today).isEmpty)
        XCTAssertTrue(try openTasks().isEmpty)
    }

    /// And it appears the moment the window does open, not on the day itself.
    func testItAppearsOnceTheLeadWindowOpens() throws {
        let template = try service.create(
            title: "Pay rent",
            frequency: .daily,
            leadDays: 2,
            startDate: days(5, from: today)
        )
        XCTAssertTrue(service.materialize(reference: today).isEmpty)
        XCTAssertEqual(service.materialize(reference: days(3, from: today)).count, 1)
        XCTAssertEqual(template.lastOccurrenceKey, RecurrenceRule.dayKey(days(5, from: today)))
    }

    // MARK: - One at a time

    /// A daily template must not put seven rows in the list because seven days are
    /// inside a seven-day window.
    func testOnlyOneOccurrenceIsOpenAtATime() throws {
        try makeDaily(leadDays: 7)
        service.materialize(reference: today)
        service.materialize(reference: today)
        service.materialize(reference: days(1, from: today))
        XCTAssertEqual(try openTasks().count, 1)
    }

    /// Completing one is what releases the next, and the template is untouched by
    /// it: that is the behaviour the whole feature was asked for.
    func testCompletingOneReleasesTheNextAndKeepsTheTemplate() throws {
        let template = try makeDaily()
        service.materialize(reference: today)
        let first = try XCTUnwrap(try openTasks().first)

        first.completed = true
        try store.context.save()

        service.materialize(reference: days(1, from: today))

        XCTAssertEqual(try openTasks().count, 1, "the next one should be open")
        XCTAssertEqual(try allTasks().count, 2, "the completed one stays as history")
        XCTAssertTrue(template.isActive, "completing an occurrence must not retire the template")
    }

    // MARK: - Idempotency

    /// The first guard. Running the pass again changes nothing.
    func testRepeatedPassesCreateNothingNew() throws {
        try makeDaily()
        service.materialize(reference: today)
        let after = try allTasks().count
        for _ in 0..<5 { service.materialize(reference: today) }
        XCTAssertEqual(try allTasks().count, after)
    }

    /// The second guard, and the one that is easy to get wrong: the key has to be
    /// checked against SOFT-DELETED rows too. Otherwise deleting today's occurrence
    /// puts it straight back on the next pass, and the task cannot be dismissed.
    ///
    /// `leadDays: 0` so the assertion is about the guard and nothing else: with a
    /// lead, TOMORROW's occurrence is legitimately in range the moment today's stops
    /// being open, and a replacement appearing would be correct behaviour rather
    /// than the defect under test. That case is asserted separately below.
    func testDeletingAnOccurrenceSkipsThatDateRatherThanRemakingIt() async throws {
        try makeDaily(leadDays: 0)
        service.materialize(reference: today)
        let first = try XCTUnwrap(try openTasks().first)
        let deletedKey = first.occurrenceKey

        try await todos.delete(first.toDTO())

        service.materialize(reference: today)
        let keys = try allTasks().map(\.occurrenceKey)
        XCTAssertEqual(keys.filter { $0 == deletedKey }.count, 1, "the deleted date must not come back")
        XCTAssertTrue(try openTasks().isEmpty, "and today has nothing else due")
    }

    /// Deleting one with a lead time in play. The skipped date still must not come
    /// back, but the NEXT date may legitimately arrive straight away, because a
    /// 3-day lead already covers tomorrow. What would be wrong is the same date
    /// reappearing under a new row.
    func testDeletingOneWithALeadTimeBringsTheNextDateNotTheSameOne() async throws {
        try makeDaily(leadDays: 3)
        service.materialize(reference: today)
        let first = try XCTUnwrap(try openTasks().first)
        let deletedKey = first.occurrenceKey

        try await todos.delete(first.toDTO())
        service.materialize(reference: today)

        let open = try openTasks()
        XCTAssertEqual(open.count, 1)
        XCTAssertNotEqual(open[0].occurrenceKey, deletedKey, "the skipped date must not come back")
        XCTAssertEqual(
            try allTasks().filter { $0.occurrenceKey == deletedKey }.count, 1,
            "and it must not exist twice"
        )
    }

    // MARK: - Missed dates

    /// A week away must not come back to seven identical overdue rows. The cursor
    /// walks past what has gone and creates only what is current.
    func testAGapCreatesOneTaskNotABacklog() throws {
        try makeDaily()
        let later = days(7, from: today)
        let created = service.materialize(reference: later)
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(try allTasks().count, 1)
        XCTAssertEqual(
            RecurrenceRule.dayKey(try XCTUnwrap(try openTasks().first?.dueDate)),
            RecurrenceRule.dayKey(later),
            "the one task should be today's, not the first one missed"
        )
    }

    /// An occurrence that WAS created and left undone is a different thing: it is a
    /// real task, and it holds the next one back until it is dealt with.
    func testAnUndoneOccurrenceBlocksTheNextOne() throws {
        try makeDaily()
        service.materialize(reference: today)
        service.materialize(reference: days(4, from: today))
        XCTAssertEqual(try allTasks().count, 1)
    }

    // MARK: - Lifecycle

    func testAPausedTemplateCreatesNothing() throws {
        let template = try makeDaily()
        try service.setActive(template, false)
        XCTAssertTrue(service.materialize(reference: today).isEmpty)
        XCTAssertTrue(try openTasks().isEmpty)
    }

    /// Resuming picks up from the next future date. It does not backfill the days
    /// it was paused for, which would punish the user for pausing.
    func testResumingPicksUpFromTodayNotFromHistory() throws {
        let template = try makeDaily()
        try service.setActive(template, false)
        service.materialize(reference: today)

        try service.setActive(template, true)
        let later = days(10, from: today)
        service.materialize(reference: later)

        XCTAssertEqual(try allTasks().count, 1)
        XCTAssertEqual(
            RecurrenceRule.dayKey(try XCTUnwrap(try openTasks().first?.dueDate)),
            RecurrenceRule.dayKey(later)
        )
    }

    func testATemplatePastItsEndDateCreatesNothing() throws {
        try service.create(
            title: "Water the plants",
            frequency: .daily,
            leadDays: 0,
            startDate: today,
            endDate: days(2, from: today)
        )
        service.materialize(reference: today)
        XCTAssertEqual(try allTasks().count, 1)

        // Complete it so the "one at a time" guard is not what is being measured.
        let first = try XCTUnwrap(try openTasks().first)
        first.completed = true
        try store.context.save()

        XCTAssertTrue(service.materialize(reference: days(9, from: today)).isEmpty)
        XCTAssertEqual(try allTasks().count, 1)
    }

    /// Deleting a template is not deleting its tasks. One of them may be open in
    /// front of the user, and it is an ordinary task now.
    func testDeletingATemplateKeepsTheTasksItMade() throws {
        let template = try makeDaily()
        service.materialize(reference: today)
        XCTAssertEqual(try openTasks().count, 1)

        try service.delete(template)

        XCTAssertEqual(try openTasks().count, 1)
        XCTAssertTrue(try service.templates().isEmpty)
    }

    // MARK: - Validation

    func testAWeeklyRuleNeedsAWeekday() {
        XCTAssertThrowsError(try service.create(title: "Gym", frequency: .weekly, weekdayMask: 0))
    }

    func testATitleIsRequired() {
        XCTAssertThrowsError(try service.create(title: "   ", frequency: .daily))
    }

    // MARK: - Content

    /// The template's fields land on the task it makes. Losing one of these is
    /// invisible until the person wonders why their repeating task has no tag.
    func testTheOccurrenceCopiesTheTemplatesFields() throws {
        try service.create(
            title: "Call the dentist",
            taskDescription: "Ask about the crown",
            tag: "health",
            priority: 2,
            address: "12 Orchard Road",
            googleMapsLink: "https://maps.app.goo.gl/abc",
            remindMe: true,
            frequency: .daily,
            leadDays: 0,
            startDate: today
        )
        service.materialize(reference: today)
        let task = try XCTUnwrap(try openTasks().first)
        XCTAssertEqual(task.title, "Call the dentist")
        XCTAssertEqual(task.todoDescription, "Ask about the crown")
        XCTAssertEqual(task.tag, "health")
        XCTAssertEqual(task.priority, 2)
        XCTAssertEqual(task.address, "12 Orchard Road")
        XCTAssertEqual(task.googleMapsLink, "https://maps.app.goo.gl/abc")
        XCTAssertTrue(task.remindMe)
    }

    /// The DTO is what the row and the editor read, and what sync ships. A field
    /// missing here means a repeating task looks like a one-off on the other device.
    func testTheDTOReportsTheOccurrence() throws {
        try makeDaily()
        service.materialize(reference: today)
        let dto = try XCTUnwrap(try openTasks().first).toDTO()
        XCTAssertTrue(dto.isRecurringOccurrence)
        XCTAssertFalse(dto.occurrenceKey.isEmpty)
    }

    /// An ordinary task must not read as an occurrence, or every task in the list
    /// grows a repeat glyph.
    func testAnOrdinaryTaskIsNotAnOccurrence() async throws {
        let task = try await todos.create(TodoCreateRequest(title: "One off", description: nil, dueDate: nil, tag: nil))
        XCTAssertFalse(task.isRecurringOccurrence)
    }
}
