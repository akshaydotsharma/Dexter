import Foundation
import SwiftData
import CryptoKit

/// A Dexter-only decision about a calendar event (#689): hide it from the
/// Planner, or treat it as declined.
///
/// Dexter never writes to a calendar, so this row is the whole of the
/// decision. The organiser is not told and the source calendar does not
/// change. The row syncs, so a hide on the phone also hides on the Mac.
///
/// A new additive `@Model`: one new table, nothing above it changes. Every
/// default sits on the declaration (#555).
///
/// ### How an event is matched
///
/// `eventKey` is the event's `calendarItemExternalIdentifier`, the iCalendar
/// UID that CalDAV (iCloud, Google) and Exchange give the event on the server.
/// It is the same on every device, and every occurrence of a repeating event
/// shares it. When a calendar gives no external id (a local calendar not yet
/// synced), the key falls back to `local:` plus the device-local
/// `eventIdentifier`, which still works on this device.
///
/// `occurrenceStart` is nil for the whole event or the whole series. For one
/// occurrence of a repeating event it is `EKEvent.occurrenceDate`: the
/// ORIGINAL start of that occurrence. A moved occurrence keeps its original
/// occurrence date, so a decision about it still matches after the move.
@Model
final class LocalEventOverride {
    /// Derived from (action, key, occurrence) by `EventOverrideID.make`, not
    /// minted, so the same decision on two devices is ONE record and a second
    /// write revives the row instead of adding a duplicate (#514).
    @Attribute(.unique) var clientUUID: String = ""

    var eventKey: String = ""

    /// Nil: the whole event or the whole series. Otherwise one occurrence.
    var occurrenceStart: Date? = nil

    /// `EventOverrideAction.rawValue`.
    var action: String = "hidden"

    /// Saved for the restore list, because the event may no longer load.
    var title: String = ""
    var eventStart: Date = Date(timeIntervalSince1970: 0)
    var calendarTitle: String = ""
    /// True when the decision covers every occurrence of a repeating event,
    /// for the restore list's wording. A one-off event also has a nil
    /// `occurrenceStart`, so that field alone cannot say this.
    var appliesToSeries: Bool = false

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Set by Undo and by Restore. A later decision revives the same row.
    var deletedAt: Date? = nil

    init(
        clientUUID: String,
        eventKey: String,
        occurrenceStart: Date?,
        action: EventOverrideAction,
        title: String,
        eventStart: Date,
        calendarTitle: String,
        appliesToSeries: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.clientUUID = clientUUID
        self.eventKey = eventKey
        self.occurrenceStart = occurrenceStart
        self.action = action.rawValue
        self.title = title
        self.eventStart = eventStart
        self.calendarTitle = calendarTitle
        self.appliesToSeries = appliesToSeries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var actionEnum: EventOverrideAction { EventOverrideAction(rawValue: action) ?? .hidden }

    /// The value the engine reads.
    var rule: EventOverrideRule {
        EventOverrideRule(id: clientUUID, eventKey: eventKey, occurrenceStart: occurrenceStart, action: actionEnum)
    }
}

enum EventOverrideAction: String, Codable, Sendable {
    case hidden
    case declined
}

/// Builds the one id a decision can have.
enum EventOverrideID {
    static func make(action: EventOverrideAction, eventKey: String, occurrenceStart: Date?) -> String {
        let occ = occurrenceStart.map { String(Int($0.timeIntervalSince1970.rounded())) } ?? "series"
        let raw = "\(action.rawValue)|\(eventKey)|\(occ)"
        let hex = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "eo-" + hex.prefix(32)
    }
}
