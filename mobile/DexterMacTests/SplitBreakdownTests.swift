import XCTest
@testable import DexterMac

/// Multiple payers and exact per-person amounts on a trip expense (#540).
///
/// Both live inside the `splitsData` JSON rather than in new SwiftData
/// properties, so the first thing this has to prove is that nothing already
/// stored changed meaning. After that: that the two new readings convert to
/// SGD correctly, that they net to zero across the group, and that the cent
/// arithmetic behind "spread the rest" actually lands on the total.
final class SplitBreakdownTests: XCTestCase {

    private let priya = UUID()
    private let sam = UUID()

    /// EUR expense, so a conversion that quietly used the wrong basis shows up
    /// as a wrong number rather than as the same number twice.
    private let eurRate = 1.5

    private func expense(
        amount: Double,
        currency: String = "EUR",
        paidBy: UUID? = nil,
        splits: [ExpenseSplitEntry] = [],
        isRefund: Bool = false
    ) -> LocalExpense {
        let rate = currency == "EUR" ? eurRate : 1.0
        let row = LocalExpense(
            clientUUID: UUID().uuidString.lowercased(),
            date: Date(),
            category: "food_and_dining",
            originalAmount: amount,
            originalCurrency: currency,
            sgdAmount: amount * rate,
            fxRate: rate,
            source: "manual",
            isRefund: isRefund,
            paidByPersonUUID: paidBy
        )
        row.splits = splits
        return row
    }

    private func owed(_ row: LocalExpense, _ party: SplitPartyID) -> Double {
        row.owedBreakdown(basis: row.signedSGD)
            .filter { $0.party == party }
            .reduce(0) { $0 + $1.amount }
    }

    private func paid(_ row: LocalExpense, _ party: SplitPartyID) -> Double {
        row.paidBreakdown(basis: row.signedSGD)
            .filter { $0.party == party }
            .reduce(0) { $0 + $1.amount }
    }

    // MARK: - Nothing already stored changed meaning

