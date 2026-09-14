import XCTest
@testable import DexterMac

/// A finished thing is read newest-first (#534).
///
/// Asked for as *"for all places where things are sorted, like trips or even
/// lists, for the completed items, sort them latest first"*. The Wallet's Past
/// stack already read this way; Trips, Tasks, Lists and the vision board did not,
/// each for its own reason, which is why there are four rules here and not one.
///
/// What each test is really guarding is the DIRECTION, and the direction is easy
/// to lose: every one of these groups is one `<` away from reading backwards
/// again, and a list in the wrong order still looks like a working list.
final class LatestFirstOrderingTests: XCTestCase {

    private let day = TimeInterval(86_400)
    private lazy var epoch = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Trips

    private struct Span: TripDateRange {
        let name: String
        let startDate: Date
        let endDate: Date
    }

    private func trip(_ name: String, from: Int, to: Int) -> Span {
        Span(
            name: name,
            startDate: WallClock.startOfStoredDay(epoch.addingTimeInterval(Double(from) * day)),
            endDate: WallClock.startOfStoredDay(epoch.addingTimeInterval(Double(to) * day))
        )
    }

    private var today: Date { WallClock.startOfStoredDay(epoch) }

    /// The trip you just got back from leads. This is the change.
    func testPastTripsReadLatestFirst() {
        let groups = TripIndexOrder.grouped(
            [
                trip("Last year", from: -400, to: -390),
                trip("Last week", from: -9, to: -3),
                trip("Last month", from: -40, to: -33),
            ],
            today: today
        )

        XCTAssertEqual(groups.past.map(\.name), ["Last week", "Last month", "Last year"])
    }

    /// Two past trips that started the same day order by the one that ended
    /// LAST, because the whole comparison inverts, tiebreak included.
    func testPastTripsStartingTheSameDayOrderByTheLaterEnd() {
        let groups = TripIndexOrder.grouped(
            [
                trip("Short", from: -20, to: -18),
                trip("Long", from: -20, to: -12),
            ],
            today: today
        )

        XCTAssertEqual(groups.past.map(\.name), ["Long", "Short"])
    }

    /// Upcoming is NOT flipped. A trip you have not taken yet is read forwards:
    /// the next one to start is the one you are packing for.
    func testUpcomingTripsStillReadSoonestFirst() {
        let groups = TripIndexOrder.grouped(
            [
                trip("December", from: 90, to: 100),
                trip("Next week", from: 7, to: 14),
            ],
            today: today
        )

        XCTAssertEqual(groups.upcoming.map(\.name), ["Next week", "December"])
    }

    /// A trip spanning today is Active for the whole of today, and only drops to
    /// Past once its end date is behind us (#506's day-granular boundary).
    func testATripSpanningTodayIsActive() {
        let groups = TripIndexOrder.grouped(
            [
                trip("Here now", from: -2, to: 2),
                trip("Ends today", from: -5, to: 0),
                trip("Ended yesterday", from: -5, to: -1),
            ],
            today: today
        )

        XCTAssertEqual(groups.active.map(\.name), ["Ends today", "Here now"])
        XCTAssertEqual(groups.past.map(\.name), ["Ended yesterday"])
    }

    // MARK: - Tasks

    private func todo(_ title: String, completedAt: Date, createdAt: Date? = nil) -> Todo {
        Todo(
            id: UUID(),
            title: title,
            description: nil,
            completed: true,
            dueDate: nil,
            tag: nil,
            position: nil,
            version: 0,
            // Defaults to the reverse of the completion order: the store hands
            // tasks over `createdAt` ascending, and inheriting that order is the
            // bug this rule fixes, so a test that agreed with it would prove
            // nothing.
            createdAt: createdAt ?? epoch.addingTimeInterval(-completedAt.timeIntervalSince(epoch)),
            updatedAt: completedAt,
            deletedAt: nil
        )
    }

    /// The task you just ticked leads, whatever order it was created in.
    func testCompletedTasksReadLatestFirst() {
        let todos = [
            todo("Ticked on Monday", completedAt: epoch),
            todo("Ticked just now", completedAt: epoch.addingTimeInterval(3 * day)),
            todo("Ticked on Tuesday", completedAt: epoch.addingTimeInterval(day)),
        ]

        XCTAssertEqual(
            CompletedTaskOrder.latestFirst(todos).map(\.title),
            ["Ticked just now", "Ticked on Tuesday", "Ticked on Monday"]
        )
    }

