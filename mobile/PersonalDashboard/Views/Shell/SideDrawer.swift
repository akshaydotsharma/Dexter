import SwiftUI

/// Left side drawer mirroring `Sidebar.jsx`. Width = `min(280, screenWidth * 0.8)`.
///
/// Edge-swipe and finger-tracking gestures (issue #35):
/// - Opening: a leading 20pt edge gesture lives on `ContentView` and writes
///   to `router.drawerDragOffset` so the panel follows the finger.
/// - Closing: a finger-tracking pan on the panel (and a tap on the scrim).
struct SideDrawer: View {
    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    /// Velocity threshold for "fling" snaps (pt/s). Above this, the drawer
    /// snaps to the direction of motion regardless of distance.
    private let velocitySnapThreshold: CGFloat = 500
    /// Distance threshold as a fraction of drawer width (40%).
    private let distanceSnapFraction: CGFloat = 0.4

    var body: some View {
        GeometryReader { geo in
            let drawerWidth = min(280, geo.size.width * 0.8)
            let baseOffset: CGFloat = router.drawerOpen ? 0 : -drawerWidth
            let panelX = max(-drawerWidth, min(0, baseOffset + router.drawerDragOffset))
            // 0 = fully closed, 1 = fully open. Drives scrim opacity + hit-testing.
            let progress = (panelX + drawerWidth) / drawerWidth

            ZStack(alignment: .leading) {
                // Scrim — always present so it can fade in/out with the drag.
                Tokens.ink.opacity(0.40 * Double(progress))
                    .ignoresSafeArea()
                    .allowsHitTesting(progress > 0.01)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            router.drawerOpen = false
                            router.drawerDragOffset = 0
                        }
                    }

                drawerPanel
                    .frame(width: drawerWidth)
                    .background(
                        Tokens.surface
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(Tokens.border)
                                    .frame(width: 0.5)
                            }
                            .ignoresSafeArea(edges: .vertical)
                    )
                    .offset(x: panelX)
                    .gesture(closeDragGesture(drawerWidth: drawerWidth))
            }
            .animation(.easeOut(duration: 0.2), value: router.drawerOpen)
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.9), value: router.drawerDragOffset)
        }
    }

    /// Finger-tracking swipe-left-to-close gesture on the panel itself.
    /// Active only when the drawer is open. Negative translations move the
    /// panel toward the closed position; positive translations are ignored
    /// (no over-pull past fully-open).
    private func closeDragGesture(drawerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard router.drawerOpen else { return }
                router.drawerDragOffset = max(-drawerWidth, min(0, value.translation.width))
            }
            .onEnded { value in
                guard router.drawerOpen else { return }
                let translation = value.translation.width
                let velocity = value.predictedEndTranslation.width - translation
                let shouldClose = translation < -drawerWidth * distanceSnapFraction
                    || velocity < -velocitySnapThreshold
                withAnimation(.easeOut(duration: 0.2)) {
                    router.drawerDragOffset = 0
                    if shouldClose {
                        router.drawerOpen = false
                    }
                }
            }
    }

    private var drawerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // User name header. The bottom tab bar now owns the primary
            // surfaces (Notes / Lists / Chat / Tasks / Activity), so the
            // drawer is repurposed for "the user's stuff" — name, Today,
            // help, settings (Navigation v3, issue #48).
            //
            // Hardcoded "Akshay" matches the footer pattern; the iOS app
            // has no auth so there's no real account to fetch from.
            HStack(spacing: Space.md) {
                Text("AS")
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                    .frame(width: 36, height: 36)
                    .background(Tokens.paper2, in: Circle())
                    .overlay(Circle().stroke(Tokens.border, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Akshay")
                        .font(.edTitle)
                        .foregroundStyle(Tokens.ink)
                    Text("Personal dashboard")
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.muted)
                }
                Spacer()
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.xl)

            DrawerDivider()

            // Three rows: Today, Help center, Settings. Primary surfaces
            // (Notes, Lists, Tasks, Activity) and Chat now live in the
            // bottom tab bar. Dashboard remains hidden (issue #30).
            DrawerRow(section: .today, router: router)
            DrawerRow(section: .helpCenter, router: router)
            DrawerRow(section: .settings, router: router)

            Spacer()

            // Footer
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("v\(Self.shortVersion) (\(Self.buildNumber))")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .accessibilityLabel("App version \(Self.shortVersion) build \(Self.buildNumber)")

                HStack(spacing: Space.md) {
                    Button {
                        schemePref = schemePref.next
                    } label: {
                        Image(systemName: schemeIcon)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Tokens.muted)
                            .frame(width: 36, height: 36)
                            .background(Tokens.paper2, in: Circle())
                            .overlay(Circle().stroke(Tokens.border, lineWidth: 0.5))
                    }
                    .accessibilityLabel("Theme: \(schemePref.rawValue)")

                    Text("AS")
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.ink)
                        .frame(width: 32, height: 32)
                        .background(Tokens.paper2, in: Circle())
                        .overlay(Circle().stroke(Tokens.border, lineWidth: 0.5))

                    Text("Akshay")
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)

                    Spacer()
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
            }
        }
    }

    private var schemeIcon: String {
        switch schemePref {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    // MARK: - Bundle helpers (mirrors SettingsView)

    private static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

private struct DrawerDivider: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.divider)
            .frame(height: 0.5)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
    }
}

private struct DrawerRow: View {
    let section: AppSection
    @Bindable var router: AppRouter

    var body: some View {
        let isActive = router.currentSection == section
        let accent = Tokens.accent(for: section)

        Button {
            router.go(to: section)
        } label: {
            HStack(spacing: Space.md) {
                // Active rail
                Rectangle()
                    .fill(isActive ? accent : Color.clear)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)

                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isActive ? accent : Tokens.muted)
                    .frame(width: 20)

                Text(section.displayName)
                    .font(.edBodyMedium)
                    .foregroundStyle(isActive ? Tokens.ink : Tokens.muted)

                Spacer()
            }
            .padding(.trailing, Space.lg)
            .frame(height: 44)
            .background(isActive ? Tokens.paper2 : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
