import XCTest
@testable import DexterMac

/// The "who pays whom" solver behind the trip expense report (#528).
///
/// This is the only new math in the report — every other figure is
/// `TripSettlement`'s — so it carries the burden of proof. Two properties are
/// what a reader actually relies on: every balance ends at zero, and nobody is
/// asked to make more payments than the group needs.
final class TripTransferSolverTests: XCTestCase {

    private let priya = UUID()
    private let sam = UUID()
    private let ravi = UUID()

    // MARK: - Helpers

    /// Applies a plan to the balances and returns what is left.
    private func settle(
        _ balances: [SplitPartyID: Double],
        with plan: [TripTransferSolver.Transfer]
    ) -> [SplitPartyID: Double] {
        var remaining = balances
        for transfer in plan {
            // A debtor's negative balance moves toward zero as they pay out.
            remaining[transfer.from, default: 0] += transfer.amount
            remaining[transfer.to, default: 0] -= transfer.amount
        }
        return remaining
    }

    private func assertCleared(
        _ balances: [SplitPartyID: Double],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let plan = TripTransferSolver.transfers(balances: balances)
        let remaining = settle(balances, with: plan)
        for (party, value) in remaining {
            XCTAssertEqual(
                value, 0, accuracy: 0.01,
                "\(party) was left holding \(value)",
                file: file, line: line
            )
        }
        let active = balances.filter { abs($0.value) > TripTransferSolver.epsilon }.count
        XCTAssertLessThanOrEqual(
            plan.count, max(active - 1, 0),
            "A group of \(active) unsettled parties needs at most \(max(active - 1, 0)) transfers",
            file: file, line: line
        )
    }

    // MARK: - Clearing

    func testNobodyOwesAnythingProducesNoTransfers() {
        XCTAssertTrue(TripTransferSolver.transfers(balances: [:]).isEmpty)
        XCTAssertTrue(TripTransferSolver.transfers(balances: [.me: 0, .person(priya): 0]).isEmpty)
    }

    /// A balance under half a cent is settled, the same threshold
    /// `TripSettlement` drops a party at. Otherwise the report would print a
    /// payment of "SGD 0.00".
    func testSubCentBalancesAreTreatedAsSettled() {
        let plan = TripTransferSolver.transfers(balances: [.me: 0.004, .person(priya): -0.004])
        XCTAssertTrue(plan.isEmpty)
    }

    func testOneDebtorAndOneCreditorIsASinglePayment() {
        let balances: [SplitPartyID: Double] = [.me: -140, .person(priya): 140]
        let plan = TripTransferSolver.transfers(balances: balances)

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.from, .me)
        XCTAssertEqual(plan.first?.to, .person(priya))
        XCTAssertEqual(plan.first?.amount ?? 0, 140, accuracy: 0.001)
        assertCleared(balances)
    }

    /// Two creditors is the case the obvious reading gets wrong: "everyone pays
    /// the person who is owed" has no single answer here.
    func testTwoCreditorsAndOneDebtorClears() {
        assertCleared([
            .me: -300,
            .person(priya): 180,
            .person(sam): 120
        ])
    }

    func testFourWaySpreadClears() {
        assertCleared([
            .me: 220.75,
            .person(priya): -95.50,
            .person(sam): -180.25,
            .person(ravi): 55.00
        ])
    }

    /// Uneven splits leave cent-level residue on every party. The plan must
    /// still land them all on zero.
    func testCentResidueStillClears() {
        assertCleared([
            .me: 33.34,
            .person(priya): -16.67,
            .person(sam): -16.67
        ])
    }

    // MARK: - Shape

    func testATransferNeverRunsBetweenTwoDebtorsOrTwoCreditors() {
        let balances: [SplitPartyID: Double] = [
            .me: -80,
            .person(priya): -40,
            .person(sam): 90,
            .person(ravi): 30
        ]
        let plan = TripTransferSolver.transfers(balances: balances)

        for transfer in plan {
            XCTAssertLessThan(balances[transfer.from] ?? 0, 0, "Only a debtor pays")
            XCTAssertGreaterThan(balances[transfer.to] ?? 0, 0, "Only a creditor is paid")
            XCTAssertGreaterThan(transfer.amount, 0)
        }
        assertCleared(balances)
    }

    /// The report is exported more than once. The same trip must produce the
    /// same plan, or two copies in the same group chat disagree.
    func testThePlanIsDeterministicWhenAmountsTie() {
        let balances: [SplitPartyID: Double] = [
            .me: -100,
            .person(priya): 50,
            .person(sam): 50
        ]
        let first = TripTransferSolver.transfers(balances: balances)
        for _ in 0..<8 {
            XCTAssertEqual(TripTransferSolver.transfers(balances: balances), first)
        }
    }

    /// The bound that makes the plan worth printing: N parties, at most N - 1
    /// payments, no matter how the money is spread.
    func testAtMostPartiesMinusOneTransfersAcrossManyShapes() {
        let shapes: [[Double]] = [
            [-10, 10],
            [-10, 4, 6],
            [-6, -4, 10],
            [12, -3, -3, -3, -3],
            [100.01, -50.00, -25.00, -25.01],
            [-1, -2, -3, 6]
        ]
        let parties: [SplitPartyID] = [.me, .person(priya), .person(sam), .person(ravi), .person(UUID())]

        for shape in shapes {
            var balances: [SplitPartyID: Double] = [:]
            for (index, value) in shape.enumerated() { balances[parties[index]] = value }
            assertCleared(balances)
        }
    }
}
