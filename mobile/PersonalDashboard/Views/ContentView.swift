import SwiftUI

struct ContentView: View {
    @State private var router = AppRouter()
    @AppStorage("colorSchemePref") private var schemePrefRaw: String = ColorSchemePref.system.rawValue

    private var schemePref: Binding<ColorSchemePref> {
        Binding(
            get: { ColorSchemePref(rawValue: schemePrefRaw) ?? .system },
            set: { schemePrefRaw = $0.rawValue }
        )
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Chat is the root. Surfaces stack on top of chat by toggling
            // `router.path` and rendering the appropriate surface.
            chatRoot
                .zIndex(0)

            // Surface overlays — chosen via router state.
            if let section = router.path.first {
                surfaceView(for: section)
                    .zIndex(1)
                    .transition(.move(edge: .trailing))
            }

            // Drawer on top of everything.
            SideDrawer(router: router, schemePref: schemePref)
                .zIndex(2)
        }
        .preferredColorScheme((ColorSchemePref(rawValue: schemePrefRaw) ?? .system).resolved)
        .activeSection(router.currentSection)
        .animation(.easeOut(duration: 0.2), value: router.path)
    }

    @ViewBuilder
    private var chatRoot: some View {
        ChatView(router: router, schemePref: schemePref)
            .activeSection(.chat)
    }

    @ViewBuilder
    private func surfaceView(for section: AppSection) -> some View {
        switch section {
        case .chat:
            // shouldn't render — chat is the root, not an overlay.
            EmptyView()
        case .tasks:
            TasksView(router: router, schemePref: schemePref)
        case .notes:
            NotesView(router: router, schemePref: schemePref)
        case .lists:
            ListsView(router: router, schemePref: schemePref)
        case .dashboard:
            DashboardView(router: router, schemePref: schemePref)
        case .settings:
            SettingsView(router: router, schemePref: schemePref)
        case .today:
            PlaceholderView(section: section, router: router, schemePref: schemePref)
        }
    }
}

private struct PlaceholderView: View {
    let section: AppSection
    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Tokens.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(
                    title: section.displayName,
                    onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } },
                    onToggleTheme: { schemePref = schemePref.next }
                )
                Spacer()
                VStack(spacing: Space.md) {
                    Image(systemName: section.icon)
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(Tokens.muted)
                    Text("\(section.displayName) is coming soon.")
                        .font(.edBody)
                        .foregroundStyle(Tokens.muted)
                }
                Spacer()
            }
            ChatFAB { router.popToChat() }
        }
        .activeSection(section)
    }
}

#Preview {
    ContentView()
}
