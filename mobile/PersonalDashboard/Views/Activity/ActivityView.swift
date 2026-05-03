import SwiftUI

/// Activity timeline surface (issue #16). Read-only chronological feed of
/// every note, todo, list, and folder the user has created. Same shape as the
/// web version: filter chips, day-grouped rows with sticky headers, infinite
/// scroll via the last-row sentinel, deep-link to the owning section with a
/// brief accent pulse on the focused row.
struct ActivityView: View {
    @State private var viewModel = ActivityViewModel()

    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: "Activity",
                    onMenu: {
                        withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true }
                    },
                    onToggleTheme: { schemePref = schemePref.next }
                )

                // Caption sits under TopBar, mirroring the web subtitle.
                Text("Everything you have captured, newest first.")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.sm)
                    .padding(.bottom, Space.sm)

                FilterChipBar(
                    selected: viewModel.filter,
                    onSelect: { next in
                        viewModel.setFilter(next)
                    }
                )
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)

                Divider().background(Tokens.divider)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if viewModel.isLoading {
                            FirstLoadSkeleton()
                        } else if viewModel.items.isEmpty {
                            EmptyStateView(filter: viewModel.filter)
                                .frame(maxWidth: .infinity)
                                .padding(.top, Space.xxxl)
                        } else {
                            ForEach(groups, id: \.key) { group in
                                Section(header: dayHeader(for: group)) {
                                    ForEach(Array(group.items.enumerated()), id: \.element.rowKey) { idx, item in
                                        ActivityRow(item: item) {
                                            handleTap(item: item)
                                        }
                                        if idx < group.items.count - 1 {
                                            Rectangle()
                                                .fill(Tokens.divider)
                                                .frame(height: 0.5)
                                                .padding(.leading, Space.lg)
                                        }
                                    }
                                }
                            }

                            // Subsequent-page skeleton + load-more sentinel
                            if viewModel.isLoadingMore {
                                NextPageSkeleton()
                            }

                            if viewModel.nextCursor != nil {
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear {
                                        viewModel.loadNextPage()
                                    }
                            }
                        }
                    }
                    .padding(.bottom, 96) // FAB clearance
                }
                .refreshable { viewModel.refresh() }
            }

            ChatFAB { router.popToChat() }
        }
        .activeSection(.activity)
        .onAppear { viewModel.loadFirstPage() }
    }

    // MARK: - Tap → deep-link

    private func handleTap(item: ActivityItem) {
        let target: AppSection
        let isFolder: Bool
        switch item.type {
        case .note:   target = .notes; isFolder = false
        case .todo:   target = .tasks; isFolder = false
        case .list:   target = .lists; isFolder = false
        case .folder: target = .notes; isFolder = true // folder deep-link lands in Notes
        }
        router.focus = ActivityFocus(section: target, id: item.id, isFolder: isFolder)
        router.go(to: target)
    }

    // MARK: - Grouping

    /// Bucket items by local-day. Server delivers them newest-first already,
    /// so we just walk in order and group.
    private var groups: [DayGroup] {
        var result: [DayGroup] = []
        var current: DayGroup?
        let calendar = Calendar.current
        for item in viewModel.items {
            let key = calendar.startOfDay(for: item.createdAt)
            if current?.key != key {
                if let c = current { result.append(c) }
                current = DayGroup(key: key, items: [item])
            } else {
                current?.items.append(item)
            }
        }
        if let c = current { result.append(c) }
        return result
    }

    private func dayHeader(for group: DayGroup) -> some View {
        HStack(spacing: Space.sm) {
            Circle()
                .fill(Tokens.accentActivity)
                .frame(width: 6, height: 6)
            Text(formatDayHeader(group.key))
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(Tokens.inkSoft)
            Spacer()
        }
        .frame(height: 36)
        .padding(.horizontal, Space.lg)
        .background(
            Tokens.paper
                .opacity(0.95)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Tokens.divider).frame(height: 0.5)
                }
        )
    }
}

// MARK: - Day group helper

private struct DayGroup {
    let key: Date
    var items: [ActivityItem]
}

// MARK: - Filter chips

