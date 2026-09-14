import XCTest
@testable import DexterMac

/// The trip expense report, asserted as data (#528).
///
/// The report's whole value is that it agrees with the tab it was exported
/// from. So the tests are mostly agreement tests: the participant table against
/// `TripSettlement.totals`, the cover shares against the participant table, the
/// category totals against the group total, the transfers against the balances
/// they claim to clear.
///
/// One fixture trip carries every case the feature has to survive: two
/// currencies, a refund, an unsplit bill another participant fronted, a bill
/// the user has no part in at all, a participant holding a zero share, a person
/// deleted from People, an empty split, and a row removed from the trip.
final class TripExpenseReportTests: XCTestCase {

    private let priya = UUID()
    private let sam = UUID()
    /// In a split, but no longer in People and no longer on the trip roster.
    private let ghost = UUID()

    private let tripID = UUID()
    /// The trip's frozen EUR rate, the one `tripRateToSGD` observes.
    private let eurRate = 1.473

    // MARK: - Fixture

    private func day(_ value: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = value
        components.hour = 12
        let date = Calendar.current.date(from: components) ?? Date()
        return Calendar.current.startOfDay(for: date)
    }

    private func expense(
        _ id: String,
        day dayOfMonth: Int,
        merchant: String,
        category: String,
        amount: Double,
        currency: String,
        paidBy: UUID? = nil,
        splits: [ExpenseSplitEntry] = [],
        isRefund: Bool = false,
        hiddenFromTrip: Bool = false
    ) -> LocalExpense {
        let rate = currency == "EUR" ? eurRate : 1.0
        let row = LocalExpense(
            clientUUID: id,
            date: day(dayOfMonth),
            category: category,
            merchant: merchant,
            originalAmount: amount,
            originalCurrency: currency,
            sgdAmount: amount * rate,
            fxRate: rate,
            source: "manual",
            tripUUID: tripID,
            isRefund: isRefund,
            paidByPersonUUID: paidBy,
            hiddenFromTrip: hiddenFromTrip
        )
        row.splits = splits
        return row
    }

    /// Trattoria — a three-way split where Sam holds a zero share.
    private var trattoria: LocalExpense {
        expense(
            "trattoria", day: 3, merchant: "Trattoria", category: "food_and_dining",
            amount: 120, currency: "EUR",
            splits: [
                ExpenseSplitEntry(person: nil, shares: 1),
                ExpenseSplitEntry(person: priya, shares: 1),
                ExpenseSplitEntry(person: sam, shares: 0)
            ]
        )
    }

    /// Taxi — UNSPLIT and fronted by Priya. The user owes her all of it
    /// (#504, #512).
    private var taxi: LocalExpense {
        expense(
            "taxi", day: 3, merchant: "Taxi", category: "transport",
            amount: 60, currency: "EUR", paidBy: priya
        )
    }

    /// Hotel — split with someone who has since been deleted from People.
    private var hotel: LocalExpense {
        expense(
            "hotel", day: 4, merchant: "Hotel Rialto", category: "accommodation",
            amount: 200, currency: "SGD",
            splits: [
                ExpenseSplitEntry(person: nil, shares: 1),
                ExpenseSplitEntry(person: ghost, shares: 1)
            ]
        )
    }

    /// A refund, on the same day as the hotel, so it nets that day down.
    private var museumRefund: LocalExpense {
        expense(
            "refund", day: 4, merchant: "Museum refund", category: "activities",
            amount: 40, currency: "EUR", isRefund: true
        )
    }

    /// An empty split the user paid: their cost in full.
    private var gelato: LocalExpense {
        expense("gelato", day: 5, merchant: "Gelato", category: "food_and_dining", amount: 30, currency: "EUR")
    }

    /// A bill the user has NO part in: Priya paid, Priya and the deleted person
    /// shared it. Under the old behaviour, a ledger following the tab's
    /// You-only reading had no reason to carry this row. The report is the
    /// group's record of the trip, so it does.
    private var dinnerWithoutMe: LocalExpense {
        expense(
            "dinner", day: 5, merchant: "Osteria", category: "food_and_dining",
            amount: 90, currency: "EUR", paidBy: priya,
            splits: [
                ExpenseSplitEntry(person: priya, shares: 1),
                ExpenseSplitEntry(person: ghost, shares: 1)
            ]
        )
    }

