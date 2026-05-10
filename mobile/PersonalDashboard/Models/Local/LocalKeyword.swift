import Foundation
import SwiftData

/// Local-first SwiftData model for a personal-vocabulary entry.
///
/// The user teaches the assistant words it might mishear (company names,
/// product names, personal jargon) so the LLM can prefer those terms when
/// speech-to-text gets them wrong. `term` is the canonical word the user
/// wants the assistant to recognise; `notes` is free-form context the user
/// types to explain when to apply the term.
///
/// Identity follows the same `clientUUID` convention as `LocalTodo` /
/// `LocalNote` / `LocalList` so future cross-references stay consistent.
@Model
final class LocalKeyword {
    /// Stable identity. Generated locally on creation. Unique within the SwiftData store.
    @Attribute(.unique) var clientUUID: UUID

    /// Canonical word or phrase the user wants the assistant to recognise.
    var term: String

    /// Free-form context the user types to disambiguate the term — what it
    /// means, when to prefer it. Empty string when the user didn't supply any.
    var notes: String

    var createdAt: Date
    var updatedAt: Date

    init(
        clientUUID: UUID = UUID(),
        term: String,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.term = term
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
