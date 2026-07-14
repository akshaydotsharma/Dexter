import Foundation
import SwiftData

/// Result of running one credit-card or bank statement PDF through the
/// batch-import pipeline (#184, bank support #243). Every parsed line lands in
/// exactly one of these buckets, so
/// `imported + skippedDuplicates + ignoredNonSpend + deposits + failed == total parsed`.
struct StatementImportResult: Sendable {
    /// Lines that deduped clean and were inserted. Counts BOTH spend
    /// (purchase/fee/interest) and refund rows — every row that produced a
    /// `LocalExpense` this run. `refunds` (below) is the refund subset, so the
    /// spend-only count is `imported - refunds`.
    let imported: Int
    /// Subset of `imported` inserted as "+" credits (`isRefund: true`) so they
    /// net against spending totals (#206). Covers card reversals/cashback AND
    /// (on a bank statement) money received from a person or a reimbursement
    /// (#243). Surfaced in the summary as "including N credits" so it's clear
    /// money came back in, not just out.
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

    /// Bank-statement deposit lines (money received into the account) — counted,
    /// never inserted, because income isn't tracked yet (#243). Kept distinct
    /// from `ignoredNonSpend` (card payments) so the summary can report deposits
    /// with their own total. Defaults to 0 so credit-card imports and older test
    /// call sites are unaffected.
    var deposits: Int = 0
    /// SGD sum of the deposits this run could FX-convert. A deposit whose FX
    /// lookup failed is still counted in `deposits` but omitted here, so this is
    /// a lower bound on money received. Defaults to 0.
    var depositsTotalSGD: Double = 0

    var totalParsed: Int {
        imported + skippedDuplicates + ignoredNonSpend + deposits + failed
    }