    /// Removed from the trip (#264). Must appear nowhere and count nowhere.
    private var removed: LocalExpense {
        expense(
            "removed", day: 5, merchant: "Removed From Trip", category: "shopping",
            amount: 999, currency: "EUR", hiddenFromTrip: true
        )
    }

    /// Newest first, matching the tab's sort.
    private func allExpenses() -> [LocalExpense] {
        [dinnerWithoutMe, gelato, removed, museumRefund, hotel, taxi, trattoria]
    }

    private var order: [SplitPartyID] { [.me, .person(priya), .person(sam)] }

    private func input(
        all: [LocalExpense]? = nil,
        currency: String = "SGD"
    ) -> TripExpenseReportInput {
        let rows = all ?? allExpenses()
        let code = currency.uppercased()
        let rate = code == "EUR" ? eurRate : 1.0
        return TripExpenseReportInput(
            tripName: "Italy",
            startDate: day(3),
            endDate: day(5),
            allExpenses: rows,
            participantOrder: order,
            reportCurrencyCode: code,
            exportDate: day(14),
            displayName: { party in
                switch party {
                case .me:                       return "You"
                case .person(let id) where id == self.priya: return "Priya"
                case .person(let id) where id == self.sam:   return "Sam"
                case .person:                   return "Someone"
                }
            },
            // Mirrors the tab's `formatMoney(_:in:)`: an SGD-basis value
            // converted with the trip's own frozen rate.
            displayMoney: { String(format: "%@ %.2f", code, $0 / rate) },
            captureMoney: { value, code in String(format: "%@ %.2f", code, value) },
            tripRateToSGD: { code in code == "EUR" ? self.eurRate : 1.0 }
        )
    }

    private func report(
        all: [LocalExpense]? = nil,
        currency: String = "SGD"
    ) -> TripExpenseReport {
        TripExpenseReport.make(input(all: all, currency: currency))
    }

    private func participant(_ named: String, in report: TripExpenseReport) throws -> TripExpenseReport.ParticipantRow {
        try XCTUnwrap(report.participants.first { $0.name == named }, "No row for \(named)")
    }

    private func ledgerRow(_ titled: String, in report: TripExpenseReport) throws -> TripExpenseReport.LedgerRow {
        try XCTUnwrap(
            report.ledger.flatMap(\.rows).first { $0.title == titled },
            "No ledger row for \(titled)"
        )
    }

    /// 120 + 60 + 30 + 90 EUR at 1.473, less the EUR 40 refund, plus SGD 200.
    private var expectedGroupTotalSGD: Double {
        (120 + 60 + 30 + 90 - 40) * eurRate + 200
    }

    // MARK: - The report is the whole trip

    /// The point of the reversal: the report lists a bill the user has no part
    /// in. A ledger showing only the reader's share beside a settlement
    /// computed over everyone's would be two documents stapled together.
    func testTheLedgerCarriesABillTheUserHasNoPartIn() throws {
        let made = report()
        let row = try ledgerRow("Osteria", in: made)

        XCTAssertEqual(row.payer, "Priya paid")
        XCTAssertEqual(row.split, "Split evenly: Priya, Someone")
        XCTAssertEqual(made.ledger.flatMap(\.rows).count, 6, "Every expense on the trip is listed")
    }

    /// Nothing the report says is scoped to a person. Every section counts the
    /// same six expenses.
    func testEverySectionCoversTheWholeTrip() {
        let made = report()

        XCTAssertEqual(made.cover.expenseCount, 6)
        XCTAssertEqual(made.ledger.flatMap(\.rows).count, 6)
        XCTAssertEqual(made.categories.reduce(0) { $0 + $1.count }, 6)
        XCTAssertEqual(made.groupTotal, expectedGroupTotalSGD, accuracy: 0.001)
    }

    /// A bill the user is not part of still lands in its category and its day.
    func testABillTheUserHasNoPartInStillCountsInTheTotals() throws {
        let food = try XCTUnwrap(made(in: report(), category: "Food & Dining"))
        // Trattoria 120 + Gelato 30 + Osteria 90, all EUR.
        XCTAssertEqual(food.total, 240 * eurRate, accuracy: 0.001)
        XCTAssertEqual(food.count, 3)
    }

    private func made(in report: TripExpenseReport, category: String) -> TripExpenseReport.CategoryRow? {
        report.categories.first { $0.name == category }
    }

