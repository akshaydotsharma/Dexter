import Foundation
import SwiftData

/// Errors thrown by `PersonService`. Only surfaces empty-name and
/// persistence failures — callers rarely branch on them.
enum PersonServiceError: LocalizedError {
    case emptyName
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .emptyName:            return "Person name can't be empty."
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PersonServiceError.emptyName }
        person.name = trimmed
        try save()
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
