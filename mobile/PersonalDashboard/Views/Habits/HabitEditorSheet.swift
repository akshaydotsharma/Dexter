import SwiftUI

/// Create / edit form for a habit (#661). Nil `habit` means create.
///
/// Shaped after `RecurringTaskEditorSheet`: eyebrow labels over paper fields,
/// Cancel and Save in the toolbar. Archive and Delete appear only when editing,
/// at the foot of the form, because they act on something that exists.
struct HabitEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let habit: LocalHabit?

    @State private var name: String = ""
    /// No longer edited here (#669: the emoji field is gone). An existing
    /// habit's stored emoji is loaded and passed back to `update` unchanged,
    /// so saving an edit never wipes it; a new habit gets none.
    @State private var emoji: String = ""
    @State private var colorKey: String = HabitColor.gold.rawValue
    @State private var schedule: HabitSchedule = .daily
    @State private var weekdayMask: Int = 0b011_1110   // Mon-Fri, a sensible first pick for "some days"
    @State private var targetCount: Int = 1
    @State private var unit: String = ""
    @State private var startDay: Date = Date()

    @State private var loaded = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false

    private var isEditing: Bool { habit != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (schedule == .daily || weekdayMask & 0b111_1111 != 0)
            && targetCount >= 1
            && !saving
    }

    private var tint: Color { HabitColor.resolve(colorKey).color }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        // Only the name (#669). The emoji input that sat to
                        // its left is gone; the field takes the full width.
                        labeled("Name") {
                            TextField(PlainFieldPlaceholder.title("Drink water"), text: $name)
                                .paperFieldOnMac()
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .padding(Space.md)
                                .plainFieldPlaceholder("Drink water", isVisible: name.isEmpty, padding: Space.md)
                                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                .paperBorder(Tokens.border, radius: Radius.md)
                                .submitLabel(.done)
                        }

                        labeled("Colour") { colourRow }

                        labeled("Repeat") { scheduleCard }

                        labeled("Daily target") { targetCard }

                        labeled("Starts") {
                            EdDateTimeField(
                                date: $startDay,
                                showsTime: false,
                                dateLabel: "Start day",
                                tint: tint
                            )
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.edFootnote)
                                .foregroundStyle(Tokens.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let habit {
                            manageRow(habit)
                        }
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle(isEditing ? "Edit habit" : "New habit")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { save() }
                        .disabled(!canSave)
                        .foregroundStyle(canSave ? Tokens.ink : Tokens.muted)
                }
            }
            .confirmationDialog(
                "Delete this habit?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete habit", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its history goes with it. Archive it instead to keep the history.")
            }
        }
        // macOS: a sheet with no explicit size collapses to its toolbar (#474).
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
        .onAppear(perform: loadIfNeeded)
    }

    // MARK: - Pieces

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(label).eyebrow()
            content()
        }
    }

    private var colourRow: some View {
        HStack(spacing: Space.sm) {
            ForEach(HabitColor.allCases) { option in
                let selected = option.rawValue == colorKey
                Button { colorKey = option.rawValue } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle()
                                .strokeBorder(Tokens.ink, lineWidth: selected ? 2 : 0)
                                .padding(-4)
                        )
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Picker("Repeat", selection: $schedule) {
                ForEach(HabitSchedule.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if schedule == .weekdays {
                HStack(spacing: Space.xs) {
                    ForEach(orderedWeekdays, id: \.self) { index in
                        weekdayChip(index)
                    }
                }
                if weekdayMask & 0b111_1111 == 0 {
                    Text("Pick at least one day.")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.danger)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    private func weekdayChip(_ index: Int) -> some View {
        let selected = weekdayMask & (1 << index) != 0
        let symbols = Calendar.current.shortWeekdaySymbols
        return Button {
            weekdayMask ^= (1 << index)
        } label: {
            Text(Calendar.current.veryShortWeekdaySymbols[index])
                .font(.edCaption)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? Tokens.accentFg : Tokens.inkSoft)
                .frame(width: 32, height: 32)
                .background(Circle().fill(selected ? tint : Tokens.paper2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbols[index])
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 0 = Sunday ... 6 = Saturday, rotated so the device's first weekday leads.
    /// The stored mask stays Sunday-based whatever this shows.
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { ($0 + first) % 7 }
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Stepper(value: $targetCount, in: 1...100) {
                HStack(spacing: Space.xs) {
                    Text(targetCount == 1 ? "Once" : "\(targetCount) times")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                        .monospacedDigit()
                    Text("a day")
                        .font(.edBody)
                        .foregroundStyle(Tokens.inkSoft)
                }
            }
            if targetCount > 1 {
                TextField(PlainFieldPlaceholder.title("Unit, e.g. glasses"), text: $unit)
                    .paperFieldOnMac()
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .padding(Space.sm)
                    .plainFieldPlaceholder("Unit, e.g. glasses", isVisible: unit.isEmpty, padding: Space.sm)
                    .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.sm))
                Text("Each tap on Today adds one. The day counts as done at \(targetCount).")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.md)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    private func manageRow(_ habit: LocalHabit) -> some View {
        HStack(spacing: Space.sm) {
            // Destructive leads, confirm trails (#645).
            Button("Delete") { confirmingDelete = true }
                .buttonStyle(EdButtonStyle(kind: .danger, size: .sm))
            Spacer()
            Button(habit.isArchived ? "Restore" : "Archive") { toggleArchive(habit) }
                .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
        }
        .padding(.top, Space.md)
    }

    // MARK: - Load / save

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let habit else {
            startDay = Date()
            return
        }
        name = habit.name
        emoji = habit.emoji
        colorKey = HabitColor.resolve(habit.colorKey).rawValue
        schedule = habit.scheduleEnum
        weekdayMask = habit.scheduleEnum == .weekdays ? habit.weekdayMask : 0b011_1110
        targetCount = max(1, habit.targetCount)
        unit = habit.unit ?? ""
        // Anchor -> device day, so the picker surfaces the stored day (#506).
        startDay = WallClock.deviceDay(from: habit.startDay)
    }

    private func save() {
        guard canSave else { return }
        saving = true
        defer { saving = false }
        let service = HabitService.default()
        let anchor = WallClock.dayAnchor(from: startDay)
        let mask = schedule == .daily ? 0b111_1111 : weekdayMask
        let cleanUnit = targetCount > 1 ? unit : nil
        do {
            if let habit {
                try service.update(
                    habit,
                    name: name,
                    emoji: emoji,
                    colorKey: colorKey,
                    schedule: schedule,
                    weekdayMask: mask,
                    targetCount: targetCount,
                    unit: cleanUnit,
                    startDay: anchor
                )
            } else {
                try service.create(
                    name: name,
                    emoji: emoji,
                    colorKey: colorKey,
                    schedule: schedule,
                    weekdayMask: mask,
                    targetCount: targetCount,
                    unit: cleanUnit,
                    startDay: anchor
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleArchive(_ habit: LocalHabit) {
        do {
            try HabitService.default().setArchived(habit, !habit.isArchived)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        guard let habit else { return }
        do {
            try HabitService.default().delete(habit)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
