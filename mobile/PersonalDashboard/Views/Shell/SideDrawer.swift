import SwiftUI

/// Left side drawer mirroring `Sidebar.jsx`. Width = `min(280, screenWidth * 0.8)`.
struct SideDrawer: View {
    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    var body: some View {
        GeometryReader { geo in
            let drawerWidth = min(280, geo.size.width * 0.8)

            ZStack(alignment: .leading) {
                // Scrim
                if router.drawerOpen {
                    Tokens.ink.opacity(0.40)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.2)) {
                                router.drawerOpen = false
                            }
                        }
                }

                if router.drawerOpen {
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
                        .transition(.move(edge: .leading))
                        .gesture(
                            DragGesture(minimumDistance: 20)
                                .onEnded { value in
                                    if value.translation.width < -40 {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            router.drawerOpen = false
                                        }
                                    }
                                }
                        )
                }
            }
            .animation(.easeOut(duration: 0.2), value: router.drawerOpen)
        }
    }

    private var drawerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Wordmark
            HStack(spacing: Space.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Tokens.paper)
                    .frame(width: 28, height: 28)
                    .background(Tokens.ink, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                Text("Dashy")
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                Spacer()
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.xl)

            // Primary
            DrawerRow(section: .today, router: router)
            DrawerRow(section: .chat, router: router)

            DrawerDivider()

            // Surfaces
            DrawerRow(section: .tasks, router: router)
            DrawerRow(section: .notes, router: router)
            DrawerRow(section: .lists, router: router)

            DrawerDivider()

            // Dashboard
            DrawerRow(section: .dashboard, router: router)

            // Activity (read-only chronological feed of all creations)
            DrawerRow(section: .activity, router: router)

            DrawerDivider()

            // Settings
            DrawerRow(section: .settings, router: router)

            Spacer()

            // Footer
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
