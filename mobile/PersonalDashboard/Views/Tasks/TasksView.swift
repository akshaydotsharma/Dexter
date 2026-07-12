import SwiftUI
import Combine

struct TasksView: View {
    @State private var viewModel = TodosViewModel()
    @State private var showingEditor = false
    @State private var editingTodo: Todo?
    @State private var completedExpanded: Bool = false
    // Per-section tap-below inline draft state.
    // draftBucket == nil → no draft active; non-nil → draft in that section.
    private enum DraftBucket: String { case today, tomorrow, thisWeek, later, noDate }
    @State private var draftBucket: DraftBucket? = nil
    @State private var draftText: String = ""
    @FocusState private var draftFocused: Bool

    @Bindable var router: AppRouter

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: "Tasks",
                    onMenu: {
                        withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true }
                    }
                )

                // Using `List` (not `ScrollView { LazyVStack }`) so each row
                // can opt into native `.swipeActions`. The list is dressed
                // down to keep the editorial paper styling: clear row
                // backgrounds, hidden separators, and `.scrollContentBackground`
                // hidden so `Tokens.paper` shows through.
                List {
                    if viewModel.isLoading && viewModel.todos.isEmpty {
                        placeholderRow("Loading…")
                    } else if viewModel.todos.isEmpty {
                        // Empty-state: single tap-below that seeds a No Date task.
                        placeholderRow("No tasks yet. Tap below to start.")
                        emptyStateDraftRow
                    } else {
                        taskGroups
                    }

                    // FAB clearance — keeps the last row scrollable above the floating + button.
                    // Also acts as a tap-to-dismiss zone for any active inline draft.
                    Color.clear
                        .frame(height: 96)
                        .contentShape(Rectangle())
                        // Commit any in-progress edit: draftFocused = false covers the
                        // tap-below draft; hideKeyboard() covers a focused task row.
                        .onTapGesture { draftFocused = false; hideKeyboard() }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
                .listStyle(.plain)
                .listSectionSpacing(0)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
                .refreshable { await viewModel.load() }
            }

            Button {
                showingEditor = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
            .padding(.trailing, 22)
            .padding(.bottom, BottomTabBarMetrics.height + Space.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            // Hide the FAB while an inline draft is active — the user is already
            // adding a task inline, so the FAB is redundant and visually distracting.
            .opacity(draftBucket == nil ? 1 : 0)
            .allowsHitTesting(draftBucket == nil)
            .animation(.easeOut(duration: 0.15), value: draftBucket)
        }
        .activeSection(.tasks)
        // Live-refresh when the voice-capture or chat path writes a task.
        .onReceive(NotificationCenter.default.publisher(for: .localStoreDidChange)) { _ in
            Task { await viewModel.load() }
        }
        .task { await viewModel.load() }
        .onAppear {
            // Activity timeline deep-link consumption. The Activity surface
            // sets `router.focus` to ActivityFocus(section: .tasks, id: clientUUID)
            // before pushing the section. Scroll + pulse on the matching row
            // is a follow-up; for now we clear the field so the focus doesn't
            // fire again on the next appearance.
            if router.focus?.section == .tasks {
                router.focus = nil
            }
        }
        .sheet(isPresented: $showingEditor) {
            TaskEditorSheet(viewModel: viewModel, todo: nil)
        }
        .sheet(item: $editingTodo) { todo in
            TaskEditorSheet(viewModel: viewModel, todo: todo)
        }
        .alert("Couldn't load tasks",
               isPresented: Binding(
                   get: { viewModel.errorMessage != nil },
                   set: { if !$0 { viewModel.errorMessage = nil } }
               )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Tap-below helpers

    private func startDraft(in bucket: DraftBucket) {
        draftBucket = bucket
        draftText = ""
        // Give the List time to insert DraftTaskRow before focusing.
        DispatchQueue.main.async { draftFocused = true }
    }

    /// Commits the current draftText as a new task in the active bucket.
    /// - keepFocus: true = chain creation (Return key); false = dismiss (focus-loss path).
    private func commitDraft(keepFocus: Bool) {
        guard let bucket = draftBucket else { return }
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draftBucket = nil
            draftFocused = false
            return
        }
        let due = suggestedDueDate(for: bucket)
        Task { await viewModel.create(title: trimmed, dueDate: due) }
        if keepFocus {
            draftText = ""
            DispatchQueue.main.async { draftFocused = true }
        } else {
            draftBucket = nil
            draftFocused = false
        }
    }

    private func suggestedDueDate(for bucket: DraftBucket) -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        switch bucket {
        case .today:
            return cal.date(bySettingHour: 23, minute: 0, second: 0, of: today)
        case .tomorrow:
            let eod = cal.date(bySettingHour: 23, minute: 0, second: 0, of: today)!
            return cal.date(byAdding: .day, value: 1, to: eod)
        case .thisWeek:
            let eod = cal.date(bySettingHour: 23, minute: 0, second: 0, of: today)!
            return cal.date(byAdding: .day, value: 3, to: eod)
        case .later:
            let eod = cal.date(bySettingHour: 23, minute: 0, second: 0, of: today)!
            return cal.date(byAdding: .day, value: 14, to: eod)
        case .noDate:
            return nil
        }
    }

    // Empty-state fallback: single tap-below seeding a No Date task.
    @ViewBuilder
    private var emptyStateDraftRow: some View {
        if draftBucket == .noDate {
            DraftTaskRow(
                text: $draftText,
                isFocused: $draftFocused,
                onSubmit: { commitDraft(keepFocus: true) },
                onFocusLost: { commitDraft(keepFocus: false) }
            )
            // Same height-stabilisation as the per-section draft rows: lock to 60pt
            // so swapping the empty-state tap-zone for the draft row doesn't jump.
            .frame(minHeight: 60)
            .padding(.horizontal, Space.lg)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        } else {
            Color.clear
                .frame(minHeight: 120)
                .contentShape(Rectangle())
                .onTapGesture { startDraft(in: .noDate) }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
        }
    }

    // MARK: - All caught up

    /// Celebratory empty state shown when every open task is complete but the
    /// Completed section still holds rows. Without this, `taskGroups` renders
    /// only the Completed header's hairline + collapsed toggle — a floating
    /// line with nothing above it that reads as broken. Reuses the inline-draft
    /// mechanism (`startDraft(in: .noDate)`) for the quick-add affordance, so
    /// tapping it seeds an undated task via the same path as every other
    /// section's tap-below.
    @ViewBuilder
    private var allCaughtUpRow: some View {
        VStack(spacing: Space.lg) {
            // Celebratory block — matches the shared empty-state template
            // (icon 28pt / muted, .edHeading / ink).
            VStack(spacing: Space.md) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Tokens.muted)
                Text("All caught up")
                    .font(.edHeading)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.center)
            }

            // Quick-add: reuses the inline-draft flow. Tapping flips
            // draftBucket to .noDate, which hides this state (draftBucket != nil)
            // and surfaces the DraftTaskRow inside the "No Date" section below.
            Button {
                startDraft(in: .noDate)
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Add a task")
                        .font(.edBodyMedium)
                }
                .foregroundStyle(Tokens.muted)
                .padding(.vertical, Space.sm)
                .padding(.horizontal, Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a task")
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, Space.xxxl)
        .padding(.horizontal, Space.lg)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    // MARK: - Grouped tasks

    @ViewBuilder
    private var taskGroups: some View {
        let buckets = computeBuckets()
        // Every open bucket empty, no inline draft in flight, but completed
        // tasks remain → show the celebratory "all caught up" state above the
        // Completed section. Guarded on completed being non-empty; the
        // genuinely-empty case is handled by the body's `todos.isEmpty` branch.
        let hasOpenTasks = !buckets.overdue.isEmpty
            || !buckets.today.isEmpty
            || !buckets.thisWeek.isEmpty
            || !buckets.later.isEmpty
            || !buckets.noDate.isEmpty
        if !hasOpenTasks && draftBucket == nil && !buckets.completed.isEmpty {
            allCaughtUpRow
        }
        // Overdue: no tap-below (adding a new overdue task is incoherent).
        if !buckets.overdue.isEmpty {
            taskSection(title: "Overdue", count: buckets.overdue.count, accent: Tokens.danger, soft: Tokens.dangerSoft, todos: buckets.overdue, bucket: nil)
        }
        if !buckets.today.isEmpty || draftBucket == .today {
            taskSection(title: "Today", count: buckets.today.count, accent: Tokens.warning, soft: Tokens.warningSoft, todos: buckets.today, bucket: .today)
        }
        if !buckets.tomorrow.isEmpty || draftBucket == .tomorrow {
            taskSection(title: "Tomorrow", count: buckets.tomorrow.count, accent: Tokens.info, soft: Tokens.paper2, todos: buckets.tomorrow, bucket: .tomorrow)
        }
        if !buckets.thisWeek.isEmpty || draftBucket == .thisWeek {
            taskSection(title: "This Week", count: buckets.thisWeek.count, accent: Tokens.inkSoft, soft: Tokens.paper2, todos: buckets.thisWeek, bucket: .thisWeek)
        }
        if !buckets.later.isEmpty || draftBucket == .later {
            taskSection(title: "Later", count: buckets.later.count, accent: Tokens.inkSoft, soft: Tokens.paper2, todos: buckets.later, bucket: .later)
        }
        if !buckets.noDate.isEmpty || draftBucket == .noDate {
            taskSection(title: "No Date", count: buckets.noDate.count, accent: Tokens.muted, soft: Tokens.paper2, todos: buckets.noDate, bucket: .noDate)
        }
        if !buckets.completed.isEmpty {
            completedSection(buckets.completed)
        }
    }

    private struct TaskBuckets {
        var overdue: [Todo] = []
        var today: [Todo] = []
        var tomorrow: [Todo] = []
        var thisWeek: [Todo] = []
        var later: [Todo] = []
        var noDate: [Todo] = []
        var completed: [Todo] = []
    }

    /// Sort order shared by every open bucket: soonest due time on top
    /// ("next event first"), later times below. Tasks without a due date (the
    /// "No Date" bucket) order among themselves by creation time, oldest first;
    /// createdAt (ascending) is also the tiebreaker when two tasks share a due
    /// time. The colored priority bar still renders on each row — it no longer
    /// affects ordering.
    private func chronoSorted(_ todos: [Todo]) -> [Todo] {
        todos.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (da?, db?):
                if da != db { return da < db }
                return a.createdAt < b.createdAt
            case (nil, nil):
                return a.createdAt < b.createdAt
            case (_?, nil):
                return true   // a task with a due date sorts before one without
            case (nil, _?):
                return false
            }
        }
    }

    private func computeBuckets() -> TaskBuckets {
        let now = Date()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let dayAfterTomorrow = cal.date(byAdding: .day, value: 2, to: today)!
        let weekEnd = cal.date(byAdding: .day, value: 7, to: today)!

        var b = TaskBuckets()
        b.completed = viewModel.todos.filter { $0.completed }
        let open = viewModel.todos.filter { !$0.completed }
        for todo in open {
            guard let due = todo.dueDate else { b.noDate.append(todo); continue }
            if due < today { b.overdue.append(todo) }
            else if due < tomorrow { b.today.append(todo) }
            else if due < dayAfterTomorrow { b.tomorrow.append(todo) }
            else if due < weekEnd { b.thisWeek.append(todo) }
            else { b.later.append(todo) }
        }
        b.overdue = chronoSorted(b.overdue)
        b.today = chronoSorted(b.today)
        b.tomorrow = chronoSorted(b.tomorrow)
        b.thisWeek = chronoSorted(b.thisWeek)
        b.later = chronoSorted(b.later)
        b.noDate = chronoSorted(b.noDate)
        return b
    }

    /// Renders a task section with an optional per-section tap-below affordance.
    /// Pass `bucket: nil` for sections that should not have tap-below (e.g. Overdue).
    @ViewBuilder
    private func taskSection(title: String, count: Int, accent: Color, soft: Color, todos: [Todo], bucket: DraftBucket?) -> some View {
        Section {
            ForEach(todos) { todo in
                TaskRow(
                    todo: todo,
                    isDraftActive: draftBucket != nil,
                    onToggle: { Task { await viewModel.toggleCompleted(todo) } },
                    onInfoTap: { editingTodo = todo },
                    onTitleCommit: { newTitle in
                        Task { await viewModel.update(todo, title: newTitle, description: todo.description, dueDate: todo.dueDate, tag: todo.tag) }
                    },
                    onTapWhileDraftActive: { draftFocused = false }
                )
                .swipeToDeleteTrash {
                    Task { await viewModel.delete(todo) }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: Space.lg, bottom: 2, trailing: Space.lg))
            }

            // Tap-below affordance for this section (skipped for Overdue).
            if let bucket {
                if draftBucket == bucket {
                    DraftTaskRow(
                        text: $draftText,
                        isFocused: $draftFocused,
                        onSubmit: { commitDraft(keepFocus: true) },
                        onFocusLost: { commitDraft(keepFocus: false) }
                    )
                    // Match the tap-zone's 40pt height exactly so swapping clear→draft
                    // doesn't shift the "No Date" header (and everything below) by ~16pt
                    // as the keyboard appears. EdgeInsets() + .padding(.horizontal, Space.lg)
                    // at the call site reproduces the same leading/trailing gutter as
                    // the existing TaskRow rows (.listRowInsets leading/trailing Space.lg
                    // + internal .padding(.horizontal, Space.md)).
                    .frame(minHeight: 40)
                    .padding(.horizontal, Space.lg)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                } else {
                    // Visible ghost add-row (#268): section-level hairline + outline
                    // plus.circle on the checkbox column. 40pt matches the draft row
                    // height so swapping ghost → draft doesn't shift the layout.
                    // Zero listRowInsets — GhostAddRow owns its own insets so its
                    // divider aligns with the Completed separator.
                    GhostAddRow(label: "New Task", minHeight: 40) { startDraft(in: bucket) }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
            }
        } header: {
            sectionHeader(title: title, count: count, accent: accent, soft: soft)
        }
    }

    @ViewBuilder
    private func completedSection(_ todos: [Todo]) -> some View {
        Section {
            if completedExpanded {
                ForEach(todos) { todo in
                    TaskRow(
                        todo: todo,
                        isDraftActive: draftBucket != nil,
                        onToggle: { Task { await viewModel.toggleCompleted(todo) } },
                        onInfoTap: { editingTodo = todo },
                        onTitleCommit: { newTitle in
                            Task { await viewModel.update(todo, title: newTitle, description: todo.description, dueDate: todo.dueDate, tag: todo.tag) }
                        },
                        onTapWhileDraftActive: { draftFocused = false }
                    )
                    .swipeToDeleteTrash {
                        Task { await viewModel.delete(todo) }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: Space.lg, bottom: 2, trailing: Space.lg))
                }
            }
        } header: {
            VStack(spacing: 0) {
                // Hairline demarcating the boundary between open and completed tasks.
                Rectangle()
                    .fill(Tokens.border)
                    .frame(height: 1)
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)

                Button {
                    withAnimation(.easeOut(duration: 0.2)) { completedExpanded.toggle() }
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: completedExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Tokens.muted)
                        Text("Completed")
                            .font(.edHeading)
                            .foregroundStyle(Tokens.muted)
                        Text("\(todos.count)")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .padding(.horizontal, Space.sm)
                            .padding(.vertical, 2)
                            .background(Tokens.paper2, in: Capsule())
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .textCase(nil)
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
                .padding(.bottom, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Commit any in-progress edit alongside the expand/collapse toggle so the
                // keyboard collapses when the user taps the Completed header: draftFocused = false
                // covers the tap-below draft; hideKeyboard() covers a focused task row.
                .simultaneousGesture(TapGesture().onEnded { draftFocused = false; hideKeyboard() })
            }
            .background(Tokens.paper)
        }
    }

    private func sectionHeader(title: String, count: Int, accent: Color, soft: Color) -> some View {
        HStack(spacing: Space.sm) {
            Text(title)
                .font(.edHeading)
                .foregroundStyle(accent)
            Text("\(count)")
                .font(.edCaption)
                .foregroundStyle(accent)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 2)
                .background(soft, in: Capsule())
            Spacer()
        }
        .textCase(nil)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.paper)
        // Tapping a section header commits any in-progress edit: draftFocused = false
        // covers the tap-below draft; hideKeyboard() covers a focused task row.
        .contentShape(Rectangle())
        .onTapGesture { draftFocused = false; hideKeyboard() }
    }

    private func placeholderRow(_ text: String) -> some View {
        Text(text)
            .font(.edBody)
            .foregroundStyle(Tokens.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Space.xxxl)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: Space.lg, bottom: 0, trailing: Space.lg))
    }
}

