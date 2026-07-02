import Foundation
import SwiftData

/// Result of running one credit-card statement PDF through the batch-import
/// pipeline (#184). Every parsed line lands in exactly one of these buckets, so
/// `imported + skippedDuplicates + ignoredNonSpend + failed == total parsed`.
struct StatementImportResult: Sendable {
    /// Lines that deduped clean and were inserted. Counts BOTH spend
    /// (purchase/fee/interest) and refund rows — every row that produced a
    /// `LocalExpense` this run. `refunds` (below) is the refund subset, so the
    /// spend-only count is `imported - refunds`.
    let imported: Int
    /// Subset of `imported` that were refunds/credits, inserted with
    /// `isRefund: true` so they net against spending totals (#206). Surfaced
    /// separately in the summary ("including N refunds") so it's clear money
    /// came back in, not just out.
    let refunds: Int
    /// Lines (spend or refund) that matched an existing expense via
    /// `ExpenseDedupe` and were skipped.
    let skippedDuplicates: Int
    /// Payment (card transfer) lines — counted, never inserted. A payment is a
    /// transfer TO the card that pays down the balance; importing it would
    /// double-count against the purchases it settled (#206).
    let ignoredNonSpend: Int
    /// Spend lines that failed to insert (bad amount, FX failure, persistence
    /// error). Non-fatal — the batch continues past each one.
    let failed: Int
    /// True when the model likely ran out of output tokens on a very large
    /// statement, so the tail rows never came through. Drives a "some
    /// transactions may be missing" note in the summary.
    let possiblyTruncated: Bool

    /// UUIDs of the expenses actually inserted this run (kept for parity with
    /// the email path's `addedExpenseUUIDs`; the UI doesn't offer undo yet).
    let importedUUIDs: [UUID]

    var totalParsed: Int {
        imported + skippedDuplicates + ignoredNonSpend + failed
    }

    /// User-facing one-liner for the summary alert. Mentions only the buckets
    /// that have entries so a clean import reads simply. Examples:
    ///   "Imported 42 (including 3 refunds) · Skipped 8 duplicates · Ignored 5 payments"
    ///   "Imported 12"
    ///   "Nothing to import — no transactions found."
    var summaryLine: String {
        guard totalParsed > 0 else {
            return "Nothing to import — no transactions found on this statement."
        }
        var head = "Imported \(imported)"
        if refunds > 0 {
            head += " (including \(refunds) refund\(refunds == 1 ? "" : "s"))"
        }
        var parts: [String] = [head]
        if skippedDuplicates > 0 {
            parts.append("Skipped \(skippedDuplicates) duplicate\(skippedDuplicates == 1 ? "" : "s")")
        }
        if ignoredNonSpend > 0 {
            parts.append("Ignored \(ignoredNonSpend) payment\(ignoredNonSpend == 1 ? "" : "s")")
        }
        if failed > 0 {
            parts.append("\(failed) couldn't be added")
        }
        let counts = parts.joined(separator: " · ")
        guard possiblyTruncated else { return counts }

        // Chunking makes this essentially unreachable, but if a single chunk
        // still ran out of output budget the import is genuinely incomplete —
        // make that unmissable (leading warning, not a trailing footnote) with
        // the count that DID land, so the user knows to re-import.
        return """
        ⚠️ Incomplete import — some transactions may be missing

        \(counts)

        Part of this statement was too long to read in one pass. Re-import the \
        statement to try again, or add any missing transactions manually.
        """
    }
}

/// Batch statement-import orchestrator (#184).
///
/// Mirrors `EmailToItinerary`'s "parse → dedupe → insert → stamp keys → count
/// skipped" shape, but for a whole statement rather than one receipt:
///   1. Ask Claude for the full transaction array (native PDF block).
///   2. Drop card-payment lines (tally as `ignoredNonSpend`) — a payment settles
///      the balance and would double-count against the purchases it paid off.
///      Refunds are NOT dropped: they import as credits (`isRefund: true`) that
///      net against spending totals (#206).
///   3. Reconcile by structural class rather than boolean existence (#208).
///      Group the remaining lines by their structural key
///      (dir|merchant|day|amount|currency). For each class, let N = lines this
///      statement asserts and M = matching rows already stored; insert
///      `max(0, N - M)` of them (FX-convert + `ExpenseService` with `source:
///      .pdf`, stamping the structural `dedupeKey`; statements carry no order
///      reference, so `sourceReference` stays empty), and count the rest as
///      skipped duplicates.
///
/// Why counts, not a boolean: statement rows have no per-line reference, so two
/// genuine same-day/same-amount purchases (e.g. two coffees at one café) are
/// structurally identical. A boolean `exists` skips every line after the first
/// and under-counts real spend. Counting inserts the right multiplicity while
/// staying idempotent on re-import (N == M → insert 0) and self-healing after a
/// truncated import or a receipt already logged for one visit (N > M → top up).
///
/// Auto-import: there is no per-row review. The importer inserts survivors
/// directly and returns counts for the summary.
@MainActor
struct StatementImporter {
    let anthropic: AnthropicClient
    let store: SwiftDataStore

