import Foundation
import SwiftData

/// Errors thrown by `MealService`. Like `ExpenseServiceError`, the non-storage
/// cases only surface programming bugs, so UI rarely needs to branch on them.
enum MealServiceError: LocalizedError {
    case invalidNutrients
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .invalidNutrients:     return "Nutrient values cannot be negative."
        case .persistence(let err): return err.localizedDescription
        }
    }
}

/// CRUD over `LocalMeal`, plus read and write of the single `MealTargets`
/// record (#542). Operates on the shared SwiftData context.
///
/// ### Days
///
/// Every day this service writes goes through `WallClock.dayAnchor(from:)`, and
/// every day it matches on goes through `WallClock.isSameStoredDay`. A caller
/// passes a device-local `Date` and never has to know that storage is anchored
/// at UTC. This is the one rule that keeps a Tuesday's calories on Tuesday when
/// the device moves west (#506).
@MainActor
struct MealService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    static func `default`() -> MealService {
        MealService(store: .shared)
    }

    // MARK: - Meals

    /// Insert a new meal, or rewrite the one an explicit `clientUUID` already
    /// names.
    ///
    /// Mirrors `ExpenseService.addExpense` deliberately, including why: a
    /// supplied `clientUUID` is an IDENTITY, so a repeat call carrying one is a
    /// RETRY of a single create rather than a second meal (#514). A Shortcut
    /// that times out and is re-run, or a chat draft replaying the model's own
    /// id, therefore cannot double-log lunch. It also means the update path
    /// needs no separate write: the same call that creates can correct.
    ///
    /// `createdAt` stays at the first attempt, which is when the row was made.
    /// Every other field takes the latest call's value, `loggedAt` included,
    /// because the latest call is the one the user submitted.
    ///
    /// A caller that passes NO id keeps insert-only behaviour, so two genuinely
    /// separate snacks of the same thing stay two rows.
    @discardableResult
    func addMeal(
        date: Date = Date(),
        loggedAt: Date = Date(),
        mealType: MealType,
        mealDescription: String,
        nutrients: MealNutrients = .zero,
        items: [MealItemEntry] = [],
        confidence: Double = 0,
        source: String,
        needsDetail: Bool = false,
        isSuspect: Bool = false,
        suspectReason: String? = nil,
        assumptionsNote: String? = nil,
        containsAlcohol: Bool = false,
        groundingSources: [WebSearchSource] = [],
        clientUUID: String? = nil
    ) throws -> LocalMeal {
        guard !nutrients.hasNegativeValue else { throw MealServiceError.invalidNutrients }

        let anchoredDay = WallClock.dayAnchor(from: date)
        let clampedConfidence = min(max(confidence, 0), 1)

        if let clientUUID, let existing = try existingMeal(clientUUID: clientUUID) {
            existing.date            = anchoredDay
            existing.loggedAt        = loggedAt
            existing.mealTypeEnum    = mealType
            existing.mealDescription = mealDescription
            existing.nutrients       = nutrients
            existing.items           = items
            existing.confidence      = clampedConfidence
            existing.source          = source
            existing.needsDetail     = needsDetail
            existing.isSuspect       = isSuspect
            existing.suspectReason   = suspectReason?.trimmedNonEmptyMealField
            existing.assumptionsNote = assumptionsNote?.trimmedNonEmptyMealField
            existing.containsAlcohol = containsAlcohol
            // #594. Written on every upsert, including with an empty array: a
            // re-estimate that no longer searched must not keep the previous
            // answer's sources, or the meal would claim a provenance its numbers
            // no longer have.
            existing.groundingSources = groundingSources
            existing.updatedAt       = Date()
            try save()
            return existing
        }

        let row = LocalMeal(
            clientUUID: clientUUID ?? UUID().uuidString.lowercased(),
            date: anchoredDay,
            loggedAt: loggedAt,
            mealType: mealType.rawValue,
            mealDescription: mealDescription,
            confidence: clampedConfidence,
            source: source,
            needsDetail: needsDetail,
            isSuspect: isSuspect,
            suspectReason: suspectReason?.trimmedNonEmptyMealField,
            assumptionsNote: assumptionsNote?.trimmedNonEmptyMealField,
            containsAlcohol: containsAlcohol
        )
        row.nutrients = nutrients
        row.items = items
        row.groundingSources = groundingSources
        store.context.insert(row)
        try save()
        return row
    }

    /// The row a `clientUUID` names, or nil. Kept next to `addMeal` because
    /// that is its only caller: it is what makes a supplied id an identity.
    private func existingMeal(clientUUID: String) throws -> LocalMeal? {
        let descriptor = FetchDescriptor<LocalMeal>(
            predicate: #Predicate { $0.clientUUID == clientUUID }
        )
        return try store.context.fetch(descriptor).first
    }

    /// Update a meal in place. Every parameter is optional and nil means "leave
    /// this field alone".
    ///
    /// The two text fields that CAN be cleared take a double optional, so the
    /// caller can say "leave it" (nil), "clear it" (`.some(nil)`) and "set it"
    /// (`.some(value)`). Collapsing an emptied field to plain nil is how #444
    /// and #488 made a deletion impossible to express, and this model has two
    /// fields with exactly that shape.
    func updateMeal(
        _ meal: LocalMeal,
        date: Date? = nil,
        loggedAt: Date? = nil,
        mealType: MealType? = nil,
        mealDescription: String? = nil,
        nutrients: MealNutrients? = nil,
        items: [MealItemEntry]? = nil,
        confidence: Double? = nil,
        source: String? = nil,
        needsDetail: Bool? = nil,
        isSuspect: Bool? = nil,
        suspectReason: String?? = nil,
        assumptionsNote: String?? = nil,
        containsAlcohol: Bool? = nil,
        groundingSources: [WebSearchSource]? = nil
    ) throws {
        if let date {
            meal.date = WallClock.dayAnchor(from: date)
        }
        if let loggedAt {
            meal.loggedAt = loggedAt
        }
        if let mealType {
            meal.mealTypeEnum = mealType
        }
        if let mealDescription {
            meal.mealDescription = mealDescription
        }
        if let nutrients {
            guard !nutrients.hasNegativeValue else { throw MealServiceError.invalidNutrients }
            meal.nutrients = nutrients
        }
        if let items {
            meal.items = items
        }
        if let confidence {
            meal.confidence = min(max(confidence, 0), 1)
        }
        if let source {
            meal.source = source
        }
        if let needsDetail {
            meal.needsDetail = needsDetail
        }
        if let isSuspect {
            meal.isSuspect = isSuspect
        }
        if let suspectReason {
            meal.suspectReason = suspectReason?.trimmedNonEmptyMealField
        }
        if let assumptionsNote {
            meal.assumptionsNote = assumptionsNote?.trimmedNonEmptyMealField
        }
        // #555. A plain `Bool?`, not a double optional, and that is safe here
        // in a way it was not for the two text fields above. A toggle always
        // knows its own state, so it passes `false` rather than nil: "clear it"
        // and "leave it" stay two different requests, which is the whole of
        // what #444 and #488 got wrong.
        if let containsAlcohol {
            meal.containsAlcohol = containsAlcohol
        }
        // #594. A plain optional for the same reason `containsAlcohol` is one:
        // the caller that clears this passes an EMPTY ARRAY, which is a
        // different request from passing nothing. Only `overrideTotals` clears
        // it, and it clears it because typed numbers are not a brand's numbers.
        if let groundingSources {
            meal.groundingSources = groundingSources
        }
        meal.updatedAt = Date()
        try save()
    }

    func deleteMeal(_ meal: LocalMeal) throws {
        store.context.delete(meal)
        try save()
    }

    // MARK: - Fetch

    /// Every meal on one calendar day, earliest first.
    ///
    /// `day` is a DEVICE-local date: pass `Date()` for today. Matching goes
    /// through `WallClock.isSameStoredDay`, so a stored anchor is compared as a
    /// day and never as an instant.
    ///
    /// Filters in memory rather than in a `#Predicate` because the comparison is
    /// a stored-day equality, which a predicate cannot express, and because this
    /// is a personal-scale table — the same call `DataImportService.deleteMatching`
    /// makes.
    func meals(on day: Date) throws -> [LocalMeal] {
        let anchor = WallClock.dayAnchor(from: day)
        return try allMeals().filter { WallClock.isSameStoredDay($0.date, anchor) }
    }

    /// Every meal from `start` to `end` inclusive, both ends read as calendar
    /// days rather than instants, earliest first.
    ///
    /// Inclusive on purpose: a caller asking for "1 to 7 September" means seven
    /// days, and a half-open range would silently drop the seventh.
    func meals(from start: Date, to end: Date) throws -> [LocalMeal] {
        let lower = WallClock.dayAnchor(from: min(start, end))
        let upper = WallClock.dayAnchor(from: max(start, end))
        return try allMeals().filter { meal in
            let day = WallClock.startOfStoredDay(meal.date)
            return day >= lower && day <= upper
        }
    }

    /// Chronological across the whole store: by day, then by the instant within
    /// the day. A food log reads forwards, unlike the Finance list, which reads
    /// newest first.
    private func allMeals() throws -> [LocalMeal] {
        let descriptor = FetchDescriptor<LocalMeal>(
            sortBy: [
                SortDescriptor(\.date, order: .forward),
                SortDescriptor(\.loggedAt, order: .forward)
            ]
        )
        return try store.context.fetch(descriptor)
    }

    // MARK: - Targets

    /// The targets in force on a given day, or nil when none have been set.
    ///
    /// v1 only ever holds one record, so this returns that one. It is written
    /// against `effectiveFrom` anyway because the field exists precisely so that
    /// a second record can arrive later without a migration: the answer is the
    /// latest record that has already taken effect, and if none has, the
    /// earliest record there is (targets set today still describe a meal logged
    /// yesterday).
    func targets(on day: Date = Date()) throws -> MealTargets? {
        let anchor = WallClock.dayAnchor(from: day)
        let all = try store.context.fetch(
            FetchDescriptor<MealTargets>(
                sortBy: [SortDescriptor(\.effectiveFrom, order: .forward)]
            )
        )
        return all.last { WallClock.startOfStoredDay($0.effectiveFrom) <= anchor } ?? all.first
    }

    /// Insert or rewrite a targets record.
    ///
    /// Upserts on `clientUUID` exactly as `addMeal` does, and for the same
    /// reason: a retried save must correct the record it already wrote rather
    /// than leave two sets of targets in a store whose readers expect one.
    /// Passing no id rewrites the record already in force, so the ordinary
    /// "recalculate my targets" path stays a single row without the caller
    /// tracking an id.
    ///
    /// `handEdited` is the set of nutrients the USER typed. A derivation passes
    /// the empty set; an override passes the nutrients the user touched, so a
    /// later re-derivation knows which seven it may refresh.
    @discardableResult
    func saveTargets(
        targets: MealNutrients,
        ageYears: Int,
        biologicalSex: String,
        heightCm: Double,
        weightKg: Double,
        activityLevel: String,
        goal: String,
        rationale: String,
        effectiveFrom: Date = Date(),
        handEdited: Set<Nutrient> = [],
        clientUUID: String? = nil
    ) throws -> MealTargets {
        guard !targets.hasNegativeValue else { throw MealServiceError.invalidNutrients }

        let anchoredFrom = WallClock.dayAnchor(from: effectiveFrom)
        let existing: MealTargets?
        if let clientUUID {
            existing = try store.context
                .fetch(FetchDescriptor<MealTargets>(predicate: #Predicate { $0.clientUUID == clientUUID }))
                .first
        } else {
            existing = try self.targets(on: effectiveFrom)
        }

        let row = existing ?? MealTargets(clientUUID: clientUUID ?? UUID().uuidString.lowercased())
        row.targets       = targets
        row.ageYears      = ageYears
        row.biologicalSex = biologicalSex
        row.heightCm      = heightCm
        row.weightKg      = weightKg
        row.activityLevel = activityLevel
        row.goal          = goal
        row.rationale     = rationale
        row.effectiveFrom = anchoredFrom
        row.handEdited    = handEdited
        row.updatedAt     = Date()
        if existing == nil {
            store.context.insert(row)
        }
        try save()
        return row
    }

    // MARK: - Helpers

    private func save() throws {
        do {
            try store.context.save()
        } catch {
            throw MealServiceError.persistence(error)
        }
    }
}

private extension String {
    /// Trim whitespace, return nil for empty. A note that is only spaces is a
    /// note nobody wrote, and storing it would make an empty callout render.
    ///
    /// Named apart from `ExpenseService`'s private `trimmedNonEmpty` because
    /// both are file-private extensions on `String` in the same module and two
    /// identical names would be ambiguous to nobody but a reader.
    var trimmedNonEmptyMealField: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
