import SwiftUI
import SwiftData

struct DashboardView: View {
    @State private var viewModel = DashboardViewModel()

    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    // Query the live SwiftData state so the view body re-evaluates on every
    // mutation. We don't read these arrays for display — they're a lightweight
    // change-trigger that keeps `viewModel.stats` in lockstep with the store.
    @Query(filter: #Predicate<LocalTodo> { $0.deletedAt == nil }) private var todos: [LocalTodo]
    @Query(filter: #Predicate<LocalNote> { $0.deletedAt == nil }) private var notes: [LocalNote]
    @Query(filter: #Predicate<LocalList> { $0.deletedAt == nil }) private var lists: [LocalList]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: "Dashboard",
                    onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } },
                    onToggleTheme: { schemePref = schemePref.next }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        if let stats = viewModel.stats {
                            statsSection(stats: stats)
                        }

                        quickActions
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.lg)
                    .padding(.bottom, 96)
                }
                .refreshable { viewModel.refresh() }
            }

            ChatFAB { router.popToChat() }
        }
        .activeSection(.dashboard)
        .onAppear { viewModel.refresh() }
        .onChange(of: todos.count) { viewModel.refresh() }
        .onChange(of: notes.count) { viewModel.refresh() }
        .onChange(of: lists.count) { viewModel.refresh() }
    }

    private func statsSection(stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("This week").eyebrow()
            VStack(spacing: Space.md) {
                StatCard(title: "Tasks", value: stats.todos.total, trend: stats.todos.trend, icon: "checkmark.square", accent: Tokens.accentTasks)
                StatCard(title: "Notes", value: stats.notes.total, trend: stats.notes.trend, icon: "doc.text", accent: Tokens.accentNotes)
                StatCard(title: "Lists", value: stats.lists.total, trend: stats.lists.trend, icon: "list.bullet", accent: Tokens.accentLists)
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Quick actions").eyebrow()
            Button {
                router.popToChat()
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Ask the assistant")
                }
            }
            .buttonStyle(EdButtonStyle(kind: .primary, size: .md, fullWidth: true))
        }
    }
}

private struct StatCard: View {
    let title: String
    let value: Int
    let trend: Int
    let icon: String
    let accent: Color

    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Tokens.border, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(Tokens.muted)
                Text("\(value)")
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .contentTransition(.numericText())
            }

            Spacer()

            trendBadge
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    private var trendBadge: some View {
        let symbol: String
        let color: Color
        let soft: Color
        if trend > 0 {
            symbol = "arrow.up"; color = Tokens.success; soft = Tokens.successSoft
        } else if trend < 0 {
            symbol = "arrow.down"; color = Tokens.danger; soft = Tokens.dangerSoft
        } else {
            symbol = "minus"; color = Tokens.muted; soft = Tokens.paper2
        }
        return HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text("\(abs(trend))%")
                .font(.edCaption)
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 4)
        .background(soft, in: Capsule())
    }
}
