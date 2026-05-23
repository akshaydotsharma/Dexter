import Foundation

/// Pre-filled values handed to `AddExpenseSheet` when the user enters via
/// the scan-receipt / photo / PDF flow. The sheet seeds its fields from
/// this struct instead of either loading from SwiftData or starting blank.
///
/// `extractionError` is non-nil when the receipt was saved but Vision
/// failed — the sheet shows an inline banner telling the user to fill in
/// the details. `confidence` is informational; the UI shows a subtle hint
/// when it's `.low` so the user double-checks the amount.
struct PrefilledExpense: Hashable {
    /// Path stored on the resulting expense (`"receipts/<uuid>.<ext>"`).
    /// Always present — we save the file before Vision is even called.
    let receiptImagePath: String

    /// What channel produced this. `.photo` for library, `.receipt` for
    /// camera, `.pdf` for Files.
    let source: ExpenseSource

    /// Whether Vision returned something usable. False -> banner +
    /// `extractionError` text.
    let extractionSucceeded: Bool

    /// User-facing error message when extraction failed. Drives the
    /// inline banner inside the sheet header.
    let extractionError: String?

    /// Self-reported model confidence. Surfaced as a small hint when low.
    let confidence: ExtractedExpense.Confidence?

    // MARK: - Extracted fields (any may be nil)

    let amount: Double?
    let currency: String?
    let category: ExpenseCategory?
    let date: Date?
    let merchant: String?
    let descriptionText: String?

    // MARK: - Constructors

    /// Successful extraction → seed every field that the model gave us.
    static func fromExtraction(
        _ extracted: ExtractedExpense,
        receiptImagePath: String,
        source: ExpenseSource
    ) -> PrefilledExpense {
        let parsedDate: Date? = {
            guard let raw = extracted.date else { return nil }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: raw)
        }()

        let descriptionText: String? = {
            guard let items = extracted.items, !items.isEmpty else { return nil }
            return items.prefix(6).joined(separator: ", ")
        }()

        return PrefilledExpense(
            receiptImagePath: receiptImagePath,
            source: source,
            extractionSucceeded: true,
            extractionError: nil,
            confidence: extracted.confidence,
            amount: extracted.totalAmount,
            currency: extracted.currency,
            category: ExpenseCategory.matching(displayName: extracted.category),
            date: parsedDate,
            merchant: extracted.merchant,
            descriptionText: descriptionText
        )
    }

    /// Vision failed → carry only the receipt + the error message.
    static func fromFailure(
        receiptImagePath: String,
        source: ExpenseSource,
        message: String
    ) -> PrefilledExpense {
        PrefilledExpense(
            receiptImagePath: receiptImagePath,
            source: source,
            extractionSucceeded: false,
            extractionError: message,
            confidence: nil,
            amount: nil,
            currency: nil,
            category: nil,
            date: nil,
            merchant: nil,
            descriptionText: nil
        )
    }
}
