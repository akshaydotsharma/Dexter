import XCTest
import SwiftData
@testable import PersonalDashboard

/// Renaming a person in place (#530).
///
/// Before this, the app had no rename affordance at all, so correcting a trip
/// participant's name meant removing them and adding a new person. That minted a
/// new `clientUUID`, and every join downstream of a person is by UUID: the trip's
/// `participantPersonUUIDs`, `LocalExpense.personUUID`, `paidByPersonUUID` and
/// every `ExpenseSplitEntry.personUUID`. The old splits kept pointing at a record
/// that no longer existed, so settle-up rendered the person as "Someone" and
/// their balance detached from the new name.
///
/// These tests assert the two halves that make a rename safe: identity does not
/// move, and the one denormalised copy of the name is refreshed.
@MainActor
final class PersonRenameTests: XCTestCase {

    private var store: SwiftDataStore!
    private var service: PersonService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        service = PersonService(store: store)
    }

    override func tearDownWithError() throws {
        service = nil
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func expense(
        merchant: String,
        person: LocalPerson?,
        paidBy: UUID? = nil,
        splits: [ExpenseSplitEntry] = [],
        amount: Double = 40
    ) -> LocalExpense {
        let row = LocalExpense(
            category: "food_and_dining",
            merchant: merchant,
            originalAmount: amount,
            originalCurrency: "SGD",
            sgdAmount: amount,
            fxRate: 1,
            source: "manual",
            personUUID: person?.clientUUID,
            personName: person?.name,
            paidByPersonUUID: paidBy
        )
        row.splits = splits
        store.context.insert(row)
        return row
    }

    private func fetchExpenses() throws -> [LocalExpense] {
        try store.context.fetch(FetchDescriptor<LocalExpense>())
    }

    // MARK: - Identity survives

    /// The point of the whole change. A rename must not mint a new record, so
    /// every id a trip, an expense, a payer or a split holds still resolves.
    func testRenameKeepsIdentityAndEveryJoin() throws {
        let tim = try service.findOrCreate(name: "Tim")
        let id = tim.clientUUID

        let trip = LocalTrip(name: "Italy", startDate: Date(), endDate: Date())
        trip.participantPersonUUIDs = [id]
        store.context.insert(trip)

        let split = [
            ExpenseSplitEntry(person: nil, shares: 1),
            ExpenseSplitEntry(person: id, shares: 1),
        ]
        let dinner = expense(merchant: "Trattoria", person: tim, paidBy: id, splits: split)
        try store.context.save()

        try service.rename(tim, to: "Don")

        XCTAssertEqual(tim.clientUUID, id, "A rename must not mint a new person.")
        XCTAssertEqual(tim.name, "Don")
        XCTAssertEqual(trip.participantPersonUUIDs, [id])
        XCTAssertEqual(dinner.personUUID, id)
        XCTAssertEqual(dinner.paidByPersonUUID, id)
        XCTAssertEqual(dinner.splits.compactMap(\.personID), [id])
    }

    /// The chip colour is how the user recognises a person. A rename is not a
    /// new person, so the colour must not be reassigned from the palette.
    func testRenameKeepsTheChipColour() throws {
        let person = try service.findOrCreate(name: "Tim")
        let colour = person.colorHex
        try service.rename(person, to: "Don")
        XCTAssertEqual(person.colorHex, colour)
    }

    /// Only the person's own record changes identity-wise: no second person is
    /// created behind the rename.
    func testRenameDoesNotCreateASecondPerson() throws {
        let tim = try service.findOrCreate(name: "Tim")
        try service.rename(tim, to: "Don")
        let all = try service.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Don")
    }

    // MARK: - The denormalised copy is refreshed

    /// `LocalExpense.personName` is a copy kept so a row stays self-describing
    /// after the person is DELETED. It is written once at save time, so without
    /// the backfill a renamed person's expenses keep showing the old name in the
    /// Finance badge, in the edit sheet and in an exported archive.
    func testRenameBackfillsEveryTaggedExpense() throws {
        let tim = try service.findOrCreate(name: "Tim")
        expense(merchant: "Trattoria", person: tim)
        expense(merchant: "Gelato", person: tim)
        try store.context.save()

        try service.rename(tim, to: "Don")

        let names = try fetchExpenses().map(\.personName)
        XCTAssertEqual(names.compactMap { $0 }.sorted(), ["Don", "Don"])
    }

    /// The backfill is scoped by `personUUID`. A row tagged with someone else,
    /// and a row with no person at all, must be left exactly as they were.
    func testRenameTouchesNoOtherRow() throws {
        let tim = try service.findOrCreate(name: "Tim")
        let sam = try service.findOrCreate(name: "Sam")
        expense(merchant: "Trattoria", person: tim)
        expense(merchant: "Bar", person: sam)
        expense(merchant: "Groceries", person: nil)
        try store.context.save()

        try service.rename(tim, to: "Don")

        let rows = try fetchExpenses()
        XCTAssertEqual(rows.first { $0.merchant == "Bar" }?.personName, "Sam")
        XCTAssertEqual(rows.first { $0.merchant == "Bar" }?.personUUID, sam.clientUUID)
        XCTAssertNil(rows.first { $0.merchant == "Groceries" }?.personName)
        XCTAssertEqual(rows.first { $0.merchant == "Trattoria" }?.personName, "Don")
    }

    /// A payer and a split entry carry an id and no name, so they need no
    /// backfill — and the rename must not invent one on them.
    func testRenameLeavesPayerAndSplitPayloadsAlone() throws {
        let tim = try service.findOrCreate(name: "Tim")
        let split = [ExpenseSplitEntry(person: tim.clientUUID, shares: 2)]
        let row = expense(merchant: "Hotel", person: nil, paidBy: tim.clientUUID, splits: split)
        try store.context.save()

        try service.rename(tim, to: "Don")

        XCTAssertNil(row.personName)
        XCTAssertEqual(row.paidByPersonUUID, tim.clientUUID)
        XCTAssertEqual(row.splits, split)
    }

    // MARK: - Settle-up does not move

    /// The user's actual worry, asserted against the real settle-up math: a
    /// rename changes the LABEL and nothing else. `TripSettlement` keys on
    /// `SplitPartyID.person(UUID)`, so identical balances before and after are
    /// only possible if the person's id survived.
    func testSettleUpBalancesAreIdenticalAfterARename() throws {
        let tim = try service.findOrCreate(name: "Tim")
        let sam = try service.findOrCreate(name: "Sam")
        let everyone = [
            ExpenseSplitEntry(person: nil, shares: 1),
            ExpenseSplitEntry(person: tim.clientUUID, shares: 1),
            ExpenseSplitEntry(person: sam.clientUUID, shares: 1),
        ]
        // Deliberately uneven, so every party carries a NON-ZERO balance. Three
        // equal bills settle to nothing and would assert against an empty list.
        let rows = [
            expense(merchant: "Hotel", person: nil, paidBy: tim.clientUUID, splits: everyone, amount: 300),
            expense(merchant: "Dinner", person: nil, paidBy: nil, splits: everyone, amount: 90),
            expense(merchant: "Taxi", person: nil, paidBy: sam.clientUUID, splits: everyone, amount: 30),
        ]
        try store.context.save()

        let before = TripSettlement.compute(expenses: rows)
            .map { ($0.party, $0.net) }

        try service.rename(tim, to: "Don")

        let after = TripSettlement.compute(expenses: rows)
            .map { ($0.party, $0.net) }

        XCTAssertEqual(before.count, after.count)
        for (lhs, rhs) in zip(before, after) {
            XCTAssertEqual(lhs.0, rhs.0, "A party changed identity across the rename.")
            XCTAssertEqual(lhs.1, rhs.1, accuracy: 0.0001)
        }
        XCTAssertTrue(after.contains { $0.0 == .person(tim.clientUUID) })
    }

    // MARK: - Rejections write nothing

    /// A rename onto a name another person already holds is rejected rather than
    /// merged. A merge would have to repoint the tag, the payer, every split
    /// entry and every trip's participant list, and cannot be undone.
    func testRenameOntoAnExistingNameIsRejected() throws {
        let tim = try service.findOrCreate(name: "Tim")
        _ = try service.findOrCreate(name: "Don")
        expense(merchant: "Trattoria", person: tim)
        try store.context.save()

        XCTAssertThrowsError(try service.rename(tim, to: "Don")) { error in
            guard case PersonServiceError.nameTaken = error else {
                return XCTFail("Expected .nameTaken, got \(error)")
            }
        }

        XCTAssertEqual(tim.name, "Tim", "A rejected rename must write nothing.")
        XCTAssertEqual(try fetchExpenses().first?.personName, "Tim")
    }

    /// The collision check is case-insensitive, matching `findOrCreate`, so the
    /// rename cannot slip a near-duplicate past it.
    func testCollisionIsCaseInsensitive() throws {
        let tim = try service.findOrCreate(name: "Tim")
        _ = try service.findOrCreate(name: "Don")
        XCTAssertThrowsError(try service.rename(tim, to: "  dON  "))
        XCTAssertEqual(tim.name, "Tim")
    }

    /// Re-casing a person's OWN name is a rename, not a collision. The clash
    /// check has to exclude the person being renamed or this throws.
    func testRecasingOwnNameIsAllowed() throws {
        let person = try service.findOrCreate(name: "tim")
        try service.rename(person, to: "Tim")
        XCTAssertEqual(person.name, "Tim")
    }

    func testEmptyNameIsRejected() throws {
        let person = try service.findOrCreate(name: "Tim")
        XCTAssertThrowsError(try service.rename(person, to: "   ")) { error in
            guard case PersonServiceError.emptyName = error else {
                return XCTFail("Expected .emptyName, got \(error)")
            }
        }
        XCTAssertEqual(person.name, "Tim")
    }

    /// The name is trimmed on the way in, so a stray space cannot produce two
    /// people who read identically in a chip.
    func testRenameTrimsWhitespace() throws {
        let person = try service.findOrCreate(name: "Tim")
        try service.rename(person, to: "  Don  ")
        XCTAssertEqual(person.name, "Don")
    }
}
