import Foundation
import SwiftData

/// Expense-level deduplication for the email-to-expense path (#177).
///
/// Mirrors `EmailItemDedupe`, but for `LocalExpense` rows. Message-level
/// idempotency (`LocalProcessedEmail` by Message-Id) does NOT cover the two
/// real cases:
///   (a) Re-scan, which deliberately bypasses the message ledger, and
///   (b) the user forwarding the SAME receipt as two different emails (two
///       copies of one Amazon order or one flight fare: same order/booking
///       reference, same amount/date, different Message-Ids).
/// Both would otherwise log the same expense twice. This helper makes each
/// proposed expense dedup against what already exists, so either path yields
/// exactly one row.
///
/// Scope: used ONLY by `EmailToItinerary`. Chat / voice / capture / manual
/// expense adds never call this and keep their current behaviour. The signature
/// is also stored on the row (`dedupeKey` / `sourceReference`) so a later email
/// can match it cheaply.
enum ExpenseDedupe {

    /// A proposed expense parsed out of an `add_expense` tool input, reduced to
    /// the fields that define equivalence.
    struct Proposed {
        let merchant: String        // raw merchant, may be empty
        let date: Date              // spend date, startOfDay
        let originalAmount: Double  // amount in the original currency
        let originalCurrency: String // ISO 4217, uppercased
        let sourceReference: String // order / booking reference, or "" if none
        /// Direction (#206). A refund and a same-magnitude purchase are NOT
        /// equivalent, so this is folded into the structural key. Defaulted to
        /// false so every existing caller (email path) is unchanged and only
        /// the statement importer, which can propose refunds, sets it.
        var isRefund: Bool = false
    }

    /// Compute the equivalence signature for a proposed expense.
    ///
    /// Strongest signal first: when an order/booking reference is present,
    /// equivalence is (reference) alone — two different emails of the same order
    /// collide here regardless of how their amount/date/merchant render.
    /// Otherwise fall back to a structural key: `merchant|yyyy-mm-dd|amount(2dp)|currency`,
    /// all normalised (lowercased, trimmed).
    static func signature(for proposed: Proposed) -> String {
        let reference = normalizeReference(proposed.sourceReference)
        if !reference.isEmpty {
            return "ref:\(reference)"
        }
        let merchant = normalizeMerchant(proposed.merchant)
        let day = dayKey(proposed.date)
        let amount = amountKey(proposed.originalAmount)
        let currency = proposed.originalCurrency.uppercased()
        // A refund gets its own namespace so it never collides with a
        // same-magnitude purchase; an expense keeps the original format so
        // existing stored `dedupeKey`s stay valid (#206).
        let dir = proposed.isRefund ? "refund|" : ""
        return "s:\(dir)\(merchant)|\(day)|\(amount)|\(currency)"
    }

    /// True when an equivalent expense already exists. Checks both the stored
    /// `dedupeKey` (fast path for expenses the email path created) AND a
    /// structural comparison against existing rows (covers rows created before
    /// this field existed, and reference-vs-structural mismatches).
    @MainActor
    static func exists(signature: String, proposed: Proposed, context: ModelContext) -> Bool {
        // Fast path: a previously-ingested expense carrying the same dedupeKey.
        let sig = signature
        let byKey = (try? context.fetchCount(
            FetchDescriptor<LocalExpense>(
                predicate: #Predicate { $0.dedupeKey == sig }
            )
        )) ?? 0
        if byKey > 0 { return true }

        // Reference match: a row that stored the same normalised reference.
        // This lets a re-forward of the SAME order collide even if the amount
        // or merchant text rendered slightly differently across two emails.
        let reference = normalizeReference(proposed.sourceReference)
        if !reference.isEmpty {
            let byRef = (try? context.fetchCount(
                FetchDescriptor<LocalExpense>(
                    predicate: #Predicate { $0.sourceReference == reference }
                )
            )) ?? 0
            if byRef > 0 { return true }
        }

        // Structural fallback: compare against all expenses (covers chat/voice/
        // manual rows that have no dedupeKey). Done in memory because the
        // normalised merchant + amount key isn't expressible in a #Predicate.
        let targetStructural = structuralKey(proposed)
        let rows = (try? context.fetch(FetchDescriptor<LocalExpense>())) ?? []
        for row in rows where rowStructuralKey(row) == targetStructural {
            return true
        }
        return false
    }

