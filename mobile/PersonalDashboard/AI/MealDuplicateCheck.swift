import Foundation

/// One meal reduced to just the four fields the duplicate rule reads (#543).
///
/// A value type rather than the `@Model`, so the rule is pure: it can be tested
/// without a store, and the composer can ask "would the meal I am about to write
/// be a duplicate" before that meal exists as a row.
struct MealDuplicateCandidate: Equatable, Sendable {
    /// `LocalMeal.clientUUID`, or any stand-in for a row not yet written.
    let id: String
    /// The stored UTC day anchor, compared as a day and never as an instant.
    let dayAnchor: Date
    let mealType: MealType
    let mealDescription: String
    let loggedAt: Date
}

/// Soft detection of the same meal logged twice (#543).
///
/// ### Why this never blocks
///
/// People do drink two coffees, eat the same breakfast two days running, and
/// finish a bowl and go back for another. A hard block on any of those is a bug
/// you would hit in the first week, and the cost of being wrong is asymmetric:
/// a missed duplicate is a number the user can delete, a blocked meal is a
/// capture path that has stopped working.
///
/// So the rule only ever FLAGS. Both rows are marked, the user is offered keep
/// both, replace or discard, and the default is keep both.
///
/// ### Why there is no stored flag
///
/// The flag is derived from the day's rows on every read rather than written to
/// a column. It has to be: it is a property of a PAIR, so deleting one row makes
/// the other one no longer a duplicate, and a stored flag would be left behind
/// saying otherwise. Deriving it also keeps the meal schema untouched.
enum MealDuplicateCheck {

    /// How close in time two logs of the same thing have to be to read as one
    /// meal entered twice rather than as two meals.
    ///
    /// Two hours because a second breakfast at 11:00 is a real second meal and a
    /// second breakfast at 08:05 is almost always the first one entered again —
    /// a Shortcut re-run, a chat draft confirmed twice, a slip of the thumb.
    static let window: TimeInterval = 2 * 60 * 60

    /// How much of the two descriptions has to overlap. Jaccard over the
    /// normalised word sets, so word order and filler do not matter.
    static let similarityThreshold: Double = 0.6

    /// Every candidate that shares a day, a meal type, a similar description and
    /// a two-hour window with at least one other candidate.
    ///
    /// Returns the ids of BOTH sides of every matching pair, because both rows
    /// carry the flag: the user is choosing between two meals, and marking only
    /// the newer one would hide half the choice.
    static func flaggedIDs(among candidates: [MealDuplicateCandidate]) -> Set<String> {
        var flagged: Set<String> = []
        guard candidates.count > 1 else { return flagged }

        for i in candidates.indices {
            for j in candidates.indices where j > i {
                if areDuplicates(candidates[i], candidates[j]) {
                    flagged.insert(candidates[i].id)
                    flagged.insert(candidates[j].id)
                }
            }
        }
        return flagged
    }

    /// Whichever already-stored meals the given candidate duplicates.
    ///
    /// Used by the composer before the row is written, so the choice between
    /// keep both, replace and discard is offered while replacing is still
    /// cheap.
    static func matches(
        for candidate: MealDuplicateCandidate,
        among existing: [MealDuplicateCandidate]
    ) -> [MealDuplicateCandidate] {
        existing.filter { $0.id != candidate.id && areDuplicates($0, candidate) }
    }

    /// The rule itself: same day, same meal type, similar description, logged
    /// within the window.
    static func areDuplicates(
        _ lhs: MealDuplicateCandidate,
        _ rhs: MealDuplicateCandidate
    ) -> Bool {
        guard WallClock.isSameStoredDay(lhs.dayAnchor, rhs.dayAnchor) else { return false }
        guard lhs.mealType == rhs.mealType else { return false }
        guard abs(lhs.loggedAt.timeIntervalSince(rhs.loggedAt)) <= window else { return false }
        return isSimilar(lhs.mealDescription, rhs.mealDescription)
    }

    // MARK: - Description similarity

    /// Words that carry no information about WHAT was eaten.
    ///
    /// Three groups, all of them quantity rather than identity.
    ///
    /// COUNTS, spelled and digit forms both. "two coffees" and "a coffee" are
    /// the pair this rule most needs to catch, and they differ by exactly a
    /// count: keeping the count in the comparison drops their overlap to a half
    /// and the pair goes unflagged. The quantity is the thing the user is being
    /// asked about, so it must not be what hides the question.
    ///
    /// PORTION NOUNS, for the same reason one step removed: "2 slices of toast"
    /// and "toast" name one food, and "slice" is part of how much, not part of
    /// what.
    ///
    /// GRAMMAR, which never carried anything.
    static let ignoredWords: Set<String> = [
        // Grammar
        "a", "an", "the", "and", "with", "of", "some", "my", "plus", "for",
        // Counts
        "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "half", "couple", "few",
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
        // Portions and sizes
        "slice", "piece", "bowl", "cup", "glass", "plate", "serving", "portion",
        "pack", "packet", "can", "bottle", "scoop", "handful", "spoonful",
        "tbsp", "tsp", "spoon", "g", "ml", "gram", "small", "medium", "large"
    ]

    /// Lowercase, strip punctuation, singularise a trailing "s", drop the
    /// filler, and return what is left as a set.
    ///
    /// Singularisation runs BEFORE the filter, not after, so "slices" and
    /// "coffees" are tested against the list in the form the list holds. Doing
    /// it the other way round means every plural slips the filter, which is
    /// invisible until a pair that should match does not.
    ///
    /// The singularisation itself is crude on purpose: "coffees" and "coffee"
    /// have to land on the same token, and a real stemmer is a dependency this
    /// rule does not earn. The words it gets wrong ("hummus", "couscous") are
    /// wrong CONSISTENTLY, so two descriptions holding the same word still match
    /// each other.
    static func tokens(_ description: String) -> Set<String> {
        let cleaned = description.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        let words = String(cleaned)
            .split(separator: " ")
            .map(String.init)
            .map { word -> String in
                (word.count > 3 && word.hasSuffix("s")) ? String(word.dropLast()) : word
            }
            .filter { !ignoredWords.contains($0) }
        return Set(words)
    }

    /// Jaccard overlap of the two normalised word sets, against the threshold.
    ///
    /// Two descriptions that both normalise to nothing (pure filler) are NOT
    /// similar. An empty set matching an empty set would flag every pair of
    /// contentless logs as duplicates of each other.
    static func isSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let a = tokens(lhs)
        let b = tokens(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let union = a.union(b).count
        guard union > 0 else { return false }
        let overlap = Double(a.intersection(b).count) / Double(union)
        return overlap >= similarityThreshold
    }
}

extension MealDuplicateCandidate {
    /// Reduce a stored row to the four fields the rule reads.
    init(_ meal: LocalMeal) {
        self.init(
            id: meal.clientUUID,
            dayAnchor: meal.date,
            mealType: meal.mealTypeEnum,
            mealDescription: meal.mealDescription,
            loggedAt: meal.loggedAt
        )
    }
}

extension MealDuplicateCheck {
    /// The stored rows to flag, as `clientUUID`s.
    static func flaggedIDs(among meals: [LocalMeal]) -> Set<String> {
        flaggedIDs(among: meals.map(MealDuplicateCandidate.init))
    }
}
