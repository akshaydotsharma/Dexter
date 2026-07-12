import SwiftUI

struct TodayView: View {
    @Bindable var router: AppRouter

    @State private var todosVM = TodosViewModel()
    @State private var notesVM = NotesViewModel()
    @State private var listsVM = ListsViewModel()

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: nil,
                    onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        header
                        tasksCard
                        notesCard
                        listsCard
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.lg)
                    .padding(.bottom, 96)
                }
                .refreshable { await loadAll() }
            }
        }
        .activeSection(.today)
        .task { await loadAll() }
    }

    private func loadAll() async {
        async let a: () = todosVM.load()
        async let b: () = notesVM.load()
        async let c: () = listsVM.load()
        _ = await (a, b, c)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(Self.dayString(Date()))
                .eyebrow()
            Text(Self.dateString(Date()))
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
            Text(Self.greeting)
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
                .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tasks card

    private var tasksCard: some View {
        let open = todosVM.todos.filter { !$0.completed }
        let dueTodayOrSoon = open.filter { isDueTodayOrOverdue($0.dueDate) }
        let preview = dueTodayOrSoon.isEmpty ? Array(open.prefix(5)) : Array(dueTodayOrSoon.prefix(5))

        return TodayCard(
            section: .tasks,
            title: "Tasks",
            count: open.count,
            countLabel: "open",
            isLoading: todosVM.isLoading && todosVM.todos.isEmpty,
            isEmpty: open.isEmpty,
            emptyText: "Inbox zero. Nice."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(preview.enumerated()), id: \.element.id) { idx, todo in
                    TodayTaskRow(
                        todo: todo,
                        onToggle: { Task { await todosVM.toggleCompleted(todo) } }
                    )
                    if idx < preview.count - 1 {
                        Rectangle()
                            .fill(Tokens.divider)
                            .frame(height: 0.5)
                            .padding(.leading, Space.lg)
                    }
                }
            }
        } footer: {
            TodayCardFooter(label: "All tasks") {
                router.go(to: .tasks)
            }
        }
    }

    // MARK: - Notes card

    private var notesCard: some View {
        let recent = notesVM.notes.sorted(by: { $0.updatedAt > $1.updatedAt }).prefix(3)

        return TodayCard(
            section: .notes,
            title: "Notes",
            count: notesVM.notes.count,
            countLabel: "recent",
            isLoading: notesVM.isLoading && notesVM.notes.isEmpty,
            isEmpty: notesVM.notes.isEmpty,
            emptyText: "No notes yet."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { idx, note in
                    TodayNoteRow(note: note)
                    if idx < recent.count - 1 {
                        Rectangle()
                            .fill(Tokens.divider)
                            .frame(height: 0.5)
                            .padding(.leading, Space.lg)
                    }
                }
            }
        } footer: {
            TodayCardFooter(label: "All notes") {
                router.go(to: .notes)
            }
        }
    }

    // MARK: - Lists card

    private var listsCard: some View {
        let active = listsVM.lists
            .filter { !$0.items.isEmpty && $0.items.contains(where: { !$0.checked }) }
            .sorted(by: { $0.createdAt > $1.createdAt })
            .prefix(3)

        return TodayCard(
            section: .lists,
            title: "Lists",
            count: active.count,
            countLabel: "active",
            isLoading: listsVM.isLoading && listsVM.lists.isEmpty,
            isEmpty: listsVM.lists.isEmpty,
            emptyText: "No lists yet."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(active.enumerated()), id: \.element.id) { idx, list in
                    TodayListRow(list: list)
                    if idx < active.count - 1 {
                        Rectangle()
                            .fill(Tokens.divider)
                            .frame(height: 0.5)
                            .padding(.leading, Space.lg)
                    }
                }
            }
        } footer: {
            TodayCardFooter(label: "All lists") {
                router.go(to: .lists)
            }
        }
    }

    // MARK: - Helpers

    private func isDueTodayOrOverdue(_ date: Date?) -> Bool {
        guard let date else { return false }
        let cal = Calendar.current
        return cal.isDateInToday(date) || date < Date()
    }

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return f.string(from: date)
    }

    private static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning."
        case 12..<17: return "Good afternoon."
        case 17..<22: return "Good evening."
        default:      return "Working late."
        }
    }
}

