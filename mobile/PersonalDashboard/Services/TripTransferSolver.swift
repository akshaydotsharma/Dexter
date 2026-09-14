import Foundation

/// "Who pays whom" for a trip (#528).
///
/// The settle-up card answers a different question: it states each party's net
/// position ("Priya is owed 140"). That is not a plan. Four people with four
/// non-zero balances still have to work out who hands money to whom, and the
/// obvious reading — everybody pays the one person who is owed — is wrong as
/// soon as two people are owed.
///
/// This turns the netted balances into the transfers that clear them. Greedy:
/// repeatedly take the biggest debtor and the biggest creditor and move the
/// smaller of the two amounts between them. Each step zeroes at least one
/// party, so a group of N parties needs at most N - 1 transfers, and the sum of
/// the transfers into and out of every party equals that party's balance.
///
/// It is not the provably minimal set for every input (that problem is
/// NP-hard). It is minimal in the count that matters here — no party is ever
/// asked to make two payments that could have been one — and it never invents a
/// transfer between two people who both owe, or both are owed.
enum TripTransferSolver {

    /// One payment. `from` hands `amount` to `to`.
    struct Transfer: Equatable {
        let from: SplitPartyID
        let to: SplitPartyID
        /// Always positive, in the caller's amount basis.
        let amount: Double
    }

    /// Below this magnitude (half a cent) a party counts as settled. Same
    /// threshold `TripSettlement` uses to drop a party from the balance list,
    /// so the two agree on who is still in play.
    static let epsilon = 0.005

    /// The transfers that clear `balances`, where a positive balance means the
    /// party is owed money and a negative one means they owe it.
    ///
    /// Returns an empty list when everyone is already settled. The result is
    /// deterministic: ties break on a stable party key, so the same trip
    /// exports the same plan every time.
    static func transfers(balances: [SplitPartyID: Double]) -> [Transfer] {
        var creditors = balances
            .filter { $0.value > epsilon }
            .map { (party: $0.key, amount: $0.value) }
        var debtors = balances
            .filter { $0.value < -epsilon }
            .map { (party: $0.key, amount: -$0.value) }

        var plan: [Transfer] = []

        while !creditors.isEmpty && !debtors.isEmpty {
            creditors.sort(by: largestFirst)
            debtors.sort(by: largestFirst)

            let amount = min(debtors[0].amount, creditors[0].amount)
            guard amount > epsilon else { break }

            plan.append(Transfer(from: debtors[0].party, to: creditors[0].party, amount: amount))

            debtors[0].amount -= amount
            creditors[0].amount -= amount
            if debtors[0].amount <= epsilon { debtors.removeFirst() }
            if creditors[0].amount <= epsilon { creditors.removeFirst() }
        }

        return plan
    }

    /// Biggest amount first; equal amounts fall back to the party key so the
    /// plan does not reshuffle between two exports of the same trip.
    private static func largestFirst(
        _ lhs: (party: SplitPartyID, amount: Double),
        _ rhs: (party: SplitPartyID, amount: Double)
    ) -> Bool {
        if abs(lhs.amount - rhs.amount) > 1e-9 { return lhs.amount > rhs.amount }
        return lhs.party.stableKey < rhs.party.stableKey
    }
}

extension SplitPartyID {
    /// A total order over parties, for deterministic sorting. The user sorts
    /// first (empty string), then people by their id.
    var stableKey: String {
        switch self {
        case .me:             return ""
        case .person(let id): return id.uuidString
        }
    }
}