    /// Two tasks completed in the same instant fall back to creation time, newest
    /// first, and that answer must not depend on the order they arrived in.
    /// `sorted(by:)` is not documented to be stable, so the tiebreak is
    /// load-bearing rather than decorative: without it the section can reshuffle
    /// itself on a re-render the user did nothing to cause.
    func testCompletedTasksTickedTogetherFallBackToCreationTime() {
        let same = epoch.addingTimeInterval(day)
        let todos = [
            todo("Older", completedAt: same, createdAt: epoch),
            todo("Newer", completedAt: same, createdAt: epoch.addingTimeInterval(day)),
        ]

        XCTAssertEqual(CompletedTaskOrder.latestFirst(todos).map(\.title), ["Newer", "Older"])
        XCTAssertEqual(
            CompletedTaskOrder.latestFirst(todos.reversed()).map(\.title),
            ["Newer", "Older"]
        )
    }

    // MARK: - List items

    private func items(_ spec: [(String, Bool)]) -> [ChecklistItem] {
        spec.map { ChecklistItem(text: $0.0, checked: $0.1) }
    }

    /// Ticking puts the item at the TOP of the completed block, directly under
    /// the last active item. Before this it was appended to the very bottom, so
    /// the thing you just finished ended up furthest from where you were working.
    func testATickedItemLandsAtTheTopOfTheCompletedBlock() {
        let list = items([("Milk", false), ("Bread", false), ("Coffee", true)])

        XCTAssertEqual(
            ChecklistItemOrder.afterToggle(list, at: 0).map(\.text),
            ["Bread", "Milk", "Coffee"]
        )
    }

    /// Ticking a second item pushes the first one down: the completed block
    /// reads latest-first all the way down, not just at its head.
    func testTheCompletedBlockStaysLatestFirstAcrossTicks() {
        var list = items([("Milk", false), ("Bread", false), ("Jam", false)])
        list = ChecklistItemOrder.afterToggle(list, at: 0)   // tick Milk
        list = ChecklistItemOrder.afterToggle(list, at: 0)   // tick Bread

        XCTAssertEqual(list.map(\.text), ["Jam", "Bread", "Milk"])
        XCTAssertEqual(list.map(\.checked), [false, true, true])
    }

    /// Un-ticking is unchanged: the item goes back to the BOTTOM of the active
    /// block, next to the things still to do.
    func testAnUnTickedItemReturnsToTheBottomOfTheActiveBlock() {
        let list = items([("Milk", false), ("Bread", true), ("Jam", true)])

        let result = ChecklistItemOrder.afterToggle(list, at: 2)
        XCTAssertEqual(result.map(\.text), ["Milk", "Jam", "Bread"])
        XCTAssertEqual(result.map(\.checked), [false, false, true])
    }

    /// A new item belongs at the end of the ACTIVE block, never under the
    /// completed ones (#267).
    func testANewItemGoesToTheEndOfTheActiveBlock() {
        let list = items([("Milk", false), ("Bread", true)])

        XCTAssertEqual(
            ChecklistItemOrder.afterAdding(ChecklistItem(text: "Jam"), to: list).map(\.text),
            ["Milk", "Jam", "Bread"]
        )
    }

    /// A drag cannot strand a completed item above an open one; relative order
    /// inside each block survives.
    func testADragCannotInterleaveTheTwoBlocks() {
        let list = items([("Done first", true), ("Milk", false), ("Done second", true)])

        XCTAssertEqual(
            ChecklistItemOrder.afterReorder(list).map(\.text),
            ["Milk", "Done first", "Done second"]
        )
    }

    /// A stale index from a row that has just gone away must not crash a toggle.
    func testAnOutOfBoundsToggleChangesNothing() {
        let list = items([("Milk", false)])

        XCTAssertEqual(ChecklistItemOrder.afterToggle(list, at: 4).map(\.text), ["Milk"])
    }
}