// MARK: - Inline draft row

/// Inline draft row that appears when the user taps below the last task.
/// Mirrors the visual shape of TaskRow: stroked circle bullet + text field.
private struct DraftTaskRow: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onFocusLost: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            // Empty stroked circle — identical to TaskRow's unchecked bullet.
            Circle()
                .stroke(Tokens.borderStrong, lineWidth: 2)
                .frame(width: 22, height: 22)
                .frame(width: 24, height: 24)
                // Align circle center to firstTextBaseline as TaskRow does.
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }

            TextField("New task", text: $text)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .submitLabel(.return)
                .focused(isFocused)
                .onSubmit { onSubmit() }
                .onChange(of: isFocused.wrappedValue) { _, nowFocused in
                    if !nowFocused { onFocusLost() }
                }
                .accessibilityLabel("New task")

            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.md)
        .contentShape(Rectangle())
    }
}

// MARK: - Row

private struct TaskRow: View {
    let todo: Todo
    /// When a tap-below draft is active, suppress opening the editor sheet so the tap
    /// only dismisses the draft keyboard — nothing re-steals first responder.
    var isDraftActive: Bool = false
    let onToggle: () -> Void
    /// Tapping the trailing info icon opens the full editor sheet.
    let onInfoTap: () -> Void
    /// Inline title commit (tap row body → edit title → submit / focus loss).
    let onTitleCommit: (String) -> Void
    /// Called back to the parent when this row is tapped while a draft is active,
    /// so the parent can flip draftFocused = false and trigger the focus-loss → commitDraft cycle.
    var onTapWhileDraftActive: () -> Void = {}

