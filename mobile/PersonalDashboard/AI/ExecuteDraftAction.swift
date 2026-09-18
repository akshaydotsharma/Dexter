import Foundation
import SwiftData

/// Errors thrown when applying a draft action fails. The orchestrator
/// catches these and turns them into `FailedDraft` entries so the App
/// Intent dialog can surface the failure without aborting the whole batch.
enum DraftExecutionError: LocalizedError {
    case notFound(entityType: String, idString: String)
    case invalidArgument(field: String, reason: String)
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .notFound(let type, let id):
            return "Couldn't find \(type) \(id)."
        case .invalidArgument(let field, let reason):
            return "Invalid \(field): \(reason)"
        case .persistence(let err):
            return err.localizedDescription
        }
    }
}

/// Outcome of one applied tool call. Surfaced back to the App Intent for
/// dialog rendering and to the chat UI for confirmation banners.
struct DraftActionOutcome {
    let type: String          // "todo" | "note" | "list" | "folder" | "trip" | "itinerary_item" | "meal"
    let action: String        // see action constants below
    let id: String            // UUID string
    let title: String?
    let dueDate: Date?
    let addedNames: String?
    /// Present only on `log_meal` / `update_meal` (#546). Carries the numbers,
    /// the flags and the remaining-today figures that the chat card and the
    /// Shortcut dialog both read, computed at the moment of the write while the
    /// store is already open. Defaulted so the existing construction sites are
    /// untouched.
    var meal: MealLogSummary? = nil
}

/// Applies the tool-call action types to SwiftData. Operates on
/// `LocalTodo / LocalNote / LocalList / LocalNoteFolder / LocalTrip /
/// LocalItineraryItem / LocalExpense / LocalMeal`. Deletes are true deletes
/// (no tombstones).
@MainActor
struct ExecuteDraftAction {
    let store: SwiftDataStore

    /// The `LocalMeal.source` this dispatcher stamps on a meal it writes
    /// (#546).
    ///
    /// Chat and the Shortcut share every tool and this whole dispatcher, so the
    /// only thing that can tell them apart is who constructed it. Chat is the
    /// default because `ExecuteDraftAction.default()` is the chat wiring;
    /// `ChatToDrafts.default()` overrides it. Getting this wrong costs nothing
    /// but a wrong provenance badge, which is precisely why it would never be
    /// noticed if it were left to drift.
    let mealSource: String

    init(store: SwiftDataStore, mealSource: String = MealSource.chat) {
        self.store = store
        self.mealSource = mealSource
    }

    /// Same shared-store factory as `AssistantContextBuilder.default`.
    static func `default`() -> ExecuteDraftAction {
        ExecuteDraftAction(store: .shared)
    }

    /// Dispatch a parsed tool call onto the right branch. `input` is the
    /// raw decoded JSON object the model returned.
    /// - Parameter groundingSources: the pages the calling turn's own web
    ///   search returned (#594). Defaulted to none, so the Shortcut path, which
    ///   declares no search tool, is untouched. Only the two meal branches read
    ///   it; nothing else on this dispatcher has a published figure to credit.
    func run(
        actionType: DraftActionType,
        input: [String: AnthropicJSONValue],
        groundingSources: [WebSearchSource] = []
    ) async throws -> DraftActionOutcome {
        switch actionType {
        case .createTodo: return try createTodo(input)
        case .createNote: return try createNote(input)
        case .createList: return try createList(input)
        case .completeTodo: return try completeTodo(input)
        case .updateTodo: return try updateTodo(input)
        case .updateNote: return try updateNote(input)
        case .appendToNote: return try appendToNote(input)
        case .updateList: return try updateList(input)
        case .addToList: return try addToList(input)
        case .updateListItem: return try updateListItem(input)
        case .removeListItem: return try removeListItem(input)
        case .updateFolder: return try updateFolder(input)
        case .deleteTodo: return try deleteTodo(input)
        case .deleteNote: return try deleteNote(input)
        case .deleteList: return try deleteList(input)
        case .deleteFolder: return try deleteFolder(input)
        case .createTrip: return try createTrip(input)
        case .addItineraryItems: return try addItineraryItems(input)
        case .updateTrip: return try updateTrip(input)
        case .deleteTrip: return try deleteTrip(input)
        case .updateItineraryItem: return try updateItineraryItem(input)
        case .deleteItineraryItem: return try deleteItineraryItem(input)
        case .addExpense: return try await addExpense(input)
        case .addRecurringExpense: return try await addRecurringExpense(input)
        case .clearExpenses: return try clearExpenses(input)
        case .logMeal: return try logMeal(input, groundingSources: groundingSources)
        case .updateMeal: return try updateMeal(input, groundingSources: groundingSources)
        case .deleteMeal: return try deleteMeal(input)
        case .unknown:
            throw DraftExecutionError.invalidArgument(field: "action", reason: "unknown action type")
        }
    }

    // MARK: - Expenses

    /// `add_expense` tool handler. Converts non-SGD amounts via FXService,
    /// freezes the rate on the row, and persists. Source defaults to `.text`
    /// (we'll override to `.voice` from the voice path and `.photo` /
    /// `.receipt` in Phase B).
    private func addExpense(_ input: [String: AnthropicJSONValue]) async throws -> DraftActionOutcome {
        // Amount. Tolerate either JSON number or numeric string from the
        // model — both shapes have shown up in practice.
        let originalAmount = input["original_amount"]?.doubleValue
            ?? Double(input["original_amount"]?.stringValue ?? "")
            ?? 0
        guard originalAmount > 0 else {
            throw DraftExecutionError.invalidArgument(field: "original_amount", reason: "must be > 0")
        }

        // Category. Fallback to `.other` if the model picks something off-list.
        let categoryRaw = (input["category"]?.stringValue ?? "").lowercased()
        let category = ExpenseCategory(rawValue: categoryRaw) ?? .other

        // Currency. Empty string = SGD.
        let currencyRaw = trimmedString(input["original_currency"]) ?? "SGD"
        let currency = currencyRaw.isEmpty ? "SGD" : currencyRaw.uppercased()

        // Date. Empty / unparseable = today.
        let date = parseAnyISODate(input["date"]?.stringValue) ?? Date()

        let merchant = trimmedString(input["merchant"])
        let descriptionField = trimmedString(input["description"])
        let paymentMethod = trimmedString(input["payment_method"])

        // Source. Optional; defaults to `.text` so existing chat/voice/capture
        // callers (which don't pass `source`) behave exactly as before. The
        // email-to-expense path (#177) passes "receipt".
        let sourceRaw = (trimmedString(input["source"]) ?? "").lowercased()
        let source = ExpenseSource(rawValue: sourceRaw) ?? .text

        // Optional trip linkage (#177). A travel fare parsed from a forwarded
        // booking email carries the matched trip's UUID so the expense links to
        // the trip. Any other caller omits it (empty / absent) and the expense
        // is standalone. Only a valid UUID is honoured.
        let tripUUID: UUID? = trimmedString(input["trip_id"]).flatMap { UUID(uuidString: $0) }

        // Optional Person / Event tags (#183). The model emits a NAME; we
        // find-or-create the record (case-insensitive) and stamp the FK +
        // denormalised name onto the row post-insert, mirroring how trip
        // linkage is stamped below. An event linked to a matched trip carries
        // that trip's UUID so travel spend rolls up.
        let personName = trimmedString(input["person_name"])
        let eventName = trimmedString(input["event_name"])

        // Trip / group settle-up params (#258). When the model supplies
        // `split_with` and/or `paid_by`, the row stores the FULL bill and the
        // per-person breakdown lives in `splitsData` (applied after insert via
        // `applyChatSplit`), so the #188 per-share division must be OFF —
        // `numberOfShares` is forced to 1 here so `shareAmount` stays the full
        // amount. Otherwise the #188 model applies as before.
        let hasSplitParams = (input["split_with"]?.arrayValue?.isEmpty == false)
            || (trimmedString(input["paid_by"]) != nil)

        // Optional split shares (#188). The model emits the FULL receipt total
        // in `original_amount` plus a share count; we store the user's equal
        // share (total / shares). Tolerate a JSON int, double, or numeric
        // string; clamp to >= 1 so a missing / bogus value behaves as unsplit.
        let numberOfShares = hasSplitParams ? 1 : max(
            input["number_of_shares"]?.intValue
                ?? Int(input["number_of_shares"]?.stringValue ?? "")
                ?? 1,
            1
        )
        let shareAmount = originalAmount / Double(numberOfShares)

        // Optional UUID override from the tool input. If the model emitted
        // a valid UUID we use it; otherwise we generate one.
        let providedID = trimmedString(input["id"])
        let clientUUID: String = {
            if let raw = providedID, UUID(uuidString: raw) != nil {
                return raw.lowercased()
            }
            return UUID().uuidString.lowercased()
        }()

        // FX. SGD passes straight through; other currencies hit FXService
        // (cached for 1 day). Failures bubble as `invalidArgument` so the
        // chat surface shows a useful error rather than a silent zero.
        let fx = FXService(store: store)
        let conversion: (sgdAmount: Double, rate: Double)
        do {
            conversion = try await fx.convert(shareAmount, from: currency)
        } catch {
            throw DraftExecutionError.invalidArgument(
                field: "original_currency",
                reason: "couldn't fetch FX rate for \(currency): \(error.localizedDescription)"
            )
        }

        let service = ExpenseService(store: store)
        let row: LocalExpense
        do {
            row = try service.addExpense(
                date: date,
                category: category,
                merchant: merchant,
                expenseDescription: descriptionField,
                originalAmount: shareAmount,
                originalCurrency: currency,
                sgdAmount: conversion.sgdAmount,
                fxRate: conversion.rate,
                paymentMethod: paymentMethod,
                source: source,
                numberOfShares: numberOfShares,
                clientUUID: clientUUID
            )
        } catch {
            throw DraftExecutionError.persistence(error)
        }

        // Link the expense to a trip when the caller supplied a valid trip_id
        // (#177). ExpenseService doesn't take tripUUID, so set it on the row
        // after creation and re-save. dedupeKey / sourceReference stay empty
        // here — the email path stamps those on the returned clientUUID after
        // dedup, mirroring how itinerary items are stamped post-add.
        if let tripUUID {
            row.tripUUID = tripUUID
            // Trip expenses are opt-in to Finance (#277): a newly captured trip
            // expense starts hidden from Finance totals until the user ticks it
            // on the trip's Expenses tab. Non-trip captures keep the in-Finance
            // default. Still fully counted by the trip's own tiles / settle-up.
            row.hiddenFromFinance = true
            try? save()
        }

        // Tag Person / Event by name (#183). find-or-create so "Sarah" typed
        // twice reuses one record. When the event is linked to a matched trip,
        // pass that trip's UUID so the event rolls up under the trip. Stamp the
        // FK + denormalised name on the row, then re-save (same post-insert
        // pattern as trip linkage above).
        var tagged = false
        if let personName {
            let person = try PersonService(store: store).findOrCreate(name: personName)
            row.personUUID = person.clientUUID
            row.personName = person.name
            tagged = true
        }
        if let eventName {
            let event = try EventService(store: store).findOrCreate(name: eventName, tripUUID: tripUUID)
            row.eventUUID = event.clientUUID
            row.eventName = event.name
            tagged = true
        }
        if tagged {
            try? save()
        }

        // Trip / group settle-up split (#258). Resolve `paid_by` + `split_with`
        // names into a stored split (full-bill convention, `numberOfShares`
        // already forced to 1 above). No-op when neither param is present.
        if try applyChatSplit(input, to: row) {
            try? save()
        }

        // Build a human title for the outcome dialog. Prefer merchant,
        // then description, then a category fallback so the App Intent's
        // "Saved 'X'" line is never blank.
        let title = row.merchant
            ?? row.expenseDescription
            ?? category.displayName

        return DraftActionOutcome(
            type: "expense",
            action: ActionString.created,
            id: row.clientUUID,
            title: title,
            dueDate: nil,
            addedNames: nil
        )
    }

