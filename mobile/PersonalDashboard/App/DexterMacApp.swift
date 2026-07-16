import SwiftUI
import SwiftData

/// Entry point for the native macOS build (issue #281).
///
/// Deliberately separate from the iOS `PersonalDashboardApp`: only this file is
/// a member of the macOS target, so there is exactly one `@main` per target and
/// the iOS app entry (with its `UIApplicationDelegateAdaptor`, background tasks,
/// and email ingest) is never dragged onto macOS.
///
/// The beachhead surfaces a single feature (Tasks) in one window, backed by the
/// Mac's own local SwiftData store (`SwiftDataStore.shared`). There is no
/// CloudKit sync on free personal-team signing; cross-device continuity comes
/// from restoring the iCloud Drive backup the phone writes (a later milestone).
@main
struct DexterMacApp: App {
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            MacRootView(router: router)
                // Harmless if unused by Tasks (its view model reads
                // SwiftDataStore.shared directly); wires the container for any
                // future @Query-based surface added to this window.
                .modelContainer(SwiftDataStore.shared.container)
                .frame(minWidth: 460, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Minimal macOS shell for the Tasks beachhead: a navigation container hosting
/// the existing `TasksView`, reused unchanged. As more surfaces are ported this
/// grows into a `NavigationSplitView` with a sidebar; for now it is a
/// single-feature window.
private struct MacRootView: View {
    @Bindable var router: AppRouter

    var body: some View {
        NavigationStack {
            TasksView(router: router)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.paper)
    }
}
