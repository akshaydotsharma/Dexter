import SwiftUI
import SwiftData

@main
struct PersonalDashboardApp: App {
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

                    // Kick off a sync round-trip on launch so the SwiftData
                    // store hydrates from the server (or pushes pending
                    // local changes) before the user navigates anywhere.
                    // Failures are silent — the next refresh retries.
                    try? await SyncEngine.shared.sync()
                }
        }
        .modelContainer(SwiftDataStore.shared.container)
    }
}
