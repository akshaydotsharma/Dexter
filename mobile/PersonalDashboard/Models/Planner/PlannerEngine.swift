import Foundation
import CoreGraphics

// MARK: - Sources

/// The four things a Planner row can be (#687). Each has a hue AND a shape, so a
/// row reads correctly without colour: work and personal are solid tints, a task
/// is an outline with a check circle, a manual block is hatched ink.
enum PlannerSource: String, CaseIterable, Codable, Hashable, Sendable {
    case work
    case personal
    case task
    case manual

    var label: String {
        switch self {
        case .work:     return "Work"
        case .personal: return "Personal"
        case .task:     return "Tasks"
        case .manual:   return "Manual"
        }
    }

    /// The meter key label, which reads better singular for blocks.
    var meterLabel: String {
        switch self {
        case .work:     return "Work"
        case .personal: return "Personal"
        case .task:     return "Tasks"
        case .manual:   return "Blocks"
        }
    }
}

// MARK: - Value snapshots the engine reads

/// A calendar event, copied out of EventKit so the engine never touches it.
struct PlannerEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let location: String
    let calendarID: String
    let calendarTitle: String
    /// `.work` or `.personal`, decided by the calendar's tag.
    let source: PlannerSource
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// The event's notes, for the read-only details sheet (#687 round 3).
    var notes: String = ""
    /// Cross-device key (#689): `calendarItemExternalIdentifier`, or a
    /// device-local fallback. See `PlannerEventOverrides.eventKey`.
    var eventKey: String = ""
    /// `EKEvent.occurrenceDate`: the ORIGINAL start of this occurrence, which
    /// a moved occurrence keeps. Nil means use `start`.
    var occurrenceDate: Date? = nil
    /// True for an occurrence of a repeating event.
    var isRecurring: Bool = false
    /// Declined at the source, declined in Dexter, or neither (#689).
    var decline: PlannerDeclineState = .none
}

/// A `LocalPlanBlock`, as a value.
struct PlannerBlock: Identifiable, Equatable, Sendable {
    let id: String
    let kind: PlanBlockKind
    let title: String
    /// Device-local midnight of the block's day (already projected from the anchor).
    let day: Date
    let start: Date?
    let end: Date?
    let durationMinutes: Int
    let taskUUID: String

    var isTimed: Bool { start != nil && end != nil }
}

/// A `LocalTodo`, as a value.
struct PlannerTask: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let priority: TaskPriority
    let due: Date?
    let completed: Bool
}

// MARK: - Rows

/// One thing shown on a day, whatever it came from.
struct PlannerItem: Identifiable, Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// A calendar event. Read-only, fixed.
        case event(calendarID: String)
        /// A Dexter plan block (`LocalPlanBlock.clientUUID`).
        case block(String)
        /// A task shown because of its due date (not a plan).
        case taskDue
    }

    let id: String
    let title: String
    /// The second line: "Work · Room 4B", "Task · P0", "Dexter block".
    let detail: String
    let source: PlannerSource
    /// Nil for anything in the all-day row.
    let start: Date?
    let end: Date?
    let durationMinutes: Int
    let origin: Origin
    /// The task this row concerns, for task blocks and task-due rows.
    let taskUUID: String?
    let priority: TaskPriority
    /// Days past due, for an overdue task. 0 when not overdue.
    let overdueDays: Int
    let completed: Bool
    /// A declined event (#689): drawn faded and struck through, and left out
    /// of the meter, the overflow, free time and conflicts.
    var isDeclined: Bool = false

    var isFixed: Bool {
        if case .event = origin { return true }
        return false
    }

    var isBlock: Bool {
        if case .block = origin { return true }
        return false
    }

    var blockID: String? {
        if case .block(let id) = origin { return id }
        return nil
    }

    /// True when this row takes time on the day: a timed event or a timed block.
    var occupiesTime: Bool { start != nil && end != nil }

    /// Takes time for the meter, free time and conflicts: occupies time and is
    /// not declined. A declined tile still has a place on the grid.
    var blocksTime: Bool { occupiesTime && !isDeclined }

    /// Counts against the workday: timed rows that occupy time, plus blocks
    /// planned to the day with no hour. All-day calendar events and task due
    /// dates are informational only.
    var countsTowardCapacity: Bool {
        if isDeclined { return false }
        if occupiesTime { return true }
        return isBlock && start == nil
    }
}

