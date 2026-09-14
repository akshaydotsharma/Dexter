import Foundation

/// Identifies one party in a trip split: the user ("me") or a specific person.
///
/// Lives beside the split entry rather than in the expense editor (#540): the
/// settle-up breakdown helpers below are domain logic and must not depend on a
/// view file. `AddExpenseSheet` still owns the editor state that wraps it.
enum SplitPartyID: Hashable {
    case me
    case person(UUID)
}

/// One participant's slice of a group-split expense (trip expenses, #258).
///
/// Stored as JSON inside `LocalExpense.splitsData`. A `nil` / absent
/// `personUUID` represents the user ("me"), so the user can be one of the
/// people a bill is split among. `shares` is a weight, not a fraction: a
/// person's cost is `amount * (their shares / total shares)`. Equal split is
/// simply everyone at 1 share.
///
/// Person ids are stored as lowercase UUID strings (matching the string
/// convention `LocalExpense.clientUUID` uses) so the payload is stable and
/// round-trips cleanly through `JSONEncoder`.
///
/// ## Exact amounts and multiple payers (#540)
///
/// `owedAmount` and `paidAmount` are the two ways a bill can refuse to be a
/// weight. Both are OPTIONAL fields inside this JSON rather than new SwiftData
/// properties, which is the whole point: no column is added, so there is no
/// lightweight migration, no `schemaModels` divergence between two branches
/// (#432), and no peer on an older build NULLing a key it never heard of
/// (#428). Every payload written before this change decodes with both nil and
/// behaves exactly as it did.
///
/// - `owedAmount`: this party's exact consumed amount, in the expense's
///   CAPTURED currency (the same units as `LocalExpense.originalAmount`), and
///   always a positive magnitude — direction comes from the basis, never from
///   the stored figure. `nil` means "derive my slice from `shares`".
/// - `paidAmount`: what this party fronted, same units and sign convention.
///   `nil` / zero means they paid nothing. When NO entry carries one, the
///   payer is the single `LocalExpense.paidByPersonUUID`, exactly as before.
///
/// An entry can hold a `paidAmount` with `shares: 0`: someone who put money in
/// but consumed none of the bill.
struct ExpenseSplitEntry: Codable, Equatable, Hashable {
    /// The person this slice belongs to, as a lowercase UUID string. `nil`
    /// means the user ("me").
    let personUUID: String?

    /// Relative weight for this person. Defaults to 1 (equal split).
    let shares: Int

    /// Exact consumed amount in the captured currency, or nil to use `shares`.
    let owedAmount: Double?

    /// Amount this party fronted, in the captured currency. nil = paid nothing.
    let paidAmount: Double?

    init(personUUID: String?, shares: Int, owedAmount: Double? = nil, paidAmount: Double? = nil) {
        self.personUUID = personUUID
        self.shares = max(shares, 0)
        self.owedAmount = owedAmount.map { abs($0) }
        self.paidAmount = paidAmount.map { abs($0) }
    }

    /// Convenience initialiser from a typed `UUID?` (nil = me). Normalises to
    /// the lowercase-string storage form.
    init(person: UUID?, shares: Int, owedAmount: Double? = nil, paidAmount: Double? = nil) {
        self.init(
            personUUID: person?.uuidString.lowercased(),
            shares: shares,
            owedAmount: owedAmount,
            paidAmount: paidAmount
        )
    }

    /// The typed person id, or `nil` for the user ("me").
    var personID: UUID? {
        guard let personUUID else { return nil }
        return UUID(uuidString: personUUID)
    }

    /// This entry's party, for the settle-up and badge code.
    var party: SplitPartyID {
        personID.map { .person($0) } ?? .me
    }
}

// MARK: - Cent-exact money helpers (#540)

/// Money arithmetic for the split editor, kept out of the view so the rules
/// are unit-testable (the lesson from #488: a decision that lives in a `View`
/// can only be verified by a human driving the app).
///
/// Everything works in integer cents and converts back, so distributing 100
/// across 3 gives 33.34 / 33.33 / 33.33 and sums back to exactly 100 rather
/// than drifting by a cent the user then has to hunt.
enum SplitMath {
    /// Two amounts are the same money when they are within half a cent.
    static let epsilon = 0.005

    static func cents(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }

    static func amount(cents: Int) -> Double {
        Double(cents) / 100
    }

    /// Split `total` into `count` cent-exact parts. The remainder cents go to
    /// the earliest parts, so the list always sums back to `total`.
    static func evenSplit(total: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let whole = cents(total)
        let base = whole / count
        let remainder = whole - base * count
        return (0..<count).map { index in
            amount(cents: base + (index < abs(remainder) ? (remainder < 0 ? -1 : 1) : 0))
        }
    }

