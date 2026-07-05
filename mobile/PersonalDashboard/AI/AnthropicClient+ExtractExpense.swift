import Foundation

/// One parsed receipt-extraction result. Mirrors the JSON schema the model
/// is instructed to emit. Every field is optional except `confidence` —
/// the LLM is told to return `null` for anything it can't reliably read.
///
/// `category` is the **raw display name** of an `ExpenseCategory`
/// (e.g. "Food & Dining"). Callers map it back to the enum via
/// `ExpenseCategory.matchingDisplayName`.
struct ExtractedExpense: Decodable, Sendable, Equatable {
    let merchant: String?
    let date: String?              // "YYYY-MM-DD"
    let totalAmount: Double?
    let currency: String?          // ISO 4217
    let category: String?          // ExpenseCategory.displayName
    let items: [String]?
    let confidence: Confidence?

    enum Confidence: String, Decodable, Sendable {
        case high, medium, low
    }

    enum CodingKeys: String, CodingKey {
        case merchant
        case date
        case totalAmount = "total_amount"
        case currency
        case category
        case items
        case confidence
    }
}

/// Errors surfaced to the Finance UI when extraction fails. The receipt
/// file is always saved regardless — these errors only describe the
/// Vision call. The UI falls back to opening AddExpenseSheet with the
/// receipt attached and the user fills in the rest manually.
enum ReceiptExtractionError: LocalizedError {
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
            return "Couldn't find a JSON block in Claude's response."
        case .parse(let err):
            return "Couldn't parse Claude's response. \(err.localizedDescription)"
        }
    }
}

