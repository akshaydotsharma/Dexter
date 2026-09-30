import Foundation
import EventKit
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One EventKit calendar as the Planner shows it in Settings (#687).
struct PlannerCalendar: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let accountTitle: String
    /// `.work` or `.personal`: the user's tag, or the default guess.
    let tag: PlannerSource
    let isShown: Bool
}

/// Read-only calendar access for the Planner (#687), shared by iOS and macOS.
///
/// Reads every calendar the user has added to Apple Calendar through EventKit.
/// It never writes: no event is created, edited or deleted, and no Dexter block
/// is ever copied to a calendar. That is why it asks for full READ access and
/// nothing else.
///
/// `revision` bumps whenever the calendar database changes
/// (`EKEventStoreChanged`), which is what makes a view re-read its events: an
/// event added in Calendar on the phone shows up in the Planner without a
/// relaunch.
@MainActor
@Observable
final class PlannerCalendarService {
    static let shared = PlannerCalendarService()

    enum Access: Equatable {
        case notDetermined
        case granted
        case denied
        case restricted
        /// Write-only access, which cannot read events.
        case writeOnly
    }

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?

    private(set) var access: Access
    private(set) var calendars: [PlannerCalendar] = []
    private(set) var revision: Int = 0
    /// True while the one-time permission prompt is on screen.
    private(set) var isRequesting = false
    /// True when a request came back refused while the status is still
    /// `notDetermined`: macOS answered for the app WITHOUT showing a prompt.
    ///
    /// Measured on #687 round 2. A build launched from a terminal inherits the
    /// terminal as its TCC "responsible process", and tccd judges the prompt
    /// against THAT process's entitlements. With cmux as the parent the log
    /// reads "Prompting policy for hardened runtime; service: kTCCServiceCalendar
    /// requires entitlement com.apple.security.personal-information.calendars
    /// but it is missing for responsible=com.cmuxterm.app", EventKit returns
    /// "Access request result: 2" in about 20 ms, and nothing is shown. The UI
    /// uses this flag to say so and to offer System Settings instead.
    private(set) var promptDidNotAppear = false