/// One day, split the way the Today screen draws it.
struct PlannerDay: Equatable, Sendable {
    let day: Date
    /// All-day events, day-only blocks, dayless tasks due today, overdue tasks.
    let allDay: [PlannerItem]
    /// Everything with an hour, ordered by start.
    let timed: [PlannerItem]

    var all: [PlannerItem] { allDay + timed }
}

/// Two or more timed rows that overlap.
struct ConflictGroup: Equatable, Sendable {
    let items: [PlannerItem]
    /// Minutes covered by at least two of the rows.
    let overlapMinutes: Int
    /// Earliest and latest moment covered by at least two of the rows.
    let overlapStart: Date
    let overlapEnd: Date
}

/// The meter: booked time against the workday, split by source.
struct CapacitySummary: Equatable, Sendable {
    let bookedBySource: [PlannerSource: Int]
    let capacityMinutes: Int
    let isWorkday: Bool

    var bookedMinutes: Int { bookedBySource.values.reduce(0, +) }
    var freeMinutes: Int { max(0, capacityMinutes - bookedMinutes) }
    /// Minutes over the workday. Always 0 on a day that is not a workday, since
    /// a weekend has no capacity to overflow.
    var overflowMinutes: Int { isWorkday ? max(0, bookedMinutes - capacityMinutes) : 0 }
    var isOver: Bool { overflowMinutes > 0 }

    func minutes(_ source: PlannerSource) -> Int { bookedBySource[source] ?? 0 }
}

/// The user's workday, from Settings.
struct WorkdaySettings: Equatable, Sendable {
    /// Minutes after midnight the workday starts. 540 = 9:00.
    var startMinute: Int = 9 * 60
    /// Workday length in minutes. 540 = 9 h.
    var lengthMinutes: Int = 9 * 60
    /// Workday weekdays as `Calendar` weekday numbers (1 = Sunday).
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]

    static let standard = WorkdaySettings()
}

// MARK: - Engine

/// The pure logic behind the Planner (#687): one day's rows, its free gaps, its
/// capacity, its conflicts, and which tasks fit a gap. No SwiftData, no EventKit
/// and no SwiftUI, so every rule here is unit-tested directly.
enum PlannerEngine {

    /// The shortest free gap worth a row. Anything shorter is noise between
    /// back-to-back meetings.
    static let minimumGapMinutes = 15

    /// The length a timed task with no plan block is drawn with.
    static let dueTaskMinutes = 30

    // MARK: Building a day

