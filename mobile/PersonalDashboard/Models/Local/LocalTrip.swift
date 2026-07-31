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

    // MARK: - Destination cover photography (#428)
    //
    // Five fields, all OPTIONAL with a nil default and nothing removed, for the
    // same reason `participantsData` above is: the SwiftData lightweight
    // migration on an existing install must not be able to fail, and a failure
    // here loses the whole store. Nil on every pre-existing trip means "no cover
    // has ever been attempted", which is exactly the truth.
    //
    // The bytes deliberately do NOT live here. All five existing image-bearing
    // models store a path, and the sync oplog carries full row JSON on upsert,
    // so a `Data` field would put a 300 KB JPEG into the log on every edit.

    /// Relative path to the cached cover, e.g. `trip-covers/<uuid>.jpg`.
    ///
    /// Relative, never absolute: the app's container path changes on reinstall,
    /// so an absolute path would break silently. Matches
    /// `LocalNoteImage.relativePath`.
    ///
    /// DEVICE-LOCAL. The filename is a UUID minted on whichever device fetched
    /// the cover, so a peer receiving this row over sync has the path and not the
    /// file. `coverImageSourceURL` below is the portable identity; this is not.
    var coverImagePath: String?

    /// The remote URL the cover was fetched from.
    ///
    /// This, not the path, is what identifies a cover across devices, which is
    /// what makes the missing-file case self-healing rather than data loss: a
    /// cover is always re-derivable from here.
    var coverImageSourceURL: String?

    /// Credit line for the photograph ("Artist — License"), and the link to its
    /// Commons file page. Held so the credit can be surfaced wherever it is owed;
    /// the tile itself never draws on the photograph.
    var coverImageAttribution: String?
    var coverImageAttributionURL: String?

    /// Three-valued fetch state: nil (never attempted), `resolved`, `none`
    /// (searched, nothing suitable found), `failed` (transient, worth retrying).
    ///
    /// `none` is load-bearing and is why this is not a Bool: without it, a trip
    /// called "Work offsite" — which has no destination to photograph — would be
    /// re-searched on every launch forever.
    ///
    /// `String?` rather than an enum-backed `Int` on purpose. These values get
    /// read by hand during triage, in the sync oplog and in an exported
    /// `manifest.json`, and `2` says nothing there.
    var coverImageState: String?

    var createdAt: Date
    var updatedAt: Date

    init(
        clientUUID: UUID = UUID(),
        name: String,
        startDate: Date,
        endDate: Date,
        notes: String = "",
        participantsData: Data? = nil,
        coverImagePath: String? = nil,
        coverImageSourceURL: String? = nil,
        coverImageAttribution: String? = nil,
        coverImageAttributionURL: String? = nil,
        coverImageState: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
        self.participantsData = participantsData
        self.coverImagePath = coverImagePath
        self.coverImageSourceURL = coverImageSourceURL
        self.coverImageAttribution = coverImageAttribution
        self.coverImageAttributionURL = coverImageAttributionURL
        self.coverImageState = coverImageState
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
