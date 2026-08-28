import SwiftUI
import Combine
#if os(macOS)
import AppKit
#endif

struct TasksView: View {
    @State private var viewModel = TodosViewModel()
    /// What the new-task editor is opened with: nothing, or a file to read (#402).
    @State private var editorTarget: TaskEditorTarget?
    /// Pickers behind the plus menu's capture entries.
    @State private var showingDocumentPicker = false
    #if os(iOS)
    @State private var showingDocumentCamera = false
    @State private var showingDocumentPhotos = false
    #endif
    @State private var editingTodo: Todo?
    @State private var completedExpanded: Bool = false
    // Per-section tap-below inline draft state.
    // draftBucket == nil → no draft active; non-nil → draft in that section.
    private enum DraftBucket: String { case today, tomorrow, thisWeek, later, noDate }
    @State private var draftBucket: DraftBucket? = nil
    @State private var draftText: String = ""
    @FocusState private var draftFocused: Bool
    /// Drives the read-only month calendar popover (#385). Anchored to the
    /// top-bar button on iOS and to the window-toolbar button on macOS.
    @State private var showingCalendar = false
    /// Ticket count per task (#399), driving the pass chip. Counted in one fetch
    /// for the whole visible list rather than per row, and refreshed on the same
    /// signals that reload the tasks themselves.
    @State private var ticketCounts: [UUID: TaskTicketService.Summary] = [:]
    @Bindable var router: AppRouter

    var body: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()

            VStack(spacing: 0) {
                // iOS in-view top bar; macOS uses the native window toolbar
                // via `.macSectionChrome` below (issue #283).
                #if os(iOS)
                TopBar(
                    title: "Tasks",
                    onMenu: {
                        withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true }
                    },
                    trailing: {
                        // Month calendar across tasks AND trips (#385). Same
                        // top-bar slot Notes/Lists use for Archive, so the
                        // section-level affordances share one home.
                        TopBarIconButton(
                            systemName: "calendar",
                            accessibilityLabel: "View calendar",
                            action: { showingCalendar = true }
                        )
                        .popover(isPresented: $showingCalendar) {
                            TaskCalendarPopover()
                        }
                    }
                )
                #endif

