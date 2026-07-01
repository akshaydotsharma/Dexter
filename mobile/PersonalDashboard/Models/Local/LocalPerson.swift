import Foundation
import SwiftData

/// Local-first SwiftData model for a person an expense can be tagged with
/// (#183). Answers "what did I spend on Sarah?".
///
/// A person is just a reusable name + a display colour for its chip. Expenses
/// link back via `LocalExpense.personUUID` (no SwiftData relationship — the
/// codebase joins by `clientUUID` everywhere for offline-resilience). The
/// person's name is also denormalised onto the expense row so a row stays
/// self-describing if the person is later deleted.
///
/// Same `clientUUID` convention as `LocalTrip`.
@Model
final class LocalPerson {
    @Attribute(.unique) var clientUUID: UUID

    /// Display name (e.g. "Sarah"). Required. Matched case-insensitively by
    /// `PersonService.findOrCreate` so the same name reuses one record.
    var name: String

    /// Hex string (e.g. "10B981") driving the chip colour. Assigned round-robin
    /// on create from a small palette so distinct people read distinctly.
    var colorHex: String

    var createdAt: Date

    init(
        clientUUID: UUID = UUID(),
        name: String,
        colorHex: String,
        createdAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
    }
}
