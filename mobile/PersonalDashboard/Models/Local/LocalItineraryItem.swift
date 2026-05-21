import Foundation
import SwiftData

/// Category of an itinerary item. Stored on `LocalItineraryItem.kind` as the
/// `rawValue` so SwiftData stays on plain `String` (no custom-codable
/// migrations to worry about). The skeleton ships four kinds; new ones can be
/// added without a schema change.
enum ItineraryKind: String, CaseIterable, Identifiable, Hashable {
    case stay
    case activity
    case place
    case restaurant

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stay:       return "Stay"
        case .activity:   return "Activity"
        case .place:      return "Place"
        case .restaurant: return "Restaurant"
        }
    }

    /// SF Symbol used in row icons and the kind picker chips.
    var icon: String {
        switch self {
        case .stay:       return "bed.double"
        case .activity:   return "figure.walk"
        case .place:      return "mappin.and.ellipse"
        case .restaurant: return "fork.knife"
        }
    }
}

/// One row on a trip's day-by-day timeline. Belongs to a `LocalTrip` via
/// `tripUUID` foreign key (no SwiftData relationship — keeps the schema
/// boring and cascade-on-delete explicit, matching the rest of the app).
@Model
final class LocalItineraryItem {
    @Attribute(.unique) var clientUUID: UUID

    /// `LocalTrip.clientUUID` this item belongs to.
    var tripUUID: UUID

    /// The day this item lives on. Always normalised to `Calendar.startOfDay`
    /// so grouping by day is just a key-equality check.
    var dayDate: Date

    /// `ItineraryKind.rawValue`. Stored as a String to keep SwiftData happy.
    /// Read via `kindEnum` for type-safe access.
    var kind: String

    /// Short title (e.g. "Hanoi Hotel", "Halong Bay tour"). Required.
    var title: String

    /// Free-form notes. Empty when none.
    var notes: String

    /// Optional start time for this item. Stored as a full `Date` so the
    /// hours/minutes always round-trip cleanly with the day they belong to
    /// (the editor combines `dayDate` + the picked time-of-day before
    /// persisting). `nil` means the item is "untimed" and renders with a
    /// hollow marker plus no time label. The day grouping continues to use
    /// `dayDate` so timezone shifts in `startTime` can't accidentally move
    /// an item to a neighbouring day.
    var startTime: Date?

    /// Ordering within a single day. Lower numbers render first; ties are
    /// broken by `createdAt`. Skeleton uses append-on-create (max + 1); a
    /// drag-to-reorder UI is a follow-up.
    var sortOrder: Int

    var createdAt: Date
    var updatedAt: Date

    init(
        clientUUID: UUID = UUID(),
        tripUUID: UUID,
        dayDate: Date,
        kind: ItineraryKind,
        title: String,
        notes: String = "",
        startTime: Date? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.tripUUID = tripUUID
        self.dayDate = dayDate
        self.kind = kind.rawValue
        self.title = title
        self.notes = notes
        self.startTime = startTime
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Type-safe accessor backed by the stored raw `kind` string. Falls back
    /// to `.activity` if the stored value can't be decoded (e.g. an older
    /// schema added a kind that was later removed).
    var kindEnum: ItineraryKind {
        get { ItineraryKind(rawValue: kind) ?? .activity }
        set { kind = newValue.rawValue }
    }
}
