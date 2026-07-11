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
/// Participants are managed in the trip editor (Edit trip on the Itineraries
/// list), not here.
///
/// Amounts default to the currency each expense was CAPTURED in — a trip's
/// spend reads naturally in euros on a Europe trip. A toggle on the stats card
/// converts the whole tab to the chosen display currency on demand.
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

    /// False (default) = amounts render in the currency each expense was
    /// captured in. True = everything converts to the chosen display currency.
    @State private var showConverted: Bool = false

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

    // MARK: - Currency mode

    /// Per-currency signed totals in capture currency, largest spend first.
    private var totalsByCurrency: [(code: String, total: Double, myShare: Double)] {
        var totals: [String: (total: Double, myShare: Double)] = [:]
        for expense in expenses {
            let code = expense.originalCurrency.uppercased()
            var entry = totals[code] ?? (0, 0)
            entry.total += expense.signedOriginal
            entry.myShare += expense.myShareOriginal
            totals[code] = entry
        }
        return totals
            .map { (code: $0.key, total: $0.value.total, myShare: $0.value.myShare) }
            .sorted { abs($0.total) > abs($1.total) }
    }

    /// Non-nil when every expense was captured in the same currency — the only
    /// case where settle-up can run natively in the capture currency.
    private var singleCurrencyCode: String? {
        let codes = Set(expenses.map { $0.originalCurrency.uppercased() })
        return codes.count == 1 ? codes.first : nil
    }

    /// "EUR 1,240.50", signed. Capture-currency counterpart of
    /// `FinanceDashboardBand.formatMoney` (which converts to the display
    /// currency and uses its symbol).
    static func formatOriginal(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let amount = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "\(code) \(amount)"
    }

    private var displayCurrencyCode: String {
        FinanceSettings.displayCurrencyCode.uppercased()
    }

    /// Small capsule that flips the tab between as-captured and converted
    /// amounts. Labelled with the mode a tap switches TO.
    private var currencyToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showConverted.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(showConverted ? "As added" : displayCurrencyCode)
                    .font(.edCaption)
            }
            .foregroundStyle(Tokens.accentFinance)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 4)
            .background(Tokens.accentFinance.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showConverted
            ? "Show amounts in the currency they were added in"
            : "Show amounts in \(displayCurrencyCode)")
    }

    // MARK: - Stats card

    private var groupTotalSGD: Double {
        expenses.reduce(0) { $0 + $1.signedSGD }
    }

    private var yourShareSGD: Double {
        expenses.reduce(0) { $0 + $1.myShareSGD }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("Group total").eyebrow()
                Spacer()
                currencyToggle
            }

            if showConverted {
                Text(FinanceDashboardBand.formatMoney(groupTotalSGD))
                    .font(.edDisplay)
                    .foregroundStyle(Tokens.ink)
                    .tracking(-0.6)
            } else {
                let totals = totalsByCurrency
                if let first = totals.first {
                    Text(Self.formatOriginal(first.total, code: first.code))
                        .font(.edDisplay)
                        .foregroundStyle(Tokens.ink)
                        .tracking(-0.6)
                }
                ForEach(totals.dropFirst(), id: \.code) { entry in
                    Text(Self.formatOriginal(entry.total, code: entry.code))
                        .font(.edBodyMedium)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.inkSoft)
                }
            }

            HStack(spacing: Space.lg) {
                statTile(label: "Your share", value: yourShareLabel)
                statTile(label: "Expenses", value: "\(expenses.count)")
            }
            .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    private var yourShareLabel: String {
        if showConverted {
            return FinanceDashboardBand.formatMoney(yourShareSGD)
        }
        return totalsByCurrency
            .map { Self.formatOriginal($0.myShare, code: $0.code) }
            .joined(separator: " · ")
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

    /// True when the settle-up card can run natively in the capture currency:
    /// the user wants as-added amounts AND the trip is single-currency. A
    /// mixed-currency trip has no meaningful "as added" net, so it falls back
    /// to the display currency (flagged in the card).
    private var settlesInCaptureCurrency: Bool {
        !showConverted && singleCurrencyCode != nil
    }

    /// Netted per-party balances, sorted with the user first, then the people
    /// who are owed the most. Only parties whose net is more than a cent show.
    private var balances: [TripSettlement.Balance] {
        if settlesInCaptureCurrency {
            return TripSettlement.compute(expenses: expenses) { $0.signedOriginal }
        }
        return TripSettlement.compute(expenses: expenses)
    }

    private func settleAmount(_ value: Double) -> String {
        if settlesInCaptureCurrency, let code = singleCurrencyCode {
            return Self.formatOriginal(value, code: code)
        }
        return FinanceDashboardBand.formatMoney(value)
    }

    private var settleUpCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("Settle up").eyebrow()
                if !showConverted && singleCurrencyCode == nil {
                    Spacer()
                    Text("in \(displayCurrencyCode) · mixed currencies")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                }
            }
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
            Text(settleAmount(abs(balance.net)))
                .font(.edFootnoteStrong)
                .monospacedDigit()
                .foregroundStyle(owed ? Tokens.success : Tokens.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phrase(for: balance)) \(settleAmount(abs(balance.net)))")
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
                    ExpenseRow(expense: expense, showsOriginalFirst: !showConverted) {
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
                     ? "Tap + to log a trip expense. Add people in Edit trip to split the bill."
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
/// Runs on a caller-supplied signed amount per expense — the frozen
/// home-currency `signedSGD` by default (correct for mixed-currency trips),
/// or `signedOriginal` when the whole trip shares one capture currency. For
/// each party the net position is `totalPaid - totalOwedShare`: positive means
/// the party is owed money by the group, negative means they owe. The group
/// nets to zero.
///
/// An UNSPLIT expense is owed entirely by whoever paid it, so it nets to zero
/// for that party and never creates a balance — exactly right for a personal
/// cost logged against the trip.
enum TripSettlement {
    struct Balance: Identifiable {
        let party: SplitPartyID
        /// Signed net in the caller's amount basis. > 0 owed money, < 0 owes.
        let net: Double
        var id: SplitPartyID { party }
    }

    /// Below this magnitude (half a cent) a party counts as settled and is
    /// dropped from the list.
    private static let epsilon = 0.005

    static func compute(
        expenses: [LocalExpense],
        amount: (LocalExpense) -> Double = { $0.signedSGD }
    ) -> [Balance] {
        var paid: [SplitPartyID: Double] = [:]
        var owed: [SplitPartyID: Double] = [:]

        for expense in expenses {
            let value = amount(expense)
            let payer: SplitPartyID = expense.paidByPersonUUID.map { .person($0) } ?? .me
            paid[payer, default: 0] += value

            let splits = expense.splits
            if splits.isEmpty {
                // Unsplit: the payer bears the whole cost (nets to zero).
                owed[payer, default: 0] += value
                continue
            }
            let totalShares = splits.reduce(0) { $0 + max($1.shares, 0) }
            guard totalShares > 0 else {
                owed[payer, default: 0] += value
                continue
            }
            for entry in splits {
                let shares = max(entry.shares, 0)
                guard shares > 0 else { continue }
                let party: SplitPartyID = entry.personID.map { .person($0) } ?? .me
                owed[party, default: 0] += value * Double(shares) / Double(totalShares)
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