    /// `add_recurring_expense` tool handler (#236). Creates a recurring
    /// TEMPLATE — it does NOT log an expense directly. After creating it we run
    /// one materialisation pass (WITHOUT a notification, since the user is right
    /// here getting an on-screen confirmation) so that a template whose posting
    /// day has already passed this month posts its first expense immediately;
    /// otherwise the next foreground / background pass handles posting.
    private func addRecurringExpense(_ input: [String: AnthropicJSONValue]) async throws -> DraftActionOutcome {
        let amount = input["amount"]?.doubleValue
            ?? Double(input["amount"]?.stringValue ?? "")
            ?? 0
        guard amount > 0 else {
            throw DraftExecutionError.invalidArgument(field: "amount", reason: "must be > 0")
        }

        let categoryRaw = (input["category"]?.stringValue ?? "").lowercased()
        let category = ExpenseCategory(rawValue: categoryRaw) ?? .other

        let currencyRaw = trimmedString(input["currency"]) ?? "SGD"
        let currency = currencyRaw.isEmpty ? "SGD" : currencyRaw.uppercased()

        // day_of_month: tolerate int or numeric string; clamp to 1...31.
        let rawDay = input["day_of_month"]?.intValue
            ?? Int(input["day_of_month"]?.stringValue ?? "")
            ?? 1
        let dayOfMonth = min(max(rawDay, 1), 31)

        let merchant = trimmedString(input["merchant"])
        let descriptionField = trimmedString(input["description"])
        let paymentMethod = trimmedString(input["payment_method"])

        let startDate = parseAnyISODate(input["start_date"]?.stringValue) ?? Date()
        let endDate = parseAnyISODate(input["end_date"]?.stringValue)

        let providedID = trimmedString(input["id"])
        let clientUUID: String? = {
            if let raw = providedID, UUID(uuidString: raw) != nil { return raw.lowercased() }
            return nil
        }()

        let service = RecurringExpenseService(store: store)
        let template: RecurringExpense
        do {
            template = try service.create(
                amount: amount,
                currency: currency,
                category: category,
                merchant: merchant,
                expenseDescription: descriptionField,
                paymentMethod: paymentMethod,
                dayOfMonth: dayOfMonth,
                isActive: true,
                startDate: startDate,
                endDate: endDate,
                clientUUID: clientUUID
            )
        } catch {
            throw DraftExecutionError.persistence(error)
        }

        // Post immediately if this month's posting day has already passed.
        // notify:false — the caller (chat card / capture dialog) already tells
        // the user; a banner on top would be redundant.
        _ = await service.materialize(notify: false)

        // Let manual-fetch Finance surfaces refresh if anything posted.
        NotificationCenter.default.post(name: .localStoreDidChange, object: nil)

        let title = template.merchant
            ?? template.expenseDescription
            ?? category.displayName

        return DraftActionOutcome(
            type: "recurring_expense",
            action: ActionString.created,
            id: template.clientUUID,
            title: title,
            dueDate: nil,
            addedNames: nil
        )
    }

    /// `clear_expenses` tool handler (#204). Bulk-deletes finance entries
    /// matching an optional after/before/category filter. Synchronous — unlike
    /// `addExpense` there's no FX round-trip.
    ///
    /// Full-wipe safety guard: an UNFILTERED clear (no after_date, no
    /// before_date, no category) deletes EVERY expense, so it only executes
    /// when `confirm_all: true` is passed. Without it, nothing is deleted and
    /// a `needs_confirmation` outcome is returned telling the user to confirm.
    /// This guard lives here (not just in the system prompt) so the
    /// auto-executing capture / voice path can't wipe everything on one
    /// unconfirmed request. Filtered clears always execute directly, matching
    /// every other delete on these surfaces.
    private func clearExpenses(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let cal = Calendar.current
        // Normalise the bounds to start-of-day so day-granular "after 1 Jun"
        // semantics line up with `LocalExpense.date` (also start-of-day).
        let after = parseAnyISODate(input["after_date"]?.stringValue).map { cal.startOfDay(for: $0) }
        let before = parseAnyISODate(input["before_date"]?.stringValue).map { cal.startOfDay(for: $0) }

        let categoryRaw = (trimmedString(input["category"]) ?? "").lowercased()
        let category = categoryRaw.isEmpty ? nil : ExpenseCategory(rawValue: categoryRaw)

        // Free-text import-source needle (#251): a bank / statement name like
        // "DBS" the user asked to clear. Matched as a case-insensitive substring
        // of statementLabel / statementFileName inside the service. Kept as the
        // raw (trimmed) string here so the outcome title can echo it verbatim.
        let source = trimmedString(input["source"]) ?? ""

        // A filter is "present" whenever the model supplied any dimension —
        // including a category string we don't recognise (handled just below),
        // so an unknown category never silently degrades into a full wipe. A
        // source needle counts too, so a targeted "clear everything from DBS"
        // never needs confirm_all.
        let hasFilter = (after != nil) || (before != nil) || !categoryRaw.isEmpty || !source.isEmpty
        let confirmAll = input["confirm_all"]?.boolValue ?? false

        let service = ExpenseService(store: store)

        // Full-wipe safety guard: unfiltered clear-all needs explicit confirm.
        if !hasFilter && !confirmAll {
            let count = (try? service.totalCount()) ?? 0
            let message = count == 0
                ? "There are no expenses to clear."
                : "This clears all \(count) expense\(count == 1 ? "" : "s"). Say \"yes, clear all\" to confirm."
            return DraftActionOutcome(
                type: "expense",
                action: ActionString.needsConfirmation,
                id: "",
                title: message,
                dueDate: nil,
                addedNames: nil
            )
        }

        // Unknown-category guard: the model passed a category we can't map.
        // Refuse rather than fall through to an unfiltered wipe.
        if !categoryRaw.isEmpty && category == nil {
            return DraftActionOutcome(
                type: "expense",
                action: ActionString.needsConfirmation,
                id: "",
                title: "I don't recognise the category \"\(categoryRaw)\", so nothing was cleared.",
                dueDate: nil,
                addedNames: nil
            )
        }

        let deleted: Int
        do {
            deleted = try service.deleteExpenses(
                after: after,
                before: before,
                category: category,
                source: source.isEmpty ? nil : source
            )
        } catch {
            throw DraftExecutionError.persistence(error)
        }

        return DraftActionOutcome(
            type: "expense",
            action: ActionString.cleared,
            id: "",
            title: Self.clearedExpensesTitle(deleted: deleted, after: after, before: before, category: category, source: source),
            dueDate: nil,
            addedNames: nil
        )
    }

