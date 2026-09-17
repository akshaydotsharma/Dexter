import Foundation

/// One meal type's blocks on one day, in the order they should be shown (#599).
///
/// A slot exists for all four types whether or not anything is planned in it,
/// because the day panel's job is to be filled in: an empty Lunch has to be
/// visible to be tapped. `isEmpty` is what the panel branches on, not the
/// presence of the slot.
struct MealPlanSlot: Identifiable, Equatable {
    let mealType: MealType
    /// Blocks in this slot, ordered by `slotIndex`. Several, for a day with
    /// three snacks.
    let entries: [LocalMealPlanEntry]

    var id: String { mealType.rawValue }

    var isEmpty: Bool { entries.isEmpty }

    /// Blocks in this slot that still count. See `MealPlanStatus.countsTowardsPlan`.
    var counted: [LocalMealPlanEntry] { entries.filter(\.countsTowardsPlan) }

    static func == (lhs: MealPlanSlot, rhs: MealPlanSlot) -> Bool {
        lhs.mealType == rhs.mealType
            && lhs.entries.map(\.clientUUID) == rhs.entries.map(\.clientUUID)
    }
}

/// One day of planned meals, grouped and totalled (#599).
///
/// The plan-side twin of `MealDaySummary`, and it draws its exclusions the same
/// way and for the same reason: one type decides what counts, so no two
/// surfaces can disagree about a day. A day panel that filtered and summed on
/// its own, beside a calendar cell that filtered and summed on its own, is
/// exactly how one day ends up with two numbers.
///
/// ### What is left out of a total, and why
///
/// A skipped block is excluded from the totals, from the verdicts and from the
/// ingredient roll-up. A meal you have decided not to eat brings no calories
/// and needs no shopping, so counting it would make the day look heavier than
/// it is and the list longer than it needs to be.
///
/// A block with no numbers is a different absence and is handled differently.
/// It is not excluded; it is COUNTED as unknown. `blocksWithoutNutrition` is
/// what the panel prints beside the total, because "1,850 kcal planned" is a
/// lie if two of the five blocks have no figures at all, and silence about it
/// is the kind of wrong that never looks wrong.
struct MealPlanDay {

    /// The day these blocks are planned for, as a DEVICE-local midnight.
    let day: Date

    /// Every block on the day, in reading order: meal type, then slot index.
    let all: [LocalMealPlanEntry]

    /// Blocks that still count. Skipped ones are not here.
    let counted: [LocalMealPlanEntry]

    /// Blocks the user has skipped. Still shown, struck through, at the foot of
    /// their own slot.
    let skipped: [LocalMealPlanEntry]

    /// Sum over the counted blocks that carry numbers. Blocks without numbers
    /// contribute nothing and are reported separately.
    let totals: MealNutrients

    /// How many counted blocks had numbers to add.
    let blocksWithNutrition: Int

    /// How many counted blocks had none. The reason `totals` must never be
    /// printed on its own.
    let blocksWithoutNutrition: Int

    /// Nothing at all is planned for this day.
    ///
    /// Distinct from a day whose blocks are all skipped: that day was planned
    /// and then abandoned, and the panel says so rather than offering a blank
    /// slate.
    var isEmpty: Bool { all.isEmpty }

    /// True when `totals` describes every counted block on the day. False the
    /// moment one block has no numbers, which is when the figure needs its
    /// caveat.
    var totalsAreComplete: Bool { blocksWithoutNutrition == 0 }

    init(day: Date, entries: [LocalMealPlanEntry]) {
        self.day = day
        let ordered = Self.order(entries)
        self.all = ordered

        var counted: [LocalMealPlanEntry] = []
        var skipped: [LocalMealPlanEntry] = []
        for entry in ordered {
            if entry.countsTowardsPlan {
                counted.append(entry)
            } else {
                skipped.append(entry)
            }
        }
        self.counted = counted
        self.skipped = skipped

        var totals = MealNutrients.zero
        var withNumbers = 0
        var withoutNumbers = 0
        for entry in counted {
            if let nutrients = entry.plannedNutrients {
                totals = totals + nutrients
                withNumbers += 1
            } else {
                withoutNumbers += 1
            }
        }
        self.totals = totals
        self.blocksWithNutrition = withNumbers
        self.blocksWithoutNutrition = withoutNumbers
    }

    /// The four slots, in the order of an actual day, each holding its blocks.
    ///
    /// Always four, always in `MealType.allCases` order, so the panel renders
    /// the same skeleton on an empty day as on a full one and nothing below the
    /// fold moves as blocks are added.
    var slots: [MealPlanSlot] {
        MealType.allCases.map { type in
            MealPlanSlot(
                mealType: type,
                entries: all.filter { $0.mealTypeEnum == type }
            )
        }
    }

    /// Blocks of one meal type, ordered by `slotIndex`.
    func entries(for mealType: MealType) -> [LocalMealPlanEntry] {
        all.filter { $0.mealTypeEnum == mealType }
    }

