import Foundation
import SwiftData

/// Errors thrown by `ExpenseService`. The few error paths only surface
/// programming bugs (zero amount, invalid category) — UI rarely needs to
/// branch on them.
enum ExpenseServiceError: LocalizedError {
    case invalidAmount
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .invalidAmount:        return "Amount must be greater than zero."
        case .persistence(let err): return err.localizedDescription
        }
    }
}

/// A resolved Person / Event tag (FK + denormalised name) passed to
/// `updateExpense` (#183). Bundling both keeps the row's link and its
/// self-describing name in sync in one argument.
struct ExpenseTag: Equatable {
    let uuid: UUID
    let name: String
}

/// Filter criteria applied by `ExpenseService.expenses(filter:)`. All
/// fields are optional — nil means "no constraint on this dimension".
/// Backs both the Finance list and the future analytics surface.
struct ExpenseFilter: Equatable {
    var dateRange: ClosedRange<Date>?
    var categories: Set<ExpenseCategory>?
    var sources: Set<ExpenseSource>?
    /// Person tags to include (#183). nil / empty = no constraint. An expense
    /// matches when its `personUUID` is in the set (OR within the dimension).
    var people: Set<UUID>?
    /// Event tags to include (#183). Same OR-within-dimension semantics.
    var events: Set<UUID>?
    var searchText: String?

    static let none = ExpenseFilter()
}

/// Date-window helper used by both the service and view-layer filters.
/// Hoisted out of `ExpenseService` so the view can call it from a
/// synchronous, non-isolated context (the service itself is `@MainActor`
/// because it touches the shared SwiftData store).
enum ExpenseDateRanges {
    /// Returns (startOfMonth, end-of-last-day-of-that-month) for any
    /// reference date.
    static func monthBounds(for reference: Date) -> (Date, Date) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: reference)
        let start = cal.date(from: comps) ?? reference
        let nextMonth = cal.date(byAdding: .month, value: 1, to: start) ?? reference
        let end = nextMonth.addingTimeInterval(-1)
        return (start, end)
    }
}

