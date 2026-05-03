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

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.lg) {
                        addRow

                        if viewModel.isLoading && viewModel.todos.isEmpty {
                            placeholder("Loading…")
                        } else if viewModel.todos.isEmpty {
                            placeholder("No tasks yet. Add one above.")
                        } else {
                            taskGroups
                        }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.lg)
                    .padding(.bottom, 96) // FAB clearance
                }
                .refreshable { await viewModel.load() }
            }

            ChatFAB { router.popToChat() }
        }
        .activeSection(.tasks)
        .task { await viewModel.load() }
        .onAppear {
            // Activity timeline deep-link consumption. The Activity surface
            // sets `router.focus` to ActivityFocus(section: .tasks, id: serverId)
            // before pushing the section. Local todos are keyed by clientUUID,
            // so the integer id can't currently be resolved back to a SwiftData
            // row; we clear the field here so the focus doesn't fire again on
            // the next appearance. If a serverId column is added to the local
            // model later, scroll + pulse can be implemented in this hook.
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

    private var taskGroups: some View {
        let now = Date()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let weekEnd = cal.date(byAdding: .day, value: 7, to: today)!

        let open = viewModel.todos.filter { !$0.completed }
        let completed = viewModel.todos.filter { $0.completed }

        var overdue: [Todo] = []
        var todayList: [Todo] = []
        var thisWeek: [Todo] = []
        var later: [Todo] = []
        var noDate: [Todo] = []

        for todo in open {
            guard let due = todo.dueDate else { noDate.append(todo); continue }
            if due < today { overdue.append(todo) }
            else if due < tomorrow { todayList.append(todo) }
            else if due < weekEnd { thisWeek.append(todo) }
            else { later.append(todo) }
        }

        return VStack(alignment: .leading, spacing: Space.xl) {
            if !overdue.isEmpty {
                taskSection(title: "Overdue", count: overdue.count, accent: Tokens.danger, soft: Tokens.dangerSoft, todos: overdue)
            }
            if !todayList.isEmpty {
                taskSection(title: "Today", count: todayList.count, accent: Tokens.warning, soft: Tokens.warningSoft, todos: todayList)
            }
            if !thisWeek.isEmpty {
                taskSection(title: "This Week", count: thisWeek.count, accent: Tokens.inkSoft, soft: Tokens.paper2, todos: thisWeek)
            }
            if !later.isEmpty {
                taskSection(title: "Later", count: later.count, accent: Tokens.inkSoft, soft: Tokens.paper2, todos: later)
            }
            if !noDate.isEmpty {
                taskSection(title: "No Date", count: noDate.count, accent: Tokens.muted, soft: Tokens.paper2, todos: noDate)
            }
            if !completed.isEmpty {
                completedSection(completed)
            }
        }
    }

    private func taskSection(title: String, count: Int, accent: Color, soft: Color, todos: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
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
            VStack(spacing: Space.xs) {
                ForEach(todos) { todo in
                    TaskRow(todo: todo) {
                        Task { await viewModel.toggleCompleted(todo) }
                    } onTap: {
                        editingTodo = todo
                    }
                }
            }
        }
    }

    private func completedSection(_ todos: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
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

            if completedExpanded {
                VStack(spacing: Space.xs) {
                    ForEach(todos) { todo in
                        TaskRow(todo: todo) {
                            Task { await viewModel.toggleCompleted(todo) }
                        } onTap: {
                            editingTodo = todo
                        }
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.edBody)
            .foregroundStyle(Tokens.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Space.xxxl)
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