    private init() {
        access = Self.readAccess()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        }
        if access == .granted { reloadCalendars() }
    }

    private static func readAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .fullAccess:    return .granted
        case .writeOnly:     return .writeOnly
        case .denied:        return .denied
        case .restricted:    return .restricted
        @unknown default:
            // `.authorized` (pre-17) is deprecated; treat anything unknown as a
            // grant only if a read actually works, which `events` will show.
            return .granted
        }
    }

    /// Ask once. The system shows its prompt only while the status is
    /// `notDetermined`; after that it answers without asking, so calling this
    /// on every appearance is safe and prompts exactly one time.
    func requestAccessIfNeeded() async {
        access = Self.readAccess()
        guard access == .notDetermined, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        do {
            let granted = try await store.requestFullAccessToEvents()
            NSLog("PlannerCalendar: requestFullAccessToEvents returned %@", granted ? "granted" : "refused")
        } catch {
            NSLog("PlannerCalendar: requestFullAccessToEvents threw %@", String(describing: error))
        }
        access = Self.readAccess()
        NSLog("PlannerCalendar: authorizationStatus after request = %ld", EKEventStore.authorizationStatus(for: .event).rawValue)
        // Refused while still undetermined: the system never showed a prompt.
        promptDidNotAppear = access == .notDetermined
        if access == .granted {
            store.reset()
            reloadCalendars()
        }
        revision &+= 1
    }

    /// The access card's button. It asks, and when the system gives no prompt
    /// (see `promptDidNotAppear`) it opens Privacy & Security > Calendars on
    /// the Mac, so a click always does something visible.
    func requestAccessFromButton() async {
        await requestAccessIfNeeded()
        if access == .notDetermined || access == .denied || access == .writeOnly {
            promptDidNotAppear = access == .notDetermined
            Self.openSystemSettings()
        }
    }

    /// Re-read the status, for when the user comes back from Settings.
    func refreshAccess() {
        let before = access
        access = Self.readAccess()
        if access != before {
            if access == .granted { store.reset(); reloadCalendars() }
            revision &+= 1
        }
    }

    private func storeChanged() {
        access = Self.readAccess()
        if access == .granted { reloadCalendars() }
        revision &+= 1
    }

    func reloadCalendars() {
        guard access == .granted else { calendars = []; return }
        let tags = PlannerSettings.calendarTags
        let hidden = PlannerSettings.hiddenCalendars
        calendars = store.calendars(for: .event)
            .map { cal in
                PlannerCalendar(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    accountTitle: cal.source?.title ?? "",
                    tag: tags[cal.calendarIdentifier] ?? Self.defaultTag(for: cal),
                    isShown: !hidden.contains(cal.calendarIdentifier)
                )
            }
            .sorted { ($0.accountTitle, $0.title) < ($1.accountTitle, $1.title) }
    }

    private static func defaultTag(for cal: EKCalendar) -> PlannerSource {
        PlannerCalendarTagging.defaultTag(
            sourceTitle: cal.source?.title ?? "",
            calendarTitle: cal.title,
            isExchange: cal.source?.sourceType == .exchange
        )
    }

    // MARK: Settings writes

    func setTag(_ tag: PlannerSource, for calendarID: String) {
        var tags = PlannerSettings.calendarTags
        tags[calendarID] = tag
        PlannerSettings.calendarTags = tags
        reloadCalendars()
        revision &+= 1
    }

    func setShown(_ shown: Bool, for calendarID: String) {
        var hidden = PlannerSettings.hiddenCalendars
        if shown { hidden.remove(calendarID) } else { hidden.insert(calendarID) }
        PlannerSettings.hiddenCalendars = hidden
        reloadCalendars()
        revision &+= 1
    }

    // MARK: Reads

    /// Every event on a shown calendar that overlaps `[start, end)`, as values.
    func events(from start: Date, to end: Date) -> [PlannerEvent] {
        guard access == .granted else { return [] }
        let byID = Dictionary(calendars.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let shown = store.calendars(for: .event).filter { byID[$0.calendarIdentifier]?.isShown ?? true }
        guard !shown.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: shown)
        return store.events(matching: predicate).compactMap { ev in
            guard let s = ev.startDate, let e = ev.endDate else { return nil }
            let calID = ev.calendar.calendarIdentifier
            let tag = byID[calID]?.tag ?? Self.defaultTag(for: ev.calendar)
            // A recurring event shares one identifier across occurrences, so the
            // start makes the row id unique.
            let id = "\(ev.eventIdentifier ?? UUID().uuidString)@\(Int(s.timeIntervalSince1970))"
            return PlannerEvent(
                id: id,
                title: (ev.title ?? "").isEmpty ? "Busy" : ev.title,
                location: ev.location ?? "",
                calendarID: calID,
                calendarTitle: ev.calendar.title,
                source: tag == .work ? .work : .personal,
                start: s,
                end: max(e, s),
                isAllDay: ev.isAllDay,
                notes: ev.notes ?? "",
                eventKey: PlannerEventOverrides.eventKey(
                    externalID: ev.calendarItemExternalIdentifier,
                    localID: ev.eventIdentifier
                ),
                occurrenceDate: ev.occurrenceDate,
                isRecurring: ev.hasRecurrenceRules || ev.isDetached,
                decline: Self.declinedAtSource(ev) ? .atSource : .none
            )
        }
    }

    /// True when MY attendee status on the event is Declined, in whatever
    /// calendar app I answered it (#689). EventKit exposes the current user's
    /// attendee record with `isCurrentUser`.
    static func declinedAtSource(_ ev: EKEvent) -> Bool {
        ev.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    // MARK: Settings deep link

    /// Opens the place where the user can turn calendar access back on.
    static func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
