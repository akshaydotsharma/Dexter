import Foundation
import SwiftData

/// Local-first SwiftData model for a todo. `clientUUID` is the stable
/// identity; the server's integer primary key is irrelevant on the iOS side.
@Model
final class LocalTodo {
    /// Stable identity. Generated locally on creation. Unique within the SwiftData store.
    @Attribute(.unique) var clientUUID: UUID

    var title: String
    var todoDescription: String?
    var completed: Bool
    var dueDate: Date?
    var tag: String?
    var position: Int?

    /// Optional street / postal address for this task's location. Empty when
    /// none. Stored with a default so adding it to an existing install is a
    /// safe lightweight migration (no data loss). Shown as a plain text line
    /// on the task row; the tappable map affordance lives on `googleMapsLink`.
    var address: String = ""

    /// Optional Google Maps URL for this task's location. Empty when none.
    /// Stored with a default for safe migration. Read via the DTO's `mapsURL`;
    /// the row shows a tappable "MAP" chip only when it resolves to a URL.
    var googleMapsLink: String = ""

    /// Task priority as a raw `Int` (see `TaskPriority`). Local-only, stored
    /// with a default so adding it to an existing install is a safe lightweight
    /// migration (no data loss). Drives the colored left-edge bar on task rows.
    var priority: Int = 0

    /// Whether to raise a local notification at `dueDate` (#444). Stored with a
    /// default so adding it to an existing install is a safe lightweight
    /// migration.
    ///
    /// Only ever meaningful alongside a `dueDate` — there is no separate reminder
    /// time, the due moment IS the reminder moment. The editor keeps the two in
    /// step by clearing this when the due date is cleared, and
    /// `TaskReminderScheduler` treats a nil `dueDate` as disarmed regardless, so
    /// a stale `true` from an older write can never schedule anything.
    var remindMe: Bool = false

    /// When the person dealt with this task's reminder notification, on whichever
    /// device they did it (#444).
    ///
    /// Exists because notification dismissal is DEVICE-LOCAL and does not sync,
    /// while the task does. Without it, a second device that receives an armed
    /// reminder after its moment has passed cannot tell the difference between "you
    /// have not seen this yet" and "you already swiped it away on your phone", so it
    /// either always re-notifies or never does. Set when the notification is
    /// dismissed or tapped, and it syncs, which is what lets the other device skip a
    /// late delivery for something already handled.
    ///
    /// Completing, deleting, or disarming the task are separate signals and are
    /// already checked on their own — this covers only "the banner was dealt with
    /// but the task itself was left alone".
    var reminderClearedAt: Date? = nil

    var version: Int64

    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    var needsSync: Bool

    init(
        clientUUID: UUID = UUID(),
        title: String,
        todoDescription: String? = nil,
        completed: Bool = false,
        dueDate: Date? = nil,
        tag: String? = nil,
        position: Int? = nil,
        address: String = "",
        googleMapsLink: String = "",
        priority: Int = 0,
        remindMe: Bool = false,
        reminderClearedAt: Date? = nil,
        version: Int64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        needsSync: Bool = true
    ) {
        self.clientUUID = clientUUID
        self.title = title
        self.todoDescription = todoDescription
        self.completed = completed
        self.dueDate = dueDate
        self.tag = tag
        self.position = position
        self.address = address
        self.googleMapsLink = googleMapsLink
        self.priority = priority
        self.remindMe = remindMe
        self.reminderClearedAt = reminderClearedAt
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.needsSync = needsSync
    }

    /// Project to the view-facing DTO. ViewModels and views consume `Todo`
    /// (struct, value semantics) rather than the `LocalTodo` model directly,
    /// so SwiftUI updates are predictable and equality is per-snapshot.
    func toDTO() -> Todo {
        Todo(
            id: clientUUID,
            title: title,
            description: todoDescription,
            completed: completed,
            dueDate: dueDate,
            tag: tag,
            position: position,
            version: version,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
            address: address,
            googleMapsLink: googleMapsLink,
            priority: priority,
            remindMe: remindMe,
            reminderClearedAt: reminderClearedAt
        )
    }
}