                // Using `List` (not `ScrollView { LazyVStack }`) so each row
                // can opt into native `.swipeActions`. The list is dressed
                // down to keep the editorial paper styling: clear row
                // backgrounds, hidden separators, and `.scrollContentBackground`
                // hidden so `Tokens.paper` shows through.
                // Wrapped in a ScrollViewReader so the focused inline draft row can be
                // scrolled clear of the keyboard (SwiftUI's default List avoidance
                // won't lift it because there's content below the draft).
                ScrollViewReader { proxy in
                    // Plain, non-selectable `List` on both platforms. macOS
                    // gets NO selection binding: a selectable macOS List paints
                    // a grey row-hover highlight, which #287 wants gone. Without
                    // a selection model there is nothing to highlight on hover,
                    // and `.macTamedListSelection()` (selectionDisabled) below
                    // still guards against the inline-edit grey from issue #285.
                    let listView = List { taskListRows }
                    listView
                    .listStyle(.plain)
                    .listSectionSpacingCompat(0)
                    .scrollContentBackground(.hidden)
                    .background(Tokens.paper)
                    // macOS: mark rows non-selectable so `List` never paints a
                    // selection/edit highlight behind a focused inline-edit row
                    // (issue #285). Rows carry their own tap gestures + buttons.
                    .macTamedListSelection()
                    // Pull-to-refresh runs a sync pass, then reloads (#363).
                    .syncRefreshable { await viewModel.load() }
                    // When the inline draft gains focus, scroll it clear of the keyboard.
                    .onChange(of: draftFocused) { _, focused in
                        guard focused else { return }
                        // Let the keyboard finish animating in (viewport shrinks) before scrolling,
                        // otherwise the target position is computed against the full-height viewport.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("draftTaskRow", anchor: .bottom)
                            }
                        }
                    }
                }
            }

            addMenuButton
            .padding(.trailing, 22)
            .padding(.bottom, BottomTabBarMetrics.fabBottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            // Hide the FAB while an inline draft is active — the user is already
            // adding a task inline, so the FAB is redundant and visually distracting.
            .opacity(draftBucket == nil ? 1 : 0)
            .allowsHitTesting(draftBucket == nil)
            .animation(.easeOut(duration: 0.15), value: draftBucket)
        }
        // Dim the list while an attachment is being read, so the operation reads as
        // app-wide rather than as something happening in one small card (#416).
        .dimsWhileReadingAnAttachment()
        .activeSection(.tasks)
        .macSectionChrome("Tasks") {
            // macOS home for the calendar (#385): the native window toolbar,
            // where the popover gets a proper anchor and hover works.
            Button { showingCalendar = true } label: {
                Image(systemName: "calendar")
            }
            .help("View calendar")
            .accessibilityLabel("View calendar")
            .popover(isPresented: $showingCalendar) {
                TaskCalendarPopover()
            }
        }
        // Publish this section's create action so File > New Task and ⌘N reach
        // it while Tasks is on screen (issue #295). Same target as the add
        // button, so the menu and the button cannot diverge.
        #if os(macOS)
        .focusedSceneValue(\.newItemAction, NewItemAction(title: "New Task") {
            editorTarget = .blank
        })
        #endif
        // Live-refresh when the voice-capture or chat path writes a task.
        .onReceive(NotificationCenter.default.publisher(for: .localStoreDidChange)) { _ in
            Task {
                await viewModel.load()
                reloadTicketCounts()
            }
        }
        .task {
            await viewModel.load()
            reloadTicketCounts()
        }
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
        // New-task editor. On iOS a full sheet; on macOS the same restyled
        // editor presented as a compact modal sheet (the FAB has no anchor for
        // a popover — the per-task detail editor is the popover, issue #287).
        .sheet(item: $editorTarget) { target in
            TaskEditorSheet(
                viewModel: viewModel,
                todo: nil,
                initialDocument: target.document
            )
        }
        // Capture entries on the plus menu (#402). A picked file becomes the
        // editor's `initialDocument`, so the editor opens straight away and reads it
        // with its own spinner rather than making the person wait on a blank screen.
        #if os(iOS)
        .fullScreenCover(isPresented: $showingDocumentCamera) {
            CameraPicker { data in
                showingDocumentCamera = false
                openEditor(with: data, isPDF: false)
            }
            .ignoresSafeArea()
        }
        .photoLibraryPicker(isPresented: $showingDocumentPhotos) { data in
            openEditor(with: data, isPDF: false)
        }
        #endif
        .ticketFilePicker(isPresented: $showingDocumentPicker) { data, isPDF in
            openEditor(with: data, isPDF: isPDF)
        }
        // Detail editor from a row's info button. iOS only — macOS presents
        // this as a popover anchored to the info button inside `TaskRow`.
        #if os(iOS)
        .sheet(item: $editingTodo) { todo in
            TaskEditorSheet(viewModel: viewModel, todo: todo)
        }
        #endif
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

    // iOS uses the ghost→draft swap + programmatic autofocus below. macOS was
    // split off (#287) to a PERSISTENT native add-field (`MacAddTaskRow`) the
    // user clicks directly — the programmatic focus here raced the initiating
    // mouse-up on macOS and lost, requiring a second click. These two helpers
    // are therefore iOS-only now; `suggestedDueDate` is shared with the macOS
    // add-field so it stays unguarded.
    #if os(iOS)
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
    #endif

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
            // The last day the section covers, not a fixed +3 (#418). Now that This
            // Week ends with the week, +3 can land in Later and the task would
            // vanish out of the section it was typed into. Falls back to the day
            // after tomorrow, which is the earliest day the section can hold.
            let window = TaskBucketWindow()
            let day = window.lastDayOfThisWeek ?? window.dayAfterTomorrow
            return cal.date(bySettingHour: 23, minute: 0, second: 0, of: day)
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
        #if os(macOS)
        // macOS: a persistent one-click add-field (see MacAddRow / #287)
        // instead of the invisible tap-zone → autofocusing draft row.
        MacAddRow(label: "New Task", minHeight: 28, onCreate: { title in
            Task { await viewModel.create(title: title, dueDate: suggestedDueDate(for: .noDate)) }
        })
        .id("macAdd-empty")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        #else
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
            .id("draftTaskRow")
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
        #endif
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

            #if os(macOS)
            // macOS: a persistent one-click add-field (see MacAddRow / #287)
            // rather than a button that reveals an autofocusing draft row (which
            // had the second-click focus race). Width-capped so it sits neatly
            // under the celebratory block.
            MacAddRow(label: "New Task", minHeight: 28, onCreate: { title in
                Task { await viewModel.create(title: title, dueDate: suggestedDueDate(for: .noDate)) }
            })
            .id("macAdd-allcaughtup")
            .frame(maxWidth: 320)
            #else
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
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, Space.xxxl)
        .padding(.horizontal, Space.lg)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    // MARK: - List body

    /// The `List`'s rows, extracted so the macOS `List(selection:)` and the iOS
    /// plain `List` can share one body without duplicating it. The rendered tree
    /// is identical to the previous inline content, so iOS is unchanged.
    @ViewBuilder
    private var taskListRows: some View {
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
            // tap-below draft; hideKeyboard() covers a focused task row. On
            // macOS, resign first responder so a click in the empty area below
            // the list ends the persistent add-field's edit → commit (#287 bug 2).
            .onTapGesture {
                draftFocused = false; hideKeyboard()
                #if os(macOS)
                macResignFirstResponder()
                #endif
            }
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
    /// time. Priority still renders on each row (as the row's colored wash,
    /// #376) — it no longer affects ordering.
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
        // Boundaries live in `TaskBucketWindow` (#418): This Week ends when the week
        // ends, not seven rolling days out, and the arithmetic is testable there.
        let window = TaskBucketWindow()

        var b = TaskBuckets()
        b.completed = viewModel.todos.filter { $0.completed }
        let open = viewModel.todos.filter { !$0.completed }
        for todo in open {
            guard let due = todo.dueDate else { b.noDate.append(todo); continue }
            switch window.bucket(for: due) {
            case .overdue:  b.overdue.append(todo)
            case .today:    b.today.append(todo)
            case .tomorrow: b.tomorrow.append(todo)
            case .thisWeek: b.thisWeek.append(todo)
            case .later:    b.later.append(todo)
            }
        }
        b.overdue = chronoSorted(b.overdue)
        b.today = chronoSorted(b.today)
        b.tomorrow = chronoSorted(b.tomorrow)
        b.thisWeek = chronoSorted(b.thisWeek)
        b.later = chronoSorted(b.later)
        b.noDate = chronoSorted(b.noDate)
        return b
    }

    // MARK: - Add menu + capture
    /// The plus button (#402). A task can be created two ways — from a document or
    /// by typing — so the button offers the choice rather than assuming the second,
    /// mirroring the capture menu Finance already uses.
    ///
    /// Capture sits above the divider because that is the new capability people came
    /// for; manual entry stays last and is also what ⌘N and File > New Task reach, so
    /// the fast path for someone who just wants to type is still one keystroke.
    private var addMenuButton: some View {
        Menu {
            #if os(iOS)
            // Hidden without a camera (simulators, and any Mac): the picker would
            // silently fall back to the photo library and make two entries redundant.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    Haptics.light()
                    showingDocumentCamera = true
                } label: {
                    Label("Scan a document", systemImage: "camera")
                }
            }
            Button {
                Haptics.light()
                showingDocumentPhotos = true
            } label: {
                Label("From Photos", systemImage: "photo.on.rectangle")
            }
            #endif
            Button {
                showingDocumentPicker = true
            } label: {
                Label("From a file", systemImage: "doc.text")
            }
            Divider()
            Button {
                editorTarget = .blank
            } label: {
                Label("Enter manually", systemImage: "pencil")
            }
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
        .accessibilityLabel("Add a task")
    }

    /// Open the new-task editor on a picked file. `nil` is a cancelled picker.
    ///
    /// The presentation waits for the picker to finish dismissing. Asking SwiftUI to
    /// present a sheet from the same view in the same turn another presentation is
    /// tearing down gets the request dropped, and the symptom is a file pick that
    /// silently does nothing. The delay is the dismissal animation, so it reads as
    /// the picker closing rather than as lag.
    private func openEditor(with data: Data?, isPDF: Bool) {
        guard let data, !data.isEmpty else { return }
        let upload = TaskDocumentUpload(data: data, isPDF: isPDF)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            editorTarget = .document(upload)
        }
    }

    private func reloadTicketCounts() {
        let ids = Set(viewModel.todos.map(\.id))
        guard !ids.isEmpty else {
            ticketCounts = [:]
            return
        }
        if let counts = try? TaskTicketService().counts(todoIds: ids) {
            ticketCounts = counts
        }
    }

    /// Renders a task section with an optional per-section tap-below affordance.
    /// Pass `bucket: nil` for sections that should not have tap-below (e.g. Overdue).
    @ViewBuilder
    private func taskSection(title: String, count: Int, accent: Color, soft: Color, todos: [Todo], bucket: DraftBucket?) -> some View {
        Section {
            ForEach(todos) { todo in
                TaskRow(
                    todo: todo,
                    viewModel: viewModel,
                    isDraftActive: draftBucket != nil,
                    onToggle: { Task { await viewModel.toggleCompleted(todo) } },
                    onInfoTap: { editingTodo = todo },
                    onTitleCommit: { newTitle in
                        Task { await viewModel.update(todo, title: newTitle, description: todo.description, dueDate: todo.dueDate, tag: todo.tag) }
                    },
                    onTapWhileDraftActive: { draftFocused = false },
                    attachments: ticketCounts[todo.id]
                )
                .swipeToDeleteTrash {
                    Task { await viewModel.delete(todo) }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .contentRowInsets(vertical: TaskRowMetrics.listVInset)
            }

            // Tap-below affordance for this section (skipped for Overdue).
            if let bucket {
                #if os(macOS)
                // macOS: a PERSISTENT native add-field the user clicks directly.
                // Focus comes from the real mouse-down — one click, no race —
                // replacing the iOS ghost→draft swap + programmatic autofocus
                // that lost first responder to the List and needed a second
                // click (#287, bug 1). Zero listRowInsets: MacAddRow owns
                // its own insets so its hairline aligns with the Completed
                // separator, exactly like the ghost it replaces.
                MacAddRow(label: "New Task", minHeight: 28, onCreate: { title in
                    Task { await viewModel.create(title: title, dueDate: suggestedDueDate(for: bucket)) }
                })
                .id("macAdd-\(bucket.rawValue)")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                #else
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
                    .id("draftTaskRow")
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
                #endif
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
                        viewModel: viewModel,
                        isDraftActive: draftBucket != nil,
                        onToggle: { Task { await viewModel.toggleCompleted(todo) } },
                        onInfoTap: { editingTodo = todo },
                        onTitleCommit: { newTitle in
                            Task { await viewModel.update(todo, title: newTitle, description: todo.description, dueDate: todo.dueDate, tag: todo.tag) }
                        },
                        onTapWhileDraftActive: { draftFocused = false },
                        attachments: ticketCounts[todo.id]
                    )
                    .swipeToDeleteTrash {
                        Task { await viewModel.delete(todo) }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentRowInsets(vertical: TaskRowMetrics.listVInset)
                }
            }
        } header: {
            VStack(spacing: 0) {
                // Hairline demarcating the boundary between open and completed tasks.
                Rectangle()
                    .fill(Tokens.border)
                    .frame(height: 1)
                    .padding(.horizontal, RowMetrics.hairlineInset)
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
                // covers the tap-below draft; hideKeyboard() covers a focused task row. On macOS,
                // resign first responder so the persistent add-field commits (#287 bug 2).
                .simultaneousGesture(TapGesture().onEnded {
                    draftFocused = false; hideKeyboard()
                    #if os(macOS)
                    macResignFirstResponder()
                    #endif
                })
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
        // covers the tap-below draft; hideKeyboard() covers a focused task row. On macOS,
        // resign first responder so the persistent add-field commits (#287 bug 2).
        .contentShape(Rectangle())
        .onTapGesture {
            draftFocused = false; hideKeyboard()
            #if os(macOS)
            macResignFirstResponder()
            #endif
        }
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

// MARK: - Row metrics (macOS density)

/// Row sizing shared by `TaskRow` and `DraftTaskRow`. macOS uses a denser,
/// slightly smaller variant to match the Apple Reminders row rhythm (issue
/// #287); iOS keeps its established sizing byte-for-byte. These are LOCAL to
/// the Tasks views — the shared design tokens (`.edBody`, `Space`) are left
/// untouched so no other screen shifts.
private enum TaskRowMetrics {
    /// Vertical padding inside a row. Tighter on macOS for denser rows.
    static var verticalPadding: CGFloat {
        #if os(macOS)
        Space.xs
        #else
        Space.sm
        #endif
    }

    /// Extra per-row vertical inset applied via `listRowInsets`. Zero on macOS
    /// (density); 2pt on iOS (unchanged).
    static var listVInset: CGFloat {
        #if os(macOS)
        0
        #else
        2
        #endif
    }

    /// Completion-circle inner ring diameter. macOS targets the Reminders
    /// checkbox at 16pt; iOS keeps 22pt (issue #301).
    static var circleInner: CGFloat {
        #if os(macOS)
        16
        #else
        22
        #endif
    }

    /// Completion-circle outer hit frame.
    static var circleOuter: CGFloat {
        #if os(macOS)
        18
        #else
        24
        #endif
    }

    /// Checkmark glyph size, scaled to the circle.
    static var checkFont: Font {
        #if os(macOS)
        .system(size: 9, weight: .bold)
        #else
        .system(size: 11, weight: .bold)
        #endif
    }

    /// Title font: `.edBody` on both platforms.
    ///
    /// This hardcoded Inter at 15pt on macOS, described in the old comment as
    /// "~1pt under the shared `.edBody` WITHOUT touching that token". It was a
    /// local workaround for a shared ramp that was too large on the Mac.
    ///
    /// #294 fixed the ramp itself, so `.edBody` is now 13pt on macOS and the
    /// override had inverted: 15pt is 2pt LARGER than the body text it existed
    /// to compensate for, so Tasks rows would have read bigger than every other
    /// section. Deleting it is the point. A local patch that outlives the defect
    /// it patched becomes the defect (issue #301).
    static var titleFont: Font { .edBody }
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
                .frame(width: TaskRowMetrics.circleInner, height: TaskRowMetrics.circleInner)
                .frame(width: TaskRowMetrics.circleOuter, height: TaskRowMetrics.circleOuter)
                // Align circle center to firstTextBaseline as TaskRow does.
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }

            // macOS uses a dedicated borderless AppKit field that clears the
            // shared window field editor's grey fill on every focus (issue
            // #287); the SwiftUI TextField could not reach that fill on the
            // autofocusing draft row. iOS keeps the SwiftUI TextField unchanged.
            #if os(macOS)
            MacClearTextField(
                placeholder: "New task",
                text: $text,
                isFocused: Binding(
                    get: { isFocused.wrappedValue },
                    set: { isFocused.wrappedValue = $0 }
                ),
                onSubmit: onSubmit,
                onFocusChange: { focused in if !focused { onFocusLost() } }
            )
            .accessibilityLabel("New task")
            #else
            TextField("New task", text: $text)
                .paperFieldOnMac()
                .font(TaskRowMetrics.titleFont)
                .foregroundStyle(Tokens.ink)
                .submitLabel(.return)
                .focused(isFocused)
                .onSubmit { onSubmit() }
                .onChange(of: isFocused.wrappedValue) { _, nowFocused in
                    if !nowFocused { onFocusLost() }
                }
                .accessibilityLabel("New task")
            #endif

            Spacer(minLength: 0)
        }
        .padding(.vertical, TaskRowMetrics.verticalPadding)
        .padding(.horizontal, Space.md)
        .contentShape(Rectangle())
    }
}

