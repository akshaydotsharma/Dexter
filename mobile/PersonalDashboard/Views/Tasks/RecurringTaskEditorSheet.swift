import SwiftUI
import SwiftData

/// Add / edit form for a recurring-task template (#524). Nil `template` means
/// create. Mirrors `RecurringExpenseEditorSheet`'s shape (eyebrow labels, paper
/// surfaces, section accent) over the task fields plus the shared repeat rule.
///
/// Editing changes only what the template makes NEXT. Tasks it already created
/// are ordinary tasks and are never revisited, so a title fixed here does not
/// rewrite the one already sitting in Today.
struct RecurringTaskEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let template: RecurringTask?

    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var tag: String = ""
    @State private var priority: TaskPriority = .none
    @State private var remindMe: Bool = false
    @State private var remindersBlocked: Bool = false
    @State private var draft: RecurrenceDraft = .seeded()

    @State private var loaded: Bool = false
    @State private var saving: Bool = false
    @State private var errorMessage: String?

    /// Distinct tags across existing templates AND tasks, so the picker offers
    /// the same vocabulary the task editor does.
    @Query(filter: #Predicate<LocalTodo> { $0.deletedAt == nil })
    private var todos: [LocalTodo]

    private var isEditing: Bool { template != nil }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.isValid && !saving
    }

    private var availableTags: [String] {
        Set(todos.compactMap { $0.tag })
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        labeled("Title") {
                            TextField("What comes back?", text: $title, axis: .vertical)
                                .paperFieldOnMac()
                                .lineLimit(1...3)
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .padding(Space.md)
                                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                .paperBorder(Tokens.border, radius: Radius.md)
                        }
                        labeled("Notes") {
                            TextField("Optional notes", text: $descriptionText, axis: .vertical)
                                .paperFieldOnMac()
                                .lineLimit(2...6)
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .padding(Space.md)
                                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                .paperBorder(Tokens.border, radius: Radius.md)
                        }
                        labeled("Repeat") {
                            RepeatRuleEditor(draft: $draft, showsStartDate: true)
                        }
                        labeled("Remind me") {
                            RecurringReminderRow(remindMe: $remindMe, blocked: remindersBlocked)
                        }
                        labeled("Tag") {
                            TagChipPicker(selection: $tag, tags: availableTags)
                        }
                        labeled("Priority") {
                            Picker("Priority", selection: $priority) {
                                ForEach(TaskPriority.allCases, id: \.self) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.edFootnote)
                                .foregroundStyle(Tokens.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle(isEditing ? "Edit repeat" : "New repeat")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? Tokens.ink : Tokens.muted)
                }
            }
        }
        // macOS only: a sheet with no explicit size collapses to its toolbar
        // (#474). On iPhone this minWidth is wider than the screen, so it has to
        // stay out of the iOS tree entirely.
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
        .onAppear(perform: loadIfNeeded)
        .onChange(of: remindMe) { _, armed in
            guard armed else {
                remindersBlocked = false
                return
            }
            // Asked the first time a reminder is armed, never at launch (#444).
            Task {
                let allowed = await TaskReminderScheduler.requestAuthorizationIfNeeded()
                remindersBlocked = !allowed
            }
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(label).eyebrow()
            content()
        }
    }

    // MARK: - Load / save

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let template else {
            draft = .seeded()
            return
        }
        title = template.title
        descriptionText = template.taskDescription ?? ""
        tag = template.tag ?? ""
        priority = TaskPriority(rawValue: template.priority) ?? .none
        remindMe = template.remindMe
        draft = .from(template: template)
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        defer { saving = false }
        let service = RecurringTaskService.default()
        do {
            if let template {
                try service.update(
                    template,
                    title: title,
                    taskDescription: descriptionText,
                    tag: tag,
                    priority: priority.rawValue,
                    remindMe: remindMe,
                    frequency: draft.frequency,
                    interval: draft.interval,
                    weekdayMask: draft.weekdayMask,
                    dayOfMonth: draft.dayOfMonth,
                    monthOfYear: draft.monthOfYear,
                    timeOfDayMinutes: draft.timeOfDayMinutes,
                    leadDays: draft.leadDays,
                    startDate: draft.startDate,
                    endDate: .some(draft.resolvedEndDate)
                )
            } else {
                try service.create(
                    title: title,
                    taskDescription: descriptionText,
                    tag: tag,
                    priority: priority.rawValue,
                    remindMe: remindMe,
                    frequency: draft.frequency,
                    interval: draft.interval,
                    weekdayMask: draft.weekdayMask,
                    dayOfMonth: draft.dayOfMonth,
                    monthOfYear: draft.monthOfYear,
                    timeOfDayMinutes: draft.timeOfDayMinutes,
                    leadDays: draft.leadDays,
                    startDate: draft.startDate,
                    endDate: draft.resolvedEndDate
                )
            }
            // A brand-new template whose first date is already inside its lead
            // window should put the task in the list now, not on the next launch.
            await RecurringTaskCoordinator.shared.runPass()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The reminder toggle for a template, phrased for something that has not
/// happened yet: every occurrence carries a due date by construction, so unlike
/// the task editor's version this one is never a flag with nothing behind it.
struct RecurringReminderRow: View {
    @Binding var remindMe: Bool
    var blocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.md) {
                Image(systemName: "bell")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.accentTasks)
                Text("Notify me when each one is due")
                    .font(.edBody)
                    .foregroundStyle(Tokens.inkSoft)
                Spacer()
                Toggle("", isOn: $remindMe.animation())
                    .labelsHidden()
                    .tint(Tokens.accentTasks)
            }
            if remindMe, blocked {
                #if os(macOS)
                Text("Notifications are turned off for Dexter. Turn them on in System Settings to get these reminders.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                Text("Notifications are turned off for Dexter. Turn them on in Settings to get these reminders.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
        }
        .padding(Space.md)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
        .paperBorder(Tokens.border, radius: Radius.md)
    }
}
