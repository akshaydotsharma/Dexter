import Foundation

/// Thirteen canonical expense categories. Raw values are the user-facing
/// strings the LLM picks from in the `add_expense` tool schema and what
/// gets persisted onto `LocalExpense.category`.
///
/// Order here is also the order used in pickers and dashboard breakdowns,
/// so adjust with intent — the "Other" case is always last so it falls to
/// the bottom of category lists.
enum ExpenseCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case foodAndDining       = "food_and_dining"
    case groceries           = "groceries"
    case transport           = "transport"
    case shopping            = "shopping"
    case entertainment       = "entertainment"
    case billsAndUtilities   = "bills_and_utilities"
    case rent                = "rent"
    case healthAndWellness   = "health_and_wellness"
    case travel              = "travel"
    case subscriptions       = "subscriptions"
    case personalCare        = "personal_care"
    case giftsAndDonations   = "gifts_and_donations"
    case other               = "other"

    var id: String { rawValue }

    /// Human-readable label shown in pickers and rows.
    var displayName: String {
        switch self {
        case .foodAndDining:     return "Food & Dining"
        case .groceries:         return "Groceries"
        case .transport:         return "Transport"
        case .shopping:          return "Shopping"
        case .entertainment:     return "Entertainment"
        case .billsAndUtilities: return "Bills & Utilities"
        case .rent:              return "Rent"
        case .healthAndWellness: return "Health & Wellness"
        case .travel:            return "Travel"
        case .subscriptions:     return "Subscriptions"
        case .personalCare:      return "Personal Care"
        case .giftsAndDonations: return "Gifts & Donations"
        case .other:             return "Other"
        }
    }

    /// SF Symbol rendered on category chips, list rows, and the +Sheet picker.
    var sfSymbol: String {
        switch self {
        case .foodAndDining:     return "fork.knife"
        case .groceries:         return "cart"
        case .transport:         return "tram.fill"
        case .shopping:          return "bag"
        case .entertainment:     return "popcorn"
        case .billsAndUtilities: return "bolt"
        case .rent:              return "house.fill"
        case .healthAndWellness: return "heart.text.square"
        case .travel:            return "airplane"
        case .subscriptions:     return "repeat"
        case .personalCare:      return "scissors"
        case .giftsAndDonations: return "gift"
        case .other:             return "square.grid.2x2"
        }
    }
}

/// Source channel an expense came from. Drives both downstream telemetry
/// and the source-filter chips in the Finance list. Stored as a raw string
/// on `LocalExpense.source`.
enum ExpenseSource: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case manual    = "manual"
    case text      = "text"
    case voice     = "voice"
    case photo     = "photo"
    case receipt   = "receipt"
    case pdf       = "pdf"
    case recurring = "recurring"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual:    return "Manual"
        case .text:      return "Text"
        case .voice:     return "Voice"
        case .photo:     return "Photo"
        case .receipt:   return "Receipt"
        case .pdf:       return "PDF"
        case .recurring: return "Recurring"
        }
    }

    var sfSymbol: String {
        switch self {
        case .manual:    return "pencil"
        case .text:      return "text.bubble"
        case .voice:     return "mic"
        case .photo:     return "photo"
        case .receipt:   return "doc.text.viewfinder"
        case .pdf:       return "doc.text"
        case .recurring: return "arrow.triangle.2.circlepath"
        }
    }
}

/// ISO 4217 currencies the user can pick from in the AddExpense sheet and
/// that FXService knows how to fetch rates for. Order: SGD first (home
/// currency), then the most likely travel destinations.
enum SupportedCurrency {
    static let all: [String] = [
        "SGD", "USD", "EUR", "GBP", "AUD", "JPY",
        "MYR", "INR", "CNY", "HKD", "THB", "IDR",
        "PHP", "KRW"
    ]
}
