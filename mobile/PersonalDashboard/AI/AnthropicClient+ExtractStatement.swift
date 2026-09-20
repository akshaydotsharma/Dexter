import Foundation

/// One parsed line off a credit-card statement. Mirrors the JSON schema the
/// model is instructed to emit for the batch-import path (#184). Unlike the
/// single-receipt `ExtractedExpense`, statement lines are terse and the model
/// is asked to fill every field it can read — a statement row almost always
/// has a merchant, date, and amount, so these are non-optional with a null
/// tolerance handled at decode time.
///
/// `type` classifies the line so the importer can drop card payments and
/// refunds (which the positive-only `LocalExpense` model can't represent) while
/// still counting them for the summary. `category` is the **raw enum value**
/// (e.g. "food_and_dining"), matching how the `add_expense` tool schema
/// advertises categories, so it maps straight onto `LocalExpense.category`.
struct ExtractedStatementLine: Decodable, Sendable, Equatable {
    let merchant: String?
    let date: String?          // "YYYY-MM-DD"
    let amount: Double?
    let currency: String?      // ISO 4217
    let type: LineType?
    let category: String?      // ExpenseCategory.rawValue

    /// Optional itemized / free-text description for the line. The STATEMENT
    /// prompt never emits it (statement rows have no per-line detail), so it
    /// stays nil there and statements are unaffected. The PHOTO / receipt
    /// prompt (#247) uses it to carry the same short line-item summary the
    /// single-receipt path produces, so a receipt imported via the multi-expense
    /// path keeps its description. `decodeIfPresent` + a nil default keeps every
    /// existing decode and call site unchanged.
    let description: String?

    /// The transaction description EXACTLY as printed on the statement,
    /// verbatim (including any trailing location / country tokens and reference
    /// codes), with NO cleanup or reformatting (#208). Used ONLY as the stable
    /// dedup key: the numeric columns (amount / date / currency) are stable
    /// across extraction runs, but the model paraphrases `merchant` differently
    /// each run, which broke re-import idempotency. The verbatim descriptor is
    /// copied off the page character-for-character, so it's identical across
    /// runs. Optional so older / partial responses without it still decode; the
    /// importer falls back to `merchant` for the key when it's nil/empty.
    let descriptor: String?

    /// Statement line classification. Purchases, fees, and interest become
    /// expenses; payments (transfers to the card), refunds/credits, and bank
    /// deposits are tallied and skipped because `LocalExpense` stores only
    /// positive spend.
    ///
    /// `deposit` is the bank-statement addition (#243): money received INTO a
    /// bank / savings / current account (salary, an incoming transfer, an
    /// interest credit) that is NOT a refund of a prior card purchase. It is
    /// kept DISTINCT from `payment` so the importer can count and REPORT
    /// deposits separately (with a total) rather than folding them into the card
    /// "payment" bucket. On a credit-card statement this type essentially never
    /// appears.
    enum LineType: String, Decodable, Sendable {
        case purchase
        case fee
        case interest
        case payment
        case refund
        case deposit

        /// True when this line represents money spent (a debit). Payments,
        /// refunds, and deposits are NOT spend. Kept for callers that need the
        /// strict spend/credit distinction; import routing uses `shouldImport`.
        var isSpend: Bool {
            switch self {
            case .purchase, .fee, .interest:   return true
            case .payment, .refund, .deposit:  return false
            }
        }

        /// True when this line should be IMPORTED as a `LocalExpense` (#206).
        /// Spend types import as expenses; a `refund` also imports, but as a
        /// credit (`isRefund: true`) that nets against totals. A `payment` (a
        /// transfer TO the card that reduces the balance) is NEVER imported —
        /// it's counted and skipped, because it isn't spending and double-counts
        /// against the purchases it paid off. A `deposit` (money into a bank
        /// account) is likewise never imported: income isn't tracked yet, so it
        /// is counted and reported, never stored (#243).
        var shouldImport: Bool {
            switch self {
            case .purchase, .fee, .interest, .refund: return true
            case .payment, .deposit:                  return false
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case merchant
        case date
        case amount
        case currency
        case type
        case category
        case descriptor
        case description
    }

    /// Lenient decode: an unrecognised `type` string decodes to nil rather than
    /// failing the whole array, so one odd row never sinks a 40-line statement.
    /// `descriptor` is `decodeIfPresent`, so a response (or a JSON-recovery
    /// prefix) that omits it decodes cleanly to nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        merchant = try c.decodeIfPresent(String.self, forKey: .merchant)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        type = (try? c.decodeIfPresent(LineType.self, forKey: .type)) ?? nil
        category = try c.decodeIfPresent(String.self, forKey: .category)
        descriptor = try c.decodeIfPresent(String.self, forKey: .descriptor)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    /// Direct memberwise init for tests. `descriptor` and `description` default
    /// to nil so existing call sites that don't exercise them stay unchanged.
    init(merchant: String?, date: String?, amount: Double?, currency: String?, type: LineType?, category: String?, descriptor: String? = nil, description: String? = nil) {
        self.merchant = merchant
        self.date = date
        self.amount = amount
        self.currency = currency
        self.type = type
        self.category = category
        self.descriptor = descriptor
        self.description = description
    }
}

/// Statement-level header metadata, extracted ONCE per PDF (not per line) so
/// each imported expense can record which statement it came from — e.g.
/// "May 2026 Citi - 1234" (#189). Every field is optional because a statement
/// may not expose all of them (a terse export might omit the issuer name, or
/// mask the card number entirely); the label builder degrades gracefully when
/// pieces are missing rather than inventing "Unknown".
struct ExtractedStatementMeta: Decodable, Sendable, Equatable {
    /// Card issuer / bank as printed on the statement (e.g. "Citi", "DBS",
    /// "Amex"). nil when the statement doesn't name it plainly.
    let issuer: String?
    /// Last 4 digits of the card number, as a string (leading zeros matter).
    let last4: String?
    /// Billing / statement month, 1-12. nil when unreadable.
    let statementMonth: Int?
    /// Billing / statement year, four digits. nil when unreadable.
    let statementYear: Int?

