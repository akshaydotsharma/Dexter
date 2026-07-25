import Foundation
import SwiftData

/// SwiftData container singleton.
///
/// The store backs the iOS local-first data layer (#14). It holds
/// `LocalTodo`, `LocalNote`, `LocalList`, `LocalNoteFolder`, `LocalKeyword`,
/// `LocalTrip`, and `LocalItineraryItem`.
/// SwiftData persists to the app's Application Support directory by default,
/// which survives cache eviction unlike the legacy JSON cache.
///
/// Access the shared `ModelContext` via `SwiftDataStore.shared.context`.
/// Services and view models inject this context; tests can substitute an
/// in-memory container via `SwiftDataStore.makeInMemory()`.
@MainActor
final class SwiftDataStore {
    static let shared = SwiftDataStore()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// True when `DEXTER_STORE_PATH` redirected this process away from the
    /// user's real store (#318). Surfaces so the UI can say so out loud: a
    /// disposable store looks exactly like a wiped one, and a tester who
    /// forgets the override is active will read an empty app as data loss.
    /// Always false in release builds, where the override is inert.
    private(set) static var isUsingOverrideStore = false

    /// Resolve the SQLite URL, honouring the `DEXTER_STORE_PATH` override.
    ///
    /// The override exists so automated verification (notably the #319 backup
    /// round trip, which by design destroys and rebuilds a store) can run
    /// against a disposable copy instead of the user's real financial data.
    /// Debug-only and env-only: never a persisted setting, so a stale value
    /// cannot outlive the run that set it.
    ///
    /// On any problem this **refuses to launch** rather than falling back to the
    /// default path. That looks harsh but it is the only safe behaviour: a
    /// silent fallback would send a run that asked for a throwaway store
    /// straight at the live one, which is precisely the accident the override
    /// is meant to prevent. Failing to launch touches nobody's data.
    private static func resolveStoreURL(default defaultURL: URL) -> URL {
        #if DEBUG
        // Reuses AppConfig's placeholder guard (#308) rather than writing a
        // second one: an unexpanded `${DEXTER_STORE_PATH}` is a non-empty
        // string and would otherwise be taken for a real path.
        guard let raw = AppConfig.resolved(ProcessInfo.processInfo.environment["DEXTER_STORE_PATH"]) else {
            return defaultURL
        }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        // Require an existing parent directory. Without this check a typo'd
        // path yields a brand-new empty store, the app opens with no data, and
        // the obvious conclusion is that the data is gone.
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            fatalError(
                """
                DEXTER_STORE_PATH is set to \(url.path) but its parent directory \
                does not exist. Refusing to launch rather than creating an empty \
                store, and refusing to fall back to the real store so this run \
                cannot touch live data. Create the directory or unset the variable.
                """
            )
        }
        guard url.pathExtension.lowercased() == "sqlite" else {
            fatalError(
                """
                DEXTER_STORE_PATH must end in .sqlite (got \(url.lastPathComponent)). \
                SwiftData writes -wal and -shm siblings alongside it, so the \
                extension is load-bearing for copying a store correctly.
                """
            )
        }
        NSLog("SwiftDataStore: using OVERRIDE store at %@ (DEXTER_STORE_PATH)", url.path)
        return url
        #else
        // Release builds ignore the variable entirely.
        return defaultURL
        #endif
    }

    private init() {
        do {
            let schema = Schema([
                LocalTodo.self,
                LocalNoteFolder.self,
                LocalNote.self,
                LocalList.self,
                LocalKeyword.self,
                LocalTrip.self,
                LocalItineraryItem.self,
                LocalExpense.self,
                RecurringExpense.self,
                LocalPerson.self,
                LocalEvent.self,
                LocalFXRate.self,
                LocalProcessedEmail.self,
                LocalEmailIngestLog.self,
                LocalStatementImport.self,
            ])
            // SwiftData defaults the store URL to Application Support, but
            // on a fresh simulator that directory doesn't exist yet and
            // CoreData logs a noisy stat failure on first run. Pre-creating
            // the directory and pointing the configuration at an explicit
            // URL avoids both problems.
            let supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let defaultURL = supportDir.appendingPathComponent("PersonalDashboard.sqlite")
            let storeURL = Self.resolveStoreURL(default: defaultURL)
            Self.isUsingOverrideStore = (storeURL != defaultURL)
            let configuration = ModelConfiguration(
                schema: schema,
                url: storeURL
            )
            self.container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to bootstrap SwiftData container: \(error)")
        }
        // Runs once at first launch after the UTC-wall-clock change (#168),
        // before any itinerary UI can query. Guarded internally.
        migrateItineraryTimesToUTC()
        // One-time retag of pre-existing transport-shaped activities to the new
        // transport kind (#238). Guarded internally.
        migrateActivitiesToTransport()
    }

    /// One-time backfill (#238): before the `transport` itinerary kind existed,
    /// flights and trains were stored as `.activity`. This pass retags the ones
    /// that carry a transport signal (a decoded boarding pass, a flight number,
    /// or an origin→destination route — i.e. `TicketMeta.isTransport`) to
    /// `.transport` with mode `.flight`.
    ///
    /// Heuristic by design: the `isTransport` signal is flight-shaped (BCBP /
    /// flight number / airport route), so backfilled rows default to `.flight`.
    /// A ticketless car transfer with no route leaves no signal and is left as
    /// an activity; the user can switch it in the editor. New imports classify
    /// correctly at the source, so this only touches legacy rows.
    ///
    /// Gated by a `UserDefaults` flag so it runs exactly once. Wrapped in
    /// do/catch — never crashes launch; a failure leaves the flag unset to retry.
    private func migrateActivitiesToTransport() {
        let flagKey = "activitiesToTransportMigrated_v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }

        let ctx = container.mainContext
        do {
            let items = try ctx.fetch(FetchDescriptor<LocalItineraryItem>())
            var didChange = false
            for item in items where item.kindEnum == .activity && (item.ticketMeta?.isTransport ?? false) {
                item.kindEnum = .transport
                if item.transportModeEnum == nil {
                    item.transportModeEnum = .flight
                }
                item.updatedAt = Date()
                didChange = true
            }
            if didChange {
                try ctx.save()
            }
            defaults.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so a future launch can retry. Never crash.
            NSLog("SwiftDataStore: activities→transport migration failed: %@", String(describing: error))
        }
    }

    /// One-time migration (#168): convert existing itinerary item times from
    /// the old device-local-wall-clock scheme to the new UTC-wall-clock scheme.
    ///
    /// Before #168, `startTime`/`endTime` stored a Date whose DEVICE-local H:M
    /// equalled the stated booking time. After #168 the app displays times with
    /// a UTC-pinned formatter, so those rows would render shifted. This pass
    /// rebuilds each stored Date so its UTC components equal the old device-local
    /// components (i.e. the stated H:M is preserved under the new anchor).
    ///
    /// Assumption: correct when the device timezone now equals the timezone in
    /// effect when the item was created (the common case — items created and
    /// migrated on the same phone in the same zone). Rare items created while
    /// the phone was in a different timezone can be corrected by re-scan (#165)
    /// or a manual edit, both of which re-anchor to UTC wall-clock directly.
    ///
    /// Gated by a `UserDefaults` flag so it runs exactly once. Wrapped in
    /// do/catch — never crashes launch.
    private func migrateItineraryTimesToUTC() {
        let flagKey = "itineraryTimesUTCMigrated_v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }

        let ctx = container.mainContext
        let local = Calendar.current
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        // Rebuild `stored` (a device-local wall-clock Date) as a UTC wall-clock
        // Date preserving all components. Returns nil if reconstruction fails.
        func rebased(_ stored: Date) -> Date? {
            let c = local.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: stored
            )
            var out = DateComponents()
            out.year = c.year
            out.month = c.month
            out.day = c.day
            out.hour = c.hour
            out.minute = c.minute
            out.second = c.second
            return utc.date(from: out)
        }

        do {
            let items = try ctx.fetch(FetchDescriptor<LocalItineraryItem>())
            var didChange = false
            for item in items where item.startTime != nil || item.endTime != nil {
                if let start = item.startTime, let r = rebased(start) {
                    item.startTime = r
                    didChange = true
                }
                if let end = item.endTime, let r = rebased(end) {
                    item.endTime = r
                    didChange = true
                }
            }
            if didChange {
                try ctx.save()
            }
            defaults.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so a future launch can retry. Never crash.
            NSLog("SwiftDataStore: itinerary UTC time migration failed: %@", String(describing: error))
        }
    }

    /// Test/preview-only initializer backed by an explicit container (usually
    /// `makeInMemory()`), so isolated tests exercise the real service + dedup
    /// paths against an in-memory store instead of the on-disk singleton. Skips
    /// the launch-time itinerary migration (irrelevant to a fresh store). Never
    /// used by the app, which always goes through `.shared`.
    init(container: ModelContainer) {
        self.container = container
    }

    /// Build an in-memory container for tests or previews.
    static func makeInMemory() -> ModelContainer {
        do {
            let schema = Schema([
                LocalTodo.self,
                LocalNoteFolder.self,
                LocalNote.self,
                LocalList.self,
                LocalKeyword.self,
                LocalTrip.self,
                LocalItineraryItem.self,
                LocalExpense.self,
                RecurringExpense.self,
                LocalPerson.self,
                LocalEvent.self,
                LocalFXRate.self,
                LocalProcessedEmail.self,
                LocalEmailIngestLog.self,
                LocalStatementImport.self,
            ])
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to bootstrap in-memory SwiftData container: \(error)")
        }
    }
}
