import Foundation

/// One item chosen for a meal, already scaled to the amount on screen (#625).
///
/// ### Why the nutrients are carried and not the row
///
/// `entry` is a plain `MealItemEntry` with the eight numbers already worked out
/// for the amount on screen, which is the same value type an estimate produces
/// and the same one `LocalMeal` stores. So whoever receives a pick writes it the
/// way it writes any other item, and nothing downstream has to know the library
/// exists.
///
/// ### Why there is an origin rather than a row id
///
/// Because a pick can be something the user has never saved. The picker searches
/// his own items and the public food database in one field, offers to estimate
/// anything neither of them can price, and every one of those three results goes
/// straight in the tray when it is tapped. A `.database` or `.estimated` pick
/// has no row behind it at all: nothing is written when it is tapped, so a
/// result he tries and then removes leaves the library exactly as it was.
///
/// That is the property the first version of this feature got wrong. Writing a
/// row at tap time, or asking for a confirm form before the tap, both turn the
/// list into something the user has to curate. The rule now is that eating an
/// item is what makes it his, so `commit` is the only thing that writes.
///
/// `id` is this pick's identity in the tray, held apart from `entry.id` because
/// editing an amount rebuilds the entry and a list whose rows change identity
/// under an open keyboard loses the caret.
struct FoodItemPick: Identifiable, Equatable, Sendable {

    var id: UUID = UUID()

    /// Where this pick came from, and therefore what committing it has to do.
    enum Origin: Equatable, Sendable {
        /// A row already in the library. Committing counts a use and nothing
        /// else.
        case saved(itemUUID: String)
        /// A hit that is not the user's yet. Committing writes it.
        case database(FoodItemDraft)
        /// Numbers the estimator worked out from the name the user typed,
        /// because nothing with a label answers for it. Committing writes it,
        /// exactly as a hit does.
        ///
        /// Deliberately NOT a `.database` pick wearing a different hat. A cafe
        /// cappuccino has no barcode and no usable record: Open Food Facts
        /// answers "cappuccino" with thousands of instant-coffee sachets and
        /// not one calorie figure between them, so the estimator is the only
        /// thing that can price it. What comes back is a guess rather than a
        /// transcription, it carries no outside identity at all, and it enters
        /// the library under `FoodItemSource.estimate`. Three things a reader
        /// who saw `.database` would get wrong.
        ///
        /// Everywhere else it behaves as a hit does: nothing is written when it
        /// is tapped, it scales off its own draft, and it becomes a row only on
        /// commit.
        case estimated(FoodItemDraft)

        /// One string naming the THING a pick is of, for "is this already in
        /// the tray" and for nothing else.
        ///
        /// Not the pick's `id`, which names one tray row, and not the entry's
        /// name, which two flavours of the same bar can share. A saved row is
        /// its `clientUUID`; a hit is the strongest outside identity it
        /// carries, in the order `FoodItemService.upsert` matches on, so a
        /// second tap of one result finds the first tap of it.
        ///
        /// An estimate has no outside identity to offer, so it is keyed on its
        /// NAME, normalised exactly the way `commit` matches names. That is one
        /// rule read twice rather than an exception: two estimates that would
        /// collapse into one library row must not sit in the tray as two items,
        /// or the meal counts a cappuccino the library only ever knew once.
        var subjectKey: String {
            switch self {
            case .saved(let uuid):
                return "saved:\(uuid)"
            case .database(let draft):
                return "database:\(draft.externalID ?? draft.barcode ?? draft.displayName)"
            case .estimated(let draft):
                return "estimated:\(FoodItemPick.nameKey(draft.displayName))"
            }
        }
    }

    var origin: Origin

    var entry: MealItemEntry
}

// MARK: - Reading a pick

extension FoodItemPick {

    /// The library row's id, when this pick has one.
    var savedItemUUID: String? {
        if case .saved(let uuid) = origin { return uuid }
        return nil
    }

    /// The draft behind this pick, when it came out of the public database.
    var databaseDraft: FoodItemDraft? {
        if case .database(let draft) = origin { return draft }
        return nil
    }

    /// The draft behind this pick, when the estimator worked it out.
    var estimatedDraft: FoodItemDraft? {
        if case .estimated(let draft) = origin { return draft }
        return nil
    }

    /// What this pick is OF, as one comparable string. See `Origin.subjectKey`.
    var subjectKey: String { origin.subjectKey }

    /// This pick's entry at `quantity`, or nil when nothing can say what that
    /// amount weighs any more.
    ///
    /// `savedRow` is read by a `.saved` pick only, and may be nil when the row
    /// has been deleted since it was picked. A pick that is not saved yet, from
    /// the database or from the estimator, scales off its own draft and needs
    /// nothing from the store. That is what lets a result sit in the tray
    /// unwritten and still answer "what are 200 g of you".
    ///
    /// Both branches end at `MealNutrients.scaled(_:fromBasePortion:to:)`, so
    /// the view never multiplies a nutrient itself and the two origins cannot
    /// drift apart on the arithmetic.
    func entry(at quantity: Double, savedRow: LocalFoodItem?) -> MealItemEntry? {
        switch origin {
        case .saved:
            return savedRow?.mealItem(quantity: quantity)
        case .database(let draft), .estimated(let draft):
            return draft.mealItem(quantity: quantity)
        }
    }