    /// How many stored `LocalExpense` rows already match the STRUCTURAL class of
    /// `proposed` (#208). Used by the statement importer to reconcile *counts*
    /// rather than mere existence: a boolean `exists` can only ever say "at least
    /// one", so once the first of two identical Kult Yard coffees lands, every
    /// further identical line looks like a duplicate and real spend is
    /// under-counted. This returns the multiplicity so the importer can insert
    /// `max(0, N - M)` rows for a class.
    ///
    /// Counts purely by structural key (`merchant|day|amount|currency` +
    /// refund-direction namespace). Reference matching is deliberately ignored:
    /// statements carry no order/booking reference, so structural multiplicity is
    /// the only thing that matters here. Because legit duplicates now share the
    /// same structural `dedupeKey`, we must NOT take the fast `dedupeKey`-count
    /// path (it would conflate reference/structural keys and can't see rows from
    /// other sources); instead we fetch and compare each row's structural key the
    /// SAME way `exists` does, so an already-logged receipt / email row for the
    /// same visit also counts (and is absorbed rather than double-imported).
    @MainActor
    static func existingCount(matching proposed: Proposed, context: ModelContext) -> Int {
        let target = structuralKey(proposed)
        let rows = (try? context.fetch(FetchDescriptor<LocalExpense>())) ?? []
        return rows.reduce(0) { count, row in
            rowStructuralKey(row) == target ? count + 1 : count
        }
    }

    // MARK: - Statement bucket reconciliation (#208)

    /// One incoming statement line reduced to the fields that decide dedup.
    /// `descriptor` is the VERBATIM statement descriptor (the caller applies the
    /// merchant fallback when the model returned none); it is normalised inside
    /// the reconciler, so the caller may pass it raw or pre-normalised.
    struct StatementIncoming {
        let isRefund: Bool
        let date: Date
        let amount: Double
        let currency: String
        let descriptor: String
    }

    /// Decide, for a batch of incoming statement lines, which ones to INSERT vs
    /// treat as duplicates of already-stored rows (#208). Returns a parallel
    /// `[Bool]` (`true` = insert) aligned to `incoming`.
    ///
    /// Why not the paraphrased merchant: the merchant string the model emits
    /// drifts between extraction runs (e.g. "SHOPEE SINGAPORE" vs "SHOPEE
    /// SINGAPORE Shopee"), so a merchant-based key failed to dedup a re-import
    /// and silently re-inserted rows. Amount, date, and currency come from the
    /// statement's numeric columns and are stable; the verbatim `descriptor` is
    /// copied off the page unchanged and is stable too. So we reconcile as a
    /// MULTISET within each (direction, day, amount, currency) BUCKET, matching
    /// on the descriptor, with a legacy fallback for rows that predate the
    /// descriptor field.
    ///
    /// A stored row MATCHES an incoming line when it shares the bucket AND
    /// ( the stored `dedupeDescriptor` is empty [legacy / non-statement row]
    ///   OR its normalised descriptor equals the incoming one ).
    ///
    /// Greedy assignment per bucket, order-stable, each stored row consumed at
    /// most once:
    ///   1. Exact pass — each incoming line claims an unconsumed stored row with
    ///      the SAME non-empty descriptor (exact matches are preferred so a
    ///      legacy wildcard slot is left for a line that has no exact match).
    ///   2. Legacy pass — each still-unmatched incoming line claims an unconsumed
    ///      EMPTY-descriptor stored row (a pre-fix row, or a receipt/manual row).
    ///   3. Anything still unmatched is INSERTED.
    ///
    /// Consequences: exact re-import -> 0 inserted (idempotent); the SHOPEE
    /// paraphrase case -> descriptor identical -> deduped; genuine same-day
    /// same-amount lines with different descriptors -> both kept; a legacy row
    /// with no descriptor -> matched on amount+date+currency so a re-import does
    /// NOT re-add it; three identical lines -> 3 match 3 -> 0 on re-import.
    @MainActor
    static func statementInsertDecisions(
        incoming: [StatementIncoming],
        context: ModelContext
    ) -> [Bool] {
        // Mutable stored-row slots, grouped by bucket. A single fetch; the email
        // /receipt path never runs this.
        struct Slot { let descKey: String; var consumed: Bool }
        let rows = (try? context.fetch(FetchDescriptor<LocalExpense>())) ?? []
        var buckets: [String: [Slot]] = [:]
        for row in rows {
            let bucket = bucketKey(
                isRefund: row.isRefund,
                date: row.date,
                amount: row.originalAmount,
                currency: row.originalCurrency
            )
            buckets[bucket, default: []].append(
                Slot(descKey: normalizeMerchant(row.dedupeDescriptor), consumed: false)
            )
        }

        // Group incoming line indices by bucket, preserving statement order so
        // an earlier line wins a contested legacy slot.
        var indicesByBucket: [String: [Int]] = [:]
        var bucketOrder: [String] = []
        for (i, line) in incoming.enumerated() {
            let bucket = bucketKey(
                isRefund: line.isRefund,
                date: line.date,
                amount: line.amount,
                currency: line.currency
            )
            if indicesByBucket[bucket] == nil { bucketOrder.append(bucket) }
            indicesByBucket[bucket, default: []].append(i)
        }

        var decisions = [Bool](repeating: false, count: incoming.count)
        for bucket in bucketOrder {
            let indices = indicesByBucket[bucket] ?? []
            var slots = buckets[bucket] ?? []
            var pending: [Int] = []

            // Pass 1 — exact non-empty descriptor match.
            for i in indices {
                let descKey = normalizeMerchant(incoming[i].descriptor)
                if !descKey.isEmpty,
                   let slotIdx = slots.firstIndex(where: { !$0.consumed && $0.descKey == descKey }) {
                    slots[slotIdx].consumed = true   // duplicate -> skip
                } else {
                    pending.append(i)
                }
            }
            // Pass 2 — legacy empty-descriptor fallback, else insert.
            for i in pending {
                if let slotIdx = slots.firstIndex(where: { !$0.consumed && $0.descKey.isEmpty }) {
                    slots[slotIdx].consumed = true   // matched a legacy row -> skip
                } else {
                    decisions[i] = true              // new spend -> insert
                }
            }
            buckets[bucket] = slots
        }
        return decisions
    }

