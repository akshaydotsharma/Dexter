import SwiftUI
import SwiftData

/// The expenses tab of a trip's detail screen (#258).
///
/// Trip expenses are ordinary `LocalExpense` rows joined by `tripUUID` (the FK
/// added in #177), enriched with the settle-up split metadata (#258). This
/// view surfaces three things: header stats (group total, the user's share,
/// count), netted settle-up balances ("Rohan is owed S$140"), and the expense
/// list itself. Adding / editing goes through `AddExpenseSheet` with a trip
/// context, driven by the parent `TripDetailView` (which owns the sheet + FAB).
struct TripExpensesView: View {
    let trip: LocalTrip

    /// Tapping a row bubbles the expense's clientUUID up so the parent opens
    /// the editor (the parent owns the sheet + trip context).
    let onEditExpense: (String) -> Void

    /// Trip expenses, newest first. Filtered by the trip FK in the query.
    @Query private var expenses: [LocalExpense]

    /// People, so participant names / colours resolve for the settle-up rows.
    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var people: [LocalPerson]

    init(trip: LocalTrip, onEditExpense: @escaping (String) -> Void) {
        self.trip = trip
        self.onEditExpense = onEditExpense
        let tripID = trip.clientUUID
        _expenses = Query(
            filter: #Predicate<LocalExpense> { $0.tripUUID == tripID },
            sort: [
                SortDescriptor(\.date, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse)
            ]
        )
    }

    var body: some View {
        Group {
            if expenses.isEmpty {
                emptyState
            } else {
                populated
            }
        }
    }

    // MARK: - Populated

