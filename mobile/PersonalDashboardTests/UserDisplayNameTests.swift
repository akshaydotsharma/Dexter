import XCTest
@testable import PersonalDashboard

/// Naming the user (#530).
///
/// The user is NOT a `LocalPerson` and must never become one: `nil` is the
/// person id that means "the user" in every `ExpenseSplitEntry`, in
/// `paidByPersonUUID`, in `LocalExpense.myShareSGD` and in `TripSettlement`.
/// So this is a label, stored in `UserDefaults` beside the display currency,
/// and nothing about an expense changes.
///
/// The half that is easy to get wrong is the GRAMMAR. "You owe" is second
/// person because "You" is a pronoun, not because the party is the user. Once
/// the user is called Akshay, every one of those lines has to move to the
/// third person or the app starts saying "Akshay owe".
final class UserDisplayNameTests: XCTestCase {

    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: FinanceSettings.Key.userDisplayName)
        UserDefaults.standard.removeObject(forKey: FinanceSettings.Key.userDisplayName)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: FinanceSettings.Key.userDisplayName)
        } else {
            UserDefaults.standard.removeObject(forKey: FinanceSettings.Key.userDisplayName)
        }
        super.tearDown()
    }

    // MARK: - The default is unchanged behaviour

    func testDefaultsToYou() {
        XCTAssertEqual(FinanceSettings.userDisplayName, "You")
        XCTAssertEqual(FinanceSettings.userDisplayInitial, "Y")
        XCTAssertTrue(FinanceSettings.userIsAddressedInSecondPerson)
    }

    /// Clearing the Settings field is how you go back to the pronoun. An empty
    /// or whitespace-only stored value must not leave the app with no name.
    func testEmptyAndWhitespaceReadAsYou() {
        FinanceSettings.userDisplayName = ""
        XCTAssertEqual(FinanceSettings.userDisplayName, "You")
        FinanceSettings.userDisplayName = "   "
        XCTAssertEqual(FinanceSettings.userDisplayName, "You")
        XCTAssertTrue(FinanceSettings.userIsAddressedInSecondPerson)
    }

    func testNameIsTrimmed() {
        FinanceSettings.userDisplayName = "  Akshay  "
        XCTAssertEqual(FinanceSettings.userDisplayName, "Akshay")
    }

    // MARK: - Naming yourself

    func testNamedUserSwitchesToThirdPerson() {
        FinanceSettings.userDisplayName = "Akshay"
        XCTAssertEqual(FinanceSettings.userDisplayName, "Akshay")
        XCTAssertEqual(FinanceSettings.userDisplayInitial, "A")
        XCTAssertFalse(FinanceSettings.userIsAddressedInSecondPerson)
    }

    /// The avatar initial is grapheme-safe, so a Devanagari or emoji name
    /// yields one whole character rather than half of one.
    func testInitialIsGraphemeSafe() {
        FinanceSettings.userDisplayName = "अक्षय"
        XCTAssertEqual(FinanceSettings.userDisplayInitial.count, 1)
        FinanceSettings.userDisplayName = "🙂 me"
        XCTAssertEqual(FinanceSettings.userDisplayInitial, "🙂")
    }

    // MARK: - Possessive grammar

    /// The rule behind "AKSHAY'S SPEND" and "Akshay's cost in full": a name
    /// takes the apostrophe, the pronoun takes "Your". Written once because
    /// "You's spend" is the exact sentence it exists to prevent.
    func testPossessiveTakesTheApostropheOnlyForAName() {
        XCTAssertEqual(FinanceSettings.possessive("You"), "Your")
        XCTAssertEqual(FinanceSettings.possessive("Akshay"), "Akshay's")
        XCTAssertEqual(FinanceSettings.possessive("Papa"), "Papa's")
    }

    /// Resolved through the live setting, which is how the summary card reads
    /// it: unnamed keeps the heading it had before the setting existed.
    func testSummaryHeadingFollowsTheSetting() {
        XCTAssertEqual("\(FinanceSettings.possessive(FinanceSettings.userDisplayName)) spend",
                       "Your spend")
        FinanceSettings.userDisplayName = "Akshay"
        XCTAssertEqual("\(FinanceSettings.possessive(FinanceSettings.userDisplayName)) spend",
                       "Akshay's spend")
    }

    // MARK: - The split roster follows

    func testSplitRosterUsesTheName() throws {
        FinanceSettings.userDisplayName = "Akshay"
        let other = UUID()
        let roster = try XCTUnwrap(SplitAvatarRoster.make(
            payerPersonUUID: nil,
            splits: [
                ExpenseSplitEntry(person: nil, shares: 1),
                ExpenseSplitEntry(person: other, shares: 1),
            ],
            name: { _ in "Papa" },
            colorHex: { _ in nil }
        ))
        XCTAssertEqual(roster.payer.name, "Akshay")
        XCTAssertEqual(roster.payer.initial, "A")
        // Third person, and lower-cased "you" is gone from the spoken list.
        XCTAssertTrue(roster.spokenLabel.hasPrefix("Akshay paid"), roster.spokenLabel)
        XCTAssertFalse(roster.spokenLabel.contains("you"), roster.spokenLabel)
    }

    /// The same roster with no name set must read exactly as it did before the
    /// setting existed.
    func testSplitRosterIsUnchangedWithoutAName() throws {
        let other = UUID()
        let roster = try XCTUnwrap(SplitAvatarRoster.make(
            payerPersonUUID: nil,
            splits: [
                ExpenseSplitEntry(person: nil, shares: 1),
                ExpenseSplitEntry(person: other, shares: 1),
            ],
            name: { _ in "Papa" },
            colorHex: { _ in nil }
        ))
        XCTAssertEqual(roster.payer.name, "You")
        XCTAssertEqual(roster.payer.initial, "Y")
        XCTAssertTrue(roster.spokenLabel.hasPrefix("You paid"), roster.spokenLabel)
    }

    // MARK: - The report follows

    /// "You pay Papa" but "Akshay pays Papa". The verb is chosen from the WORD,
    /// so a named user takes the same third person a participant does.
    func testTransferVerbFollowsTheName() {
        let unnamed = TripExpenseReport.make(input(payer: nil))
        XCTAssertTrue(
            unnamed.transfers.contains { $0.sentence.contains("You pay ") },
            unnamed.transfers.map(\.sentence).description
        )

        FinanceSettings.userDisplayName = "Akshay"
        let named = TripExpenseReport.make(input(payer: nil))
        XCTAssertTrue(
            named.transfers.contains { $0.sentence.contains("Akshay pays ") },
            named.transfers.map(\.sentence).description
        )
    }

    // MARK: - Fixture

    /// One trip, one bill of 100 fronted by Papa and split evenly, so the user
    /// owes Papa 50 and the report has exactly one transfer to phrase.
    private func input(payer: UUID?) -> TripExpenseReportInput {
        let papa = UUID()
        let expense = LocalExpense(
            category: "food_and_dining",
            merchant: "Trattoria",
            originalAmount: 100,
            originalCurrency: "SGD",
            sgdAmount: 100,
            fxRate: 1,
            source: "manual",
            paidByPersonUUID: papa
        )
        expense.splits = [
            ExpenseSplitEntry(person: nil, shares: 1),
            ExpenseSplitEntry(person: papa, shares: 1),
        ]
        return TripExpenseReportInput(
            tripName: "Italy",
            startDate: Date(),
            endDate: Date(),
            allExpenses: [expense],
            participantOrder: [.me, .person(papa)],
            reportCurrencyCode: "SGD",
            exportDate: Date(),
            displayName: { party in
                switch party {
                case .me:      return FinanceSettings.userDisplayName
                case .person:  return "Papa"
                }
            },
            displayMoney: { "SGD \($0)" },
            captureMoney: { value, code in "\(code) \(value)" },
            tripRateToSGD: { _ in nil }
        )
    }
}
