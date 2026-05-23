import SwiftUI
import SwiftData

/// Activity timeline surface (issue #16). Read-only chronological feed of
/// every note, todo, list, and folder the user has captured. Day-grouped rows
/// with sticky headers, deep-link to the owning section.
///
/// The feed reads directly from SwiftData via `@Query`, so any create / edit
/// / soft-delete on any surface (Tasks, Notes, Lists, AI capture, chat
/// confirm) updates the feed automatically without a pull-to-refresh.
struct ActivityView: View {
    enum Filter: Equatable, CaseIterable, Identifiable {
        case all, note, todo, list, folder

        var id: String {
            switch self {
            case .all:    return "all"
            case .note:   return "note"
            case .todo:   return "todo"
            case .list:   return "list"
            case .folder: return "folder"
            }
        }

        var label: String {
            switch self {
            case .all:    return "All"
            case .note:   return "Notes"
            case .todo:   return "Todos"
            case .list:   return "Lists"
            case .folder: return "Folders"
            }
        }

        var typeMatch: ActivityItem.ItemType? {
            switch self {
            case .all:    return nil
            case .note:   return .note
            case .todo:   return .todo
            case .list:   return .list
            case .folder: return .folder
            }
        }
    }

    @Bindable var router: AppRouter

    @Query(filter: #Predicate<LocalTodo> { $0.deletedAt == nil })
    private var todos: [LocalTodo]

    @Query(filter: #Predicate<LocalNote> { $0.deletedAt == nil })
    private var notes: [LocalNote]

    @Query(filter: #Predicate<LocalList> { $0.deletedAt == nil })
    private var lists: [LocalList]

    @Query(filter: #Predicate<LocalNoteFolder> { $0.deletedAt == nil })
    private var folders: [LocalNoteFolder]

    @State private var filter: Filter = .all
    @State private var visibleCount: Int = pageSize

    /// First page size and the increment per "load more" tap. Generous because
    /// SwiftData fetches are cheap and the dataset is small (single-device,
    /// personal scope).
    private static let pageSize = 100

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: "Activity",
                    onMenu: {
                        withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true }
                    }
                )

                Text("Everything you have captured, newest first.")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.sm)
                    .padding(.bottom, Space.sm)

                FilterChipBar(
                    selected: filter,
                    onSelect: { next in
                        guard next != filter else { return }
                        filter = next
                        visibleCount = Self.pageSize
                    }
                )
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)

                Divider().background(Tokens.divider)

                let pageItems = currentPageItems
                let total = totalAfterFilter