    /// The regression guard. A payload written before #540 carries neither new
    /// key, so it has to decode and settle exactly as it always did.
    func testLegacyPayloadDecodesWithNoAmountsAndSettlesUnchanged() throws {
        let json = #"[{"personUUID":null,"shares":1},{"personUUID":"\#(priya.uuidString.lowercased())","shares":2}]"#
        let entries = try JSONDecoder().decode([ExpenseSplitEntry].self, from: Data(json.utf8))

        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].owedAmount)
        XCTAssertNil(entries[0].paidAmount)

        let row = expense(amount: 90, paidBy: priya, splits: entries)
        XCTAssertFalse(row.hasMultiplePayers)
        XCTAssertFalse(row.splitsByExactAmount)
        XCTAssertEqual(row.payerParties, [.person(priya)])
        XCTAssertEqual(paid(row, .person(priya)), 135, accuracy: 0.0001)
        XCTAssertEqual(owed(row, .me), 45, accuracy: 0.0001, "1 of 3 shares of EUR 90 at 1.5")
        XCTAssertEqual(owed(row, .person(priya)), 90, accuracy: 0.0001)
        XCTAssertEqual(row.myShareSGD, 45, accuracy: 0.0001)
        XCTAssertEqual(row.myShareOriginal, 30, accuracy: 0.0001)
    }

    /// An unsplit bill someone else fronted is still the user's cost in full
    /// (#504). The breakdowns are now the only place that rule lives.
    func testUnsplitExpensePaidByAnotherPartyIsOwedEntirelyByTheUser() {
        let row = expense(amount: 100, paidBy: priya)
        XCTAssertEqual(paid(row, .person(priya)), 150, accuracy: 0.0001)
        XCTAssertEqual(owed(row, .me), 150, accuracy: 0.0001)
        XCTAssertEqual(row.myShareSGD, 150, accuracy: 0.0001)
        XCTAssertFalse(row.isGroupSplit)
    }

    // MARK: - Exact amounts

    func testExactAmountsConvertByTheRowsFXRateAndSumToTheSGDTotal() {
        let row = expense(amount: 100, splits: [
            ExpenseSplitEntry(person: nil, shares: 1, owedAmount: 61.40),
            ExpenseSplitEntry(person: priya, shares: 1, owedAmount: 38.60)
        ])
        XCTAssertTrue(row.splitsByExactAmount)
        XCTAssertEqual(owed(row, .me), 92.10, accuracy: 0.0001)
        XCTAssertEqual(owed(row, .person(priya)), 57.90, accuracy: 0.0001)

        let total = row.owedBreakdown(basis: row.signedSGD).reduce(0) { $0 + $1.amount }
        XCTAssertEqual(total, row.sgdAmount, accuracy: 0.0001)
        XCTAssertEqual(row.myShareSGD, 92.10, accuracy: 0.0001, "Personal totals read the exact amount, not the weight")
        XCTAssertEqual(row.myShareOriginal, 61.40, accuracy: 0.0001)
    }

    /// Exact amounts are stored as positive magnitudes; the direction has to
    /// come from the basis, or a refund would count as a spend.
    func testExactAmountsOnARefundStayNegative() {
        let row = expense(
            amount: 50,
            splits: [
                ExpenseSplitEntry(person: nil, shares: 1, owedAmount: 20),
                ExpenseSplitEntry(person: priya, shares: 1, owedAmount: 30)
            ],
            isRefund: true
        )
        XCTAssertEqual(owed(row, .me), -30, accuracy: 0.0001)
        XCTAssertEqual(row.myShareSGD, -30, accuracy: 0.0001)
    }

    /// A share weight next to an exact amount is the shape a half-migrated
    /// payload would take. The amount has to win, or a bill would be read two
    /// different ways depending on which field was inspected.
    func testExactAmountsOutrankShareWeights() {
        let row = expense(amount: 100, splits: [
            ExpenseSplitEntry(person: nil, shares: 9, owedAmount: 25),
            ExpenseSplitEntry(person: priya, shares: 1, owedAmount: 75)
        ])
        XCTAssertEqual(owed(row, .me), 37.50, accuracy: 0.0001)
    }

    // MARK: - Multiple payers

    func testTwoPayersAreCreditedTheirOwnContributions() {
        let row = expense(amount: 400, splits: [
            ExpenseSplitEntry(person: nil, shares: 1, paidAmount: 250),
            ExpenseSplitEntry(person: priya, shares: 1, paidAmount: 150)
        ])
        XCTAssertTrue(row.hasMultiplePayers)
        XCTAssertEqual(row.payerParties, [.me, .person(priya)])
        XCTAssertEqual(paid(row, .me), 375, accuracy: 0.0001)
        XCTAssertEqual(paid(row, .person(priya)), 225, accuracy: 0.0001)

        let total = row.paidBreakdown(basis: row.signedSGD).reduce(0) { $0 + $1.amount }
        XCTAssertEqual(total, row.sgdAmount, accuracy: 0.0001)
    }

    /// The case the feature exists for: two people put money in, three people
    /// ate. Everyone's net has to come out of one pass and add to zero.
    func testMultiPayerSettlementNetsToZeroAcrossTheGroup() {
        let row = expense(amount: 300, currency: "SGD", splits: [
            ExpenseSplitEntry(person: nil, shares: 1, paidAmount: 200),
            ExpenseSplitEntry(person: priya, shares: 1, paidAmount: 100),
            ExpenseSplitEntry(person: sam, shares: 1)
        ])
        let balances = TripSettlement.compute(expenses: [row])
        let net = Dictionary(uniqueKeysWithValues: balances.map { ($0.party, $0.net) })

        XCTAssertEqual(net[.me] ?? 0, 100, accuracy: 0.0001, "Paid 200, ate 100")
        XCTAssertEqual(net[.person(priya)] ?? 0, 0, accuracy: 0.0001, "Paid 100, ate 100")
        XCTAssertEqual(net[.person(sam)] ?? 0, -100, accuracy: 0.0001, "Paid nothing, ate 100")
        XCTAssertEqual(balances.reduce(0) { $0 + $1.net }, 0, accuracy: 0.0001)
    }

    /// Someone can put money in without eating. They are owed it back in full,
    /// and they must not appear as a sharer of the bill.
    func testAPayerWithNoShareIsCreditedButIsNotASharer() {
        let row = expense(amount: 100, currency: "SGD", splits: [
            ExpenseSplitEntry(person: nil, shares: 1),
            ExpenseSplitEntry(person: priya, shares: 0, paidAmount: 60),
            ExpenseSplitEntry(person: sam, shares: 0, paidAmount: 40)
        ])
        XCTAssertTrue(row.isGroupSplit, "The user still holds a share")
        XCTAssertEqual(owed(row, .me), 100, accuracy: 0.0001)
        XCTAssertEqual(owed(row, .person(priya)), 0, accuracy: 0.0001)
        XCTAssertEqual(paid(row, .person(priya)), 60, accuracy: 0.0001)

        let roster = SplitAvatarRoster.make(
            payerParties: row.payerParties,
            splits: row.splits,
            name: { [self.priya: "Priya", self.sam: "Sam"][$0] },
            colorHex: { _ in nil }
        )
        // Asserted on identity, not on the letter: the user's initial follows
        // whatever display name is saved on the machine running the tests.
        XCTAssertEqual(roster.payers.map(\.party), [.person(priya), .person(sam)])
        XCTAssertEqual(roster.sharers.map(\.party), [.me])
    }

    /// A bill nobody split, paid into by two people, is still the user's cost
    /// in full: co-paying is not sharing.
    func testCoPaidButUnsplitBillIsNotAGroupSplit() {
        let row = expense(amount: 100, currency: "SGD", splits: [
            ExpenseSplitEntry(person: nil, shares: 0, paidAmount: 70),
            ExpenseSplitEntry(person: priya, shares: 0, paidAmount: 30)
        ])
        XCTAssertFalse(row.isGroupSplit)
        XCTAssertEqual(owed(row, .me), 100, accuracy: 0.0001)
        XCTAssertEqual(row.myShareSGD, 100, accuracy: 0.0001)
    }

    // MARK: - Cent arithmetic

    func testEvenSplitOfAnIndivisibleTotalStillSumsToIt() {
        let parts = SplitMath.evenSplit(total: 100, count: 3)
        XCTAssertEqual(parts, [33.34, 33.33, 33.33])
        XCTAssertEqual(parts.reduce(0, +), 100, accuracy: 0.0001)
    }

    /// Exact proportionality is impossible once an indivisible cent is in
    /// play, so what is asserted is where that cent lands: on the heavier
    /// weight, which is where a person doing the sum by hand would put it.
    func testWeightedSplitSumsToTheTotalAndGivesTheOddCentToTheHeavierWeight() {
        let parts = SplitMath.weightedSplit(total: 100, weights: [1, 2])
        XCTAssertEqual(parts, [33.33, 66.67])
        XCTAssertEqual(parts.reduce(0, +), 100, accuracy: 0.0001)
    }

    /// "Spread the rest" gives the remainder to the people who have not been
    /// given a figure yet. That is what the user means by it.
    func testSpreadFillsTheEmptyEntriesFirst() {
        let spread = SplitMath.spread([40, 0, 0], total: 100)
        XCTAssertEqual(spread, [40, 30, 30])
        XCTAssertEqual(spread.reduce(0, +), 100, accuracy: 0.0001)
    }

    /// With every figure already entered there is nobody to favour, so the
    /// difference spreads across all of them.
    func testSpreadWithEveryEntryFilledRebalancesAllOfThem() {
        let spread = SplitMath.spread([30, 30, 30], total: 100)
        XCTAssertEqual(spread.reduce(0, +), 100, accuracy: 0.0001)
        XCTAssertEqual(spread, [33.34, 33.33, 33.33])
    }

    /// Fixed entries that already exceed the total leave nothing to hand out.
    /// Zeroing everyone to force a fit would destroy what the user typed.
    func testSpreadLeavesAnOvershootAlone() {
        let amounts = [80.0, 90.0, 0.0]
        XCTAssertEqual(SplitMath.spread(amounts, total: 100), amounts)
    }

    func testRemainderReportsWhatIsLeftAndWhatIsOver() {
        XCTAssertEqual(SplitMath.remainder([40, 30], total: 100), 30, accuracy: 0.0001)
        XCTAssertEqual(SplitMath.remainder([70, 50], total: 100), -20, accuracy: 0.0001)
        XCTAssertTrue(SplitMath.isBalanced([33.34, 33.33, 33.33], total: 100))
    }
}
