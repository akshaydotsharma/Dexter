import SwiftUI

// MARK: - Shared sheet chrome

/// The Planner's sheet chrome, in the Tasks editor's grammar (#687 round 6).
///
/// Mac: `TaskEditorSheet.macBody`'s header, Cancel · title · Save as plain text
/// buttons over a hairline, on paper. iPhone: `TaskEditorSheet.iosBody`'s
/// NavigationStack with an inline title and Cancel / Save in the bar.
struct PlannerSheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Open at full height on the iPhone (an editor, or a sheet that is mostly a list).
    var fullHeight: Bool = false
    /// When set, the header shows Cancel and Save. Nil: a single Done.
    var onSave: (() -> Void)? = nil
    var canSave: Bool = true
    /// Mac width. The editors take the Tasks editor's 360; list sheets 440.
    var width: CGFloat = 440
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.edHeading)
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.edCaption).foregroundStyle(Tokens.muted).lineLimit(1)
                    }
                }
                .padding(.horizontal, 64)
                HStack {
                    if onSave != nil {
                        Button("Cancel") { dismiss() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Tokens.muted)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("planner.sheet.cancel")
                    }
                    Spacer()
                    trailingButton
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)

            Rectangle().fill(Tokens.divider).frame(height: 0.5)

            VStack(alignment: .leading, spacing: Space.md) {
                content
            }
            .padding(Space.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width, height: 540)
        .background(Tokens.paper)
        #else
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Space.md) {
                    if let subtitle {
                        Text(subtitle).font(.edCaption).foregroundStyle(Tokens.muted)
                    }
                    content
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationTitle(title)
            .inlineNavigationTitle()
            .toolbar {
                if onSave != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .foregroundStyle(Tokens.muted)
                            .accessibilityIdentifier("planner.sheet.cancel")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { trailingButton }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationDetents(fullHeight ? [.large] : [.medium, .large])
        #endif
    }

    @ViewBuilder
    private var trailingButton: some View {
        if let onSave {
            Button("Save") { onSave(); dismiss() }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(canSave ? saveTint : Tokens.muted)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("planner.sheet.save")
        } else {
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(saveTint)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("planner.sheet.done")
        }
    }

    /// The Tasks editor: accent on the Mac, ink in the iPhone bar.
    private var saveTint: Color {
        #if os(macOS)
        Tokens.accentTasks
        #else
        Tokens.ink
        #endif
    }
}

/// One labelled group in a Planner editor: the eyebrow over a card, exactly as
/// the Tasks editor draws "Date & Time" (Mac) and "Due date" (iPhone).
struct PlannerFormSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            if let title { EdFormSectionHeader(title) }
            EdFormGroup { content }
        }
    }
}

/// A row inside a form card: icon tile, label, trailing control.
struct PlannerFormRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let label: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: Space.md) {
            EdIconTile(symbol, tint)
            Text(label).font(.edBody).foregroundStyle(Tokens.ink)
            Spacer(minLength: Space.sm)
            trailing
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }
}

/// Lengths offered for a task estimate.
enum PlannerDurations {
    static let options = [15, 30, 45, 60, 90, 120, 180, 240]
}

/// A small menu that shows a length and lets the user pick another.
struct PlannerDurationMenu: View {
    @Binding var minutes: Int
    var body: some View {
        Menu {
            ForEach(PlannerDurations.options, id: \.self) { m in
                Button(PlannerFormat.duration(m)) { minutes = m }
            }
        } label: {
            HStack(spacing: 3) {
                Text(PlannerFormat.duration(minutes)).font(.edMono)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Tokens.inkSoft)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Tokens.paper2, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Length \(PlannerFormat.duration(minutes))")
    }
}

// MARK: - Add at a time

/// What a tap on empty grid space opens (#687 round 2): the tapped time,
/// snapped to 15 minutes, with two ways to use it. Add a manual block from one
/// line of text, or place a task from the To-plan list at that time.
struct PlannerSlotSheet: View {
    let start: Date
    let candidates: [PlannerEngine.Candidate]
    let onAddBlock: (PlannerQuickAdd.Result) -> Void
    let onPlaceTask: (PlannerEngine.Candidate, Date, Date) -> Void
    /// The length a placed task starts with: the draft's, when the sheet opens
    /// from "Place a task here" (#687 round 3).
    var defaultLength: Int? = nil
    var showsNewBlock: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var lengths: [String: Int] = [:]
    @FocusState private var focused: Bool

