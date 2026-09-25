import SwiftUI
import SwiftData

/// The Habits section (#661): every habit, with its last seven days, and
/// the numbers that say how it is going.
///
/// ### One fetch, grouped in memory
///
/// The section runs exactly two queries, both here: the habits and every live
/// check-in. `HabitLedger.group` turns the check-ins into a per-habit, per-day
/// dictionary in one pass, and each card receives its own slice as a plain
/// value. No card and no cell runs a query of its own, which is the shape that
/// froze Finance in #442.
struct HabitsView: View {
    @Bindable var router: AppRouter

    @Query(
        filter: #Predicate<LocalHabit> { $0.deletedAt == nil },
        sort: [SortDescriptor<LocalHabit>(\.sortIndex), SortDescriptor<LocalHabit>(\.createdAt)]
    )
    private var habits: [LocalHabit]

    @Query(filter: #Predicate<LocalHabitCheckIn> { $0.deletedAt == nil })
    private var checkIns: [LocalHabitCheckIn]

    @State private var editor: HabitEditorTarget?
    @State private var daySelection: HabitDaySelection?
    @State private var showArchived = false
    @State private var pulseID: String?
    /// The ONE habit whose month view is open, or nil. A single value, so
    /// opening one card closes any other (a shared accordion). Not persisted:
    /// the section always opens collapsed.
    @State private var expandedHabitID: String?
    @State private var writeError: String?

    /// Check-ins keyed by habit, then by anchored day. Built once per render.
    private var grouped: [String: [Date: HabitDayEntry]] {
        HabitLedger.group(checkIns.map { ($0.habitUUID, $0.day, $0.entry) })
    }

    var body: some View {
        let today = HabitLedger.todayAnchor()
        let grouped = self.grouped
        return screen(today: today, grouped: grouped)
            .activeSection(.habits)
            .macSectionChrome("Habits") {
                Button { editor = .new } label: {
                    Image(systemName: "plus")
                }
                .help("New habit")
                .accessibilityLabel("New habit")
            }
            .sheet(item: $editor) { target in
                editorSheet(target)
            }
            .sheet(item: $daySelection) { selection in
                daySheet(selection, today: today, grouped: grouped)
            }
    }

    private func screen(today: Date, grouped: [String: [Date: HabitDayEntry]]) -> some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()
            VStack(spacing: 0) {
                #if os(iOS)
                topBar
                #endif
                ScrollViewReader { proxy in
                    ScrollView {
                        list(today: today, grouped: grouped)
                    }
                    .onAppear { consumeFocus(proxy) }
                    .onChange(of: router.focus) { _, _ in consumeFocus(proxy) }
                }
            }
        }
    }

    #if os(iOS)
    private var topBar: some View {
        TopBar(
            title: "Habits",
            onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
        ) {
            TopBarIconButton(systemName: "plus", accessibilityLabel: "New habit") {
                editor = .new
            }
        }
    }
    #endif

    private func list(today: Date, grouped: [String: [Date: HabitDayEntry]]) -> some View {
        let active = habits.filter { !$0.isArchived }
        let archived = habits.filter(\.isArchived)
        return LazyVStack(alignment: .leading, spacing: Space.lg) {
            if let writeError {
                Text(writeError)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.danger)
            }
            if active.isEmpty {
                emptyState(hasArchived: !archived.isEmpty)
            } else {
                ForEach(active) { habit in
                    reviewCard(habit, today: today, entries: grouped[habit.clientUUID] ?? [:])
                }
            }
            if !archived.isEmpty {
                archivedSection(archived)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.lg)
        .padding(.bottom, 96)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private func reviewCard(_ habit: LocalHabit, today: Date, entries: [Date: HabitDayEntry]) -> some View {
        HabitReviewCard(
            habit: habit,
            entries: entries,
            today: today,
            isPulsing: pulseID == habit.clientUUID,
            isExpanded: expandedHabitID == habit.clientUUID,
            onToggleExpand: {
                withAnimation(.easeOut(duration: 0.2)) {
                    expandedHabitID = expandedHabitID == habit.clientUUID ? nil : habit.clientUUID
                }
            },
            onEdit: { editor = .edit(habit) },
            actions: dayActions(for: habit)
        )
        .id(habit.clientUUID)
    }

    /// One set of day actions per habit, shared by its strip and its month.
    private func dayActions(for habit: LocalHabit) -> HabitDayActions {
        HabitDayActions(
            toggle: { day in write { try HabitService.default().toggle(habit, on: day) } },
            set: { day, setting in write { try HabitService.default().set(habit, on: day, to: setting) } },
            partial: { day in daySelection = HabitDaySelection(habitUUID: habit.clientUUID, day: day) },
            isCountHabit: habit.targetCount > 1
        )
    }

    private func write(_ body: () throws -> Void) {
        do {
            try body()
            writeError = nil
            Haptics.tick()
        } catch {
            writeError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func editorSheet(_ target: HabitEditorTarget) -> some View {
        switch target {
        case .new: HabitEditorSheet(habit: nil)
        case .edit(let habit): HabitEditorSheet(habit: habit)
        }
    }

    @ViewBuilder
    private func daySheet(
        _ selection: HabitDaySelection,
        today: Date,
        grouped: [String: [Date: HabitDayEntry]]
    ) -> some View {
        if let habit = habits.first(where: { $0.clientUUID == selection.habitUUID }) {
            let entry = grouped[habit.clientUUID]?[HabitLedger.key(selection.day)]
            HabitDaySheet(
                habit: habit,
                day: selection.day,
                state: HabitLedger.state(habit.rule, entry: entry, on: selection.day, today: today)
            )
        }
    }

    // MARK: - Pieces

    private func emptyState(hasArchived: Bool) -> some View {
        VStack(spacing: Space.md) {
            Image(systemName: "flame")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Tokens.accentHabits)
            Text(hasArchived ? "No active habits" : "No habits yet")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
            Text("Add something you want to do every day, or on some days. Check it off from Today and watch the streak grow.")
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { editor = .new } label: {
                Label("New habit", systemImage: "plus")
            }
            .buttonStyle(EdButtonStyle(kind: .primary))
            .padding(.top, Space.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xxl)
        .padding(.horizontal, Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .paperBorder()
    }

    private func archivedSection(_ archived: [LocalHabit]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showArchived.toggle() }
            } label: {
                HStack(spacing: Space.xs) {
                    Text("Archived · \(archived.count)").eyebrow()
                    Image(systemName: showArchived ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tokens.muted)
                    Spacer()
                }
                .padding(.horizontal, Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showArchived {
                VStack(spacing: 0) {
                    ForEach(Array(archived.enumerated()), id: \.element.clientUUID) { index, habit in
                        HStack(spacing: Space.md) {
                            Button { editor = .edit(habit) } label: {
                                HStack(spacing: Space.md) {
                                    HabitBadge(habit: habit, size: 28)
                                    Text(habit.name)
                                        .font(.edBody)
                                        .foregroundStyle(Tokens.inkSoft)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button("Restore") {
                                try? HabitService.default().setArchived(habit, false)
                            }
                            .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                        }
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.md)
                        if index < archived.count - 1 {
                            Rectangle().fill(Tokens.divider).frame(height: 0.5).padding(.leading, Space.lg)
                        }
                    }
                }
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                .paperBorder()
            }
        }
    }

    /// A tap on a Today row lands here with the habit's id. Scroll to it,
    /// pulse it once, and clear the focus so it does not fire again.
    private func consumeFocus(_ proxy: ScrollViewProxy) {
        guard let focus = router.focus, focus.section == .habits else { return }
        let id = focus.id.uuidString.lowercased()
        router.focus = nil
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
            pulseID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeOut(duration: 0.3)) { pulseID = nil }
            }
        }
    }
}

