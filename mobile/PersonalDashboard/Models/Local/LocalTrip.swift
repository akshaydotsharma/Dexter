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

    var createdAt: Date
    var updatedAt: Date

    init(
        clientUUID: UUID = UUID(),
        name: String,
        startDate: Date,
        endDate: Date,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