extension AnthropicClient {
    /// Send an image to Claude and ask for structured receipt fields.
    /// `mediaType` is the MIME type ("image/jpeg", "image/png", "image/heic").
    func extractExpense(imageData: Data, mediaType: String) async throws -> ExtractedExpense {
        let base64 = imageData.base64EncodedString()
        let content: [AnthropicJSONValue] = [
            .object([
                "type": .string("image"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string(mediaType),
                    "data": .string(base64)
                ])
            ]),
            .object([
                "type": .string("text"),
                "text": .string(Self.extractionPrompt)
            ])
        ]
        return try await runExtraction(content: content, extraHeaders: [:])
    }

    /// Send a PDF receipt (e.g. an emailed invoice exported to Files) and
    /// ask for the same structured fields. PDF support is gated behind the
    /// `pdfs-2024-09-25` beta header.
    func extractExpense(pdfData: Data) async throws -> ExtractedExpense {
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
                "text": .string(Self.extractionPrompt)
            ])
        ]
        return try await runExtraction(
            content: content,
            extraHeaders: ["anthropic-beta": "pdfs-2024-09-25"]
        )
    }

    /// Send a PHOTO to Claude and ask for EVERY distinct expense in it (#247).
    ///
    /// A photo can hold several receipts at once, or a printed / handwritten
    /// list of transactions for different merchants. This returns one
    /// `ExtractedStatementLine` per distinct expense (a single receipt yields
    /// exactly one line). It reuses the statement extraction CORE
    /// (`runStatementExtraction`) — object-wrapper parsing, bare-array fallback,
    /// truncated-array recovery, lenient per-line decode — with a RECEIPT-specific
    /// prompt (`expensesFromPhotoPrompt`) instead of the statement prompt. No PDF
    /// beta header is needed for an image, so `extraHeaders` is empty. Only the
    /// `.lines` element is returned; there is no statement header for a photo.
    func extractExpenses(imageData: Data, mediaType: String) async throws -> [ExtractedStatementLine] {
        let base64 = imageData.base64EncodedString()
        let content: [AnthropicJSONValue] = [
            .object([
                "type": .string("image"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string(mediaType),
                    "data": .string(base64)
                ])
            ]),
            .object([
                "type": .string("text"),
                "text": .string(Self.expensesFromPhotoPrompt)
            ])
        ]
        let (lines, _, _) = try await runStatementExtraction(content: content, extraHeaders: [:])
        return lines
    }

    // MARK: - Core

    private func runExtraction(
        content: [AnthropicJSONValue],
        extraHeaders: [String: String]
    ) async throws -> ExtractedExpense {
        guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else {
            throw ReceiptExtractionError.notConfigured
        }

        // Construct the request body by hand (not via AnthropicRequest) so we
        // can send heterogeneous content blocks. The existing AnthropicMessage
        // wire type is restricted to text / tool_use / tool_result and would
        // need a wider sum type to carry image/document blocks; this is a
        // one-call surface so a hand-rolled JSON body is simpler.
        let body: AnthropicJSONValue = .object([
            "model": .string(Self.model),
            "max_tokens": .int(Self.maxTokens),
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
        // PDF + Vision extractions can take noticeably longer than text-only
        // requests. Give them headroom over URLSession's 60s default.
        request.timeoutInterval = 90

        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw ReceiptExtractionError.parse(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReceiptExtractionError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ReceiptExtractionError.http(0, "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(800), encoding: .utf8) ?? "<non-utf8 bytes>"
            throw ReceiptExtractionError.http(http.statusCode, preview)
        }

        let decoded: AnthropicResponse
        do {
            decoded = try Self.decoder.decode(AnthropicResponse.self, from: data)
        } catch {
            throw ReceiptExtractionError.parse(error)
        }

        // Concatenate all returned text blocks. The model usually emits one,
        // but never assume.
        let combinedText = decoded.content.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: "\n")

        guard let jsonString = Self.firstJSONBlock(in: combinedText),
              let jsonData = jsonString.data(using: .utf8) else {
            throw ReceiptExtractionError.noJSON
        }
        do {
            return try Self.decoder.decode(ExtractedExpense.self, from: jsonData)
        } catch {
            throw ReceiptExtractionError.parse(error)
        }
    }

    // MARK: - Prompt + parsing

    /// Categories advertised to the model. Kept in sync with `ExpenseCategory`
    /// display names so the model can return any of the 12 verbatim.
    private static var categoryList: String {
        ExpenseCategory.allCases
            .map { "\"\($0.displayName)\"" }
            .joined(separator: ", ")
    }

    static let extractionPrompt: String = """
    Read this receipt and extract the expense details. Return STRICT JSON
    inside a ```json fence and nothing else.

    Schema:
    {
      "merchant": "...",
      "date": "YYYY-MM-DD",
      "total_amount": 12.34,
      "currency": "SGD",
      "category": "Food & Dining",
      "items": ["..."],
      "confidence": "high"
    }

    Rules:
    - Any field you can't read with confidence: return null.
    - "currency" must be an ISO 4217 code. If you genuinely cannot tell,
      default to "SGD".
    - "category" must be exactly one of: \(categoryList).
    - "confidence" is one of "high", "medium", "low". Reflect how sure you
      are about the total amount specifically.
    - "items" is a short list of line-item names (at most 6). Skip if not
      visible.
    - Do not invent fields. Do not add commentary outside the JSON fence.
    """

    /// Prompt for the PHOTO multi-expense path (#247). Unlike `extractionPrompt`
    /// (one receipt → one object) this asks for one object PER DISTINCT expense,
    /// and unlike `statementPrompt` it has NO statement header and only the two
    /// receipt-relevant line types. The output KEEPS the `"lines"` wrapper key so
    /// the shared `linesArray(in:)` parser matches, but OMITS the `"statement"`
    /// wrapper (there is no header). `category` uses the RAW enum values (matching
    /// how `StatementImporter.insert` maps via `ExpenseCategory(rawValue:)`), NOT
    /// the display name the single-receipt prompt uses.
    static let expensesFromPhotoPrompt: String = """
    This is a PHOTO that may contain ONE OR MORE receipts, or a printed /
    handwritten list of transactions for different merchants. Return one JSON
    object per DISTINCT expense — one per receipt, or one per transaction line in
    a list. If the photo is a single receipt, return EXACTLY ONE object.

    Return STRICT JSON inside a ```json fence and nothing else — no prose before
    or after. Emit a single JSON OBJECT with exactly one key, "lines":
    {
      "lines": [
        {
          "merchant": "Starbucks",
          "date": "YYYY-MM-DD",
          "amount": 12.34,
          "currency": "SGD",
          "type": "purchase",
          "category": "food_and_dining",
          "description": "Latte, croissant"
        }
      ]
    }

    Rules for each line:
    - "merchant": the merchant / vendor name for display (e.g. "Starbucks").
    - "date": the transaction date in ISO 8601 (YYYY-MM-DD). If the receipt shows
      no year, infer a sensible one; never emit year 0, 0001, or 1970.
    - "amount": the TOTAL for that receipt / transaction, as a POSITIVE number.
      Never emit a negative amount — the sign is conveyed by "type".
    - "currency": an ISO 4217 code (e.g. "SGD", "USD", "GBP"). If you genuinely
      cannot tell, default to "SGD".
    - "type": EXACTLY one of "purchase" or "refund".
        - "purchase": a normal receipt / spend (the common case).
        - "refund": a credit note or refund (money coming back).
      Do NOT use "payment", "deposit", "interest", or "fee" — those are
      statement-only concepts and never apply to a receipt photo.
    - "category" must be EXACTLY one of these raw values: \(categoryRawList).
      Pick the best fit from the merchant (a supermarket → groceries, a
      restaurant → food_and_dining, an airline/hotel → travel, Netflix/Spotify →
      subscriptions, a utility → bills_and_utilities, a monthly rent/lease → rent).
      Use "other" only when nothing fits.
    - "description": a SHORT summary of the line items on that receipt (at most 6,
      comma-separated), e.g. "Latte, croissant". Omit or set null if not visible.
    - Do NOT include a "descriptor" field — receipts have no verbatim bank
      descriptor.

    Never invent lines that aren't in the photo. Do not invent fields or add
    commentary outside the JSON fence. Return ONLY the fenced JSON.
    """

    /// Pull the first ```json``` fenced block out of `text` and return its
    /// raw body. Falls back to any ``` block if no language tag is present.
    /// Returns nil if no fence is found and the text isn't already a JSON
    /// object on its own.
    static func firstJSONBlock(in text: String) -> String? {
        // Preferred: ```json ... ```
        if let range = text.range(of: "```json") {
            let after = text[range.upperBound...]
            if let close = after.range(of: "```") {
                return String(after[after.startIndex..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Bare ``` fence (no language).
        if let open = text.range(of: "```") {
            let after = text[open.upperBound...]
            if let close = after.range(of: "```") {
                let candidate = String(after[after.startIndex..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.hasPrefix("{") { return candidate }
            }
        }
        // Raw JSON object — model occasionally drops the fence.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let end = trimmed.range(of: "}", options: .backwards) {
            return String(trimmed[trimmed.startIndex...end.lowerBound])
        }
        return nil
    }
}

// MARK: - ExpenseCategory lookup by display name

extension ExpenseCategory {
    /// Find the category whose `displayName` matches `name` exactly. Used to
    /// map an extracted `"Food & Dining"` string back to the enum.
    static func matching(displayName name: String?) -> ExpenseCategory? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExpenseCategory.allCases.first { $0.displayName == trimmed }
    }
}