// MARK: - Card

private struct TodayCard<Content: View, Footer: View>: View {
    let section: AppSection
    let title: String
    let count: Int
    let countLabel: String
    let isLoading: Bool
    let isEmpty: Bool
    let emptyText: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Text(title.uppercased())
                    .eyebrow()
                if !isLoading && !isEmpty {
                    Text("·")
                        .eyebrow()
                    Text("\(count) \(countLabel)")
                        .eyebrow()
                }
                Spacer()
            }
            .padding(.horizontal, Space.xs)

            VStack(spacing: 0) {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().tint(Tokens.muted)
                        Spacer()
                    }
                    .padding(.vertical, Space.xl)
                } else if isEmpty {
                    Text(emptyText)
                        .font(.edBody)
                        .foregroundStyle(Tokens.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.xl)
                } else {
                    content
                }

                if !isLoading && !isEmpty {
                    Rectangle()
                        .fill(Tokens.divider)
                        .frame(height: 0.5)
                    footer
                }
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .paperBorder()
        }
    }
}

private struct TodayCardFooter: View {
    let label: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(label)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Tokens.muted)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rows

private struct TodayTaskRow: View {
    let todo: Todo
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Button(action: onToggle) {
                Image(systemName: todo.completed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(todo.completed ? Tokens.accentTasks : Tokens.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Map the glyph's center (with a 4pt body-font offset for x-height) to the
            // firstTextBaseline so the checkbox visually centers on the title's first line.
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }

            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .strikethrough(todo.completed, color: Tokens.muted)
                    .lineLimit(2)

                if let due = todo.dueDate {
                    Text(dueLabel(due))
                        .font(.edCaption)
                        .foregroundStyle(isOverdue(due) ? Tokens.danger : Tokens.muted)
                }
            }

            Spacer()
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        // Thin colored left-edge bar keyed to priority, matching the Tasks screen.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Tokens.priorityColor(for: todo.taskPriority))
                .frame(width: Space.xs)
        }
    }

    private func isOverdue(_ date: Date) -> Bool {
        date < Calendar.current.startOfDay(for: Date())
    }

    private func dueLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) { return "Due today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

private struct TodayNoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
            Text(relativeTime(note.updatedAt))
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }

    // When the note has no title, fall back to a one-line snippet of the
    // body with inline markdown rendered and block prefixes stripped so
    // the row doesn't lead with `## ` or `- `.
    private var displayTitle: AttributedString {
        if let t = note.title, !t.isEmpty { return AttributedString(t) }
        if let c = note.content, !c.isEmpty { return markdownSnippetAttributed(c) }
        return AttributedString("Untitled note")
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Updated \(f.localizedString(for: date, relativeTo: Date()))"
    }
}

private struct TodayListRow: View {
    let list: Checklist

    var body: some View {
        let total = list.items.count
        let done = list.items.filter(\.checked).count

        let accent = list.resolvedColor
        HStack(spacing: Space.md) {
            ListIconChip(icon: list.resolvedIcon, color: accent, size: 30, corner: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(list.title)
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Text("\(done) of \(total)")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }

            Spacer()

            ProgressBar(done: done, total: total, color: accent)
                .frame(width: 80, height: 4)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
}

private struct ProgressBar: View {
    let done: Int
    let total: Int
    var color: Color = Tokens.accentLists

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Tokens.paper2)
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: geo.size.width * progress)
            }
        }
    }

    private var progress: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(done) / CGFloat(total)
    }
}