    /// The index a NEW block of this meal type should take, which is one past
    /// the highest already there.
    ///
    /// One past the MAXIMUM rather than the count, so a day whose middle snack
    /// was deleted before the service renormalised still appends rather than
    /// colliding with the block that is already sitting at that index.
    func nextSlotIndex(for mealType: MealType) -> Int {
        (entries(for: mealType).map(\.slotIndex).max() ?? -1) + 1
    }

    /// Reading order for a day: meal type in serving order, then slot index,
    /// then creation time as the tie-break.
    ///
    /// The tie-break matters. Two blocks that somehow share an index — a
    /// restore, a peer write, a build that predates the renormalisation — would
    /// otherwise come back in whatever order the fetch produced, so the list
    /// would reshuffle between two renders and a tap would land on a different
    /// block than the one under the finger.
    static func order(_ entries: [LocalMealPlanEntry]) -> [LocalMealPlanEntry] {
        let rank = Dictionary(
            uniqueKeysWithValues: MealType.allCases.enumerated().map { ($1, $0) }
        )
        return entries.sorted { lhs, rhs in
            let lhsRank = rank[lhs.mealTypeEnum] ?? MealType.allCases.count
            let rhsRank = rank[rhs.mealTypeEnum] ?? MealType.allCases.count
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.slotIndex != rhs.slotIndex { return lhs.slotIndex < rhs.slotIndex }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.clientUUID < rhs.clientUUID
        }
    }

    /// The plan for one device-local day, selected out of every block held.
    ///
    /// The ONE place a day is picked out of a list of blocks, for the reason
    /// `MealDaySummary.onDay` is: two surfaces running two filters is how one
    /// day gets two answers. Matching goes through `WallClock.isSameStoredDay`,
    /// so a stored UTC anchor is compared as a day and never as an instant
    /// (#506).
    static func onDay(_ day: Date, in entries: [LocalMealPlanEntry]) -> MealPlanDay {
        let anchor = WallClock.dayAnchor(from: day)
        return MealPlanDay(
            day: Calendar.current.startOfDay(for: day),
            entries: entries.filter { WallClock.isSameStoredDay($0.date, anchor) }
        )
    }
}

// MARK: - What a calendar cell says

/// What one plan-calendar cell has to say about its day (#599).
///
/// Counts rather than a total, because the question a plan grid answers is
/// "have I filled this day in", not "how heavy is it". A calorie figure would
/// be blank on most cells anyway: a hand-typed block carries no numbers, and
/// printing a partial total in a square too small to caveat it would state
/// something false in the one place there is no room to correct it.
struct MealPlanReading: Equatable, Sendable {
    /// Blocks that still count, of any state but skipped.
    let counted: Int
    /// Blocks the user skipped.
    let skipped: Int
    /// Counted blocks already ticked as eaten.
    let eaten: Int
    /// Which meal types have at least one counted block. Drives the four pips
    /// on a cell, so "dinner is still empty" is visible without opening the day.
    let coveredTypes: Set<MealType>

    static let none = MealPlanReading(counted: 0, skipped: 0, eaten: 0, coveredTypes: [])

    /// Nothing at all was written down for this day. A day of nothing but
    /// skipped blocks is NOT empty — it was planned and then abandoned, which
    /// is a different thing to look at.
    var isEmpty: Bool { counted == 0 && skipped == 0 }

    /// Every meal type has something counted in it.
    var isComplete: Bool { coveredTypes.count == MealType.allCases.count }

    /// What a day's plan reads as, in words (#599, moved here in #605).
    ///
    /// Says which meals are MISSING rather than which are present, once the day
    /// has anything on it at all. That is the actionable half: a user checking a
    /// plan by ear is looking for the gap, and "breakfast, lunch and dinner
    /// planned" makes them work out the fourth themselves.
    ///
    /// It lived on the pips view until the Plan tab took the app's shared
    /// calendar, which draws no pips. The sentence was never about the pips: it
    /// is what this reading SAYS, so it belongs on the reading, where the
    /// calendar's `spokenDetail` can reach it without a view in between.
    var spokenSummary: String {
        if isEmpty { return "nothing planned" }
        if counted == 0 {
            return "\(skipped) skipped, nothing else planned"
        }

        var parts: [String] = []
        if isComplete {
            parts.append("all four meals planned")
        } else {
            let missing = MealType.allCases
                .filter { !coveredTypes.contains($0) }
                .map { $0.displayName.lowercased() }
            parts.append("\(counted) planned, no \(missing.joined(separator: " or "))")
        }
        if eaten > 0 { parts.append("\(eaten) eaten") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: ", ")
    }
}

extension MealPlanDay {

    /// This day's cell reading.
    var reading: MealPlanReading {
        MealPlanReading(
            counted: counted.count,
            skipped: skipped.count,
            eaten: counted.filter { $0.statusEnum == .eaten }.count,
            coveredTypes: Set(counted.map(\.mealTypeEnum))
        )
    }

