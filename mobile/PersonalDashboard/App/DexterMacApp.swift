import SwiftUI
import SwiftData

/// Entry point for the native macOS build (issue #281).
///
/// Deliberately separate from the iOS `PersonalDashboardApp`: only this file is
/// a member of the macOS target, so there is exactly one `@main` per target and
/// the iOS app entry (with its `UIApplicationDelegateAdaptor`, background tasks,
/// and email ingest) is never dragged onto macOS.
///
/// The Mac runs its own local SwiftData store (`SwiftDataStore.shared`). There
/// is no CloudKit sync on free personal-team signing; cross-device continuity
/// comes from restoring the iCloud Drive backup the phone writes (a later
/// milestone, after all features are ported — issue #281).
@main
struct DexterMacApp: App {
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            MacRootView(router: router)
                .modelContainer(SwiftDataStore.shared.container)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Native macOS shell: a `NavigationSplitView` with a sidebar of sections and a
/// detail pane that hosts the selected feature. This replaces the iOS
/// chat-rooted `ZStack` router + floating tab bar + edge-swipe drawer, which are
/// phone idioms. `AppRouter` still carries per-feature navigation state.
///
/// Each feature is wired into `detailView(for:)` as it is ported; sections not
/// yet ported render a `ComingSoonView` placeholder.
private struct MacRootView: View {
    @Bindable var router: AppRouter

    /// Sidebar order. Excludes the dead `dashboard` section (issue #30).
    private let sections: [AppSection] = [
        .chat, .today, .tasks, .notes, .lists,
        .activity, .itineraries, .finance, .vocabulary,
        .settings, .helpCenter,
    ]

    @State private var selection: AppSection = .tasks

    var body: some View {
        NavigationSplitView {
            List(sections, selection: $selection) { section in
                Label(section.displayName, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Dexter")
            .frame(minWidth: 210)
        } detail: {
            detailView(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.paper)
        }
    }

    @ViewBuilder
    private func detailView(for section: AppSection) -> some View {
        switch section {
        case .tasks:
            TasksView(router: router)
        case .today:
            TodayView(router: router)
        case .lists:
            ListsView(router: router)
        case .notes:
            NotesView(router: router)
        case .vocabulary:
            PersonalVocabularyView(router: router)
        case .activity:
            ActivityView(router: router)
        default:
            ComingSoonView(section: section)
        }
    }
}

/// Placeholder for a section not yet ported to macOS.
private struct ComingSoonView: View {
    let section: AppSection

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: section.icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Tokens.muted)
            Text(section.displayName)
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
            Text("Coming to macOS")
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.paper)
    }
}