private struct FilterChipBar: View {
    let selected: ActivityViewModel.Filter
    let onSelect: (ActivityViewModel.Filter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                ForEach(ActivityViewModel.Filter.allCases) { filter in
                    let isActive = filter == selected
                    Button {
                        onSelect(filter)
                    } label: {
                        Text(filter.label)
                            .font(.edSubheadline)
                            .foregroundStyle(isActive ? Tokens.accentActivity : Tokens.inkSoft)
                            .padding(.horizontal, Space.md)
                            .frame(minHeight: 36)
                            .background(
                                Capsule().fill(isActive ? Tokens.accentActivity.opacity(0.12) : Tokens.paper2)
                            )
                            .overlay(
                                Capsule().stroke(
                                    isActive ? Tokens.accentActivity.opacity(0.35) : Tokens.border,
                                    lineWidth: 0.5
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
                }
            }
        }
    }
}

// MARK: - Row

private struct ActivityRow: View {
    let item: ActivityItem
    let onTap: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: Space.md) {
                tintedIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(1)
                    if let snippet = item.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.edSubheadline)
                            .foregroundStyle(Tokens.muted)
                            .lineLimit(1)
                    }
                    if item.type == .note, let parent = item.parent, !parent.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                            Text(parent)
                                .lineLimit(1)
                        }
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                    }
                }

                Spacer(minLength: Space.sm)

                Text(formatRelative(item.createdAt))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .accessibilityLabel(formatAbsolute(item.createdAt))
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .scaleEffect(pressed ? 0.99 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var tintedIcon: some View {
        let accent = iconAccent(for: item.type)
        return Image(systemName: iconName(for: item.type))
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(accent)
            .frame(width: 32, height: 32)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }

    private func iconName(for type: ActivityItem.ItemType) -> String {
        switch type {
        case .note:   return "note.text"
        case .todo:   return "checkmark.square"
        case .list:   return "list.bullet"
        case .folder: return "folder"
        }
    }

    private func iconAccent(for type: ActivityItem.ItemType) -> Color {
        switch type {
        case .note:   return Tokens.accentNotes
        case .todo:   return Tokens.accentTasks
        case .list:   return Tokens.accentLists
        case .folder: return Tokens.muted
        }
    }

    private var accessibilityLabel: String {
        let kind: String
        switch item.type {
        case .note:   kind = "Note"
        case .todo:   kind = "Task"
        case .list:   kind = "List"
        case .folder: kind = "Folder"
        }
        var parts = ["\(kind) created.", item.title.isEmpty ? "Untitled" : item.title]
        if let s = item.snippet, !s.isEmpty { parts.append(s) }
        if item.type == .note, let p = item.parent, !p.isEmpty {
            parts.append("In \(p) folder.")
        }
        parts.append(formatAbsolute(item.createdAt))
        return parts.joined(separator: " ")
    }
}

// MARK: - Skeletons

private struct FirstLoadSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<3, id: \.self) { groupIdx in
                if groupIdx > 0 {
                    Color.clear.frame(height: Space.xl)
                }
                // Day header bone
                HStack(spacing: Space.sm) {
                    Circle().fill(Tokens.paper2).frame(width: 6, height: 6)
                    PulseBone()
                        .frame(width: 80, height: 12)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Spacer()
                }
                .padding(.horizontal, Space.lg)
                .frame(height: 36)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Tokens.divider).frame(height: 0.5)
                }

                ForEach(0..<4, id: \.self) { rowIdx in
                    SkeletonRow()
                    if rowIdx < 3 {
                        Rectangle()
                            .fill(Tokens.divider)
                            .frame(height: 0.5)
                            .padding(.leading, Space.lg)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct NextPageSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            SkeletonRow()
            Rectangle().fill(Tokens.divider).frame(height: 0.5).padding(.leading, Space.lg)
            SkeletonRow()
        }
        .accessibilityHidden(true)
    }
}

private struct SkeletonRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: Space.md) {
            PulseBone()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                PulseBone()
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.trailing, 100) // simulate ~60% width
                PulseBone()
                    .frame(maxWidth: .infinity)
                    .frame(height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.trailing, 30)
            }

            PulseBone()
                .frame(width: 32, height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
}

/// 1.4s ease-in-out opacity pulse on `Tokens.paper2`. Honours the system
/// reduced-motion preference by holding at a static 55% opacity.
private struct PulseBone: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        Tokens.paper2
            .opacity(reduceMotion ? 0.55 : (animate ? 0.7 : 0.4))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let filter: ActivityViewModel.Filter

    var body: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: filter == .all ? "tray" : "line.3.horizontal.decrease")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text(headline)
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.inkSoft)
            Text(sub)
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.lg)
        }
        .padding(.vertical, Space.xxxl)
        .frame(maxWidth: .infinity)
    }

    private var headline: String {
        if filter == .all { return "Nothing here yet." }
        return "No \(filter.label.lowercased()) here yet."
    }

    private var sub: String {
        if filter == .all { return "Notes, todos, lists, and folders you create will show up here." }
        return "Switch to All to see everything."
    }
}

// MARK: - Date formatting helpers (file-private)

private func formatDayHeader(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()
    let today = calendar.startOfDay(for: now)
    let target = calendar.startOfDay(for: date)
    let days = calendar.dateComponents([.day], from: target, to: today).day ?? 0
    if days == 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    if days > 1 && days < 7 {
        return target.formatted(.dateTime.weekday(.wide))
    }
    let sameYear = calendar.component(.year, from: today) == calendar.component(.year, from: target)
    if sameYear {
        return target.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
    return target.formatted(.dateTime.day().month(.abbreviated).year())
}

private func formatRelative(_ date: Date) -> String {
    let now = Date()
    let diff = now.timeIntervalSince(date)
    if diff < 60 { return "now" }
    let minutes = Int(diff / 60)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    let target = calendar.startOfDay(for: date)
    let days = calendar.dateComponents([.day], from: target, to: today).day ?? 0
    if days == 1 { return "Yesterday" }
    if days < 7 {
        return target.formatted(.dateTime.weekday(.abbreviated))
    }
    let sameYear = calendar.component(.year, from: today) == calendar.component(.year, from: target)
    if sameYear {
        return target.formatted(.dateTime.day().month(.abbreviated))
    }
    return target.formatted(.dateTime.day().month(.abbreviated).year())
}

private func formatAbsolute(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}
