import Foundation
import SwiftData

/// One visible entry in the email-ingestion activity log (#143). Records what
/// happened to each forwarded email so the user can see recent auto-adds and
/// skips, and so the undo action has the item UUIDs to delete.
///
/// Additive-only model — safe to add to the schema on existing installs.
@Model
final class LocalEmailIngestLog {
    @Attribute(.unique) var clientUUID: UUID

    /// Subject line of the source email (trimmed). Empty when none.
    var subject: String

    /// From header of the source email (display form). Empty when unknown.
    var sender: String

    /// `EmailIngestOutcome.rawValue` — "added" | "skipped" | "failed".
    /// Stored as String to keep the schema migration-safe (read via
    /// `outcomeEnum`).
    var outcome: String

    /// Human summary of what happened ("Added 2 items to Vietnam" /
    /// "No matching trip" / error text).
    var summary: String

    /// `LocalTrip.clientUUID` the items were added to, when `outcome == added`.
    /// nil for skips/failures. Drives the per-entry undo target.
    var tripUUID: UUID?

    /// Comma-joined `LocalItineraryItem.clientUUID` strings that were added,
    /// so undo can delete exactly those rows. Empty when nothing was added.
    var addedItemUUIDs: String

    /// Comma-joined `LocalExpense.clientUUID` strings that were logged from this
    /// email (#177), so undo can delete exactly those rows too. Additive field
    /// with a default, so the SwiftData migration on existing installs stays
    /// lightweight. Empty when no expense was logged.
    var addedExpenseUUIDs: String = ""

    /// Diagnostics (#143): first ~1000 chars of the parsed body the model
    /// actually received, so a parser miss ("just a signature") is
    /// distinguishable from a real no-match. Additive field with a default,
    /// so the SwiftData migration on existing installs stays lightweight.
    var debugBody: String = ""

    /// Diagnostics (#143): the compact trip-context string the model was given
    /// for matching. Confirms whether the right trip was even visible.
    var debugTripContext: String = ""

    var createdAt: Date

    init(
        clientUUID: UUID = UUID(),
        subject: String,
        sender: String,
        outcome: EmailIngestOutcome,
        summary: String,
        tripUUID: UUID? = nil,
        addedItemUUIDs: [UUID] = [],
        addedExpenseUUIDs: [UUID] = [],
        debugBody: String = "",
        debugTripContext: String = "",
        createdAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.subject = subject
        self.sender = sender
        self.outcome = outcome.rawValue
        self.summary = summary
        self.tripUUID = tripUUID
        self.addedItemUUIDs = addedItemUUIDs.map { $0.uuidString.lowercased() }.joined(separator: ",")
        self.addedExpenseUUIDs = addedExpenseUUIDs.map { $0.uuidString.lowercased() }.joined(separator: ",")
        self.debugBody = debugBody
        self.debugTripContext = debugTripContext
        self.createdAt = createdAt
    }

    var outcomeEnum: EmailIngestOutcome {
        EmailIngestOutcome(rawValue: outcome) ?? .failed
    }

    /// Parsed list of added item UUIDs (for undo).
    var addedItemUUIDList: [UUID] {
        addedItemUUIDs
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
    }

    /// Parsed list of logged expense UUIDs (for undo, #177).
    var addedExpenseUUIDList: [UUID] {
        addedExpenseUUIDs
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }
    }
}

/// What happened to a single ingested email.
enum EmailIngestOutcome: String, CaseIterable, Sendable {
    case added
    case skipped
    case failed

    var displayName: String {
        switch self {
        case .added:   return "Added"
        case .skipped: return "Skipped"
        case .failed:  return "Failed"
        }
    }

    var icon: String {
        switch self {
        case .added:   return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.left.circle"
        case .failed:  return "exclamationmark.triangle"
        }
    }
}
