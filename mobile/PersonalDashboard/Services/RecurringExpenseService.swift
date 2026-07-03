import Foundation
import SwiftData

/// Errors thrown by `RecurringExpenseService` CRUD. Mirrors the shape of
/// `ExpenseServiceError` so the editor surfaces useful messages.
enum RecurringExpenseServiceError: LocalizedError {
    case invalidAmount
    case invalidDayOfMonth
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .invalidAmount:        return "Amount must be greater than zero."
        case .invalidDayOfMonth:    return "Day of month must be between 1 and 31."
        case .persistence(let err): return err.localizedDescription
        }
    }
}

/// CRUD over `RecurringExpense` plus the materialiser that turns due templates
/// into real `LocalExpense` rows (#236).
///
/// Materialisation is idempotent on TWO guards so repeated foregrounds and
/// missed-month backfill are both safe:
///   1. A per-posting `dedupeKey` (`recurring:<templateUUID>:<yyyy-MM>`) stamped
///      onto each generated `LocalExpense` — a month already posted is never
///      posted again, even if the template's cursor is somehow behind.
///   2. The template's `lastPostedMonthKey` cursor, advanced past every month
///      the materialiser has processed, so a normal pass never re-walks history.
///
/// Every generated row goes through `ExpenseService.addExpense` so FX freeze,
/// currency default, and `startOfDay` normalisation all come for free and the
/// row is indistinguishable from a manually-logged expense (just tagged
/// `ExpenseSource.recurring`).
@MainActor
struct RecurringExpenseService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    static func `default`() -> RecurringExpenseService {
        RecurringExpenseService(store: .shared)
    }

    // MARK: - CRUD

    /// All templates, newest first. The management list groups active vs paused
    /// itself, so a single created-desc sort is enough here.
    func templates() throws -> [RecurringExpense] {
        try store.context.fetch(
            FetchDescriptor<RecurringExpense>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        )
    }

    @discardableResult
    func create(
        amount: Double,
        currency: String,
        category: ExpenseCategory,
        merchant: String?,
        expenseDescription: String?,
        paymentMethod: String?,
        dayOfMonth: Int,
        isActive: Bool = true,
        startDate: Date = Date(),
        endDate: Date? = nil,
        clientUUID: String? = nil
    ) throws -> RecurringExpense {
        guard amount > 0 else { throw RecurringExpenseServiceError.invalidAmount }
        guard (1...31).contains(dayOfMonth) else { throw RecurringExpenseServiceError.invalidDayOfMonth }

        let now = Date()
        let row = RecurringExpense(
            clientUUID: clientUUID ?? UUID().uuidString.lowercased(),
            amount: amount,
            currency: currency.uppercased(),
            category: category.rawValue,
            merchant: merchant?.trimmedNonEmpty,
            expenseDescription: expenseDescription?.trimmedNonEmpty,
            paymentMethod: paymentMethod?.trimmedNonEmpty,
            dayOfMonth: dayOfMonth,
            isActive: isActive,
            startDate: Calendar.current.startOfDay(for: startDate),
            endDate: endDate.map { Calendar.current.startOfDay(for: $0) },
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(row)
        try save()
        return row
    }

    /// Update in place. All fields optional — nil leaves the field untouched.
    /// Edits only ever affect FUTURE postings; already-posted `LocalExpense`
    /// rows are never revisited (and the per-month `dedupeKey` means a month
    /// already posted is never re-posted with new values).
    func update(
        _ template: RecurringExpense,
        amount: Double? = nil,
        currency: String? = nil,
        category: ExpenseCategory? = nil,
        merchant: String? = nil,
        expenseDescription: String? = nil,
        paymentMethod: String? = nil,
        dayOfMonth: Int? = nil,
        isActive: Bool? = nil,
        startDate: Date? = nil,
        endDate: Date?? = nil
    ) throws {
        if let amount {
            guard amount > 0 else { throw RecurringExpenseServiceError.invalidAmount }
            template.amount = amount
        }
        if let currency { template.currency = currency.uppercased() }
        if let category { template.category = category.rawValue }
        if let merchant { template.merchant = merchant.trimmedNonEmpty }
        if let expenseDescription { template.expenseDescription = expenseDescription.trimmedNonEmpty }
        if let paymentMethod { template.paymentMethod = paymentMethod.trimmedNonEmpty }
        if let dayOfMonth {
            guard (1...31).contains(dayOfMonth) else { throw RecurringExpenseServiceError.invalidDayOfMonth }
            template.dayOfMonth = dayOfMonth
        }
        if let isActive { template.isActive = isActive }
        if let startDate { template.startDate = Calendar.current.startOfDay(for: startDate) }
        // Double-optional: outer nil = no change, `.some(nil)` = clear the end
        // date, `.some(date)` = set it.
        if let endDate {
            template.endDate = endDate.map { Calendar.current.startOfDay(for: $0) }
        }
        template.updatedAt = Date()
        try save()
    }

    /// Toggle pause/resume. A paused template posts nothing until resumed.
    func setActive(_ template: RecurringExpense, _ active: Bool) throws {
        template.isActive = active
        template.updatedAt = Date()
        try save()
    }

    /// Delete the template. Posted expenses it already generated are left
    /// untouched — they're ordinary `LocalExpense` rows now.
    func delete(_ template: RecurringExpense) throws {
        store.context.delete(template)
        try save()
    }

    // MARK: - Materialisation

    /// One posted row's display label, used to summarise a materialisation pass
    /// in the notification (e.g. "Rent", "Netflix").
    struct Posted {
        let label: String
        let sgdAmount: Double
    }

    /// Post any due or missed months for every active template, up to
    /// `reference` (today). Returns the rows posted this pass.
    ///
    /// When `notify` is true and one or more rows post, a single local
    /// notification summarises them (authorization is requested lazily on the
    /// first pass that actually posts, so users who never use the feature are
    /// never prompted). Called with `notify: false` from the in-app / AI create
    /// path, where the user already sees an on-screen confirmation.
    @discardableResult
    func materialize(reference: Date = Date(), notify: Bool) async -> [Posted] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: reference)
        let currentAnchor = Self.firstOfMonth(today, cal: cal)

        let all = (try? templates()) ?? []
        var posted: [Posted] = []

        for template in all where template.isActive {
            let result = await materializeTemplate(template, today: today, currentAnchor: currentAnchor, cal: cal)
            posted.append(contentsOf: result)
        }

        if notify, !posted.isEmpty {
            await RecurringExpenseNotifications.postPosted(posted)
        }
        return posted
    }

    /// Walk one template's candidate months from its cursor up to the current
    /// month, posting each due month exactly once and advancing the cursor.
    private func materializeTemplate(
        _ template: RecurringExpense,
        today: Date,
        currentAnchor: Date,
        cal: Calendar
    ) async -> [Posted] {
        var posted: [Posted] = []

        let startAnchor = Self.firstOfMonth(cal.startOfDay(for: template.startDate), cal: cal)
        // Resume from the month AFTER the cursor, but never before the start
        // month. A nil cursor starts at the template's start month.
        var candidate: Date
        if let cursorKey = template.lastPostedMonthKey,
           let cursorAnchor = Self.anchor(fromKey: cursorKey, cal: cal),
           let next = cal.date(byAdding: .month, value: 1, to: cursorAnchor) {
            candidate = max(next, startAnchor)
        } else {
            candidate = startAnchor
        }

        let endDay = template.endDate.map { cal.startOfDay(for: $0) }
        var newCursor = template.lastPostedMonthKey

        // Iterate month-by-month until we pass the current month.
        while candidate <= currentAnchor {
            let monthKey = Self.monthKey(for: candidate, cal: cal)
            let postDate = Self.postingDate(monthAnchor: candidate, dayOfMonth: template.dayOfMonth, cal: cal)

            // Future posting day (this month's day hasn't arrived yet, or a
            // month ahead): stop — later months are all future too. Cursor is
            // left where it is so the month is reconsidered next pass.
            if postDate > today { break }

            // Past its end date? A posting strictly after endDate is suppressed,
            // and any month beyond the end month also lands here (its postDate is
            // after endDate). The month is still "processed", so the cursor
            // advances past it and the template goes dormant.
            let withinEnd = endDay.map { postDate <= $0 } ?? true

            if withinEnd {
                let outcome = await postIfNeeded(template: template, monthKey: monthKey, postDate: postDate)
                switch outcome {
                case .posted(let row):
                    posted.append(row)
                case .alreadyExists:
                    break  // idempotent skip; still advance the cursor below.
                case .failed:
                    // FX / persistence failed for this month. Stop without
                    // advancing the cursor past it so the next foreground
                    // retries; earlier months processed this pass keep their
                    // advanced cursor (saved after the loop).
                    if newCursor != template.lastPostedMonthKey {
                        template.lastPostedMonthKey = newCursor
                        template.updatedAt = Date()
                        try? save()
                    }
                    return posted
                }
            }

            newCursor = monthKey
            guard let next = cal.date(byAdding: .month, value: 1, to: candidate) else { break }
            candidate = next
        }

        if newCursor != template.lastPostedMonthKey {
            template.lastPostedMonthKey = newCursor
            template.updatedAt = Date()
            try? save()
        }
        return posted
    }

    /// Outcome of a single month's post attempt.
    private enum PostOutcome {
        case posted(Posted)
        case alreadyExists
        case failed
    }

    /// Post one month's expense unless it already exists (dedupe by
    /// `recurring:<uuid>:<yyyy-MM>`).
    private func postIfNeeded(template: RecurringExpense, monthKey: String, postDate: Date) async -> PostOutcome {
        let key = Self.dedupeKey(templateUUID: template.clientUUID, monthKey: monthKey)

        // Idempotency guard: already posted this month?
        let existing = (try? store.context.fetchCount(
            FetchDescriptor<LocalExpense>(predicate: #Predicate { $0.dedupeKey == key })
        )) ?? 0
        if existing > 0 { return .alreadyExists }

        let currency = template.currency.isEmpty ? "SGD" : template.currency.uppercased()

        let fx = FXService(store: store)
        let conversion: (sgdAmount: Double, rate: Double)
        do {
            conversion = try await fx.convert(template.amount, from: currency)
        } catch {
            return .failed
        }

        let service = ExpenseService(store: store)
        do {
            let row = try service.addExpense(
                date: postDate,
                category: template.categoryEnum,
                merchant: template.merchant,
                expenseDescription: template.expenseDescription,
                originalAmount: template.amount,
                originalCurrency: currency,
                sgdAmount: conversion.sgdAmount,
                fxRate: conversion.rate,
                paymentMethod: template.paymentMethod,
                source: .recurring
            )
            // Stamp the dedupe key so a re-run (or a backfill that overlaps this
            // month) never double-posts. Re-save through the shared context.
            row.dedupeKey = key
            try save()

            let label = template.merchant?.trimmedNonEmpty
                ?? template.expenseDescription?.trimmedNonEmpty
                ?? template.categoryEnum.displayName
            return .posted(Posted(label: label, sgdAmount: conversion.sgdAmount))
        } catch {
            return .failed
        }
    }

    // MARK: - Date helpers

    /// The first day (start-of-day) of the month containing `date`.
    static func firstOfMonth(_ date: Date, cal: Calendar) -> Date {
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    /// "yyyy-MM" key for the month containing `date`.
    static func monthKey(for date: Date, cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// First-of-month anchor date for a "yyyy-MM" key. Nil if malformed.
    static func anchor(fromKey key: String, cal: Calendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        return cal.date(from: comps)
    }

    /// Posting date for a month, clamping the day-of-month to the month's last
    /// day (so day 31 posts on 28/29 Feb, day 31 posts on the 30th in a 30-day
    /// month). Normalised to start-of-day to match `LocalExpense.date`.
    static func postingDate(monthAnchor: Date, dayOfMonth: Int, cal: Calendar) -> Date {
        let lastDay = cal.range(of: .day, in: .month, for: monthAnchor)?.count ?? 28
        let clamped = min(max(dayOfMonth, 1), lastDay)
        var comps = cal.dateComponents([.year, .month], from: monthAnchor)
        comps.day = clamped
        let date = cal.date(from: comps) ?? monthAnchor
        return cal.startOfDay(for: date)
    }

    /// Stable per-month dedupe key for a template's posting.
    static func dedupeKey(templateUUID: String, monthKey: String) -> String {
        "recurring:\(templateUUID.lowercased()):\(monthKey)"
    }

    private func save() throws {
        do {
            try store.context.save()
        } catch {
            throw RecurringExpenseServiceError.persistence(error)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
