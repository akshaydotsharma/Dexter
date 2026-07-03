import Foundation
import SwiftData

/// A recurring-expense TEMPLATE (#236). Defines a fixed monthly charge (rent,
/// a subscription, insurance) once; `RecurringExpenseService` materialises it
/// into a real `LocalExpense` on its posting day each month.
///
/// This is a template, NOT a ledger entry — it never appears in the Finance
/// list itself. The rows it generates are ordinary `LocalExpense`s tagged with
/// `ExpenseSource.recurring`, so they behave like any other expense (editable,
/// countable, filterable) and are untouched when the template is later edited
/// or deleted.
///
/// Field style mirrors `LocalExpense`: `String` `clientUUID` (the AI tool
/// surface emits/consumes UUID strings), and every field additive with a
/// default so the SwiftData migration on existing installs stays lightweight
/// (add-with-default, never remove).
@Model
final class RecurringExpense {
    /// Stable identity. Generated locally on creation. Unique within the store.
    @Attribute(.unique) var clientUUID: String

    /// Amount in the original currency (what will be charged each month). Always
    /// a positive magnitude, like `LocalExpense.originalAmount`.
    var amount: Double

    /// ISO 4217 code of the charge's currency (e.g. "SGD", "USD"). FX is frozen
    /// per-posting at materialisation time, never on the template.
    var currency: String

    /// `ExpenseCategory.rawValue`. Stored raw so adding a new category doesn't
    /// require a migration (same convention as `LocalExpense.category`).
    var category: String

    /// Merchant / vendor (e.g. "Landlord", "Netflix"). Optional.
    var merchant: String?

    /// Free-form description. Named `expenseDescription` (not `description`) to
    /// avoid clashing with `CustomStringConvertible.description`.
    var expenseDescription: String?

    /// Payment method label (e.g. "Visa **1234", "GIRO"). Optional.
    var paymentMethod: String?

    /// Day of the month the charge posts, 1...31. Values past the end of a short
    /// month are CLAMPED to that month's last day at materialisation time (e.g.
    /// 31 posts on 28/29 Feb) — the stored value is preserved.
    var dayOfMonth: Int

    /// Whether this template is live. A paused template (`false`) posts nothing
    /// and is skipped by the materialiser until re-activated.
    var isActive: Bool = true

    /// First calendar month this template is eligible to post in (compared at
    /// MONTH granularity, so a template created mid-month still backfills the
    /// current month if its posting day has already passed).
    var startDate: Date

    /// Optional last calendar month/day this template posts. Nil = open-ended.
    /// A posting whose date is strictly after `endDate` is suppressed, and once
    /// the current month is past `endDate`'s month the template posts nothing.
    var endDate: Date?

    /// Cursor: the most-recent month key ("yyyy-MM") the materialiser has fully
    /// processed for this template. Nil = never materialised. The materialiser
    /// resumes from the month AFTER this so repeated foregrounds and missed-month
    /// backfill are both bounded. Advanced alongside the per-posting `dedupeKey`
    /// stamp on the generated `LocalExpense`, so idempotency is guarded on BOTH.
    var lastPostedMonthKey: String?

    var createdAt: Date
    var updatedAt: Date

    // MARK: - Dead-field parity with the other LocalModels
    //
    // Unused today; kept so the schema lines up with the other local models and
    // any future sync / migration story doesn't need a destructive change.
    var needsSync: Bool = false
    var version: Int = 0

    init(
        clientUUID: String = UUID().uuidString.lowercased(),
        amount: Double,
        currency: String,
        category: String,
        merchant: String? = nil,
        expenseDescription: String? = nil,
        paymentMethod: String? = nil,
        dayOfMonth: Int,
        isActive: Bool = true,
        startDate: Date = Date(),
        endDate: Date? = nil,
        lastPostedMonthKey: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        needsSync: Bool = false,
        version: Int = 0
    ) {
        self.clientUUID = clientUUID
        self.amount = amount
        self.currency = currency
        self.category = category
        self.merchant = merchant
        self.expenseDescription = expenseDescription
        self.paymentMethod = paymentMethod
        self.dayOfMonth = dayOfMonth
        self.isActive = isActive
        self.startDate = startDate
        self.endDate = endDate
        self.lastPostedMonthKey = lastPostedMonthKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.needsSync = needsSync
        self.version = version
    }

    // MARK: - Convenience

    var categoryEnum: ExpenseCategory {
        ExpenseCategory(rawValue: category) ?? .other
    }
}
