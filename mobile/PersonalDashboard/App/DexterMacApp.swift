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
    var body: some Scene {
        WindowGroup {
            // `MacRootView` owns its own `AppRouter` so each window carries
            // independent navigation state. Hoisting the router up here would
            // share one selection across every window, because a `WindowGroup`
            // evaluates its content once per window but `@State` on the `App`
            // is created once per process.
            MacRootView()
                .modelContainer(SwiftDataStore.shared.container)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        // Menu bar commands (issue #295). They act on whichever window is
        // focused, via the router each window publishes as a focused scene
        // value, because commands are declared once per scene but routers are
        // per window.
        .commands { DexterCommands() }
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
    /// The single source of truth for which section is showing.
    ///
    /// This used to be a local `@State selection` sitting alongside the
    /// router, which meant the Mac had TWO navigation states and only the
    /// sidebar could write to one of them. Every programmatic navigation in
    /// the shared views goes through `AppRouter.go(to:)`, so on macOS all of
    /// them were dead clicks: six rows in Activity, three in Today, and the
    /// chat result card's "jump to what I just created".
    ///
    /// Worse than inert: those call sites set `router.focus` immediately
    /// before calling `go(to:)`, and the destination views consume that focus
    /// on appear. So the click did nothing, and the NEXT time the user opened
    /// that section by hand it scrolled to and pulsed a row they had clicked
    /// minutes earlier. Deriving selection from the router fixes both, and
    /// makes `LAUNCH_SECTION` work, which is what unblocks scripted
    /// navigation for screenshots and QA.
    @State private var router = AppRouter()

    /// Sidebar order. Excludes the dead `dashboard` section (issue #30).
    private let sections: [AppSection] = [
        .chat, .today, .tasks, .notes, .lists,
        .itineraries, .finance, .vocabulary, .activity,
        .settings, .helpCenter,
    ]

    /// Reads the router and writes back through `go(to:)`, so the sidebar and
    /// every programmatic navigation move the same state.
    private var selection: Binding<AppSection> {
        Binding(
            get: { router.currentSection },
            set: { router.go(to: $0) }
        )
    }

    /// Theme preference, shared with the iOS store via the same UserDefaults
    /// key (`colorSchemePref`) that `ContentView` uses. Surfaced to `Settings`
    /// as a binding and applied to the whole window so the picker takes effect.
    @AppStorage("colorSchemePref") private var schemePrefRaw: String = ColorSchemePref.system.rawValue

    private var schemePref: Binding<ColorSchemePref> {
        Binding(
            get: { ColorSchemePref(rawValue: schemePrefRaw) ?? .system },
            set: { schemePrefRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(sections, selection: selection) { section in
                Label(section.displayName, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Dexter")
            .frame(minWidth: 210)
        } detail: {
            detailView(for: router.currentSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.paper)
        }
        .preferredColorScheme((ColorSchemePref(rawValue: schemePrefRaw) ?? .system).resolved)
        // Let the menu bar act on THIS window's router when it is focused.
        .publishRouterToCommands(router)
        .task {
            // `currentSection` reads an empty path as `.chat`, so seed the
            // historical macOS default of opening on Tasks. Only when nothing
            // has already set a section, so a `LAUNCH_SECTION` deep-link is
            // preserved. Idempotent, which matters because `.task` on a
            // `WindowGroup`'s root view runs once per WINDOW, not per process.
            if router.path.isEmpty {
                router.go(to: .tasks)
            }
        }
    }

    @ViewBuilder
    private func detailView(for section: AppSection) -> some View {
        switch section {
        case .chat:
            ChatView(router: router)
        case .tasks:
            TasksView(router: router)
        case .today:
            TodayView(router: router)
        case .lists:
            ListsView(router: router)
        case .notes:
            NotesView(router: router)
        case .itineraries:
            TripsView(router: router)
        case .finance:
            FinanceView(router: router)
        case .vocabulary:
            PersonalVocabularyView(router: router)
        case .activity:
            ActivityView(router: router)
        case .settings:
            SettingsView(router: router, schemePref: schemePref)
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