    enum CodingKeys: String, CodingKey {
        case issuer
        case last4
        case statementMonth
        case statementYear
    }

    /// Lenient decode: any field the model omits or emits as the wrong JSON
    /// type decodes to nil rather than failing the whole extraction. `last4`
    /// tolerates a number-typed value (some models emit `1234` not `"1234"`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issuer = (try? c.decodeIfPresent(String.self, forKey: .issuer)).flatMap { $0 }
        if let s = try? c.decodeIfPresent(String.self, forKey: .last4) {
            last4 = s
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .last4) {
            last4 = String(n)
        } else {
            last4 = nil
        }
        statementMonth = (try? c.decodeIfPresent(Int.self, forKey: .statementMonth)).flatMap { $0 }
        statementYear = (try? c.decodeIfPresent(Int.self, forKey: .statementYear)).flatMap { $0 }
    }

    /// Direct memberwise init for tests.
    init(issuer: String?, last4: String?, statementMonth: Int?, statementYear: Int?) {
        self.issuer = issuer
        self.last4 = last4
        self.statementMonth = statementMonth
        self.statementYear = statementYear
    }

    /// Human-readable attribution label — "<Month YYYY> <Issuer> - <last4>",
    /// e.g. "May 2026 Citi - 1234". Each piece is omitted gracefully when
    /// missing:
    ///   - period ("May 2026") needs BOTH month (1-12) and year.
    ///   - card ("Citi - 1234") uses whichever of issuer / last4 is present,
    ///     joined with " - " only when both exist.
    /// When issuer, last4, AND period are all missing this is "" (the caller
    /// stores nothing rather than a placeholder like "Unknown").
    var attributionLabel: String {
        var pieces: [String] = []
        if let period { pieces.append(period) }
        let card = cardLabel
        if !card.isEmpty { pieces.append(card) }
        return pieces.joined(separator: " ")
    }

    /// "<Issuer> - <last4>" for the expense's payment method, using whichever
    /// pieces exist ("Citi - 1234", "Citi", "1234", or "").
    var cardLabel: String {
        let trimmedIssuer = issuer?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLast4 = normalizedLast4
        switch (trimmedIssuer?.isEmpty == false ? trimmedIssuer : nil, trimmedLast4) {
        case let (issuer?, last4?): return "\(issuer) - \(last4)"
        case let (issuer?, nil):    return issuer
        case let (nil, last4?):     return last4
        case (nil, nil):            return ""
        }
    }

    /// "May 2026" when both month and year are present and valid; nil otherwise.
    var period: String? {
        guard let statementYear, statementYear > 0,
              let statementMonth, (1...12).contains(statementMonth) else { return nil }
        let monthName = Self.monthSymbols[statementMonth - 1]
        return "\(monthName) \(statementYear)"
    }

    /// last4 reduced to digits, kept only when exactly 4 remain (guards against
    /// the model returning a masked string like "****1234" or a full PAN).
    private var normalizedLast4: String? {
        let digits = (last4 ?? "").filter { $0.isNumber }
        return digits.count == 4 ? digits : nil
    }

    /// Full English month names, POSIX locale, so "May 2026" renders the same
    /// regardless of device locale (matches how the rest of Finance formats).
    private static let monthSymbols: [String] = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.monthSymbols
    }()
}

/// Errors surfaced to the Finance UI when statement extraction fails. Distinct
/// from `ReceiptExtractionError` so the import summary can phrase them for the
/// batch context ("couldn't read the statement" vs "couldn't read the receipt").
enum StatementExtractionError: LocalizedError {
    case notConfigured
    case transport(Error)
    case http(Int, String)
    case noJSON
    case parse(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Anthropic API key not configured."
        case .transport(let err):
            return "Couldn't reach Anthropic. \(err.localizedDescription)"
        case .http(let status, let preview):
            return "Anthropic API HTTP \(status). \(preview)"
        case .noJSON:
            return "Couldn't find a JSON array in Claude's response."
        case .parse(let err):
            return "Couldn't parse Claude's response. \(err.localizedDescription)"
        }
    }
}

/// Where an interrupted or stopped statement run got to, so a later attempt
/// can pick up from there instead of paying for the chunks already read
/// (#635).
///
/// `PDFChunker.split` is deterministic for a given PDF and page size, so
/// the COUNT of chunks already read is enough to identify which ones to
/// skip: the same file always splits the same way. `meta` carries the
/// header forward, because a statement prints it on page 1 and a resumed
/// run never reads page 1 again; without it every resumed row would lose
/// its card attribution and payment method (#189).
struct StatementResumePoint: Sendable, Equatable {
    let chunksCompleted: Int
    let chunksTotal: Int
    let meta: ExtractedStatementMeta

    /// False once every chunk has been read, so a finished run never offers
    /// a Resume that would do nothing.
    var hasUnreadChunks: Bool { chunksCompleted < chunksTotal }
}

/// The outcome of one statement extraction run (#635). Replaces the 4-tuple
/// this returned before, because a run now has THREE ways of ending early
/// and each needs its own copy, plus a resume point the caller can act on.
struct StatementExtraction: Sendable {
    let lines: [ExtractedStatementLine]
    let meta: ExtractedStatementMeta
    /// A chunk hit the model's output-token ceiling, so its tail rows never
    /// came through. ORed across chunks.
    ///
    /// Since #637 this is only ever true when the self-healing re-split ALSO
    /// failed: a truncated chunk is re-read as halves of its own page range
    /// first, and only a range that is down to a single page (or has run out
    /// of recursion depth) and still truncates reaches the user as a warning.
    let possiblyTruncated: Bool
    /// The page ranges that stayed truncated after the re-split, in the
    /// original statement's 1-based page numbers (#637). Lets the summary say
    /// "pages 7 to 9 were only partly read" rather than "some transactions may
    /// be missing". Empty on a clean run, and `possiblyTruncated` is exactly
    /// `!truncatedPageRanges.isEmpty` for every run that came through the
    /// chunk loop.
    let truncatedPageRanges: [PDFPageRange]
    /// Why the run ended before the last chunk, or nil when it read
    /// everything.
    let stopReason: StopReason?
    /// Chunks read in total, counting any skipped by a resume.
    let chunksCompleted: Int
    let chunksTotal: Int

