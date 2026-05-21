import SwiftUI

/// Finance surface placeholder (issue #110). Mirrors the HelpCenter pattern:
/// a routed page so the drawer entry has a real destination instead of a
/// 404. Real content (accounts, spending, recurring bills) lands here later.
struct FinanceView: View {
    @Bindable var router: AppRouter

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: "Finance",
                    onMenu: {
                        withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true }
                    }
                )

                Spacer()

                VStack(spacing: Space.lg) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(Tokens.muted)

                    Rectangle()
                        .fill(Tokens.accentFinance)
                        .frame(width: 32, height: 2)

                    VStack(spacing: Space.sm) {
                        Text("Coming soon")
                            .font(.edDisplay)
                            .foregroundStyle(Tokens.ink)
                            .multilineTextAlignment(.center)
                            .tracking(-0.4)

                        Text("Accounts, spending, and recurring bills will live here.")
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
        .activeSection(.finance)
    }
}