    /// Scope-aware summary for a `clear_expenses` outcome, e.g.
    /// "Cleared 12 expenses", "Cleared 3 expenses in Groceries after 1 Jun 2026",
    /// or "No expenses matched before 1 May 2026." when nothing was deleted.
    private static func clearedExpensesTitle(
        deleted: Int,
        after: Date?,
        before: Date?,
        category: ExpenseCategory?,
        source: String
    ) -> String {
        let scope = clearScopeSuffix(after: after, before: before, category: category, source: source)
        guard deleted > 0 else {
            return "No expenses matched\(scope)."
        }
        let noun = deleted == 1 ? "expense" : "expenses"
        return "Cleared \(deleted) \(noun)\(scope)."
    }

    private static func clearScopeSuffix(after: Date?, before: Date?, category: ExpenseCategory?, source: String) -> String {
        var parts: [String] = []
        if let category {
            parts.append("in \(category.displayName)")
        }
        // Echo the source verbatim so "Cleared 4 expenses imported from DBS"
        // reads back the exact bank name the user gave (#251).
        if !source.isEmpty {
            parts.append("imported from \(source)")
        }
        if let after, let before {
            parts.append("between \(clearDateFormatter.string(from: after)) and \(clearDateFormatter.string(from: before))")
        } else if let after {
            parts.append("after \(clearDateFormatter.string(from: after))")
        } else if let before {
            parts.append("before \(clearDateFormatter.string(from: before))")
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    private static let clearDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    // MARK: - Meals (#546)

    /// `log_meal`. Writes one row from an estimate the model already made.
    ///
    /// ### Why there is no second API call here
    ///
    /// The estimate arrives IN the tool input. The model read the description
    /// this turn, so asking it a second time would double the cost of every log
    /// and, worse, would need the estimation rules written out twice. Instead
    /// the payload is rebuilt into the same `EstimatedMeal` the composer's
    /// fenced-JSON call decodes, and from there this path and the composer's
    /// are literally the same code: `MealEstimateGuards.check` grades it and
    /// `MealEstimationService.save` writes it. See `MealToolSchema` for why
    /// that matters.
    ///
    /// ### Why a retry is safe
    ///
    /// `id` is passed through to `MealService.addMeal`, which treats a supplied
    /// `clientUUID` as an IDENTITY. A Shortcut that timed out and was re-run
    /// rewrites the row it already made. There is no separate update path to
    /// keep in step, because the create IS the update.
    private func logMeal(
        _ input: [String: AnthropicJSONValue],
        groundingSources: [WebSearchSource] = []
    ) throws -> DraftActionOutcome {
        let now = Date()
        guard let description = trimmedString(input["description"]) else {
            throw DraftExecutionError.invalidArgument(
                field: "description",
                reason: "a meal needs the user's own words"
            )
        }

        // Only a valid UUID is honoured as an identity. A malformed one becomes
        // a fresh row rather than an error: losing the meal over a bad id would
        // be the worst possible trade on a capture path.
        let clientUUID: String = {
            if let raw = trimmedString(input["id"]), UUID(uuidString: raw) != nil {
                return raw.lowercased()
            }
            return UUID().uuidString.lowercased()
        }()

        let typeHint = MealType(rawValue: (trimmedString(input["meal_type"]) ?? "").lowercased())
        let resolved = MealToolSchema.resolveDay(isoDate: input["date"]?.stringValue, now: now)

        // #625. Any item naming a saved library row takes that row's stored
        // figures before anything is graded, so the guards and the totals both
        // run over the numbers that will actually be written.
        let checked = MealEstimateGuards.check(
            substitutingSavedItems(in: MealToolSchema.estimatedMeal(from: input)),
            fallbackMealType: typeHint ?? MealEstimationService.inferredType(at: now),
            groundingSources: groundingSources
        )

        let meals = MealService(store: store)
        let estimation = MealEstimationService(meals: meals)

        // Duplicates are read BEFORE the write, against the rows that already
        // exist. Reading afterwards would make a retried Shortcut find the row
        // it had just rewritten and report its own log as a near-duplicate of
        // itself.
        let existingOnDay = (try? meals.meals(on: resolved.day)) ?? []
        let candidate = MealDuplicateCandidate(
            id: clientUUID,
            dayAnchor: WallClock.dayAnchor(from: resolved.day),
            mealType: checked.mealType,
            mealDescription: description,
            loggedAt: now
        )
        let duplicateOf = MealDuplicateCheck.matches(
            for: candidate,
            among: existingOnDay.map(MealDuplicateCandidate.init)
        ).max(by: { $0.loggedAt < $1.loggedAt })

        let row: LocalMeal
        do {
            row = try estimation.save(
                checked,
                description: description,
                day: resolved.day,
                loggedAt: now,
                source: mealSource,
                clientUUID: clientUUID
            )
        } catch {
            throw DraftExecutionError.persistence(error)
        }
        try save()

        return mealOutcome(
            row: row,
            action: ActionString.created,
            duplicateOfID: duplicateOf?.id,
            wasDateClampedFromFuture: resolved.wasClampedFromFuture,
            now: now
        )
    }

    /// `update_meal`. Re-estimates a logged meal in place.
    ///
    /// Goes through the SAME `MealEstimationService.save` the log path uses,
    /// carrying the existing row's `clientUUID`, so the upsert rewrites that row
    /// rather than inserting a second one. `createdAt` stays where it was and
    /// `loggedAt` is preserved, because a correction changes what the meal WAS,
    /// never when it happened.
    private func updateMeal(
        _ input: [String: AnthropicJSONValue],
        groundingSources: [WebSearchSource] = []
    ) throws -> DraftActionOutcome {
        let now = Date()
        let existing = try fetchMeal(input["id"])

        // An update with no items key at all is a model that did not
        // re-estimate. Honouring it would run the guards over an empty array,
        // which reads as "no food identified" and would zero a perfectly good
        // meal — a silent data loss dressed up as a correction. An EXPLICIT
        // empty array with no_food_identified set is a real answer and is let
        // through.
        guard MealToolSchema.carriesItems(input) else {
            throw DraftExecutionError.invalidArgument(
                field: "items",
                reason: "a correction must carry the whole re-estimated meal"
            )
        }

        let description = trimmedString(input["description"]) ?? existing.mealDescription
        let typeHint = MealType(rawValue: (trimmedString(input["meal_type"]) ?? "").lowercased())
        // An absent or empty date leaves the meal on the day it is already on.
        let resolved = MealToolSchema.resolveDay(
            isoDate: input["date"]?.stringValue,
            now: now,
            fallback: existing.deviceDay
        )

        // #625. Same substitution as the log path. A correction that names a
        // saved item has to land on the stored numbers too, or "that was the
        // 150 g pot" would re-estimate the pot it is correcting.
        let checked = MealEstimateGuards.check(
            substitutingSavedItems(in: MealToolSchema.estimatedMeal(from: input)),
            fallbackMealType: typeHint ?? existing.mealTypeEnum,
            groundingSources: groundingSources
        )

        let estimation = MealEstimationService(meals: MealService(store: store))
        let row: LocalMeal
        do {
            row = try estimation.save(
                checked,
                description: description,
                day: resolved.day,
                loggedAt: existing.loggedAt,
                source: mealSource,
                clientUUID: existing.clientUUID
            )
        } catch {
            throw DraftExecutionError.persistence(error)
        }
        try save()

        return mealOutcome(
            row: row,
            action: ActionString.updated,
            duplicateOfID: nil,
            wasDateClampedFromFuture: resolved.wasClampedFromFuture,
            now: now
        )
    }

    /// Replace every item that names a saved library row with that row's
    /// STORED numbers, scaled to the portion the model stated (#625).
    ///
    /// ### The model chooses the row; the device does the arithmetic
    ///
    /// A packet carries printed nutrition the user has already read and
    /// accepted, and re-estimating it costs a round trip and returns a
    /// different answer every time — two logs of one pot then disagree, and a
    /// week's protein is the sum of that disagreement. So the model's job here
    /// is to NAME the row and state how much of it was eaten. Its own eight
    /// numbers are discarded for that item. A model that misquotes a figure
    /// cannot corrupt the log, which is the whole reason the id exists rather
    /// than a lookup tool the model would copy numbers out of.
    ///
    /// ### An id that resolves to nothing is not an error
    ///
    /// The item keeps the model's own estimate and the meal logs as it would
    /// have without the id. A hallucinated id, a row deleted between the turn
    /// and the write, a peer that never synced: all three cost accuracy on one
    /// dish, and none of them is worth losing the meal over.
    ///
    /// ### Why the guards still run afterwards
    ///
    /// The composer's picker path skips them, because a human typed the grams
    /// there. Here the PORTION is the model's, which is exactly the number the
    /// ceilings and the macro check exist to catch: "500 g of protein powder"
    /// is a stored row scaled by a hallucination. The substituted item goes
    /// back into the estimate and is graded with everything beside it, and the
    /// meal's eight totals are then summed over the final list by
    /// `MealEstimateGuards.check`, so a substitution can never leave totals
    /// disagreeing with their own items.
    private func substitutingSavedItems(in estimate: EstimatedMeal) -> EstimatedMeal {
        guard estimate.items.contains(where: { Self.trimmedID($0.savedItemID) != nil }) else {
            return estimate
        }

        let library = FoodItemService(store: store)
        var substituted: [LocalFoodItem] = []

        let items = estimate.items.map { raw -> EstimatedMealItem in
            guard let id = Self.trimmedID(raw.savedItemID),
                  let row = Self.libraryRow(id, in: library) else { return raw }

            // A stated portion wins; an absent, zero or nonsensical one falls
            // back to what the user normally eats of this item, which is the
            // number the picker opens on.
            let stated = raw.portionQuantity
            let quantity = (stated?.isFinite == true && (stated ?? 0) > 0)
                ? (stated ?? row.defaultPortionQuantity)
                : row.defaultPortionQuantity

            let entry = row.mealItem(quantity: quantity)
            substituted.append(row)
            return EstimatedMealItem(
                name: entry.name,
                portionQuantity: entry.portionQuantity,
                portionUnit: entry.portionUnit,
                calories: entry.calories,
                proteinG: entry.proteinG,
                carbsG: entry.carbsG,
                fatG: entry.fatG,
                fibreG: entry.fibreG,
                sugarG: entry.sugarG,
                sodiumMg: entry.sodiumMg,
                satFatG: entry.satFatG,
                savedItemID: row.clientUUID
            )
        }

        // This path really is the item being eaten, so the picker's ordering
        // learns from it the same way a tap does. A correction that re-states
        // the same item counts twice, and that is the right way round: these
        // are ordering counters, and under-counting an item the user logs by
        // voice would bury it under items they only ever tap.
        //
        // A failed counter bump never fails the log. The meal is the record;
        // the count is how a list is sorted.
        for row in substituted { try? library.recordUse(row) }

        return EstimatedMeal(
            mealType: estimate.mealType,
            title: estimate.title,
            items: items,
            containsAlcohol: estimate.containsAlcohol,
            confidence: estimate.confidence,
            assumptions: estimate.assumptions,
            noFoodIdentified: estimate.noFoodIdentified
        )
    }

    /// A non-empty trimmed `saved_item_id`, or nil.
    private static func trimmedID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        return trimmed
    }

    /// The library row an id names, matched as sent and then lowercased.
    ///
    /// Ids are minted lowercase and the context block prints them that way, so
    /// the second lookup only catches a model that re-cased what it was given.
    /// It is one fetch against a personal-scale table and it saves a wrong
    /// number.
    private static func libraryRow(_ id: String, in library: FoodItemService) -> LocalFoodItem? {
        if let row = (try? library.item(clientUUID: id)) ?? nil { return row }
        let lowered = id.lowercased()
        guard lowered != id else { return nil }
        return (try? library.item(clientUUID: lowered)) ?? nil
    }

    /// `delete_meal`. A true delete, like every other delete here.
    ///
    /// Not gated. The chat surface holds this action back until the user
    /// confirms (`DraftActionType.requiresChatConfirmation`); the Shortcut path
    /// runs it directly, which is the standing decision for every destructive
    /// tool on that path.
    private func deleteMeal(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let meal = try fetchMeal(input["id"])
        let title = meal.mealDescription
        let id = meal.clientUUID
        do {
            try MealService(store: store).deleteMeal(meal)
        } catch {
            throw DraftExecutionError.persistence(error)
        }
        try save()
        return DraftActionOutcome(
            type: "meal",
            action: ActionString.deleted,
            id: id,
            title: title,
            dueDate: nil,
            addedNames: nil
        )
    }

    /// Build the outcome for a written meal, including the summary both
    /// surfaces render from.
    ///
    /// The day is re-read AFTER the write so the remaining-today figures
    /// include the meal that was just logged. A "left today" line that ignored
    /// the log that produced it would be answering the wrong question.
    private func mealOutcome(
        row: LocalMeal,
        action: String,
        duplicateOfID: String?,
        wasDateClampedFromFuture: Bool,
        now: Date
    ) -> DraftActionOutcome {
        let meals = MealService(store: store)
        let dayMeals = (try? meals.meals(on: row.deviceDay)) ?? [row]
        let duplicateOf = duplicateOfID.flatMap { id in
            dayMeals.first { $0.clientUUID == id }
        }
        let summary = MealLogSummary(
            meal: row,
            dayMeals: dayMeals,
            targets: try? meals.targets(on: row.deviceDay),
            duplicateOf: duplicateOf,
            wasDateClampedFromFuture: wasDateClampedFromFuture,
            now: now
        )
        return DraftActionOutcome(
            type: "meal",
            action: action,
            id: row.clientUUID,
            // The dialog sentence, verbatim. Same convention as the bulk
            // expense clear: when the title IS the sentence, the App Intent
            // speaks it rather than wrapping it in a phrase that would bury the
            // number.
            title: summary.dialogSentence(now: now),
            dueDate: nil,
            addedNames: nil,
            meal: summary
        )
    }

    /// Fetch a meal by its `clientUUID`.
    ///
    /// Separate from `fetchOne` because `LocalMeal.clientUUID` is a `String`,
    /// not a `UUID` — the AI tool surface emits and consumes UUIDs as strings,
    /// and this model stores them that way so a retried Shortcut can name the
    /// row it already made.
    private func fetchMeal(_ value: AnthropicJSONValue?) throws -> LocalMeal {
        let raw = (value?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, UUID(uuidString: raw) != nil else {
            throw DraftExecutionError.notFound(entityType: "meal", idString: raw.isEmpty ? "<missing>" : raw)
        }
        let lowered = raw.lowercased()
        let descriptor = FetchDescriptor<LocalMeal>(
            predicate: #Predicate { $0.clientUUID == lowered }
        )
        guard let row = try? store.context.fetch(descriptor).first else {
            throw DraftExecutionError.notFound(entityType: "meal", idString: lowered)
        }
        return row
    }

    // MARK: - Trip / group split (#258)

    /// Resolve the `paid_by` + `split_with` params on an `add_expense` call into
    /// a stored settle-up split on `row`. Returns true when a split was
    /// persisted (so the caller re-saves), false when the params imply a plain
    /// personal expense (or are absent).
    ///
    /// Name mapping mirrors the existing `person_name` handling: each name is
    /// find-or-created (case-insensitive) via `PersonService`, and the literal
    /// "me"/"myself"/"I"/"you" maps to the user's own slice (nil personUUID).
    /// The LLM decides who belongs in the list; this code only maps names — the
    /// user is included only when the list names them (or when a person paid but
    /// no split list was given, in which case the whole bill is the user's to
    /// settle with that payer). Equal split (one share each) in v1.
    ///
    /// A split is persisted ONLY when someone other than the user is involved
    /// (as payer or split party); "the user paid, only the user shares" stays an
    /// ordinary personal expense so it counts fully in personal totals.
    private func applyChatSplit(_ input: [String: AnthropicJSONValue], to row: LocalExpense) throws -> Bool {
        let splitNames = input["split_with"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        let payerRaw = trimmedString(input["paid_by"])
        guard !splitNames.isEmpty || payerRaw != nil else { return false }

        let personService = PersonService(store: store)

        // Payer: a named person, or the user ("me" / empty).
        var payerUUID: UUID? = nil
        var payerIsPerson = false
        if let payerRaw, !Self.isMeToken(payerRaw) {
            let person = try personService.findOrCreate(name: payerRaw)
            payerUUID = person.clientUUID
            payerIsPerson = true
        }

        // Split parties, in the order the model listed them, deduped. The user
        // is included only when "me" appears in the list.
        var entries: [ExpenseSplitEntry] = []
        var seenPersons = Set<UUID>()
        var includedMe = false
        for name in splitNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if Self.isMeToken(trimmed) {
                if !includedMe {
                    entries.append(ExpenseSplitEntry(person: nil, shares: 1))
                    includedMe = true
                }
            } else {
                let person = try personService.findOrCreate(name: trimmed)
                if seenPersons.insert(person.clientUUID).inserted {
                    entries.append(ExpenseSplitEntry(person: person.clientUUID, shares: 1))
                }
            }
        }

        // A named payer with no split list → the whole bill is the user's to
        // settle with that payer (the user owes the full amount).
        if entries.isEmpty, payerIsPerson {
            entries.append(ExpenseSplitEntry(person: nil, shares: 1))
        }

        // Only persist when someone other than the user is involved.
        let hasOtherParty = payerIsPerson || entries.contains { $0.personUUID != nil }
        guard hasOtherParty, !entries.isEmpty else { return false }

        row.splits = entries
        row.paidByPersonUUID = payerUUID
        return true
    }

    /// True when a split name refers to the user rather than another person.
    private static func isMeToken(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["me", "myself", "i", "you", "self"].contains(t)
    }

    // MARK: - CREATE

    private func createTodo(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let title = trimmedString(input["title"]) ?? ""
        guard !title.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "title", reason: "required")
        }
        let description = trimmedString(input["description"])
        // Minute precision, matching what the editor writes (#444). The model emits
        // ISO strings that may carry seconds or even fractional seconds, and a task
        // asked for "at 5pm" should not land at 17:00:03.4 just because that is what
        // came back.
        let dueDate = parseISODate(trimmedString(input["due_at"])).map(WallClock.minutePrecision)
        let tag = trimmedString(input["tag"])
        // Empty / unknown -> no priority (0). Parseable value -> its raw Int.
        let priority = TaskPriority(aiString: trimmedString(input["priority"]))?.rawValue ?? 0

        let now = Date()
        let row = LocalTodo(
            title: title,
            todoDescription: description,
            completed: false,
            dueDate: dueDate,
            tag: tag,
            priority: priority,
            createdAt: now,
            updatedAt: now,
            needsSync: false
        )
        store.context.insert(row)
        try save()

        return outcome(type: "todo", action: ActionString.created, id: row.clientUUID, title: row.title, dueDate: row.dueDate)
    }

