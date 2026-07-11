import Foundation

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
struct ExpenseSplitEntry: Codable, Equatable, Hashable {
    /// The person this slice belongs to, as a lowercase UUID string. `nil`
    /// means the user ("me").
    let personUUID: String?

    /// Relative weight for this person. Defaults to 1 (equal split).
    let shares: Int

    init(personUUID: String?, shares: Int) {
        self.personUUID = personUUID
        self.shares = max(shares, 0)
    }

    /// Convenience initialiser from a typed `UUID?` (nil = me). Normalises to
    /// the lowercase-string storage form.
    init(person: UUID?, shares: Int) {
        self.init(personUUID: person?.uuidString.lowercased(), shares: shares)
    }

    /// The typed person id, or `nil` for the user ("me").
    var personID: UUID? {
        guard let personUUID else { return nil }
        return UUID(uuidString: personUUID)
    }
}
