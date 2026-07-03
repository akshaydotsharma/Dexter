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
            // edits made during the session). Cheap and non-blocking: the
            // service no-ops fast when backup is off, no folder is set, or the
            // interval hasn't elapsed. Background time is limited, so the active
            // hook is the primary path.
            switch newPhase {
            case .active, .background:
                Task { @MainActor in
                    try? BackupService(modelContext: SwiftDataStore.shared.context)
                        .runBackupIfDue(force: false)
                }
            default:
                break
            }
        }
    }
}