    /// True when this pick can be rescaled with what is in hand.
    func canRescale(savedRow: LocalFoodItem?) -> Bool {
        switch origin {
        case .saved:                return savedRow != nil
        case .database, .estimated: return true
        }
    }
}

// MARK: - Committing (#625)

extension FoodItemPick {

    /// Turn a committed tray into library rows. The ONE place a pick becomes a
    /// saved item.
    ///
    /// ### Why committing is what makes a row his
    ///
    /// The library is supposed to accumulate by use, not by curation: an item
    /// is his because he ate it, and it then ranks up the list. So a tap adds
    /// to the tray and writes nothing, and this runs when the meal is actually
    /// written. A tray the user abandoned leaves no trace, which is the whole
    /// reason a rejected hit never appears in the list he did not want to
    /// maintain.
    ///
    /// ### The three origins, and the two jobs
    ///
    /// - `.database` and `.estimated`: if he already has a row for this thing it
    ///   is REUSED untouched, and only something he has never eaten is written.
    ///   Eating the same packet a second time therefore counts a use and changes
    ///   no number. See `existingRow(for:in:)` for why reusing beats upserting
    ///   here, and for the extra rule an estimate needs to be reusable at all.
    /// - `.saved`: nothing to create. The row is looked up so the counters can
    ///   be moved.
    ///
    /// `countingUse` is the difference between eating and planning. A meal that
    /// was logged bumps `useCount`, so the list orders itself around what he
    /// actually eats. A planned block does not: a week of intentions must not
    /// outrank the thing he has had forty times. The plan still upserts, so the
    /// row exists and is reusable.
    ///
    /// ### Why nothing here throws
    ///
    /// The meal is already the point, and it is either written or about to be.
    /// A row that will not validate, or a saved row deleted between the pick
    /// and the write, costs the ordering of a picker list; failing the caller
    /// over it would cost the record that the user ate. Both are skipped
    /// quietly, the same call `MealComposer` already made about a missing row.
    @discardableResult
    @MainActor
    static func commit(
        _ picks: [FoodItemPick],
        countingUse: Bool,
        using service: FoodItemService? = nil
    ) -> [LocalFoodItem] {
        guard !picks.isEmpty else { return [] }

        // Resolved inside rather than as a default argument: a default is
        // evaluated in the CALLER's context, and `FoodItemService.default()` is
        // main-actor isolated, so a default would have made every call site
        // prove it was on the main actor for a value this function supplies.
        let items = service ?? .default()

        var rows: [LocalFoodItem] = []
        for pick in picks {
            switch pick.origin {
            case .saved(let uuid):
                if let row = (try? items.item(clientUUID: uuid)) ?? nil { rows.append(row) }
            case .database(let draft), .estimated(let draft):
                // One branch for both unsaved origins on purpose: a hit and an
                // estimate differ in where their numbers came from, which the
                // draft already records in `source`, and in nothing this
                // function does. Splitting them would be two copies of the
                // reuse rule waiting to disagree.
                //
                // ── A thing already his is REUSED, never re-imported ────────
                //
                // `upsert` rewrites the name and all eight nutrients of the row
                // it matches. That is right for an explicit re-import and wrong
                // here, because this path now runs every time he eats the
                // thing. Without this lookup, correcting a figure by hand held
                // only until the next time he logged it, and the database's
                // number came back silently. That defeats the whole point of
                // the row becoming his: the database seeds it ONCE, and after
                // that his copy wins.
                //
                // The same rule the merged list draws on screen, drawn again at
                // the moment of writing. `FoodItemSearchMerge.databaseHits`
                // hides a hit he already has, so reaching here with a matching
                // row means the list and the store briefly disagreed, which is
                // exactly when a silent overwrite would happen.
                if let existing = Self.existingRow(for: draft, in: items) {
                    rows.append(existing)
                } else if let row = try? items.upsert(draft.libraryWrite) {
                    rows.append(row)
                }
            }
        }

        if countingUse {
            for row in rows { try? items.recordUse(row) }
        }
        return rows
    }