    /// The reference-free (direction, day, amount, currency) bucket key that
    /// groups structurally-comparable statement rows. Descriptor is NOT part of
    /// the bucket — matching within a bucket is what the descriptor decides.
    private static func bucketKey(isRefund: Bool, date: Date, amount: Double, currency: String) -> String {
        let dir = isRefund ? "refund|" : ""
        return "\(dir)\(dayKey(date))|\(amountKey(amount))|\(currency.uppercased())"
    }

    /// The structural key (reference-free) for a proposed expense.
    private static func structuralKey(_ proposed: Proposed) -> String {
        let merchant = normalizeMerchant(proposed.merchant)
        let day = dayKey(proposed.date)
        let amount = amountKey(proposed.originalAmount)
        let currency = proposed.originalCurrency.uppercased()
        let dir = proposed.isRefund ? "refund|" : ""
        return "\(dir)\(merchant)|\(day)|\(amount)|\(currency)"
    }

    /// The structural key for an existing stored row, computed the SAME way as
    /// `structuralKey(_:)` for a proposed expense so `exists` compares like for
    /// like.
    private static func rowStructuralKey(_ row: LocalExpense) -> String {
        let merchant = normalizeMerchant(row.merchant ?? "")
        let day = dayKey(row.date)
        let amount = amountKey(row.originalAmount)
        let currency = row.originalCurrency.uppercased()
        let dir = row.isRefund ? "refund|" : ""
        return "\(dir)\(merchant)|\(day)|\(amount)|\(currency)"
    }

    // MARK: - Normalisation

    static func normalizeMerchant(_ merchant: String) -> String {
        let lowered = merchant.lowercased()
        let collapsed = lowered.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalise an order/booking reference to letters + digits, uppercased.
    /// Mirrors `EmailItemDedupe.normalizeConfirmation` so a shared PNR that is
    /// both a flight confirmation and a fare reference normalises identically.
    static func normalizeReference(_ reference: String) -> String {
        reference.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func dayKey(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Amount to two decimal places, so `450` and `450.00` collide.
    private static func amountKey(_ amount: Double) -> String {
        String(format: "%.2f", amount)
    }
}