// MARK: - Row

private struct TaskRow: View {
    let todo: Todo
    /// Backing view model. On macOS it builds the inline detail-editor popover
    /// anchored to this row's info button (issue #287). Unused on iOS, where
    /// the info tap opens a sheet via `onInfoTap`; stored on both so the
    /// initializer stays identical and iOS behaviour is byte-for-byte unchanged.
    let viewModel: TodosViewModel
    /// When a tap-below draft is active, suppress opening the editor sheet so the tap
    /// only dismisses the draft keyboard — nothing re-steals first responder.
    var isDraftActive: Bool = false
    let onToggle: () -> Void
    /// Tapping the trailing info icon opens the full editor (a sheet on iOS, a
    /// popover on macOS).
    let onInfoTap: () -> Void
    /// Inline title commit (tap row body → edit title → submit / focus loss).
    let onTitleCommit: (String) -> Void
    /// Called back to the parent when this row is tapped while a draft is active,
    /// so the parent can flip draftFocused = false and trigger the focus-loss → commitDraft cycle.
    var onTapWhileDraftActive: () -> Void = {}
    /// Number of tickets attached to this task (#399). Drives the pass chip. The
    /// parent counts them all in one fetch rather than each row querying, so a
    /// long list doesn't issue a query per row.
    /// Nil when the task has no attachments (#402).
    var attachments: TaskTicketService.Summary? = nil

