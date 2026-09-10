import XCTest
import SwiftData
@testable import PersonalDashboard

/// One submit creates one expense (#514).
///
/// A €16 city tax landed twice: two rows 290 ms apart, identical in every
/// field except `clientUUID`, both written by the phone at consecutive Lamport
/// ticks. `AddExpenseSheet.save()` ran twice for one submit, and because
/// `addExpense` minted an id per CALL, the second run could not converge on
/// the row the first had made.
///
/// The sheet's own guard is a view detail and not reachable from here. What is
/// testable is the property that actually protects the data: a create named by
/// an explicit id is idempotent, however many times it runs.
///
/// `LocalExpense.clientUUID` is `@Attribute(.unique)`, so SwiftData already
/// keeps a same-id insert down to one ROW. It does that by replacing the row
/// with the newly built object, which drops every field the create path does
/// not set: the trip link, the split, the payer, the receipt, the Finance
/// visibility flag, and the original `createdAt`. On a trip expense that is
/// most of the row. So the count assertions below hold either way, and the
/// tests that actually discriminate are the ones about what SURVIVES.
@MainActor
final class ExpenseCreateIdempotencyTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: ExpenseService!

    override func setUp() {
        super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = ExpenseService(store: store)
    }

    override func tearDown() {
        service = nil
        store = nil
        super.tearDown()
    }

    private func rows() throws -> [LocalExpense] {
        try store.context.fetch(FetchDescriptor<LocalExpense>())
    }

    @discardableResult
    private func add(
        id: String?,
        merchant: String = "City tax",
        amount: Double = 16,
        category: ExpenseCategory = .billsAndUtilities
    ) throws -> LocalExpense {
        try service.addExpense(
            date: Date(timeIntervalSince1970: 1_757_462_400),
            category: category,
            merchant: merchant,
            expenseDescription: nil,
            originalAmount: amount,
            originalCurrency: "EUR",
            sgdAmount: amount * 1.47,
            fxRate: 1.47,
            paymentMethod: nil,
            source: .manual,
            clientUUID: id
        )
    }

    // MARK: - The reported defect

    /// The city tax case: one draft submitted twice must not leave two rows.
    func testTwoCreatesOfOneDraftLeaveOneRow() throws {
        let id = UUID().uuidString.lowercased()
        try add(id: id)
        try add(id: id)
        XCTAssertEqual(try rows().count, 1, "a repeated create of one draft is a retry, not a second expense")
    }

    /// The surviving row is the one the user last submitted, not a stale first
    /// attempt: a retry usually exists because something about the first go
    /// needed changing.
    func testTheSecondCreateWins() throws {
        let id = UUID().uuidString.lowercased()
        try add(id: id, merchant: "City tax", amount: 16)
        try add(id: id, merchant: "City tax (2 guests)", amount: 32, category: .travel)

        let all = try rows()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.merchant, "City tax (2 guests)")
        XCTAssertEqual(all.first?.originalAmount, 32)
        XCTAssertEqual(all.first?.sgdAmount ?? 0, 32 * 1.47, accuracy: 0.0001)
        XCTAssertEqual(all.first?.category, ExpenseCategory.travel.rawValue)
    }

    /// `createdAt` belongs to the moment the user made the expense, so a retry
    /// keeps the first attempt's stamp. Finance sorts and groups on `date`, but
    /// `createdAt` is what the duplicate hunt in #514 read to pair the rows.
    func testARetryKeepsTheFirstCreatedAt() throws {
        let id = UUID().uuidString.lowercased()
        let first = try add(id: id)
        let stamp = first.createdAt
        try add(id: id, amount: 20)
        XCTAssertEqual(try rows().first?.createdAt, stamp)
    }

    /// The retry rewrites the fields the create path owns and leaves every
    /// other field standing. This is the assertion that fails if the explicit
    /// update is removed and SwiftData's unique-collision replacement is left
    /// to do the job: it rebuilds the row from a fresh object, so a trip
    /// expense loses its trip, its split, its payer and its receipt.
    func testARetryLeavesTheFieldsTheCreatePathDoesNotOwn() throws {
        let id = UUID().uuidString.lowercased()
        let trip = UUID()
        let papa = UUID()

        let first = try add(id: id)
        first.tripUUID = trip
        first.paidByPersonUUID = papa
        first.splits = [ExpenseSplitEntry(person: nil, shares: 1),
                        ExpenseSplitEntry(person: papa, shares: 1)]
        first.hiddenFromFinance = true
        first.receiptImagePath = "receipts/city-tax.jpg"
        try store.context.save()

        try add(id: id, amount: 20)

        let all = try rows()
        XCTAssertEqual(all.count, 1)
        let row = try XCTUnwrap(all.first)
        XCTAssertEqual(row.originalAmount, 20, "the retry's own fields still win")
        XCTAssertEqual(row.tripUUID, trip, "a retry must not unlink the expense from its trip")
        XCTAssertEqual(row.paidByPersonUUID, papa)
        XCTAssertEqual(row.splits.count, 2, "the settle-up split must survive a retry")
        XCTAssertTrue(row.hiddenFromFinance)
        XCTAssertEqual(row.receiptImagePath, "receipts/city-tax.jpg")
    }

    /// The row keeps its identity, so anything already pointing at it (a
    /// sync record, a trip's splits, an open editor) still resolves.
    func testTheRowKeepsItsIdentity() throws {
        let id = UUID().uuidString.lowercased()
        try add(id: id)
        try add(id: id, amount: 20)
        XCTAssertEqual(try rows().first?.clientUUID, id)
    }

    // MARK: - What must not change

    /// Insert-only behaviour for callers that pass no id. The statement
    /// importer and the recurring materialiser both add rows that are
    /// legitimately identical to rows already stored (#208), and neither may
    /// start collapsing them.
    func testCreatesWithoutAnIdStillEachInsert() throws {
        try add(id: nil)
        try add(id: nil)
        XCTAssertEqual(try rows().count, 2)
    }

    /// Two genuinely different expenses added back to back stay two rows.
    func testTwoDifferentDraftsStayTwoRows() throws {
        try add(id: UUID().uuidString.lowercased(), merchant: "City tax", amount: 16)
        try add(id: UUID().uuidString.lowercased(), merchant: "City tax", amount: 16)
        XCTAssertEqual(try rows().count, 2, "distinct drafts are distinct expenses even when they look alike")
    }

    /// The amount guard still rejects, and rejects BEFORE touching the row an
    /// id names: a retry carrying a bad amount must not corrupt the good row.
    func testAZeroAmountRetryLeavesTheStoredRowAlone() throws {
        let id = UUID().uuidString.lowercased()
        try add(id: id, amount: 16)
        XCTAssertThrowsError(try add(id: id, amount: 0))
        let all = try rows()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.originalAmount, 16)
    }
}
