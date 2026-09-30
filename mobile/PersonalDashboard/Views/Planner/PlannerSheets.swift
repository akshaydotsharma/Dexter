import SwiftUI

// MARK: - Shared sheet chrome

/// A titled sheet body with a close button, sized for macOS where a sheet has
/// no intrinsic size (#474).
struct PlannerSheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Open at full height on the iPhone (for a sheet that is mostly a list).
    var fullHeight: Bool = false
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.edTitle).foregroundStyle(Tokens.ink)
                    if let subtitle {
                        Text(subtitle).font(.edCaption).foregroundStyle(Tokens.muted)
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.muted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            content
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.surface)
        #if os(macOS)
        .frame(width: 440, height: 560)
        #else
        .presentationDragIndicator(.visible)
        .presentationDetents(fullHeight ? [.large] : [.medium, .large])
        #endif
    }
}

/// Lengths offered for a task estimate.
enum PlannerDurations {
    static let options = [15, 30, 45, 60, 90, 120, 180]
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
            subtitle: showsNewBlock ? "Add a block, or place a task at this time" : "Place a task at this time"
        ) {
            if showsNewBlock {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("New block").eyebrow()
                HStack(spacing: Space.sm) {
                    TextField("Focus time 45m", text: $text)
                        .font(.edBody)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(addBlock)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .paperBorder(Tokens.borderStrong, radius: Radius.md, lineWidth: 1)
                        .accessibilityLabel("Block title and length")
                    Button("Add", action: addBlock)
                        .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                        .disabled(!hasText)
                        .opacity(hasText ? 1 : 0.5)
                }
                if let s = parsed.start, let e = parsed.end {
                    Text(hasText ? "\(parsed.title) · \(PlannerStyle.range(s, e))" : "Type a title. Add a length like 15m or 1h; the default is 30m.")
                        .font(.edCaption).foregroundStyle(Tokens.muted)
                }
            }
            }
            if candidates.isEmpty {
                Text("No open tasks to place.").font(.edFootnote).foregroundStyle(Tokens.muted)
            }
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Place a task at \(PlannerStyle.clockAP(start))").eyebrow()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(candidates.prefix(12).enumerated()), id: \.element.id) { index, c in
                                if index > 0 { Rectangle().fill(Tokens.divider).frame(height: 1) }
                                taskRow(c)
                            }
                        }
                        .plannerCard()
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
        PlannerSheetScaffold(title: "Plan a task", subtitle: task.title) {
            HStack {
                Text("Length").font(.edFootnote).foregroundStyle(Tokens.muted)
                Spacer()
                PlannerDurationMenu(minutes: $minutes)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Plan to a day").eyebrow()
                PlannerFlow(spacing: 6) {
                    ForEach(days) { option in
                        dayChip(option)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Or pick a free slot").eyebrow()
                let found = Array(slots(minutes).prefix(6))
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
            Spacer(minLength: 0)
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
    @State private var seeded = false
    @FocusState private var focused: Bool

    private var parsed: PlannerQuickAdd.Result { PlannerQuickAdd.parse(text, on: baseDay) }

    var body: some View {
        PlannerSheetScaffold(title: "Add to \(PlannerStyle.weekdayFormatter.string(from: baseDay))") {
            if showForm { form } else { line }
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
            VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                Text("Title").eyebrow()
                TextField("Focus time", text: $formTitle)
                    .font(.edBody)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            Toggle("At a time", isOn: $formTimed)
                .font(.edBody)
                .tint(Tokens.accentTasks)
            if formTimed {
                DatePicker("Start", selection: $formStart)
                    .font(.edBody)
                DatePicker("End", selection: $formEnd, in: formStart...)
                    .font(.edBody)
            } else {
                DatePicker("Day", selection: $formDay, displayedComponents: .date)
                    .font(.edBody)
                HStack {
                    Text("Length").font(.edBody)
                    Spacer()
                    PlannerDurationMenu(minutes: $formMinutes)
                }
            }
            Button {
                let title = formTitle.trimmingCharacters(in: .whitespaces)
                if formTimed {
                    let mins = max(5, PlannerEngine.minutes(from: formStart, to: max(formEnd, formStart)))
                    onAdd(.init(title: title.isEmpty ? "Block" : title, day: Calendar.current.startOfDay(for: formStart), start: formStart, durationMinutes: mins))
                } else {
                    onAdd(.init(title: title.isEmpty ? "Block" : title, day: Calendar.current.startOfDay(for: formDay), start: nil, durationMinutes: formMinutes))
                }
                dismiss()
            } label: { Text("Add block") }
            .buttonStyle(EdButtonStyle(kind: .primary, fullWidth: true))
            .keyboardShortcut(.defaultAction)
        }
        .onChange(of: formStart) { old, new in
            // Keep the length when the start moves.
            let length = formEnd.timeIntervalSince(old)
            formEnd = new.addingTimeInterval(max(300, length))
        }
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
        let base = cal.startOfDay(for: baseDay)
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

/// The details of a Dexter block (#687 round 3): title, day, start, end and
/// notes, plus Delete. Opens for a new draft ("More options") and for an
/// existing block (click or tap its tile). A planned task shows its task title
/// and a link to the task instead of an editable title.
struct PlannerBlockDetailsSheet: View {
    enum Mode {
        case create(start: Date, end: Date, title: String)
        case edit(LocalPlanBlock)
    }

    let mode: Mode
    let onSave: (_ title: String, _ start: Date?, _ end: Date?, _ day: Date, _ minutes: Int, _ notes: String) -> Void
    var onDelete: (() -> Void)? = nil
    var onOpenTask: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var timed = true
    @State private var start = Date()
    @State private var end = Date()
    @State private var day = Date()
    @State private var minutes = 30
    @State private var notes = ""
    @State private var seeded = false
    @State private var confirmDelete = false

    private var isTask: Bool {
        if case .edit(let b) = mode { return b.kindEnum == .task }
        return false
    }

    private var heading: String {
        switch mode {
        case .create: return "New block"
        case .edit(let b): return b.kindEnum == .task ? "Planned task" : "Block"
        }
    }

    var body: some View {
        PlannerSheetScaffold(title: heading) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    if isTask {
                        HStack {
                            Text(title).font(.edHeading).foregroundStyle(Tokens.ink)
                            Spacer()
                            if let onOpenTask {
                                Button("Open task") { dismiss(); onOpenTask() }
                                    .buttonStyle(PlannerSmallButtonStyle())
                            }
                        }
                    } else {
                        field("Title") {
                            TextField("Title", text: $title)
                                .font(.edBody)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                                .accessibilityIdentifier("planner.details.title")
                        }
                    }
                    Toggle("At a time", isOn: $timed).font(.edBody).tint(Tokens.accentTasks)
                    if timed {
                        DatePicker("Date", selection: dateBinding, displayedComponents: .date).font(.edBody)
                        DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute).font(.edBody)
                        DatePicker("End", selection: $end, in: start..., displayedComponents: .hourAndMinute).font(.edBody)
                    } else {
                        DatePicker("Day", selection: $day, displayedComponents: .date).font(.edBody)
                        HStack {
                            Text("Length").font(.edBody)
                            Spacer()
                            PlannerDurationMenu(minutes: $minutes)
                        }
                    }
                    field("Notes") {
                        TextEditor(text: $notes)
                            .font(.edBody)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 90)
                            .padding(6)
                            .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                            .accessibilityIdentifier("planner.details.notes")
                    }
                    Button {
                        onSave(title, timed ? start : nil, timed ? max(end, start.addingTimeInterval(300)) : nil, timed ? Calendar.current.startOfDay(for: start) : day, minutes, notes)
                        dismiss()
                    } label: { Text("Save") }
                    .buttonStyle(EdButtonStyle(kind: .primary, fullWidth: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("planner.details.save")
                    if let onDelete {
                        Button { confirmDelete = true } label: {
                            Text(isTask ? "Remove from plan" : "Delete block")
                        }
                        .buttonStyle(EdButtonStyle(kind: .danger, fullWidth: true))
                        .confirmationDialog(isTask ? "Remove this task from the plan?" : "Delete this block?",
                                            isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button(isTask ? "Remove from plan" : "Delete block", role: .destructive) {
                                onDelete()
                                dismiss()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(isTask ? "The task itself stays." : "It is removed from every device.")
                        }
                    }
                }
                .padding(.bottom, Space.md)
            }
        }
        .onAppear(perform: seed)
    }

    /// The date picker moves start and end together, keeping their hours.
    private var dateBinding: Binding<Date> {
        Binding(
            get: { start },
            set: { newDay in
                let cal = Calendar.current
                let shift = cal.startOfDay(for: newDay).timeIntervalSince(cal.startOfDay(for: start))
                start = start.addingTimeInterval(shift)
                end = end.addingTimeInterval(shift)
            }
        )
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(label).eyebrow()
            content()
        }
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        switch mode {
        case .create(let s, let e, let t):
            title = t
            timed = true
            start = s
            end = e
            day = Calendar.current.startOfDay(for: s)
            minutes = PlannerEngine.minutes(from: s, to: e)
        case .edit(let block):
            title = block.title
            timed = block.isTimed
            notes = block.notes
            let deviceDay = WallClock.deviceDay(from: block.day)
            day = deviceDay
            minutes = block.durationMinutes
            let s = block.start ?? deviceDay.addingTimeInterval(TimeInterval(PlannerSettings.workday.startMinute * 60))
            start = s
            end = block.end ?? s.addingTimeInterval(TimeInterval(block.durationMinutes * 60))
        }
    }
}

// MARK: - Calendar event

/// A calendar event's details (#687 round 3), with Dexter-only actions (#689).
/// The event itself stays read-only: Decline and Remove are Dexter records,
/// the source calendar does not change, and the organiser is not told.
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
        PlannerSheetScaffold(title: event.title, subtitle: event.source == .work ? "Work calendar" : "Personal calendar") {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    if event.decline != .none {
                        Label(event.decline == .atSource ? "You declined this in your calendar" : "Declined in Dexter",
                              systemImage: "xmark.circle")
                            .font(.edFootnoteStrong)
                            .foregroundStyle(Tokens.danger)
                    }
                    row("Time", when)
                    row("Calendar", event.calendarTitle)
                    if !event.location.isEmpty { row("Location", event.location) }
                    if !event.notes.isEmpty { row("Notes", event.notes) }
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
                Button { ask(.remove) } label: { Text("Remove from Planner") }
                    .buttonStyle(EdButtonStyle(kind: .danger, fullWidth: true))
                    .accessibilityIdentifier("planner.event.remove")
            }
        }
        .padding(.top, 4)
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

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).eyebrow()
            Text(value).font(.edBody).foregroundStyle(Tokens.ink).textSelection(.enabled)
        }
    }
}
