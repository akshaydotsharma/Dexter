import Foundation
import SwiftData

/// Errors thrown by `PersonService`. Surfaces an empty name, a rename onto a
/// name another person already holds (#530), and persistence failures.
enum PersonServiceError: LocalizedError {
    case emptyName
    case nameTaken(String)
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .emptyName:            return "Person name can't be empty."
        case .nameTaken(let name):  return "A person named \(name) already exists."
        case .persistence(let err): return err.localizedDescription
        }
    }
}

/// CRUD + find-or-create over `LocalPerson` (#183). Backs the Person picker
/// in the AddExpense sheet, the Person filter, and the AI's find-or-create by
/// name. Operates on the shared SwiftData context.
///
/// Structure mirrors `ExpenseService`: `@MainActor` (touches the shared
/// store), a `default()` factory, and a private `save()` that wraps errors.
@MainActor
struct PersonService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    static func `default`() -> PersonService {
        PersonService(store: .shared)
    }

    /// Colours assigned round-robin to new people so distinct people read
    /// distinctly in chips. Hex strings (no leading `#`) parsed by the chip
    /// view via `Color(hex:)`.
    static let palette: [String] = [
        "10B981", // emerald
        "6366F1", // indigo
        "F59E0B", // amber
        "EC4899", // pink
        "14B8A6", // teal
        "8B5CF6", // violet
        "EF4444", // red
        "3B82F6", // blue
    ]

    // MARK: - Read

    /// All people, alphabetical (case-insensitive) so the picker is scannable.
    func all() throws -> [LocalPerson] {
        let descriptor = FetchDescriptor<LocalPerson>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        return try store.context.fetch(descriptor)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Find-or-create

    /// Return the existing person whose name matches `name`
    /// (case-insensitive, trimmed), or create one. Keeps "Sarah" typed twice
    /// pointing at one record. Throws on an empty name.
    @discardableResult
    func findOrCreate(name: String) throws -> LocalPerson {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PersonServiceError.emptyName }

        if let existing = try all().first(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            return existing
        }

        // Assign the next palette colour based on the current count so early
        // people spread across the palette instead of clustering on one hue.
        let count = (try? all().count) ?? 0
        let colorHex = Self.palette[count % Self.palette.count]

        let row = LocalPerson(name: trimmed, colorHex: colorHex)
        store.context.insert(row)
        try save()
        return row
    }

    // MARK: - Update / delete

    func update(_ person: LocalPerson, name: String) throws {
        try rename(person, to: name)
    }

    /// Rename a person in place, keeping their identity (#530).
    ///
    /// Everything downstream of a person joins by `clientUUID` — the trip's
    /// `participantPersonUUIDs`, `LocalExpense.personUUID`,
    /// `LocalExpense.paidByPersonUUID` and every `ExpenseSplitEntry.personUUID` —
    /// so a rename must not mint a new record. That is exactly what the old
    /// remove-then-add workaround did, which is why it detached the settle-up
    /// balances and left the splits rendering "Someone".
    ///
    /// Two things happen here and they must land in ONE save, so a single sync
    /// pass carries both and no peer can observe the halfway state:
    ///
    /// 1. `LocalPerson.name` changes. `colorHex` deliberately does not: the chip
    ///    colour is how the user recognises the person, and a rename is not a
    ///    new person.
    /// 2. `LocalExpense.personName` is backfilled on every row tagged with this
    ///    person. That field is a denormalised copy kept so an expense stays
    ///    self-describing after the person is DELETED, so it is refreshed rather
    ///    than removed.
    ///
    /// A rename onto a name another person already holds is rejected, not
    /// merged. A merge would have to repoint `personUUID`, `paidByPersonUUID`,
    /// every split entry and every trip's participant list, and it cannot be
    /// undone — it belongs in its own change, not hidden inside a rename.
    /// Renaming a person to their own name in a different case is allowed and
    /// is not a collision.
    func rename(_ person: LocalPerson, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PersonServiceError.emptyName }

        let clash = try all().first { other in
            other.clientUUID != person.clientUUID
                && other.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }
        if let clash { throw PersonServiceError.nameTaken(clash.name) }

        guard person.name != trimmed else { return }

        person.name = trimmed
        try backfillTaggedExpenses(personUUID: person.clientUUID, name: trimmed)
        try save()
    }

    /// Refresh the denormalised `personName` on every expense tagged with this
    /// person. Rows tagged with anyone else, and rows with no person at all, are
    /// not touched.
    ///
    /// Fetched with a predicate rather than by walking every expense: a store
    /// with a few years of statement imports holds thousands of rows and only a
    /// handful carry a person tag.
    private func backfillTaggedExpenses(personUUID: UUID, name: String) throws {
        let descriptor = FetchDescriptor<LocalExpense>(
            predicate: #Predicate { $0.personUUID == personUUID }
        )
        let tagged = try store.context.fetch(descriptor)
        for expense in tagged {
            expense.personName = name
        }
    }

    /// Delete a person. Expenses that referenced it keep their denormalised
    /// `personName` (self-describing) but lose the live link — matching the
    /// codebase's "denormalised name survives a delete" pattern. Callers that
    /// want to unlink rows first can do so before calling this.
    func delete(_ person: LocalPerson) throws {
        store.context.delete(person)
        try save()
    }

    // MARK: - Helpers

    private func save() throws {
        do {
            try store.context.save()
        } catch {
            throw PersonServiceError.persistence(error)
        }
    }
}