    /// The row he already has for this product, if any.
    ///
    /// Matches on `externalID` first and `barcode` second, which is the pair
    /// `FoodItemService.upsert` matches on and the pair
    /// `FoodItemSearchMerge.databaseHits` hides on. All three have to agree on
    /// what counts as one product, or the list, the store and this commit each
    /// draw a different conclusion from the same two rows.
    ///
    /// Deliberately includes ARCHIVED rows, which the picker's search does not.
    /// Committing onto a hidden row is odd, and re-importing a second copy of
    /// something he archived is worse: it would put a row he retired back in
    /// the list with none of its history.
    ///
    /// ### The name fallback, and why it is only a fallback
    ///
    /// A draft carrying NEITHER outside identity falls through to a match on
    /// the name. In practice that draft is always an estimate: every Open Food
    /// Facts hit arrives with the product's own id and its barcode, so a
    /// database draft never reaches this line.
    ///
    /// The fallback is not optional, it is what makes the estimate route work
    /// at all. Without it every commit of an estimate inserts, because there is
    /// nothing to match on, so estimating "cappuccino" on Monday and again on
    /// Tuesday leaves two cappuccinos in a list whose entire promise is that
    /// the user never has to tidy it.
    ///
    /// And it would be wrong one line above, on a hit. Two flavours of one bar
    /// share a name constantly, and collapsing them would silently log the
    /// wrong product's figures. The difference is what the name IS: on a
    /// packet it is a shelf label that a manufacturer reuses across a range,
    /// and on an estimate it is the user's own words for one thing he ate.
    /// Matching those words back to the row those same words already made is
    /// the closest thing an estimate has to an identity.
    ///
    /// Archived rows are EXCLUDED here, unlike the two lookups above. Reusing
    /// an archived row would quietly send every future cappuccino into a row he
    /// retired and cannot see, so the item he keeps estimating would never
    /// reappear in his list. A retired name he types again is a new item.
    @MainActor
    private static func existingRow(
        for draft: FoodItemDraft,
        in items: FoodItemService
    ) -> LocalFoodItem? {
        if let externalID = draft.externalID, !externalID.isEmpty,
           let row = (try? items.item(externalID: externalID)) ?? nil {
            return row
        }
        if let barcode = draft.barcode, !barcode.isEmpty,
           let row = (try? items.item(barcode: barcode)) ?? nil {
            return row
        }
        let hasOutsideIdentity = !(draft.externalID ?? "").isEmpty || !(draft.barcode ?? "").isEmpty
        guard !hasOutsideIdentity else { return nil }
        return rowNamed(draft.displayName, in: items)
    }

    /// The non-archived row whose display name is the same words, ignoring case
    /// and surrounding space.
    ///
    /// Reads the picker's own ordering, so the most-eaten row wins a tie. Two
    /// rows can only share a name here if one of them predates this rule or
    /// arrived from a peer, and in that case the one he actually eats is the
    /// one to keep counting.
    @MainActor
    private static func rowNamed(
        _ name: String,
        in items: FoodItemService
    ) -> LocalFoodItem? {
        let key = nameKey(name)
        guard !key.isEmpty else { return nil }
        guard let rows = try? items.allItems() else { return nil }
        return rows.first { nameKey($0.displayName) == key }
    }

    /// One name, reduced to what two names have to share to be the same thing.
    ///
    /// Case and surrounding space only. Nothing clever: an estimate names a
    /// thing in the user's own words, and a normaliser that also stripped
    /// punctuation or plurals would start merging "egg" into "eggs benedict".
    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - One result list out of two sources (#625)

/// How the picker's own items and the public database's hits become one list.
///
/// Kept apart from the view because it is the rule with the edge case in it,
/// and a rule that only exists inside a `body` cannot be tested.
enum FoodItemSearchMerge {

    /// The database hits worth showing beside `local`, in the order they
    /// arrived.
    ///
    /// ### His copy wins
    ///
    /// A hit naming a product he already has is dropped, because the row he has
    /// is the better one: he may have corrected its numbers, its portion is the
    /// one he actually eats, and it carries his use count. Showing both would
    /// put the same yogurt on screen twice with no way to tell which tap keeps
    /// his edits.
    ///
    /// Matching is on `externalID` first and `barcode` second, the same two
    /// outside identities `FoodItemService.upsert` matches on, so what the list
    /// treats as one product and what the store treats as one row cannot
    /// disagree. Names are deliberately NOT compared: two flavours of one bar
    /// share a name often, and hiding a hit over that would make a product
    /// unreachable.
    static func databaseHits(
        _ hits: [FoodItemDraft],
        excluding local: [LocalFoodItem]
    ) -> [FoodItemDraft] {
        var known: Set<String> = []
        for row in local {
            if let id = row.externalID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                known.insert("id:\(id)")
            }
            if let code = row.barcode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
                known.insert("code:\(code)")
            }
        }
        guard !known.isEmpty else { return hits }

        return hits.filter { draft in
            if let id = draft.externalID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !id.isEmpty, known.contains("id:\(id)") {
                return false
            }
            if let code = draft.barcode?.trimmingCharacters(in: .whitespacesAndNewlines),
               !code.isEmpty, known.contains("code:\(code)") {
                return false
            }
            return true
        }
    }
}
