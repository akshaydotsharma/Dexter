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
        case all, note, todo, list, folder, trips, finance

        var id: String {
            switch self {
            case .all:     return "all"
            case .note:    return "note"
            case .todo:    return "todo"
            case .list:    return "list"
            case .folder:  return "folder"
            case .trips:   return "trips"
            case .finance: return "finance"
            }
        }

        var label: String {
            switch self {
            case .all:     return "All"
            case .note:    return "Notes"
            case .todo:    return "Todos"
            case .list:    return "Lists"
            case .folder:  return "Folders"
            case .trips:   return "Trips"
            case .finance: return "Finance"
            }
        }

        /// Whether a given row type belongs under this chip. Finance folds the
        /// two expense flavours (individual + collapsed statement) into one
        /// chip; Trips maps to itinerary rows.
        func includes(_ type: ActivityItem.ItemType) -> Bool {
            switch self {
            case .all:     return true
            case .note:    return type == .note
            case .todo:    return type == .todo
            case .list:    return type == .list
            case .folder:  return type == .folder
            case .trips:   return type == .itinerary
            case .finance: return type == .expense || type == .statement
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

    // Expenses and itinerary items are hard-deleted (no `deletedAt` field —
    // FinanceView / TripDetailView query them the same way), so there are no
    // soft-deleted rows to exclude. Trips power the itinerary parent-chip
    // (trip name) + deep-link target lookup.
    @Query private var expenses: [LocalExpense]

    @Query private var itineraryItems: [LocalItineraryItem]

    @Query private var trips: [LocalTrip]

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

        // Itinerary items: one row each, parent chip = trip name, deep-link to
        // the owning trip. Snippet is the kind (+ start time when present).
        let tripNameByUUID: [UUID: String] = Dictionary(
            trips.map { ($0.clientUUID, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        for item in itineraryItems {
            let kindLabel = item.kindEnum.displayName
            let snippet: String? = {
                guard let start = item.startTime else { return kindLabel }
                return "\(kindLabel) · \(start.formatted(date: .omitted, time: .shortened))"
            }()
            out.append(ActivityItem(
                id: item.clientUUID,
                type: .itinerary,
                title: item.title,
                snippet: snippet,
                parent: tripNameByUUID[item.tripUUID],
                // Activity = when the item was added, like expenses. Using
                // createdAt (not max with updatedAt) keeps a yesterday booking
                // from resurfacing at the top of Today when its trip is touched.
                sortDate: item.createdAt,
                createdAt: item.createdAt,
                tripUUID: item.tripUUID
            ))
        }

        // Expenses. EVERY PDF-source expense collapses into ONE `.statement`
        // row so a statement upload never explodes the feed — the user only
        // wants the statement itself, not each parsed line. The group key +
        // title prefer the imported file name, fall back to the parsed
        // attribution label, and finally to the import day (rows imported
        // before file-name capture existed, or statements whose header couldn't
        // be read, so both fields are empty). Every non-PDF expense (manual /
        // chat / voice / photo / email receipt) stays an individual `.expense`
        // row. `groupKey` gives each statement row a stable identity across
        // feed recomputes.
        var statementGroups: [String: (title: String, rows: [LocalExpense])] = [:]

        for expense in expenses {
            if expense.sourceEnum == .pdf {
                let fileName = expense.statementFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = expense.statementLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                let key: String
                let title: String
                if !fileName.isEmpty {
                    key = "file:\(fileName)"; title = fileName
                } else if !label.isEmpty {
                    key = "label:\(label)"; title = label
                } else {
                    let day = Calendar.current.startOfDay(for: expense.createdAt)
                    key = "day:\(day.timeIntervalSince1970)"; title = "Statement import"
                }
                if statementGroups[key] == nil {
                    statementGroups[key] = (title, [expense])
                } else {
                    statementGroups[key]?.rows.append(expense)
                }
                continue
            }
            out.append(ActivityItem(
                id: UUID(uuidString: expense.clientUUID) ?? UUID(),
                type: .expense,
                title: expenseTitle(expense),
                snippet: expenseSnippet(expense),
                parent: nil,
                // LocalExpense has no `updatedAt`; createdAt is the only bump.
                sortDate: expense.createdAt,
                createdAt: expense.createdAt
            ))
        }

        for (key, group) in statementGroups {
            let rows = group.rows
            let maxCreated = rows.map(\.createdAt).max() ?? Date()
            // Representative id = the newest expense in the group (stable across
            // recomputes); rowKey keys off `key` via groupKey.
            let representative = rows.max(by: { $0.createdAt < $1.createdAt })
            let count = rows.count
            out.append(ActivityItem(
                id: representative.flatMap { UUID(uuidString: $0.clientUUID) } ?? UUID(),
                type: .statement,
                title: group.title,
                snippet: "\(count) expense\(count == 1 ? "" : "s")",
                parent: nil,
                sortDate: maxCreated,
                createdAt: maxCreated,
                groupKey: key
            ))
        }

        let filtered = out.filter { filter.includes($0.type) }
        return filtered.sorted { $0.sortDate > $1.sortDate }
    }

    private var totalAfterFilter: Int { combinedItems.count }

    private var currentPageItems: [ActivityItem] {
        let all = combinedItems
        guard visibleCount < all.count else { return all }
        return Array(all.prefix(visibleCount))
    }

    // MARK: - Expense row text

    /// Title for an individual expense row. Merchant first (task spec); falls
    /// back to the free-form description, then the category, so a row never
    /// renders as "Untitled".
    private func expenseTitle(_ expense: LocalExpense) -> String {
        if let merchant = expense.merchant?.trimmingCharacters(in: .whitespacesAndNewlines), !merchant.isEmpty {
            return merchant
        }
        if let desc = expense.expenseDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            return desc
        }
        return expense.categoryEnum.displayName
    }

    /// Snippet for an individual expense row: SGD amount + category, matching
    /// the Finance surface's formatting (`FinanceDashboardBand.formatMoney`).
    private func expenseSnippet(_ expense: LocalExpense) -> String {
        "\(FinanceDashboardBand.formatMoney(expense.sgdAmount)) · \(expense.categoryEnum.displayName)"
    }

    // MARK: - Tap → deep-link

    private func handleTap(item: ActivityItem) {
        switch item.type {
        case .note:
            router.focus = ActivityFocus(section: .notes, id: item.id, isFolder: false)
            router.go(to: .notes)
        case .todo:
            router.focus = ActivityFocus(section: .tasks, id: item.id, isFolder: false)
            router.go(to: .tasks)
        case .list:
            router.focus = ActivityFocus(section: .lists, id: item.id, isFolder: false)
            router.go(to: .lists)
        case .folder:
            router.focus = ActivityFocus(section: .notes, id: item.id, isFolder: true)
            router.go(to: .notes)
        case .itinerary:
            // Deep-link into the owning trip. ItinerariesView consumes a
            // `.itineraries` focus whose id is the trip UUID and opens that
            // trip's detail. Falls back to the Itineraries root if the trip
            // can't be resolved.
            if let tripUUID = item.tripUUID {
                router.focus = ActivityFocus(section: .itineraries, id: tripUUID, isFolder: false)
            }
            router.go(to: .itineraries)
        case .expense, .statement:
            router.go(to: .finance)
        }
    }

    // MARK: - Grouping

    private func groups(for items: [ActivityItem]) -> [DayGroup] {
        var result: [DayGroup] = []
        var current: DayGroup?
        let calendar = Calendar.current
        for item in items {
            // Day-bucket by the SAME date the feed is sorted by (sortDate).
            // Grouping by a different date than the sort produces
            // non-contiguous day groups that share a `key`; the outer
            // `ForEach(groups, id: \.key)` then sees duplicate ids and SwiftUI
            // duplicates / drops rows. Keying on sortDate guarantees contiguous,
            // uniquely-keyed groups because the list is already sorted by it.
            let key = calendar.startOfDay(for: item.sortDate)
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
                    if let parent = item.parent, !parent.isEmpty,
                       item.type == .note || item.type == .itinerary {
                        HStack(spacing: 4) {
                            Image(systemName: item.type == .itinerary ? "airplane" : "folder")
                                .font(.system(size: 10))
                            Text(parent)
                                .lineLimit(1)
                        }
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                    }
                }

                Spacer(minLength: Space.sm)

                // Timestamp mirrors the sort/group key so the row's relative
                // label always agrees with its day header.
                Text(formatRelative(item.sortDate))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                    .accessibilityLabel(formatAbsolute(item.sortDate))
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
        case .note:      return "note.text"
        case .todo:      return "checkmark.square"
        case .list:      return "list.bullet"
        case .folder:    return "folder"
        case .itinerary: return "airplane"
        case .expense:   return "creditcard"
        case .statement: return "doc.text"
        }
    }

    private func iconAccent(for type: ActivityItem.ItemType) -> Color {
        switch type {
        case .note:      return Tokens.accentNotes
        case .todo:      return Tokens.accentTasks
        case .list:      return Tokens.accentLists
        case .folder:    return Tokens.muted
        case .itinerary: return Tokens.accentItineraries
        case .expense:   return Tokens.accentFinance
        case .statement: return Tokens.accentFinance
        }
    }

    private var accessibilityLabel: String {
        let kind: String
        switch item.type {
        case .note:      kind = "Note"
        case .todo:      kind = "Task"
        case .list:      kind = "List"
        case .folder:    kind = "Folder"
        case .itinerary: kind = "Itinerary item"
        case .expense:   kind = "Expense"
        case .statement: kind = "Statement import"
        }
        var parts = ["\(kind) created.", item.title.isEmpty ? "Untitled" : item.title]
        if let s = item.snippet, !s.isEmpty { parts.append(s) }
        if item.type == .note, let p = item.parent, !p.isEmpty {
            parts.append("In \(p) folder.")
        }
        if item.type == .itinerary, let p = item.parent, !p.isEmpty {
            parts.append("Trip: \(p).")
        }
        parts.append(formatAbsolute(item.sortDate))
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
        if filter == .all { return "Notes, todos, lists, folders, trips, and expenses you capture will show up here." }
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