    /// Every row of one device-local day.
    ///
    /// - Parameters:
    ///   - day: any instant on the day; the device calendar decides which day.
    ///   - now: used for "overdue", which only the current day shows.
    static func day(
        _ day: Date,
        events: [PlannerEvent],
        blocks: [PlannerBlock],
        tasks: [PlannerTask],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PlannerDay {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let isToday = calendar.isDate(dayStart, inSameDayAs: now)
        let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var allDay: [PlannerItem] = []
        var timed: [PlannerItem] = []

        // Calendar events.
        for event in events {
            if event.isAllDay {
                // An all-day event covers [start, end) in whole days.
                guard event.start < dayEnd, event.end > dayStart else { continue }
                allDay.append(PlannerItem(
                    id: "e-\(event.id)", title: event.title,
                    detail: detail(source: event.source, extra: event.location),
                    source: event.source, start: nil, end: nil, durationMinutes: 0,
                    origin: .event(calendarID: event.calendarID), taskUUID: nil,
                    priority: .none, overdueDays: 0, completed: false,
                    isDeclined: event.decline != .none
                ))
            } else {
                guard event.start < dayEnd, event.end > dayStart else { continue }
                let s = max(event.start, dayStart)
                let e = min(event.end, dayEnd)
                timed.append(PlannerItem(
                    id: "e-\(event.id)", title: event.title,
                    detail: detail(source: event.source, extra: event.location),
                    source: event.source, start: s, end: e,
                    durationMinutes: minutes(from: s, to: e),
                    origin: .event(calendarID: event.calendarID), taskUUID: nil,
                    priority: .none, overdueDays: 0, completed: false,
                    isDeclined: event.decline != .none
                ))
            }
        }

        // Plan blocks.
        var plannedTaskIDsToday = Set<String>()
        for block in blocks where calendar.isDate(block.day, inSameDayAs: dayStart) {
            let task = block.taskUUID.isEmpty ? nil : tasksByID[block.taskUUID]
            if block.kind == .task, !block.taskUUID.isEmpty { plannedTaskIDsToday.insert(block.taskUUID) }
            let source: PlannerSource = block.kind == .task ? .task : .manual
            let priority = task?.priority ?? .none
            let title = task?.title ?? block.title
            let detailText: String
            if block.kind == .task {
                var parts = ["Task"]
                if priority != .none { parts.append(priority.label) }
                if !block.isTimed { parts.append("planned, no time") }
                detailText = parts.joined(separator: " · ")
            } else {
                detailText = block.isTimed ? "Dexter block" : "Dexter block · no time"
            }
            let item = PlannerItem(
                id: "b-\(block.id)", title: title, detail: detailText, source: source,
                start: block.start, end: block.end,
                durationMinutes: block.isTimed ? minutes(from: block.start!, to: block.end!) : block.durationMinutes,
                origin: .block(block.id),
                taskUUID: block.taskUUID.isEmpty ? nil : block.taskUUID,
                priority: priority, overdueDays: 0, completed: task?.completed ?? false
            )
            if block.isTimed { timed.append(item) } else { allDay.append(item) }
        }

        // Tasks, by due date. A task already placed on this day shows as its
        // block only.
        for task in tasks where !task.completed {
            guard let due = task.due, !plannedTaskIDsToday.contains(task.id) else { continue }
            let hasHour = TaskDueTime.isSet(on: due, calendar: calendar)
            let dueDay = calendar.startOfDay(for: due)
            if dueDay == dayStart {
                let prio = task.priority == .none ? "" : " · \(task.priority.label)"
                if hasHour {
                    // A timed task with no plan is drawn as an ordinary tile of
                    // `dueTaskMinutes`, starting at its due time (#687 round 2).
                    let end = min(due.addingTimeInterval(TimeInterval(dueTaskMinutes * 60)), dayEnd)
                    timed.append(PlannerItem(
                        id: "d-\(task.id)", title: task.title, detail: "Task\(prio) · due",
                        source: .task, start: due, end: max(end, due),
                        durationMinutes: minutes(from: due, to: max(end, due)),
                        origin: .taskDue, taskUUID: task.id, priority: task.priority,
                        overdueDays: 0, completed: false
                    ))
                } else {
                    allDay.append(PlannerItem(
                        id: "d-\(task.id)", title: task.title, detail: "Task\(prio) · due today",
                        source: .task, start: nil, end: nil, durationMinutes: 0,
                        origin: .taskDue, taskUUID: task.id, priority: task.priority,
                        overdueDays: 0, completed: false
                    ))
                }
            } else if isToday, dueDay < dayStart, TaskDueTime.overdueAfter(due, calendar: calendar) <= now {
                let late = calendar.dateComponents([.day], from: dueDay, to: dayStart).day ?? 1
                allDay.append(PlannerItem(
                    id: "d-\(task.id)", title: task.title,
                    detail: late == 1 ? "1 day overdue" : "\(late) days overdue",
                    source: .task, start: nil, end: nil, durationMinutes: 0,
                    origin: .taskDue, taskUUID: task.id, priority: task.priority,
                    overdueDays: max(1, late), completed: false
                ))
            }
        }

        timed.sort { a, b in
            if a.start! != b.start! { return a.start! < b.start! }
            if a.end! != b.end! { return a.end! > b.end! }
            return a.title < b.title
        }
        allDay.sort { a, b in
            // Calendar events first, then overdue, then the rest.
            func rank(_ i: PlannerItem) -> Int {
                if i.isFixed { return 0 }
                if i.overdueDays > 0 { return 1 }
                return 2
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.overdueDays != b.overdueDays { return a.overdueDays > b.overdueDays }
            return a.title < b.title
        }
        return PlannerDay(day: dayStart, allDay: allDay, timed: timed)
    }

    // MARK: Workday

    /// The workday window on a day.
    static func workdayWindow(on day: Date, settings: WorkdaySettings, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(settings.startMinute * 60))
        return DateInterval(start: start, duration: TimeInterval(settings.lengthMinutes * 60))
    }

    static func isWorkday(_ day: Date, settings: WorkdaySettings, calendar: Calendar = .current) -> Bool {
        settings.weekdays.contains(calendar.component(.weekday, from: day))
    }

    // MARK: Capacity

    /// Booked time against the workday, by source, counting only rows whose
    /// source is visible. That is what makes the meter match the rows shown:
    /// hide Personal and its minutes leave the bar too.
    ///
    /// A timed row counts only the part inside the workday window, so a 7am gym
    /// session does not eat the workday. A block planned to the day with no hour
    /// counts its whole duration.
    static func capacity(
        of day: PlannerDay,
        settings: WorkdaySettings,
        visible: Set<PlannerSource> = Set(PlannerSource.allCases),
        calendar: Calendar = .current
    ) -> CapacitySummary {
        let window = workdayWindow(on: day.day, settings: settings, calendar: calendar)
        var booked: [PlannerSource: Int] = [:]
        for item in day.all where item.countsTowardCapacity && visible.contains(item.source) {
            let mins: Int
            if let s = item.start, let e = item.end {
                let cs = max(s, window.start), ce = min(e, window.end)
                mins = ce > cs ? minutes(from: cs, to: ce) : 0
            } else {
                mins = item.durationMinutes
            }
            guard mins > 0 else { continue }
            booked[item.source, default: 0] += mins
        }
        let workday = isWorkday(day.day, settings: settings, calendar: calendar)
        return CapacitySummary(
            bookedBySource: booked,
            capacityMinutes: workday ? settings.lengthMinutes : 0,
            isWorkday: workday
        )
    }

    // MARK: Free time

    /// Free intervals inside the workday, from the rows that occupy time and
    /// whose source is visible. Past time on the current day is not free: a gap
    /// that spans `now` starts at `now` rounded up to five minutes. No row in
    /// the grid is built from these; they feed the "pick a free slot" chips and
    /// the quick-add "fits" note.
    static func freeTime(
        on day: PlannerDay,
        settings: WorkdaySettings,
        visible: Set<PlannerSource> = Set(PlannerSource.allCases),
        now: Date? = nil,
        calendar: Calendar = .current
    ) -> [DateInterval] {
        guard isWorkday(day.day, settings: settings, calendar: calendar) else { return [] }
        let window = workdayWindow(on: day.day, settings: settings, calendar: calendar)
        let busy = day.timed
            .filter { visible.contains($0.source) && $0.blocksTime }
            .map { DateInterval(start: $0.start!, end: $0.end!) }
        var gaps = freeGaps(in: window, busy: busy)
        if let now, calendar.isDate(now, inSameDayAs: day.day) {
            let floor = roundUp(now, toMinutes: 5, calendar: calendar)
            gaps = gaps.compactMap { g in
                if g.end <= floor { return nil }
                let s = max(g.start, floor)
                return minutes(from: s, to: g.end) >= minimumGapMinutes ? DateInterval(start: s, end: g.end) : nil
            }
        }
        return gaps
    }

    // MARK: Time grid geometry

    /// Where a tile sits in a day column: `y` from the top of the day and its
    /// height, both proportional to time. Every hour is `hourHeight` tall, so a
    /// 30 minute booking is half an hour row. A tile is never shorter than
    /// `minHeight`, which keeps a 15 minute item tappable.
    static func tileGeometry(
        start: Date,
        end: Date,
        dayStart: Date,
        hourHeight: CGFloat,
        minHeight: CGFloat
    ) -> (y: CGFloat, height: CGFloat) {
        let startMin = max(0, start.timeIntervalSince(dayStart) / 60)
        let endMin = min(24 * 60, max(startMin, end.timeIntervalSince(dayStart) / 60))
        let y = CGFloat(startMin) / 60 * hourHeight
        let h = CGFloat(endMin - startMin) / 60 * hourHeight
        return (y, max(minHeight, h))
    }

    /// The instant a point in a day column stands for, snapped DOWN to `snap`
    /// minutes, for a tap on empty grid space.
    static func time(
        atY y: CGFloat,
        dayStart: Date,
        hourHeight: CGFloat,
        snapMinutes: Int = 15
    ) -> Date {
        let raw = max(0, min(24 * 60 - 1, Double(y / hourHeight * 60)))
        let snapped = (raw / Double(snapMinutes)).rounded(.down) * Double(snapMinutes)
        return dayStart.addingTimeInterval(snapped * 60)
    }

    /// A tile's lane inside its overlap cluster.
    struct Lane: Equatable, Sendable {
        let itemID: String
        /// Zero-based column inside the cluster.
        let index: Int
        /// Columns the cluster needs; every tile of a cluster shares it.
        let count: Int
        /// True when the tile overlaps at least one other.
        let inConflict: Bool
    }

    /// Side-by-side lanes for overlapping tiles. Each overlap cluster is laid
    /// out on its own: a tile takes the first lane whose previous tile has
    /// ended, and the cluster's width is split by the number of lanes it needs.
    /// A tile that overlaps nothing gets the full width.
    static func lanes(_ items: [PlannerItem]) -> [Lane] {
        var out: [Lane] = []
        for group in conflictGroups(items) {
            var laneEnds: [Date] = []
            var assigned: [(String, Int)] = []
            for item in group {
                if let idx = laneEnds.firstIndex(where: { $0 <= item.start! }) {
                    laneEnds[idx] = item.end!
                    assigned.append((item.id, idx))
                } else {
                    laneEnds.append(item.end!)
                    assigned.append((item.id, laneEnds.count - 1))
                }
            }
            // A declined tile keeps its lane but is never "in conflict", and
            // does not put another tile in conflict (#689).
            let live = group.filter { !$0.isDeclined }
            let clashing = Set(conflictGroups(live).filter { $0.count > 1 }.flatMap { $0.map(\.id) })
            for (id, idx) in assigned {
                out.append(Lane(itemID: id, index: idx, count: laneEnds.count, inConflict: clashing.contains(id)))
            }
        }
        return out
    }

    /// Free intervals inside `window` not covered by any busy interval, each at
    /// least `minimumGapMinutes` long.
    static func freeGaps(in window: DateInterval, busy: [DateInterval]) -> [DateInterval] {
        let sorted = busy
            .filter { $0.end > window.start && $0.start < window.end }
            .sorted { $0.start < $1.start }
        var gaps: [DateInterval] = []
        var cursor = window.start
        for b in sorted {
            if b.start > cursor {
                let end = min(b.start, window.end)
                if minutes(from: cursor, to: end) >= minimumGapMinutes {
                    gaps.append(DateInterval(start: cursor, end: end))
                }
            }
            cursor = max(cursor, b.end)
            if cursor >= window.end { break }
        }
        if cursor < window.end, minutes(from: cursor, to: window.end) >= minimumGapMinutes {
            gaps.append(DateInterval(start: cursor, end: window.end))
        }
        return gaps
    }

    // MARK: Conflicts

    /// Clusters of rows that overlap in time, each cluster in start order. A
    /// row that overlaps nothing is a cluster of one.
    static func conflictGroups(_ items: [PlannerItem]) -> [[PlannerItem]] {
        let sorted = items.filter(\.occupiesTime).sorted { $0.start! < $1.start! }
        var groups: [[PlannerItem]] = []
        var current: [PlannerItem] = []
        var currentEnd = Date.distantPast
        for item in sorted {
            if !current.isEmpty, item.start! < currentEnd {
                current.append(item)
                currentEnd = max(currentEnd, item.end!)
            } else {
                if !current.isEmpty { groups.append(current) }
                current = [item]
                currentEnd = item.end!
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Every row that overlaps another, for the "N conflicts" count.
    static func conflicts(in day: PlannerDay, visible: Set<PlannerSource> = Set(PlannerSource.allCases)) -> [ConflictGroup] {
        conflictGroups(day.timed.filter { visible.contains($0.source) && !$0.isDeclined })
            .filter { $0.count > 1 }
            .map(makeConflict)
    }

    private static func makeConflict(_ group: [PlannerItem]) -> ConflictGroup {
        // Sweep the boundaries, counting how many rows are open at each moment.
        var edges: [(Date, Int)] = []
        for i in group { edges.append((i.start!, 1)); edges.append((i.end!, -1)) }
        edges.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var open = 0
        var seconds: TimeInterval = 0
        var last: Date?
        var first: Date?
        var lastEnd: Date?
        for (t, delta) in edges {
            if let l = last, open >= 2, t > l {
                seconds += t.timeIntervalSince(l)
                if first == nil { first = l }
                lastEnd = t
            }
            open += delta
            last = t
        }
        let s = first ?? group[0].start!
        return ConflictGroup(
            items: group,
            overlapMinutes: Int((seconds / 60).rounded()),
            overlapStart: s,
            overlapEnd: lastEnd ?? s
        )
    }


    // MARK: Tasks that fit a gap

    /// A task offered by the Fill sheet or the "To plan" list.
    struct Candidate: Identifiable, Equatable, Sendable {
        let task: PlannerTask
        let estimateMinutes: Int
        let overdueDays: Int
        var id: String { task.id }
    }

    /// Open tasks with no plan on or after `today`, ranked the way the Fill
    /// sheet lists them: overdue first (most overdue first), then P0, P1, then
    /// the rest, then by nearest due date, undated last, then title.
    ///
    /// `estimates` supplies a remembered length per task; anything else gets
    /// `defaultEstimate`, since a task carries no duration of its own.
    static func candidates(
        tasks: [PlannerTask],
        blocks: [PlannerBlock],
        today: Date,
        estimates: [String: Int] = [:],
        defaultEstimate: Int = 30,
        calendar: Calendar = .current
    ) -> [Candidate] {
        let todayStart = calendar.startOfDay(for: today)
        let planned = Set(blocks.filter { $0.kind == .task && $0.day >= todayStart }.map(\.taskUUID))
        let open = tasks.filter { !$0.completed && !planned.contains($0.id) }
        let ranked = open.map { task -> Candidate in
            var late = 0
            if let due = task.due, TaskDueTime.overdueAfter(due, calendar: calendar) <= today {
                late = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: due), to: todayStart).day ?? 1)
            }
            return Candidate(task: task, estimateMinutes: estimates[task.id] ?? defaultEstimate, overdueDays: late)
        }
        return ranked.sorted(by: rankOrder)
    }

    static func rankOrder(_ a: Candidate, _ b: Candidate) -> Bool {
        let aLate = a.overdueDays > 0, bLate = b.overdueDays > 0
        if aLate != bLate { return aLate }
        if aLate && a.overdueDays != b.overdueDays { return a.overdueDays > b.overdueDays }
        if a.task.priority.sortRank != b.task.priority.sortRank {
            return a.task.priority.sortRank < b.task.priority.sortRank
        }
        switch (a.task.due, b.task.due) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        return a.task.title.localizedCaseInsensitiveCompare(b.task.title) == .orderedAscending
    }

    /// The Fill sheet's list: the tasks that fit a gap of `gapMinutes`, in rank
    /// order. A task longer than the gap is never offered.
    static func fitting(_ candidates: [Candidate], gapMinutes: Int) -> [Candidate] {
        candidates.filter { $0.estimateMinutes <= gapMinutes }
    }

    /// Which of the fitting tasks start switched on: walk them in rank order and
    /// take each one while it still fits what is left of the gap.
    static func defaultSelection(_ fitting: [Candidate], gapMinutes: Int) -> Set<String> {
        var left = gapMinutes
        var picked = Set<String>()
        for c in fitting where c.estimateMinutes <= left {
            picked.insert(c.id)
            left -= c.estimateMinutes
        }
        return picked
    }

    /// Back-to-back slots for the chosen tasks, in rank order, from the gap's
    /// start. Stops at the first one that would run past the gap's end.
    static func placements(
        for chosen: [Candidate],
        in gap: DateInterval
    ) -> [(candidate: Candidate, start: Date, end: Date)] {
        var out: [(Candidate, Date, Date)] = []
        var cursor = gap.start
        for c in chosen {
            let end = cursor.addingTimeInterval(TimeInterval(c.estimateMinutes * 60))
            guard end <= gap.end else { break }
            out.append((c, cursor, end))
            cursor = end
        }
        return out.map { (candidate: $0.0, start: $0.1, end: $0.2) }
    }

    // MARK: Moving work off an overloaded day

    /// The first later day, within `horizon` days, that is a workday with at
    /// least `minutes` free. Nil when none does.
    static func nearestDayWithRoom(
        after day: Date,
        minutes: Int,
        freeMinutes: (Date) -> Int,
        settings: WorkdaySettings,
        horizon: Int = 7,
        calendar: Calendar = .current
    ) -> Date? {
        let start = calendar.startOfDay(for: day)
        for offset in 1...max(1, horizon) {
            guard let d = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            guard isWorkday(d, settings: settings, calendar: calendar) else { continue }
            if freeMinutes(d) >= minutes { return d }
        }
        return nil
    }

    /// Free slots on a day long enough for `minutes`, for the "pick a free
    /// slot" chips.
    static func slots(
        on day: PlannerDay,
        minutes: Int,
        settings: WorkdaySettings,
        now: Date? = nil,
        calendar: Calendar = .current
    ) -> [DateInterval] {
        freeTime(on: day, settings: settings, now: now, calendar: calendar).compactMap { g in
            g.duration >= TimeInterval(minutes * 60) ? DateInterval(start: g.start, duration: TimeInterval(minutes * 60)) : nil
        }
    }

    // MARK: Helpers

    static func minutes(from start: Date, to end: Date) -> Int {
        Int((end.timeIntervalSince(start) / 60).rounded())
    }

    static func roundUp(_ date: Date, toMinutes step: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let unit = TimeInterval(step * 60)
        let secs = date.timeIntervalSince(start)
        return start.addingTimeInterval((secs / unit).rounded(.up) * unit)
    }

    private static func detail(source: PlannerSource, extra: String) -> String {
        let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? source.label : "\(source.label) · \(trimmed)"
    }
}

// MARK: - Formatting

enum PlannerFormat {
    /// "2h 30m", "45m", "3h".
    static func duration(_ minutes: Int) -> String {
        let m = max(0, minutes)
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r)m" }
        if r == 0 { return "\(h)h" }
        return "\(h)h \(r)m"
    }
}
