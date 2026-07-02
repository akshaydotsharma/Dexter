import XCTest
import SwiftData
@testable import PersonalDashboard

/// Count-reconciliation dedup for statement import (#208).
///
/// Statement rows carry no per-line reference, so two genuine same-day /
/// same-amount charges at one merchant (e.g. two coffees) are structurally
/// identical. The old boolean `ExpenseDedupe.exists` skipped every line after
/// the first and under-counted real spend. These tests pin the new behaviour:
/// for each structural class the importer inserts `max(0, N - M)` rows, where N
/// is what the statement asserts and M is what is already stored.
///
/// Runs fully offline: every line is SGD, which `FXService` short-circuits to a
/// 1.0 rate with no network call. Each test uses an isolated in-memory store so
/// nothing touches the on-disk singleton.
@MainActor
final class StatementDedupeReconciliationTests: XCTestCase {

    private var store: SwiftDataStore!
    private var importer: StatementImporter!

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        importer = StatementImporter(anthropic: AnthropicClient(), store: store)
    }

    override func tearDown() async throws {
        store = nil
        importer = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func line(
        _ merchant: String,
        _ amount: Double?,
        day: String = "2026-05-01",
        type: ExtractedStatementLine.LineType = .purchase,
        currency: String = "SGD"
    ) -> ExtractedStatementLine {
        ExtractedStatementLine(
            merchant: merchant,
            date: day,
            amount: amount,
            currency: currency,
            type: type,
            category: "food_and_dining"
        )
    }

    private func storedCount() throws -> Int {
        try store.context.fetchCount(FetchDescriptor<LocalExpense>())
    }

    /// Seed a stored expense directly (models a row created by another path —
    /// receipt / email / manual). Uses the same date normalisation the importer
    /// uses so the structural keys line up.
    @discardableResult
    private func seed(
        merchant: String,
        amount: Double,
        day: String = "2026-05-01",
        source: ExpenseSource,
        isRefund: Bool = false
    ) throws -> LocalExpense {
        let date = StatementImporter.parseDate(day) ?? Date()
        return try ExpenseService(store: store).addExpense(
            date: date,
            category: .other,
            merchant: merchant,
            expenseDescription: nil,
            originalAmount: amount,
            originalCurrency: "SGD",
            sgdAmount: amount,
            fxRate: 1.0,
            paymentMethod: nil,
            source: source,
            isRefund: isRefund
        )
    }

    // MARK: - (a) Two identical lines both import

    func test_twoIdenticalLines_bothImport() async throws {
        let result = await importer.insert(
            lines: [line("Kult Yard", 6.5), line("Kult Yard", 6.5)],
            possiblyTruncated: false
        )

        XCTAssertEqual(result.imported, 2, "both same-day coffees must import (N=2, M=0)")
        XCTAssertEqual(result.skippedDuplicates, 0)
        XCTAssertEqual(try storedCount(), 2)
        XCTAssertEqual(result.totalParsed, 2)
    }

    // MARK: - (b) Re-import of the same statement inserts zero

    func test_reimportSameStatement_insertsZero() async throws {
        let lines = [line("Kult Yard", 6.5), line("Kult Yard", 6.5)]

        let first = await importer.insert(lines: lines, possiblyTruncated: false)
        XCTAssertEqual(first.imported, 2)

        let second = await importer.insert(lines: lines, possiblyTruncated: false)
        XCTAssertEqual(second.imported, 0, "clean re-import is idempotent (N=2, M=2)")
        XCTAssertEqual(second.skippedDuplicates, 2)
        XCTAssertEqual(try storedCount(), 2, "no new rows on re-import")
    }

    // MARK: - (c) Truncated first import self-heals

    func test_truncatedFirstImport_thenFull_insertsDeficit() async throws {
        // First import landed only 1 of 2 (truncation).
        let partial = await importer.insert(lines: [line("Kult Yard", 6.5)], possiblyTruncated: false)
        XCTAssertEqual(partial.imported, 1)

        // Re-import the full statement (2 lines): exactly the missing one lands.
        let full = await importer.insert(
            lines: [line("Kult Yard", 6.5), line("Kult Yard", 6.5)],
            possiblyTruncated: false
        )
        XCTAssertEqual(full.imported, 1, "self-heals the missing line (N=2, M=1)")
        XCTAssertEqual(full.skippedDuplicates, 1)
        XCTAssertEqual(try storedCount(), 2, "total reaches the true 2")
    }

    // MARK: - (d) Receipt already logged for one visit is absorbed

    func test_receiptOverlap_absorbsOneAndImportsRest() async throws {
        // A receipt for one of the two visits was already logged (non-pdf source).
        try seed(merchant: "Kult Yard", amount: 6.5, source: .receipt)

        let result = await importer.insert(
            lines: [line("Kult Yard", 6.5), line("Kult Yard", 6.5)],
            possiblyTruncated: false
        )
        XCTAssertEqual(result.imported, 1, "statement tops up to the true count (N=2, M=1)")
        XCTAssertEqual(result.skippedDuplicates, 1)
        XCTAssertEqual(try storedCount(), 2, "receipt + one statement row = the true 2")
    }

    // MARK: - (e) Refund reconciles in its own direction class

    func test_sameDaySameAmount_purchaseAndRefund_bothImport() async throws {
        let result = await importer.insert(
            lines: [
                line("Zara", 50, type: .purchase),
                line("Zara", 50, type: .refund)
            ],
            possiblyTruncated: false
        )
        // Direction is part of the structural class, so purchase and refund are
        // different classes: each has N=1, M=0 → both import.
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.refunds, 1)
        XCTAssertEqual(result.skippedDuplicates, 0)
        XCTAssertEqual(try storedCount(), 2)
    }

    // MARK: - Bucket invariant with a mixed statement

    func test_mixedStatement_bucketsReconcile() async throws {
        let result = await importer.insert(
            lines: [
                line("Kult Yard", 6.5),                 // import
                line("Kult Yard", 6.5),                 // import (same class, N=2 M=0)
                line("Autopay", 200, type: .payment),   // ignored (never imported)
                line("Zara", 50, type: .refund),        // import (refund class)
                line("Broken", nil)                     // failed (no amount)
            ],
            possiblyTruncated: false
        )

        XCTAssertEqual(result.imported, 3)
        XCTAssertEqual(result.refunds, 1)
        XCTAssertEqual(result.ignoredNonSpend, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.skippedDuplicates, 0)
        // The core accounting invariant must always hold.
        XCTAssertEqual(
            result.imported + result.skippedDuplicates + result.ignoredNonSpend + result.failed,
            result.totalParsed
        )
        XCTAssertEqual(result.totalParsed, 5)
    }

    // MARK: - existingCount helper counts multiplicity, not existence

    func test_existingCount_reflectsMultiplicity() async throws {
        try seed(merchant: "Kult Yard", amount: 6.5, source: .receipt)
        try seed(merchant: "Kult Yard", amount: 6.5, source: .pdf)
        try seed(merchant: "Kult Yard", amount: 6.5, day: "2026-05-02", source: .pdf) // different day

        let proposed = ExpenseDedupe.Proposed(
            merchant: "Kult Yard",
            date: Calendar(identifier: .gregorian).startOfDay(for: StatementImporter.parseDate("2026-05-01")!),
            originalAmount: 6.5,
            originalCurrency: "SGD",
            sourceReference: "",
            isRefund: false
        )
        let count = ExpenseDedupe.existingCount(matching: proposed, context: store.context)
        XCTAssertEqual(count, 2, "counts both same-day rows, ignores the different day")
    }
}