    private var populated: some View {
        ScrollView {
            VStack(spacing: Space.lg) {
                statsCard
                if !balances.isEmpty {
                    settleUpCard
                }
                expenseList
                Color.clear.frame(height: 96)
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Stats card

    private var groupTotal: Double {
        expenses.reduce(0) { $0 + $1.signedSGD }
    }

    private var yourShare: Double {
        expenses.reduce(0) { $0 + $1.myShareSGD }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Group total").eyebrow()
            Text(FinanceDashboardBand.formatMoney(groupTotal))
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .tracking(-0.6)

            HStack(spacing: Space.lg) {
                statTile(label: "Your share", value: FinanceDashboardBand.formatMoney(yourShare))
                statTile(label: "Expenses", value: "\(expenses.count)")
            }
            .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    private func statTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
            Text(value)
                .font(.edBodyMedium)
                .monospacedDigit()
                .foregroundStyle(Tokens.inkSoft)
        }
    }

    // MARK: - Settle up

    /// Netted per-party balances, sorted with the user first, then the people
    /// who are owed the most. Only parties whose net is more than a cent show.
    private var balances: [TripSettlement.Balance] {
        TripSettlement.compute(expenses: expenses)
    }

    private var settleUpCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Settle up").eyebrow()
            VStack(spacing: Space.sm) {
                ForEach(balances) { balance in
                    settleRow(balance)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    private func settleRow(_ balance: TripSettlement.Balance) -> some View {
        // Positive net = owed money (green); negative = owes (ink). The amount
        // is shown as a magnitude; the phrasing carries the direction.
        let owed = balance.net > 0
        return HStack(spacing: Space.sm) {
            Circle()
                .fill(partyColor(balance.party))
                .frame(width: 10, height: 10)
            Text(phrase(for: balance))
                .font(.edFootnote)
                .foregroundStyle(Tokens.inkSoft)
                .lineLimit(1)
            Spacer(minLength: Space.sm)
            Text(FinanceDashboardBand.formatMoney(abs(balance.net)))
                .font(.edFootnoteStrong)
                .monospacedDigit()
                .foregroundStyle(owed ? Tokens.success : Tokens.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phrase(for: balance)) \(FinanceDashboardBand.formatMoney(abs(balance.net)))")
    }

    /// "You are owed" / "You owe" / "Rohan is owed" / "Sam owes".
    private func phrase(for balance: TripSettlement.Balance) -> String {
        let owed = balance.net > 0
        switch balance.party {
        case .me:
            return owed ? "You are owed" : "You owe"
        case .person(let id):
            let name = personName(id)
            return owed ? "\(name) is owed" : "\(name) owes"
        }
    }

    private func personName(_ id: UUID) -> String {
        people.first { $0.clientUUID == id }?.name ?? "Someone"
    }

    private func partyColor(_ party: SplitPartyID) -> Color {
        switch party {
        case .me:
            return Tokens.accentFinance
        case .person(let id):
            if let person = people.first(where: { $0.clientUUID == id }) {
                return Color(personHex: person.colorHex)
            }
            return Tokens.accentFinance
        }
    }

    // MARK: - Expense list

    private var expenseList: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Expenses").eyebrow()
            VStack(spacing: Space.xs) {
                ForEach(expenses) { expense in
                    ExpenseRow(expense: expense) {
                        onEditExpense(expense.clientUUID)
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                Image(systemName: "wallet.bifold")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Tokens.mutedSoft)
                Spacer().frame(height: Space.md)
                Text("No expenses yet")
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.center)
                Spacer().frame(height: Space.xs)
                Text(trip.participantPersonUUIDs.isEmpty
                     ? "Tap + to log a trip expense. Add participants in Edit trip to split the bill."
                     : "Tap + to log a trip expense and split it with your group.")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.lg)
    }
}

// MARK: - Settlement math

/// Pure settle-up computation over a trip's expenses (#258).
///
/// Runs entirely on the frozen home-currency amounts (`signedSGD`) so a
/// mixed-currency trip nets correctly and refunds subtract. For each party the
/// net position is `totalPaid - totalOwedShare`: positive means the party is
/// owed money by the group, negative means they owe. The group nets to zero.
///
/// An UNSPLIT expense is owed entirely by whoever paid it, so it nets to zero
/// for that party and never creates a balance — exactly right for a personal
/// cost logged against the trip.
enum TripSettlement {
    struct Balance: Identifiable {
        let party: SplitPartyID
        /// Home-currency net. > 0 owed money, < 0 owes.
        let net: Double
        var id: SplitPartyID { party }
    }

    /// Below this magnitude (half a cent) a party counts as settled and is
    /// dropped from the list.
    private static let epsilon = 0.005

    static func compute(expenses: [LocalExpense]) -> [Balance] {
        var paid: [SplitPartyID: Double] = [:]
        var owed: [SplitPartyID: Double] = [:]

        for expense in expenses {
            let amount = expense.signedSGD
            let payer: SplitPartyID = expense.paidByPersonUUID.map { .person($0) } ?? .me
            paid[payer, default: 0] += amount

            let splits = expense.splits
            if splits.isEmpty {
                // Unsplit: the payer bears the whole cost (nets to zero).
                owed[payer, default: 0] += amount
                continue
            }
            let totalShares = splits.reduce(0) { $0 + max($1.shares, 0) }
            guard totalShares > 0 else {
                owed[payer, default: 0] += amount
                continue
            }
            for entry in splits {
                let shares = max(entry.shares, 0)
                guard shares > 0 else { continue }
                let party: SplitPartyID = entry.personID.map { .person($0) } ?? .me
                owed[party, default: 0] += amount * Double(shares) / Double(totalShares)
            }
        }

        let parties = Set(paid.keys).union(owed.keys)
        var balances: [Balance] = parties.map { party in
            Balance(party: party, net: (paid[party] ?? 0) - (owed[party] ?? 0))
        }
        balances.removeAll { abs($0.net) < epsilon }

        // User first, then people owed the most, then people who owe the most.
        balances.sort { lhs, rhs in
            if lhs.party == .me { return true }
            if rhs.party == .me { return false }
            return lhs.net > rhs.net
        }
        return balances
    }
}