    /// Three causes, three remedies, so three signals. `possiblyTruncated`
    /// is deliberately NOT one of them: that is the model running out of
    /// output budget on a chunk it DID read, not the run ending early.
    enum StopReason: Sendable, Equatable {
        /// The user tapped Stop. The loop taps out at the next chunk
        /// boundary.
        case stoppedByUser
        /// A chunk threw: the request died mid-run (the phone locked and
        /// iOS suspended the app, the network dropped, the API errored).
        /// Everything read before it is kept.
        case interrupted
    }

    /// Where to pick up from, or nil when there is nothing left to read.
    var resumePoint: StatementResumePoint? {
        guard stopReason != nil, chunksCompleted < chunksTotal else { return nil }
        return StatementResumePoint(
            chunksCompleted: chunksCompleted,
            chunksTotal: chunksTotal,
            meta: meta
        )
    }
}

/// What one chunk call yields. Named so the merge loop below can be handed
/// a stub extractor in tests without a live Anthropic call.
typealias StatementChunkResult = (lines: [ExtractedStatementLine], meta: ExtractedStatementMeta, possiblyTruncated: Bool)


extension AnthropicClient {
    /// Per-chunk token budget for statement extraction. Output scales with the
    /// transaction count (~30-70 tokens per line). The primary guard against a
    /// dropped tail is now page chunking (see `extractStatement` / `PDFChunker`),
    /// which keeps each request to ~80 lines; this raised ceiling is the
    /// secondary guard so an individual chunk essentially never truncates.
    /// Sonnet 4.5 supports far more than the old 8192, so 16384 leaves generous
    /// headroom. A chunk that somehow still hits the ceiling sets
    /// `possiblyTruncated`, which propagates to a prominent warning in the
    /// import summary (see `StatementImporter`).
    ///
    /// Reviewed under #554 and left alone. It is the one cap in `AI/` that was
    /// already sized against its own output (a transaction array, ~30-70 tokens
    /// a line, chunked to ~80 lines) rather than inherited, and it already
    /// reports `possiblyTruncated` when it is hit.
    static let statementMaxTokens = 16384

    /// Extract every transaction line from a credit-card statement PDF (#184),
    /// splitting large statements into page-range chunks so nothing is lost to
    /// the output-token ceiling (#202).
    ///
    /// Small statements (≤ one chunk's worth of pages) take the single-call
    /// path unchanged. Larger statements are split by `PDFChunker` and each
    /// chunk is extracted SEQUENTIALLY (not in parallel — the on-device tool
    /// loop and API rate limits favour serial calls, and it avoids hammering
    /// the key). The per-chunk line arrays are concatenated into one list; the
    /// header/meta is taken from the first chunk that yields it (statements
    /// print it on page 1). `possiblyTruncated` is the OR across chunks, so the
    /// truncation warning still fires if any single chunk ran out of budget.
    ///
    /// Page-boundary duplicates (a rare row read on both sides of a split) are
    /// harmless: the merged list flows through the EXISTING `ExpenseDedupe` in
    /// `StatementImporter.insert`, which collapses structural duplicates.
    /// `onProgress` reports (chunks finished, chunks in total) after each chunk
    /// lands, so a caller can show "3 of 5" rather than an unchanging spinner
    /// (#498). It is called on the main actor and is awaited, so the reports
    /// arrive in order. A single-chunk statement reports (1, 1) once.
    ///
    /// `cancellation` is polled BETWEEN chunks (#498). When it is set, the loop
    /// stops and returns the lines read so far, flagged `.stoppedByUser`, rather
    /// than throwing: those rows still insert, and a later re-import is
    /// idempotent, so a stopped run self-heals. Cancelling the `Task` instead
    /// would make the insert pass's FX lookups throw and count every non-SGD
    /// row as failed.
    ///
    /// A chunk that THROWS is treated the same way (#635). Before, the loop had
    /// no `catch`, so one dead request threw straight out of here and every
    /// chunk already read was discarded: a 10-chunk statement that failed at
    /// chunk 8 imported nothing after paying for seven extractions. Now the
    /// loop breaks and returns what it has, flagged `.interrupted`. The one
    /// exception is a failure with nothing read yet, which still throws: there
    /// is nothing to salvage and the user needs the real error.
    ///
    /// `resumingFrom` skips the chunks a previous run already read (#635).
    func extractStatement(
        pdfData: Data,
        resumingFrom: StatementResumePoint? = nil,
        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil,
        cancellation: ImportCancellationToken? = nil
    ) async throws -> StatementExtraction {
        let chunks = PDFChunker.split(pdfData)
        return try await Self.runStatementChunks(
            chunks: chunks,
            wholePDF: pdfData,
            resumingFrom: resumingFrom,
            onProgress: onProgress,
            cancellation: cancellation,
            extractChunk: { chunk in
                // The log path names the chunk AND its pages, so one console
                // line answers "which part of the file was this?" on its own
                // (#637). A re-split half falls inside its parent chunk, so it
                // reports that chunk's number with its own narrower range.
                let owner = chunks.firstIndex {
                    $0.pages.first <= chunk.pages.first && chunk.pages.last <= $0.pages.last
                }
                let which = owner.map { "chunk \($0 + 1) of \(chunks.count)" }
                    ?? "chunk ? of \(chunks.count)"
                return try await self.extractStatementChunk(
                    pdfData: chunk.data,
                    logPath: "statement \(which) \(chunk.pages.label)"
                )
            }
        )
    }