/// CRUD + analytics over `LocalExpense`. Operates on the shared SwiftData
/// context. All math is in SGD (the frozen `sgdAmount` field on each row)
/// so totals don't drift with FX changes.
@MainActor
struct ExpenseService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    static func `default`() -> ExpenseService {
        ExpenseService(store: .shared)
    }

    // MARK: - CRUD

    /// Insert a new expense. Caller is responsible for computing `sgdAmount`
    /// + `fxRate` via `FXService.convert` before invoking this.
    @discardableResult
    func addExpense(
        date: Date,
        category: ExpenseCategory,
        merchant: String?,
        expenseDescription: String?,
        originalAmount: Double,
        originalCurrency: String,
        sgdAmount: Double,
        fxRate: Double,
        paymentMethod: String?,
        source: ExpenseSource,
        personUUID: UUID? = nil,
        personName: String? = nil,
        eventUUID: UUID? = nil,
        eventName: String? = nil,
        numberOfShares: Int = 1,
        clientUUID: String? = nil
    ) throws -> LocalExpense {
        guard originalAmount > 0 else { throw ExpenseServiceError.invalidAmount }

        let row = LocalExpense(
            clientUUID: clientUUID ?? UUID().uuidString.lowercased(),
            date: Calendar.current.startOfDay(for: date),
            category: category.rawValue,
            merchant: merchant?.trimmedNonEmpty,
            expenseDescription: expenseDescription?.trimmedNonEmpty,
            originalAmount: originalAmount,
            originalCurrency: originalCurrency.uppercased(),
            sgdAmount: sgdAmount,
            fxRate: fxRate,
            paymentMethod: paymentMethod?.trimmedNonEmpty,
            receiptImagePath: nil,
            source: source.rawValue,
            createdAt: Date(),
            personUUID: personUUID,
            personName: personName?.trimmedNonEmpty,
            eventUUID: eventUUID,
            eventName: eventName?.trimmedNonEmpty,
            numberOfShares: max(numberOfShares, 1)
        )
        store.context.insert(row)
        try save()
        return row
    }

    /// Update an existing expense in place. All fields are nullable — pass
    /// `nil` to leave the corresponding field untouched (note: passing nil
    /// for `merchant` / `expenseDescription` / `paymentMethod` does NOT
    /// clear them; the AddExpense sheet always passes the current value so
    /// there's no clearing semantic to worry about in Phase A).
    func updateExpense(
        _ expense: LocalExpense,
        date: Date? = nil,
        category: ExpenseCategory? = nil,
        merchant: String? = nil,
        expenseDescription: String? = nil,
        originalAmount: Double? = nil,
        originalCurrency: String? = nil,
        sgdAmount: Double? = nil,
        fxRate: Double? = nil,
        paymentMethod: String? = nil,
        person: ExpenseTag?? = nil,
        event: ExpenseTag?? = nil,
        numberOfShares: Int? = nil
    ) throws {
        if let date {
            expense.date = Calendar.current.startOfDay(for: date)
        }
        if let category {
            expense.category = category.rawValue
        }
        if let merchant {
            expense.merchant = merchant.trimmedNonEmpty
        }
        if let expenseDescription {
            expense.expenseDescription = expenseDescription.trimmedNonEmpty
        }
        if let originalAmount {
            guard originalAmount > 0 else { throw ExpenseServiceError.invalidAmount }
            expense.originalAmount = originalAmount
        }
        if let originalCurrency {
            expense.originalCurrency = originalCurrency.uppercased()
        }
        if let sgdAmount {
            expense.sgdAmount = sgdAmount
        }
        if let fxRate {
            expense.fxRate = fxRate
        }
        if let paymentMethod {
            expense.paymentMethod = paymentMethod.trimmedNonEmpty
        }
        // Person / Event tags (#183). Tri-state via a double-optional: the
        // outer nil (default) means "no change"; `.some(nil)` clears the tag;
        // `.some(tag)` sets both the FK and the denormalised name.
        if let person {
            expense.personUUID = person?.uuid
            expense.personName = person?.name.trimmedNonEmpty
        }
        if let event {
            expense.eventUUID = event?.uuid
            expense.eventName = event?.name.trimmedNonEmpty
        }
        // Split shares (#188). Clamp to >= 1; the caller passes the stored
        // per-share `originalAmount` / `sgdAmount` alongside, so no re-division
        // happens here — the sheet computes the share before calling update.
        if let numberOfShares {
            expense.numberOfShares = max(numberOfShares, 1)
        }
        try save()
    }

    func deleteExpense(_ expense: LocalExpense) throws {
        store.context.delete(expense)
        try save()
    }

    // MARK: - Analytics

    /// Total SGD spent this calendar month (start-of-month → now).
    func monthTotal(_ reference: Date = .now) throws -> Double {
        let (start, end) = ExpenseDateRanges.monthBounds(for: reference)
        return try sum(in: start...end)
    }

    /// Total SGD spent in the previous calendar month. Used for the
    /// dashboard's delta chip.
    func previousMonthTotal(_ reference: Date = .now) throws -> Double {
        let cal = Calendar.current
        let prev = cal.date(byAdding: .month, value: -1, to: reference) ?? reference
        let (start, end) = ExpenseDateRanges.monthBounds(for: prev)
        return try sum(in: start...end)
    }

    /// Top N categories this month by SGD spent. Empty array if no expenses.
    func topCategoriesThisMonth(limit: Int = 3) throws -> [(category: ExpenseCategory, total: Double)] {
        let (start, end) = ExpenseDateRanges.monthBounds(for: .now)
        let rows = try fetch(in: start...end)
        var sums: [String: Double] = [:]
        for row in rows {
            sums[row.category, default: 0] += row.sgdAmount
        }
        return sums
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (ExpenseCategory(rawValue: $0.key) ?? .other, $0.value) }
    }

    /// Daily totals for the last 30 calendar days (inclusive). Days with no
    /// spend are present with `0.0` so the sparkline draws a flat segment
    /// instead of skipping points.
    func dailyTotalsLast30Days(reference: Date = .now) throws -> [(date: Date, total: Double)] {
        let cal = Calendar.current
        let end = cal.startOfDay(for: reference)
        guard let start = cal.date(byAdding: .day, value: -29, to: end) else { return [] }
        let endOfDay = cal.date(byAdding: .day, value: 1, to: end)!.addingTimeInterval(-1)
        let rows = try fetch(in: start...endOfDay)

        var byDay: [Date: Double] = [:]
        for row in rows {
            let day = cal.startOfDay(for: row.date)
            byDay[day, default: 0] += row.sgdAmount
        }
        var out: [(date: Date, total: Double)] = []
        for offset in 0..<30 {
            if let day = cal.date(byAdding: .day, value: offset, to: start) {
                out.append((day, byDay[day] ?? 0))
            }
        }
        return out
    }

    /// Filtered list of expenses, sorted by `date` descending then
    /// `createdAt` descending so same-day rows show insertion order with
    /// newest at the top.
    func expenses(filter: ExpenseFilter = .none) throws -> [LocalExpense] {
        let descriptor = FetchDescriptor<LocalExpense>(
            sortBy: [
                SortDescriptor(\.date, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse)
            ]
        )
        let all = try store.context.fetch(descriptor)
        return all.filter { Self.matches($0, filter: filter) }
    }

    // MARK: - Helpers

    private func sum(in range: ClosedRange<Date>) throws -> Double {
        try fetch(in: range).reduce(0) { $0 + $1.sgdAmount }
    }

    private func fetch(in range: ClosedRange<Date>) throws -> [LocalExpense] {
        let lo = range.lowerBound
        let hi = range.upperBound
        let descriptor = FetchDescriptor<LocalExpense>(
            predicate: #Predicate { $0.date >= lo && $0.date <= hi }
        )
        return try store.context.fetch(descriptor)
    }

    private static func matches(_ expense: LocalExpense, filter: ExpenseFilter) -> Bool {
        if let range = filter.dateRange {
            if !range.contains(expense.date) { return false }
        }
        if let categories = filter.categories, !categories.isEmpty {
            guard let category = ExpenseCategory(rawValue: expense.category) else { return false }
            if !categories.contains(category) { return false }
        }
        if let sources = filter.sources, !sources.isEmpty {
            guard let source = ExpenseSource(rawValue: expense.source) else { return false }
            if !sources.contains(source) { return false }
        }
        if let people = filter.people, !people.isEmpty {
            guard let personUUID = expense.personUUID, people.contains(personUUID) else { return false }
        }
        if let events = filter.events, !events.isEmpty {
            guard let eventUUID = expense.eventUUID, events.contains(eventUUID) else { return false }
        }
        if let search = filter.searchText?.trimmedNonEmpty?.lowercased(), !search.isEmpty {
            let merchant = expense.merchant?.lowercased() ?? ""
            let description = expense.expenseDescription?.lowercased() ?? ""
            if !merchant.contains(search) && !description.contains(search) {
                return false
            }
        }
        return true
    }

    /// Returns (startOfMonth, endOfMonth-end-of-last-day) for any reference date.
    /// Shim delegates to the non-isolated `ExpenseDateRanges.monthBounds` so
    /// existing callers don't have to change but views can call from a sync
    /// non-isolated context.
    static func monthBounds(for reference: Date) -> (Date, Date) {
        ExpenseDateRanges.monthBounds(for: reference)
    }

    private func save() throws {
        do {
            try store.context.save()
        } catch {
            throw ExpenseServiceError.persistence(error)
        }
    }
}

private extension String {
    /// Trim whitespace, return nil for empty. Saves a sprinkling of inline
    /// trims on every save path.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