    private func createNote(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let title = trimmedString(input["title"]) ?? ""
        guard !title.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "title", reason: "required")
        }
        let body = trimmedString(input["body"])
        let folderUUID = parseUUID(trimmedString(input["folder_id"]))

        let now = Date()
        let row = LocalNote(
            folderClientUUID: folderUUID,
            title: title,
            content: body,
            createdAt: now,
            updatedAt: now,
            needsSync: false
        )
        store.context.insert(row)
        try save()

        return outcome(type: "note", action: ActionString.created, id: row.clientUUID, title: row.title)
    }

    private func createList(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let title = trimmedString(input["title"]) ?? ""
        guard !title.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "title", reason: "required")
        }
        let items = parseChecklistItems(input["items"])

        // Resolve icon + color from the tool input, validating against the
        // curated set. When the model omits or supplies an unknown value, fall
        // back to the local keyword mapper so the tile is never blank (#253).
        let inferred = ListAppearance.infer(from: title)
        let rawIcon = trimmedString(input["icon"])
        let icon = ListAppearance.isValidSymbol(rawIcon) ? rawIcon! : inferred.icon
        let colorHex = ListAppearance.matchedPaletteColor(trimmedString(input["color"]))?.id
            ?? inferred.colorHex

        let now = Date()
        let row = LocalList(
            title: title,
            items: items,
            iconName: icon,
            colorHex: colorHex,
            createdAt: now,
            updatedAt: now,
            needsSync: false
        )
        store.context.insert(row)
        try save()

        return outcome(type: "list", action: ActionString.created, id: row.clientUUID, title: row.title)
    }

    // MARK: - COMPLETE / UPDATE

    private func completeTodo(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "todo")
        let row: LocalTodo = try fetchOne(uuid: uuid, entity: "todo")
        let completed = input["completed"]?.boolValue ?? true
        row.completed = completed
        row.updatedAt = Date()
        try save()

        let action = completed ? ActionString.completed : ActionString.reopened
        return outcome(type: "todo", action: action, id: row.clientUUID, title: row.title)
    }

    private func updateTodo(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "todo")
        let row: LocalTodo = try fetchOne(uuid: uuid, entity: "todo")

        var changed = false
        if let title = trimmedString(input["title"]), !title.isEmpty {
            row.title = title; changed = true
        }
        // "null" sentinel = clear, empty string = keep, anything else = set.
        if let raw = input["description"]?.stringValue {
            if raw == "null" {
                row.todoDescription = nil; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                row.todoDescription = raw.trimmingCharacters(in: .whitespacesAndNewlines); changed = true
            }
        }
        if let raw = input["due_at"]?.stringValue {
            if raw == "null" {
                row.dueDate = nil; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let parsed = parseISODate(raw) {
                row.dueDate = WallClock.minutePrecision(parsed); changed = true
            }
        }
        if let raw = input["tag"]?.stringValue {
            if raw == "null" {
                row.tag = nil; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                row.tag = raw.trimmingCharacters(in: .whitespacesAndNewlines); changed = true
            }
        }
        // "null" -> clear to none, empty -> keep, parseable value -> set. Mirrors
        // the tag sentinel above.
        if let raw = input["priority"]?.stringValue {
            if raw == "null" {
                row.priority = 0; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let parsed = TaskPriority(aiString: raw) {
                row.priority = parsed.rawValue; changed = true
            }
        }
        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "task", reason: "no changes provided")
        }

        row.updatedAt = Date()
        try save()
        return outcome(type: "todo", action: ActionString.updated, id: row.clientUUID, title: row.title, dueDate: row.dueDate)
    }

    private func updateNote(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "note")
        let row: LocalNote = try fetchOne(uuid: uuid, entity: "note")

        var changed = false
        if let title = trimmedString(input["title"]), !title.isEmpty {
            row.title = title; changed = true
        }
        if let raw = input["body"]?.stringValue {
            if raw == "null" {
                row.content = nil; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                row.content = raw; changed = true
            }
        }
        if let raw = input["folder_id"]?.stringValue {
            if raw == "null" {
                row.folderClientUUID = nil; changed = true
            } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let folderUUID = UUID(uuidString: raw) {
                row.folderClientUUID = folderUUID; changed = true
            }
        }
        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "note", reason: "no changes provided")
        }

        row.updatedAt = Date()
        try save()
        return outcome(type: "note", action: ActionString.updated, id: row.clientUUID, title: row.title)
    }

    /// `append_to_note` tool handler. Appends `content` to the end of the
    /// existing note body without ever asking the LLM to reconstruct the
    /// current body. This is the safe path for "add a point" / "append a
    /// bullet" style edits — `edit_note` (full-body replace) is reserved
    /// for explicit rewrites, since asking the model to reconstruct a body
    /// from a truncated context preview reliably corrupts it.
    ///
    /// The merge logic is list-aware: when the existing body ends in a
    /// numbered list, the appended content is renumbered to continue the
    /// sequence and joined with a single newline so markdown keeps treating
    /// it as one list. Same idea for `-` / `*` bullet lists. For plain
    /// prose the separator is a blank line.
    private func appendToNote(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "note")
        let row: LocalNote = try fetchOne(uuid: uuid, entity: "note")

        let raw = input["content"]?.stringValue ?? ""
        let newContent = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newContent.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "content", reason: "required")
        }

        let existing = row.content ?? ""
        let merged: String
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged = newContent
        } else if let continuation = Self.continueList(existing: existing, appended: newContent) {
            merged = continuation
        } else if existing.hasSuffix("\n\n") {
            merged = existing + newContent
        } else if existing.hasSuffix("\n") {
            merged = existing + "\n" + newContent
        } else {
            merged = existing + "\n\n" + newContent
        }

        row.content = merged
        row.updatedAt = Date()
        try save()
        return DraftActionOutcome(
            type: "note",
            action: ActionString.updated,
            id: row.clientUUID.uuidString.lowercased(),
            title: row.title,
            dueDate: nil,
            addedNames: nil
        )
    }

    /// If `existing` ends in a markdown list (numbered or bulleted), returns
    /// a merged string where the appended content has been reshaped to keep
    /// that list contiguous: numbered items get renumbered from the next
    /// integer, bullet items get a leading `- ` prefix if missing, and the
    /// join uses a single newline so the rendered list does not break.
    /// Returns nil when the existing body does not end in a list — the
    /// caller should fall back to plain paragraph spacing.
    static func continueList(existing: String, appended: String) -> String? {
        // Strip trailing whitespace once so suffix checks are reliable.
        let trimmedExisting = existing
            .reversed()
            .drop(while: { $0.isWhitespace || $0.isNewline })
            .reversed()
        let existingStripped = String(trimmedExisting)
        guard let lastNewline = existingStripped.lastIndex(of: "\n") else {
            return continueFromLastLine(prefix: "", lastLine: existingStripped, appended: appended)
        }
        let prefix = String(existingStripped[..<lastNewline])
        let lastLine = String(existingStripped[existingStripped.index(after: lastNewline)...])
        return continueFromLastLine(prefix: prefix, lastLine: lastLine, appended: appended)
    }

    private static func continueFromLastLine(prefix: String, lastLine: String, appended: String) -> String? {
        if let (leading, nextNumber) = numberedListMatch(lastLine) {
            let reshaped = renumberAppended(appended, startingAt: nextNumber, indent: leading)
            return joinList(prefix: prefix, lastLine: lastLine, reshaped: reshaped)
        }
        if let (leading, marker) = bulletListMatch(lastLine) {
            let reshaped = rebulletAppended(appended, marker: marker, indent: leading)
            return joinList(prefix: prefix, lastLine: lastLine, reshaped: reshaped)
        }
        return nil
    }

    private static func joinList(prefix: String, lastLine: String, reshaped: String) -> String {
        let base = prefix.isEmpty ? lastLine : prefix + "\n" + lastLine
        return base + "\n" + reshaped
    }

    /// Returns (indentString, nextNumber) if the line is a numbered-list
    /// item like `1. foo` or `  12) bar`. The next number is the matched
    /// number plus one. Indent is preserved so nested lists keep their level.
    private static func numberedListMatch(_ line: String) -> (String, Int)? {
        // Indent: leading spaces/tabs.
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
        let indent = String(line[line.startIndex..<i])
        // Number: 1-3 digits.
        let numberStart = i
        while i < line.endIndex, line[i].isNumber { i = line.index(after: i) }
        guard numberStart != i else { return nil }
        guard let number = Int(line[numberStart..<i]) else { return nil }
        // Delimiter: `.` or `)`.
        guard i < line.endIndex, (line[i] == "." || line[i] == ")") else { return nil }
        i = line.index(after: i)
        // Required space after the delimiter.
        guard i < line.endIndex, line[i] == " " else { return nil }
        return (indent, number + 1)
    }

    /// Returns (indentString, markerCharacter) if the line is a bullet item
    /// like `- foo` or `* bar`. Markers `+ ` are also accepted because
    /// CommonMark allows them.
    private static func bulletListMatch(_ line: String) -> (String, Character)? {
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
        let indent = String(line[line.startIndex..<i])
        guard i < line.endIndex else { return nil }
        let marker = line[i]
        guard marker == "-" || marker == "*" || marker == "+" else { return nil }
        let afterMarker = line.index(after: i)
        guard afterMarker < line.endIndex, line[afterMarker] == " " else { return nil }
        return (indent, marker)
    }

    /// Splits the appended block into lines, strips any leading number/dot
    /// the model may have emitted, and rewrites each line as `<n>. <text>`
    /// starting at `startingAt`. Blank lines and prose lines without a
    /// recognisable list shape are kept as-is so a free-form paragraph
    /// inside the appended content doesn't get accidentally numbered.
    private static func renumberAppended(_ appended: String, startingAt: Int, indent: String) -> String {
        let lines = appended.components(separatedBy: "\n")
        var counter = startingAt
        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append("")
                continue
            }
            // Strip a leading `\d+[.)] ` if present so we can re-number.
            let stripped = stripLeadingNumber(trimmed)
            // Treat every non-empty line as a new item — this is the common
            // case for "add a point". If the model genuinely wanted a
            // paragraph it should use edit_note instead.
            out.append("\(indent)\(counter). \(stripped)")
            counter += 1
        }
        return out.joined(separator: "\n")
    }

    private static func rebulletAppended(_ appended: String, marker: Character, indent: String) -> String {
        let lines = appended.components(separatedBy: "\n")
        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append("")
                continue
            }
            let stripped = stripLeadingBullet(trimmed)
            out.append("\(indent)\(marker) \(stripped)")
        }
        return out.joined(separator: "\n")
    }

    private static func stripLeadingNumber(_ line: String) -> String {
        var i = line.startIndex
        while i < line.endIndex, line[i].isNumber { i = line.index(after: i) }
        guard i != line.startIndex, i < line.endIndex,
              line[i] == "." || line[i] == ")" else {
            // Also strip a stray bullet, in case the model is mixing markers.
            return stripLeadingBullet(line)
        }
        let afterDelim = line.index(after: i)
        guard afterDelim <= line.endIndex else { return line }
        let rest = afterDelim < line.endIndex ? line[afterDelim...] : Substring("")
        return String(rest).trimmingCharacters(in: .whitespaces)
    }

    private static func stripLeadingBullet(_ line: String) -> String {
        guard let first = line.first, first == "-" || first == "*" || first == "+" else { return line }
        let rest = line.dropFirst()
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private func updateList(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "list")
        let row: LocalList = try fetchOne(uuid: uuid, entity: "list")

        var changed = false
        if let title = trimmedString(input["title"]), !title.isEmpty {
            row.title = title; changed = true
        }
        if let arr = input["items"]?.arrayValue, !arr.isEmpty {
            row.items = parseChecklistItems(input["items"])
            changed = true
        }
        // Icon / color: empty string keeps current; a valid value sets it. An
        // unknown SF Symbol or color name is ignored (leaves the list as-is)
        // rather than clearing to a blank tile.
        if let rawIcon = trimmedString(input["icon"]), ListAppearance.isValidSymbol(rawIcon) {
            row.iconName = rawIcon; changed = true
        }
        if let matched = ListAppearance.matchedPaletteColor(trimmedString(input["color"])) {
            row.colorHex = matched.id; changed = true
        }
        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "list", reason: "no changes provided")
        }

        row.updatedAt = Date()
        try save()
        return outcome(type: "list", action: ActionString.updated, id: row.clientUUID, title: row.title)
    }

    private func addToList(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "list")
        let row: LocalList = try fetchOne(uuid: uuid, entity: "list")

        let newItems = parseChecklistItems(input["new_items"])
        guard !newItems.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "new_items", reason: "required")
        }

        var items = row.items
        items.insert(contentsOf: newItems, at: 0)
        row.items = items
        row.updatedAt = Date()
        try save()

        let added = newItems.map { $0.text }.joined(separator: ", ")
        return DraftActionOutcome(
            type: "list",
            action: ActionString.itemsAdded,
            id: row.clientUUID.uuidString.lowercased(),
            title: row.title,
            dueDate: nil,
            addedNames: added
        )
    }

    private func updateListItem(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["list_id"], entity: "list")
        let row: LocalList = try fetchOne(uuid: uuid, entity: "list")

        guard let index = input["item_index"]?.intValue, index >= 0 else {
            throw DraftExecutionError.invalidArgument(field: "item_index", reason: "required and >= 0")
        }
        var items = row.items
        guard index < items.count else {
            throw DraftExecutionError.invalidArgument(
                field: "item_index",
                reason: "out of range (\(index) of \(items.count))"
            )
        }

        var item = items[index]
        var changed = false
        if let text = trimmedString(input["text"]), !text.isEmpty {
            item.text = text; changed = true
        }
        if let checked = input["checked"]?.boolValue, checked != item.checked {
            item.checked = checked; changed = true
        }
        // `url` is optional in the schema: only touch it when the key is
        // present. An empty string is a valid change (clears the link).
        if let urlRaw = input["url"]?.stringValue {
            let trimmed = urlRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != item.url { item.url = trimmed; changed = true }
        }
        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "list item", reason: "no changes provided")
        }
        items[index] = item
        row.items = items
        row.updatedAt = Date()
        try save()

        return outcome(type: "list", action: ActionString.itemUpdated, id: row.clientUUID, title: row.title)
    }

    private func removeListItem(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["list_id"], entity: "list")
        let row: LocalList = try fetchOne(uuid: uuid, entity: "list")

        guard let index = input["item_index"]?.intValue, index >= 0 else {
            throw DraftExecutionError.invalidArgument(field: "item_index", reason: "required and >= 0")
        }
        var items = row.items
        guard index < items.count else {
            throw DraftExecutionError.invalidArgument(
                field: "item_index",
                reason: "out of range (\(index) of \(items.count))"
            )
        }
        items.remove(at: index)
        row.items = items
        row.updatedAt = Date()
        try save()

        return outcome(type: "list", action: ActionString.itemRemoved, id: row.clientUUID, title: row.title)
    }

    private func updateFolder(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "folder")
        let row: LocalNoteFolder = try fetchOne(uuid: uuid, entity: "folder")

        guard let name = trimmedString(input["name"]), !name.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "name", reason: "required")
        }
        row.name = name
        row.updatedAt = Date()
        try save()

        return outcome(type: "folder", action: ActionString.updated, id: row.clientUUID, title: row.name)
    }

    // MARK: - DELETE (true deletes, no tombstones)

    private func deleteTodo(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "todo")
        let row: LocalTodo = try fetchOne(uuid: uuid, entity: "todo")
        let title = row.title
        store.context.delete(row)
        try save()
        return DraftActionOutcome(
            type: "todo", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: title, dueDate: nil, addedNames: nil
        )
    }

    private func deleteNote(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "note")
        let row: LocalNote = try fetchOne(uuid: uuid, entity: "note")
        let title = row.title
        store.context.delete(row)
        try save()
        return DraftActionOutcome(
            type: "note", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: title, dueDate: nil, addedNames: nil
        )
    }

    private func deleteList(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "list")
        let row: LocalList = try fetchOne(uuid: uuid, entity: "list")
        let title = row.title
        store.context.delete(row)
        try save()
        return DraftActionOutcome(
            type: "list", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: title, dueDate: nil, addedNames: nil
        )
    }

    private func deleteFolder(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "folder")
        let row: LocalNoteFolder = try fetchOne(uuid: uuid, entity: "folder")
        let name = row.name

        // Detach (don't cascade-delete) child notes — matches the original
        // tool description: "notes in the folder will be moved to no folder".
        let folderUUID = uuid
        let children = (try? store.context.fetch(
            FetchDescriptor<LocalNote>(
                predicate: #Predicate { $0.folderClientUUID == folderUUID && $0.deletedAt == nil }
            )
        )) ?? []
        let now = Date()
        for child in children {
            child.folderClientUUID = nil
            child.updatedAt = now
        }

        store.context.delete(row)
        try save()
        return DraftActionOutcome(
            type: "folder", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: name, dueDate: nil, addedNames: nil
        )
    }

    // MARK: - TRIPS

    private func createTrip(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let name = trimmedString(input["name"]) ?? ""
        guard !name.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "name", reason: "required")
        }
        // A trip's start and end name calendar days, anchored at UTC midnight
        // so they do not move with the device timezone (#506).
        guard let startRaw = trimmedString(input["start_date"]),
              let startOfStart = WallClock.dayAnchor(fromISO: startRaw) else {
            throw DraftExecutionError.invalidArgument(field: "start_date", reason: "required ISO 8601 date")
        }
        guard let endRaw = trimmedString(input["end_date"]),
              let startOfEnd = WallClock.dayAnchor(fromISO: endRaw) else {
            throw DraftExecutionError.invalidArgument(field: "end_date", reason: "required ISO 8601 date")
        }
        guard startOfEnd >= startOfStart else {
            throw DraftExecutionError.invalidArgument(field: "end_date", reason: "must be on or after start_date")
        }

        let notes = input["notes"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanNotes = notes == "null" ? "" : notes

        let now = Date()
        let row = LocalTrip(
            name: name,
            startDate: startOfStart,
            endDate: startOfEnd,
            notes: cleanNotes,
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(row)
        try save()
        return outcome(type: "trip", action: ActionString.created, id: row.clientUUID, title: row.name)
    }

    private func addItineraryItems(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let tripUUID = try requireUUID(input["trip_id"], entity: "trip")
        let trip: LocalTrip = try fetchOne(uuid: tripUUID, entity: "trip")

        guard let rawItems = input["items"]?.arrayValue, !rawItems.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "items", reason: "required and non-empty")
        }

        let now = Date()
        var addedTitles: [String] = []

        // Snapshot existing items for sortOrder math so we don't refetch per item.
        let tripFK = tripUUID
        var existing = (try? store.context.fetch(
            FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.tripUUID == tripFK }
            )
        )) ?? []

        for entry in rawItems {
            guard let dict = entry.objectValue else { continue }
            let title = (dict["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            // The day is read from the leading `yyyy-MM-dd` and anchored at
            // UTC midnight (#506). `parseAnyISODate` already parses a date-only
            // string in UTC, and `cal.startOfDay` then pushed it back to
            // device-local midnight — which is how a stop written in one
            // timezone came to read a day early in another.
            guard let dayRaw = dict["day_date"]?.stringValue,
                  let dayStart = WallClock.dayAnchor(fromISO: dayRaw) else { continue }

            // Map kind string; last-resort fallback is .activity per spec.
            let kindRaw = (dict["kind"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let kind = ItineraryKind(rawValue: kindRaw) ?? .activity

            // Transport-only mode. Discarded for non-transport kinds even if the
            // model provided it. Defaults to .other when transport but the mode
            // is missing/unrecognised, so a transport row always renders a mode.
            let transportMode: TransportMode? = kind == .transport
                ? (TransportMode(rawValue: (dict["mode"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .other)
                : nil

            let notes = (dict["notes"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanNotes = notes == "null" ? "" : notes

            // Optional start_time: any unparseable value silently falls back
            // to nil (untimed) rather than failing the whole batch. The
            // model can omit the field entirely; we don't require it.
            let startTime = parseWallClockTime(dict["start_time"]?.stringValue)

            // Arrival/landing time for a transport leg or activity (same
            // wall-clock parse as start_time). Discarded for other kinds even if
            // the model accidentally provided it — arrival only renders there.
            let arrivalTime = (kind == .activity || kind == .transport)
                ? parseWallClockTime(dict["arrival_time"]?.stringValue)
                : nil

            // Stay-only check-out fields. For non-stay kinds, both are
            // discarded even if the model accidentally provided them.
            var endDateValue: Date? = nil
            var endTimeValue: Date? = nil
            if kind == .stay {
                if let endRaw = dict["end_date"]?.stringValue,
                   let anchoredEnd = WallClock.dayAnchor(fromISO: endRaw) {
                    endDateValue = anchoredEnd
                }
                endTimeValue = parseWallClockTime(dict["end_time"]?.stringValue)
            }

            // Optional postal address. A bare/empty value or the "null"
            // sentinel both store as empty.
            let addressRaw = (dict["address"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let address = addressRaw == "null" ? "" : addressRaw

            // Google Maps link. An explicit link from the email always wins.
            // When the email carried none, build and STORE a search link from
            // the venue name + address so the item's map field is populated
            // (not just derived at render time). We don't validate the URL.
            let mapsRaw = (dict["google_maps_link"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitMapsLink = mapsRaw == "null" ? "" : mapsRaw
            let mapsLink = explicitMapsLink.isEmpty
                ? (LocalItineraryItem.googleMapsSearchURL(name: title, address: address)?.absoluteString ?? "")
                : explicitMapsLink

            // Ticket text fields (#224). Seat / venue take the same
            // empty/"null"/value handling as address. Gate is a short code the
            // model most often fabricates from a stray token, so it's routed
            // through `TicketField.code` (which also rejects the "null"
            // sentinel, placeholders, and lone letters) — a junk value stores
            // as empty rather than persisting. Barcode + attachment fields are
            // NOT set here: they come from the on-device decode enrichment step.
            let seatRaw = (dict["seat"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let seat = seatRaw == "null" ? "" : seatRaw
            let gate = TicketField.code(dict["gate"]?.stringValue) ?? ""
            let venueRaw = (dict["venue"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let venue = venueRaw == "null" ? "" : venueRaw

            let maxForDay = existing
                .filter { WallClock.isSameStoredDay($0.dayDate, dayStart) }
                .map { $0.sortOrder }
                .max() ?? -1

            let row = LocalItineraryItem(
                tripUUID: tripUUID,
                dayDate: dayStart,
                kind: kind,
                transportMode: transportMode,
                title: title,
                notes: cleanNotes,
                startTime: startTime,
                endDate: endDateValue,
                endTime: endTimeValue,
                arrivalTime: arrivalTime,
                sortOrder: maxForDay + 1,
                address: address,
                googleMapsLink: mapsLink,
                seat: seat,
                gate: gate,
                venue: venue,
                createdAt: now,
                updatedAt: now
            )
            store.context.insert(row)
            existing.append(row)
            addedTitles.append(title)
        }

        guard !addedTitles.isEmpty else {
            throw DraftExecutionError.invalidArgument(field: "items", reason: "no valid items provided")
        }

        trip.updatedAt = now
        try save()

        return DraftActionOutcome(
            type: "itinerary_item",
            action: ActionString.itemsAdded,
            id: trip.clientUUID.uuidString.lowercased(),
            title: trip.name,
            dueDate: nil,
            addedNames: addedTitles.joined(separator: ", ")
        )
    }

    private func updateTrip(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "trip")
        let row: LocalTrip = try fetchOne(uuid: uuid, entity: "trip")

        var changed = false
        if let name = trimmedString(input["name"]), !name.isEmpty {
            row.name = name; changed = true
        }
        // start_date / end_date: empty = keep, real value = set. No "null" support (can't clear dates).
        if let raw = input["start_date"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw != "null",
           let anchored = WallClock.dayAnchor(fromISO: raw) {
            row.startDate = anchored; changed = true
        }
        if let raw = input["end_date"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw != "null",
           let anchored = WallClock.dayAnchor(fromISO: raw) {
            row.endDate = anchored; changed = true
        }
        // notes: empty = keep, "null" = clear (to ""), real value = set.
        if let raw = input["notes"]?.stringValue {
            if raw == "null" {
                row.notes = ""; changed = true
            } else {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    row.notes = trimmed; changed = true
                }
            }
        }

        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "trip", reason: "no changes provided")
        }
        guard row.endDate >= row.startDate else {
            throw DraftExecutionError.invalidArgument(field: "end_date", reason: "must be on or after start_date")
        }

        row.updatedAt = Date()
        try save()
        return outcome(type: "trip", action: ActionString.updated, id: row.clientUUID, title: row.name)
    }

    private func deleteTrip(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "trip")
        let row: LocalTrip = try fetchOne(uuid: uuid, entity: "trip")
        let name = row.name

        // Cascade: delete every itinerary item that references this trip,
        // then the trip itself. Single SwiftData save.
        let tripFK = uuid
        let children = (try? store.context.fetch(
            FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.tripUUID == tripFK }
            )
        )) ?? []
        for child in children {
            store.context.delete(child)
        }
        store.context.delete(row)
        try save()

        return DraftActionOutcome(
            type: "trip", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: name, dueDate: nil, addedNames: nil
        )
    }

    private func updateItineraryItem(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "itinerary_item")
        let row: LocalItineraryItem = try fetchOne(uuid: uuid, entity: "itinerary_item")

        var changed = false
        if let raw = input["day_date"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, raw != "null",
           let anchored = WallClock.dayAnchor(fromISO: raw) {
            row.dayDate = anchored; changed = true
        }
        if let raw = input["kind"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty, raw != "null",
           let kind = ItineraryKind(rawValue: raw) {
            row.kind = kind.rawValue; changed = true
        }
        // mode: transport-only. Empty = keep. Applied only when the (possibly
        // just-updated) kind is transport; the stale-shape guard below clears it
        // for any non-transport kind.
        if let raw = input["mode"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty, raw != "null",
           let mode = TransportMode(rawValue: raw) {
            row.transportModeEnum = mode; changed = true
        }
        if let title = trimmedString(input["title"]), !title.isEmpty {
            row.title = title; changed = true
        }
        if let raw = input["notes"]?.stringValue {
            if raw == "null" {
                row.notes = ""; changed = true
            } else {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    row.notes = trimmed; changed = true
                }
            }
        }
        // start_time follows the same empty/"null"/value tri-state as notes.
        // Empty string = keep current value, "null" = clear (untimed),
        // anything else = parse as ISO 8601 and set.
        if let raw = input["start_time"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.startTime = nil; changed = true
            } else if !trimmed.isEmpty, let parsed = parseWallClockTime(trimmed) {
                row.startTime = parsed; changed = true
            }
        }
        // arrival_time: same empty/"null"/value tri-state as start_time. The
        // stale-shape guard below clears it when the kind isn't activity.
        if let raw = input["arrival_time"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.arrivalTime = nil; changed = true
            } else if !trimmed.isEmpty, let parsed = parseWallClockTime(trimmed) {
                row.arrivalTime = parsed; changed = true
            }
        }
        // end_date / end_time: same tri-state. Cleared automatically when
        // kind switches away from stay (handled below after `changed` check).
        if let raw = input["end_date"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.endDate = nil; changed = true
            } else if !trimmed.isEmpty, let anchored = WallClock.dayAnchor(fromISO: trimmed) {
                row.endDate = anchored; changed = true
            }
        }
        if let raw = input["end_time"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.endTime = nil; changed = true
            } else if !trimmed.isEmpty, let parsed = parseWallClockTime(trimmed) {
                row.endTime = parsed; changed = true
            }
        }
        // address: same empty/"null"/value tri-state as notes. Empty = keep,
        // "null" = clear, anything else = set. The map link is derived from
        // this at render time (LocalItineraryItem.mapsURL).
        if let raw = input["address"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.address = ""; changed = true
            } else if !trimmed.isEmpty {
                row.address = trimmed; changed = true
            }
        }
        // google_maps_link: same empty/"null"/value tri-state as notes.
        // Empty = keep, "null" = clear, anything else = set verbatim.
        if let raw = input["google_maps_link"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.googleMapsLink = ""; changed = true
            } else if !trimmed.isEmpty {
                row.googleMapsLink = trimmed; changed = true
            }
        }
        // Ticket text fields (#224): seat / venue take the same
        // empty/"null"/value tri-state as address. Empty = keep, "null" =
        // clear, anything else = set. Barcode + attachment stay out of the
        // tool path (they're stamped by the on-device decode enrichment).
        if let raw = input["seat"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.seat = ""; changed = true
            } else if !trimmed.isEmpty {
                row.seat = trimmed; changed = true
            }
        }
        // gate: empty = keep. A non-empty value is sanitized via
        // `TicketField.code`, which maps the "null" sentinel, placeholders, and
        // lone letters to nil. An explicit "null" therefore clears; a junk
        // value also clears rather than persisting.
        if let raw = input["gate"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                row.gate = TicketField.code(trimmed) ?? ""; changed = true
            }
        }
        if let raw = input["venue"]?.stringValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "null" {
                row.venue = ""; changed = true
            } else if !trimmed.isEmpty {
                row.venue = trimmed; changed = true
            }
        }
        // If the kind isn't stay any more, clear the stay-only fields so the
        // persisted shape doesn't leak stale data through the timeline.
        if row.kindEnum != .stay {
            if row.endDate != nil { row.endDate = nil; changed = true }
            if row.endTime != nil { row.endTime = nil; changed = true }
        }
        // arrivalTime is for transport / activity legs; clear it if the kind
        // moved away from both so a stale arrival can't leak onto a
        // place/restaurant/stay.
        if row.kindEnum != .activity, row.kindEnum != .transport, row.arrivalTime != nil {
            row.arrivalTime = nil; changed = true
        }
        // transportMode is transport-only; clear it if the kind moved away so a
        // stale mode can't leak onto another kind.
        if row.kindEnum != .transport, !row.transportMode.isEmpty {
            row.transportMode = ""; changed = true
        }

        guard changed else {
            throw DraftExecutionError.invalidArgument(field: "itinerary item", reason: "no changes provided")
        }

        row.updatedAt = Date()
        // Bump the parent trip's updatedAt so it floats to the top of the
        // EXISTING TRIPS context next round.
        let tripFK = row.tripUUID
        if let trip = try? store.context.fetch(
            FetchDescriptor<LocalTrip>(predicate: #Predicate { $0.clientUUID == tripFK })
        ).first {
            trip.updatedAt = Date()
        }
        try save()
        return outcome(type: "itinerary_item", action: ActionString.updated, id: row.clientUUID, title: row.title)
    }

    private func deleteItineraryItem(_ input: [String: AnthropicJSONValue]) throws -> DraftActionOutcome {
        let uuid = try requireUUID(input["id"], entity: "itinerary_item")
        let row: LocalItineraryItem = try fetchOne(uuid: uuid, entity: "itinerary_item")
        let title = row.title
        let tripFK = row.tripUUID
        store.context.delete(row)
        if let trip = try? store.context.fetch(
            FetchDescriptor<LocalTrip>(predicate: #Predicate { $0.clientUUID == tripFK })
        ).first {
            trip.updatedAt = Date()
        }
        try save()
        return DraftActionOutcome(
            type: "itinerary_item", action: ActionString.deleted,
            id: uuid.uuidString.lowercased(), title: title, dueDate: nil, addedNames: nil
        )
    }

    // MARK: - Helpers

    private func save() throws {
        do {
            try store.context.save()
            // Notify manual-fetch surfaces (Tasks / Notes / Lists) that the
            // shared store changed so they can live-refresh. This is the single
            // choke point for both the voice-capture and chat write paths.
            NotificationCenter.default.post(name: .localStoreDidChange, object: nil)
        } catch {
            throw DraftExecutionError.persistence(error)
        }
    }

    private func fetchOne<T: PersistentModel>(uuid: UUID, entity: String) throws -> T {
        if T.self == LocalTodo.self {
            let descriptor = FetchDescriptor<LocalTodo>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        if T.self == LocalNote.self {
            let descriptor = FetchDescriptor<LocalNote>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        if T.self == LocalList.self {
            let descriptor = FetchDescriptor<LocalList>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        if T.self == LocalNoteFolder.self {
            let descriptor = FetchDescriptor<LocalNoteFolder>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        if T.self == LocalTrip.self {
            let descriptor = FetchDescriptor<LocalTrip>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        if T.self == LocalItineraryItem.self {
            let descriptor = FetchDescriptor<LocalItineraryItem>(predicate: #Predicate { $0.clientUUID == uuid })
            guard let row = try? store.context.fetch(descriptor).first else {
                throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
            }
            return row as! T
        }
        throw DraftExecutionError.notFound(entityType: entity, idString: uuid.uuidString.lowercased())
    }

    private func requireUUID(_ value: AnthropicJSONValue?, entity: String) throws -> UUID {
        guard let raw = value?.stringValue, let uuid = UUID(uuidString: raw) else {
            let provided = value?.stringValue ?? "<missing>"
            throw DraftExecutionError.notFound(entityType: entity, idString: provided)
        }
        return uuid
    }

    private func parseUUID(_ raw: String?) -> UUID? {
        guard let raw, !raw.isEmpty, raw != "null" else { return nil }
        return UUID(uuidString: raw)
    }

    private func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, raw != "null" else { return nil }
        // Try with fractional seconds first, then without — both shapes
        // are valid ISO 8601 and the LLM emits either.
        if let date = Self.iso8601Fractional.date(from: raw) {
            return date
        }
        if let date = Self.iso8601.date(from: raw) {
            return date
        }
        return nil
    }

    /// Slightly more lenient ISO parser used by the trip tools. Accepts
    /// full datetimes (with or without fractional seconds) AND bare
    /// `yyyy-MM-dd` dates, which the model emits for day-level fields.
    private func parseAnyISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, raw != "null" else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Self.iso8601Fractional.date(from: trimmed) { return d }
        if let d = Self.iso8601.date(from: trimmed) { return d }
        if let d = Self.dateOnly.date(from: trimmed) { return d }
        return nil
    }

    /// Parse an ISO 8601 datetime as a FLOATING wall-clock time. Itinerary
    /// times are wall-clock at the destination: a 14:00 check-in in Milan must
    /// read 14:00 no matter where the phone is. The AI emits the destination
    /// offset (e.g. "...T14:00:00+02:00"); we drop the offset and anchor the
    /// wall-clock to UTC (a FIXED internal anchor, never shown to the user)
    /// so a UTC-pinned display formatter always renders the stated H:M
    /// regardless of the device's current timezone. Returns nil for date-only
    /// or unparseable input (→ untimed item).
    private func parseWallClockTime(_ raw: String?) -> Date? {
        guard let raw, raw != "null" else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Strip a trailing timezone designator: "Z", "+02:00", "-0500", "+02".
        let noOffset = trimmed.replacingOccurrences(
            of: "(Z|[+-]\\d{2}(:?\\d{2})?)$",
            with: "",
            options: .regularExpression)
        // Anchor the wall clock to UTC (fixed internal anchor).
        for fmt in Self.wallClockFormatters {
            if let d = fmt.date(from: noOffset) { return d }
        }
        return nil
    }

    private func trimmedString(_ value: AnthropicJSONValue?) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseChecklistItems(_ value: AnthropicJSONValue?) -> [ChecklistItem] {
        guard let array = value?.arrayValue else { return [] }
        var out: [ChecklistItem] = []
        for entry in array {
            guard let dict = entry.objectValue else { continue }
            let text = (dict["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let checked = dict["checked"]?.boolValue ?? false
            let url = (dict["url"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(ChecklistItem(text: text, checked: checked, url: url))
        }
        return out
    }

    private func outcome(type: String, action: String, id: UUID, title: String?, dueDate: Date? = nil) -> DraftActionOutcome {
        DraftActionOutcome(
            type: type,
            action: action,
            id: id.uuidString.lowercased(),
            title: title,
            dueDate: dueDate,
            addedNames: nil
        )
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Bare `yyyy-MM-dd` parsed in UTC. Used for date-only fields (trip
    /// start/end, itinerary item day_date).
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Wall-clock parsers for itinerary time-of-day fields. Both anchor to
    /// UTC so an offset-stripped datetime like "2026-09-02T14:00:00" parses
    /// to 14:00:00 UTC, i.e. the time the booking stated. UTC is a FIXED
    /// internal anchor (never shown to the user); a UTC-pinned display
    /// formatter then renders the stated H:M no matter the device timezone,
    /// so itinerary times never drift when the phone changes zones. One shape
    /// with fractional seconds, one without.
    private static let wallClockFormatters: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"].map { pattern in
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = pattern
            return f
        }
    }()
}

/// Action strings returned with `DraftActionOutcome`. Kept as a namespace
/// rather than an enum so callers can compare against the raw string used
/// by the App Intent's dialog switch.
enum ActionString {
    static let created = "created"
    static let completed = "completed"
    static let reopened = "reopened"
    static let updated = "updated"
    static let deleted = "deleted"
    static let itemsAdded = "items_added"
    static let itemUpdated = "item_updated"
    static let itemRemoved = "item_removed"
    /// Bulk clear of finance entries (#204). Distinct from `deleted` (single
    /// row) so the dialog / cards can render a count-bearing summary.
    static let cleared = "cleared"
    /// A `clear_expenses` call that was refused because it would wipe ALL
    /// expenses without confirmation (or named an unknown category). Nothing
    /// was deleted; the outcome `title` carries the message to surface.
    static let needsConfirmation = "needs_confirmation"
}