    /// The typed line, with the tapped time filled in when the line names none.
    private var parsed: PlannerQuickAdd.Result {
        var r = PlannerQuickAdd.parse(text, on: start)
        if r.start == nil {
            r.start = start
            r.day = Calendar.current.startOfDay(for: start)
        }
        return r
    }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        PlannerSheetScaffold(
            title: "\(PlannerStyle.shortDayFormatter.string(from: start)) · \(PlannerStyle.clockAP(start))",
            subtitle: showsNewBlock ? "Add a block, or place a task at this time" : "Place a task at this time",
            fullHeight: true
        ) {
            if showsNewBlock {
                VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                    PlannerFormSection("New block") {
                        HStack(spacing: Space.sm) {
                            TextField("Focus time 45m", text: $text)
                                .font(.edBody)
                                .textFieldStyle(.plain)
                                .focused($focused)
                                .onSubmit(addBlock)
                                .accessibilityLabel("Block title and length")
                            Button("Add", action: addBlock)
                                .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                                .disabled(!hasText)
                                .opacity(hasText ? 1 : 0.5)
                        }
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.sm)
                    }
                    if let s = parsed.start, let e = parsed.end {
                        Text(hasText ? "\(parsed.title) · \(PlannerStyle.range(s, e))" : "Type a title. Add a length like 15m or 1h; the default is 30m.")
                            .font(.edCaption).foregroundStyle(Tokens.muted)
                            .padding(.horizontal, Space.xs)
                    }
                }
            }
            if candidates.isEmpty {
                Text("No open tasks to place.").font(.edFootnote).foregroundStyle(Tokens.muted)
            } else {
                VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                    EdFormSectionHeader("Place a task at \(PlannerStyle.clockAP(start))")
                    ScrollView {
                        EdFormGroup {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(candidates.prefix(12).enumerated()), id: \.element.id) { index, c in
                                    if index > 0 { EdFormRowDivider() }
                                    taskRow(c)
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func taskRow(_ c: PlannerEngine.Candidate) -> some View {
        let length = Binding<Int>(get: { lengths[c.id] ?? defaultLength ?? c.estimateMinutes }, set: { lengths[c.id] = $0 })
        return HStack(spacing: 8) {
            Rectangle().fill(PlannerStyle.priorityColor(c.task.priority)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.task.title).font(.edSubheadline.weight(.medium)).foregroundStyle(Tokens.ink).lineLimit(1)
                if c.overdueDays > 0 {
                    Text(c.overdueDays == 1 ? "1 day overdue" : "\(c.overdueDays) days overdue")
                        .font(.edCaption.weight(.medium)).foregroundStyle(Tokens.danger)
                } else if c.task.priority != .none {
                    Text(c.task.priority.label).font(.edCaption).foregroundStyle(Tokens.muted)
                }
            }
            Spacer(minLength: 4)
            PlannerDurationMenu(minutes: length)
            Button("Place") {
                let end = start.addingTimeInterval(TimeInterval(length.wrappedValue * 60))
                onPlaceTask(c, start, end)
                dismiss()
            }
            .buttonStyle(PlannerSmallButtonStyle(filled: true))
            .accessibilityLabel("Place \(c.task.title) at \(PlannerStyle.clockAP(start))")
        }
        .padding(.trailing, 10).padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addBlock() {
        guard hasText else { return }
        onAddBlock(parsed)
        dismiss()
    }
}

// MARK: - Plan a task

/// Plan one task to a day with no hour, or into a suggested free slot (#687).
struct PlannerPlanTaskSheet: View {
    struct DayOption: Identifiable {
        let day: Date
        let freeMinutes: Int
        let isWorkday: Bool
        var id: Date { day }
    }

    let task: PlannerTask
    let initialEstimate: Int
    /// The next seven days from today, with their free time.
    let days: [DayOption]
    /// Free slots, soonest first, for a given length.
    let slots: (Int) -> [DateInterval]
    let onPlanDay: (Date, Int) -> Void
    let onPlanSlot: (DateInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 30
    @State private var seeded = false

    var body: some View {
        PlannerSheetScaffold(title: "Plan a Task", subtitle: task.title) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    PlannerFormSection {
                        PlannerFormRow(symbol: "hourglass", tint: Tokens.accentTasks, label: "Length") {
                            PlannerDurationMenu(minutes: $minutes)
                        }
                    }
                    PlannerFormSection("Plan to a day") {
                        PlannerFlow(spacing: 6) {
                            ForEach(days) { option in
                                dayChip(option)
                            }
                        }
                        .padding(Space.md)
                    }
                    PlannerFormSection("Or pick a free slot") {
                        let found = Array(slots(minutes).prefix(6))
                        Group {
                            if found.isEmpty {
                                Text("No free slot of \(PlannerFormat.duration(minutes)) in the next seven days.")
                                    .font(.edCaption).foregroundStyle(Tokens.muted)
                            } else {
                                PlannerFlow(spacing: 6) {
                                    ForEach(found, id: \.start) { slot in
                                        Button {
                                            onPlanSlot(slot)
                                            dismiss()
                                        } label: {
                                            Text(slotLabel(slot))
                                        }
                                        .buttonStyle(PlannerSmallButtonStyle())
                                    }
                                }
                            }
                        }
                        .padding(Space.md)
                    }
                    Text("Pick a day or a slot to plan it with this length.")
                        .font(.edCaption).foregroundStyle(Tokens.muted)
                }
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            minutes = initialEstimate
        }
    }

    private var best: Date? {
        days.first { $0.isWorkday && $0.freeMinutes >= minutes }?.day
    }

    private func dayChip(_ option: DayOption) -> some View {
        let full = option.isWorkday && option.freeMinutes < minutes
        let isBest = option.day == best
        let label: String = {
            let name = Calendar.current.isDateInToday(option.day) ? "Today" : PlannerStyle.weekdayShortFormatter.string(from: option.day)
            if full { return "\(name) · full" }
            if isBest, option.isWorkday { return "\(name) · \(PlannerFormat.duration(option.freeMinutes)) free" }
            return name
        }()
        return Button {
            onPlanDay(option.day, minutes)
            dismiss()
        } label: {
            Text(label)
                .font(.edCaption.weight(isBest ? .semibold : .medium))
                .foregroundStyle(full ? Tokens.danger : (isBest ? Tokens.accentTasks : Tokens.ink))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Tokens.surface, in: Capsule())
                .overlay(Capsule().stroke(full ? Tokens.danger : (isBest ? Tokens.accentTasks : Tokens.border), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Plan to \(PlannerStyle.weekdayFormatter.string(from: option.day))\(full ? ", full" : "")")
    }

    private func slotLabel(_ slot: DateInterval) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(slot.start) ? "Today" : (cal.isDateInTomorrow(slot.start) ? "Tomorrow" : PlannerStyle.weekdayShortFormatter.string(from: slot.start))
        return "\(day) \(PlannerStyle.clockAP(slot.start))"
    }
}

// MARK: - Quick add

/// Add a manual block (#687): one line of text read on the device, or a short
/// form. "Leave out the time and the block is planned to the day only."
struct PlannerQuickAddSheet: View {
    let baseDay: Date
    /// Open time on a day, for the "it overlaps something" line.
    let gapsOn: (Date) -> [DateInterval]
    let onAdd: (PlannerQuickAdd.Result) -> Void
    var initialText: String = ""

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var showForm = false
    @State private var formTitle = ""
    @State private var formTimed = true
    @State private var formStart = Date()
    @State private var formEnd = Date()
    @State private var formDay = Date()
    @State private var formMinutes = 30
    @State private var formPanel: String?
    @State private var seeded = false
    @FocusState private var focused: Bool

    private var parsed: PlannerQuickAdd.Result { PlannerQuickAdd.parse(text, on: baseDay) }

    var body: some View {
        PlannerSheetScaffold(title: "Add to \(PlannerStyle.weekdayFormatter.string(from: baseDay))", fullHeight: showForm) {
            if showForm { ScrollView { form.padding(.bottom, Space.md) } } else { line }
            Spacer(minLength: 0)
        }
        .onAppear(perform: seed)
    }

    private var line: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            TextField("Call bank 3:30pm 15m", text: $text)
                .font(.edBody)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(addLine)
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .paperBorder(Tokens.borderStrong, radius: Radius.md, lineWidth: 1)
                .accessibilityLabel("Block, in one line")
            PlannerQuickAddPreview(parsed: parsed, hasText: !text.trimmingCharacters(in: .whitespaces).isEmpty, gaps: gapsOn(parsed.day))
            Button(action: addLine) { Text("Add block") }
                .buttonStyle(EdButtonStyle(kind: .primary, fullWidth: true))
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
            Button("Use the form instead") {
                prefillForm()
                withAnimation(.easeOut(duration: 0.2)) { showForm = true }
            }
            .buttonStyle(.plain)
            .font(.edFootnote)
            .foregroundStyle(Tokens.accentTasks)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            PlannerFormSection("Title") {
                TextField("Focus time", text: $formTitle)
                    .font(.edBody)
                    .textFieldStyle(.plain)
                    .padding(Space.md)
            }
            PlannerFormSection("Date & Time") {
                EdDateTimeField(
                    date: formStartBinding,
                    hasTime: $formTimed,
                    timeLabel: "Start",
                    tint: Tokens.accentTasks,
                    drawsCard: false,
                    openPanel: $formPanel
                )
                if formTimed {
                    EdFormRowDivider()
                    EdDateTimeField(
                        date: $formEnd,
                        showsDate: false,
                        timeLabel: "End",
                        timeIcon: "clock.badge.checkmark",
                        tint: Tokens.accentTasks,
                        drawsCard: false,
                        openPanel: $formPanel
                    )
                } else {
                    EdFormRowDivider()
                    PlannerFormRow(symbol: "hourglass", tint: Tokens.accentTasks, label: "Length") {
                        PlannerDurationMenu(minutes: $formMinutes)
                    }
                }
            }
            Button {
                let title = formTitle.trimmingCharacters(in: .whitespaces)
                if formTimed {
                    let mins = max(5, PlannerEngine.minutes(from: formStart, to: max(formEnd, formStart)))
                    onAdd(.init(title: title.isEmpty ? "Block" : title, day: Calendar.current.startOfDay(for: formStart), start: formStart, durationMinutes: mins))
                } else {
                    onAdd(.init(title: title.isEmpty ? "Block" : title, day: Calendar.current.startOfDay(for: formStart), start: nil, durationMinutes: formMinutes))
                }
                dismiss()
            } label: { Text("Add block") }
            .buttonStyle(EdButtonStyle(kind: .primary, fullWidth: true))
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Moving the start keeps the length.
    private var formStartBinding: Binding<Date> {
        Binding(get: { formStart }, set: { new in
            let length = max(300, formEnd.timeIntervalSince(formStart))
            formStart = new
            formEnd = new.addingTimeInterval(length)
        })
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        text = initialText
        focused = true
        prefillForm()
    }

    private func prefillForm() {
        let p = parsed
        formTitle = text.isEmpty ? "" : p.title
        let cal = Calendar.current
        let base = cal.startOfDay(for: p.day)
        let start = p.start ?? PlannerEngine.roundUp(
            cal.isDateInToday(base) ? Date() : base.addingTimeInterval(TimeInterval(PlannerSettings.workday.startMinute * 60)),
            toMinutes: 15
        )
        formStart = start
        formEnd = start.addingTimeInterval(TimeInterval(p.durationMinutes * 60))
        formDay = p.day
        formMinutes = p.durationMinutes
        formTimed = true
    }

    private func addLine() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onAdd(parsed)
        dismiss()
    }
}

/// The chips a typed line was read into, plus which gap it takes.
struct PlannerQuickAddPreview: View {
    let parsed: PlannerQuickAdd.Result
    let hasText: Bool
    let gaps: [DateInterval]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlannerFlow(spacing: 6) {
                chip("Block", dot: true)
                if let s = parsed.start, let e = parsed.end {
                    chip(PlannerStyle.range(s, e))
                } else {
                    chip("No time · \(PlannerFormat.duration(parsed.durationMinutes))")
                }
                chip(PlannerStyle.shortDayFormatter.string(from: parsed.day))
            }
            if hasText, let note = fitNote {
                Text(note).font(.edCaption).foregroundStyle(Tokens.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var fitNote: String? {
        guard let s = parsed.start, let e = parsed.end else { return "Planned to the day, with no hour." }
        // No free-time arithmetic here (#687 round 2): the grid shows free
        // time by its empty space. Only say when the block would overlap.
        if gaps.contains(where: { $0.start <= s && $0.end >= e }) { return nil }
        return "It overlaps something already on the day."
    }

    private func chip(_ text: String, dot: Bool = false) -> some View {
        HStack(spacing: 5) {
            if dot {
                RoundedRectangle(cornerRadius: 2.5).fill(PlannerStyle.color(.manual)).frame(width: 8, height: 8)
            }
            Text(text).font(.edCaption.weight(.medium)).foregroundStyle(Tokens.ink)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Tokens.surface, in: Capsule())
        .overlay(Capsule().stroke(Tokens.border, lineWidth: 1))
    }
}

// MARK: - Block details

/// The details of a Dexter block (#687 round 3, rebuilt in round 6 on the
/// Tasks editor's components): title and notes, then Date & Time as
/// `EdDateTimeField` rows (the one date and time control in the app, #657)
/// with the length, then the canonical `DeleteRowButton`. Opens for a new
/// draft ("More options"), for an existing block (double click, or Edit in the
/// quick view), and for a timed task that has no plan yet.
struct PlannerBlockDetailsSheet: View {
    enum Mode {
        case create(start: Date, end: Date, title: String)
        case edit(LocalPlanBlock)
        /// A timed task with no plan block yet (#687 fix): Save creates its
        /// plan block with the chosen start and length.
        case planTask(title: String, start: Date, end: Date)
    }

    let mode: Mode
    let onSave: (_ title: String, _ start: Date?, _ end: Date?, _ day: Date, _ minutes: Int, _ notes: String) -> Void
    /// Delete, handed back to the Planner, which asks how (`PlannerDeletion`).
    var onDelete: (() -> Void)? = nil
    var onOpenTask: (() -> Void)? = nil
    /// Other ways to plan the task (another day, a suggested slot).
    var onOtherOptions: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var timed = true
    /// The day, and the start time when `timed`.
    @State private var start = Date()
    @State private var end = Date()
    @State private var minutes = 30
    @State private var notes = ""
    @State private var seeded = false
    /// One accordion for the Start and End fields (#657).
    @State private var openPanel: String?

    private var isTask: Bool {
        switch mode {
        case .edit(let b): return b.kindEnum == .task
        case .planTask:    return true
        case .create:      return false
        }
    }

    private var heading: String {
        switch mode {
        case .create: return "New Block"
        case .edit(let b): return b.kindEnum == .task ? "Planned Task" : "Details"
        case .planTask: return "Plan Task"
        }
    }

    private var tint: Color { isTask ? Tokens.accentTasks : PlannerStyle.color(.manual) }

    var body: some View {
        PlannerSheetScaffold(title: heading, fullHeight: true, onSave: save, width: 360) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    titleAndNotes
                    PlannerFormSection("Date & Time") {
                        EdDateTimeField(
                            date: startBinding,
                            hasTime: $timed,
                            timeLabel: "Start",
                            tint: Tokens.accentTasks,
                            drawsCard: false,
                            openPanel: $openPanel
                        )
                        if timed {
                            EdFormRowDivider()
                            EdDateTimeField(
                                date: endBinding,
                                showsDate: false,
                                timeLabel: "End",
                                timeIcon: "clock.badge.checkmark",
                                tint: Tokens.accentTasks,
                                drawsCard: false,
                                openPanel: $openPanel
                            )
                        }
                        EdFormRowDivider()
                        HStack(spacing: Space.md) {
                            Image(systemName: "hourglass")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Tokens.accentTasks)
                                .frame(width: 18)
                            Text("Length").font(.edBody).foregroundStyle(Tokens.ink)
                            Spacer(minLength: Space.sm)
                            PlannerDurationMenu(minutes: timed ? lengthBinding : $minutes)
                                .accessibilityIdentifier("planner.details.length")
                        }
                        .padding(Space.md)
                    }
                    if let onOtherOptions {
                        Button("Plan to another day or slot…") { dismiss(); onOtherOptions() }
                            .buttonStyle(.plain)
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.accentTasks)
                    }
                    if let onDelete {
                        DeleteRowButton(title: isTask ? "Delete…" : "Delete block") {
                            dismiss()
                            onDelete()
                        }
                        .accessibilityIdentifier("planner.details.delete")
                    }
                }
                .padding(.bottom, Space.md)
            }
        }
        .onAppear(perform: seed)
        .onChange(of: timed) { _, isTimed in
            // Switching a time on gives the block its length from the start.
            if isTimed { end = start.addingTimeInterval(TimeInterval(max(15, minutes) * 60)) }
            else { minutes = max(15, PlannerEngine.minutes(from: start, to: end)) }
        }
    }

    /// Title and notes: one group with no labels on the Mac, labelled cards on
    /// the iPhone, as the Tasks editor draws them. A planned task shows its
    /// task's title with a way to open the task, since the title is the task's.
    @ViewBuilder
    private var titleAndNotes: some View {
        #if os(macOS)
        EdFormGroup {
            titleRow
            EdFormRowDivider()
            TextField(PlainFieldPlaceholder.title("Notes"), text: $notes, axis: .vertical)
                .paperFieldOnMac()
                .lineLimit(2...6)
                .font(.edBody)
                .foregroundStyle(Tokens.inkSoft)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .plainFieldPlaceholder("Notes", isVisible: notes.isEmpty, padding: Space.md)
                .accessibilityIdentifier("planner.details.notes")
        }
        #else
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(isTask ? "Task" : "Title").eyebrow()
            titleRow
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Notes").eyebrow()
            TextField("Optional notes", text: $notes, axis: .vertical)
                .lineLimit(2...6)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
                .accessibilityIdentifier("planner.details.notes")
        }
        #endif
    }

    @ViewBuilder
    private var titleRow: some View {
        if isTask {
            HStack(spacing: Space.sm) {
                Text(title)
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(2)
                Spacer(minLength: Space.sm)
                if let onOpenTask {
                    Button("Open task") { dismiss(); onOpenTask() }
                        .buttonStyle(.plain)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.accentTasks)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
        } else {
            #if os(macOS)
            TextField(PlainFieldPlaceholder.title("Title"), text: $title, axis: .vertical)
                .paperFieldOnMac()
                .lineLimit(1...3)
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .plainFieldPlaceholder("Title", isVisible: title.isEmpty, padding: Space.md)
                .accessibilityIdentifier("planner.details.title")
            #else
            TextField("What is this block for?", text: $title, axis: .vertical)
                .lineLimit(1...3)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .accessibilityIdentifier("planner.details.title")
            #endif
        }
    }

    private func save() {
        let day = Calendar.current.startOfDay(for: start)
        onSave(title, timed ? start : nil, timed ? max(end, start.addingTimeInterval(15 * 60)) : nil,
               day, timed ? PlannerEngine.minutes(from: start, to: end) : minutes, notes)
    }

    /// Moving the start (its day or its time) keeps the length.
    private var startBinding: Binding<Date> {
        Binding(get: { start }, set: { s in
            let length = max(15 * 60, end.timeIntervalSince(start))
            start = s
            end = s.addingTimeInterval(length)
        })
    }

    /// The End row carries a time only; its day is the start's. An end at or
    /// before the start means the next 15 minutes, never a negative block.
    private var endBinding: Binding<Date> {
        Binding(get: { end }, set: { e in
            let cal = Calendar.current
            let parts = cal.dateComponents([.hour, .minute], from: e)
            var candidate = cal.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: start) ?? e
            if candidate <= start { candidate = start.addingTimeInterval(15 * 60) }
            end = candidate
        })
    }

    /// The length menu sets the end.
    private var lengthBinding: Binding<Int> {
        Binding(
            get: { max(15, PlannerEngine.minutes(from: start, to: end)) },
            set: { m in end = start.addingTimeInterval(TimeInterval(m * 60)) }
        )
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        switch mode {
        case .planTask(let t, let s, let e), .create(let s, let e, let t):
            title = t
            timed = true
            start = s
            end = e
            minutes = PlannerEngine.minutes(from: s, to: e)
        case .edit(let block):
            title = block.title
            timed = block.isTimed
            notes = block.notes
            let deviceDay = WallClock.deviceDay(from: block.day)
            minutes = block.durationMinutes
            let s = block.start ?? deviceDay.addingTimeInterval(TimeInterval(PlannerSettings.workday.startMinute * 60))
            start = s
            end = block.end ?? s.addingTimeInterval(TimeInterval(block.durationMinutes * 60))
        }
    }
}