    @State private var isEditing: Bool = false
    @State private var editText: String = ""
    /// Presents the task's tickets. Separate from the editor so the card, and the
    /// scanner behind it, are two taps from the list rather than buried in a form.
    @State private var showingTickets = false
    /// True while the editor popover has a file panel open or a read running (#416).
    /// Lives on the ROW because the popover's behaviour is set from out here: busy
    /// means it closes only when we say so, so neither Finder taking key nor a stray
    /// click behind it can bin a read in progress.
    @State private var isAttachmentBusy = false
    @FocusState private var titleFocused: Bool
    @Environment(\.openURL) private var openURL
    // macOS: local presentation state for the Reminders-style detail popover
    // anchored to the info button. iOS presents the editor as a sheet driven
    // by the parent's `editingTodo`, so this state is macOS-only.
    #if os(macOS)
    @State private var showingEditorPopover = false
    #endif

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            completionButton
                // Map the circle's center (with a 4pt body-font offset for x-height) to the
                // firstTextBaseline so the bullet visually centers on the title's first line.
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                .accessibilityLabel(todo.completed ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    // macOS: borderless AppKit field that clears the shared
                    // field editor's grey fill on every focus, so inline rename
                    // reads as clean text on the paper row (issue #287). iOS
                    // keeps the SwiftUI TextField unchanged.
                    #if os(macOS)
                    MacClearTextField(
                        placeholder: "",
                        text: $editText,
                        isFocused: Binding(
                            get: { titleFocused },
                            set: { titleFocused = $0 }
                        ),
                        onSubmit: { commitInlineEdit() },
                        onFocusChange: { focused in if !focused { commitInlineEdit() } }
                    )
                    #else
                    TextField("", text: $editText)
                        .paperFieldOnMac()
                        .font(TaskRowMetrics.titleFont)
                        .foregroundStyle(Tokens.ink)
                        .submitLabel(.done)
                        .focused($titleFocused)
                        .onSubmit { commitInlineEdit() }
                        .onChange(of: titleFocused) { _, nowFocused in
                            if !nowFocused { commitInlineEdit() }
                        }
                    #endif
                } else {
                    Text(todo.title)
                        .font(TaskRowMetrics.titleFont)
                        .strikethrough(todo.completed)
                        .foregroundStyle(todo.completed ? Tokens.mutedSoft : Tokens.ink)
                        .multilineTextAlignment(.leading)
                        // macOS: title text is the tap-to-edit target (the row
                        // tap is gated off there so the circle stays clickable).
                        #if os(macOS)
                        .contentShape(Rectangle())
                        .onTapGesture { beginBodyTap() }
                        #endif
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

                if todo.dueDate != nil || showsTagPill || showsMapPill || showsTicketPill {
                    HStack(spacing: Space.sm) {
                        if let due = todo.dueDate {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 10))
                                Text(due, format: .dateTime.month(.abbreviated).day().hour().minute())
                                // #444. An armed reminder is otherwise invisible
                                // outside the editor, so the one place the due
                                // moment is already shown is where it belongs.
                                if todo.hasArmedReminder {
                                    Image(systemName: "bell.fill")
                                        .font(.system(size: 9))
                                        .accessibilityLabel("Reminder set")
                                }
                            }
                            .font(.edCaption)
                            .foregroundStyle(dueColor(for: due))
                        }
                        if showsTagPill, let tag = todo.tag {
                            // Colour keyed to the tag itself (#338), shared with
                            // the chips in the detail popover.
                            TagPill(tag: tag)
                        }
                        if showsMapPill, let url = todo.mapsURL {
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
                        if showsTicketPill {
                            ticketChip
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                #if os(macOS)
                // macOS: open the Reminders-style detail popover anchored to
                // this button (issue #287) rather than the parent sheet.
                showingEditorPopover = true
                #else
                onInfoTap()
                #endif
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: RowMetrics.rowInfoGlyph, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(width: RowMetrics.rowInfoTarget, height: RowMetrics.rowInfoTarget, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // macOS: the editor emanates from the info button as a popover, so
            // it visually belongs to this task. iOS keeps the parent `.sheet`.
            #if os(macOS)
            // Deliberately NOT SwiftUI's `.popover` (#416): that one is transient, so
            // it was destroyed the moment Finder took key, and the whole attach then
            // happened off screen. `MacAnchoredPopover` owns the NSPopover and can
            // keep it open, which is what lets ONE surface carry the operation end to
            // end: Add, choose a file, watch it parse, see the card, edit it.
            .macAnchoredPopover(
                isPresented: $showingEditorPopover,
                isBusy: isAttachmentBusy,
                preferredEdge: .minX
            ) {
                TaskEditorSheet(
                    viewModel: viewModel,
                    todo: todo,
                    isAttachmentBusy: $isAttachmentBusy,
                    onClose: { showingEditorPopover = false }
                )
            }
            #endif
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            .accessibilityLabel("Edit task details")
        }
        .padding(.vertical, Space.sm)
        // The row now spans the pane on macOS (#339), so this padding IS the
        // content margin and has to match the one section headers and every
        // other flat row use. Unchanged on iOS, where `RowMetrics` resolves to
        // the `Space.md` this line already had.
        .padding(.horizontal, RowMetrics.horizontalPadding)
        // Priority now reads as a glass-like wash over the whole row rather
        // than a rail at its leading edge (#376) — the row carries the signal,
        // and the leading edge is left to the completion circle. `.none` rows
        // come back untinted. See `PriorityWash`.
        .priorityWash(todo.taskPriority, dimmed: todo.completed)
        // macOS: soft inset rounded hover highlight (Reminders-style), which
        // replaces the hard system selection bar killed by
        // `macTamedListSelection()` on the List. No-op on iOS.
        .macRowHover()
        .contentShape(Rectangle())
        // iOS: the WHOLE row is tap-to-edit; the completion circle beats it with
        // a high-priority gesture (see `completionButton`). On macOS a full-row
        // tap gesture greedily swallows the circle's click (the circle never
        // toggles, the row just opens the editor), so macOS scopes tap-to-edit
        // to the title text only and leaves the circle a clean Button (#285).
        #if os(iOS)
        .onTapGesture { beginBodyTap() }
        #endif
        .sheet(isPresented: $showingTickets) {
            TaskTicketsSheet(owner: .task(todo.id), context: TaskTicketContext(todo: todo))
        }
    }

    // MARK: - Pill budget
    //
    // The metadata line carries at most TWO pills (#403). Three chips plus a due
    // date turns the row into a wall of capsules and the title stops being the
    // first thing read. The two tap targets win the slots because they open
    // something the row can't otherwise reach; the tag yields, since it's still
    // on the detail popover and drives filtering elsewhere.

    /// A pass earns a pill; a plain file does not (#403). Saying FILE spent a row
    /// slot on something you can't act on from the list, and the file is one tap
    /// away in the detail sheet.
    ///
    /// "Is a pass" is the Wallet's judgement, not "has a barcode" (#437): a rental
    /// voucher whose QR only opens a booking page is scannable and is not a ticket.
    private var showsTicketPill: Bool { attachments?.holdsAPass == true }

    private var showsMapPill: Bool { todo.mapsURL != nil }

    /// Third in line, so it drops out only when both action pills are present.
    private var showsTagPill: Bool {
        guard let tag = todo.tag, !tag.isEmpty else { return false }
        return !(showsTicketPill && showsMapPill)
    }

    /// The ticket chip. Its own tap target opens the attachments without
    /// triggering the row's tap-to-rename, matching how the MAP chip guards its
    /// own tap. Only rendered for genuinely scannable attachments (#402, #403),
    /// so it can say TICKET without promising a card that doesn't exist.
    @ViewBuilder
    private var ticketChip: some View {
        if let attachments {
            let count = attachments.count
            Button {
                Haptics.light()
                showingTickets = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 10, weight: .regular))
                    // A count only earns its space once there's more than one.
                    Text(count > 1 ? "\(count) TICKETS" : "TICKET")
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
            .accessibilityLabel(count > 1 ? "Show \(count) tickets" : "Show ticket")
        }
    }

