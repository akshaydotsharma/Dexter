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
    /// Forces the SwiftData store to bootstrap at process start, in DEBUG only.
    ///
    /// `SwiftDataStore.shared` is a `static let`, so it is lazy, and both the
    /// debug launch hooks and #318's store-path override guards run inside its
    /// `init()`. A launch that never gets as far as building the store produces
    /// no hook output and no guard refusal, which is indistinguishable from the
    /// feature being broken. That has already cost two diagnostic rounds: probes
    /// reporting "LAUNCHED" for cases that should have refused, and hooks
    /// believed dead that were simply never reached.
    ///
    /// This sits in `init()` rather than in a `.task` on the scene's root view,
    /// which is what was requested. A `.task` only runs once a view appears, so
    /// it cannot cover the case the request is actually about, a launch that
    /// never renders a view. `init()` runs unconditionally at process start,
    /// which is as close to a module initialiser as Swift offers, and it is
    /// where the guarantee has to live to be worth anything.
    ///
    /// Release builds are untouched, and this file is macOS-only.
    init() {
        #if DEBUG
        _ = SwiftDataStore.shared
        #endif
    }

    var body: some Scene {
        // Identified so `openWindow(id:)` can reopen a window after the last one
        // is closed. #295 takes ⌘N for record creation, which replaces the
        // command group that supplied the free New Window item, so the reopen
        // path has to be explicit.
        WindowGroup(id: MacRootWindow.id) {
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

    /// Whether the process was launched with a valid `LAUNCH_SECTION` target.
    ///
    /// Read here rather than on `AppRouter` so the iOS-shared file stays
    /// untouched. Mirrors the parsing in `AppRouter.path`'s initialiser,
    /// including `.dashboard`, which that initialiser redirects to Activity
    /// rather than rejecting.
    private static var hasLaunchTarget: Bool {
        guard let raw = ProcessInfo.processInfo.environment["LAUNCH_SECTION"]?.lowercased() else {
            return false
        }
        return AppSection(rawValue: raw) != nil
    }

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
            // historical macOS default of opening on Tasks. Idempotent, which
            // matters because `.task` on a `WindowGroup`'s root view runs once
            // per WINDOW, not per process.
            //
            // Emptiness alone is not enough to decide. `AppRouter.path`'s
            // initialiser deliberately leaves the path empty for
            // `LAUNCH_SECTION=chat`, because on iOS chat IS the stack root.
            // Seeding on emptiness therefore swallowed that one target and
            // left Chat the only section unreachable by script. So seed only
            // when no valid launch target was requested at all.
            if router.path.isEmpty && !Self.hasLaunchTarget {
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
///
/// Two fixes here (issue #305).
///
/// It set no window title, so the detail pane inherited nothing and the window
/// fell back to the sidebar's `.navigationTitle("Dexter")`. Help center was
/// therefore the one section whose title bar read "Dexter" instead of its own
/// name. Found by measuring the screenshots, not by reading the code.
///
/// And the placeholder was hand-rolled: a 40pt glyph over two lines of text,
/// which is phone-sized on a desktop. `ContentUnavailableView` is the native
/// macOS 14+ empty state, so it gets correct metrics, spacing and vertical
/// centring from the system rather than from constants maintained here.
private struct ComingSoonView: View {
    let section: AppSection

    var body: some View {
        ContentUnavailableView {
            Label(section.displayName, systemImage: section.icon)
        } description: {
            Text("Coming to macOS")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.paper)
        .macSectionChrome(section.displayName)
    }
}
