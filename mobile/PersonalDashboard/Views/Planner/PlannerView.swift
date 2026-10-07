import SwiftUI
import SwiftData

/// The Planner section (#687): Alternative B, "Agenda and Capacity".
///
/// One place that merges the work calendar, the personal calendar, Dexter
/// Tasks and blocks added by hand, and answers "does today fit?" before any
/// row is read.
///
/// ### Data
///
/// Two queries, both here: live tasks and live plan blocks. Calendar events
/// come from `PlannerCalendarService` (EventKit, read-only) and are loaded once
/// per visible range. Everything is copied into value snapshots and handed to
/// `PlannerEngine`, so no row runs a query of its own (#442).
///
/// ### Layout
///
/// Day is a proportional time grid on both platforms (#687 round 2): every
/// hour is the same height, tiles are sized by start and end, and empty space
/// is the free time (a tap there adds at that time).
/// iPhone: reached from the side drawer beside Today; Week is the week board,
/// and "To plan" is a sheet from the top bar.
/// Mac: a "To plan" inspector column, Day / Week in the native toolbar, and
/// Week as seven columns of the same grid.
struct PlannerView: View {
    @Bindable var router: AppRouter

    @Query(filter: #Predicate<LocalTodo> { $0.deletedAt == nil })
    private var todos: [LocalTodo]

    @Query(filter: #Predicate<LocalPlanBlock> { $0.deletedAt == nil })
    private var blockRows: [LocalPlanBlock]

    /// Dexter-only decisions about calendar events (#689).
    @Query(filter: #Predicate<LocalEventOverride> { $0.deletedAt == nil })
    private var overrideRows: [LocalEventOverride]

    private var overrideRules: [EventOverrideRule] { overrideRows.map(\.rule) }

    @State private var calendars = PlannerCalendarService.shared
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var mode: PlannerMode = PlannerMode.launchValue
    @State private var events: [PlannerEvent] = []
    @State private var now = Date()
    @State private var sheet: PlannerSheetKind?
    @State private var writeError: String?
    @State private var inlineText = ""
    @State private var launchSheetConsumed = false
    /// The block being made on the grid, and its title while it is named.
    @State private var draft: PlannerDraft?
    @State private var draftTitle = ""
    /// "Removed … · Undo", straight after a hide (#689).
    @State private var toast: PlannerToast?
    /// iPhone: the To-plan panel, and whether a drag has tucked it away.
    @State private var toPlanPanel = false
    @State private var panelTucked = false
    /// The tile whose quick view is open (#687 round 6).
    @State private var quickView: PlannerItem?
    /// A tile waiting on the "how do you want to delete it" dialog.
    @State private var pendingDelete: PlannerItem?
    /// A repeating event waiting on "only this one, or the series".
    @State private var pendingScope: PendingScope?
    /// A To-plan task open in the Tasks section's own editor.
    @State private var editingTodo: Todo?
    /// A To-plan task waiting on its Delete confirmation.
    @State private var pendingTaskDelete: PlannerTask?
    /// Mac: the To-plan row a single click selected.
    @State private var selectedToPlanID: String?
    @State private var todosVM = TodosViewModel()
    @Environment(\.plannerTaskDrag) private var taskDrag

    @AppStorage(PlannerSettings.Key.hiddenSources) private var hiddenRaw: String = ""
    @AppStorage(PlannerSettings.Key.workdayStartMinute) private var startMinute: Int = PlannerSettings.defaultStartMinute
    @AppStorage(PlannerSettings.Key.workdayLengthMinutes) private var lengthMinutes: Int = PlannerSettings.defaultLengthMinutes

    @Environment(\.scenePhase) private var scenePhase

    // MARK: Derived

    private var settings: WorkdaySettings {
        WorkdaySettings(startMinute: min(max(startMinute, 0), 23 * 60), lengthMinutes: min(max(lengthMinutes, 60), 16 * 60))
    }

    private var hidden: Set<PlannerSource> { PlannerSettings.decodeSources(hiddenRaw) }
    private var visible: Set<PlannerSource> { Set(PlannerSource.allCases).subtracting(hidden) }

    private var tasks: [PlannerTask] {
        todos.map {
            PlannerTask(
                id: $0.clientUUID.uuidString,
                title: $0.title,
                priority: TaskPriority(rawValue: $0.priority) ?? .none,
                due: $0.dueDate,
                completed: $0.completed
            )
        }
    }

    private var blocks: [PlannerBlock] {
        blockRows.map {
            PlannerBlock(
                id: $0.clientUUID, kind: $0.kindEnum, title: $0.title,
                day: WallClock.deviceDay(from: $0.day),
                start: $0.start, end: $0.end,
                durationMinutes: $0.durationMinutes, taskUUID: $0.taskUUID
            )
        }
    }

    /// The last length each task was planned for, so a re-plan starts there.
    private func estimates(_ blocks: [PlannerBlock]) -> [String: Int] {
        var out: [String: Int] = [:]
        for b in blocks where b.kind == .task && !b.taskUUID.isEmpty { out[b.taskUUID] = b.durationMinutes }
        return out
    }

    private var calendar: Calendar { .current }

    private var weekStart: Date {
        let d = calendar.startOfDay(for: selectedDay)
        let wd = calendar.component(.weekday, from: d)
        return calendar.date(byAdding: .day, value: -((wd + 5) % 7), to: d) ?? d
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    /// The range of events to load: the selected week, plus the next eight days
    /// from today for the plan sheet's free-time chips.
    private var loadKey: PlannerLoadKey {
        let today = calendar.startOfDay(for: Date())
        let start = min(weekStart, today)
        let end = max(calendar.date(byAdding: .day, value: 8, to: weekStart) ?? weekStart,
                      calendar.date(byAdding: .day, value: 9, to: today) ?? today)
        return PlannerLoadKey(start: start, end: end, revision: calendars.revision, access: calendars.access)
    }

    // MARK: Body

    var body: some View {
        let context = PlannerContext(
            tasks: tasks, blocks: blocks, rawEvents: events, overrides: overrideRules,
            now: now, settings: settings, visible: visible
        )
        return screen(context)
            .environment(\.plannerTileActions, tileActions(context))
            .confirmationDialog(
                pendingDelete.map(PlannerDeletion.dialogTitle(for:)) ?? "",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { item in
                ForEach(PlannerDeletion.choices(for: item)) { choice in
                    Button(choice.buttonTitle, role: choice.isDestructive ? .destructive : nil) {
                        performDelete(choice, item)
                    }
                    .accessibilityIdentifier("planner.delete.\(choice.rawValue)")
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text(PlannerDeletion.dialogMessage(for: item))
            }
            .confirmationDialog(
                pendingScope?.title ?? "",
                isPresented: Binding(get: { pendingScope != nil }, set: { if !$0 { pendingScope = nil } }),
                titleVisibility: .visible,
                presenting: pendingScope
            ) { p in
                Button("Only this event") { runScoped(p, .occurrence) }
                    .accessibilityIdentifier("planner.series.only")
                Button("All events in the series") { runScoped(p, .series) }
                    .accessibilityIdentifier("planner.series.all")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This is a repeating event.")
            }
            .confirmationDialog(
                pendingTaskDelete.map { "Delete “\($0.title)”?" } ?? "",
                isPresented: Binding(get: { pendingTaskDelete != nil }, set: { if !$0 { pendingTaskDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingTaskDelete
            ) { task in
                Button("Delete the task", role: .destructive) { deleteTask(task.id) }
                    .accessibilityIdentifier("planner.delete.deleteTask")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The task is deleted from Tasks.")
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    PlannerToastView(toast: toast) { undoToast(toast) }
                        .padding(.horizontal, Space.lg)
                        #if os(iOS)
                        .padding(.bottom, 96)
                        #else
                        .padding(.bottom, 24)
                        #endif
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast.id) {
                            try? await Task.sleep(for: .seconds(6))
                            if self.toast?.id == toast.id { withAnimation { self.toast = nil } }
                        }
                }
            }
            .activeSection(.planner)
            .macSectionChrome("Planner") { macToolbar }
            #if os(macOS)
            .navigationSubtitle(subtitle)
            #endif
            .sheet(item: $sheet) { kind in
                sheetView(kind, context: context)
            }
            #if os(iOS)
            // The Tasks section's own editor, for a To-plan row (#687 round 6).
            .background {
                Color.clear.sheet(item: $editingTodo) { todo in
                    TaskEditorSheet(viewModel: todosVM, todo: todo, onDelete: { askDeleteTask(todo.id.uuidString) })
                }
            }
            #endif
            .task(id: loadKey) { reloadEvents() }
            .task { await calendars.requestAccessIfNeeded() }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    now = Date()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { calendars.refreshAccess(); now = Date() }
            }
            .onAppear { consumeLaunchSheet() }
    }

    private var subtitle: String {
        mode == .week
            ? "Week of \(PlannerStyle.dayMonthFormatter.string(from: weekStart))"
            : "\(PlannerStyle.weekdayFormatter.string(from: selectedDay)) \(PlannerStyle.dayMonthFormatter.string(from: selectedDay))"
    }

    /// A fixed header (day, chips, meter) over a grid that fills the rest of
    /// the height and scrolls on its own, so the meter stays in view while the
    /// hours move (#687 round 2).
    @ViewBuilder
    private func screen(_ ctx: PlannerContext) -> some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()
            #if os(iOS)
            VStack(spacing: 0) {
                TopBar(
                    title: "Planner",
                    onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
                ) {
                    TopBarIconButton(systemName: "tray", accessibilityLabel: "Tasks to plan") {
                        withAnimation(.easeOut(duration: 0.25)) { toPlanPanel = true }
                    }
                    TopBarIconButton(systemName: "plus", accessibilityLabel: "Add a block") {
                        sheet = .quickAdd("")
                    }
                }
                if mode == .week {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) { weekBoardContent(ctx) }
                            .padding(.horizontal, Space.lg)
                            .padding(.top, Space.md)
                            .padding(.bottom, 110)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        dayHeader(ctx)
                        dayGrid(ctx, bottomInset: 96)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.md)
                    // Name the draft: a compact card above the keyboard.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if draft?.isNaming == true, sheet == nil {
                            quickCreate
                                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                                .paperBorder()
                                .shadowLg()
                                .padding(.horizontal, Space.md)
                                .padding(.bottom, Space.sm)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
            // The quick view card, above the floating tab bar (#687 round 6).
            if let item = quickView, draft?.isNaming != true, sheet == nil, !toPlanPanel {
                VStack {
                    Spacer(minLength: 0)
                    quickViewCard(item, ctx: ctx)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                        .paperBorder()
                        .shadowLg()
                        .padding(.horizontal, Space.md)
                        .padding(.bottom, 92)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if toPlanPanel { toPlanPanelView(ctx) }
            dragChip
            #else
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    if mode == .week {
                        weekGridContent(ctx)
                    } else {
                        dayHeader(ctx)
                        dayGrid(ctx, bottomInset: 0)
                        inlineQuickAdd()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Rectangle().fill(Tokens.border).frame(width: 1)
                PlannerInspector(
                    candidates: candidates(ctx),
                    onPlan: { sheet = .plan($0.task.id) },
                    onDrop: { c, t in dropTask(c.task.id, title: c.task.title, at: t) },
                    selectedID: selectedToPlanID,
                    editingID: editingTodo?.id.uuidString,
                    onSelect: { selectedToPlanID = $0.task.id },
                    onOpen: { openTaskEditor($0.task) },
                    onCommand: { cmd, c in runToPlan(cmd, c.task) },
                    onCloseEditor: { editingTodo = nil },
                    editor: { c in
                        AnyView(Group {
                            if let todo = editingTodo, todo.id.uuidString == c.task.id {
                                TaskEditorSheet(
                                    viewModel: todosVM, todo: todo,
                                    onClose: { editingTodo = nil },
                                    onDelete: { askDeleteTask(c.task.id) }
                                )
                            }
                        })
                    }
                )
                .frame(width: 270)
            }
            #endif
        }
    }

    // MARK: Day

    @ViewBuilder
    private func dayHeader(_ ctx: PlannerContext) -> some View {
        let day = ctx.day(selectedDay)
        let summary = PlannerEngine.capacity(of: day, settings: ctx.settings, visible: ctx.visible)
        header(PlannerDayHeader(day: selectedDay, eyebrowOverride: calendar.isDateInToday(selectedDay) ? "Today · \(PlannerStyle.weekdayFormatter.string(from: selectedDay))" : nil))
        PlannerSourceChips(counts: counts(day), hidden: hidden, onToggle: toggle)
        accessCard
        if let writeError {
            Text(writeError).font(.edFootnote).foregroundStyle(Tokens.danger)
        }
        PlannerMeterCard(summary: summary, settings: ctx.settings, onFixes: summary.isOver ? { sheet = .fixes(selectedDay) } : nil)
    }

    private func dayGrid(_ ctx: PlannerContext, bottomInset: CGFloat) -> some View {
        PlannerFillRemaining {
            dayGridBody(ctx, bottomInset: bottomInset)
        }
    }

    private func dayGridBody(_ ctx: PlannerContext, bottomInset: CGFloat) -> some View {
        PlannerDayTimeGrid(
            day: ctx.day(selectedDay),
            visible: ctx.visible,
            now: ctx.now,
            settings: ctx.settings,
            bottomInset: bottomInset,
            onTapItem: tapped,
            draft: draftHandlers,
            onOpenItem: openItem
        )
        .frame(maxHeight: .infinity)
    }

    private func header<Head: View>(_ head: Head) -> some View {
        HStack(alignment: .bottom, spacing: Space.sm) {
            head
            Spacer(minLength: Space.sm)
            #if os(iOS)
            VStack(alignment: .trailing, spacing: 6) {
                modePicker.frame(width: 132)
                dayNav
            }
            #endif
        }
    }

    // MARK: Day nav and mode

    @ViewBuilder
    private var dayNav: some View {
        #if os(macOS)
        // Native control group on the Mac, so the three read as one toolbar
        // control and take the system's own label styling.
        ControlGroup {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .help(mode == .week ? "Previous week" : "Previous day")
                .accessibilityLabel(mode == .week ? "Previous week" : "Previous day")
            Button(mode == .week ? "This week" : "Today") { jumpToToday() }
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .help(mode == .week ? "Next week" : "Next day")
                .accessibilityLabel(mode == .week ? "Next week" : "Next day")
        }
        .fixedSize()
        #else
        dayNavPhone
        #endif
    }

    private var dayNavPhone: some View {
        HStack(spacing: 2) {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .accessibilityLabel(mode == .week ? "Previous week" : "Previous day")
            Button { jumpToToday() } label: {
                Text(mode == .week ? "This week" : "Today")
                    .font(.edCaption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .frame(height: 28)
            }
            .accessibilityLabel(mode == .week ? "This week" : "Today")
            Button { step(1) } label: {
                Image(systemName: "chevron.right").frame(width: 30, height: 28).contentShape(Rectangle())
            }
            .accessibilityLabel(mode == .week ? "Next week" : "Next day")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Tokens.ink)
        .background(Tokens.surface, in: Capsule())
        .overlay(Capsule().stroke(Tokens.border, lineWidth: 1))
    }

    private var modePicker: some View {
        Picker("View", selection: $mode) {
            Text("Day").tag(PlannerMode.day)
            Text("Week").tag(PlannerMode.week)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// macOS toolbar: day nav, Day / Week, filter, add. One `ToolbarItem`
    /// renders one control (#524), so they are grouped in one `HStack`.
    @ViewBuilder
    private var macToolbar: some View {
        #if os(macOS)
        HStack(spacing: 10) {
            dayNav
            modePicker.frame(width: 130)
            Menu {
                ForEach(PlannerSource.allCases, id: \.self) { s in
                    Toggle(s.label, isOn: Binding(get: { !hidden.contains(s) }, set: { _ in toggle(s) }))
                }
                Divider()
                Button("Planner settings…") { sheet = .settings }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .menuIndicator(.hidden)
            .help("Filter sources")
            .accessibilityLabel("Filter sources")
            Button { sheet = .quickAdd("") } label: { Image(systemName: "plus") }
                .help("Add a block")
                .accessibilityLabel("Add a block")
        }
        #else
        EmptyView()
        #endif
    }

    private func step(_ direction: Int) {
        let days = mode == .week ? 7 * direction : direction
        selectedDay = calendar.date(byAdding: .day, value: days, to: selectedDay) ?? selectedDay
    }

    private func jumpToToday() {
        selectedDay = calendar.startOfDay(for: Date())
    }

    private func toggle(_ source: PlannerSource) {
        var h = hidden
        if h.contains(source) { h.remove(source) } else { h.insert(source) }
        hiddenRaw = PlannerSettings.encodeSources(h)
    }

    private func counts(_ day: PlannerDay) -> [PlannerSource: Int] {
        var c: [PlannerSource: Int] = [:]
        for i in day.all { c[i.source, default: 0] += 1 }
        return c
    }

    // MARK: Access

    @ViewBuilder
    private var accessCard: some View {
        switch calendars.access {
        case .granted:
            EmptyView()
        default:
            PlannerAccessCard(
                access: calendars.access,
                isRequesting: calendars.isRequesting,
                promptDidNotAppear: calendars.promptDidNotAppear
            ) {
                Task { await calendars.requestAccessFromButton() }
            }
        }
    }

    /// One click or tap on a tile: its quick view (#687 round 6).
    private func tapped(_ item: PlannerItem) {
        resolveDraft()
        withAnimation(.easeOut(duration: 0.18)) { quickView = item }
    }

    /// A double click, Edit in the quick view, or a tap on an all-day pill:
    /// the full editor. Closes the quick view first, so a double click never
    /// leaves one behind.
    private func openItem(_ item: PlannerItem) {
        resolveDraft()
        quickView = nil
        if let id = item.blockID {
            sheet = .edit(id)
        } else if case .taskDue = item.origin, let id = item.taskUUID {
            // A timed task opens its start and length with a Save; a task due
            // on a day with no hour opens the day and slot picker.
            if let s = item.start, let e = item.end {
                sheet = .taskTime(taskID: id, start: s, end: e)
            } else {
                sheet = .plan(id)
            }
        } else if case .event = item.origin {
            sheet = .event(item.id)
        }
    }

    // MARK: Drag to create (#687 round 3)

    private var draftHandlers: PlannerDraftHandlers {
        PlannerDraftHandlers(
            draft: draft,
            onChange: { s, e in
                quickView = nil
                if draft?.isNaming == true { resolveDraft() }
                draft = PlannerDraft(start: s, end: e, isNaming: false)
            },
            onCommit: { s, e in
                quickView = nil
                if draft?.isNaming == true {
                    // A click or tap away from a draft being named settles it
                    // and does not start a new one.
                    resolveDraft()
                    return
                }
                draftTitle = ""
                draft = PlannerDraft(start: s, end: e, isNaming: true)
            },
            popoverPresented: Binding(
                get: { draft?.isNaming == true && sheet == nil },
                set: { shown in if !shown, draft?.isNaming == true, sheet == nil { resolveDraft() } }
            ),
            quickCreate: { AnyView(quickCreate) },
            onResize: { item, end in resized(item, to: end) },
            onMove: { item, start, end in moved(item, start: start, end: end) },
            onMoveBegin: {
                if draft?.isNaming == true { resolveDraft() }
                withAnimation(.easeOut(duration: 0.18)) { quickView = nil }
            },
            allDayTaskMinutes: allDayTaskMinutes,
            onDropAllDayTask: { item, t in
                guard let id = item.taskUUID else { return }
                quickView = nil
                dropTask(id, title: item.title, at: t)
            }
        )
    }

    /// iPhone only (#693): the Mac's All Day pills keep their click and menu.
    private var allDayTaskMinutes: ((PlannerItem) -> Int)? {
        #if os(iOS)
        let remembered = estimates(blocks)
        return { item in
            PlannerDragGeometry.allDayTaskLength(
                itemMinutes: item.isBlock ? item.durationMinutes : 0,
                remembered: item.taskUUID.flatMap { remembered[$0] }
            )
        }
        #else
        return nil
        #endif
    }

    /// A tile was picked up and moved (#693): the same length at a new start.
    /// A block keeps its title; a timed task with no block becomes a plan
    /// block at the new time, as a resize does.
    private func moved(_ item: PlannerItem, start: Date, end: Date) {
        if let id = item.blockID {
            write {
                if let row = try PlanBlockService.default().block(id: id) {
                    try PlanBlockService.default().update(row, title: row.title, start: start, end: end,
                                                          day: start, durationMinutes: PlannerEngine.minutes(from: start, to: end))
                }
            }
        } else if case .taskDue = item.origin, let taskID = item.taskUUID {
            write { try PlanBlockService.default().planTask(taskUUID: taskID, title: item.title, start: start, end: end) }
        }
    }

    @ViewBuilder
    private var quickCreate: some View {
        if let d = draft {
            PlannerQuickCreate(
                draft: d,
                title: $draftTitle,
                onSave: saveDraft,
                onCancel: discardDraft,
                onMoreOptions: {
                    sheet = .newBlock(start: d.start, end: d.end, title: draftTitle)
                    draft = nil
                },
                onPlaceTask: {
                    sheet = .placeTask(start: d.start, end: d.end)
                    draft = nil
                }
            )
        }
    }

    /// A tile's bottom edge was dragged. A block keeps its start and gets the
    /// new end; a timed task with no block becomes a plan block with it.
    private func resized(_ item: PlannerItem, to end: Date) {
        guard let start = item.start else { return }
        if let id = item.blockID {
            write {
                if let row = try PlanBlockService.default().block(id: id) {
                    try PlanBlockService.default().update(row, title: row.title, start: start, end: end,
                                                          day: start, durationMinutes: PlannerEngine.minutes(from: start, to: end))
                }
            }
        } else if case .taskDue = item.origin, let taskID = item.taskUUID {
            write { try PlanBlockService.default().planTask(taskUUID: taskID, title: item.title, start: start, end: end) }
        }
    }

    /// Return or Save: write a manual block with the typed title.
    private func saveDraft() {
        guard let d = draft else { return }
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        write { _ = try PlanBlockService.default().addManual(title: t, start: d.start, end: d.end) }
        draft = nil
        draftTitle = ""
    }

    private func discardDraft() {
        draft = nil
        draftTitle = ""
    }

    /// Click or tap away: a titled draft is saved, an untitled one is dropped
    /// and writes nothing.
    private func resolveDraft() {
        guard draft != nil else { return }
        if draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            discardDraft()
        } else {
            saveDraft()
        }
    }

    // MARK: Overloaded day

    private func fixesSheet(_ d: Date, ctx: PlannerContext) -> some View {
        let day = ctx.day(d)
        let movable = day.all.filter { $0.isBlock && ctx.visible.contains($0.source) }
        let fixed = day.timed.filter { $0.isFixed && ctx.visible.contains($0.source) }
        let conflicts = PlannerEngine.conflicts(in: day, visible: ctx.visible)
        let summary = PlannerEngine.capacity(of: day, settings: ctx.settings, visible: ctx.visible)
        return PlannerSheetScaffold(
            title: "\(PlannerStyle.weekdayFormatter.string(from: d)) is over by \(PlannerFormat.duration(summary.overflowMinutes))",
            subtitle: "Move what you planned; calendar events stay fixed"
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Can move").eyebrow()
                    if movable.isEmpty {
                        Text("Nothing on this day was planned by you. Everything here is a calendar event.")
                            .font(.edCaption).foregroundStyle(Tokens.muted)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(movable.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Rectangle().fill(Tokens.divider).frame(height: 1) }
                                moveRow(item, day: day, ctx: ctx)
                            }
                        }
                        .plannerCard()
                    }
                    Text("Fixed").eyebrow().padding(.top, 6)
                    VStack(spacing: 4) {
                        ForEach(fixed) { item in
                            let inConflict = conflicts.contains { g in g.items.contains { $0.id == item.id } }
                            PlannerTile(item: item, inConflict: inConflict, height: 36).frame(height: 36)
                        }
                    }
                    if !conflicts.isEmpty {
                        Text("\(conflicts.count) overlap\(conflicts.count == 1 ? "" : "s"), ringed in red.")
                            .font(.edCaption).foregroundStyle(Tokens.danger)
                    }
                }
            }
        }
    }

    private func moveRow(_ item: PlannerItem, day: PlannerDay, ctx: PlannerContext) -> some View {
        let minutes = max(5, item.durationMinutes)
        let target = PlannerEngine.nearestDayWithRoom(
            after: day.day, minutes: minutes,
            freeMinutes: { PlannerEngine.capacity(of: ctx.day($0), settings: ctx.settings, visible: ctx.visible).freeMinutes },
            settings: ctx.settings
        )
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.edSubheadline.weight(.medium)).foregroundStyle(Tokens.ink).lineLimit(1)
                Text([item.priority == .none ? nil : item.priority.label, PlannerFormat.duration(minutes)].compactMap { $0 }.joined(separator: " · "))
                    .font(.edCaption).foregroundStyle(Tokens.muted)
            }
            Spacer(minLength: 4)
            if let target, let id = item.blockID {
                Button("To \(PlannerStyle.weekdayShortFormatter.string(from: target))") {
                    write { if let row = try PlanBlockService.default().block(id: id) { try PlanBlockService.default().move(row, toDay: target) } }
                }
                .buttonStyle(PlannerSmallButtonStyle(filled: true))
            } else {
                Text("No room this week").font(.edCaption).foregroundStyle(Tokens.muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    // MARK: Week

    private func weekRows(_ ctx: PlannerContext) -> [(day: PlannerDay, summary: CapacitySummary)] {
        weekDays.map { d in
            let day = ctx.day(d)
            return (day, PlannerEngine.capacity(of: day, settings: ctx.settings, visible: ctx.visible))
        }
    }

    @ViewBuilder
    private func weekHeader(_ ctx: PlannerContext, rows: [(day: PlannerDay, summary: CapacitySummary)]) -> some View {
        let total = rows.reduce(0) { $0 + $1.summary.bookedMinutes }
        let over = rows.filter { $0.summary.isOver }.count
        let weekNumber = calendar.component(.weekOfYear, from: weekStart)
        let end = weekDays.last ?? weekStart
        header(
            VStack(alignment: .leading, spacing: 1) {
                Text("Week \(weekNumber)").eyebrow()
                Text("\(PlannerStyle.dayMonthFormatter.string(from: weekStart)) - \(PlannerStyle.dayMonthFormatter.string(from: end))")
                    .font(.edTitle).foregroundStyle(Tokens.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text("\(PlannerFormat.duration(total)) booked\(over > 0 ? " · \(over) day\(over == 1 ? "" : "s") over" : "")")
                    .font(.edCaption)
                    .foregroundStyle(over > 0 ? Tokens.danger : Tokens.muted)
            }
        )
        PlannerSourceChips(counts: [:], hidden: hidden, onToggle: toggle)
        accessCard
    }

    /// iPhone: the week board (one row per day), unchanged this round.
    @ViewBuilder
    private func weekBoardContent(_ ctx: PlannerContext) -> some View {
        let rows = weekRows(ctx)
        weekHeader(ctx, rows: rows)
        PlannerWeekBoard(
            rows: rows.map { r in
                PlannerWeekBoard.Row(
                    day: r.day.day, summary: r.summary,
                    titles: r.day.all.filter { ctx.visible.contains($0.source) }.map(\.title)
                )
            },
            settings: ctx.settings
        ) { d in
            selectedDay = d
            mode = .day
        }
        Text("Tap a day to open its hours. A task planned to a day with no hour counts toward that day.")
            .font(.edCaption).foregroundStyle(Tokens.muted)
    }

    /// Mac: seven columns of the same grid and the same tiles.
    @ViewBuilder
    private func weekGridContent(_ ctx: PlannerContext) -> some View {
        let rows = weekRows(ctx)
        weekHeader(ctx, rows: rows)
        PlannerFillRemaining {
            PlannerWeekTimeGrid(
                columns: rows.map { .init(day: $0.day, summary: $0.summary) },
                visible: ctx.visible,
                now: ctx.now,
                settings: ctx.settings,
                onOpenDay: { d in selectedDay = d; mode = .day },
                onTapItem: tapped,
                draft: draftHandlers,
                onOpenItem: openItem
            )
        }
    }

    // MARK: To plan

    private func candidates(_ ctx: PlannerContext) -> [PlannerEngine.Candidate] {
        PlannerEngine.candidates(
            tasks: ctx.tasks, blocks: ctx.blocks, today: ctx.now,
            estimates: estimates(ctx.blocks)
        )
    }

    private func toPlanSheet(_ ctx: PlannerContext) -> some View {
        let all = candidates(ctx)
        return PlannerSheetScaffold(title: "To plan", subtitle: "\(all.count) open task\(all.count == 1 ? "" : "s") with no plan") {
            if all.isEmpty {
                Text("Every open task has a plan.").font(.edFootnote).foregroundStyle(Tokens.muted)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(all.enumerated()), id: \.element.id) { index, c in
                            if index > 0 { Rectangle().fill(Tokens.divider).frame(height: 1) }
                            PlannerToPlanRow(candidate: c) { sheet = .plan(c.task.id) }
                        }
                    }
                    .plannerCard()
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Inline quick add (macOS)

    #if os(macOS)
    private func inlineQuickAdd() -> some View {
        let trimmed = inlineText.trimmingCharacters(in: .whitespaces)
        let parsed = PlannerQuickAdd.parse(inlineText, on: selectedDay)
        return HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(Tokens.muted)
            TextField("Add a block: Call bank 3:30pm 15m", text: $inlineText)
                .textFieldStyle(.plain)
                .font(.edBody)
                .onSubmit { addInline(parsed) }
            if !trimmed.isEmpty {
                Text(parsed.start.map { PlannerStyle.range($0, parsed.end!) } ?? "No time · \(PlannerFormat.duration(parsed.durationMinutes))")
                    .font(.edCaption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Tokens.surface2, in: Capsule())
                    .overlay(Capsule().stroke(Tokens.border, lineWidth: 1))
                Button("Add") { addInline(parsed) }
                    .buttonStyle(PlannerSmallButtonStyle(filled: true, tint: Tokens.ink))
            }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Tokens.surface, in: Capsule())
        .overlay(Capsule().stroke(Tokens.borderStrong, lineWidth: 1))
    }

    private func addInline(_ parsed: PlannerQuickAdd.Result) {
        guard !inlineText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        write { try PlanBlockService.default().add(parsed) }
        inlineText = ""
    }
    #endif

    // MARK: Sheets

    /// Free intervals over the WHOLE day (not just the workday), for the
    /// quick-add "overlaps" check.
    private func openTime(on d: Date, ctx: PlannerContext) -> [DateInterval] {
        let day = ctx.day(d)
        let start = calendar.startOfDay(for: d)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let busy = day.timed.filter(\.blocksTime).map { DateInterval(start: $0.start!, end: $0.end!) }
        return PlannerEngine.freeGaps(in: DateInterval(start: start, end: end), busy: busy)
    }

    @ViewBuilder
    private func sheetView(_ kind: PlannerSheetKind, context ctx: PlannerContext) -> some View {
        switch kind {
        case .slot(let start):
            PlannerSlotSheet(
                start: start,
                candidates: candidates(ctx),
                onAddBlock: { parsed in write { try PlanBlockService.default().add(parsed) } },
                onPlaceTask: { c, s, e in
                    write { try PlanBlockService.default().planTask(taskUUID: c.task.id, title: c.task.title, start: s, end: e) }
                }
            )
        case .plan(let taskID):
            if let task = ctx.tasks.first(where: { $0.id == taskID }) {
                planSheet(task, ctx: ctx)
            } else {
                PlannerSheetScaffold(title: "Task not found") { EmptyView() }
            }
        case .quickAdd(let text):
            PlannerQuickAddSheet(
                baseDay: selectedDay,
                gapsOn: { openTime(on: $0, ctx: ctx) },
                onAdd: { parsed in write { try PlanBlockService.default().add(parsed) } },
                initialText: text
            )
        case .edit(let blockID):
            if let row = blockRows.first(where: { $0.clientUUID == blockID }) {
                PlannerBlockDetailsSheet(
                    mode: .edit(row),
                    onSave: { title, start, end, day, minutes, notes in
                        write { try PlanBlockService.default().update(row, title: title, start: start, end: end, day: day, durationMinutes: minutes, notes: notes) }
                    },
                    onDelete: {
                        // The details sheet closes, then the Planner asks how.
                        let item = ctx.day(WallClock.deviceDay(from: row.day)).all.first { $0.blockID == blockID }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pendingDelete = item }
                    },
                    onOpenTask: row.kindEnum == .task ? { openTask(row.taskUUID) } : nil
                )
            } else {
                PlannerSheetScaffold(title: "Block not found") { EmptyView() }
            }
        case .taskTime(let taskID, let start, let end):
            PlannerBlockDetailsSheet(
                mode: .planTask(title: ctx.tasks.first { $0.id == taskID }?.title ?? "Task", start: start, end: end),
                onSave: { title, s, e, day, minutes, notes in
                    write {
                        let service = PlanBlockService.default()
                        let row = (s != nil && e != nil)
                            ? try service.planTask(taskUUID: taskID, title: title, start: s!, end: e!)
                            : try service.planTask(taskUUID: taskID, title: title, toDay: day, durationMinutes: minutes)
                        if !notes.isEmpty { try service.update(row, title: row.title, start: row.start, end: row.end, day: day, durationMinutes: row.durationMinutes, notes: notes) }
                    }
                },
                onDelete: {
                    let item = ctx.day(start).timed.first { $0.taskUUID == taskID && !$0.isBlock }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pendingDelete = item }
                },
                onOpenTask: { openTask(taskID) },
                onOtherOptions: { sheet = .plan(taskID) }
            )
        case .newBlock(let start, let end, let title):
            PlannerBlockDetailsSheet(
                mode: .create(start: start, end: end, title: title),
                onSave: { title, s, e, day, minutes, notes in
                    write {
                        if let s, let e {
                            _ = try PlanBlockService.default().addManual(title: title, start: s, end: e, notes: notes)
                        } else {
                            _ = try PlanBlockService.default().addManual(title: title, day: day, durationMinutes: minutes, notes: notes)
                        }
                    }
                }
            )
        case .placeTask(let start, let end):
            PlannerSlotSheet(
                start: start,
                candidates: candidates(ctx),
                onAddBlock: { _ in },
                onPlaceTask: { c, s, e in
                    write { try PlanBlockService.default().planTask(taskUUID: c.task.id, title: c.task.title, start: s, end: e) }
                },
                defaultLength: PlannerEngine.minutes(from: start, to: end),
                showsNewBlock: false
            )
        case .event(let itemID):
            if let ev = ctx.events.first(where: { "e-\($0.id)" == itemID }) {
                PlannerEventDetailsSheet(
                    event: ev,
                    onDecline: { scope in declineEvent(ev, scope) },
                    onUndoDecline: { undoDecline(ev) },
                    onRemove: { scope in removeEvent(ev, scope) }
                )
            } else {
                PlannerSheetScaffold(title: "Event not found") { EmptyView() }
            }
        case .fixes(let d):
            fixesSheet(d, ctx: ctx)
        case .toPlan:
            toPlanSheet(ctx)
        case .settings:
            PlannerSettingsView()
        }
    }

    private func planSheet(_ task: PlannerTask, ctx: PlannerContext) -> some View {
        let today = calendar.startOfDay(for: ctx.now)
        let next = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        let options = next.map { d -> PlannerPlanTaskSheet.DayOption in
            let s = PlannerEngine.capacity(of: ctx.day(d), settings: ctx.settings)
            return .init(day: d, freeMinutes: s.freeMinutes, isWorkday: s.isWorkday)
        }
        let estimate = estimates(ctx.blocks)[task.id] ?? 30
        return PlannerPlanTaskSheet(
            task: task,
            initialEstimate: estimate,
            days: options,
            slots: { minutes in
                next.flatMap { d in
                    PlannerEngine.slots(on: ctx.day(d), minutes: minutes, settings: ctx.settings, now: ctx.now)
                }
            },
            onPlanDay: { day, minutes in
                write { try PlanBlockService.default().planTask(taskUUID: task.id, title: task.title, toDay: day, durationMinutes: minutes) }
            },
            onPlanSlot: { slot in
                write { try PlanBlockService.default().planTask(taskUUID: task.id, title: task.title, start: slot.start, end: slot.end) }
            }
        )
    }

    // MARK: Hide and decline (#689)

    private func eventFor(_ ctx: PlannerContext) -> (PlannerItem) -> PlannerEvent? {
        let byItemID = Dictionary(ctx.events.map { ("e-\($0.id)", $0) }, uniquingKeysWith: { a, _ in a })
        return { byItemID[$0.id] }
    }

    private func tileActions(_ ctx: PlannerContext) -> PlannerTileActions {
        let event = eventFor(ctx)
        return PlannerTileActions(
            quickViewID: quickView?.id,
            event: event,
            run: { cmd, item in run(cmd, item, event: event(item)) },
            dismissQuickView: { quickView = nil }
        )
    }

    /// Every tile command lands here: quick view, context menu, double click.
    private func run(_ cmd: PlannerTileCommand, _ item: PlannerItem, event ev: PlannerEvent?) {
        quickView = nil
        switch cmd {
        case .edit, .details:
            openItem(item)
        case .delete:
            if !PlannerDeletion.choices(for: item).isEmpty { pendingDelete = item }
        case .decline(let scope):
            guard let ev else { return }
            if let scope { declineEvent(ev, scope) }
            else if ev.isRecurring { pendingScope = PendingScope(kind: .decline, event: ev) }
            else { declineEvent(ev, .occurrence) }
        case .undoDecline:
            if let ev { undoDecline(ev) }
        case .remove(let scope):
            guard let ev else { return }
            if let scope { removeEvent(ev, scope) }
            else if ev.isRecurring { pendingScope = PendingScope(kind: .remove, event: ev) }
            else { removeEvent(ev, .occurrence) }
        }
    }

    private func runScoped(_ p: PendingScope, _ scope: EventOverrideService.Scope) {
        switch p.kind {
        case .decline: declineEvent(p.event, scope)
        case .remove:  removeEvent(p.event, scope)
        }
        pendingScope = nil
    }

    private func performDelete(_ choice: PlannerDeleteChoice, _ item: PlannerItem) {
        pendingDelete = nil
        Task { @MainActor in
            do {
                try await PlannerDeletion.perform(choice, for: item, store: .shared)
                writeError = nil
            } catch {
                writeError = "Couldn't delete that. \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func quickViewCard(_ item: PlannerItem, ctx: PlannerContext) -> some View {
        let event = eventFor(ctx)(item)
        PlannerQuickView(
            item: item, event: event,
            run: { run($0, item, event: event) },
            onClose: { withAnimation(.easeOut(duration: 0.18)) { quickView = nil } }
        )
    }

    // MARK: To-plan rows (#687 round 6)

    /// The Tasks section's own editor for a To-plan task.
    private func openTaskEditor(_ task: PlannerTask) {
        guard let row = todos.first(where: { $0.clientUUID.uuidString == task.id }) else { return }
        selectedToPlanID = task.id
        #if os(iOS)
        toPlanPanel = false
        #endif
        editingTodo = row.toDTO()
    }

    private func runToPlan(_ cmd: PlannerTileCommand, _ task: PlannerTask) {
        switch cmd {
        case .edit, .details: openTaskEditor(task)
        case .delete: pendingTaskDelete = task
        default: break
        }
    }

    private func askDeleteTask(_ taskID: String) {
        editingTodo = nil
        if let task = tasks.first(where: { $0.id == taskID }) { pendingTaskDelete = task }
    }

    private func deleteTask(_ taskID: String) {
        pendingTaskDelete = nil
        Task { @MainActor in
            do {
                try await PlannerDeletion.deleteTask(taskID, store: .shared)
                writeError = nil
            } catch {
                writeError = "Couldn't delete that task. \(error.localizedDescription)"
            }
        }
    }

    private func declineEvent(_ ev: PlannerEvent, _ scope: EventOverrideService.Scope) {
        write { try EventOverrideService.default().set(.declined, for: ev, scope: scope) }
    }

    private func undoDecline(_ ev: PlannerEvent) {
        write { try EventOverrideService.default().clearDecline(for: ev) }
    }

    private func removeEvent(_ ev: PlannerEvent, _ scope: EventOverrideService.Scope) {
        var id: String?
        write { id = try EventOverrideService.default().set(.hidden, for: ev, scope: scope).clientUUID }
        guard let id else { return }
        let what = scope == .series && ev.isRecurring ? "all “\(ev.title)” events" : "“\(ev.title)”"
        withAnimation(.easeOut(duration: 0.2)) {
            toast = PlannerToast(message: "Removed \(what) from the Planner", overrideID: id)
        }
    }

    private func undoToast(_ t: PlannerToast) {
        write { try EventOverrideService.default().remove(id: t.overrideID) }
        withAnimation { toast = nil }
    }

    // MARK: Drag a task onto the grid (#687 fix)

    /// Plan (or move) a task to a dropped slot. One live plan per task, so a
    /// task that already has one is moved.
    private func dropTask(_ taskID: String, title: String, at t: PlannerTaskDragCoordinator.Target) {
        write { try PlanBlockService.default().planTask(taskUUID: taskID, title: title, start: t.start, end: t.end) }
    }

    #if os(iOS)
    /// The To-plan list as a bottom panel rather than a sheet, so a row can be
    /// dragged onto the grid: the panel slides down out of the way while the
    /// row's recogniser keeps the finger.
    private func toPlanPanelView(_ ctx: PlannerContext) -> some View {
        let all = candidates(ctx)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: Space.sm) {
                Capsule().fill(Tokens.borderStrong).frame(width: 36, height: 4).frame(maxWidth: .infinity)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To plan").font(.edTitle).foregroundStyle(Tokens.ink)
                        Text("Tap a task to edit it. Touch and hold to drag it onto the grid.")
                            .font(.edCaption).foregroundStyle(Tokens.muted)
                    }
                    Spacer()
                    Button { withAnimation(.easeOut(duration: 0.25)) { toPlanPanel = false } } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.muted).frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                if all.isEmpty {
                    Text("Every open task has a plan.").font(.edFootnote).foregroundStyle(Tokens.muted)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(all.enumerated()), id: \.element.id) { index, c in
                                if index > 0 { Rectangle().fill(Tokens.divider).frame(height: 1) }
                                PlannerToPlanRow(candidate: c) {
                                    toPlanPanel = false
                                    sheet = .plan(c.task.id)
                                }
                                .background(PlannerTaskDragSource(
                                    payload: .init(c),
                                    onBegin: { withAnimation(.easeOut(duration: 0.2)) { panelTucked = true } },
                                    onEnd: { t in
                                        if let t {
                                            dropTask(c.task.id, title: c.task.title, at: t)
                                            toPlanPanel = false
                                            panelTucked = false
                                        } else {
                                            // Missed: the panel comes back, the card flies
                                            // to the row's slot, and then the row returns.
                                            withAnimation(.easeOut(duration: 0.22)) { panelTucked = false }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { taskDrag.finish() }
                                        }
                                    },
                                    onClick: { openTaskEditor(c.task) }
                                ))
                                .plannerLifted(taskDrag.payload?.taskID == c.task.id)
                            }
                        }
                        .plannerCard()
                    }
                    .frame(maxHeight: 330)
                }
            }
            .padding(Space.lg)
            .padding(.bottom, 80)
            .background(Tokens.surface, in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
            .shadowLg()
            // Tucked: slid below the screen edge while a task is dragged.
            .offset(y: panelTucked ? 520 : 0)
            .accessibilityIdentifier("planner.toplan.panel")
        }
        .ignoresSafeArea(edges: .bottom)
        .transition(.move(edge: .bottom))
    }

    /// The lifted row under the finger, at the offset it was grabbed. On a
    /// miss it flies back to the row's slot.
    @ViewBuilder
    private var dragChip: some View {
        if let payload = taskDrag.payload, let frame = taskDrag.sourceFrame {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                // An All Day pill (#693) is far smaller than a To-plan row;
                // the card keeps a readable size either way.
                let size = CGSize(width: max(frame.width, 220), height: max(frame.height, 46))
                let p = taskDrag.pointer ?? CGPoint(x: frame.minX + taskDrag.grabOffset.width, y: frame.minY + taskDrag.grabOffset.height)
                // Card origin = pointer - grab offset, except on the way back.
                let x = taskDrag.isReturning ? frame.minX : p.x - taskDrag.grabOffset.width
                let y = taskDrag.isReturning ? frame.minY : p.y - taskDrag.grabOffset.height
                PlannerDragCard(payload: payload, overSlot: taskDrag.target != nil)
                    .frame(width: size.width, height: size.height)
                    .position(x: x - origin.x + size.width / 2, y: y - origin.y + size.height / 2)
                    .animation(taskDrag.isReturning ? .easeOut(duration: 0.22) : nil, value: taskDrag.isReturning)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
    #endif

    /// Leave the Planner for the task the block places.
    private func openTask(_ uuid: String) {
        guard let id = UUID(uuidString: uuid) else { return }
        router.focus = ActivityFocus(section: .tasks, id: id)
        router.go(to: .tasks)
    }

    // MARK: Writes

    private func write(_ body: () throws -> Void) {
        do {
            try body()
            writeError = nil
        } catch {
            writeError = "Couldn't save that change. \(error.localizedDescription)"
        }
    }

    private func reloadEvents() {
        let key = loadKey
        events = calendars.events(from: key.start, to: key.end)
    }

    /// `LAUNCH_PLANNER_SHEET=slot|quickadd|plan|toplan|fixes|settings|draft|details|event` opens a
    /// sheet at launch, so a screenshot of it needs no synthetic tap (see
    /// `project_macos_agent_qa_constraints`). Consumed once.
    private func consumeLaunchSheet() {
        guard !launchSheetConsumed,
              let raw = ProcessInfo.processInfo.environment["LAUNCH_PLANNER_SHEET"]?.lowercased()
        else { return }
        launchSheetConsumed = true
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            reloadEvents()
            let fresh = PlannerContext(tasks: tasks, blocks: blocks, rawEvents: events, overrides: overrideRules, now: Date(), settings: settings, visible: visible)
            switch raw {
            case "slot", "fill":
                let free = PlannerEngine.freeTime(on: fresh.day(selectedDay), settings: settings, visible: visible, now: fresh.now)
                sheet = .slot(free.first?.start ?? PlannerEngine.roundUp(Date(), toMinutes: 15))
            case "quickadd":
                sheet = .quickAdd(ProcessInfo.processInfo.environment["LAUNCH_PLANNER_TEXT"] ?? "Call bank 3:30pm 15m")
            case "plan":
                if let c = candidates(fresh).first { sheet = .plan(c.task.id) }
            case "toplan":
                #if os(iOS)
                toPlanPanel = true
                #else
                sheet = .toPlan
                #endif
            case "draft":
                // A named draft at the next free slot, as if dragged there.
                let free = PlannerEngine.freeTime(on: fresh.day(selectedDay), settings: settings, visible: visible, now: fresh.now)
                let s = free.first?.start ?? PlannerEngine.roundUp(Date(), toMinutes: 15)
                draftTitle = ProcessInfo.processInfo.environment["LAUNCH_PLANNER_TEXT"] ?? ""
                draft = PlannerDraft(start: s, end: s.addingTimeInterval(90 * 60), isNaming: true)
            case "quickview":
                // The quick view of the first manual block today (or the tile titled LAUNCH_PLANNER_TEXT).
                let want = ProcessInfo.processInfo.environment["LAUNCH_PLANNER_TEXT"] ?? ""
                if let i = fresh.day(selectedDay).timed.first(where: { want.isEmpty ? $0.isBlock : $0.title.hasPrefix(want) }) {
                    quickView = i
                }
            case "taskeditor":
                // The Tasks editor for the first To-plan task: the reference the
                // Planner's editors are matched against.
                if let c = candidates(fresh).first { openTaskEditor(c.task) }
            case "details":
                if let b = blockRows.first(where: { $0.kindEnum == .manual && $0.isTimed }) { sheet = .edit(b.clientUUID) }
            case "event":
                // LAUNCH_PLANNER_TEXT picks the event by title prefix.
                let want = ProcessInfo.processInfo.environment["LAUNCH_PLANNER_TEXT"] ?? ""
                if let e = fresh.day(selectedDay).timed.first(where: { $0.isFixed && (want.isEmpty || $0.title.hasPrefix(want)) }) {
                    sheet = .event(e.id)
                }
            case "fixes":
                sheet = .fixes(selectedDay)
            case "settings":
                sheet = .settings
            default:
                break
            }
        }
    }
}

// MARK: - Supporting types

/// A Decline or Remove on a repeating event, waiting on its scope.
struct PendingScope: Identifiable {
    enum Kind { case decline, remove }
    let kind: Kind
    let event: PlannerEvent
    var id: String { "\(kind)-\(event.id)" }
    var title: String { kind == .remove ? "Remove from Planner" : "Decline in Dexter" }
}

enum PlannerMode: String, Hashable {
    case day, week

    /// `LAUNCH_PLANNER_MODE=day|week`, for QA screenshots. The old `agenda`
    /// and `grid` values map to Day.
    static var launchValue: PlannerMode {
        let raw = ProcessInfo.processInfo.environment["LAUNCH_PLANNER_MODE"]?.lowercased() ?? ""
        return raw == "week" ? .week : .day
    }
}

enum PlannerSheetKind: Identifiable, Equatable {
    /// A tap on empty grid space, at this time.
    case slot(Date)
    case plan(String)
    case quickAdd(String)
    case edit(String)
    case fixes(Date)
    case toPlan
    case settings
    /// "More options" on a draft: the details sheet for a new block.
    case newBlock(start: Date, end: Date, title: String)
    /// "Place a task here" on a draft.
    case placeTask(start: Date, end: Date)
    /// A calendar event's read-only details (the item id).
    case event(String)
    /// A timed task with no plan block: its start and length, with a Save.
    case taskTime(taskID: String, start: Date, end: Date)

    var id: String {
        switch self {
        case .slot(let d):     return "slot-\(d.timeIntervalSince1970)"
        case .plan(let id):    return "plan-\(id)"
        case .quickAdd(let t): return "add-\(t)"
        case .edit(let id):    return "edit-\(id)"
        case .fixes(let d):    return "fixes-\(d.timeIntervalSince1970)"
        case .toPlan:          return "toplan"
        case .settings:        return "settings"
        case .newBlock(let s, let e, _): return "new-\(s.timeIntervalSince1970)-\(e.timeIntervalSince1970)"
        case .placeTask(let s, _):       return "place-\(s.timeIntervalSince1970)"
        case .event(let id):             return "event-\(id)"
        case .taskTime(let id, let s, _): return "tasktime-\(id)-\(s.timeIntervalSince1970)"
        }
    }
}

struct PlannerLoadKey: Hashable {
    let start: Date
    let end: Date
    let revision: Int
    let access: PlannerCalendarService.Access
}

/// Everything the engine needs for one render, as values.
struct PlannerContext {
    let tasks: [PlannerTask]
    let blocks: [PlannerBlock]
    /// Calendar events AFTER the Dexter overrides (#689). There is no way to
    /// build a context without passing the rules, so no view can show a hidden
    /// event or count a declined one.
    let events: [PlannerEvent]
    let now: Date
    let settings: WorkdaySettings
    let visible: Set<PlannerSource>

    init(
        tasks: [PlannerTask], blocks: [PlannerBlock],
        rawEvents: [PlannerEvent], overrides: [EventOverrideRule],
        now: Date, settings: WorkdaySettings, visible: Set<PlannerSource>
    ) {
        self.tasks = tasks
        self.blocks = blocks
        self.events = PlannerEventOverrides.apply(rawEvents, rules: overrides)
        self.now = now
        self.settings = settings
        self.visible = visible
    }

    func day(_ d: Date) -> PlannerDay {
        PlannerEngine.day(d, events: events, blocks: blocks, tasks: tasks, now: now)
    }
}

// MARK: - To plan

struct PlannerToPlanRow: View {
    let candidate: PlannerEngine.Candidate
    let onPlan: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(PlannerStyle.priorityColor(candidate.task.priority)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.task.title)
                    .font(.edSubheadline.weight(.medium))
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Text(meta)
                    .font(.edCaption.weight(candidate.overdueDays > 0 ? .medium : .regular))
                    .foregroundStyle(candidate.overdueDays > 0 ? Tokens.danger : Tokens.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Plan", action: onPlan)
                .buttonStyle(PlannerSmallButtonStyle())
                .accessibilityLabel("Plan \(candidate.task.title)")
        }
        .padding(.trailing, 10).padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var meta: String { Self.meta(candidate) }

    /// The row's second line, also shown on the lifted card while dragged.
    static func meta(_ candidate: PlannerEngine.Candidate) -> String {
        let length = PlannerFormat.duration(candidate.estimateMinutes)
        if candidate.overdueDays > 0 {
            return "\(candidate.overdueDays == 1 ? "1 day" : "\(candidate.overdueDays) days") overdue · \(length)"
        }
        guard let due = candidate.task.due else { return "No due date · \(length)" }
        let cal = Calendar.current
        let hasHour = TaskDueTime.isSet(on: due)
        if cal.isDateInToday(due) {
            return hasHour ? "Due \(PlannerStyle.clockAP(due)) · \(length)" : "Today, no time · \(length)"
        }
        return "Due \(PlannerStyle.weekdayShortFormatter.string(from: due)) · \(length)"
    }
}

extension View {
    /// A lifted To-plan row leaves the list: it collapses to nothing and the
    /// list closes the gap. It is collapsed, not removed, because the row's
    /// own pointer view is the one tracking the drag; removing it from the
    /// window would end the drag (AppKit) or cancel the hold (UIKit).
    func plannerLifted(_ lifted: Bool) -> some View {
        self
            .frame(height: lifted ? 0 : nil, alignment: .top)
            .opacity(lifted ? 0 : 1)
            .clipped()
            .accessibilityHidden(lifted)
    }
}

extension PlannerTaskDragCoordinator.Payload {
    /// The drag payload for a To-plan row.
    init(_ c: PlannerEngine.Candidate) {
        self.init(taskID: c.task.id, title: c.task.title, minutes: c.estimateMinutes,
                  meta: PlannerToPlanRow.meta(c), priority: c.task.priority)
    }
}

/// The macOS "To plan" column.
struct PlannerInspector: View {
    let candidates: [PlannerEngine.Candidate]
    let onPlan: (PlannerEngine.Candidate) -> Void
    @Environment(\.plannerTaskDrag) private var taskDrag
    /// A row dragged onto the grid and released over a slot (#687 fix).
    var onDrop: (PlannerEngine.Candidate, PlannerTaskDragCoordinator.Target) -> Void = { _, _ in }
    /// #687 round 6: a single click selects a row, a double click opens the
    /// Tasks section's editor anchored to it, right click gives Edit and Delete.
    var selectedID: String? = nil
    var editingID: String? = nil
    var onSelect: (PlannerEngine.Candidate) -> Void = { _ in }
    var onOpen: (PlannerEngine.Candidate) -> Void = { _ in }
    var onCommand: (PlannerTileCommand, PlannerEngine.Candidate) -> Void = { _, _ in }
    var onCloseEditor: () -> Void = {}
    var editor: (PlannerEngine.Candidate) -> AnyView = { _ in AnyView(EmptyView()) }

    private struct Bucket: Identifiable {
        let title: String
        let late: Bool
        let items: [PlannerEngine.Candidate]
        var id: String { title }
    }

    private var groups: [Bucket] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekEnd = cal.date(byAdding: .day, value: 7, to: today) ?? today
        var overdue: [PlannerEngine.Candidate] = [], dueToday: [PlannerEngine.Candidate] = []
        var week: [PlannerEngine.Candidate] = [], later: [PlannerEngine.Candidate] = [], undated: [PlannerEngine.Candidate] = []
        for c in candidates {
            if c.overdueDays > 0 { overdue.append(c); continue }
            guard let due = c.task.due else { undated.append(c); continue }
            if cal.isDate(due, inSameDayAs: today) { dueToday.append(c) }
            else if due < weekEnd { week.append(c) }
            else { later.append(c) }
        }
        return [
            Bucket(title: "Overdue", late: true, items: overdue),
            Bucket(title: "Due today", late: false, items: dueToday),
            Bucket(title: "This week", late: false, items: week),
            Bucket(title: "Later", late: false, items: later),
            Bucket(title: "No date", late: false, items: undated),
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("To plan").font(.edHeading).foregroundStyle(Tokens.ink)
                Spacer()
                Text("\(candidates.count) task\(candidates.count == 1 ? "" : "s")")
                    .font(.edCaption).foregroundStyle(Tokens.muted)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            if candidates.isEmpty {
                Text("Every open task has a plan.")
                    .font(.edCaption).foregroundStyle(Tokens.muted)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(groups) { g in
                            Text(g.title).eyebrow(g.late ? Tokens.danger : Tokens.muted)
                                .padding(.horizontal, 12).padding(.top, 8)
                            ForEach(g.items) { c in
                                PlannerToPlanRow(candidate: c) { onPlan(c) }
                                    // Drag the row onto the grid to plan it
                                    // at a time; the Plan button still works.
                                    .background(PlannerTaskDragSource(
                                        payload: .init(c),
                                        onEnd: { t in if let t { onDrop(c, t) } },
                                        onClick: { onSelect(c) },
                                        onDoubleClick: { onOpen(c) },
                                        menuEntries: { PlannerTileMenu.toPlanEntries },
                                        onCommand: { onCommand($0, c) }
                                    ))
                                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                                    .paperBorder(selectedID == c.task.id ? Tokens.accentTasks : Tokens.border, radius: Radius.md)
                                    #if os(macOS)
                                    .macAnchoredPopover(
                                        isPresented: Binding(
                                            get: { editingID == c.task.id },
                                            set: { if !$0, editingID == c.task.id { onCloseEditor() } }
                                        ),
                                        preferredEdge: .minX
                                    ) {
                                        editor(c)
                                    }
                                    #endif
                                    .padding(.horizontal, 8)
                                    .plannerLifted(taskDrag.payload?.taskID == c.task.id)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                    .animation(.easeOut(duration: 0.2), value: taskDrag.payload?.taskID)
                }
            }
            Rectangle().fill(Tokens.border).frame(height: 1)
            Text("Double-click a task to edit it. Drag it onto the grid to plan it at a time, or use Plan for a day or a slot.")
                .font(.edCaption).foregroundStyle(Tokens.muted)
                .padding(12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Tokens.surface2)
    }
}

/// Gives its content exactly the height left over, and never asks for more.
///
/// Belt and braces for #687 round 2. Once the Mac pane stopped being one
/// scroll, anything above the grid with a large MINIMUM height pushed the
/// whole split view taller than the window, and the sidebar, inspector and
/// detail all slid off screen. The cause that bit was a `Text` with
/// `.fixedSize(horizontal: false, vertical: true)` in the access card, which
/// reports a huge height when measured at zero width. A `GeometryReader` has
/// no minimum height of its own, so the grid can never add to that.
struct PlannerFillRemaining<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            content.frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxHeight: .infinity)
    }
}
