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
///   3. For each remaining line: build an `ExpenseDedupe.Proposed`, skip if it
///      already exists, else FX-convert and insert via `ExpenseService` with
///      `source: .pdf`, then stamp `dedupeKey` (structural — statements carry
///      no order reference, so `sourceReference` stays empty like the email
///      path leaves it for reference-less rows).
///
/// Auto-import: there is no per-row review. The importer inserts survivors
/// directly and returns counts for the summary. Dedup makes a re-import of the
/// same statement idempotent.
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

        for line in lines {
            // Classification. A missing/unknown type defaults to `.purchase`
            // (import it) — the model reliably tags payments/refunds, so an
            // untyped line is far more likely a normal purchase than a credit.
            let type = line.type ?? .purchase
            guard type.shouldImport else {
                // Card payments only — they settle the balance and must never
                // be imported (they'd double-count against the purchases they
                // paid off). Refunds fall through and import as credits.
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

            // Dedup against existing rows using the EXISTING helper, exactly as
            // the email path does. Statements have no order reference, so the
            // signature falls back to the structural key
            // (merchant|date|amount|currency).
            let proposed = ExpenseDedupe.Proposed(
                merchant: merchant ?? "",
                date: Calendar(identifier: .gregorian).startOfDay(for: date),
                originalAmount: amount,
                originalCurrency: currency,
                sourceReference: "",
                // Direction is part of equivalence (#206): a £50 refund must not
                // be swallowed as a "duplicate" of a same-day £50 purchase, and
                // a re-imported refund still dedupes against the prior refund.
                isRefund: isRefund
            )
            let signature = ExpenseDedupe.signature(for: proposed)
            if ExpenseDedupe.exists(signature: signature, proposed: proposed, context: store.context) {
                skippedDuplicates += 1
                continue
            }

            // FX. SGD passes straight through; other currencies hit FXService
            // (cached 1 day). A rate failure counts the line as failed rather
            // than inserting a silent zero.
            let conversion: (sgdAmount: Double, rate: Double)
            do {
                conversion = try await fx.convert(amount, from: currency)
            } catch {
                NSLog("StatementImporter: FX convert failed for %@: %@", currency, error.localizedDescription)
                failed += 1
                continue
            }

            do {
                let row = try service.addExpense(
                    date: date,
                    category: category,
                    merchant: merchant,
                    expenseDescription: nil,
                    originalAmount: amount,
                    originalCurrency: currency,
                    sgdAmount: conversion.sgdAmount,
                    fxRate: conversion.rate,
                    paymentMethod: paymentMethod,
                    source: .pdf,
                    isRefund: isRefund
                )
                // Stamp the dedupe signature so a re-import of the same
                // statement dedups against this row cheaply, mirroring the
                // email path. sourceReference stays empty (structural key) —
                // the statement carries no order/booking reference.
                row.dedupeKey = signature
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
                if isRefund { refunds += 1 }
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