    // MARK: - Rows hidden from the trip

    /// #264: a row removed from the trip has no trip surface, and the report is
    /// a trip surface. It must not be listed, counted, or settled.
    func testARowHiddenFromTheTripAppearsNowhere() {
        let made = report()

        XCTAssertFalse(made.ledger.flatMap(\.rows).contains { $0.title == "Removed From Trip" })
        XCTAssertEqual(made.cover.expenseCount, 6, "The hidden row must not be counted")
        XCTAssertFalse(made.categories.contains { $0.name == "Shopping" })
        XCTAssertEqual(made.groupTotal, expectedGroupTotalSGD, accuracy: 0.001)
    }

    // MARK: - The participant table IS TripSettlement

    func testParticipantRowsEqualTripSettlementTotals() throws {
        let rows = allExpenses().filter { !$0.hiddenFromTrip }
        let totals = TripSettlement.totals(expenses: rows)
        let made = report()

        for (party, name) in [(SplitPartyID.me, "You"), (.person(priya), "Priya"), (.person(sam), "Sam"), (.person(ghost), "Someone")] {
            let row = try participant(name, in: made)
            let expected = totals[party] ?? (paid: 0, owed: 0)
            XCTAssertEqual(row.paid, expected.paid, accuracy: 0.001, "\(name) paid")
            XCTAssertEqual(row.spent, expected.owed, accuracy: 0.001, "\(name) spent")
            XCTAssertEqual(row.net, expected.paid - expected.owed, accuracy: 0.001, "\(name) net")
        }
    }

    /// The whole group nets to zero, which is what makes the transfers solvable.
    func testTheParticipantTableNetsToZero() {
        let sum = report().participants.reduce(0) { $0 + $1.net }
        XCTAssertEqual(sum, 0, accuracy: 0.001)
    }

    /// A participant who consumed nothing still gets a row: the table is the
    /// group, not a list of people who happened to spend.
    func testAZeroShareParticipantStillGetsARow() throws {
        let row = try participant("Sam", in: report())
        XCTAssertEqual(row.paid, 0, accuracy: 0.001)
        XCTAssertEqual(row.spent, 0, accuracy: 0.001)
        XCTAssertEqual(row.net, 0, accuracy: 0.001)
    }

    /// A person deleted from People still holds a slice of a bill. Dropping
    /// them would stop the table summing to the group total, so they render by
    /// their stored slice as "Someone" — the way the tab already degrades.
    func testADeletedPersonStillRendersByTheirStoredSlice() throws {
        let row = try participant("Someone", in: report())
        // Half the SGD 200 hotel, plus half the EUR 90 dinner.
        XCTAssertEqual(row.spent, 100 + 45 * eurRate, accuracy: 0.001)
        XCTAssertEqual(row.paid, 0, accuracy: 0.001)
    }

    // MARK: - Cover: every participant's share

    /// The cover repeats a column the participant table shows later, on
    /// purpose: "what do I owe for this trip" has to be answerable from page
    /// one. Repeating it is only safe if the two can never disagree.
    func testTheCoverShareOfEachPersonMatchesTheirParticipantRow() throws {
        let made = report()
        XCTAssertEqual(made.cover.shares.map(\.name), made.participants.map(\.name))

        for share in made.cover.shares {
            let row = try participant(share.name, in: made)
            XCTAssertEqual(share.share, row.spent, accuracy: 0.0001, "\(share.name)")
            XCTAssertEqual(share.shareText, row.spentText, "\(share.name)")
        }
    }

    /// The claim the cover makes by putting the shares under the group total:
    /// these add up to it. Every expense's value is distributed across the
    /// parties that consumed it, so the sum is exact, not approximate.
    func testTheCoverSharesSumToTheGroupTotal() {
        let made = report()
        let sum = made.cover.shares.reduce(0) { $0 + $1.share }

        XCTAssertEqual(sum, made.groupTotal, accuracy: 0.001)
        XCTAssertEqual(sum, expectedGroupTotalSGD, accuracy: 0.001)
    }

    /// The user first, then the trip's roster, then anyone left holding a slice.
    func testTheCoverSharesListTheUserFirst() {
        XCTAssertEqual(report().cover.shares.map(\.name), ["You", "Priya", "Sam", "Someone"])
    }

