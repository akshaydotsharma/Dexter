import XCTest
@testable import DexterMac

/// What order a block's rows come out in (#446).
///
/// Requested as *"the sub items should be sorted chronologically. If there is no
/// date, add them wherever they were added but if there is then it should be
/// chronological, like the first comes up."* Both halves of that are rules, and
/// the second half is the one that is easy to lose in a refactor — a sort that
/// treats undated rows as "distant future" or "distant past" satisfies the first
/// half and quietly breaks the second.
@MainActor
final class VisionRowOrderTests: XCTestCase {

    private let day = TimeInterval(86_400)
    private lazy var epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func todo(_ title: String, due: Date? = nil, done: Bool = false) -> Todo {
        Todo(
            id: UUID(),
            title: title,
            description: nil,
            completed: done,
            dueDate: due,
            tag: nil,
            position: nil,
            version: 0,
            createdAt: epoch,
            updatedAt: epoch,
            deletedAt: nil
        )
    }

    private func task(_ title: String, due: Date? = nil, done: Bool = false) -> VisionRow {
        .task(todo(title, due: due, done: done))
    }

    private func item(_ text: String, done: Bool = false) -> VisionRow {
        .item(VisionItem(text: text, completed: done))
    }

    private func titles(_ rows: [VisionRow]) -> [String] {
        rows.map(\.title)
    }

    // MARK: - Chronological

    /// *"like the first comes up"* — soonest at the top, whatever order they
    /// were added in.
    func testDatedRowsComeOutSoonestFirst() {
        let rows = [
            task("Friday", due: epoch.addingTimeInterval(4 * day)),
            task("Tomorrow", due: epoch.addingTimeInterval(day)),
            task("Next week", due: epoch.addingTimeInterval(7 * day)),
        ]

        XCTAssertEqual(
            titles(VisionRowOrder.arrange(rows)),
            ["Tomorrow", "Friday", "Next week"]
        )
    }

    /// An overdue row is the soonest of all, not a special case. Sorting by the
    /// date itself is what gets that right for free.
    func testAnOverdueRowLeads() {
        let rows = [
            task("Tomorrow", due: epoch.addingTimeInterval(day)),
            task("Last week", due: epoch.addingTimeInterval(-7 * day)),
        ]

        XCTAssertEqual(titles(VisionRowOrder.arrange(rows)), ["Last week", "Tomorrow"])
    }

    /// Two rows due the same day must not swap on a re-render. `sorted(by:)` is
    /// not documented to be stable, so this is a real hazard rather than a
    /// theoretical one — and a list that shuffles itself while you look at it is
    /// worse than one in the wrong order.
    func testRowsDueTheSameDayKeepTheOrderTheyWereAddedIn() {
        let same = epoch.addingTimeInterval(2 * day)
        let rows = [task("First", due: same), task("Second", due: same), task("Third", due: same)]

        XCTAssertEqual(
            titles(VisionRowOrder.arrange(rows)),
            ["First", "Second", "Third"]
        )
    }

    // MARK: - Undated rows keep their place

    /// *"If there is no date, add them wherever they were added."* Items are
    /// never dated, so a block of plain items must come out exactly as typed.
    func testUndatedRowsKeepTheOrderTheyWereAddedIn() {
        let rows = [item("Milk"), item("Bread"), item("Coffee")]

        XCTAssertEqual(titles(VisionRowOrder.arrange(rows)), ["Milk", "Bread", "Coffee"])
    }

    /// The two rules together: dated rows sort and lead, undated rows follow in
    /// their own order. Undated is NOT "due never" sorted to the end of one list
    /// — it is a separate group that was never in the sort at all.
    func testDatedRowsLeadAndUndatedOnesFollowUntouched() {
        let rows = [
            item("Pick a venue"),
            task("Send invites", due: epoch.addingTimeInterval(3 * day)),
            item("Playlist"),
            task("Book the car", due: epoch.addingTimeInterval(day)),
        ]

        XCTAssertEqual(
            titles(VisionRowOrder.arrange(rows)),
            ["Book the car", "Send invites", "Pick a venue", "Playlist"]
        )
    }

    /// A task with no due date is undated like any item, and sits with them
    /// rather than being sorted as though it were due at some extreme.
    func testAnUndatedTaskSitsWithTheUndatedRows() {
        let rows = [
            task("No date on this one"),
            task("Thursday", due: epoch.addingTimeInterval(3 * day)),
            item("Nor this"),
        ]

        XCTAssertEqual(
            titles(VisionRowOrder.arrange(rows)),
            ["Thursday", "No date on this one", "Nor this"]
        )
    }

    // MARK: - Completed rows

    /// Completed rows still sink below everything open, whatever their dates
    /// say. A row that is done has nothing left to be due.
    func testCompletedRowsSinkBelowOpenOnesRegardlessOfDate() {
        let rows = [
            task("Done and was due first", due: epoch.addingTimeInterval(day), done: true),
            task("Still open", due: epoch.addingTimeInterval(5 * day)),
            item("Still open item"),
        ]

        XCTAssertEqual(
            titles(VisionRowOrder.arrange(rows)),
            ["Still open", "Still open item", "Done and was due first"]
        )
    }

    /// And the sunken group is ordered by the same rule, so a finished block
    /// reads as the list that was worked through rather than as a pile.
    func testTheCompletedGroupIsOrderedToo() {
        let rows = [
            task("Done late", due: epoch.addingTimeInterval(9 * day), done: true),
            item("Done item", done: true),
            task("Done early", due: epoch.addingTimeInterval(day), done: true),
        ]

        XCTAssertEqual(
            titles(VisionRowOrder.arrange(rows)),
            ["Done early", "Done late", "Done item"]
        )
    }

    /// A row just ticked is held in place for a beat so the check is seen
    /// landing on it. Held means held: it keeps its position among the open
    /// rows, sorted with them.
    func testAHeldRowStaysAmongTheOpenOnes() {
        let ticked = todo("Just ticked", due: epoch.addingTimeInterval(day), done: true)
        let rows = [
            task("Later", due: epoch.addingTimeInterval(5 * day)),
            .task(ticked),
            task("Long done", due: epoch, done: true),
        ]

        XCTAssertEqual(
            titles(VisionRowOrder.arrange(rows, sinkHold: [ticked.id])),
            ["Just ticked", "Later", "Long done"]
        )
    }

    func testAnEmptyBlockOrdersToNothing() {
        XCTAssertTrue(VisionRowOrder.arrange([]).isEmpty)
    }
}
