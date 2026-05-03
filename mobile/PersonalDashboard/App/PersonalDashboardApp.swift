import SwiftUI
import SwiftData
import UserNotifications

@main
struct PersonalDashboardApp: App {
    init() {
        // Bridge notification taps into AppRouter so capture-confirmation
        // banners can deeplink into the app. Issue #13.
        UNUserNotificationCenter.current().delegate = CaptureNotificationDelegate.shared
    }

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
                }
                .onOpenURL { url in
                    AppRouter.shared.handle(url: url)
                }
        }
        .modelContainer(SwiftDataStore.shared.container)
    }
}