    /// Every planned day in the store, read once, keyed by its stored day
    /// anchor.
    ///
    /// Built in ONE pass rather than by asking `onDay` per square, which would
    /// re-scan the whole table forty-two times a month — the per-row cost that
    /// froze Finance in #442. `MealCalendar.readings(in:)` is the same move for
    /// logged meals.
    ///
    /// A day absent from the result reads as `.none`; see ``reading(for:in:)``.
    static func readings(in entries: [LocalMealPlanEntry]) -> [Date: MealPlanReading] {
        var byDay: [Date: [LocalMealPlanEntry]] = [:]
        for entry in entries {
            byDay[WallClock.startOfStoredDay(entry.date), default: []].append(entry)
        }
        return byDay.mapValues { rows in
            MealPlanDay(day: WallClock.deviceDay(from: rows[0].date), entries: rows).reading
        }
    }

    /// The reading for one device-local day out of a table built by
    /// ``readings(in:)``.
    static func reading(for day: Date, in readings: [Date: MealPlanReading]) -> MealPlanReading {
        readings[WallClock.dayAnchor(from: day)] ?? .none
    }
}

// MARK: - The ingredients a stretch of plan needs

/// One ingredient a range of planned days asks for (#599).
///
/// `name` is the spelling to print and `blocks` is how many blocks want it.
/// The count is the whole reason this is a struct rather than a `[String]`:
/// "chicken thigh, in four meals" is a shopping decision and "chicken thigh"
/// on its own is not.
struct MealPlanIngredient: Identifiable, Equatable, Hashable, Sendable {
    /// The display spelling: the most common form the user actually typed.
    let name: String
    /// How many counted blocks name this ingredient.
    let blocks: Int

    var id: String { name.lowercased() }
}

extension MealPlanDay {

    /// The main ingredients a set of blocks asks for, most-wanted first (#599).
    ///
    /// ### It is deliberately not a shopping list
    ///
    /// The user asked for the main ingredients, roughly, and not the whole
    /// list. So there are no quantities, no units and no aisle: those are the
    /// three things that turn a glanceable strip into a document you have to
    /// maintain, and none of them is knowable from a block that says "chicken
    /// rice" anyway. A number beside a name is a count of MEALS, never a
    /// quantity of food, which is why the label says "in 4 meals".
    ///
    /// ### Matching
    ///
    /// Grouping is case- and whitespace-insensitive, so "Chicken thigh" and
    /// "chicken thigh " are one line. Nothing stronger than that: stemming
    /// would fold "egg" into "eggplant" and there is no dictionary here to stop
    /// it.
    ///
    /// The printed spelling is whichever form occurs most often, and a tie goes
    /// to the one written FIRST, so the list reads back in the user's own words.
    /// That tie-break matters more than it looks: alphabetical order would mean
    /// an early capital wins, so typing "Chicken thigh" once on Friday would
    /// silently restyle the "chicken thigh" the user has been typing all week.
    /// First-seen is also the rule `MealPlanService.cleaned` already applies
    /// within one block, so a name cannot change case by moving between the two.
    ///
    /// Skipped blocks are excluded, because a meal that is not happening needs
    /// no shopping.
    static func ingredients(in entries: [LocalMealPlanEntry]) -> [MealPlanIngredient] {
        /// Per normalised key: how many BLOCKS wanted it, and how often each
        /// spelling was used.
        var blockCount: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        var firstSeen: [String: Int] = [:]
        /// Per exact SPELLING, when it was first written. Separate from
        /// `firstSeen`, which is per normalised key: one orders the lines, this
        /// one orders the forms competing to label a single line.
        var firstSpelling: [String: Int] = [:]
        var order = 0

        for entry in entries where entry.countsTowardsPlan {
            // A block that names the same ingredient twice still wants it once,
            // so the per-block set is taken before the tally.
            var seenInThisBlock: Set<String> = []
            for raw in entry.ingredients {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                spellings[key, default: [:]][trimmed, default: 0] += 1
                if firstSpelling[trimmed] == nil {
                    firstSpelling[trimmed] = order
                    order += 1
                }
                if firstSeen[key] == nil {
                    firstSeen[key] = order
                    order += 1
                }
                guard !seenInThisBlock.contains(key) else { continue }
                seenInThisBlock.insert(key)
                blockCount[key, default: 0] += 1
            }
        }

        return blockCount.keys.map { key -> MealPlanIngredient in
            let forms = spellings[key] ?? [:]
            // Most-used spelling, first-written breaking a tie. Never
            // dictionary order, which is not stable across launches at all.
            let name = forms.sorted {
                $0.value != $1.value
                    ? $0.value > $1.value
                    : (firstSpelling[$0.key] ?? 0) < (firstSpelling[$1.key] ?? 0)
            }.first?.key ?? key
            return MealPlanIngredient(name: name, blocks: blockCount[key] ?? 0)
        }
        .sorted {
            if $0.blocks != $1.blocks { return $0.blocks > $1.blocks }
            return (firstSeen[$0.id] ?? 0) < (firstSeen[$1.id] ?? 0)
        }
    }
}
