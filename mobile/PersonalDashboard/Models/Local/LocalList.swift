import Foundation
import SwiftData

@Model
final class LocalList {
    @Attribute(.unique) var clientUUID: UUID
    var title: String
    /// Items are stored as JSON-encoded data so SwiftData (iOS 17.0)
    /// can persist them without a custom transformer. The view-facing
    /// `[ChecklistItem]` array is reconstructed on demand via toDTO().
    var itemsData: Data
    var position: Int?
    /// Per-list visual identity (#253). Both OPTIONAL with no non-nil default so
    /// the SwiftData lightweight migration on existing installs can't fail —
    /// adding nullable fields is the safe path (project rule: only ADD fields).
    /// `iconName` is an SF Symbol name, `colorHex` a palette key (the light-mode
    /// hex). Nil on every pre-existing list → the row renders with the default
    /// checklist symbol + teal via `ListAppearance` at read time.
    var iconName: String?
    var colorHex: String?
    var version: Int64
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var needsSync: Bool

    init(
        clientUUID: UUID = UUID(),
        title: String,
        items: [ChecklistItem] = [],
        position: Int? = nil,
        iconName: String? = nil,
        colorHex: String? = nil,
        version: Int64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        needsSync: Bool = true
    ) {
        self.clientUUID = clientUUID
        self.title = title
        self.itemsData = LocalList.encode(items)
        self.position = position
        self.iconName = iconName
        self.colorHex = colorHex
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsSync = needsSync
    }

    /// Read/write the items as a structured array. Decoding failures
    /// fall back to an empty list rather than crashing — better to show
    /// a recoverable empty state than a fatal error in production.
    var items: [ChecklistItem] {
        get { LocalList.decode(itemsData) }
        set { itemsData = LocalList.encode(newValue) }
    }

    func toDTO() -> Checklist {
        Checklist(
            id: clientUUID,
            title: title,
            items: items,
            position: position,
            iconName: iconName,
            colorHex: colorHex,
            version: version,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }

    private static func encode(_ items: [ChecklistItem]) -> Data {
        (try? JSONEncoder().encode(items)) ?? Data("[]".utf8)
    }

    private static func decode(_ data: Data) -> [ChecklistItem] {
        (try? JSONDecoder().decode([ChecklistItem].self, from: data)) ?? []
    }
}