                ScrollView {
                    // Plain VStack (not LazyVStack) because the dataset is small
                    // (single-device personal scope, hundreds of items at most).
                    // LazyVStack + `pinnedViews: [.sectionHeaders]` triggered a
                    // SwiftUI layout bug where sections with varying row counts
                    // left reserved blank space until a gesture forced a layout
                    // pass. Issue #63.
                    VStack(alignment: .leading, spacing: 0) {
                        if pageItems.isEmpty {
                            EmptyStateView(filter: filter)
                                .frame(maxWidth: .infinity)
                                .padding(.top, Space.xxxl)
                        } else {
                            ForEach(groups(for: pageItems), id: \.key) { group in
                                dayHeader(for: group)
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

                            if pageItems.count < total {
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear {
                                        visibleCount += Self.pageSize
                                    }
                            }
                        }
                    }
                    .padding(.bottom, 96) // FAB clearance
                }
                .refreshable {
                    // @Query is already live; pull-to-refresh just resets the
                    // page window so the feed snaps back to the top.
                    visibleCount = Self.pageSize
                }
            }
        }
        .activeSection(.activity)
    }

    // MARK: - Combine + filter + paginate

    private var combinedItems: [ActivityItem] {
        var out: [ActivityItem] = []
        out.reserveCapacity(todos.count + notes.count + lists.count + folders.count)

        for todo in todos {
            out.append(ActivityItem(
                id: todo.clientUUID,
                type: .todo,
                title: todo.title,
                snippet: todo.todoDescription,
                parent: nil,
                sortDate: max(todo.createdAt, todo.updatedAt),
                createdAt: todo.createdAt
            ))
        }

        let folderNameByUUID: [UUID: String] = Dictionary(
            uniqueKeysWithValues: folders.map { ($0.clientUUID, $0.name) }
        )

        for note in notes {
            let parentName: String? = {
                guard let fid = note.folderClientUUID else { return nil }
                return folderNameByUUID[fid]
            }()
            out.append(ActivityItem(
                id: note.clientUUID,
                type: .note,
                title: note.title ?? "",
                snippet: note.content,
                parent: parentName,
                sortDate: max(note.createdAt, note.updatedAt),
                createdAt: note.createdAt
            ))
        }

        for list in lists {
            // Snippet: first 2-3 item texts, comma-separated. The list's
            // `updatedAt` already bumps when items change (ChecklistService.update),
            // so list-item additions naturally bubble the parent to the top.
            let snippet: String? = {
                let texts = list.items.prefix(3).map(\.text).filter { !$0.isEmpty }
                return texts.isEmpty ? nil : texts.joined(separator: ", ")
            }()
            out.append(ActivityItem(
                id: list.clientUUID,
                type: .list,
                title: list.title,
                snippet: snippet,
                parent: nil,
                sortDate: max(list.createdAt, list.updatedAt),
                createdAt: list.createdAt
            ))
        }

        for folder in folders {
            out.append(ActivityItem(
                id: folder.clientUUID,
                type: .folder,
                title: folder.name,
                snippet: nil,
                parent: nil,
                sortDate: max(folder.createdAt, folder.updatedAt),
                createdAt: folder.createdAt
            ))
        }

        let filtered: [ActivityItem]
        if let match = filter.typeMatch {
            filtered = out.filter { $0.type == match }
        } else {
            filtered = out
        }

        return filtered.sorted { $0.sortDate > $1.sortDate }
    }

    private var totalAfterFilter: Int { combinedItems.count }

    private var currentPageItems: [ActivityItem] {
        let all = combinedItems
        guard visibleCount < all.count else { return all }
        return Array(all.prefix(visibleCount))
    }

    // MARK: - Tap → deep-link

    private func handleTap(item: ActivityItem) {
        let target: AppSection
        let isFolder: Bool
        switch item.type {
        case .note:   target = .notes; isFolder = false
        case .todo:   target = .tasks; isFolder = false
        case .list:   target = .lists; isFolder = false
        case .folder: target = .notes; isFolder = true
        }
        router.focus = ActivityFocus(section: target, id: item.id, isFolder: isFolder)
        router.go(to: target)
    }

    // MARK: - Grouping

    private func groups(for items: [ActivityItem]) -> [DayGroup] {
        var result: [DayGroup] = []
        var current: DayGroup?
        let calendar = Calendar.current
        for item in items {
            // Day-bucket by the visible-row date (createdAt) so the header
            // matches the "1h ago" / "Yesterday" labels users see.
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
    let selected: ActivityView.Filter
    let onSelect: (ActivityView.Filter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                ForEach(ActivityView.Filter.allCases) { filter in
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
                        // Note snippets carry raw markdown; render inline
                        // and strip leading block prefixes so the row
                        // shows the formatted preview, not `## ` or `**`.
                        // Other types (todo, list) stay plain.
                        if item.type == .note {
                            Text(markdownSnippetAttributed(snippet))
                                .font(.edSubheadline)
                                .foregroundStyle(Tokens.muted)
                                .lineLimit(1)
                        } else {
                            Text(snippet)
                                .font(.edSubheadline)
                                .foregroundStyle(Tokens.muted)
                                .lineLimit(1)
                        }
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

// MARK: - Empty state

private struct EmptyStateView: View {
    let filter: ActivityView.Filter

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
