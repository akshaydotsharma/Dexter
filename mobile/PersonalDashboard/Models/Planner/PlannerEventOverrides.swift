import Foundation

/// One Dexter decision about calendar events, as a value (#689).
struct EventOverrideRule: Equatable, Sendable {
    let id: String
    let eventKey: String
    /// Nil: every occurrence (or the one non-repeating event).
    let occurrenceStart: Date?
    let action: EventOverrideAction

    func matches(_ event: PlannerEvent) -> Bool {
        guard !eventKey.isEmpty, eventKey == event.eventKey else { return false }
        guard let occ = occurrenceStart else { return true }
        return abs(occ.timeIntervalSince(event.occurrenceDate ?? event.start)) < 1
    }
}

/// How an event is declined, if it is.
enum PlannerDeclineState: String, Equatable, Sendable {
    case none
    /// My own attendee status in the source calendar is Declined.
    case atSource
    /// Declined in Dexter only (#689).
    case inDexter
}

/// The ONE gate every calendar event passes on its way into the engine (#689).
///
/// `PlannerContext` calls this in its only initialiser, so no view, meter,
/// week board or conflict check can see an event without its overrides applied
/// (the lesson of `project_wallet_union_needs_per_source_gate`).
///
/// Rules:
/// - A `hidden` rule removes the event.
/// - A `declined` rule marks it declined in Dexter.
/// - Hidden wins over declined.
/// - An event declined at the source stays declined whatever Dexter says; an
///   Undo in Dexter cannot un-decline what the calendar says.
enum PlannerEventOverrides {
    static func apply(_ events: [PlannerEvent], rules: [EventOverrideRule]) -> [PlannerEvent] {
        guard !rules.isEmpty else { return events }
        let hidden = rules.filter { $0.action == .hidden }
        let declined = rules.filter { $0.action == .declined }
        return events.compactMap { ev in
            if hidden.contains(where: { $0.matches(ev) }) { return nil }
            var out = ev
            if out.decline == .none, declined.contains(where: { $0.matches(ev) }) {
                out.decline = .inDexter
            }
            return out
        }
    }

    /// The rules that touch one event, for the details sheet.
    static func rules(for event: PlannerEvent, in rules: [EventOverrideRule]) -> [EventOverrideRule] {
        rules.filter { $0.matches(event) }
    }

    /// The key for an EventKit event: the cross-device external id, or a
    /// device-local fallback when the calendar gives none.
    ///
    /// A MOVED occurrence (EventKit calls it detached) does not share the
    /// series' external id: EventKit appends the recurrence id, so it reads
    /// `<UID>/RID=<seconds>`. Measured on #689: a daily series had
    /// `6104BF1C-…` on every occurrence except the one moved an hour, which had
    /// `6104BF1C-…/RID=812536200`. Keyed raw, "hide the whole series" would
    /// miss the moved occurrence and it would come back. So the suffix is cut,
    /// and the occurrence is told apart by `occurrenceDate` instead, which a
    /// moved occurrence keeps at its original start.
    static func eventKey(externalID: String?, localID: String?) -> String {
        if let ext = externalID?.trimmingCharacters(in: .whitespacesAndNewlines), !ext.isEmpty {
            return seriesKey(ext)
        }
        if let local = localID?.trimmingCharacters(in: .whitespacesAndNewlines), !local.isEmpty {
            return "local:" + seriesKey(local)
        }
        return ""
    }

    /// `<UID>/RID=<n>` becomes `<UID>`; anything else is unchanged.
    static func seriesKey(_ id: String) -> String {
        guard let r = id.range(of: "/RID=") else { return id }
        return String(id[..<r.lowerBound])
    }
}