    /// A zero-share participant is still named on the cover. Leaving them off
    /// would read as "they were not on the trip".
    func testAZeroShareParticipantIsStillNamedOnTheCover() throws {
        let sam = try XCTUnwrap(report().cover.shares.first { $0.name == "Sam" })
        XCTAssertEqual(sam.share, 0, accuracy: 0.0001)
    }

    // MARK: - The unsplit bill someone else paid

    /// #504 / #512. Priya fronted the taxi and nobody split it, so it is the
    /// user's cost in full and a debt to Priya. The ledger has to print that
    /// reading, or the row above the settlement section contradicts it.
    func testAnUnsplitBillAnotherParticipantPaidIsTheUsersCostInFull() throws {
        let made = report()
        let row = try ledgerRow("Taxi", in: made)

        XCTAssertEqual(row.payer, "Priya paid")
        XCTAssertEqual(row.split, "Your cost in full")

        // And the settlement on the same document agrees.
        let priyaRow = try participant("Priya", in: made)
        XCTAssertEqual(priyaRow.paid, (60 + 90) * eurRate, accuracy: 0.001, "The taxi and the dinner")
        XCTAssertEqual(priyaRow.spent, (60 + 45) * eurRate, accuracy: 0.001, "Half the trattoria, half the dinner")
    }

    /// An empty split the user paid reads the same way, which is the point:
    /// the sentinel means "the user's, in full", whoever fronted it.
    func testAnEmptySplitIsTheUsersCostInFull() throws {
        let row = try ledgerRow("Gelato", in: report())
        XCTAssertEqual(row.payer, "You paid")
        XCTAssertEqual(row.split, "Your cost in full")
    }

    func testAZeroShareEntryIsNotListedAsASharer() throws {
        let row = try ledgerRow("Trattoria", in: report())
        XCTAssertEqual(row.split, "Split evenly: You, Priya", "Sam holds zero shares")
    }

    func testADeletedPersonIsNamedInTheSplitLine() throws {
        let row = try ledgerRow("Hotel Rialto", in: report())
        XCTAssertEqual(row.split, "Split evenly: You, Someone")
    }

    // MARK: - Refunds

    /// #206: a refund carries a positive magnitude and a direction flag. It has
    /// to read as a credit and net its day down, or the day's total contradicts
    /// the rows under it.
    func testARefundReadsAsACreditAndNetsItsDayDown() throws {
        let made = report()
        let row = try ledgerRow("Museum refund", in: made)

        XCTAssertTrue(row.isRefund)
        XCTAssertTrue(row.amount.hasPrefix("−"), "Got \(row.amount)")

        // 4 June holds the SGD 200 hotel and the EUR 40 refund.
        let fourth = try XCTUnwrap(made.ledger.first { $0.rows.contains { $0.title == "Hotel Rialto" } })
        XCTAssertEqual(fourth.total, String(format: "SGD %.2f", 200 - 40 * eurRate))
    }

    // MARK: - Days

    /// `LocalExpense.date` is written with `Calendar.current.startOfDay`, and
    /// Finance reads it the same way, so the report groups the same way.
    /// Deliberately not the UTC day anchor, which belongs to itinerary day
    /// fields (#506).
    func testDaysGroupNewestFirstOnTheDeviceCalendar() {
        let made = report()
        XCTAssertEqual(made.ledger.count, 3)
        XCTAssertEqual(made.ledger.map { $0.rows.count }, [2, 2, 2], "5 June, 4 June, 3 June")
        XCTAssertEqual(made.ledger.first?.rows.map(\.title), ["Osteria", "Gelato"])
    }

    // MARK: - Transfers

    func testTheTransfersClearEveryBalance() {
        let made = report()
        var remaining: [SplitPartyID: Double] = [:]
        for row in made.participants {
            remaining[party(for: row)] = row.net
        }
        for transfer in made.transfers {
            remaining[transfer.from, default: 0] += transfer.amount
            remaining[transfer.to, default: 0] -= transfer.amount
        }
        for (party, value) in remaining {
            XCTAssertEqual(value, 0, accuracy: 0.01, "\(party) was left holding \(value)")
        }
    }

    func testTheTransferCountStaysUnderTheParticipantCount() {
        let made = report()
        let unsettled = made.participants.filter { abs($0.net) > TripTransferSolver.epsilon }.count
        XCTAssertLessThanOrEqual(made.transfers.count, max(unsettled - 1, 0))
    }