    /// Enters inline edit from a body tap. Extracted so iOS (whole-row tap) and
    /// macOS (title-text tap) share one path.
    private func beginBodyTap() {
        if isDraftActive {
            onTapWhileDraftActive()
            return
        }
        if todo.completed { return }
        if isEditing { return }
        editText = todo.title
        isEditing = true
        DispatchQueue.main.async { titleFocused = true }
    }

    /// The completion control. macOS uses a clean `Button(action:)` — with the
    /// full-row tap gated off there, nothing competes for the click. iOS keeps
    /// the empty-action + high-priority tap gesture so one tap toggles even
    /// while the inline field owns first responder (#285).
    private var completionButton: some View {
        #if os(macOS)
        Button(action: handleToggle) { completionCircle }
            .buttonStyle(.plain)
        #else
        Button(action: {}) { completionCircle }
            .buttonStyle(.plain)
            .highPriorityGesture(TapGesture().onEnded { handleToggle() })
        #endif
    }

    private var completionCircle: some View {
        ZStack {
            Circle()
                .stroke(todo.completed ? Tokens.success : Tokens.borderStrong, lineWidth: 2)
                .background(todo.completed ? Tokens.success.clipShape(Circle()) : nil)
                .frame(width: TaskRowMetrics.circleInner, height: TaskRowMetrics.circleInner)
            if todo.completed {
                Image(systemName: "checkmark")
                    .font(TaskRowMetrics.checkFont)
                    .foregroundStyle(Tokens.paper)
            }
        }
        .frame(width: TaskRowMetrics.circleOuter, height: TaskRowMetrics.circleOuter)
        // Make the whole 24pt frame hittable, not just the 2pt stroke ring —
        // otherwise a click in the transparent center falls through and the
        // toggle never fires on macOS (issue #285).
        .contentShape(Rectangle())
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

/// What the new-task editor was opened with (#402).
///
/// One sheet rather than two Bools, so "blank editor" and "editor reading a file"
/// cannot both try to present at once.
private enum TaskEditorTarget: Identifiable {
    case blank
    case document(TaskDocumentUpload)

    var id: String {
        switch self {
        case .blank: return "blank"
        case .document(let upload): return upload.id.uuidString
        }
    }

    var document: TaskDocumentUpload? {
        switch self {
        case .blank: return nil
        case .document(let upload): return upload
        }
    }
}

struct TaskEditorSheet: View {
    let viewModel: TodosViewModel
    let todo: Todo?
    /// A file to read as soon as the editor appears, filling the draft from it
    /// (#402). Nil for a blank editor and for editing an existing task.
    var initialDocument: TaskDocumentUpload? = nil
    /// Reports an in-flight attachment operation up to the presenter (#416). The
    /// macOS popover reads it to hold itself open across Finder; iOS uses it to
    /// refuse an interactive dismiss.
    var isAttachmentBusy: Binding<Bool>? = nil
    /// How to close, for a presenter with no working `dismiss` in the environment —
    /// which is the case inside `MacAnchoredPopover`, where this content is hosted in
    /// an `NSHostingController` rather than presented by SwiftUI.
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var descriptionText: String = ""
    @State private var hasDueDate: Bool = false
    // An hour out, at minute precision. `Date()` carries seconds and a fraction of
    // one that the picker never shows, and they would otherwise ride into storage
    // (#444).
    @State private var dueDate: Date = WallClock.minutePrecision(Date().addingTimeInterval(3600))
    /// Whether to notify at `dueDate` (#444). Only reachable while `hasDueDate`
    /// is on, and cleared when it goes off.
    @State private var remindMe: Bool = false
    /// Set when the person arms a reminder but notifications are switched off for
    /// Dexter, so the row can say so instead of silently doing nothing.
    @State private var remindersBlocked: Bool = false
    @State private var tag: String = ""
    @State private var priority: TaskPriority = .none
    @State private var address: String = ""
    @State private var googleMapsLink: String = ""
    @State private var isResolvingAddress = false
    @State private var addressResolveTask: Task<Void, Never>?
    /// Tickets attached while composing a task that does not exist yet (#399).
    /// Written by `save()`, thrown away by Cancel. Held here rather than in the
    /// ticket section because this view owns that lifecycle.
    @State private var pendingTickets: [TaskTicket] = []
    /// The read in flight, which puts the blocking notice over this form (#416).
    @State private var reading: TaskReadingNotice?

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
        platformBody
            // #444. Both editors share these, so they hang off the outer body
            // rather than being repeated per platform.
            .onChange(of: hasDueDate) { _, hasDate in
                // No date, nothing to remind against. Clearing here is what stops a
                // hidden `true` from being saved by a person who armed a reminder
                // and then decided against the due date.
                if !hasDate {
                    remindMe = false
                    remindersBlocked = false
                }
            }
            .onChange(of: remindMe) { _, armed in
                guard armed else {
                    remindersBlocked = false
                    return
                }
                // Ask the first time a reminder is armed, not at launch, so someone
                // who never uses reminders is never prompted.
                Task {
                    let allowed = await TaskReminderScheduler.requestAuthorizationIfNeeded()
                    remindersBlocked = !allowed
                }
            }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    // MARK: - Remind me (#444)

    /// The reminder toggle, shared by both editors.
    ///
    /// Reachable only while a due date is set, because the due moment IS the
    /// reminder moment: there is no separate reminder time to configure, so
    /// without a date there is nothing this could mean.
    @ViewBuilder
    private var remindMeRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.md) {
                Image(systemName: "bell")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Tokens.accentTasks)
                Text("Remind me")
                    .font(.edBody)
                    .foregroundStyle(Tokens.inkSoft)
                Spacer()
                Toggle("", isOn: $remindMe.animation())
                    .labelsHidden()
                    .tint(Tokens.accentTasks)
            }
            if let note = reminderNote {
                Text(note)
                    .font(.edCaption)
                    .foregroundStyle(remindersBlocked ? Tokens.danger : Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.md)
    }

