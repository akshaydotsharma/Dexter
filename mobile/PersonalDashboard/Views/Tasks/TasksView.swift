import SwiftUI

struct TasksView: View {
    @State private var viewModel = TodosViewModel()
    @State private var showingEditor = false
    @State private var editingTodo: Todo?
    @State private var newTaskText: String = ""
    @State private var completedExpanded: Bool = false

    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: "Tasks",
                    onMenu: {
                        withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true }
                    },
                    onToggleTheme: { schemePref = schemePref.next }
                )

                // Using `List` (not `ScrollView { LazyVStack }`) so each row
                // can opt into native `.swipeActions`. The list is dressed
                // down to keep the editorial paper styling: clear row
                // backgrounds, hidden separators, and `.scrollContentBackground`
                // hidden so `Tokens.paper` shows through.
                List {
                    Section {
                        addRow
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: Space.lg, leading: Space.lg, bottom: 0, trailing: Space.lg))
                    }

                    if viewModel.isLoading && viewModel.todos.isEmpty {
                        placeholderRow("Loading…")
                    } else if viewModel.todos.isEmpty {
                        placeholderRow("No tasks yet. Add one above.")
                    } else {
                        taskGroups
                    }

                    // FAB clearance — keeps the last row scrollable above the chat FAB.
                    Color.clear
                        .frame(height: 96)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
                .refreshable { await viewModel.load() }
            }

            ChatFAB { router.popToChat() }
        }
        .activeSection(.tasks)
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

    // MARK: - Add row

    private var addRow: some View {
        HStack(spacing: Space.sm) {
            ZStack(alignment: .leading) {
                if newTaskText.isEmpty {
                    Text("Add a new task…")
                        .font(.edBody)
                        .foregroundStyle(Tokens.mutedSoft)
                        .padding(.horizontal, Space.md)
                        .allowsHitTesting(false)
                }
                TextField("", text: $newTaskText)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, 10)
                    .submitLabel(.done)
                    .onSubmit(addTaskInline)
            }
            .frame(minHeight: 40)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)

            Button {
                if !newTaskText.trimmingCharacters(in: .whitespaces).isEmpty {
                    addTaskInline()
                } else {
                    showingEditor = true
                }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(EdSendButtonStyle(enabled: true))
            .accessibilityLabel("Add task")
        }
    }

    private func addTaskInline() {
        let trimmed = newTaskText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        newTaskText = ""
        Task { await viewModel.create(title: trimmed, description: nil, dueDate: nil, tag: nil) }
    }

    // MARK: - Grouped tasks

    @ViewBuilder
    private var taskGroups: some View {
        let buckets = computeBuckets()
        if !buckets.overdue.isEmpty {
            taskSection(title: "Overdue", count: buckets.overdue.count, accent: Tokens.danger, soft: Tokens.dangerSoft, todos: buckets.overdue)
        }
        if !buckets.today.isEmpty {
            taskSection(title: "Today", count: buckets.today.count, accent: Tokens.warning, soft: Tokens.warningSoft, todos: buckets.today)
        }
        if !buckets.thisWeek.isEmpty {
            taskSection(title: "This Week", count: buckets.thisWeek.count, accent: Tokens.inkSoft, soft: Tokens.paper2, todos: buckets.thisWeek)
        }
        if !buckets.later.isEmpty {
            taskSection(title: "Later", count: buckets.later.count, accent: Tokens.inkSoft, soft: Tokens.paper2, todos: buckets.later)
        }
        if !buckets.noDate.isEmpty {
            taskSection(title: "No Date", count: buckets.noDate.count, accent: Tokens.muted, soft: Tokens.paper2, todos: buckets.noDate)
        }
        if !buckets.completed.isEmpty {
            completedSection(buckets.completed)
        }
    }

    private struct TaskBuckets {
        var overdue: [Todo] = []
        var today: [Todo] = []
        var thisWeek: [Todo] = []
        var later: [Todo] = []
        var noDate: [Todo] = []
        var completed: [Todo] = []
    }

    private func computeBuckets() -> TaskBuckets {
        let now = Date()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let weekEnd = cal.date(byAdding: .day, value: 7, to: today)!

        var b = TaskBuckets()
        b.completed = viewModel.todos.filter { $0.completed }
        let open = viewModel.todos.filter { !$0.completed }
        for todo in open {
            guard let due = todo.dueDate else { b.noDate.append(todo); continue }
            if due < today { b.overdue.append(todo) }
            else if due < tomorrow { b.today.append(todo) }
            else if due < weekEnd { b.thisWeek.append(todo) }
            else { b.later.append(todo) }
        }
        return b
    }

    @ViewBuilder
    private func taskSection(title: String, count: Int, accent: Color, soft: Color, todos: [Todo]) -> some View {
        Section {
            ForEach(todos) { todo in
                TaskRow(todo: todo) {
                    Task { await viewModel.toggleCompleted(todo) }
                } onTap: {
                    editingTodo = todo
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: Space.lg, bottom: 2, trailing: Space.lg))
                .swipeToDeleteTrash {
                    Task { await viewModel.delete(todo) }
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
                    TaskRow(todo: todo) {
                        Task { await viewModel.toggleCompleted(todo) }
                    } onTap: {
                        editingTodo = todo
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: Space.lg, bottom: 2, trailing: Space.lg))
                    .swipeToDeleteTrash {
                        Task { await viewModel.delete(todo) }
                    }
                }
            }
        } header: {
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
            .padding(.top, Space.lg)
            .padding(.bottom, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.top, Space.lg)
        .padding(.bottom, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.paper)
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

// MARK: - Row

private struct TaskRow: View {
    let todo: Todo
    let onToggle: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Button(action: onToggle) {
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
            // Map the circle's center (with a 4pt body-font offset for x-height) to the
            // firstTextBaseline so the bullet visually centers on the title's first line.
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            .accessibilityLabel(todo.completed ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 4) {
                Text(todo.title)
                    .font(.edBody)
                    .strikethrough(todo.completed)
                    .foregroundStyle(todo.completed ? Tokens.mutedSoft : Tokens.ink)
                    .multilineTextAlignment(.leading)

                if let desc = todo.description, !desc.isEmpty {
                    Text(desc)
                        .font(.edSubheadline)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                }

                if todo.dueDate != nil || (todo.tag != nil && !(todo.tag?.isEmpty ?? true)) {
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
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.md)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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

    private var isEditing: Bool { todo != nil }

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
                        Toggle(isOn: $hasDueDate.animation()) {
                            Text("Due date").font(.edBodyMedium).foregroundStyle(Tokens.ink)
                        }
                        if hasDueDate {
                            DatePicker("", selection: $dueDate)
                                .labelsHidden()
                                .tint(Tokens.accentTasks)
                        }
                        labeled("Tag") {
                            TextField("e.g. work, personal", text: $tag)
                                .textInputAutocapitalization(.never)
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .padding(Space.md)
                                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                .paperBorder(Tokens.border, radius: Radius.md)
                        }
                    }
                    .padding(Space.lg)
                }
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
        VStack(alignment: .leading, spacing: Space.xs) {
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
    }

    private func save() async {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let finalDescription = descriptionText.isEmpty ? nil : descriptionText
        let finalTag = tag.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tag
        let finalDue = hasDueDate ? dueDate : nil
        if let existing = todo {
            await viewModel.update(existing, title: trimmed, description: finalDescription, dueDate: finalDue, tag: finalTag)
        } else {
            await viewModel.create(title: trimmed, description: finalDescription, dueDate: finalDue, tag: finalTag)
        }
        dismiss()
    }
}
