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
                }
        }
        .modelContainer(SwiftDataStore.shared.container)
        .onChange(of: scenePhase) { _, newPhase in
            // Re-fetch when the app returns to the foreground (#143).
            if newPhase == .active {
                Task { await EmailIngestCoordinator.shared.runForegroundFetch() }
            }
        }
    }
}