    /// Why an armed reminder will not arrive, when that is the case.
    ///
    /// Both cases are silent failures otherwise: a denied permission and a moment
    /// that has already passed both leave the toggle looking armed with nothing
    /// scheduled behind it.
    private var reminderNote: String? {
        guard remindMe else { return nil }
        if remindersBlocked {
            #if os(macOS)
            return "Notifications are turned off for Dexter. Turn them on in System Settings to get this reminder."
            #else
            return "Notifications are turned off for Dexter. Turn them on in Settings to get this reminder."
            #endif
        }
        // The same instant the scheduler will use, so the caption and the behaviour
        // cannot disagree about a minute that has only just passed.
        if TaskReminderScheduler.fireDate(for: dueDate) <= Date() {
            return "That time has already passed, so this one will not fire."
        }
        return nil
    }

    // MARK: - iOS editor (full sheet, unchanged)

    #if os(iOS)
    private var iosBody: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        labeled("Title") {
                            TextField("What needs to be done?", text: $title, axis: .vertical)
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
                                            .paperDatePickerOnMac()
                                            .labelsHidden()
                                            .tint(Tokens.accentTasks)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(Space.md)

                                    // #444. Inside the same card as the date, because
                                    // the reminder has no time of its own — it fires at
                                    // the date above, so it belongs to it rather than
                                    // standing as its own section.
                                    Divider().background(Tokens.divider)
                                    remindMeRow
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
                                .paperFieldOnMac()
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
                                    .paperFieldOnMac()
                                    .noAutocapitalization()
                                    .autocorrectionDisabled(true)
                                    .urlKeyboard()
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
                        ticketsBlock
                    }
                    .padding(Space.lg)
                }
                .scrollDismissesKeyboard(.interactively)
                .blur(radius: formBlurWhileReading)

                // Inside the ZStack, so the navigation bar's Cancel sits above it.
                readingOverlay
            }
            .animation(.easeOut(duration: 0.2), value: reading)
            .navigationTitle(isEditing ? "Edit task" : "New task")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                        .foregroundStyle(Tokens.ink)
                }
            }
            .onAppear(perform: prefill)
            // Covers both Cancel and a swipe-down dismiss, and runs after a save has
            // already emptied the array.
            .onDisappear(perform: discardPendingTickets)
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(label).eyebrow()
            content()
        }
    }
    #endif

    // MARK: - Tickets (#399)

    /// Ticket attachments, on both the iOS and macOS editors.
    ///
    /// A ticket row is keyed on the task's `clientUUID`, which a task being created
    /// for the first time does not have yet. Rather than refuse until the task is
    /// saved — "save it first" being the editor's problem leaking out at the person —
    /// the ticket is read immediately and held in `pendingTickets`, then written when
    /// Add is pressed. Cancel discards it.
    @ViewBuilder
    private var ticketsBlock: some View {
        TaskTicketSection(
            owner: .task(todo?.id),
            context: ticketContext,
            pending: $pendingTickets,
            onExtracted: applyExtractedTicket,
            initialDocument: initialDocument,
            reading: $reading,
            isBusy: isAttachmentBusy ?? .constant(false)
        )
    }

    /// What the extractor is told about the event (#408), read off the LIVE editor
    /// fields rather than the saved task.
    ///
    /// Live matters: someone who has just typed the venue into a draft, or corrected
    /// the date, should have the ticket read against what is on screen. It is also
    /// the only source available at all while composing a task that does not exist
    /// yet.
    private var ticketContext: TaskTicketContext {
        TaskTicketContext(
            title: currentTitleForTickets,
            notes: descriptionText,
            dueDate: hasDueDate ? dueDate : nil,
            address: address
        )
    }

    /// The blocking notice, over the form only so Cancel stays reachable (#402).
    @ViewBuilder
    private var readingOverlay: some View {
        if let reading {
            TaskDocumentReadingOverlay(isPDF: reading.isPDF)
        }
    }

    /// How much to soften the form while the notice is over it.
    ///
    /// A scrim alone was not enough: the notice card and the editor's own rounded
    /// cards read as competing for the same space. Putting the form slightly out of
    /// focus is what stops its text from competing, and it restores itself when the
    /// values land.
    private var formBlurWhileReading: CGFloat {
        reading == nil ? 0 : 4
    }

    /// Fill the task's own fields from what the ticket said (#399).
    ///
    /// This is the point of uploading: the ticket already carries the event name,
    /// the date and the venue, so being asked to type them afterwards makes the
    /// feature pointless. Only ever fills fields the person has left EMPTY — a
    /// value they typed always wins over a parsed one.
    private func applyExtractedTicket(_ read: TaskTicketRead) {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let suggested = read.suggestedTitle {
            title = suggested
        }
        if !hasDueDate, let due = read.suggestedDueDate {
            dueDate = due
            hasDueDate = true
        }
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let venue = read.suggestedAddress {
            address = venue
        }
    }

    /// What the ticket card falls back to for its headline. Uses the live field so
    /// a card attached mid-compose is titled with what has been typed, not "".
    private var currentTitleForTickets: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (todo?.title ?? "") : trimmed
    }

    /// An attachment whose own details are the only thing naming the task still needs
    /// the task to have a title, since an untitled task cannot be saved. Filling it
    /// from the file is `applyExtractedTicket`'s job; this is the last-resort name for
    /// a file nothing could be read from, so the upload is never rejected outright.
    private static let untitledTicketTaskName = "Untitled task"

    /// Whether there is anything worth saving. A ticket on its own counts (#399): it
    /// carries the event name that becomes the title, and one the extractor could
    /// read nothing from still falls back to a generic name rather than trapping the
    /// person in an editor they cannot commit.
    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty || !pendingTickets.isEmpty
    }

    // MARK: - macOS editor (Reminders-style inspector popover, issue #287)

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            // Header: Cancel · title · Save — the Reminders "New Reminder"
            // grammar. Commit/dismiss live here instead of a window toolbar
            // because this content is presented as a popover / compact sheet.
            HStack {
                Button("Cancel") { closeEditor() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.muted)
                Spacer()
                Text(isEditing ? "Details" : "New Task")
                    .font(.edHeading)
                    .foregroundStyle(Tokens.ink)
                Spacer()
                Button(isEditing ? "Save" : "Add") { Task { await save() } }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(canSave ? Tokens.accentTasks : Tokens.muted)
                    .disabled(!canSave)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)

            Rectangle().fill(Tokens.divider).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    // Title + Notes — first grouped card, no icons (Reminders).
                    macGroup {
                        TextField("Title", text: $title, axis: .vertical)
                            .paperFieldOnMac()
                            .lineLimit(1...3)
                            .font(.edBodyMedium)
                            .foregroundStyle(Tokens.ink)
                            .padding(.horizontal, Space.md)
                            .padding(.vertical, Space.sm)
                        macRowDivider
                        TextField("Notes", text: $descriptionText, axis: .vertical)
                            .paperFieldOnMac()
                            .lineLimit(2...6)
                            .font(.edBody)
                            .foregroundStyle(Tokens.inkSoft)
                            .padding(.horizontal, Space.md)
                            .padding(.vertical, Space.sm)
                    }

                    // Tickets sits high on the Mac deliberately. This editor is a
                    // 360x520 popover, so a section at the bottom is below the
                    // fold and effectively invisible — you cannot drop a file on
                    // something you have to go looking for. iOS keeps it last,
                    // where a full-height sheet makes scrolling to it natural.
                    ticketsBlock

                    // Date & Time
                    macSectionHeader("Date & Time")
                    macGroup {
                        HStack(spacing: Space.md) {
                            macIconTile("calendar", Tokens.accentToday)
                            Text("Due Date").font(.edBody).foregroundStyle(Tokens.ink)
                            Spacer()
                            Toggle("", isOn: $hasDueDate.animation())
                                .labelsHidden()
                                .tint(Tokens.accentTasks)
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)

                        if hasDueDate {
                            macRowDivider
                            HStack(spacing: Space.md) {
                                macIconTile("clock", Tokens.accentTasks)
                                DatePicker("", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                                    .paperDatePickerOnMac()
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                                    .tint(Tokens.accentTasks)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Space.md)
                            .padding(.vertical, Space.sm)

                            // #444. Same card as the date it fires at.
                            macRowDivider
                            remindMeRow
                        }
                    }

                    // Organization (Tag)
                    macSectionHeader("Organization")
                    macGroup {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            HStack(spacing: Space.md) {
                                macIconTile("tag.fill", Tokens.accentNotes)
                                Text("Tag").font(.edBody).foregroundStyle(Tokens.ink)
                                Spacer()
                            }
                            TagChipPicker(selection: $tag, tags: availableTags)
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)
                    }

                    // Flag & Priority
                    macSectionHeader("Flag & Priority")
                    macGroup {
                        HStack(spacing: Space.md) {
                            macIconTile("flag.fill", Tokens.warning)
                            Text("Priority").font(.edBody).foregroundStyle(Tokens.ink)
                            Spacer()
                            Menu {
                                ForEach(TaskPriority.allCases, id: \.self) { p in
                                    Button(p.label) { priority = p }
                                }
                            } label: {
                                HStack(spacing: Space.xs) {
                                    Text(priority.label)
                                        .font(.edBody)
                                        .foregroundStyle(Tokens.inkSoft)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Tokens.muted)
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)
                    }

                    // Location (Address + Google Maps link)
                    macSectionHeader("Location")
                    macGroup {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            HStack(spacing: Space.md) {
                                macIconTile("mappin", Tokens.accentFinance)
                                Text("Address").font(.edBody).foregroundStyle(Tokens.ink)
                                if isResolvingAddress {
                                    ProgressView().controlSize(.small)
                                }
                                Spacer()
                            }
                            TextField("Street address or area", text: $address, axis: .vertical)
                                .paperFieldOnMac()
                                .lineLimit(1...3)
                                .font(.edSubheadline)
                                .foregroundStyle(Tokens.inkSoft)
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)

                        macRowDivider

                        HStack(spacing: Space.sm) {
                            macIconTile("map.fill", Tokens.accentTasks)
                            TextField("Google Maps link", text: $googleMapsLink)
                                .paperFieldOnMac()
                                .autocorrectionDisabled(true)
                                .font(.edSubheadline)
                                .foregroundStyle(Tokens.inkSoft)
                                .onChange(of: googleMapsLink) { _, newValue in
                                    scheduleAddressResolve(from: newValue)
                                }
                            if let url = editorMapsURL {
                                Button {
                                    openURL(url)
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Tokens.accentTasks)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open saved Google Maps link")
                            }
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)
                    }

                }
                .padding(Space.lg)
            }
            .blur(radius: formBlurWhileReading)
            // Scoped to the scrolling form, so the header's Cancel stays clickable.
            .overlay { readingOverlay }
        }
        .animation(.easeOut(duration: 0.2), value: reading)
        .frame(width: 360, height: 520)
        .background(Tokens.paper)
        .onAppear(perform: prefill)
        // Covers Cancel and dismissing the popover by clicking away, and runs after
        // a save has already emptied the array.
        .onDisappear(perform: discardPendingTickets)
    }

    private var isTitleEmpty: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Thin inset separator between rows within a grouped card.
    private var macRowDivider: some View {
        Rectangle()
            .fill(Tokens.divider)
            .frame(height: 0.5)
            .padding(.leading, Space.md)
    }

    /// Gray eyebrow header above a grouped card (Reminders section header).
    private func macSectionHeader(_ title: String) -> some View {
        Text(title)
            .eyebrow()
            .padding(.horizontal, Space.xs)
            .padding(.top, Space.xs)
    }

    /// A rounded inset card grouping one or more rows, with a hairline border.
    @ViewBuilder
    private func macGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    /// Small colored rounded tile carrying an SF Symbol — the signature
    /// Reminders row-icon affordance, tinted from the app's existing tokens.
    private func macIconTile(_ symbol: String, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color)
            .frame(width: 22, height: 22)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
    #endif

    /// Close the editor, whichever way it was presented (#416).
    ///
    /// `MacAnchoredPopover` hosts this content in an `NSHostingController`, so the
    /// environment's `dismiss` does nothing there — there is no SwiftUI presentation
    /// to dismiss, and the presenter has to be told instead.
    private func closeEditor() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func prefill() {
        guard let todo else { return }
        title = todo.title
        descriptionText = todo.description ?? ""
        if let due = todo.dueDate { hasDueDate = true; dueDate = due }
        // Only meaningful with a date, and `hasDueDate`'s own onChange would clear
        // it anyway, so read it through the same gate the editor enforces (#444).
        remindMe = todo.hasArmedReminder
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
        guard canSave else { return }
        let typed = title.trimmingCharacters(in: .whitespaces)
        let trimmed = typed.isEmpty ? Self.untitledTicketTaskName : typed
        let finalDescription = descriptionText.isEmpty ? nil : descriptionText
        let finalTag = tag.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tag
        // Minute precision, because that is all the picker ever showed (#444). Done
        // here rather than only on the seed so re-saving a task whose stored date
        // predates this normalises it too, instead of writing the stray seconds
        // straight back.
        let finalDue = hasDueDate ? WallClock.minutePrecision(dueDate) : nil
        let finalAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalMapsLink = googleMapsLink.trimmingCharacters(in: .whitespacesAndNewlines)
        // Can only be armed against a date (#444).
        let finalRemindMe = hasDueDate && remindMe

        if let existing = todo {
            await viewModel.update(existing, title: trimmed, description: finalDescription, dueDate: finalDue, tag: finalTag, address: finalAddress, googleMapsLink: finalMapsLink, priority: priority.rawValue, remindMe: finalRemindMe, clearsDueDate: !hasDueDate)
            flushPendingTickets(to: existing.id)
        } else {
            let created = await viewModel.create(title: trimmed, description: finalDescription, dueDate: finalDue, tag: finalTag, address: finalAddress, googleMapsLink: finalMapsLink, priority: priority.rawValue, remindMe: finalRemindMe)
            if let created { flushPendingTickets(to: created.id) }
        }
        closeEditor()
    }

    /// Write the tickets attached while composing, now that the task exists (#399).
    ///
    /// Their owner id was a placeholder until this moment, so it is substituted
    /// here. Clearing the array is what stops `.onDisappear` from then deleting the
    /// files we just committed to.
    private func flushPendingTickets(to todoId: UUID) {
        guard !pendingTickets.isEmpty else { return }
        _ = TaskTicketService().attachAll(pendingTickets, todoId: todoId)
        pendingTickets = []
    }

    /// Abandoning the editor throws away anything attached but never committed.
    ///
    /// The bytes are written to disk during the read, before there is a task to hang
    /// them on, so without this a cancelled compose would leak a file per upload.
    private func discardPendingTickets() {
        guard !pendingTickets.isEmpty else { return }
        let service = TaskTicketService()
        for ticket in pendingTickets {
            service.discardUnattached(ticket)
        }
        pendingTickets = []
    }
}
