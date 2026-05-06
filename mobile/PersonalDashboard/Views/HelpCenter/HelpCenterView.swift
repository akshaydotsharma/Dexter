import SwiftUI

/// Help center surface (Navigation v3, issue #48). Routed page with a
/// polite "Coming soon" placeholder so the drawer entry has a real
/// destination instead of a 404. Real content (FAQs, contact links,
/// release notes) lands here later.
struct HelpCenterView: View {
    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: "Help center",
                    onMenu: {
                        withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true }
                    },
                    onToggleTheme: { schemePref = schemePref.next }
                )

                Spacer()

                VStack(spacing: Space.lg) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(Tokens.muted)

                    Rectangle()
                        .fill(Tokens.accentHelp)
                        .frame(width: 32, height: 2)

                    VStack(spacing: Space.sm) {
                        Text("Coming soon")
                            .font(.edDisplay)
                            .foregroundStyle(Tokens.ink)
                            .multilineTextAlignment(.center)
                            .tracking(-0.4)

                        Text("Tips, FAQs, and ways to reach out will live here.")
                            .font(.edBody)
                            .foregroundStyle(Tokens.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                }
                .padding(.horizontal, Space.xl)

                Spacer()
                Spacer()
            }
        }
        .activeSection(.helpCenter)
    }
}