    /// The chunk loop, split out from `extractStatement` so it can be driven by
    /// a stub extractor in tests (#635). Everything that decides what a partial
    /// run returns lives here; the instance method above only supplies the real
    /// per-chunk Anthropic call.
    static func runStatementChunks(
        chunks: [PDFChunk],
        wholePDF: Data,
        resumingFrom: StatementResumePoint? = nil,
        onProgress: (@MainActor @Sendable (Int, Int) -> Void)? = nil,
        cancellation: ImportCancellationToken? = nil,
        splitChunk: @Sendable (PDFChunk) -> [PDFChunk]? = { PDFChunker.halves(of: $0) },
        maxResplitDepth: Int = defaultMaxResplitDepth,
        extractChunk: (PDFChunk) async throws -> StatementChunkResult
    ) async throws -> StatementExtraction {
        // Single chunk (small or unsplittable statement): identical behaviour
        // to the pre-#202 path — one call, same request bytes. A failure here
        // still throws, because there is no earlier chunk to salvage. A
        // truncation still re-splits (#637): a one-chunk statement is exactly
        // the case the old code lost the most rows on.
        if chunks.count <= 1 {
            let only = chunks.first ?? PDFChunk(
                data: wholePDF,
                pages: PDFPageRange(first: 1, last: 1)
            )
            let read = try await readHealingTruncation(
                only,
                depth: 0,
                maxDepth: maxResplitDepth,
                splitChunk: splitChunk,
                extractChunk: extractChunk
            )
            await onProgress?(1, 1)
            return StatementExtraction(
                lines: read.lines,
                meta: read.meta,
                possiblyTruncated: !read.truncatedRanges.isEmpty,
                truncatedPageRanges: read.truncatedRanges,
                stopReason: nil,
                chunksCompleted: 1,
                chunksTotal: 1
            )
        }

        // A resume starts at the chunk the last run stopped on, and inherits
        // that run's header: page 1 is behind us and will not be read again.
        let startIndex = min(max(resumingFrom?.chunksCompleted ?? 0, 0), chunks.count)
        var mergedLines: [ExtractedStatementLine] = []
        var mergedMeta: ExtractedStatementMeta? = resumingFrom.flatMap {
            Self.metaHasContent($0.meta) ? $0.meta : nil
        }
        var truncatedRanges: [PDFPageRange] = []
        var stopReason: StatementExtraction.StopReason?
        var completed = startIndex

        for index in startIndex..<chunks.count {
            // Poll before spending the call, so a cancel taps out at the next
            // boundary rather than after one more multi-second request.
            if cancellation?.isCancelled == true {
                stopReason = .stoppedByUser
                break
            }

            let chunk: ChunkRead
            do {
                chunk = try await readHealingTruncation(
                    chunks[index],
                    depth: 0,
                    maxDepth: maxResplitDepth,
                    splitChunk: splitChunk,
                    extractChunk: extractChunk
                )
            } catch {
                // Nothing read this run: there is nothing to keep, and a silent
                // "imported 0" would hide a real, actionable error (a bad key,
                // an unreadable PDF). Let it out.
                guard index > startIndex else { throw error }
                // Otherwise keep every chunk already read and report WHY the
                // rest is missing. Re-importing is idempotent (`ExpenseDedupe`),
                // so these rows cost nothing on a later full run.
                NSLog("extractStatement: chunk %d of %d (%@) failed, keeping %d lines: %@",
                      index + 1, chunks.count, chunks[index].pages.label,
                      mergedLines.count, error.localizedDescription)
                stopReason = .interrupted
                break
            }

            mergedLines.append(contentsOf: chunk.lines)
            truncatedRanges.append(contentsOf: chunk.truncatedRanges)
            // Take the header from the FIRST chunk that carries any readable
            // field (the statement header lives on page 1). Once found, keep it
            // — a later page must never overwrite it with an invented header.
            if mergedMeta == nil, Self.metaHasContent(chunk.meta) {
                mergedMeta = chunk.meta
            }
            completed = index + 1
            await onProgress?(completed, chunks.count)
        }

        let finalMeta = mergedMeta ?? ExtractedStatementMeta(
            issuer: nil, last4: nil, statementMonth: nil, statementYear: nil
        )
        return StatementExtraction(
            lines: mergedLines,
            meta: finalMeta,
            possiblyTruncated: !truncatedRanges.isEmpty,
            truncatedPageRanges: truncatedRanges,
            stopReason: stopReason,
            chunksCompleted: completed,
            chunksTotal: chunks.count
        )
    }

    /// How many times a truncated range may be halved before the warning
    /// stands (#637). Three levels take a default 3-page chunk to single
    /// pages twice over, so the cap is a guard against a pathological PDF
    /// rather than a limit anyone should reach. It also bounds the worst case
    /// cost: a chunk can cost at most `2^depth` extra calls.
    static let defaultMaxResplitDepth = 3

    /// What reading ONE chunk produced, after any self-healing re-split.
    struct ChunkRead {
        let lines: [ExtractedStatementLine]
        let meta: ExtractedStatementMeta
        /// Page ranges that were STILL truncated when the recursion stopped.
        /// Empty means every row came through.
        let truncatedRanges: [PDFPageRange]
    }