// MARK: - Calendar event

/// A calendar event's details (#687 round 3), with Dexter-only actions (#689),
/// in the Tasks editor's grouped rows (round 6). The event itself stays
/// read-only: Decline and Remove are Dexter records, the source calendar does
/// not change, and the organiser is not told.
struct PlannerEventDetailsSheet: View {
    let event: PlannerEvent
    var onDecline: ((EventOverrideService.Scope) -> Void)? = nil
    var onUndoDecline: (() -> Void)? = nil
    var onRemove: ((EventOverrideService.Scope) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var pending: Pending?

    private enum Pending: Identifiable {
        case decline, remove
        var id: Self { self }
    }

    var body: some View {
        PlannerSheetScaffold(title: "Event", fullHeight: true, width: 360) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    EdFormGroup {
                        HStack(alignment: .top, spacing: Space.md) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(PlannerStyle.color(event.source))
                                .frame(width: 12, height: 12)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                    .font(.edBodyMedium)
                                    .foregroundStyle(Tokens.ink)
                                    .strikethrough(event.decline != .none, color: Tokens.muted)
                                    .textSelection(.enabled)
                                Text(event.source == .work ? "Work calendar" : "Personal calendar")
                                    .font(.edCaption).foregroundStyle(Tokens.muted)
                                if event.decline != .none {
                                    Text(event.decline == .atSource ? "You declined this in your calendar" : "Declined in Dexter")
                                        .font(.edCaption.weight(.medium))
                                        .foregroundStyle(Tokens.danger)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Space.md)
                    }
                    PlannerFormSection("Details") {
                        infoRow("clock", "Time", when)
                        EdFormRowDivider()
                        infoRow("calendar", "Calendar", event.calendarTitle)
                        if !event.location.isEmpty {
                            EdFormRowDivider()
                            infoRow("mappin.and.ellipse", "Location", event.location)
                        }
                        if !event.notes.isEmpty {
                            EdFormRowDivider()
                            infoRow("text.alignleft", "Notes", event.notes)
                        }
                    }
                    actions
                    Text("Dexter only. The organiser is not told, and your calendar does not change.")
                        .font(.edCaption).foregroundStyle(Tokens.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { p in
            Button("Only this event") { run(p, .occurrence) }
                .accessibilityIdentifier("planner.series.only")
            Button("All events in the series") { run(p, .series) }
                .accessibilityIdentifier("planner.series.all")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This is a repeating event.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: Space.sm) {
            switch event.decline {
            case .none:
                if onDecline != nil {
                    Button { ask(.decline) } label: { Text("Decline in Dexter") }
                        .buttonStyle(EdButtonStyle(kind: .secondary, fullWidth: true))
                        .accessibilityIdentifier("planner.event.decline")
                }
            case .inDexter:
                if let onUndoDecline {
                    Button { onUndoDecline(); dismiss() } label: { Text("Undo decline") }
                        .buttonStyle(EdButtonStyle(kind: .secondary, fullWidth: true))
                        .accessibilityIdentifier("planner.event.undodecline")
                }
            case .atSource:
                EmptyView()
            }
            if onRemove != nil {
                DeleteRowButton(title: "Remove from Planner", systemImage: "eye.slash") { ask(.remove) }
                    .accessibilityIdentifier("planner.event.remove")
            }
        }
    }

    private var dialogTitle: String {
        pending == .remove ? "Remove from Planner" : "Decline in Dexter"
    }

    private func ask(_ p: Pending) {
        if event.isRecurring { pending = p } else { run(p, .occurrence) }
    }

    private func run(_ p: Pending, _ scope: EventOverrideService.Scope) {
        switch p {
        case .decline: onDecline?(scope)
        case .remove:  onRemove?(scope)
        }
        pending = nil
        dismiss()
    }

    private var when: String {
        let day = PlannerStyle.weekdayFormatter.string(from: event.start) + " " + PlannerStyle.dayMonthFormatter.string(from: event.start)
        return event.isAllDay ? "\(day), all day" : "\(day), \(PlannerStyle.range(event.start, event.end))"
    }

    private func infoRow(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PlannerStyle.color(event.source))
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.edBody).foregroundStyle(Tokens.ink)
                Text(value).font(.edCaption).foregroundStyle(Tokens.inkSoft).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
    }
}
