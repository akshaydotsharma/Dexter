import Foundation
import SwiftData

/// Local-first SwiftData model for an expense (Finance v1 — issue #114).
///
/// Money is stored twice. `originalAmount + originalCurrency` is what the
/// user actually paid; `sgdAmount + fxRate` is the frozen home-currency
/// conversion captured at the moment of entry so monthly totals don't
/// retroactively drift when FX rates move. Same `clientUUID` convention as
/// the other local models, but stored as `String` because the AI tool
/// surface emits and consumes UUIDs as strings.
@Model
final class LocalExpense {
    /// Stable identity. Generated locally on creation. Unique within the store.
    @Attribute(.unique) var clientUUID: String

    /// User-visible spend date (the day the expense happened, not when it
    /// was logged). Normalised to `startOfDay` so daily groupings group
    /// cleanly across timezones.
    var date: Date

    /// `ExpenseCategory.rawValue`. Stored raw so adding a new category in
    /// the enum doesn't require a SwiftData migration.
    var category: String

    /// Merchant / vendor (e.g. "Starbucks"). Optional.
    var merchant: String?

    /// Free-form description. Named `expenseDescription` (not `description`)
    /// to avoid clashing with `CustomStringConvertible.description`.
    var expenseDescription: String?

    /// Amount in the original currency (what the user actually paid).
    var originalAmount: Double

    /// ISO 4217 code of the original currency (e.g. "SGD", "USD").
    var originalCurrency: String

    /// Converted SGD amount at capture time. Frozen — never recomputed.
    /// `sgdAmount == originalAmount * fxRate`.
    var sgdAmount: Double

    /// FX rate used at capture time. SGD passthrough is `1.0`.
    var fxRate: Double

    /// Payment method label (e.g. "Visa **1234", "Cash"). Optional.
    var paymentMethod: String?

    /// Relative path inside `Documents/receipts/<uuid>.jpg`. Phase B will
    /// write the image; Phase A always leaves this nil.
    var receiptImagePath: String?

    /// `ExpenseSource.rawValue`. Drives source-filter chips and analytics.
    var source: String

    var createdAt: Date

    // MARK: - Email-ingest dedup + trip linkage (#177)
    //
    // Populated ONLY by the email-to-expense path (`EmailToItinerary`), so a
    // re-forward / re-scan of the same receipt dedups against an existing row
    // instead of logging a second expense. All three are additive with defaults
    // so every existing call site (chat / voice / capture / manual) compiles
    // and behaves unchanged, and the SwiftData migration on existing installs
    // stays lightweight (add-with-default, never remove).
    //
    // - `dedupeKey`: the `ExpenseDedupe.signature(...)` stamped after insert.
    // - `sourceReference`: the normalised order / booking reference the
    //   signature preferred, kept so a later email can match it cheaply.
    // - `tripUUID`: `LocalTrip.clientUUID` when the expense is a travel fare
    //   linked to a matched trip; nil for a standalone purchase.
    var dedupeKey: String = ""
    var sourceReference: String = ""
    var tripUUID: UUID? = nil

    // MARK: - Person / Event tags (#183)
    //
    // Two optional groupings any expense can carry: a Person ("who was this
    // for / with") and an Event ("what occasion / trip"). Both are additive
    // with nil defaults so the SwiftData migration on existing installs stays
    // lightweight (add-with-default, never remove) and every existing call
    // site compiles unchanged.
    //
    // FK + denormalised name for each, mirroring the trip-linkage pattern
    // above: the UUID joins back to `LocalPerson` / `LocalEvent`, and the name
    // is duplicated onto the row so it stays self-describing if the person /
    // event is later deleted (and so filters / badges don't need a second
    // fetch to render a label).
    var personUUID: UUID? = nil
    var personName: String? = nil
    var eventUUID: UUID? = nil
    var eventName: String? = nil

    // MARK: - Dead-field parity with other LocalModels
    //
    // These are intentionally unused on Phase A. Kept so that the SwiftData
    // schema lines up with the other local models and any future sync /
    // migration story doesn't need a destructive change. Don't remove.
    var needsSync: Bool
    var version: Int

    init(
        clientUUID: String = UUID().uuidString.lowercased(),
        date: Date = Date(),
        category: String,
        merchant: String? = nil,
        expenseDescription: String? = nil,
        originalAmount: Double,
        originalCurrency: String,
        sgdAmount: Double,
        fxRate: Double,
        paymentMethod: String? = nil,
        receiptImagePath: String? = nil,
        source: String,
        createdAt: Date = Date(),
        dedupeKey: String = "",
        sourceReference: String = "",
        tripUUID: UUID? = nil,
        personUUID: UUID? = nil,
        personName: String? = nil,
        eventUUID: UUID? = nil,
        eventName: String? = nil,
        needsSync: Bool = false,
        version: Int = 0
    ) {
        self.clientUUID = clientUUID
        self.date = date
        self.category = category
        self.merchant = merchant
        self.expenseDescription = expenseDescription
        self.originalAmount = originalAmount
        self.originalCurrency = originalCurrency
        self.sgdAmount = sgdAmount
        self.fxRate = fxRate
        self.paymentMethod = paymentMethod
        self.receiptImagePath = receiptImagePath
        self.source = source
        self.createdAt = createdAt
        self.dedupeKey = dedupeKey
        self.sourceReference = sourceReference
        self.tripUUID = tripUUID
        self.personUUID = personUUID
        self.personName = personName
        self.eventUUID = eventUUID
        self.eventName = eventName
        self.needsSync = needsSync
        self.version = version
    }

    // MARK: - Convenience

    var categoryEnum: ExpenseCategory {
        ExpenseCategory(rawValue: category) ?? .other
    }

    var sourceEnum: ExpenseSource {
        ExpenseSource(rawValue: source) ?? .manual
    }
}