    /// Read one chunk, and when the model runs out of output budget on it,
    /// read its two halves instead (#637).
    ///
    /// The old behaviour accepted the partial array: `linesArray` trimmed the
    /// cut-off JSON back to its last complete element, so the chunk kept its
    /// first rows and dropped its tail, silently. Halving the page range gives
    /// each half the WHOLE output budget, which is nearly always enough.
    ///
    /// The truncated attempt's rows are DISCARDED, never merged with the
    /// re-read: the halves cover the same pages, so keeping both would double
    /// every row the partial read did manage. (`ExpenseDedupe` would collapse
    /// most of them later, but "most" is not a property worth relying on.)
    ///
    /// Recursion stops on three conditions, and each one falls back to today's
    /// warning for that range only: the depth cap is reached, the range is a
    /// single page, or the bytes cannot be re-split.
    ///
    /// A half that THROWS propagates. The caller treats that as `.interrupted`
    /// and offers Resume, which re-reads the whole chunk from scratch. That is
    /// deliberate: keeping one good half and resuming from the next chunk would
    /// leave the other half's pages unread with nothing recording the gap.
    static func readHealingTruncation(
        _ chunk: PDFChunk,
        depth: Int,
        maxDepth: Int,
        splitChunk: @Sendable (PDFChunk) -> [PDFChunk]?,
        extractChunk: (PDFChunk) async throws -> StatementChunkResult
    ) async throws -> ChunkRead {
        let result = try await extractChunk(chunk)
        guard result.possiblyTruncated else {
            return ChunkRead(lines: result.lines, meta: result.meta, truncatedRanges: [])
        }

        guard depth < maxDepth, let halves = splitChunk(chunk), halves.count > 1 else {
            NSLog("extractStatement: %@ truncated and cannot be split further (depth %d), keeping %d partial lines",
                  chunk.pages.label, depth, result.lines.count)
            // Nothing left to try: keep the partial rows, exactly as before
            // #637, and name the range so the summary can say which pages.
            return ChunkRead(
                lines: result.lines,
                meta: result.meta,
                truncatedRanges: [chunk.pages]
            )
        }

        NSLog("extractStatement: %@ hit max_tokens, re-reading as %d halves (depth %d)",
              chunk.pages.label, halves.count, depth + 1)

        var lines: [ExtractedStatementLine] = []
        // The truncated attempt still parsed the header (it is emitted FIRST,
        // ahead of the lines array), so it is a valid fallback if no half
        // reads one.
        var meta = result.meta
        var ranges: [PDFPageRange] = []
        for half in halves {
            let read = try await readHealingTruncation(
                half,
                depth: depth + 1,
                maxDepth: maxDepth,
                splitChunk: splitChunk,
                extractChunk: extractChunk
            )
            lines.append(contentsOf: read.lines)
            ranges.append(contentsOf: read.truncatedRanges)
            if !Self.metaHasContent(meta), Self.metaHasContent(read.meta) {
                meta = read.meta
            }
        }
        return ChunkRead(lines: lines, meta: meta, truncatedRanges: ranges)
    }

    /// True when a parsed header carries at least one readable field, so the
    /// chunk-merge only adopts a header that actually came off the statement
    /// rather than an all-nil placeholder.
    private static func metaHasContent(_ meta: ExtractedStatementMeta) -> Bool {
        meta.issuer != nil || meta.last4 != nil
            || meta.statementMonth != nil || meta.statementYear != nil
    }

