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

    /// Statement line classification. Purchases, fees, and interest become
    /// expenses; payments (transfers to the card) and refunds/credits are
    /// tallied and skipped because `LocalExpense` stores only positive spend.
    enum LineType: String, Decodable, Sendable {
        case purchase
        case fee
        case interest
        case payment
        case refund

        /// True when this line represents money spent (should become an
        /// expense). Payments and refunds are excluded.
        var isSpend: Bool {
            switch self {
            case .purchase, .fee, .interest: return true
            case .payment, .refund:          return false
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
    }

    /// Lenient decode: an unrecognised `type` string decodes to nil rather than
    /// failing the whole array, so one odd row never sinks a 40-line statement.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        merchant = try c.decodeIfPresent(String.self, forKey: .merchant)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        type = (try? c.decodeIfPresent(LineType.self, forKey: .type)) ?? nil
        category = try c.decodeIfPresent(String.self, forKey: .category)
    }

    /// Direct memberwise init for tests.
    init(merchant: String?, date: String?, amount: Double?, currency: String?, type: LineType?, category: String?) {
        self.merchant = merchant
        self.date = date
        self.amount = amount
        self.currency = currency
        self.type = type
        self.category = category
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

extension AnthropicClient {
    /// Larger token budget for statement extraction. Output scales with the
    /// transaction count (~30-50 tokens per line), so the 1024-token default
    /// used elsewhere would truncate any real statement. 8192 comfortably
    /// covers ~150 lines; beyond that the model may still hit the ceiling and
    /// we surface a `possiblyTruncated` flag on the result so the caller can
    /// warn the user (see `StatementImporter`).
    static let statementMaxTokens = 8192

    /// Send a whole credit-card statement PDF to Claude and ask for every
    /// transaction line as a JSON array (#184). Uses a native `document` block
    /// (behind the `pdfs-2024-09-25` beta header) so Claude reads the full
    /// statement directly — this sidesteps the 6000-char text cap in
    /// `EmailAttachmentProcessor.pdfText`, which a multi-page statement would
    /// blow past.
    ///
    /// Returns the parsed lines, the statement header metadata (#189), plus
    /// whether the model likely ran out of output tokens (stop_reason ==
    /// "max_tokens"), which for a very large statement means the tail was cut
    /// off. The header sits at the FRONT of the emitted object, so it survives
    /// even when the trailing `lines` array is truncated.
    func extractStatement(pdfData: Data) async throws -> (lines: [ExtractedStatementLine], meta: ExtractedStatementMeta, possiblyTruncated: Bool) {
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
            extraHeaders: ["anthropic-beta": "pdfs-2024-09-25"]
        )
    }

    // MARK: - Core

    private func runStatementExtraction(
        content: [AnthropicJSONValue],
        extraHeaders: [String: String]
    ) async throws -> (lines: [ExtractedStatementLine], meta: ExtractedStatementMeta, possiblyTruncated: Bool) {
        guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
            throw StatementExtractionError.notConfigured
        }

        // Hand-rolled body (same rationale as `runExtraction`): heterogeneous
        // content blocks + a per-call max_tokens override the shared
        // `AnthropicRequest` wire type doesn't expose.
        let body: AnthropicJSONValue = .object([
            "model": .string(Self.model),
            "max_tokens": .int(Self.statementMaxTokens),
            "temperature": .double(Self.temperature),
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
        guard let arrayString = Self.firstJSONArray(in: combinedText),
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
        return (lines, meta, truncated)
    }

    // MARK: - Prompt + parsing

    /// Enum raw values advertised to the model, so it returns categories that
    /// map straight onto `LocalExpense.category`. Kept in sync with
    /// `ExpenseCategory` the same way the `add_expense` tool schema is.
    private static var categoryRawList: String {
        ExpenseCategory.allCases
            .map { $0.rawValue }
            .joined(separator: ", ")
    }

    static let statementPrompt: String = """
    This is a credit-card statement PDF. Extract the statement HEADER plus EVERY
    transaction line item. Return STRICT JSON inside a ```json fence and nothing
    else — no prose before or after.

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
      them: purchases, fees, interest charges, card payments, and refunds.
    - "amount" is always a POSITIVE number (the magnitude of the line). Never
      emit a negative amount; the sign is conveyed by "type" instead.
    - "type" is EXACTLY one of: "purchase", "fee", "interest", "payment",
      "refund".
        - "purchase": a normal card purchase / spend.
        - "fee": a bank fee (annual fee, late fee, foreign-transaction fee,
          cash-advance fee).
        - "interest": an interest / finance charge.
        - "payment": a payment made TO the card (a credit that reduces the
          balance, e.g. "PAYMENT - THANK YOU", a bank transfer, autopay,
          GIRO). These are NOT spending — but still return them, tagged
          "payment", so they can be counted and skipped.
        - "refund": a credit / reversal / chargeback / cashback on a purchase
          (money coming back). Return them tagged "refund" so they can be
          counted and skipped.
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
      Pick the best fit from the merchant (a supermarket → groceries, a
      restaurant → food_and_dining, an airline/hotel → travel, Netflix/Spotify
      → subscriptions, a utility → bills_and_utilities). For fees and interest
      use "bills_and_utilities". Use "other" only when nothing fits. For
      payments and refunds, still pick a plausible category (it is ignored).
    - Do NOT include summary rows, balances, "total", "opening/closing
      balance", minimum-payment lines, or reward-point lines — only real
      transaction lines.
    - Do not invent fields or add commentary outside the JSON fence.
    """

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