    @State private var isEditing: Bool = false
    @State private var editText: String = ""
    @FocusState private var titleFocused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            // Empty Button action: the high-priority tap gesture below is the single
            // source of the toggle. This guarantees one toggle per tap even while the
            // inline field is focused (iOS's "first tap dismisses keyboard" would
            // otherwise eat a plain row/Button tap).
            Button(action: {}) {
                ZStack {
                    Circle()
                        .stroke(todo.completed ? Tokens.success : Tokens.borderStrong, lineWidth: 2)
                        .background(todo.completed ? Tokens.success.clipShape(Circle()) : nil)
                        .frame(width: 22, height: 22)
                    if todo.completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Tokens.paper)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .highPriorityGesture(TapGesture().onEnded { handleToggle() })
            // Map the circle's center (with a 4pt body-font offset for x-height) to the
            // firstTextBaseline so the bullet visually centers on the title's first line.
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            .accessibilityLabel(todo.completed ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("", text: $editText)
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                        .submitLabel(.done)
                        .focused($titleFocused)
                        .onSubmit { commitInlineEdit() }
                        .onChange(of: titleFocused) { _, nowFocused in
                            if !nowFocused { commitInlineEdit() }
                        }
                } else {
                    Text(todo.title)
                        .font(.edBody)
                        .strikethrough(todo.completed)
                        .foregroundStyle(todo.completed ? Tokens.mutedSoft : Tokens.ink)
                        .multilineTextAlignment(.leading)
                }

                if let desc = todo.description, !desc.isEmpty {
                    Text(desc)
                        .font(.edSubheadline)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                }

                if !todo.address.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 10))
                        Text(todo.address)
                            .lineLimit(2)
                    }
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                }

                let hasTag = todo.tag != nil && !(todo.tag?.isEmpty ?? true)
                if todo.dueDate != nil || hasTag || todo.mapsURL != nil {
                    HStack(spacing: Space.sm) {
                        if let due = todo.dueDate {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 10))
                                Text(due, format: .dateTime.month(.abbreviated).day().hour().minute())
                            }
                            .font(.edCaption)
                            .foregroundStyle(dueColor(for: due))
                        }
                        if let tag = todo.tag, !tag.isEmpty {
                            Text(tag)
                                .font(.edCaption)
                                .foregroundStyle(Tokens.inkSoft)
                                .padding(.horizontal, Space.sm)
                                .padding(.vertical, 2)
                                .background(Tokens.paper2, in: Capsule())
                                .overlay(Capsule().stroke(Tokens.border, lineWidth: 0.5))
                        }
                        if let url = todo.mapsURL {
                            Button {
                                openURL(url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "map.fill")
                                        .font(.system(size: 10, weight: .regular))
                                    Text("MAP")
                                        .font(.edEyebrow)
                                        .textCase(.uppercase)
                                        .tracking(1.4)
                                }
                                .foregroundStyle(Tokens.accentTasks)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Tokens.accentTasks.opacity(0.12), in: Capsule(style: .continuous))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open in Google Maps")
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: onInfoTap) {
                Image(systemName: "info.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(width: 32, height: 32, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            .accessibilityLabel("Edit task details")
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.md)
        .background(Color.clear)
        // Thin colored left-edge bar keyed to the task's priority. Spans the row
        // height at the leading edge; reads as a subtle accent, not a block.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Tokens.priorityColor(for: todo.taskPriority))
                .frame(width: Space.xs)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // When a tap-below draft is active, actively flip draftFocused in the parent
            // so the focus-loss → commitDraft → dismiss cycle fires immediately.
            // We still return early so the editor sheet does not open over the keyboard.
            if isDraftActive {
                onTapWhileDraftActive()
                return
            }
            // Completed rows ignore body taps; the info icon still works.
            if todo.completed { return }
            // Already in inline-edit; let the TextField own the tap.
            if isEditing { return }
            editText = todo.title
            isEditing = true
            // DispatchQueue.main.async lets the TextField mount before we focus it.
            DispatchQueue.main.async { titleFocused = true }
        }
    }

    private func commitInlineEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            isEditing = false
            editText = ""
        }
        guard !trimmed.isEmpty, trimmed != todo.title else { return }
        onTitleCommit(trimmed)
    }

    /// Single-tap toggle. If the row is mid inline-edit, persist any rename first
    /// (commitInlineEdit ends editing), then always toggle completion.
    private func handleToggle() {
        if isEditing { commitInlineEdit() }
        onToggle()
    }

    private func dueColor(for date: Date) -> Color {
        let now = Date()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        if !todo.completed && date < now { return Tokens.danger }
        if date < tomorrow { return Tokens.warning }
        return Tokens.inkSoft
    }
}

