import Foundation
import SwiftData
#if canImport(AppKit)
import AppKit
#endif

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
/// Single debug-only seam for every launch hook that redirects or drives the
/// data layer (#318, #319 verification).
///
/// One place on purpose. Scattering `ProcessInfo` reads into views is what #316
/// exists to clean up, and the `LAUNCH_SECTION` parse is already duplicated, so
/// this gains a third tenant rather than the codebase gaining a third scattered
/// read. When #316 consolidates scaffolding it should relocate this whole enum
/// to its own file; it lives here for now only because a new file needs a
/// `project.yml` entry, which is MacUI's to add, and that would put the round
/// trip behind a cross-branch dependency.
///
/// Every hook follows the same discipline:
///   • `#if DEBUG` only, so release builds cannot be driven from the outside.
///   • Environment-only, never a persisted setting, so nothing stale outlives
///     the run that set it.
///   • Three-way resolution: absent is fine, usable proceeds, and **present but
///     unusable refuses to launch** rather than falling back. Falling back is
///     what made an unexpanded `${DEXTER_STORE_PATH}` silently target the user's
///     real store.
enum DebugLaunchHooks {
    #if DEBUG
    /// Resolve a path-valued hook three ways. Returns nil when the variable is
    /// genuinely absent; traps when it is set to something unusable.
    ///
    /// Reuses `AppConfig.resolved` for placeholder DETECTION only. Its nil is
    /// deliberately ambiguous between "missing" and "junk" because for an API key
    /// both mean "not configured"; for a path they mean opposite things, so the
    /// presence check happens here, before the helper is consulted.
    static func path(for variable: String) -> String? {
        guard let present = ProcessInfo.processInfo.environment[variable] else { return nil }
        guard let usable = AppConfig.resolved(present) else {
            fatalError(
                """
                \(variable) is set but carries no usable value (got "\(present)": \
                empty, whitespace-only, or an unexpanded $(...) / ${...} \
                placeholder). Refusing to launch rather than guessing.
                """
            )
        }
        return (usable as NSString).expandingTildeInPath
    }

    /// Run the export / import hooks once the container exists.
    ///
    /// Called from `SwiftDataStore`'s bootstrap rather than from the SwiftUI
    /// shell: `DexterMacApp.swift` is MacUI's file and currently carries the
    /// #293 router rework, so editing it concurrently is the worst available
    /// merge conflict.
    ///
    /// Export exits the process on completion so a script can rely on the exit
    /// code. Import deliberately does NOT exit, because the whole point of
    /// importing is to then inspect the restored data in the UI — checking a
    /// restored boarding pass opens is the one assertion that catches a dangling
    /// `attachmentPath`, and a count check cannot.
    @MainActor
    static func runDataHooks(context: ModelContext) {
        if let target = path(for: "DEXTER_EXPORT_TO") {
            runExport(to: target, context: context)
        }
        if let source = path(for: "DEXTER_IMPORT_FROM") {
            runImport(from: source, context: context)
        }
    }

    @MainActor
    private static func runExport(to target: String, context: ModelContext) {
        let url = URL(fileURLWithPath: target)
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            NSLog("DEXTER_EXPORT_TO: parent directory does not exist: %@", parent.path)
            exit(1)
        }
        do {
            let produced = try DataExportService(modelContext: context).export()
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: produced, to: url)
            NSLog("DEXTER_EXPORT_TO: wrote archive to %@", url.path)
            exit(0)
        } catch {
            NSLog("DEXTER_EXPORT_TO: export failed: %@", String(describing: error))
            exit(1)
        }
    }

    @MainActor
    private static func runImport(from source: String, context: ModelContext) {
        // Import is the one operation that destroys data by design, so it is
        // gated on the store already being disposable. Without this, a careless
        // script could restore an archive straight over the user's real
        // financial data, and a fresh backup would only convert that into a
        // restore that depends on the code under test.
        guard SwiftDataStore.isUsingOverrideStore else {
            NSLog("DEXTER_IMPORT_FROM: refusing to import without DEXTER_STORE_PATH set — will not write to the real store")
            exit(1)
        }
        let url = URL(fileURLWithPath: source)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("DEXTER_IMPORT_FROM: no archive at %@", url.path)
            exit(1)
        }
        do {
            let service = DataImportService(modelContext: context)
            let preview = try service.preview(url: url)
            try service.commit(preview: preview)
            NSLog("DEXTER_IMPORT_FROM: imported %@ — app left running for UI inspection", url.path)
        } catch {
            // Surfaced rather than swallowed: this is how a manifestClaimsMismatch
            // refusal becomes observable, which is otherwise unverifiable.
            NSLog("DEXTER_IMPORT_FROM: import failed: %@", String(describing: error))
            exit(1)
        }
    }
    #endif
}

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

    /// Say out loud, unmissably, that this process is NOT looking at the real
    /// store (#318).
    ///
    /// A disposable store is visually identical to a wiped one, so on this app a
    /// tester who forgets the override is active sees an empty Finance section
    /// and concludes their financial history is gone. An `NSLog` line does
    /// nothing for someone looking at the window, so this is a modal: it cannot
    /// be missed, scrolled past, or hidden behind a window that opened on
    /// another section.
    ///
    /// A modal is proportionate because the whole override is `#if DEBUG` and
    /// dev-only; this is never user-facing chrome. Deliberately implemented here
    /// rather than in the SwiftUI shell, both because `DexterMacApp.swift` is
    /// MacUI's file and because that file currently carries the #293 router
    /// rework, so a concurrent edit there would be a painful merge conflict. A
    /// persistent in-window affordance is a follow-up once the branches
    /// converge, not a substitute for this.
    ///
    /// Deferred to the next run-loop turn: this runs during container bootstrap,
    /// which can precede `NSApplication` being ready to present modally.
    private static func warnIfOverrideStore(_ url: URL) {
        #if DEBUG && canImport(AppKit)
        guard isUsingOverrideStore else { return }
        NSLog("SwiftDataStore: OVERRIDE store active at %@", url.path)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Running against an override store"
            alert.informativeText = """
                DEXTER_STORE_PATH is set, so this launch is NOT using your real \
                Dexter data.

                Store in use:
                \(url.path)

                An empty or unfamiliar app is EXPECTED here and does not mean \
                your data is lost. Your real store is untouched. Quit and unset \
                DEXTER_STORE_PATH to go back to it.
                """
            alert.addButton(withTitle: "Continue with override store")
            alert.runModal()
        }
        #endif
    }

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
        // Resolved through the shared seam, which does the three-way itself:
        // absent returns nil, present-but-unusable traps. The distinction is
        // load-bearing — collapsing it is what made an unexpanded
        // `${DEXTER_STORE_PATH}` silently target the user's real store.
        guard let raw = DebugLaunchHooks.path(for: "DEXTER_STORE_PATH") else {
            // Genuinely unset. Default path, silently. The only safe fallback.
            return defaultURL
        }
        let url = URL(fileURLWithPath: raw)
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
            Self.warnIfOverrideStore(storeURL)
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
        #if DEBUG
        // Export / import launch hooks (#319 verification). Deferred a run-loop
        // turn so both launch migrations above have completed and the container
        // is fully settled before an export snapshots it or an import mutates it.
        // No-op unless DEXTER_EXPORT_TO / DEXTER_IMPORT_FROM are set.
        let hookContext = container.mainContext
        DispatchQueue.main.async {
            DebugLaunchHooks.runDataHooks(context: hookContext)
        }
        #endif
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