    /// Split `total` in proportion to `weights`, cent-exact. Used when the
    /// editor moves from share weights to typed amounts: the figures it seeds
    /// have to be the ones the shares were already showing, to the cent.
    static func weightedSplit(total: Double, weights: [Int]) -> [Double] {
        let sum = weights.reduce(0) { $0 + max($1, 0) }
        guard sum > 0 else { return weights.map { _ in 0 } }
        let whole = cents(total)
        var parts = weights.map { whole * max($0, 0) / sum }
        var leftover = whole - parts.reduce(0, +)
        // The odd cents go to the heaviest weights first, so a 1:2 split of
        // 100 reads 33.33 / 66.67 the way it would be written by hand rather
        // than 33.34 / 66.66.
        let byWeight = weights.indices.sorted { weights[$0] > weights[$1] }
        var cursor = 0
        while leftover != 0 && !parts.isEmpty {
            let step = leftover > 0 ? 1 : -1
            parts[byWeight[cursor % byWeight.count]] += step
            leftover -= step
            cursor += 1
        }
        return parts.map { amount(cents: $0) }
    }

    /// Whether `amounts` already add up to `total`.
    static func isBalanced(_ amounts: [Double], total: Double) -> Bool {
        abs(amounts.reduce(0, +) - total) < epsilon
    }

    /// What is still unassigned: positive when money is left, negative when
    /// the parts overshoot the total.
    static func remainder(_ amounts: [Double], total: Double) -> Double {
        amount(cents: cents(total) - amounts.reduce(0) { $0 + cents($1) })
    }

    /// Spread the difference between `amounts` and `total` so the parts add up.
    ///
    /// Untouched parts absorb it first: when some entries are still zero, the
    /// whole remainder goes to those, which is what "I typed mine, give the
    /// rest to the others" means. With every entry filled in, the difference
    /// spreads across all of them instead.
    static func spread(_ amounts: [Double], total: Double) -> [Double] {
        guard !amounts.isEmpty else { return amounts }
        let targets = amounts.indices.filter { cents(amounts[$0]) == 0 }
        let receivers = targets.isEmpty ? Array(amounts.indices) : targets
        let untouched = amounts.indices.filter { !receivers.contains($0) }
            .reduce(0) { $0 + cents(amounts[$1]) }
        let pot = cents(total) - untouched
        // Never hand out a negative pot by zeroing everyone: if the fixed
        // entries already exceed the total there is nothing to spread, so
        // leave the amounts alone and let the pill keep reporting the overage.
        guard pot >= 0 else { return amounts }
        let parts = evenSplit(total: amount(cents: pot), count: receivers.count)
        var result = amounts
        for (offset, index) in receivers.enumerated() {
            result[index] = parts[offset]
        }
        return result
    }
}

// MARK: - Settle-up breakdowns (#540)

extension LocalExpense {
    /// Converts a stored per-party amount (captured currency, unsigned) into
    /// the caller's basis. The basis carries the sign, so a refund's negative
    /// basis flips the parts without any stored amount ever going negative.
    private func splitScale(basis: Double) -> Double {
        guard originalAmount > 0 else { return 0 }
        return basis / originalAmount
    }

    /// Who fronted the money, in the caller's basis.
    ///
    /// Falls back to the single `paidByPersonUUID` (nil = the user) whenever no
    /// entry carries a `paidAmount`, so every row written before #540 reads
    /// exactly as it did.
    func paidBreakdown(basis: Double) -> [(party: SplitPartyID, amount: Double)] {
        let payers = splits.filter { ($0.paidAmount ?? 0) > 0 }
        guard !payers.isEmpty else {
            return [(paidByPersonUUID.map { .person($0) } ?? .me, basis)]
        }
        let scale = splitScale(basis: basis)
        return payers.map { ($0.party, ($0.paidAmount ?? 0) * scale) }
    }

    /// Who consumed the bill, in the caller's basis.
    ///
    /// Three readings, in order: exact amounts when any entry carries one,
    /// share weights otherwise, and — for an expense with no usable split at
    /// all — the USER in full. That last case is load-bearing: an unsplit bill
    /// someone else fronted is a debt the user owes them (#504), and both
    /// `myShareSGD` and `TripSettlement` have to agree on it.
    func owedBreakdown(basis: Double) -> [(party: SplitPartyID, amount: Double)] {
        let entries = splits
        let exact = entries.filter { ($0.owedAmount ?? 0) > 0 }
        if !exact.isEmpty {
            let scale = splitScale(basis: basis)
            return exact.map { ($0.party, ($0.owedAmount ?? 0) * scale) }
        }
        let totalShares = entries.reduce(0) { $0 + max($1.shares, 0) }
        guard totalShares > 0 else { return [(.me, basis)] }
        return entries.compactMap { entry in
            let shares = max(entry.shares, 0)
            guard shares > 0 else { return nil }
            return (entry.party, basis * Double(shares) / Double(totalShares))
        }
    }

    /// The parties who fronted money, in stored order.
    var payerParties: [SplitPartyID] {
        let payers = splits.filter { ($0.paidAmount ?? 0) > 0 }
        guard !payers.isEmpty else {
            return [paidByPersonUUID.map { .person($0) } ?? .me]
        }
        return payers.map(\.party)
    }

    /// Whether more than one party fronted money for this bill.
    var hasMultiplePayers: Bool {
        splits.filter { ($0.paidAmount ?? 0) > 0 }.count > 1
    }

    /// Whether this bill's slices were entered as exact amounts rather than
    /// share weights.
    var splitsByExactAmount: Bool {
        splits.contains { ($0.owedAmount ?? 0) > 0 }
    }
}
