import Foundation
import SwiftData

/// Idempotency ledger for the email-to-itinerary ingestion (#143).
///
/// Each row records one IMAP message we've already handled, keyed by a stable
/// identity so the same email is never processed twice across repeated
/// fetches. We key on the RFC 822 `Message-Id` header when present (globally
/// unique, survives the message being re-indexed), and fall back to a
/// composite of the mailbox UIDVALIDITY + UID otherwise.
///
/// Additive-only model — safe to add to the schema on existing installs.
@Model
final class LocalProcessedEmail {
    /// Stable identity for the message. Prefer the `Message-Id` header; fall
    /// back to "uidvalidity:uid" when the header is missing. Unique so an
    /// insert of a duplicate fails loudly rather than silently double-adding.
    @Attribute(.unique) var messageKey: String

    /// The IMAP UID at the time we processed it (diagnostic only — UIDs can
    /// be reassigned if UIDVALIDITY changes, which is why `messageKey` is the
    /// real key).
    var uid: Int

    /// UIDVALIDITY of the mailbox when processed (diagnostic).
    var uidValidity: Int

    var processedAt: Date

    init(
        messageKey: String,
        uid: Int,
        uidValidity: Int,
        processedAt: Date = Date()
    ) {
        self.messageKey = messageKey
        self.uid = uid
        self.uidValidity = uidValidity
        self.processedAt = processedAt
    }
}
