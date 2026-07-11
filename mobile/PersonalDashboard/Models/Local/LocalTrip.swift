import Foundation
import SwiftData

/// Local-first SwiftData model for a trip in the Itineraries section (#104).
///
/// A trip has a destination name and a date range. Day-by-day timeline items
/// (stays, activities, places, restaurants) are stored in `LocalItineraryItem`
/// and joined back to this trip via `tripUUID` (no SwiftData relationship).
/// Same `clientUUID` convention as the rest of the local models.
@Model
final class LocalTrip {
    @Attribute(.unique) var clientUUID: UUID

    /// Destination or trip title (e.g. "Vietnam"). Required.
    var name: String

    /// First day of the trip, inclusive. Stored at `Calendar.startOfDay`.
    var startDate: Date

    /// Last day of the trip, inclusive. Stored at `Calendar.startOfDay`.
    var endDate: Date

    /// Free-form notes the user types about the trip. Empty when none.
    var notes: String

    /// Trip participants for expense splitting (#258). JSON-encoded array of
    /// participant person UUIDs (lowercase UUID strings, for stable
    /// round-tripping), following the `LocalList.itemsData` stored-Data +
    /// computed-property pattern. OPTIONAL with a nil default so the SwiftData
    /// lightweight migration on existing installs can't fail (project rule:
    /// only ADD fields, always with a default). Nil / empty on every
    /// pre-existing trip → no participants, expenses stay unsplit exactly as
    /// before. The people themselves live in `LocalPerson` (reused, not
    /// duplicated); this only stores which of them are on the trip.
    var participantsData: Data?

    var createdAt: Date
    var updatedAt: Date

    init(
        clientUUID: UUID = UUID(),
        name: String,
        startDate: Date,
        endDate: Date,
        notes: String = "",
        participantsData: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.participantsData = participantsData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The trip's participants as typed person UUIDs. Decodes on read and
    /// encodes on write, mirroring `LocalList.items`. Decoding failures fall
    /// back to an empty list rather than crashing. Order is preserved so the
    /// chips render in the order the user added people.
    var participantPersonUUIDs: [UUID] {
        get { LocalTrip.decodeParticipants(participantsData) }
        set { participantsData = LocalTrip.encodeParticipants(newValue) }
    }

    private static func encodeParticipants(_ ids: [UUID]) -> Data? {
        guard !ids.isEmpty else { return nil }
        let strings = ids.map { $0.uuidString.lowercased() }
        return try? JSONEncoder().encode(strings)
    }

    private static func decodeParticipants(_ data: Data?) -> [UUID] {
        guard let data, !data.isEmpty else { return [] }
        let strings = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return strings.compactMap { UUID(uuidString: $0) }
    }
}
