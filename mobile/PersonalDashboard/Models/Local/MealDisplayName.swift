import Foundation

/// The short name a list draws for a meal, logged or planned (#603).
///
/// ### The problem it solves
///
/// A logged meal stores what the user SAID, verbatim, and that is the right
/// thing to store: it is the text a re-estimate runs against and the text the
/// user recognises as theirs. It is the wrong thing to print five times down a
/// day. "Two eggs on toast with butter and a flat white, made at home" is a
/// sentence, and a list of sentences is a paragraph with times beside it.
///
/// So the list draws a NAME and the detail sheet draws the sentence. This is the
/// single place that decides what the name is, which is what stops the day card,
/// the Today tile, the chat card and the plan block from each answering it
/// differently.
///
/// ### The order it resolves in, and why
///
/// 1. **The stored title.** `LocalMeal.title` is what the estimate called the
///    dish, asked for in the same call that produced the numbers. A model that
///    has just read the description and broken it into dishes is the best namer
///    available, and it costs nothing extra.
/// 2. **The text itself, when it is already short.** A log of "Chicken rice" is
///    a name. Shortening what is already a name would only ever make it worse.
/// 3. **The items.** For every row logged before the title existed, and for any
///    answer that arrives without one. It reads as an ingredient list rather
///    than as a dish, which is why it is third and not first, but it beats a
///    sentence cut off in the middle.
/// 4. **The sentence, truncated at a word.** The floor. Never a cut mid-word,
///    and never an empty string: a meal with no readable name at all still has
///    to draw something a finger can aim at.
///
/// A PLANNED block skips step 1 and step 3. Its title is the user's own words,
/// typed into "What are you having?", and there is nothing for a model to
/// improve about a name somebody chose. It is shortened and nothing else.
enum MealDisplayName {

    /// The longest a name may be drawn.
    ///
    /// 44 characters is about two thirds of a phone line at `.edBody`, which is
    /// what leaves the calorie figure on the same line as the name on the
    /// narrowest surface this draws on. Long enough that most real dishes are
    /// never touched at all.
    static let characterCap = 44

    // MARK: - The two callers

    /// The name for one logged meal.
    static func short(for meal: LocalMeal) -> String {
        short(title: meal.title, items: meal.items, text: meal.mealDescription)
    }

    /// The name for one planned block.
    ///
    /// The title IS the user's words here, so there is no stored short form and
    /// no item fallback: shortening is the whole of the work. The plan sheet
    /// shows the full title in its field, which is where the rest of it lives.
    static func short(for entry: LocalMealPlanEntry) -> String {
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : shorten(trimmed)
    }

    /// The resolution itself, over values rather than models, so it can be
    /// tested without a store.
    static func short(title: String?, items: [MealItemEntry], text: String) -> String {
        if let stored = title?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return shorten(stored)
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty, trimmedText.count <= characterCap {
            return trimmedText
        }

        if let fromItems = fromItems(items) {
            return fromItems
        }

        return trimmedText.isEmpty ? "Untitled meal" : shorten(trimmedText)
    }

    /// True when the short name is not the whole of the text, so a surface can
    /// say there is more to read without comparing two strings itself.
    static func isShortened(for meal: LocalMeal) -> Bool {
        short(for: meal) != meal.mealDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The fallbacks

    /// The dishes, named, as a last resort before truncation.
    ///
    /// Names are kept in the order the estimate returned them, because that is
    /// the order the user said them in, and the first dish is nearly always the
    /// meal. Names are taken verbatim when they carry an interior capital (a
    /// brand, "Big Mac") and lowercased otherwise, so a run of them reads as one
    /// phrase rather than as a list of headings.
    static func fromItems(_ items: [MealItemEntry]) -> String? {
        let names = items
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = names.first else { return nil }

        var assembled = first
        var used = 1
        for name in names.dropFirst() {
            let candidate = assembled + ", " + caseFolded(name)
            // The "+n" that would be appended is counted here, so the name can
            // never overrun the cap by the width of its own overflow marker.
            guard candidate.count + 3 <= characterCap else { break }
            assembled = candidate
            used += 1
        }

        let remaining = names.count - used
        if remaining > 0 { assembled += " +\(remaining)" }
        return shorten(assembled)
    }

    /// Lowercase a name that reads as an ordinary phrase; leave a brand alone.
    ///
    /// The test is an interior capital: "Flat white" is a phrase and becomes
    /// "flat white", "Big Mac" and "Coke Zero" are names and are left as they
    /// are. Crude, and right far more often than either blanket rule.
    private static func caseFolded(_ name: String) -> String {
        let interior = name.dropFirst()
        guard !interior.contains(where: { $0.isUppercase }) else { return name }
        return name.prefix(1).lowercased() + interior
    }

    /// Cut to the cap at a word boundary, with an ellipsis.
    ///
    /// Never mid-word: a name that stops inside a word reads as a rendering bug
    /// rather than as an abbreviation. When the first word is itself longer than
    /// the cap there is no boundary to find, and the hard cut is the only answer
    /// left.
    static func shorten(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > characterCap else { return trimmed }

        let window = trimmed.prefix(characterCap)
        let body: Substring
        if let lastSpace = window.lastIndex(of: " "), window.distance(from: window.startIndex, to: lastSpace) > 8 {
            body = window[window.startIndex..<lastSpace]
        } else {
            body = window
        }
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:-–—."))
        return cleaned + "…"
    }
}