    /// Send ONE statement PDF (a whole small statement, or a single page-range
    /// chunk of a large one) to Claude and ask for every transaction line as a
    /// JSON array (#184). Uses a native `document` block (behind the
    /// `pdfs-2024-09-25` beta header) so Claude reads the PDF directly — this
    /// sidesteps the 6000-char text cap in `EmailAttachmentProcessor.pdfText`,
    /// which a multi-page statement would blow past.
    ///
    /// Returns the parsed lines, the statement header metadata (#189), plus
    /// whether the model likely ran out of output tokens (stop_reason ==
    /// "max_tokens"). The header sits at the FRONT of the emitted object, so it
    /// survives even when the trailing `lines` array is truncated.
    ///
    /// `logPath` names this chunk in the console line the call prints (#637),
    /// e.g. "statement pages 7 to 9". It is the whole of what makes a future
    /// truncation diagnosable without a rebuild: the line carries the page
    /// range, the billed token counts, the `stop_reason`, and how many rows
    /// the chunk produced.
    func extractStatementChunk(
        pdfData: Data,
        logPath: String = "statement chunk"
    ) async throws -> (lines: [ExtractedStatementLine], meta: ExtractedStatementMeta, possiblyTruncated: Bool) {
        let base64 = pdfData.base64EncodedString()
        let content: [AnthropicJSONValue] = [
            .object([
                "type": .string("document"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string("application/pdf"),
                    "data": .string(base64)
                ])
            ]),
            .object([
                "type": .string("text"),
                "text": .string(Self.statementPrompt)
            ])
        ]
        return try await runStatementExtraction(
            content: content,
            extraHeaders: ["anthropic-beta": "pdfs-2024-09-25"],
            logPath: logPath
        )
    }

    // MARK: - Core

    /// Internal (not `private`) so the image multi-expense extractor
    /// (`extractExpenses(imageData:mediaType:)`, #247) can reuse the exact same
    /// object-wrapper parsing, bare-array fallback, truncated-array recovery,
    /// 120s timeout, and lenient per-line decode. Behaviour is unchanged.
    ///
    /// `logPath` labels the one console line this call prints (#637). Before
    /// that ticket this was the ONLY extraction path in `AI/` that never
    /// called `logUsage`, unlike `send` and `stream`, so a statement that lost
    /// rows to the output ceiling left nothing behind to diagnose it with.
    func runStatementExtraction(
        content: [AnthropicJSONValue],
        extraHeaders: [String: String],
        logPath: String = "statement"
    ) async throws -> (lines: [ExtractedStatementLine], meta: ExtractedStatementMeta, possiblyTruncated: Bool) {
        guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
            throw StatementExtractionError.notConfigured
        }

        // Hand-rolled body (same rationale as `runExtraction`): heterogeneous
        // content blocks + a per-call max_tokens override the shared
        // `AnthropicRequest` wire type doesn't expose.
        //
        // NOT prompt-cached (#580). Same shape as `runExtraction`: no system
        // field, no tools, and every chunk carries a different page of the
        // statement. A multi-chunk import does repeat this call, but the bytes
        // it repeats are the instructions inside each chunk's own content
        // block, which is not a prefix the two chunks share.
        let body: AnthropicJSONValue = .object([
            "model": .string(Self.model),
            "max_tokens": .int(Self.statementMaxTokens),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .array(content)
                ])
            ])
        ])

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        for (k, v) in extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
        // A full-statement PDF read + large generation runs longer than the
        // single-receipt call. Give it generous headroom over the 90s used
        // there.
        request.timeoutInterval = 120

        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw StatementExtractionError.parse(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StatementExtractionError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StatementExtractionError.http(0, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(800), encoding: .utf8) ?? "<non-utf8 bytes>"
            throw StatementExtractionError.http(http.statusCode, preview)
        }

        let decoded: AnthropicResponse
        do {
            decoded = try Self.decoder.decode(AnthropicResponse.self, from: data)
        } catch {
            throw StatementExtractionError.parse(error)
        }

        let combinedText = decoded.content.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: "\n")

        // The model now wraps the result in an object:
        //   { "statement": { issuer, last4, statementMonth, statementYear },
        //     "lines": [ ... ] }
        // The header comes FIRST so it stays intact even when the trailing
        // `lines` array is truncated by the token ceiling. We pull the two
        // parts out separately: the header via a tolerant object scan, the
        // lines via the existing array recovery (which trims a truncated array
        // back to its last complete element). This preserves the #184
        // large-statement recovery behaviour untouched.
        guard let arrayString = Self.linesArray(in: combinedText),
              let arrayData = arrayString.data(using: .utf8) else {
            throw StatementExtractionError.noJSON
        }
        let lines: [ExtractedStatementLine]
        do {
            lines = try Self.decoder.decode([ExtractedStatementLine].self, from: arrayData)
        } catch {
            throw StatementExtractionError.parse(error)
        }

        // Header is best-effort: a statement with no readable header still
        // imports fine, just without an attribution label. Never fail the whole
        // import over a missing/garbled header.
        let meta = Self.statementMeta(in: combinedText) ?? ExtractedStatementMeta(
            issuer: nil, last4: nil, statementMonth: nil, statementYear: nil
        )

        // `max_tokens` stop means the generation was cut off mid-array — for a
        // large statement the tail rows are missing. `firstJSONArray` still
        // recovers the well-formed prefix, so we return what parsed plus the
        // truncation flag.
        let truncated = decoded.stop_reason == "max_tokens"

        // Two lines, one call: the shared usage counters (so output_tokens can
        // be read against the ceiling) and the two facts only this path knows,
        // the stop reason and how many rows the chunk actually produced (#637).
        // Counters only, no prompt text and no key, same as every other
        // `logUsage` site.
        Self.logUsage(decoded.usage, path: logPath)
        NSLog("[anthropic] %@ stop_reason=%@ lines=%d max_tokens=%d",
              logPath,
              decoded.stop_reason ?? "nil",
              lines.count,
              Self.statementMaxTokens)

        return (lines, meta, truncated)
    }

    // MARK: - Prompt + parsing

    /// Enum raw values advertised to the model, so it returns categories that
    /// map straight onto `LocalExpense.category`. Kept in sync with
    /// `ExpenseCategory` the same way the `add_expense` tool schema is.
    /// Internal (not `private`) so the photo multi-expense prompt in
    /// `AnthropicClient+ExtractExpense.swift` reuses the same raw-value list
    /// rather than duplicating it (#247).
    static var categoryRawList: String {
        ExpenseCategory.allCases
            .map { $0.rawValue }
            .joined(separator: ", ")
    }

    static let statementPrompt: String = """
    This is a financial statement PDF. It may be a CREDIT-CARD statement OR a
    BANK / SAVINGS / CURRENT account statement (e.g. a DBS Multiplier account).
    First determine which kind it is, because they encode the direction of money
    differently (see the direction rules below). Then extract the statement
    HEADER plus EVERY transaction line item. Return STRICT JSON inside a ```json
    fence and nothing else — no prose before or after.

    Return a single JSON OBJECT with exactly two keys, in this order:
    {
      "statement": {
        "issuer": "Citi",
        "last4": "1234",
        "statementMonth": 5,
        "statementYear": 2026
      },
      "lines": [
        {
          "merchant": "Starbucks",
          "descriptor": "STARBUCKS @ ION ORCHARD SINGAPORE SG",
          "date": "YYYY-MM-DD",
          "amount": 12.34,
          "currency": "SGD",
          "type": "purchase",
          "category": "food_and_dining"
        }
      ]
    }

    Put "statement" FIRST, before "lines".

    Statement header rules ("statement" object):
    - "issuer": the card issuer / bank name as printed on the statement (e.g.
      "Citi", "DBS", "HSBC", "American Express"). Use the short brand name, not
      the full legal entity. null if the statement doesn't name it.
    - "last4": the LAST FOUR digits of the card number, as a 4-character STRING
      (e.g. "1234", keep any leading zeros). Statements usually mask the card as
      "**** **** **** 1234" or "XXXX-1234" — return just the trailing 4 digits.
      null if the card number isn't shown at all.
    - "statementMonth" / "statementYear": the billing period the statement
      covers, as integers (month 1-12, four-digit year). Use the statement /
      closing date's month and year (e.g. a statement dated "15 May 2026" →
      month 5, year 2026). null for either if you genuinely can't tell.
    - Any header field you cannot read from the statement must be null. Do NOT
      guess or invent an issuer, card number, or period.

    Transaction line rules ("lines" array):
    - Return one element per transaction line on the statement. Include ALL of
      them: purchases, fees, interest charges, card payments, refunds, and
      (on a bank account) deposits.
    - "merchant" is the clean, human-readable merchant / vendor name for display
      (e.g. "Starbucks", "Shopee"). Tidy it up as you normally would.
    - "descriptor" is the transaction description EXACTLY as printed on the
      statement — verbatim, character-for-character. Copy the raw description
      text as-is, INCLUDING any trailing location, city, or country tokens and
      any reference / merchant codes (e.g. "STARBUCKS @ ION ORCHARD SINGAPORE
      SG", "SHOPEE SINGAPORE Shopee SINGAPORE", "AMZN Mktp SG*A1B2C3"). Do NOT
      clean it up, expand abbreviations, fix casing, remove codes, or reformat
      it in any way — it must match the statement text so the same line reads
      identically every time. Return the same descriptor value even for a
      payment or refund. Only if a line genuinely has no printed description at
      all, set it to the same value as "merchant".
    - "amount" is always a POSITIVE number (the magnitude of the line). Never
      emit a negative amount; the sign is conveyed by "type" instead.

    - DIRECTION — how to tell money OUT from money IN (read this before typing
      any line):
        - CREDIT-CARD statement: classify each line from its description /
          section as usual (purchases and fees increase the balance owed;
          payments and refunds decrease it).
        - BANK / SAVINGS / CURRENT account statement: the direction is set by
          the COLUMN the amount sits in, NOT by the description wording. A
          "Withdrawal" / "Debit" / "Money Out" / "Paid Out" column = money OUT
          (spend). A "Deposit" / "Credit" / "Money In" / "Paid In" column =
          money IN. If the columns are ambiguous or merged, use the running
          BALANCE delta: if the balance DECREASED on that line, money went OUT;
          if it INCREASED, money came IN.
        - Do NOT infer direction from words like "Collection", "Payment",
          "Receipt", "Transfer", "FAST", or "GIRO" — on a bank statement these
          appear on BOTH directions and are unreliable. For example a DBS
          "Advice FAST Payment / Receipt" or a "FAST Collection" line can be
          money OUT even though it reads like incoming money: trust the column /
          balance drop, not the label. The TO: / FROM: text can help
          disambiguate a genuine tie, but the column / balance is authoritative.

    - "type" is EXACTLY one of: "purchase", "fee", "interest", "payment",
      "refund", "deposit".
        - "purchase": a normal card purchase / spend, OR any bank-account
          WITHDRAWAL / debit (money OUT) that isn't plainly a fee or interest.
        - "fee": a bank fee (annual fee, late fee, foreign-transaction fee,
          cash-advance fee, account service fee). Money OUT.
        - "interest": an interest / finance CHARGE (money OUT). Note: interest
          CREDITED into a bank account is money IN, not a charge — tag that
          "refund" (a "+" credit), not "interest".
        - "payment": a payment that SETTLES A CREDIT CARD. This covers two
          cases, and both must be tagged "payment" (they are NOT spending —
          importing them would double-count against the card purchases they pay
          off, so they are counted and skipped):
            (1) On a CREDIT-CARD statement: a credit that reduces the card
                balance, e.g. "PAYMENT - THANK YOU", autopay, a GIRO card
                payment.
            (2) On a BANK statement: a money-OUT line that pays a credit-card
                bill. Recognise it when the description references a CARD: a
                full 15-16 digit card number or masked PAN, "CARD PAYMENT",
                "CREDIT CARD", "CCC", or a card-network name (Visa / Mastercard /
                Amex). Example: "Advice Bill Payment / CCC - 5425503303732696 :
                I-BANK" is a credit-card bill payment → "payment".
          Do NOT over-apply case (2): a money-OUT bill payment that is NOT a
          credit card stays ordinary spend ("purchase"). Utilities, telco,
          insurance, and TAX (e.g. "GIRO ... IRAS") are real expenses, not
          "payment". Only a line that clearly settles a CARD gets "payment".
        - "refund": a "+" CREDIT that should be recorded as money coming back in
          (it nets against your spending). It is imported with a positive
          amount. Tag "refund" for BOTH of these:
            (1) A reversal / chargeback / cashback / credit on a prior purchase
                (money coming back to you). Give it the merchant, date, amount,
                and category of the purchase it reverses.
            (2) On a BANK statement: money RECEIVED from another PERSON or a
                reimbursement — an incoming PayNow from a named person, a funds
                transfer from a named person, or an expense reimbursement.
                Examples: "Funds Transfer IB:KATYAL PARUL", "INCOMING PAYNOW ...
                FROM: <person>", "SEND BACK FROM PAYLAH!", "EXPENSE REPORT".
                Use the sender's name as the merchant and a sensible category.
          A "refund"-type bank line is NOT limited to card reversals — it is any
          incoming peer money that is not salary.
        - "deposit": money received INTO a bank / savings / current account that
          is SALARY or PAYROLL. This is the ONLY money-in that should be a
          "deposit" (it is skipped and only reported, not imported, because it
          would swamp the spend view). Example: "DEC PAY CWV1L". A credit that
          is clearly payroll → "deposit". For ANY OTHER money-in on a bank
          statement (an incoming transfer from a person, a reimbursement),
          prefer "refund" (case 2 above) so it is recorded as a "+" credit. When
          incoming money is ambiguous, default to "refund"; use "deposit" ONLY
          when it is clearly salary / payroll. On a credit-card statement this
          type essentially never appears.
        - Mapping summary: bank withdrawal / debit → "purchase" (or "fee" /
          "interest" for a bank fee or interest charge, or "payment" when it
          settles a credit-card bill); bank money-in → "refund" for a peer
          transfer / reimbursement, or "deposit" only for salary / payroll;
          credit-card lines keep the purchase / fee / interest / payment /
          refund meanings above.
    - "date" is the transaction date in ISO 8601 (YYYY-MM-DD). Statement lines
      often omit the year (e.g. "07 SEP", "12/09"). Infer the year from the
      statement period / billing cycle shown on the statement. If a line's
      month is earlier than the statement's closing month it may belong to the
      prior year (a December purchase on a January statement) — reason about the
      billing period to get the year right. Never emit year 0, 0001, or 1970.
    - "currency" is the statement's home currency as an ISO 4217 code (detect it
      from the statement — e.g. "SGD", "USD", "GBP"). Most statements are
      single-currency; use that one code for every line. For a FOREIGN
      transaction, use the HOME-CURRENCY posted/billed amount (the converted
      amount the card actually charged), with the home currency code — do NOT
      use the foreign amount. If you genuinely cannot tell the currency,
      default to "SGD".
    - "category" must be EXACTLY one of these raw values: \(categoryRawList).
      Pick the best fit from the merchant: a supermarket / grocery → groceries;
      a restaurant / cafe / bar / dining → food_and_dining; hotels / apartments /
      Airbnb / lodging / bed & breakfast → accommodation; tours / attractions /
      museums / experiences / activity tickets / excursions → activities; local
      taxis / metro / rideshare / buses / trains within a city → transport;
      flights / long-distance rail / long-haul travel fares → travel;
      Netflix/Spotify → subscriptions; a utility → bills_and_utilities; a monthly
      rent/lease payment → rent. For fees and interest use "bills_and_utilities".
      Use "other" only when nothing fits. A refund
      is imported, so give it the category of the purchase it reverses (a
      grocery refund → groceries). For a payment or a deposit, still pick a
      plausible category (both are skipped, so the category is ignored).
    - Do NOT include summary rows, balances, "total", "opening/closing
      balance", minimum-payment lines, or reward-point lines — only real
      transaction lines.
    - Do not invent fields or add commentary outside the JSON fence.
    """

    /// Pull the `"lines"` transaction array out of the model's response (#189).
    ///
    /// The payload is now an OBJECT — `{ "statement": {...}, "lines": [...] }` —
    /// so the old "first `[` in the text" scan (`firstJSONArray`) swallowed the
    /// wrapper object's trailing `}` and produced invalid JSON. We locate the
    /// `"lines"` key, then bracket-match from its opening `[` (ignoring brackets
    /// inside strings) to isolate exactly the array. If the array was truncated
    /// by the token ceiling (no matching `]`), we recover the well-formed prefix
    /// — trim to the last complete object and close the bracket — preserving the
    /// #184 large-statement behaviour. Falls back to `firstJSONArray` when there
    /// is no `"lines"` key (e.g. the model dropped the wrapper and emitted a bare
    /// array).
    static func linesArray(in text: String) -> String? {
        guard let searchStart = text.range(of: "\"lines\"")?.upperBound,
              let bracketStart = text.range(of: "[", range: searchStart..<text.endIndex) else {
            // No wrapper object — fall back to the fenced / bare-array scan.
            return firstJSONArray(in: text)
        }

        // Bracket-match the array, ignoring brackets inside string literals.
        var depth = 0
        var inString = false
        var escaped = false
        var i = bracketStart.lowerBound
        while i < text.endIndex {
            let ch = text[i]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "[" {
                    depth += 1
                } else if ch == "]" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[bracketStart.lowerBound...i])
                    }
                }
            }
            i = text.index(after: i)
        }

        // No closing `]` — the array was truncated mid-stream by the token
        // ceiling. Recover the well-formed prefix: trim to the last complete
        // object and close the bracket (same recovery `firstJSONArray` uses).
        let raw = String(text[bracketStart.lowerBound...])
        if let lastObjectEnd = raw.range(of: "}", options: .backwards) {
            return String(raw[raw.startIndex...lastObjectEnd.lowerBound]) + "]"
        }
        return nil
    }

    /// Pull the first ```json``` fenced JSON ARRAY out of `text`. Falls back to
    /// a bare ``` fence, then to a raw `[ ... ]` array in the text. Also
    /// recovers a well-formed PREFIX of a truncated array (a statement cut off
    /// by the token ceiling ends mid-object): if the full parse would fail, we
    /// trim back to the last complete `}` and close the bracket, so the rows
    /// that DID come through are still usable.
    static func firstJSONArray(in text: String) -> String? {
        func recover(_ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("[") else { return nil }
            // Whole array present and closed — use as-is.
            if trimmed.hasSuffix("]") { return trimmed }
            // Truncated mid-stream: trim to the last complete object and close.
            if let lastObjectEnd = trimmed.range(of: "}", options: .backwards) {
                let prefix = trimmed[trimmed.startIndex...lastObjectEnd.lowerBound]
                return String(prefix) + "]"
            }
            return nil
        }

        // Preferred: ```json ... ```
        if let range = text.range(of: "```json") {
            let after = text[range.upperBound...]
            if let close = after.range(of: "```") {
                if let recovered = recover(String(after[after.startIndex..<close.lowerBound])) {
                    return recovered
                }
            } else {
                // Opening fence but no closing fence — the generation was cut
                // off. Recover from everything after the fence.
                if let recovered = recover(String(after)) { return recovered }
            }
        }
        // Bare ``` fence (no language).
        if let open = text.range(of: "```") {
            let after = text[open.upperBound...]
            if let close = after.range(of: "```") {
                if let recovered = recover(String(after[after.startIndex..<close.lowerBound])) {
                    return recovered
                }
            } else if let recovered = recover(String(after)) {
                return recovered
            }
        }
        // Raw array — model occasionally drops the fence.
        if let open = text.range(of: "[") {
            return recover(String(text[open.lowerBound...]))
        }
        return nil
    }

    /// Pull the statement HEADER object out of the model's response (#189).
    ///
    /// The response is `{ "statement": { ... }, "lines": [ ... ] }`, header
    /// first. We isolate the `"statement": { ... }` object by brace-matching
    /// from the key, so it decodes cleanly even when the trailing `lines` array
    /// is truncated (the header is small and always complete). Returns nil when
    /// the key is absent or the object can't be balanced — the caller treats a
    /// missing header as "no attribution", never a hard failure.
    static func statementMeta(in text: String) -> ExtractedStatementMeta? {
        guard let keyRange = text.range(of: "\"statement\"") else { return nil }
        // Find the opening brace of the statement object after the key/colon.
        guard let braceStart = text.range(of: "{", range: keyRange.upperBound..<text.endIndex) else {
            return nil
        }
        // Brace-match to find the matching close, ignoring braces inside strings.
        var depth = 0
        var inString = false
        var escaped = false
        var endIndex: String.Index?
        var i = braceStart.lowerBound
        while i < text.endIndex {
            let ch = text[i]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = text.index(after: i)
                        break
                    }
                }
            }
            i = text.index(after: i)
        }
        guard let endIndex,
              let data = String(text[braceStart.lowerBound..<endIndex]).data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(ExtractedStatementMeta.self, from: data)
    }
}
