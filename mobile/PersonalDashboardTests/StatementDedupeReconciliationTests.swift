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
        currency: String = "SGD",
        descriptor: String? = nil
    ) -> ExtractedStatementLine {
        ExtractedStatementLine(
            merchant: merchant,
            date: day,
            amount: amount,
            currency: currency,
            type: type,
            category: "food_and_dining",
            descriptor: descriptor
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

    // MARK: - (f) Merchant paraphrase across runs — same descriptor dedups (#208)

    func test_merchantParaphrase_sameDescriptor_reimportInsertsZero() async throws {
        // The exact bug: SHOPEE lines stored as merchant "SHOPEE SINGAPORE" on
        // the first import and "SHOPEE SINGAPORE Shopee" on the re-import (the
        // model paraphrases the merchant), but the VERBATIM descriptor off the
        // statement text is identical across both runs.
        let verbatim = "SHOPEE SINGAPORE Shopee SINGAPORE"

        let first = await importer.insert(
            lines: [line("SHOPEE SINGAPORE", 10.27, descriptor: verbatim)],
            possiblyTruncated: false
        )
        XCTAssertEqual(first.imported, 1)

        // Re-import: merchant paraphrased differently, SAME verbatim descriptor.
        let second = await importer.insert(
            lines: [line("SHOPEE SINGAPORE Shopee", 10.27, descriptor: verbatim)],
            possiblyTruncated: false
        )
        XCTAssertEqual(second.imported, 0, "same verbatim descriptor must dedup despite paraphrased merchant")
        XCTAssertEqual(second.skippedDuplicates, 1)
        XCTAssertEqual(try storedCount(), 1, "no duplicate row on re-import")
    }

    // MARK: - (g) Legacy row (empty descriptor) is matched, not re-added

    func test_legacyRowNoDescriptor_matchedByBucket_insertsZero() async throws {
        // A pre-fix row (or a receipt / manual row) has an EMPTY dedupeDescriptor.
        // A statement re-import that now carries a verbatim descriptor must still
        // recognise it via the legacy bucket fallback (amount + date + currency)
        // so existing data is never re-duplicated.
        try seed(merchant: "SHOPEE SINGAPORE", amount: 5.97, source: .receipt)

        let result = await importer.insert(
            lines: [line("Shopee", 5.97, descriptor: "SHOPEE SINGAPORE Shopee SINGAPORE")],
            possiblyTruncated: false
        )
        XCTAssertEqual(result.imported, 0, "legacy empty-descriptor row matched on amount+date+currency")
        XCTAssertEqual(result.skippedDuplicates, 1)
        XCTAssertEqual(try storedCount(), 1, "legacy row is not re-duplicated")
    }

    // MARK: - (h) Same amount + day, different descriptors — both import

    func test_sameAmountDay_differentDescriptors_bothImport_thenReimportZero() async throws {
        let lines = [
            line("Cafe A", 8.0, descriptor: "CAFE ALPHA SINGAPORE SG"),
            line("Cafe B", 8.0, descriptor: "BETA COFFEE ROASTERS SG")
        ]

        let first = await importer.insert(lines: lines, possiblyTruncated: false)
        XCTAssertEqual(first.imported, 2, "distinct descriptors are distinct transactions")
        XCTAssertEqual(first.skippedDuplicates, 0)
        XCTAssertEqual(try storedCount(), 2)

        let second = await importer.insert(lines: lines, possiblyTruncated: false)
        XCTAssertEqual(second.imported, 0, "re-import is idempotent")
        XCTAssertEqual(second.skippedDuplicates, 2)
        XCTAssertEqual(try storedCount(), 2)
    }

    // MARK: - (i) Three identical descriptors — 3 then 0

    func test_tripleIdenticalDescriptor_firstThreeThenZero() async throws {
        let verbatim = "KULT YARD @ TIONG BAHRU SG"
        let lines = [
            line("Kult Yard", 16.5, descriptor: verbatim),
            line("Kult Yard", 16.5, descriptor: verbatim),
            line("Kult Yard", 16.5, descriptor: verbatim)
        ]

        let first = await importer.insert(lines: lines, possiblyTruncated: false)
        XCTAssertEqual(first.imported, 3, "three identical lines all import on first pass")
        XCTAssertEqual(try storedCount(), 3)

        let second = await importer.insert(lines: lines, possiblyTruncated: false)
        XCTAssertEqual(second.imported, 0, "3 match 3 → nothing re-adds")
        XCTAssertEqual(second.skippedDuplicates, 3)
        XCTAssertEqual(try storedCount(), 3)
    }

    // MARK: - (j) Bank deposit is counted + totalled, never imported (#243)

    func test_bankDeposit_countedAndTotalled_notImported() async throws {
        let result = await importer.insert(
            lines: [
                line("Salary", 5000, type: .deposit),
                line("Kopitiam", 4.5, type: .purchase)
            ],
            possiblyTruncated: false
        )

        XCTAssertEqual(result.imported, 1, "only the withdrawal imports as spend")
        XCTAssertEqual(result.deposits, 1, "the deposit is counted")
        XCTAssertEqual(result.depositsTotalSGD, 5000, accuracy: 0.001, "the deposit is summed in SGD")
        XCTAssertEqual(result.ignoredNonSpend, 0, "a deposit is NOT a card payment")
        XCTAssertEqual(result.refunds, 0, "a deposit is NOT a refund")
        // The deposit must never become a LocalExpense (not as spend, not as a credit).
        XCTAssertEqual(try storedCount(), 1, "only the withdrawal is stored")
    }

    // MARK: - (k) A money-out "collection" (mislabel trap) imports as spend

    func test_moneyOutCollection_importsAsSpend() async throws {
        // A DBS "FAST Collection" whose balance dropped is money OUT. The
        // extractor is instructed to classify it by column/balance as a
        // `purchase`, so the importer must treat it as ordinary spend.
        let result = await importer.insert(
            lines: [line("FAST Collection", 120.0, type: .purchase, descriptor: "ADVICE FAST COLLECTION SG")],
            possiblyTruncated: false
        )

        XCTAssertEqual(result.imported, 1, "a money-out collection imports as spend")
        XCTAssertEqual(result.deposits, 0)
        XCTAssertEqual(result.ignoredNonSpend, 0)
        XCTAssertEqual(try storedCount(), 1)
    }

    // MARK: - (l) summaryLine reports skipped deposits with a total

    func test_summaryLine_includesDepositClause() async throws {
        let result = await importer.insert(
            lines: [
                line("Coffee", 3.5, type: .purchase),
                line("Transfer in", 16559.11, type: .deposit)
            ],
            possiblyTruncated: false
        )

        XCTAssertEqual(result.deposits, 1)
        let summary = result.summaryLine
        XCTAssertTrue(summary.contains("Skipped 1 deposit (SGD 16,559.11)"), "summary must state the deposit count and SGD total, got: \(summary)")
        XCTAssertTrue(summary.contains("income isn't tracked yet"), "summary must explain deposits aren't tracked, got: \(summary)")
        XCTAssertFalse(summary.contains("—"), "no em dash allowed in user-facing summary, got: \(summary)")
        XCTAssertTrue(summary.contains("Imported 1"))
    }

    // MARK: - (m) totalParsed invariant now includes deposits

    func test_totalParsed_includesDeposits() async throws {
        let result = await importer.insert(
            lines: [
                line("Kopitiam", 4.5, type: .purchase),   // imported
                line("Salary", 5000, type: .deposit),      // deposit
                line("Bonus", 1000, type: .deposit),       // deposit
                line("Autopay", 200, type: .payment),      // ignoredNonSpend
                line("Broken", nil)                        // failed (no amount)
            ],
            possiblyTruncated: false
        )

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.deposits, 2)
        XCTAssertEqual(result.ignoredNonSpend, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.skippedDuplicates, 0)
        XCTAssertEqual(
            result.imported + result.skippedDuplicates + result.ignoredNonSpend + result.deposits + result.failed,
            result.totalParsed,
            "the accounting invariant now includes deposits"
        )
        XCTAssertEqual(result.totalParsed, 5)
    }

    // MARK: - (n) CC bill payment on a bank statement is ignored, not spend (#243)

    func test_bankCreditCardBillPayment_ignoredNotSpend() async throws {
        // "Advice Bill Payment / CCC - 5425503303732696 : I-BANK" settles a
        // credit card → tagged `payment` by the extractor → must be ignored, not
        // imported as spend (it double-counts the card's own purchases).
        let result = await importer.insert(
            lines: [line("Credit card bill", 1548.46, type: .payment, descriptor: "ADVICE BILL PAYMENT / CCC - 5425503303732696 : I-BANK")],
            possiblyTruncated: false
        )

        XCTAssertEqual(result.imported, 0, "a credit-card bill payment is never imported")
        XCTAssertEqual(result.ignoredNonSpend, 1, "it is counted as an ignored payment")
        XCTAssertEqual(result.refunds, 0)
        XCTAssertEqual(try storedCount(), 0, "nothing stored for a card settlement")
    }

    // MARK: - (o) A normal (non-card) bill like tax still imports as spend

    func test_bankTaxBill_importsAsSpend() async throws {
        // "GIRO ... IRAS" is tax, a real expense — the extractor keeps it a
        // `purchase`, so it must import as ordinary spend.
        let result = await importer.insert(
            lines: [line("IRAS", 871.89, type: .purchase, descriptor: "GIRO PAYMENT IRAS TAX")],
            possiblyTruncated: false
        )

        XCTAssertEqual(result.imported, 1, "a tax bill is real spend and imports")
        XCTAssertEqual(result.ignoredNonSpend, 0, "a tax bill is NOT a card settlement")
        XCTAssertEqual(try storedCount(), 1)
    }

    // MARK: - (p) Incoming peer transfer imports as a "+" credit

    func test_incomingPeerTransfer_importsAsCredit() async throws {
        // "INCOMING PAYNOW ... FROM: <person>" is money received from a person —
        // the extractor tags it `refund` so the importer stores it as a "+"
        // credit (isRefund: true) that nets against spend.
        let result = await importer.insert(
            lines: [line("Parul Katyal", 1000.0, type: .refund, descriptor: "FUNDS TRANSFER IB:KATYAL PARUL")],
            possiblyTruncated: false
        )

        XCTAssertEqual(result.imported, 1, "received peer money is recorded, not dropped")
        XCTAssertEqual(result.refunds, 1, "it is imported as a + credit")
        XCTAssertEqual(result.ignoredNonSpend, 0)
        // Confirm the stored row is actually a refund/credit.
        let stored = try store.context.fetch(FetchDescriptor<LocalExpense>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(stored[0].isRefund, "the received transfer is stored as a + credit")
    }

    // MARK: - (q) Salary stays a skipped deposit

    func test_salary_staysSkippedDeposit() async throws {
        // "DEC PAY CWV1L" is payroll — the extractor keeps it `deposit`, so it is
        // counted and reported but never imported (it would swamp the spend view).
        let result = await importer.insert(
            lines: [line("Salary", 14840.0, type: .deposit, descriptor: "DEC PAY CWV1L")],
            possiblyTruncated: false
        )

        XCTAssertEqual(result.imported, 0, "salary is never imported")
        XCTAssertEqual(result.deposits, 1, "salary is counted as a deposit")
        XCTAssertEqual(result.depositsTotalSGD, 14840.0, accuracy: 0.001)
        XCTAssertEqual(result.refunds, 0, "salary is NOT a credit")
        XCTAssertEqual(try storedCount(), 0)
    }

    // MARK: - (r) DBS-shaped mix: summary wording uses "credits", salary skipped, card bill ignored

    func test_dbsMixedStatement_summaryWording() async throws {
        var lines: [ExtractedStatementLine] = []
        // 3 ordinary withdrawals (spend).
        lines.append(line("Kopitiam", 4.5, type: .purchase, descriptor: "KOPITIAM 1"))
        lines.append(line("Grab", 12.0, type: .purchase, descriptor: "GRAB RIDE 2"))
        lines.append(line("IRAS", 871.89, type: .purchase, descriptor: "GIRO IRAS TAX"))
        // 1 credit-card bill payment (ignored).
        lines.append(line("CC bill", 1548.46, type: .payment, descriptor: "ADVICE BILL PAYMENT / CCC - 5425503303732696 : I-BANK"))
        // 2 incoming peer transfers (+ credits).
        lines.append(line("Parul", 1000.0, type: .refund, descriptor: "FUNDS TRANSFER IB:KATYAL PARUL"))
        lines.append(line("Naomi", 5.0, type: .refund, descriptor: "INCOMING PAYNOW FROM: NAOMI"))
        // 1 salary (skipped deposit).
        lines.append(line("Salary", 14840.0, type: .deposit, descriptor: "DEC PAY CWV1L"))

        let result = await importer.insert(lines: lines, possiblyTruncated: false)

        XCTAssertEqual(result.imported, 5, "3 spend + 2 credits import")
        XCTAssertEqual(result.refunds, 2, "the two peer transfers are credits")
        XCTAssertEqual(result.ignoredNonSpend, 1, "the card bill is ignored")
        XCTAssertEqual(result.deposits, 1, "salary is a skipped deposit")
        XCTAssertEqual(result.depositsTotalSGD, 14840.0, accuracy: 0.001)

        let summary = result.summaryLine
        XCTAssertTrue(summary.contains("Imported 5 (including 2 credits)"), "summary must say credits, not refunds, got: \(summary)")
        XCTAssertTrue(summary.contains("Ignored 1 payment"), "the card bill shows as an ignored payment, got: \(summary)")
        XCTAssertTrue(summary.contains("Skipped 1 deposit (SGD 14,840.00), income isn't tracked yet"), "salary reported as a skipped deposit, got: \(summary)")
        XCTAssertFalse(summary.contains("refund"), "no 'refund' wording, got: \(summary)")
        XCTAssertFalse(summary.contains("—"), "no em dash allowed, got: \(summary)")
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