// MARK: - Editor sheet (kept simple, on paper background)

private struct TaskEditorSheet: View {
    let viewModel: TodosViewModel
    let todo: Todo?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date().addingTimeInterval(3600)
    @State private var tag: String = ""
    @State private var priority: TaskPriority = .none
    @State private var address: String = ""
    @State private var googleMapsLink: String = ""
    @State private var isResolvingAddress = false
    @State private var addressResolveTask: Task<Void, Never>?

    @Environment(\.openURL) private var openURL

    private var isEditing: Bool { todo != nil }

    /// Distinct, non-empty tags across all todos, sorted case-insensitively.
    /// The picker itself folds in the current selection, so a tag the edited
    /// todo carries (or a just-added new tag) still shows even if it's the
    /// only todo using it.
    private var availableTags: [String] {
        Set(viewModel.todos.compactMap { $0.tag })
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The current editor's maps link as a URL, coercing a bare host to https.
    /// `nil` when the field is empty (so the Open button stays hidden).
    private var editorMapsURL: URL? {
        let stored = googleMapsLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return nil }
        if let url = URL(string: stored), url.scheme != nil { return url }
        return URL(string: "https://\(stored)")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        labeled("Title") {
                            TextField("What needs to be done?", text: $title, axis: .vertical)
                                .lineLimit(1...3)
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .padding(Space.md)
                                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                .paperBorder(Tokens.border, radius: Radius.md)
                        }
                        labeled("Notes") {
                            TextField("Optional notes", text: $descriptionText, axis: .vertical)
                                .lineLimit(2...6)
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .padding(Space.md)
                                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                .paperBorder(Tokens.border, radius: Radius.md)
                        }
                        labeled("Due date") {
                            VStack(spacing: 0) {
                                HStack {
                                    Text("Set a due date")
                                        .font(.edBody)
                                        .foregroundStyle(Tokens.inkSoft)
                                    Spacer()
                                    Toggle("", isOn: $hasDueDate.animation())
                                        .labelsHidden()
                                        .tint(Tokens.accentTasks)
                                }
                                .padding(Space.md)

                                if hasDueDate {
                                    Divider().background(Tokens.divider)
                                    HStack {
                                        DatePicker("", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                                            .labelsHidden()
                                            .tint(Tokens.accentTasks)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(Space.md)
                                }
                            }
                            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                            .paperBorder(Tokens.border, radius: Radius.md)
                        }
                        labeled("Tag") {
                            TagChipPicker(selection: $tag, tags: availableTags)
                        }
                        labeled("Priority") {
                            Picker("Priority", selection: $priority) {
                                ForEach(TaskPriority.allCases, id: \.self) { p in
                                    Text(p.label).tag(p)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                            HStack(spacing: Space.sm) {
                                Text("Address").eyebrow()
                                if isResolvingAddress {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Resolving from link…")
                                        .font(.edCaption)
                                        .foregroundStyle(Tokens.muted)
                                }
                            }
                            TextField("Street address or area", text: $address, axis: .vertical)
                                .lineLimit(1...3)
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .padding(Space.md)
                                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                .paperBorder(Tokens.border, radius: Radius.md)
                        }
                        labeled("Google Maps link") {
                            HStack(spacing: Space.sm) {
                                TextField("Paste a Google Maps link", text: $googleMapsLink)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .keyboardType(.URL)
                                    .font(.edBody)
                                    .foregroundStyle(Tokens.ink)
                                    .padding(Space.md)
                                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                    .paperBorder(Tokens.border, radius: Radius.md)
                                    .onChange(of: googleMapsLink) { _, newValue in
                                        scheduleAddressResolve(from: newValue)
                                    }
                                if let url = editorMapsURL {
                                    Button {
                                        openURL(url)
                                    } label: {
                                        Image(systemName: "map")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(Tokens.accentTasks)
                                            .frame(width: 48, height: 48)
                                            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                            .paperBorder(Tokens.border, radius: Radius.md)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Open saved Google Maps link")
                                }
                            }
                        }
                    }
                    .padding(Space.lg)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(isEditing ? "Edit task" : "New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .foregroundStyle(Tokens.ink)
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(label).eyebrow()
            content()
        }
    }

    private func prefill() {
        guard let todo else { return }
        title = todo.title
        descriptionText = todo.description ?? ""
        if let due = todo.dueDate { hasDueDate = true; dueDate = due }
        tag = todo.tag ?? ""
        priority = todo.taskPriority
        address = todo.address
        googleMapsLink = todo.googleMapsLink
    }

    /// Auto-fill the Address field from a pasted Google Maps link (debounced).
    /// Only fills when Address is currently empty, so it never clobbers an
    /// address the user typed by hand.
    private func scheduleAddressResolve(from link: String) {
        addressResolveTask?.cancel()
        guard address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              MapsLinkResolver.looksLikeMapsLink(link) else {
            isResolvingAddress = false
            return
        }
        addressResolveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000) // debounce keystrokes
            if Task.isCancelled { return }
            isResolvingAddress = true
            let resolved = await MapsLinkResolver().resolveAddress(from: link)
            if Task.isCancelled { return }
            if let resolved, address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                address = resolved
            }
            isResolvingAddress = false
        }
    }

    private func save() async {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let finalDescription = descriptionText.isEmpty ? nil : descriptionText
        let finalTag = tag.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tag
        let finalDue = hasDueDate ? dueDate : nil
        let finalAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalMapsLink = googleMapsLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = todo {
            await viewModel.update(existing, title: trimmed, description: finalDescription, dueDate: finalDue, tag: finalTag, address: finalAddress, googleMapsLink: finalMapsLink, priority: priority.rawValue)
        } else {
            await viewModel.create(title: trimmed, description: finalDescription, dueDate: finalDue, tag: finalTag, address: finalAddress, googleMapsLink: finalMapsLink, priority: priority.rawValue)
        }
        dismiss()
    }
}