/// What the editor sheet is open for.
enum HabitEditorTarget: Identifiable {
    case new
    case edit(LocalHabit)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let habit): return habit.clientUUID
        }
    }
}

// MARK: - One habit's review

/// One habit's card in the section (#661): header with tap-to-rename, the four
/// numbers, and the seven-day strip.
struct HabitReviewCard: View {
    let habit: LocalHabit
    /// This habit's check-ins, keyed by anchored day. Handed in; never fetched.
    let entries: [Date: HabitDayEntry]
    let today: Date
    var isPulsing: Bool = false
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onEdit: () -> Void
    let actions: HabitDayActions

    /// The month the expanded view shows. Reset to the current month each time
    /// the card opens.
    @State private var month: Date = HabitLedger.monthStart(for: HabitLedger.todayAnchor())

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool


    var body: some View {
        let rule = habit.rule
        // The rate window is the same seven days the strip shows, so the
        // number always matches what is on screen.
        let summary = HabitLedger.summary(
            rule, entries: entries, today: today, rateWindowDays: 7
        )
        let weekDays = HabitLedger.days(endingOn: today, count: 7)

        VStack(alignment: .leading, spacing: Space.lg) {
            header

            statsRow(summary)

            HabitWeekStrip(
                days: weekDays,
                states: HabitLedger.states(rule, entries: entries, days: weekDays, today: today),
                tint: habit.tint,
                actions: actions
            )

            monthToggle

            if isExpanded {
                HabitMonthView(
                    rule: rule,
                    entries: entries,
                    today: today,
                    tint: habit.tint,
                    actions: actions,
                    month: $month
                )
                .transition(.opacity)
            }
        }
        .onChange(of: isExpanded) { _, open in
            if open { month = HabitLedger.monthStart(for: today) }
        }
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .paperBorder(isPulsing ? Tokens.accentHabits : Tokens.border, lineWidth: isPulsing ? 1.5 : 0.5)
    }

