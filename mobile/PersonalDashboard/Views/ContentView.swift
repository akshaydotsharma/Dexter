import SwiftUI
import UIKit

struct ContentView: View {
    @State private var router = AppRouter()
    @AppStorage("colorSchemePref") private var schemePrefRaw: String = ColorSchemePref.system.rawValue

    /// Tracks whether we've already resigned first responder for the active
    /// edge-swipe. Without this, every `onChanged` tick would fire another
    /// `resignFirstResponder` send-action — once the keyboard is down, the
    /// repeated calls are a no-op but still wasted work. Reset on `onEnded`
    /// so the next swipe gets a fresh dismiss.
    @State private var didDismissKeyboardForEdgeSwipe: Bool = false

    private var schemePref: Binding<ColorSchemePref> {
        Binding(
            get: { ColorSchemePref(rawValue: schemePrefRaw) ?? .system },
            set: { schemePrefRaw = $0.rawValue }
        )
    }

    /// Width of the leading hot-zone that captures edge-swipes to open the
    /// drawer (issue #35). Matches the iOS-standard ~20pt edge for back /
    /// drawer gestures.
    private let edgeSwipeWidth: CGFloat = 20
    private let edgeCoordinateSpace = "rootEdgeSwipe"

    var body: some View {
        ZStack(alignment: .leading) {
            // Chat is the root. Surfaces stack on top of chat by toggling
            // `router.path` and rendering the appropriate surface.
            chatRoot
                .zIndex(0)

            // Surface overlays — chosen via router state. Page swaps are
            // instant (no slide / fade transition); the only animation
            // when switching tabs is the active-pill indicator inside
            // BottomTabBar, which keeps its spring for tactile feedback.
            if let section = router.path.first {
                surfaceView(for: section)
                    .zIndex(1)
                    .transition(.identity)
            }

            // Bottom fade — surface content that scrolls into the pill's
            // region softly fades to paper so it doesn't fight the floating
            // bar for attention (matches the Flow / Threads pattern).
            // Renders ABOVE the surface stack but BELOW the bar so the
            // pill itself stays crisp.
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    stops: [
                        .init(color: Tokens.paper.opacity(0.0), location: 0.0),
                        .init(color: Tokens.paper.opacity(0.55), location: 0.45),
                        .init(color: Tokens.paper.opacity(0.95), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: BottomTabBarMetrics.height + 60)
                .allowsHitTesting(false)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .ignoresSafeArea(edges: .bottom)
            .zIndex(2)

            // Bottom tab bar — anchored at the root so it persists across
            // surface transitions. Lives above the surface stack but below
            // the drawer scrim so opening the drawer dims the bar too.
            VStack(spacing: 0) {
                Spacer()
                BottomTabBar(router: router)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .zIndex(3)

            // Drawer on top of everything.
            SideDrawer(router: router)
                .zIndex(4)
        }
        .preferredColorScheme((ColorSchemePref(rawValue: schemePrefRaw) ?? .system).resolved)
        .activeSection(router.currentSection)
        .coordinateSpace(name: edgeCoordinateSpace)
        // Edge-swipe-to-open is scoped to a 20pt-wide leading strip overlay,
        // NOT a screen-wide `.simultaneousGesture`. A root-level DragGesture
        // with `minimumDistance: 8` claims arbitration on any 8pt drag — that
        // starves the inner List's vertical scroll, even with the
        // `startLocation.x <= edgeSwipeWidth` guard (the guard runs after
        // the gesture has already won). Constraining the gesture host to a
        // thin leading strip leaves the rest of the screen free for the
        // List's native scroll + `.swipeActions` arbitration. (#79)
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: edgeSwipeWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(edgeOpenGesture)
                .ignoresSafeArea()
                .allowsHitTesting(!router.drawerOpen)
        }
    }

    private var edgeOpenGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(edgeCoordinateSpace))
            .onChanged { value in
                guard !router.drawerOpen else { return }
                guard value.startLocation.x <= edgeSwipeWidth else { return }
                guard value.translation.width > 0 else { return }
                // Drop the keyboard the moment the drag qualifies as an
                // edge-open — keyboard slide-down and drawer slide-in then
                // happen simultaneously, finger-tracked (issue #54).
                if !didDismissKeyboardForEdgeSwipe {
                    didDismissKeyboardForEdgeSwipe = true
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
                // When the active surface owns the edge swipe (it's inside
                // a sub-screen that should pop on right-swipe), suppress the
                // drawer peek mid-drag — the gesture is being recognised as
                // a back swipe, not a drawer open.
                if router.leadingEdgeBackHandler != nil {
                    router.drawerDragOffset = 0
                    return
                }
                let drawerWidth = min(280, UIScreen.main.bounds.width * 0.8)
                router.drawerDragOffset = min(drawerWidth, value.translation.width)
            }
            .onEnded { value in
                defer { didDismissKeyboardForEdgeSwipe = false }
                guard !router.drawerOpen else {
                    router.drawerDragOffset = 0
                    return
                }
                guard value.startLocation.x <= edgeSwipeWidth else {
                    router.drawerDragOffset = 0
                    return
                }
                let drawerWidth = min(280, UIScreen.main.bounds.width * 0.8)
                let translation = value.translation.width
                let velocity = value.predictedEndTranslation.width - translation
                let shouldCommit = translation > drawerWidth * 0.4 || velocity > 500
                withAnimation(.easeOut(duration: 0.2)) {
                    router.drawerDragOffset = 0
                    if shouldCommit {
                        if let backHandler = router.leadingEdgeBackHandler {
                            // Sub-screen active: pop back instead of opening
                            // the drawer. The handler runs its own animation
                            // for the screen swap.
                            backHandler()
                        } else {
                            // Keyboard was already dismissed in onChanged; flip
                            // the flag inside the same animation block as the
                            // drag-offset reset so the panel snaps to its open
                            // position smoothly.
                            router.drawerOpen = true
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var chatRoot: some View {
        ChatView(router: router)
            .activeSection(.chat)
    }

    @ViewBuilder
    private func surfaceView(for section: AppSection) -> some View {
        switch section {
        case .chat:
            // shouldn't render — chat is the root, not an overlay.
            EmptyView()
        case .tasks:
            TasksView(router: router)
        case .notes:
            NotesView(router: router)
        case .lists:
            ListsView(router: router)
        case .dashboard:
            // Dashboard surface is hidden (issue #30). The drawer entry has
            // been removed and the LAUNCH_SECTION deep-link redirects to
            // .activity, so this case is unreachable. Restore by replacing
            // EmptyView() with `DashboardView(router: router)`.
            EmptyView()
        case .activity:
            ActivityView(router: router)
        case .settings:
            SettingsView(router: router, schemePref: schemePref)
        case .today:
            TodayView(router: router)
        case .itineraries:
            ItinerariesView(router: router)
        case .finance:
            FinanceView(router: router)
        case .vocabulary:
            PersonalVocabularyView(router: router)
        case .helpCenter:
            HelpCenterView(router: router)
        }
    }
}

private struct PlaceholderView: View {
    let section: AppSection
    @Bindable var router: AppRouter

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(
                    title: section.displayName,
                    onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
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
        }
        .activeSection(section)
    }
}

#Preview {
    ContentView()
}