    /// User-facing one-liner for the summary alert. Mentions only the buckets
    /// that have entries so a clean import reads simply. Examples:
    ///   "Imported 42 (including 3 credits) · Skipped 8 duplicates · Ignored 5 payments"
    ///   "Imported 26 (including 8 credits) · Ignored 1 payment · Skipped 1 deposit (SGD 14,840.00), income isn't tracked yet"
    ///   "Imported 12"
    ///   "Nothing to import — no transactions found."
    var summaryLine: String {
        guard totalParsed > 0 else {
            return "Nothing to import — no transactions found on this statement."
        }
        var head = "Imported \(imported)"
        if refunds > 0 {
            // "credits" not "refunds": this bucket now covers card reversals AND
            // money received from a person / a reimbursement, all imported as
            // "+" credits (#243). "credit" reads accurately for both.
            head += " (including \(refunds) credit\(refunds == 1 ? "" : "s"))"
        }
        var parts: [String] = [head]
        if skippedDuplicates > 0 {
            parts.append("Skipped \(skippedDuplicates) duplicate\(skippedDuplicates == 1 ? "" : "s")")
        }
        if ignoredNonSpend > 0 {
            parts.append("Ignored \(ignoredNonSpend) payment\(ignoredNonSpend == 1 ? "" : "s")")
        }
        if deposits > 0 {
            // Bank deposits are money received. We classify and report them but
            // don't store them (no income model yet, #243). State the total so
            // it's clear money came in that isn't in the expense figures. No
            // em dash in this user-facing string (project no-em-dash rule).
            let depositWord = deposits == 1 ? "deposit" : "deposits"
            parts.append("Skipped \(deposits) \(depositWord) (SGD \(Self.formatSGD(depositsTotalSGD))), income isn't tracked yet")
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

    /// Format an SGD magnitude with grouping and two decimals ("16,559.11").
    /// POSIX locale so grouping / decimal separators are stable regardless of
    /// device locale, matching how the rest of Finance renders amounts.
    static func formatSGD(_ amount: Double) -> String {
        Self.sgdFormatter.string(from: NSNumber(value: amount))
            ?? String(format: "%.2f", amount)
    }

    private static let sgdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
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
///   3. Reconcile by VERBATIM descriptor within a bucket, not by the paraphrased
///      merchant (#208). `ExpenseDedupe.statementInsertDecisions` multiset-matches
///      each incoming line against already-stored rows inside its
///      (dir|day|amount|currency) bucket, on the statement descriptor (with a
///      legacy fallback for rows that predate the descriptor field). Unmatched
///      lines are inserted (FX-convert + `ExpenseService` with `source: .pdf`,
///      stamping `dedupeDescriptor` = the normalised verbatim descriptor and the
///      structural `dedupeKey`; `sourceReference` stays empty); matched lines are
///      counted as skipped duplicates.
///
/// Why the verbatim descriptor: statement rows have no per-line reference, and
/// the model paraphrases the merchant differently across extraction runs (e.g.
/// "SHOPEE SINGAPORE" one run, "SHOPEE SINGAPORE Shopee" the next), so a
/// merchant-keyed re-import silently re-inserted rows. The amount, date, and
/// currency come from the statement's stable numeric columns; the descriptor is
/// copied off the page character-for-character and is stable too. Matching on it
/// keeps re-imports idempotent while two genuine same-day/same-amount lines with
/// DIFFERENT descriptors both import, and self-heals after a truncated import or
/// a receipt/legacy row already logged for one visit (that row is absorbed).
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
    /// `trip` (#258): when non-nil, every inserted row is linked to that trip and
    /// — if the trip has participants — seeded with an equal split (everyone at
    /// one share, the user as payer). nil keeps today's Finance behaviour (no
    /// trip, no split). Dedup is unaffected: trip linkage is stamped AFTER the
    /// dedup decisions, which never consider it.
    func importStatement(pdfData: Data, fileName: String? = nil, trip: LocalTrip? = nil) async throws -> StatementImportResult {
        let (lines, meta, truncated) = try await anthropic.extractStatement(pdfData: pdfData)
        return await insert(lines: lines, meta: meta, fileName: fileName, possiblyTruncated: truncated, trip: trip)
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
    ///
    /// `source`, `receiptImagePath`, and `recordsImportHistory` (#247) let the
    /// photo multi-expense path reuse this exact pipeline. They all default to
    /// the statement behaviour so every existing caller and test compiles
    /// unchanged: statements tag rows `.pdf`, carry no receipt image, and write
    /// a `LocalStatementImport` history record. A photo import passes `source:
    /// .photo` (or `.receipt`), the saved receipt's `receiptImagePath` (shared
    /// across all rows the photo produced), and `recordsImportHistory: false` so
    /// photos don't pollute the statement history.
    func insert(
        lines: [ExtractedStatementLine],
        meta: ExtractedStatementMeta = ExtractedStatementMeta(issuer: nil, last4: nil, statementMonth: nil, statementYear: nil),
        fileName: String? = nil,
        source: ExpenseSource = .pdf,
        receiptImagePath: String? = nil,
        recordsImportHistory: Bool = true,
        possiblyTruncated: Bool,
        trip: LocalTrip? = nil
    ) async -> StatementImportResult {
        var imported = 0
        var refunds = 0
        var skippedDuplicates = 0
        var ignoredNonSpend = 0
        var failed = 0
        // Bank-statement deposits (money received) — counted and reported, never
        // stored, because income isn't tracked yet (#243). `deposits` is the
        // count; `depositsTotalSGD` is the SGD sum of those we could FX-convert.
        var deposits = 0
        var depositsTotalSGD = 0.0
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

        // Trip linkage + default split (#258), resolved once. When importing
        // from a trip, every inserted row is stamped with the trip FK; if the
        // trip has participants, it also gets an equal split (everyone at one
        // share, the user as payer) under the full-bill convention
        // (`numberOfShares` stays 1). nil trip → no linkage, no split.
        let tripUUID = trip?.clientUUID
        let tripParticipants = trip?.participantPersonUUIDs ?? []

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
            /// Optional per-line description. nil for statement lines (the
            /// statement prompt emits none); carries the receipt's item summary
            /// for photo imports (#247).
            let description: String?
            let proposed: ExpenseDedupe.Proposed
            /// Structural class key (dir|merchant|day|amount|currency). Stamped on
            /// the inserted row's `dedupeKey` for continuity with the email path;
            /// NOT what statement re-import dedup keys on (that's `descKey`).
            let classKey: String
            /// Normalised VERBATIM statement descriptor — the stable re-import
            /// dedup key (#208). Falls back to the merchant when the model
            /// returned no descriptor. Stamped on the inserted row's
            /// `dedupeDescriptor`.
            let descKey: String
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
                // Non-importable credits. Two distinct kinds, counted separately:
                //   - `.deposit` (bank money-in): tallied and, where FX allows,
                //     summed for the import summary. Income isn't tracked yet, so
                //     it's never stored (#243).
                //   - `.payment` (card transfer): settles the card balance and
                //     must never be imported (it'd double-count against the
                //     purchases it paid off).
                // Refunds have `shouldImport == true` and fall through to import
                // as credits.
                if type == .deposit {
                    deposits += 1
                    // Sum the deposit in SGD (same conversion path as spend).
                    // A deposit with no readable positive amount, or one whose FX
                    // lookup fails, is still COUNTED but omitted from the total —
                    // the count must never silently drop.
                    if let amount = line.amount, amount > 0 {
                        let currency = Self.normalizeCurrency(line.currency)
                        if let conversion = try? await fx.convert(amount, from: currency) {
                            depositsTotalSGD += conversion.sgdAmount
                        } else {
                            NSLog("StatementImporter: FX convert failed for deposit in %@ — counted, excluded from total", currency)
                        }
                    }
                } else {
                    ignoredNonSpend += 1
                }
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

            // Verbatim descriptor is the stable re-import dedup key (#208). The
            // model paraphrases `merchant` differently across runs, so keying on
            // it re-inserted the same line on re-import. If the model returned no
            // descriptor for this line, fall back to the merchant so behaviour
            // degrades to the old merchant-based key rather than an empty key
            // that would over-merge unrelated same-amount/day lines.
            let rawDescriptor = line.descriptor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let descriptorSource = rawDescriptor.isEmpty ? (merchant ?? "") : rawDescriptor
            let descKey = ExpenseDedupe.normalizeMerchant(descriptorSource)

            // Per-line description: nil for statements (none emitted), the
            // receipt item summary for photo imports (#247). Trimmed, empty → nil.
            let trimmedDescription = line.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let lineDescription = (trimmedDescription?.isEmpty == false) ? trimmedDescription : nil

            candidates.append(Candidate(
                amount: amount,
                currency: currency,
                date: date,
                merchant: merchant,
                category: category,
                isRefund: isRefund,
                description: lineDescription,
                proposed: proposed,
                classKey: ExpenseDedupe.signature(for: proposed),
                descKey: descKey
            ))
        }

        // Descriptor-based bucket reconciliation (#208). Within each (direction,
        // day, amount, currency) bucket we multiset-match incoming lines against
        // already-stored rows on the VERBATIM descriptor (with a legacy fallback
        // for rows that predate the descriptor field), computed ONCE before this
        // batch inserts anything. `decisions[i]` is true when candidate i is new
        // spend to insert; false when it duplicates a stored row.
        //
        // Why descriptor, not merchant: the model paraphrases the merchant
        // differently across extraction runs, so a merchant-keyed re-import
        // silently re-inserted rows. The descriptor is copied off the page
        // verbatim and is stable across runs.
        //
        // Behaviour: two identical lines with none stored → both import; a clean
        // re-import → both skip (idempotent); a truncated first import → the
        // missing one imports (self-heals); a receipt/legacy row already logged
        // for one visit → absorbed; the SHOPEE merchant-paraphrase case → same
        // descriptor → deduped.
        let decisions = ExpenseDedupe.statementInsertDecisions(
            incoming: candidates.map {
                ExpenseDedupe.StatementIncoming(
                    isRefund: $0.isRefund,
                    date: $0.date,
                    amount: $0.amount,
                    currency: $0.currency,
                    descriptor: $0.descKey
                )
            },
            context: store.context
        )

        // Pass 2 — walk candidates in original statement order. A candidate the
        // reconciler marked for insertion attempts one (a failed insert is
        // counted as failed, never promoting a duplicate into its place, because
        // decisions were fixed up front against the pre-batch store); the rest
        // are skipped duplicates.
        for (i, candidate) in candidates.enumerated() {
            guard decisions[i] else {
                skippedDuplicates += 1
                continue
            }

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
                    expenseDescription: candidate.description,
                    originalAmount: candidate.amount,
                    originalCurrency: candidate.currency,
                    sgdAmount: conversion.sgdAmount,
                    fxRate: conversion.rate,
                    paymentMethod: paymentMethod,
                    source: source,
                    isRefund: candidate.isRefund
                )
                // Stamp the structural dedupe signature (kept for continuity with
                // the email path's fast-path). sourceReference stays empty (the
                // statement carries no reference).
                row.dedupeKey = candidate.classKey
                row.sourceReference = ""
                // The stable re-import dedup key (#208): the normalised verbatim
                // descriptor. A future re-import matches on THIS within the
                // (dir|day|amount|currency) bucket, so the same statement dedups
                // even when the model paraphrases the merchant differently.
                row.dedupeDescriptor = candidate.descKey
                // Receipt image the row came from (#247). nil for statements;
                // for a photo import every row shares the ONE saved receipt path,
                // so the reference-aware delete keeps the file until the last of
                // them is removed.
                row.receiptImagePath = receiptImagePath
                // Statement attribution (#189): which statement this came off.
                // Display-only — deliberately NOT part of the dedupe signature.
                row.statementLabel = statementLabel
                // File name of the imported PDF (#198). Collapses the whole
                // statement into a single Activity row titled by its file name,
                // even when the header couldn't be parsed (empty statementLabel).
                row.statementFileName = statementFileName
                // Trip linkage + default split (#258). Stamped after the row is
                // built; dedup already ran and never considered the trip, so a
                // re-import stays idempotent regardless of trip linkage.
                if let tripUUID {
                    row.tripUUID = tripUUID
                    // Trip expenses are opt-in to Finance (#277): an imported
                    // trip expense starts hidden from Finance totals until the
                    // user ticks it on the trip's Expenses tab. The trip's own
                    // tiles / settle-up still count it.
                    row.hiddenFromFinance = true
                    if !tripParticipants.isEmpty {
                        var entries: [ExpenseSplitEntry] = [ExpenseSplitEntry(person: nil, shares: 1)]
                        entries.append(contentsOf: tripParticipants.map { ExpenseSplitEntry(person: $0, shares: 1) })
                        row.splits = entries
                        row.paidByPersonUUID = nil
                    }
                }
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

        // Persist a permanent parse record for the Parsed Files & Imports
        // history (#234). Written on the SAME context the expenses were inserted
        // on, so it lands in the same store. Recorded only when the run actually
        // imported rows — a clean re-import that skips everything doesn't create
        // an empty history entry (and the existing rows already have a record).
        // Additive model, so this never changes the returned result or the
        // summary alert; it's purely a side record.
        //
        // Gated on `recordsImportHistory` (#247): a photo import passes false so
        // it never appears in the statement Parsed Files & Imports history —
        // that history is for statement PDFs, and a photo has no file name to
        // group under. Statements keep the default (true).
        if recordsImportHistory, imported > 0 {
            let record = LocalStatementImport(
                fileName: statementFileName,
                statementLabel: statementLabel,
                imported: imported,
                skippedDuplicates: skippedDuplicates,
                ignoredNonSpend: ignoredNonSpend,
                failed: failed,
                refunds: refunds,
                possiblyTruncated: possiblyTruncated,
                importedExpenseUUIDs: importedUUIDs,
                deposits: deposits
            )
            store.context.insert(record)
            try? store.context.save()
        }

        return StatementImportResult(
            imported: imported,
            refunds: refunds,
            skippedDuplicates: skippedDuplicates,
            ignoredNonSpend: ignoredNonSpend,
            failed: failed,
            possiblyTruncated: possiblyTruncated,
            importedUUIDs: importedUUIDs,
            deposits: deposits,
            depositsTotalSGD: depositsTotalSGD
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
