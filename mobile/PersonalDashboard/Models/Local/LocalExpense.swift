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

    // MARK: - Statement-import attribution (#189)
    //
    // Populated ONLY by the statement-import path (`StatementImporter`): the
    // human-readable statement this expense came off, e.g. "May 2026 Citi -
    // 1234". Empty for every other source (manual / chat / voice / receipt /
    // email) and for statement rows whose header couldn't be read. Additive
    // with a default so the SwiftData migration on existing installs stays
    // lightweight (add-with-default, never remove) and all existing call sites
    // are unaffected. NOT part of the dedupe signature (see `ExpenseDedupe`) —
    // it's display-only metadata and must never change whether a re-import of
    // the same statement is treated as a duplicate.
    var statementLabel: String = ""

    // The name of the PDF file this row was imported from, e.g.
    // "Citi_May2026.pdf". Populated ONLY by the statement-import path; empty for
    // every other source and for rows imported before this field existed. Used
    // to collapse a whole statement into a single Activity row titled by its
    // file name (#198). Additive with a default so the SwiftData migration on
    // existing installs stays lightweight (add-with-default, never remove) and
    // every existing call site is unaffected. Display-only — never part of the
    // dedupe signature.
    var statementFileName: String = ""

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

    // MARK: - Split shares (#188)
    //
    // How many people the bill was split among. When > 1 this row's
    // `originalAmount` / `sgdAmount` already hold the USER'S SHARE (receipt
    // total ÷ shares, computed once at save time), so every aggregation site
    // keeps reading `sgdAmount` and stays correct without change. The full
    // receipt total for display is derived: `originalAmount * numberOfShares`.
    // Additive with a default of 1 so the SwiftData migration on existing
    // installs stays lightweight (add-with-default, never remove) and every
    // existing call site behaves exactly as before (unsplit = 1 share).
    var numberOfShares: Int = 1

    // MARK: - Refund direction (#206)
    //
    // True when this row is a credit-card REFUND / reversal / cashback rather
    // than a spend, i.e. money coming IN. A refund NETS AGAINST spending
    // totals (see `signedSGD`), but its `originalAmount` / `sgdAmount` stay
    // POSITIVE (the magnitude) so the existing `> 0` insert guards and the
    // per-category math still hold — the direction is carried solely by this
    // flag. Populated ONLY by the statement-import path (`StatementImporter`)
    // today; every other source (manual / chat / voice / receipt / email)
    // leaves it false, i.e. a plain expense. Additive with a default so the
    // SwiftData migration on existing installs stays lightweight
    // (add-with-default, never remove) and every existing call site compiles
    // and behaves unchanged (existing rows default to false = expense).
    var isRefund: Bool = false

    // MARK: - Statement dedup descriptor (#208)
    //
    // The VERBATIM transaction descriptor as printed on the statement, lowercased
    // and whitespace-collapsed (the same normalisation merchants get). Populated
    // ONLY by the statement-import path (`StatementImporter`); every other source
    // and every row created before this field existed leaves it empty ("").
    //
    // Why it exists: the dedup key used to include the PARAPHRASED `merchant`,
    // which the LLM rewrites slightly differently across extraction runs (e.g.
    // "SHOPEE SINGAPORE" one run, "SHOPEE SINGAPORE Shopee" the next). The amount,
    // date, and currency come from the statement's numeric columns and are stable;
    // the merchant is the only unstable field. Keying re-import dedup on this
    // stable verbatim descriptor (via `ExpenseDedupe`) makes re-importing the same
    // statement idempotent. `merchant` is unchanged and still drives display.
    //
    // Additive with a default so the SwiftData migration on existing installs
    // stays lightweight (add-with-default, never remove); an empty value marks a
    // legacy row, which the importer matches on amount + date + currency alone so
    // pre-fix data is never re-duplicated on a future re-import.
    var dedupeDescriptor: String = ""

    // MARK: - Trip split / settle-up (#258)
    //
    // Full settle-up for trip expenses. Distinct from the #188 `numberOfShares`
    // model (which stores the user's per-share amount and leaves `sgdAmount`
    // already divided): when a trip split is set, `originalAmount` / `sgdAmount`
    // hold the FULL bill and the per-person breakdown lives in `splitsData`, so
    // the settle-up math can net who paid against who owes. `myShareSGD` below
    // reconciles the two conventions for personal totals.
    //
    // - `paidByPersonUUID`: who fronted the money. nil = the user ("me") paid.
    // - `splitsData`: JSON-encoded `[ExpenseSplitEntry]` (personUUID + shares).
    //   A nil personUUID entry is the user's own slice. nil / empty = an
    //   UNSPLIT expense (today's behaviour) — counts fully in personal totals.
    //
    // Both additive with nil defaults so the SwiftData lightweight migration on
    // existing installs stays safe (add-with-default, never remove) and every
    // existing call site / row is unaffected (no payer, no splits).
    var paidByPersonUUID: UUID? = nil
    var splitsData: Data? = nil

    // MARK: - Per-surface visibility (#264)
    //
    // A trip expense is ONE row shown on two surfaces (the trip's Expenses tab
    // and the Finance list). Deleting it from one surface must not affect the
    // other, so each surface owns a hide flag instead of hard-deleting the
    // shared row. Only when BOTH flags are set (no surface shows it) does the
    // row get physically deleted. The row keeps existing while hidden so
    // `ExpenseDedupe` still sees it and a re-import can't resurrect a
    // duplicate. Both additive with defaults for a safe lightweight migration.
    var hiddenFromFinance: Bool = false
    var hiddenFromTrip: Bool = false

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
        statementLabel: String = "",
        statementFileName: String = "",
        personUUID: UUID? = nil,
        personName: String? = nil,
        eventUUID: UUID? = nil,
        eventName: String? = nil,
        numberOfShares: Int = 1,
        isRefund: Bool = false,
        dedupeDescriptor: String = "",
        paidByPersonUUID: UUID? = nil,
        splitsData: Data? = nil,
        hiddenFromFinance: Bool = false,
        hiddenFromTrip: Bool = false,
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
        self.statementLabel = statementLabel
        self.statementFileName = statementFileName
        self.personUUID = personUUID
        self.personName = personName
        self.eventUUID = eventUUID
        self.eventName = eventName
        self.numberOfShares = numberOfShares
        self.isRefund = isRefund
        self.dedupeDescriptor = dedupeDescriptor
        self.paidByPersonUUID = paidByPersonUUID
        self.splitsData = splitsData
        self.hiddenFromFinance = hiddenFromFinance
        self.hiddenFromTrip = hiddenFromTrip
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

    /// Signed home-currency contribution this row makes to any spending total
    /// (#206). A normal expense contributes `+sgdAmount` (money out); a refund
    /// contributes `-sgdAmount` (money in, netting the total down). Every
    /// aggregation site — month total, previous-month, per-category, daily
    /// sparkline, day-group headers — sums THIS value rather than the raw
    /// `sgdAmount`, so refunds net cleanly without ever storing a negative
    /// amount (the `> 0` insert guards stay valid). A net category or day can
    /// legitimately reach zero or go slightly negative; that is correct.
    var signedSGD: Double {
        isRefund ? -sgdAmount : sgdAmount
    }

    /// Whether this expense was split among more than one person (#188).
    var isSplit: Bool {
        numberOfShares > 1
    }

    /// The full receipt total in the original currency, derived from the
    /// stored per-share `originalAmount`. Cosmetic rounding is accepted on
    /// uneven splits (e.g. 100 / 3 shows ≈ 99.99). Never stored — always
    /// recomputed from `originalAmount * numberOfShares`.
    var receiptTotalOriginal: Double {
        originalAmount * Double(max(numberOfShares, 1))
    }

    /// The full receipt total in SGD, derived from the frozen per-share
    /// `sgdAmount`. Used for the split badge so the displayed total matches
    /// the home-currency figures elsewhere on the row.
    var receiptTotalSGD: Double {
        sgdAmount * Double(max(numberOfShares, 1))
    }

    // MARK: - Trip split helpers (#258)

    /// Decoded per-person split entries. Empty when the expense is unsplit
    /// (`splitsData` nil / empty). Read/write: setting an empty array clears
    /// `splitsData` back to nil so an unsplit expense stores nothing.
    var splits: [ExpenseSplitEntry] {
        get {
            guard let splitsData, !splitsData.isEmpty else { return [] }
            return (try? JSONDecoder().decode([ExpenseSplitEntry].self, from: splitsData)) ?? []
        }
        set {
            splitsData = newValue.isEmpty ? nil : (try? JSONEncoder().encode(newValue))
        }
    }

    /// Whether this expense is split across people via the full settle-up model
    /// (#258). Distinct from the #188 `isSplit` (equal N-way per-share model).
    var isGroupSplit: Bool {
        !splits.isEmpty
    }

    /// The user's own signed home-currency contribution to personal totals.
    ///
    /// - Unsplit expense: the whole signed amount (identical to `signedSGD`),
    ///   so existing data and non-trip expenses count exactly as before.
    /// - Group split: `signedSGD * (myShares / totalShares)`, where "me" is the
    ///   nil-personUUID entry. Zero when the user isn't in the split. Falls back
    ///   to the full amount if the shares are degenerate (total <= 0), so a
    ///   malformed split never silently drops a real expense from totals.
    var myShareSGD: Double {
        let entries = splits
        guard !entries.isEmpty else { return signedSGD }
        let totalShares = entries.reduce(0) { $0 + max($1.shares, 0) }
        guard totalShares > 0 else { return signedSGD }
        let myShares = entries
            .filter { $0.personUUID == nil }
            .reduce(0) { $0 + max($1.shares, 0) }
        return signedSGD * (Double(myShares) / Double(totalShares))
    }

    /// Signed amount in the currency the expense was captured in: negative for
    /// refunds, mirroring `signedSGD`.
    var signedOriginal: Double {
        isRefund ? -originalAmount : originalAmount
    }

    /// `myShareSGD`'s twin in the captured currency, for surfaces that display
    /// amounts as-added rather than converted (#258). Same shares math.
    var myShareOriginal: Double {
        let entries = splits
        guard !entries.isEmpty else { return signedOriginal }
        let totalShares = entries.reduce(0) { $0 + max($1.shares, 0) }
        guard totalShares > 0 else { return signedOriginal }
        let myShares = entries
            .filter { $0.personUUID == nil }
            .reduce(0) { $0 + max($1.shares, 0) }
        return signedOriginal * (Double(myShares) / Double(totalShares))
    }
}