    func testATransferReadsAsASentence() throws {
        let made = report()
        let first = try XCTUnwrap(made.transfers.first)
        XCTAssertTrue(
            first.sentence.contains(" pay ") || first.sentence.contains(" pays "),
            "Got \(first.sentence)"
        )
    }

    private func party(for row: TripExpenseReport.ParticipantRow) -> SplitPartyID {
        guard let id = UUID(uuidString: row.id) else { return .me }
        return .person(id)
    }

    // MARK: - Categories

    func testCategoryTotalsSumToTheGroupTotal() {
        let made = report()
        let sum = made.categories.reduce(0) { $0 + $1.total }
        XCTAssertEqual(sum, made.groupTotal, accuracy: 0.001)
        XCTAssertEqual(made.categories.reduce(0) { $0 + $1.count }, made.cover.expenseCount)
    }

    func testCategoriesAreOrderedBySpend() {
        let totals = report().categories.map(\.total)
        XCTAssertEqual(totals, totals.sorted(by: >))
    }

    // MARK: - The currency chosen at export time

    /// The whole report is written in the chosen currency: cover figures, day
    /// totals, the participant table, the transfers and the categories. Only
    /// the ledger rows keep what they were captured in.
    func testTheChosenCurrencyReachesEverySection() throws {
        let made = report(currency: "EUR")

        XCTAssertEqual(made.reportCurrencyCode, "EUR")
        XCTAssertTrue(made.cover.groupTotal.hasPrefix("EUR "), made.cover.groupTotal)
        for share in made.cover.shares {
            XCTAssertTrue(share.shareText.hasPrefix("EUR "), "\(share.name): \(share.shareText)")
        }
        for day in made.ledger {
            XCTAssertTrue(day.total.hasPrefix("EUR "), day.total)
        }
        for row in made.participants {
            XCTAssertTrue(row.paidText.hasPrefix("EUR "), row.paidText)
            XCTAssertTrue(row.spentText.hasPrefix("EUR "), row.spentText)
            XCTAssertTrue(row.netText.hasPrefix("EUR ") || row.netText.hasPrefix("−EUR "), row.netText)
        }
        for transfer in made.transfers {
            XCTAssertTrue(transfer.amountText.hasPrefix("EUR "), transfer.amountText)
        }
        for category in made.categories {
            XCTAssertTrue(category.totalText.hasPrefix("EUR "), category.totalText)
        }
    }

    /// The exception, and an explicit requirement of the ticket: a ledger row
    /// shows what was actually handed over, in the currency it was handed over
    /// in, whatever the report is written in.
    func testLedgerRowsKeepTheirCaptureCurrencyWhicheverCurrencyIsChosen() throws {
        for currency in ["SGD", "EUR"] {
            let made = report(currency: currency)
            XCTAssertEqual(try ledgerRow("Hotel Rialto", in: made).amount, "SGD 200.00", currency)
            XCTAssertEqual(try ledgerRow("Trattoria", in: made).amount, "EUR 120.00", currency)
        }
    }

    /// Changing the currency changes how the trip is written, never what it
    /// cost: the same money, divided by the trip's own frozen rate.
    func testTheChosenCurrencyChangesTheWordingNotTheArithmetic() throws {
        let sgd = report(currency: "SGD")
        let eur = report(currency: "EUR")

        XCTAssertEqual(sgd.groupTotal, eur.groupTotal, accuracy: 0.001, "Both bases are SGD on a mixed trip")
        XCTAssertEqual(eur.cover.groupTotal, String(format: "EUR %.2f", expectedGroupTotalSGD / eurRate))
        XCTAssertEqual(try participant("You", in: eur).spent, try participant("You", in: sgd).spent, accuracy: 0.001)
    }

    // MARK: - Currencies section

    func testAMixedCurrencyTripListsEveryCaptureCurrencyWithItsRate() throws {
        let made = report()
        XCTAssertEqual(Set(made.currencies.map(\.code)), ["EUR", "SGD"])

        let eur = try XCTUnwrap(made.currencies.first { $0.code == "EUR" })
        XCTAssertEqual(eur.total, 120 + 60 + 30 + 90 - 40, accuracy: 0.001)
        XCTAssertEqual(eur.rateText, "1 EUR = SGD 1.4730")
    }

