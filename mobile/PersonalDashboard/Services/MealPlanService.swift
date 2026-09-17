import Foundation
import SwiftData

/// Errors thrown by `MealPlanService` (#599).
enum MealPlanServiceError: LocalizedError {
    case emptyTitle
    case invalidNutrients
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .emptyTitle:           return "A planned meal needs something in it."
        case .invalidNutrients:     return "Nutrient values cannot be negative."
        case .persistence(let err): return err.localizedDescription
        }
    }
}

/// CRUD over `LocalMealPlanEntry` (#599). Operates on the shared SwiftData
/// context, like every other service here.
///
/// ### Days
///
/// Every day this service writes goes through `WallClock.dayAnchor(from:)`, and
/// every day it matches on goes through `WallClock.isSameStoredDay`. A caller
/// passes a device-local `Date` and never has to know that storage is anchored
/// at UTC. Same rule as `MealService`, and it is the one that keeps Thursday's
/// dinner on Thursday when the device moves west (#506).
///
/// ### Ordering is maintained here, not in the schema
///
/// `slotIndex` decides the order of several snacks within a day. It is NOT part
/// of a unique constraint, because a unique compound key would make an ordinary
/// insert REPLACE the sibling already sitting at that index — the failure #514
/// documents for `@Attribute(.unique)`. So every write that can disturb the
/// order ends by renumbering that one (day, meal type) pair from zero through
/// ``normaliseIndices(on:mealType:)``. A bad index then costs an ordering and
/// never a row.
@MainActor
struct MealPlanService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    static func `default`() -> MealPlanService {
        MealPlanService(store: .shared)
    }

    // MARK: - Writes

    /// Add a planned block, or rewrite the one an explicit `clientUUID` names.
    ///
    /// Upserts on a supplied id for the same reason `MealService.addMeal` does:
    /// an id passed in is an IDENTITY, so a repeat call carrying one is a RETRY
    /// of a single add rather than a second block (#514). A caller that passes
    /// no id keeps insert-only behaviour, which is what lets two genuinely
    /// separate snacks of the same thing stay two blocks.
    ///
    /// `slotIndex` is chosen here rather than by the caller. A view that picked
    /// its own would have to re-read the day first, and two views doing that
    /// would eventually disagree.
    @discardableResult
    func addEntry(
        date: Date,
        mealType: MealType,
        title: String,
        ingredients: [String] = [],
        notes: String? = nil,
        recipe: String? = nil,
        status: MealPlanStatus = .planned,
        nutrients: MealNutrients? = nil,
        items: [MealItemEntry] = [],
        source: String = MealPlanSource.manual,
        clientUUID: String? = nil
    ) throws -> LocalMealPlanEntry {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw MealPlanServiceError.emptyTitle }
        if let nutrients, nutrients.hasNegativeValue { throw MealPlanServiceError.invalidNutrients }

        let anchoredDay = WallClock.dayAnchor(from: date)

        if let clientUUID, let existing = try existingEntry(clientUUID: clientUUID) {
            existing.date          = anchoredDay
            existing.mealTypeEnum  = mealType
            existing.title         = cleanTitle
            existing.ingredients   = Self.cleaned(ingredients)
            existing.notes         = notes?.trimmedNonEmptyPlanField
            existing.recipe        = recipe?.trimmedNonEmptyPlanField
            existing.statusEnum    = status
            existing.plannedNutrients = nutrients
            existing.items         = items
            existing.source        = source
            existing.updatedAt     = Date()
            try save()
            try normaliseIndices(on: anchoredDay, mealType: mealType)
            return existing
        }

        let row = LocalMealPlanEntry(
            clientUUID: clientUUID ?? UUID().uuidString.lowercased(),
            date: anchoredDay,
            mealType: mealType.rawValue,
            slotIndex: try nextSlotIndex(on: anchoredDay, mealType: mealType),
            title: cleanTitle,
            notes: notes?.trimmedNonEmptyPlanField,
            recipe: recipe?.trimmedNonEmptyPlanField,
            status: status.rawValue,
            source: source
        )
        row.ingredients = Self.cleaned(ingredients)
        row.plannedNutrients = nutrients
        row.items = items
        store.context.insert(row)
        try save()
        return row
    }

    /// Update a block in place. Every parameter is optional and nil means
    /// "leave this field alone".
    ///
    /// The two fields that CAN be cleared take a double optional, so the caller
    /// can say "leave it" (nil), "clear it" (`.some(nil)`) and "set it"
    /// (`.some(value)`). Collapsing an emptied field to plain nil is how #444
    /// and #488 each made a deletion impossible to express, and this model has
    /// exactly that shape twice: a note the user erased and a set of numbers
    /// the user no longer stands behind.
    ///
    /// `ingredients` needs no such treatment. An empty array IS the cleared
    /// state and is a different value from nil, so "remove every ingredient" is
    /// already expressible.
    func updateEntry(
        _ entry: LocalMealPlanEntry,
        date: Date? = nil,
        mealType: MealType? = nil,
        title: String? = nil,
        ingredients: [String]? = nil,
        notes: String?? = nil,
        recipe: String?? = nil,
        status: MealPlanStatus? = nil,
        nutrients: MealNutrients?? = nil,
        items: [MealItemEntry]? = nil,
        source: String? = nil
    ) throws {
        // Held before the write so the OLD pair can be renumbered too when a
        // block moves day or meal type. Renumbering only the destination would
        // leave a hole in the source, and the next add there would reuse an
        // index that is still occupied further down the list.
        let previousDay = WallClock.startOfStoredDay(entry.date)
        let previousType = entry.mealTypeEnum

        if let title {
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw MealPlanServiceError.emptyTitle }
            entry.title = clean
        }
        if let nutrients {
            if let nutrients, nutrients.hasNegativeValue { throw MealPlanServiceError.invalidNutrients }
            entry.plannedNutrients = nutrients
        }
        if let date {
            entry.date = WallClock.dayAnchor(from: date)
        }
        if let mealType {
            entry.mealTypeEnum = mealType
        }
        if let ingredients {
            entry.ingredients = Self.cleaned(ingredients)
        }
        if let notes {
            entry.notes = notes?.trimmedNonEmptyPlanField
        }
        // A double optional for the same reason `notes` is one: a recipe the
        // user erased is a different request from a recipe they left alone, and
        // collapsing the two makes a deletion inexpressible (#444, #488).
        if let recipe {
            entry.recipe = recipe?.trimmedNonEmptyPlanField
        }
        // A plain optional, because an EMPTY array already means "clear the
        // breakdown" and is a different value from nil. Same call `ingredients`
        // makes above.
        if let items {
            entry.items = items
        }
        if let status {
            entry.statusEnum = status
        }
        if let source {
            entry.source = source
        }

        // A block that changed day or meal type joins the end of its new slot
        // rather than keeping an index that means nothing there.
        let movedSlot = (date != nil && !WallClock.isSameStoredDay(entry.date, previousDay))
            || (mealType != nil && entry.mealTypeEnum != previousType)
        if movedSlot {
            entry.slotIndex = try nextSlotIndex(on: entry.date, mealType: entry.mealTypeEnum)
        }

        entry.updatedAt = Date()
        try save()

        if movedSlot {
            try normaliseIndices(on: previousDay, mealType: previousType)
            try normaliseIndices(on: entry.date, mealType: entry.mealTypeEnum)
        }
    }

    /// Set a block's state. The one write behind Skip, Un-skip and the eaten
    /// tick.
    ///
    /// A named method rather than a call to ``updateEntry(_:...)`` with one
    /// argument, because this is the write the row makes on every tap and it
    /// must not be able to disturb anything else on the block by accident.
    func setStatus(_ status: MealPlanStatus, on entry: LocalMealPlanEntry) throws {
        entry.statusEnum = status
        entry.updatedAt = Date()
        try save()
    }

    /// Delete a block, then close the gap it left in its slot.
    func deleteEntry(_ entry: LocalMealPlanEntry) throws {
        let day = WallClock.startOfStoredDay(entry.date)
        let type = entry.mealTypeEnum
        store.context.delete(entry)
        try save()
        try normaliseIndices(on: day, mealType: type)
    }

    /// Delete every block on a day. The "clear this day" action.
    func clearDay(_ day: Date) throws {
        for entry in try entries(on: day) {
            store.context.delete(entry)
        }
        try save()
    }

    // MARK: - Copying

    /// Copy a day's plan onto another day.
    ///
    /// The cheapest way to fill a week, and it makes NO API call: the blocks
    /// carry their numbers across as they stand, which is the same call
    /// `MealEstimationService.repeatMeal` makes about a repeated meal.
    ///
    /// Skipped blocks are not copied. A meal you decided not to eat on Monday
    /// is not a plan for Tuesday; copying it would make the user un-skip a
    /// decision they already made.
    ///
    /// Additive, never destructive: the destination keeps whatever is already
    /// on it and the copies join the end of their slots. A copy that wiped the
    /// target day would be one undo away from losing a plan the user typed, and
    /// clearing first is available as its own action.
    @discardableResult
    func copyDay(from source: Date, to destination: Date) throws -> [LocalMealPlanEntry] {
        let sourceEntries = MealPlanDay.order(try entries(on: source))
        var made: [LocalMealPlanEntry] = []
        for entry in sourceEntries where entry.countsTowardsPlan {
            made.append(
                try addEntry(
                    date: destination,
                    mealType: entry.mealTypeEnum,
                    title: entry.title,
                    ingredients: entry.ingredients,
                    notes: entry.notes,
                    recipe: entry.recipe,
                    // A copy is something to do, never something already done.
                    // Carrying `.eaten` across would tick a meal on a day that
                    // has not happened.
                    status: .planned,
                    nutrients: entry.plannedNutrients,
                    items: entry.items,
                    source: MealPlanSource.copy
                )
            )
        }
        return made
    }

    /// Plan a meal that has already been logged once.
    ///
    /// No API call: the logged meal's stored estimate is copied as the plan's
    /// numbers. A suspect meal's numbers are copied too, and are copied
    /// KNOWINGLY — the plan is "eat that again", and the estimate being shaky
    /// does not change what the user intends to eat. The Tracking surface is
    /// where that meal's figures get argued with.
    ///
    /// A meal that needs detail carries no numbers at all, so the block it
    /// makes carries none either rather than a row of zeros.
    @discardableResult
    func planLoggedMeal(
        _ meal: LocalMeal,
        on day: Date,
        mealType: MealType? = nil
    ) throws -> LocalMealPlanEntry {
        try addEntry(
            date: day,
            mealType: mealType ?? meal.mealTypeEnum,
            // The short NAME, not the verbatim description (#603). A plan block
            // is titled with what the dish is called, and a logged meal's text
            // is a sentence about what was eaten. Copying the sentence across
            // made a block whose title wrapped over three lines.
            title: MealDisplayName.short(for: meal),
            // The dishes are NOT the ingredients: "chicken rice" is one dish
            // made of four things. A logged meal has no ingredient list — there
            // was nothing to shop for by the time it was logged — so the block
            // starts without one and the user can estimate for it.
            ingredients: [],
            status: .planned,
            nutrients: meal.needsDetail ? nil : meal.nutrients,
            items: meal.items,
            source: MealPlanSource.copy
        )
    }

    // MARK: - Fetch

    /// Every block on one calendar day.
    ///
    /// `day` is a DEVICE-local date. Matching goes through
    /// `WallClock.isSameStoredDay`, so a stored anchor is compared as a day and
    /// never as an instant (#506).
    ///
    /// Filters in memory rather than in a `#Predicate` for the reason
    /// `MealService.meals(on:)` gives: the comparison is a stored-day equality,
    /// which a predicate cannot express, and this is a personal-scale table.
    func entries(on day: Date) throws -> [LocalMealPlanEntry] {
        let anchor = WallClock.dayAnchor(from: day)
        return MealPlanDay.order(
            try allEntries().filter { WallClock.isSameStoredDay($0.date, anchor) }
        )
    }

    /// Every block from `start` to `end`, both ends read as calendar days
    /// rather than instants, and both INCLUSIVE.
    ///
    /// Inclusive on purpose, matching `MealService.meals(from:to:)`: a caller
    /// asking for a week means seven days, and a half-open range would silently
    /// drop the seventh.
    func entries(from start: Date, to end: Date) throws -> [LocalMealPlanEntry] {
        let lower = WallClock.dayAnchor(from: min(start, end))
        let upper = WallClock.dayAnchor(from: max(start, end))
        return try allEntries().filter { entry in
            let day = WallClock.startOfStoredDay(entry.date)
            return day >= lower && day <= upper
        }
    }

    /// The whole table, ordered by day. Within a day, `MealPlanDay.order`
    /// decides, so this only has to be stable.
    private func allEntries() throws -> [LocalMealPlanEntry] {
        try store.context.fetch(
            FetchDescriptor<LocalMealPlanEntry>(
                sortBy: [
                    SortDescriptor(\.date, order: .forward),
                    SortDescriptor(\.slotIndex, order: .forward),
                    SortDescriptor(\.createdAt, order: .forward)
                ]
            )
        )
    }

    /// The row a `clientUUID` names, or nil.
    private func existingEntry(clientUUID: String) throws -> LocalMealPlanEntry? {
        try store.context.fetch(
            FetchDescriptor<LocalMealPlanEntry>(
                predicate: #Predicate { $0.clientUUID == clientUUID }
            )
        ).first
    }

    // MARK: - Ordering

    /// The index a new block of this meal type takes on this day.
    private func nextSlotIndex(on day: Date, mealType: MealType) throws -> Int {
        let anchor = WallClock.dayAnchor(from: day)
        let siblings = try allEntries().filter {
            WallClock.isSameStoredDay($0.date, anchor) && $0.mealTypeEnum == mealType
        }
        return (siblings.map(\.slotIndex).max() ?? -1) + 1
    }

    /// Renumber one (day, meal type) pair from zero, keeping the order the
    /// blocks are already in.
    ///
    /// Called after every write that can leave a hole or a collision. It never
    /// reorders anything the user can see — `MealPlanDay.order` already sorts
    /// by index and breaks ties by creation time, so this writes down the order
    /// that was being displayed anyway.
    ///
    /// Silent when nothing needs changing, so an ordinary edit does not touch
    /// `updatedAt` on rows the user did not edit. That matters beyond tidiness:
    /// sync's diff compares content hashes, and a no-op renumber that still
    /// wrote would broadcast every sibling block on the day as changed.
    func normaliseIndices(on day: Date, mealType: MealType) throws {
        let anchor = WallClock.dayAnchor(from: day)
        let siblings = MealPlanDay.order(
            try allEntries().filter {
                WallClock.isSameStoredDay($0.date, anchor) && $0.mealTypeEnum == mealType
            }
        )
        var changed = false
        for (index, entry) in siblings.enumerated() where entry.slotIndex != index {
            entry.slotIndex = index
            entry.updatedAt = Date()
            changed = true
        }
        if changed { try save() }
    }

    /// Move a block to a new position within its own slot.
    ///
    /// `destination` is an index into the slot as it reads now. Out-of-range
    /// values clamp rather than throw: a drag that overshoots the end of a list
    /// means "put it last", which is what the user did, not an error.
    func move(_ entry: LocalMealPlanEntry, toIndex destination: Int) throws {
        let day = WallClock.startOfStoredDay(entry.date)
        let type = entry.mealTypeEnum
        var siblings = MealPlanDay.order(
            try allEntries().filter {
                WallClock.isSameStoredDay($0.date, day) && $0.mealTypeEnum == type
            }
        )
        guard let from = siblings.firstIndex(where: { $0.clientUUID == entry.clientUUID }) else { return }
        let to = min(max(destination, 0), siblings.count - 1)
        guard to != from else { return }
        let moved = siblings.remove(at: from)
        siblings.insert(moved, at: to)
        for (index, sibling) in siblings.enumerated() where sibling.slotIndex != index {
            sibling.slotIndex = index
            sibling.updatedAt = Date()
        }
        try save()
    }

    // MARK: - Helpers

    /// Trim, drop the empties, and drop a repeat of something already in the
    /// list.
    ///
    /// De-duplicated case-insensitively because "Eggs" and "eggs" on one block
    /// are one ingredient typed twice, and a chip appearing twice on a card
    /// reads as a bug in the card. The FIRST spelling wins, so the list stays
    /// in the user's own words and in the order they typed.
    ///
    /// `nonisolated` because it is pure and because the callers are not all on
    /// the main actor: `MealPlanSuggestion.from(toolInput:)` decodes a tool
    /// payload off it. Keeping the rule here rather than copying it there is
    /// what stops the editor, the chat and the service disagreeing about what
    /// counts as a repeat.
    nonisolated static func cleaned(_ ingredients: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in ingredients {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }

    private func save() throws {
        do {
            try store.context.save()
        } catch {
            throw MealPlanServiceError.persistence(error)
        }
    }
}

private extension String {
    /// Trim whitespace, return nil for empty. A note that is only spaces is a
    /// note nobody wrote, and storing it would make an empty callout render.
    ///
    /// Named apart from the equivalents in `ExpenseService` and `MealService`
    /// because all three are file-private extensions on `String` in the same
    /// module, and three identical names would be ambiguous to nobody but a
    /// reader.
    var trimmedNonEmptyPlanField: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