    /// The explicit expand control. A Button, so macOS QA can drive it.
    private var monthToggle: some View {
        Button(action: onToggleExpand) {
            HStack(spacing: Space.xs) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                Text(isExpanded ? "Hide month" : "Month")
                    .font(.edFootnote)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Tokens.inkSoft)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide month view" : "Show month view")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.md) {
            HabitBadge(habit: habit, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.edHeading)
                        .foregroundStyle(Tokens.ink)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(commitRename)
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { commitRename() }
                        }
                } else {
                    // Tap drops the cursor straight into the name (#40 rule:
                    // tap, never long-press). A Button, so it is drivable on macOS.
                    Button(action: beginRename) {
                        Text(habit.name)
                            .font(.edHeading)
                            .foregroundStyle(Tokens.ink)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(habit.name)
                    .accessibilityHint("Rename")
                }
                Text(HabitScheduleText.summary(for: habit))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }

            Spacer(minLength: Space.sm)

            Button(action: onEdit) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(EdIconButtonStyle(tint: Tokens.inkSoft, size: 36))
            .accessibilityLabel("Edit \(habit.name)")
            .help("Edit habit")
        }
    }

    private func statsRow(_ summary: HabitSummary) -> some View {
        HStack(spacing: Space.sm) {
            statTile(
                value: "\(summary.currentStreak)",
                label: "Streak",
                icon: summary.currentStreak > 0 ? "flame.fill" : nil,
                tint: habit.tint
            )
            statTile(value: "\(summary.bestStreak)", label: "Best")
            statTile(
                value: summary.rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–",
                label: "7 days"
            )
        }
    }

    private func statTile(
        value: String,
        label: String,
        icon: String? = nil,
        tint: Color = Tokens.ink
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(value)
                    .font(.edHeading)
                    .foregroundStyle(Tokens.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(label)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.sm)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Rename

    private func beginRename() {
        draftName = habit.name
        isRenaming = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        // Empty input is a silent revert, not a delete.
        try? HabitService.default().rename(habit, to: draftName)
    }
}
