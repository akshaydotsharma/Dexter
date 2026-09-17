import Foundation
import SwiftData

/// Names the meals and plan blocks nobody has named yet (#603).
///
/// ### What it is for
///
/// Every list on this surface prints a dish name. The estimate provides one as
/// a meal is made, so nothing logged from now on needs this. What needs it is
/// everything already in the store: meals logged before the field existed, plan
/// blocks typed and never estimated, and any answer that came back without a
/// name. Those fall through to `MealDisplayName`'s truncation, which is a floor
/// and not an answer.
///
/// ### What it will not do
///
/// It never touches a row that already has a name, and it never asks about a
/// row whose own words are already short enough to print. `MealDisplayName`
/// prints those verbatim, and a name for them would be a call spent turning
/// "Chicken rice" into "Chicken rice".
///
/// ### Why it does not move `updatedAt`
///
/// The sync diff compares CONTENT, so a named row is broadcast to the other
/// device either way. What moving the timestamp would change is who wins a
/// conflict: a naming pass that stamped `updatedAt` on forty rows could beat a
/// genuine edit made on the phone a minute earlier, on last-write-wins. A
/// backfill must never outrank a person.
@MainActor
struct MealNamingService {
    let client: AnthropicClient
    let store: SwiftDataStore

    init(client: AnthropicClient = AnthropicClient(), store: SwiftDataStore) {
        self.client = client
        self.store = store
    }

    static func `default`() -> MealNamingService {
        MealNamingService(store: .shared)
    }

    /// How many rows one pass asks about.
    ///
    /// Forty descriptions is a few thousand tokens, which is one cheap call. A
    /// store with a year of meals in it is named over several launches, newest
    /// first, which is the order they are looked at in.
    static let batchLimit = 40

    /// Name what can be named, in one call. Returns how many rows were written.
    ///
    /// Every failure is silent to the caller by design — it returns zero rather
    /// than throwing — because nothing on screen is broken when this does not
    /// run. The rows keep their shortened words and the next pass tries again.
    @discardableResult
    func runOnce() async -> Int {
        guard let key = AppConfig.anthropicAPIKey, !key.isEmpty else { return 0 }

        let meals = unnamedMeals()
        let entries = unnamedEntries()
        guard !meals.isEmpty || !entries.isEmpty else { return 0 }

        // One batch across BOTH tables, because they are one question. A meal
        // and a plan block are named by the same rule, and splitting them would
        // double the calls to answer it.
        let requests =
            meals.map { MealNamingRequest(id: $0.clientUUID, text: $0.mealDescription) }
            + entries.map { MealNamingRequest(id: $0.clientUUID, text: $0.title) }

        let names: [String: String]
        do {
            names = try await client.nameMeals(Array(requests.prefix(Self.batchLimit)))
        } catch {
            return 0
        }
        guard !names.isEmpty else { return 0 }

        var written = 0
        for meal in meals {
            guard let name = names[meal.clientUUID] else { continue }
            meal.title = name
            written += 1
        }
        for entry in entries {
            guard let name = names[entry.clientUUID] else { continue }
            entry.shortTitle = name
            written += 1
        }
        guard written > 0 else { return 0 }

        do {
            try store.context.save()
        } catch {
            return 0
        }
        return written
    }

    // MARK: - What needs naming

    /// Logged meals with no stored name whose description is too long to print.
    ///
    /// Newest first: the day on screen is the one being read, so it is the one
    /// worth naming first. The length test is `MealDisplayName`'s own cap, so a
    /// row this skips is a row that prints its own words in full.
    func unnamedMeals() -> [LocalMeal] {
        var descriptor = FetchDescriptor<LocalMeal>(
            predicate: #Predicate { $0.title == nil },
            sortBy: [SortDescriptor(\.loggedAt, order: .reverse)]
        )
        // Fetched wider than the batch because the length test cannot be
        // expressed in a `#Predicate` — `String.count` is not available to the
        // predicate compiler — so the filter runs here and a fetch capped at the
        // batch size could come back all-short and name nothing.
        descriptor.fetchLimit = Self.batchLimit * 4
        let rows = (try? store.context.fetch(descriptor)) ?? []
        return rows
            .filter { $0.mealDescription.count > MealDisplayName.characterCap }
            .prefix(Self.batchLimit)
            .map { $0 }
    }

    /// Planned blocks in the same state: no stored name, and a typed title too
    /// long for a tile.
    func unnamedEntries() -> [LocalMealPlanEntry] {
        var descriptor = FetchDescriptor<LocalMealPlanEntry>(
            predicate: #Predicate { $0.shortTitle == nil },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = Self.batchLimit * 4
        let rows = (try? store.context.fetch(descriptor)) ?? []
        return rows
            .filter { $0.title.count > MealDisplayName.characterCap }
            .prefix(Self.batchLimit)
            .map { $0 }
    }
}
