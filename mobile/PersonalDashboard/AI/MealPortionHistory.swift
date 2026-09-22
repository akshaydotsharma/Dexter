import Foundation

/// The portions this user has already accepted, offered back to the estimator
/// (#653).
///
/// ### Why history is a MASS source and never a density one
///
/// It is tempting to offer a past meal's item as a full lookup candidate: it
/// has a name and eight numbers, it is the same shape as a database row, and it
/// would slot straight into `FoodLookupCandidate`.
///
/// That would launder a guess into a source. Most past items were estimated by
/// the model in the first place, so quoting one back as a composition record
/// would turn last week's guess into this week's citation, and the confidence
/// band derived from it would rise for no reason at all. A figure does not
/// become evidence by ageing.
///
/// A PORTION is different, and the difference is the user. A portion that has
/// been through the preview, been looked at, and been left alone is something
/// they accepted about their own plate. It is weak evidence about food in
/// general and good evidence about how much of it this person eats, which is
/// exactly the question the estimator cannot otherwise answer.
///
/// ### Why this matters here specifically
///
/// The log repeats. Over the week to 2026-09-21 the same dishes recur — two GYG
/// bowls, three lattes, three burrata sourdough sandwiches, two protein wafers —
/// and every repeat was re-estimated from nothing. The portion had already been
/// settled and the app asked again.
enum MealPortionHistory {

    /// One dish and the amount of it this user last accepted.
    struct Entry: Sendable, Equatable {
        let name: String
        let quantity: Double
        let unit: String

        /// How many separate meals this dish has appeared in. Shown because a
        /// portion accepted six times is a habit and one accepted once is an
        /// occasion.
        let timesLogged: Int
    }

    /// How far back to look.
    ///
    /// Six weeks. Long enough to catch something eaten monthly, short enough
    /// that a portion from a different phase of eating does not come back to
    /// argue for itself.
    static let window: TimeInterval = 42 * 24 * 60 * 60

    /// How many dishes the prompt carries.
    ///
    /// Twenty-five, ordered by how often they recur. The block is paid for on
    /// every estimate, and the tail of a food log is long and almost never
    /// repeats: the dishes worth carrying are the ones that come back.
    static let limit = 25

    /// Build the list from logged meals.
    ///
    /// Deduplicated by dish name, case-insensitively, keeping the MOST RECENT
    /// portion rather than an average. An average of 200 g and 400 g is 300 g,
    /// which is a portion that never happened; the last one is at least a
    /// portion this person actually had.
    static func entries(from meals: [LocalMeal], now: Date = Date()) -> [Entry] {
        let cutoff = now.addingTimeInterval(-window)

        struct Accumulator {
            var quantity: Double
            var unit: String
            var loggedAt: Date
            var count: Int
        }
        var byName: [String: Accumulator] = [:]

        for meal in meals where meal.loggedAt >= cutoff {
            // A flagged meal's portions are exactly the ones nobody should be
            // quoting back: the meal is held out of every total precisely
            // because its numbers are not trusted.
            guard !meal.isSuspect, !meal.needsDetail else { continue }

            for item in meal.items {
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let unit = item.portionUnit.lowercased()
                guard !name.isEmpty,
                      item.portionQuantity > 0,
                      MealEstimateGuards.scalableUnits.contains(unit) else { continue }

                let key = name.lowercased()
                if var existing = byName[key] {
                    existing.count += 1
                    if meal.loggedAt > existing.loggedAt {
                        existing.quantity = item.portionQuantity
                        existing.unit = unit
                        existing.loggedAt = meal.loggedAt
                    }
                    byName[key] = existing
                } else {
                    byName[key] = Accumulator(
                        quantity: item.portionQuantity,
                        unit: unit,
                        loggedAt: meal.loggedAt,
                        count: 1
                    )
                }
            }
        }

        // Most repeated first, then most recent. A stable order matters beyond
        // tidiness: this block sits in a prompt, and a list that reshuffles
        // between two identical estimates makes them two different requests.
        return byName
            .map { key, value in
                (key: key, value: value)
            }
            .sorted {
                if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                if $0.value.loggedAt != $1.value.loggedAt { return $0.value.loggedAt > $1.value.loggedAt }
                return $0.key < $1.key
            }
            .prefix(limit)
            .map { entry in
                Entry(
                    name: entry.key,
                    quantity: entry.value.quantity,
                    unit: entry.value.unit,
                    timesLogged: entry.value.count
                )
            }
    }

    /// The prompt block, or an empty string when there is no history worth
    /// carrying.
    static func promptBlock(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else { return "" }

        var out = """


        PORTIONS THIS USER HAS ACCEPTED BEFORE. Each line is a dish and the \
        amount of it they last logged. Use one when the description names the \
        same dish and gives no amount of its own, and then set "mass_source" to \
        "history". These say nothing about what the food CONTAINS — look that up \
        as usual — only about how much of it this person eats.
        """
        for entry in entries {
            let amount = entry.quantity.rounded() == entry.quantity
                ? String(format: "%.0f", entry.quantity)
                : String(format: "%.1f", entry.quantity)
            out += "\n- \(entry.name): \(amount) \(entry.unit)"
            if entry.timesLogged > 1 { out += " (\(entry.timesLogged) times)" }
        }
        return out
    }

    /// Does this portion actually appear in the history for this dish?
    ///
    /// The `history` claim is checkable for the same reason `standard_portion`
    /// is: the device is holding the list the model was shown. A claim that
    /// matches no line in it is the model's own number wearing a citation, and
    /// is demoted exactly as an unmatched portion-table quote is.
    ///
    /// Matching is on the dish name, loosely, because the model renames things
    /// between runs ("Latte" one day, "Latte with whole milk" the next) and a
    /// strict match would reject a portion that is genuinely theirs. The
    /// QUANTITY is matched strictly, within the same 2% that reads as rounding.
    static func supports(
        name: String?,
        quantity: Double,
        unit: String,
        in entries: [Entry]
    ) -> Bool {
        let needle = (name ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, quantity > 0 else { return false }

        return entries.contains { entry in
            guard entry.unit == unit.lowercased() else { return false }
            guard abs(entry.quantity - quantity) / max(entry.quantity, 0.0001) <= 0.02 else { return false }
            return entry.name.contains(needle) || needle.contains(entry.name)
        }
    }
}
