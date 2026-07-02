import Foundation
import SwiftData

/// Result of running one credit-card statement PDF through the batch-import
/// pipeline (#184). Every parsed line lands in exactly one of these buckets, so
/// `imported + skippedDuplicates + ignoredNonSpend + failed == total parsed`.
struct StatementImportResult: Sendable {
    /// Purchase/fee/interest lines that deduped clean and were inserted.
    let imported: Int
    /// Spend lines that matched an existing expense via `ExpenseDedupe` and were
    /// skipped.
    let skippedDuplicates: Int
    /// Payment (card transfer) and refund/credit lines — counted, never
    /// inserted (the positive-only `LocalExpense` model can't represent them).
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
    ///   "Imported 42 · Skipped 8 duplicates · Ignored 5 payments/refunds"
    ///   "Imported 12"
    ///   "Nothing to import — no transactions found."
    var summaryLine: String {
        guard totalParsed > 0 else {
            return "Nothing to import — no transactions found on this statement."
        }
        var parts: [String] = ["Imported \(imported)"]
        if skippedDuplicates > 0 {
            parts.append("Skipped \(skippedDuplicates) duplicate\(skippedDuplicates == 1 ? "" : "s")")
        }
        if ignoredNonSpend > 0 {
            parts.append("Ignored \(ignoredNonSpend) payment\(ignoredNonSpend == 1 ? "" : "s")/refund\(ignoredNonSpend == 1 ? "" : "s")")
        }
        if failed > 0 {
            parts.append("\(failed) couldn't be added")
        }
        var line = parts.joined(separator: " · ")
        if possiblyTruncated {
            line += "\n\nThis statement was large, so some later transactions may not have been read. Re-import or add the rest manually if a few are missing."
        }
        return line
    }
}

/// Batch statement-import orchestrator (#184).
///
/// Mirrors `EmailToItinerary`'s "parse → dedupe → insert → stamp keys → count
/// skipped" shape, but for a whole statement rather than one receipt:
///   1. Ask Claude for the full transaction array (native PDF block).
///   2. Drop payment/refund lines (tally as `ignoredNonSpend`).
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
            guard type.isSpend else {
                ignoredNonSpend += 1
                continue
            }

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
                sourceReference: ""
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
                    source: .pdf
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