    func testAMixedCurrencyTripCarriesTheDisplayCurrencyCaveat() {
        XCTAssertEqual(report().settlementCaveat, "Settled in SGD · mixed currencies")
        XCTAssertEqual(report(currency: "EUR").settlementCaveat, "Settled in EUR · mixed currencies")
    }

    /// Matches the tab's `showsCurrencyBreakdown`: a single currency that is
    /// already the report's currency adds nothing the group total has not said.
    func testTheCurrencyTableIsOmittedOnASingleCurrencyTripInTheReportCurrency() {
        let sgdOnly = report(all: [hotel], currency: "SGD")
        XCTAssertTrue(sgdOnly.currencies.isEmpty)
        XCTAssertNil(sgdOnly.settlementCaveat)
    }

    /// A single-currency trip shown in a DIFFERENT currency still needs the
    /// table, because the reader has to see what was actually spent.
    func testTheCurrencyTableSurvivesWhenTheReportCurrencyDiffers() {
        let euroTrip = report(all: [trattoria, gelato], currency: "SGD")
        XCTAssertEqual(euroTrip.currencies.map(\.code), ["EUR"])
    }

    /// On a trip captured entirely in the report's own currency there is
    /// nothing to convert, so the settlement runs on the frozen capture
    /// amounts and introduces no rounding.
    func testASingleCurrencyTripSettlesInItsOwnCapturedAmounts() throws {
        let sgdOnly = report(all: [hotel], currency: "SGD")
        XCTAssertEqual(sgdOnly.groupTotal, 200, accuracy: 0.001)
        let you = try participant("You", in: sgdOnly)
        XCTAssertEqual(you.paid, 200, accuracy: 0.001)
        XCTAssertEqual(you.spent, 100, accuracy: 0.001)
    }

    // MARK: - Cover wording

    /// The cover states the scope plainly. It must not contrast a filter: the
    /// report no longer has one, and a sentence about what was left out would
    /// send the reader looking for missing rows.
    func testTheCoverStatesTheScopeWithoutMentioningAFilter() {
        let sentence = report().cover.scopeSentence
        XCTAssertEqual(sentence, "This report covers all 6 expenses on this trip, for everyone on it.")
        XCTAssertFalse(sentence.lowercased().contains("filter"))
        XCTAssertFalse(sentence.lowercased().contains("left out"))
    }

    func testNoSectionNoteMentionsAFilter() {
        let made = report()
        for note in [made.ledgerNote, made.settlementNote, made.cover.scopeSentence, made.cover.currencySentence] {
            XCTAssertFalse(note.lowercased().contains("filter"), note)
        }
    }

    func testTheCoverNamesTheChosenCurrency() {
        let made = report(currency: "EUR")
        XCTAssertEqual(
            made.cover.currencySentence,
            "Every amount is in EUR, the currency chosen for this export, converted with the rates frozen on this trip's expenses."
        )
        XCTAssertEqual(made.cover.ledgerCurrencyNote, "Ledger rows keep the currency they were captured in.")
    }

    /// Nothing to convert and nothing to warn about, so the note is dropped
    /// rather than printed as a truism.
    func testASingleCurrencyReportDropsTheCaptureCurrencyNote() {
        let sgdOnly = report(all: [hotel], currency: "SGD")
        XCTAssertEqual(sgdOnly.cover.currencySentence, "Every amount is in SGD, the currency the trip was captured in.")
        XCTAssertNil(sgdOnly.cover.ledgerCurrencyNote)
    }

    func testTheCoverCarriesTheGroupTotalAndTheCount() {
        let made = report()
        XCTAssertEqual(made.cover.groupTotal, String(format: "SGD %.2f", expectedGroupTotalSGD))
        XCTAssertEqual(made.cover.expenseCount, 6)
    }

    // MARK: - File name

    func testTheFileIsNamedForTheTripAndTheExportDate() {
        XCTAssertEqual(report().fileName, "Italy expenses 2026-06-14.pdf")
    }

    func testAFileSystemHostileTripNameIsCollapsed() {
        let name = TripExpenseReport.fileName(tripName: "Rome / Milan: 2026", on: day(14))
        XCTAssertEqual(name, "Rome Milan 2026 expenses 2026-06-14.pdf")
    }
}