    init(anthropic: AnthropicClient = AnthropicClient(), store: SwiftDataStore = .shared) {
        self.anthropic = anthropic
        self.store = store
    }

    static func `default`() -> StatementImporter {
        StatementImporter(anthropic: AnthropicClient(), store: .shared)
    }

    /// Parse + import a statement PDF. Throws only on extraction failure
    /// (`StatementExtractionError`); per-line insert failures are caught and
    /// counted in the result, never propagated, so one bad row can't sink the
    /// whole import.
    func importStatement(pdfData: Data, fileName: String? = nil) async throws -> StatementImportResult {
        let (lines, meta, truncated) = try await anthropic.extractStatement(pdfData: pdfData)
        return await insert(lines: lines, meta: meta, fileName: fileName, possiblyTruncated: truncated)
    }

    /// Bucket + insert already-parsed lines. Split out from `importStatement`
    /// so the classification/dedup/insert logic is unit-testable without a live
    /// Anthropic call.
    ///
    /// `meta` carries the statement header (issuer / last4 / period) used to
    /// stamp each imported row's attribution label and payment method (#189).
    /// It defaults to an empty header so existing test call sites that only pass
    /// `lines` keep compiling and behave exactly as before (no label, no
    /// payment method).
    func insert(
        lines: [ExtractedStatementLine],
        meta: ExtractedStatementMeta = ExtractedStatementMeta(issuer: nil, last4: nil, statementMonth: nil, statementYear: nil),
        fileName: String? = nil,
        possiblyTruncated: Bool
    ) async -> StatementImportResult {
        var imported = 0
        var refunds = 0
        var skippedDuplicates = 0
        var ignoredNonSpend = 0
        var failed = 0
        var importedUUIDs: [UUID] = []

        let fx = FXService(store: store)
        let service = ExpenseService(store: store)

        // Statement-level attribution, computed once and stamped on every row
        // inserted this run (#189). Both are "" when the header couldn't be
        // read, in which case we write nothing rather than a placeholder.
        let statementLabel = meta.attributionLabel
        let statementFileName = (fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cardLabel = meta.cardLabel
        let paymentMethod = cardLabel.isEmpty ? nil : cardLabel

        // One statement line reduced to everything the insert step needs, plus
        // its structural class key. Built in the classification pass below so the
        // insert pass can reconcile by class (#208) instead of skipping every
        // structurally-identical line after the first.
        struct Candidate {
            let amount: Double
            let currency: String
            let date: Date
            let merchant: String?
            let category: ExpenseCategory
            let isRefund: Bool
            let proposed: ExpenseDedupe.Proposed
            /// Structural class key. For a statement (no order reference) this is
            /// the structural signature, so two same-merchant/day/amount/currency
            /// lines of the same direction share it and reconcile together.
            let classKey: String
        }

        // Pass 1 — classify every line. Payments are counted and dropped;
        // amount-less lines fail here (they can't form a valid class); everything
        // else becomes an ordered candidate carrying its structural class key.
        var candidates: [Candidate] = []
        for line in lines {
            // A missing/unknown type defaults to `.purchase` (import it) — the
            // model reliably tags payments/refunds, so an untyped line is far
            // more likely a normal purchase than a credit.
            let type = line.type ?? .purchase
            guard type.shouldImport else {
                // Card payments only — they settle the balance and must never be
                // imported (they'd double-count against the purchases they paid
                // off). Refunds fall through and import as credits.
                ignoredNonSpend += 1
                continue
            }
            // A refund imports as a credit: positive magnitude, `isRefund: true`
            // so it nets against totals. Everything else is ordinary spend.
            let isRefund = (type == .refund)

            // Amount must be positive to be a valid LocalExpense. A statement
            // line with no readable amount is dropped as a failure so the count
            // reconciles with the parsed total.
            guard let amount = line.amount, amount > 0 else {
                failed += 1
                continue
            }

            let currency = Self.normalizeCurrency(line.currency)
            let date = Self.parseDate(line.date) ?? Date()
            let merchant = line.merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = ExpenseCategory(rawValue: (line.category ?? "").lowercased()) ?? .other

            // Statements have no order reference, so the signature falls back to
            // the structural key (dir|merchant|date|amount|currency). Direction is
            // part of equivalence (#206): a £50 refund must not collapse into a
            // same-day £50 purchase, and each direction reconciles on its own.
            let proposed = ExpenseDedupe.Proposed(
                merchant: merchant ?? "",
                date: Calendar(identifier: .gregorian).startOfDay(for: date),
                originalAmount: amount,
                originalCurrency: currency,
                sourceReference: "",
                isRefund: isRefund
            )
            candidates.append(Candidate(
                amount: amount,
                currency: currency,
                date: date,
                merchant: merchant,
                category: category,
                isRefund: isRefund,
                proposed: proposed,
                classKey: ExpenseDedupe.signature(for: proposed)
            ))
        }

        // Count reconciliation (#208). For each structural class, let N be the
        // number of lines THIS statement asserts and M the number of matching
        // rows ALREADY stored (computed ONCE, before this batch inserts anything).
        // We may insert at most `max(0, N - M)` rows for the class; the rest are
        // duplicates. `budget[classKey]` is that deficit, decremented as we
        // consume slots so a re-query can't inflate M with rows we just inserted.
        //
        // Behaviour: two identical coffees with none stored → N=2,M=0 → both
        // import; a clean re-import → N=2,M=2 → both skip (idempotent); a
        // truncated first import → N=2,M=1 → one imports (self-heals); a receipt
        // already logged for one visit → N=2,M=1 → one imports (absorbs overlap).
        var budget: [String: Int] = [:]
        for candidate in candidates where budget[candidate.classKey] == nil {
            let n = candidates.filter { $0.classKey == candidate.classKey }.count
            let m = ExpenseDedupe.existingCount(matching: candidate.proposed, context: store.context)
            budget[candidate.classKey] = max(0, n - m)
        }

        // Pass 2 — walk candidates in original statement order. A class with
        // remaining budget attempts an insert (consuming a slot regardless of
        // outcome, so a failed insert never promotes a later duplicate into its
        // place); once the budget is spent, the rest of the class are skipped
        // duplicates.
        for candidate in candidates {
            guard let remaining = budget[candidate.classKey], remaining > 0 else {
                skippedDuplicates += 1
                continue
            }
            budget[candidate.classKey] = remaining - 1

            // FX. SGD passes straight through; other currencies hit FXService
            // (cached 1 day). A rate failure counts the line as failed rather
            // than inserting a silent zero.
            let conversion: (sgdAmount: Double, rate: Double)
            do {
                conversion = try await fx.convert(candidate.amount, from: candidate.currency)
            } catch {
                NSLog("StatementImporter: FX convert failed for %@: %@", candidate.currency, error.localizedDescription)
                failed += 1
                continue
            }

            do {
                let row = try service.addExpense(
                    date: candidate.date,
                    category: candidate.category,
                    merchant: candidate.merchant,
                    expenseDescription: nil,
                    originalAmount: candidate.amount,
                    originalCurrency: candidate.currency,
                    sgdAmount: conversion.sgdAmount,
                    fxRate: conversion.rate,
                    paymentMethod: paymentMethod,
                    source: .pdf,
                    isRefund: candidate.isRefund
                )
                // Stamp the structural dedupe signature. It's now EXPECTED that
                // legit duplicates in the same class share this key — counting,
                // not the key's uniqueness, is what keeps re-imports idempotent.
                // sourceReference stays empty (the statement carries no reference).
                row.dedupeKey = candidate.classKey
                row.sourceReference = ""
                // Statement attribution (#189): which statement this came off.
                // Display-only — deliberately NOT part of the dedupe signature.
                row.statementLabel = statementLabel
                // File name of the imported PDF (#198). Collapses the whole
                // statement into a single Activity row titled by its file name,
                // even when the header couldn't be parsed (empty statementLabel).
                row.statementFileName = statementFileName
                try? store.context.save()

                imported += 1
                if candidate.isRefund { refunds += 1 }
                if let uuid = UUID(uuidString: row.clientUUID) {
                    importedUUIDs.append(uuid)
                }
            } catch {
                NSLog("StatementImporter: insert failed: %@", error.localizedDescription)
                failed += 1
            }
        }

        return StatementImportResult(
            imported: imported,
            refunds: refunds,
            skippedDuplicates: skippedDuplicates,
            ignoredNonSpend: ignoredNonSpend,
            failed: failed,
            possiblyTruncated: possiblyTruncated,
            importedUUIDs: importedUUIDs
        )
    }

    // MARK: - Parsing helpers

    /// Normalise an ISO 4217 code; empty / nil defaults to the home currency.
    static func normalizeCurrency(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "SGD" : trimmed.uppercased()
    }

    /// Lenient ISO date parser: full datetime (with/without fractional
    /// seconds) or bare yyyy-MM-dd. Mirrors the parsers in `EmailToItinerary`
    /// so a statement date resolves the same way an email date would.
    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, raw != "null" else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = isoFractional.date(from: trimmed) { return d }
        if let d = isoPlain.date(from: trimmed) { return d }
        if let d = dateOnly.date(from: trimmed) { return d }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
