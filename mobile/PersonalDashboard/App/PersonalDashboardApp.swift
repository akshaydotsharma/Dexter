import SwiftUI
import SwiftData

@main
struct PersonalDashboardApp: App {
    /// Registers the email-ingestion background task + notification delegate at
    /// launch (#143). The app is otherwise pure SwiftUI.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // One-time backfill (#277): existing trip expenses become
                    // opt-in to Finance. Runs first so any rows the coordinators
                    // below touch already reflect the new default. Idempotent —
                    // guarded by a UserDefaults flag inside.
                    TripExpenseFinanceMigration.runIfNeeded(context: SwiftDataStore.shared.context)
                    // Surface the "Find devices on local network" prompt
                    // before any feature tries to reach the LAN dev server.
                    // Bonjour browse is Apple's canonical trigger; a plain
                    // URLSession is unreliable.
                    LocalNetworkPermissionPrimer.shared.prime()
                    // Also make one real API call so the app shows up in
                    // iOS Settings with a Local Network toggle on first run.
                    let _: EmptyResponse? = try? await APIClient.shared.get("dashboard/config")
                    // Opportunistic email-to-itinerary fetch on launch (#143).
                    // No-ops unless the user has configured + enabled the inbox.
                    await EmailIngestCoordinator.shared.runForegroundFetch()
                    // Post any due / missed recurring expenses on launch (#236).
                    // scenePhase .active doesn't reliably fire for the initial
                    // launch value, so the launch pass lives here (the coordinator
                    // guards against overlapping cycles).
                    await RecurringExpenseCoordinator.shared.runForegroundMaterialize()
                    // Cross-device sync pass on launch (#348). Off by default
                    // and no-ops instantly when disabled or unconfigured. In
                    // phase 1 this cannot write to the store at all: it records
                    // local changes to the shared folder and only COUNTS what a
                    // peer would change here.
                    await SyncCoordinator.shared.runForegroundPass(reason: "launch")
                    SyncCoordinator.shared.startPeriodic()
                }
        }
        .modelContainer(SwiftDataStore.shared.container)
        .onChange(of: scenePhase) { _, newPhase in
            // Re-fetch email when the app returns to the foreground (#143).
            if newPhase == .active {
                Task { await EmailIngestCoordinator.shared.runForegroundFetch() }
                // Materialise due / missed recurring expenses on foreground (#236).
                Task { await RecurringExpenseCoordinator.shared.runForegroundMaterialize() }
            }
            // Opt-in automatic backup (#141). Fires on becoming active (covers
            // cold launch and foregrounding) and on entering background (catches
            // edits made during the session). The not-due path is genuinely
            // cheap: the service no-ops fast when backup is off, no folder is
            // set, or the interval hasn't elapsed. Background time is limited,
            // so the active hook is the primary path.
            //
            // When a backup DOES run, #309 moved the archive build and the
            // coordinated write off the main actor, so this no longer stalls the
            // UI for the length of a zip. The fetches and DTO mapping still run
            // on the main actor and cannot move without #334, so it is "much
            // shorter", not "free".
            switch newPhase {
            case .active, .background:
                Task { @MainActor in
                    try? await BackupService(modelContext: SwiftDataStore.shared.context)
                        .runBackupIfDue(force: false)
                }
            default:
                break
            }

            // Sync on the same phase edges as backup, for the same reason:
            // becoming active covers cold launch and foregrounding, and entering
            // background catches edits made during the session. The periodic
            // timer only runs while frontmost, so the background edge is the one
            // that gets the last change of a session out to the folder.
            switch newPhase {
            case .active:
                SyncCoordinator.shared.startPeriodic()
                Task { await SyncCoordinator.shared.runForegroundPass(reason: "foreground") }
            case .background:
                // iOS gives no reliable background execution here without
                // entitlements we do not have, so this is best-effort: a pass
                // that does not finish just runs on next foreground.
                SyncCoordinator.shared.stopPeriodic()
                Task { await SyncCoordinator.shared.runForegroundPass(reason: "background") }
            default:
                break
            }
        }
    }
}
