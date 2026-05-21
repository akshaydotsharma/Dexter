import SwiftUI
import SwiftData

/// Day-by-day timeline for a single `LocalTrip`. One section per calendar day
/// from `trip.startDate` through `trip.endDate` (inclusive). Items render
/// inside the section that matches their `dayDate`. Any item with a `dayDate`
/// outside the trip range still gets a section so users don't lose data when
/// they shrink a trip's range.
///
/// Items are added via a per-day "+ Add" button that opens
/// `ItineraryItemEditorSheet` pre-filled with that day's date and a default
/// kind. Tapping an existing item re-opens the same sheet for edit.
/// Swipe-to-delete fires `Haptics.destructive()` and removes the item.
struct TripDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let trip: LocalTrip

    @Query private var items: [LocalItineraryItem]

    /// Drives the item editor. `.new(day:)` carries the pre-filled day so a
    /// per-day "+ Add" button doesn't need to re-derive it. `.existing(_)`
    /// carries the item UUID for edit.
    @State private var editingItem: ItineraryItemEditorTarget?

    init(trip: LocalTrip) {
        self.trip = trip
        let tripID = trip.clientUUID
        _items = Query(
            filter: #Predicate<LocalItineraryItem> { $0.tripUUID == tripID },
            sort: [
                SortDescriptor(\.dayDate, order: .forward),
                SortDescriptor(\.sortOrder, order: .forward),
                SortDescriptor(\.createdAt, order: .forward)
            ]
        )
    }

    var body: some View {
        List {
            ForEach(days, id: \.self) { day in
                Section {
                    let dayItems = itemsByDay[day] ?? []
                    if dayItems.isEmpty {
                        emptyDayRow
                    } else {
                        ForEach(dayItems) { item in
                            ItineraryItemRow(item: item) {
                                editingItem = .existing(item.clientUUID)
                            }
                            .swipeToDeleteTrash {
                                Haptics.destructive()
                                delete(item)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.lg, bottom: Space.xs, trailing: Space.lg))
                        }
                    }

                    addRow(day: day)
                } header: {
                    dayHeader(for: day)
                }
            }

            Color.clear
                .frame(height: 96)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tokens.paper)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $editingItem) { target in
            ItineraryItemEditorSheet(trip: trip, target: target)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Day computation

    /// Union of (calendar days from start to end inclusive) and (distinct
    /// dayDates of existing items). Sorted ascending. This way a trip with
    /// items beyond its current end date still shows those items in their
    /// own section instead of silently hiding them.
    private var days: [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: trip.startDate)
        let end = cal.startOfDay(for: trip.endDate)

        var set = Set<Date>()
        var cursor = start
        while cursor <= end {
            set.insert(cursor)
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        for item in items {
            set.insert(cal.startOfDay(for: item.dayDate))
        }
        return set.sorted()
    }

    private var itemsByDay: [Date: [LocalItineraryItem]] {
        let cal = Calendar.current
        return Dictionary(grouping: items) { cal.startOfDay(for: $0.dayDate) }
    }

    // MARK: - Subviews

    private func dayHeader(for day: Date) -> some View {
        let cal = Calendar.current
        let tripStart = cal.startOfDay(for: trip.startDate)
        let tripEnd = cal.startOfDay(for: trip.endDate)
        let withinTrip = day >= tripStart && day <= tripEnd
        let dayNumber = cal.dateComponents([.day], from: tripStart, to: day).day.map { $0 + 1 } ?? 0
        let weekdayDate = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))

        return HStack(spacing: Space.sm) {
            if withinTrip {
                Text("Day \(dayNumber)")
                    .font(.edEyebrow)
                    .foregroundStyle(Tokens.accent(for: .itineraries))
                Text("·")
                    .font(.edEyebrow)
                    .foregroundStyle(Tokens.mutedSoft)
                Text(weekdayDate)
                    .font(.edEyebrow)
                    .foregroundStyle(Tokens.muted)
            } else {
                Text("Outside trip")
                    .font(.edEyebrow)
                    .foregroundStyle(Tokens.muted)
                Text("·")
                    .font(.edEyebrow)
                    .foregroundStyle(Tokens.mutedSoft)
                Text(weekdayDate)
                    .font(.edEyebrow)
                    .foregroundStyle(Tokens.muted)
            }
            Spacer()
        }
        .textCase(nil)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.xs)
        .background(Tokens.paper)
    }

    private var emptyDayRow: some View {
        Text("Nothing planned")
            .font(.edSubheadline)
            .foregroundStyle(Tokens.mutedSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Space.sm)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.lg, bottom: Space.xs, trailing: Space.lg))
    }

    private func addRow(day: Date) -> some View {
        Button {
            editingItem = .new(day: day)
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("Add to this day")
                    .font(.edFootnote)
                Spacer()
            }
            .foregroundStyle(Tokens.accent(for: .itineraries))
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.lg, bottom: Space.lg, trailing: Space.lg))
        .accessibilityLabel("Add item to \(day.formatted(.dateTime.weekday().day().month()))")
    }

    // MARK: - Persistence

    private func delete(_ item: LocalItineraryItem) {
        modelContext.delete(item)
        try? modelContext.save()
    }
}

// MARK: - Editor target

/// Identifiable wrapper used as the `.sheet(item:)` payload for the item
/// editor. `.new(day:)` carries the day so the per-day "+ Add" button can
/// pre-fill the picker; `.existing(_)` carries the UUID.
enum ItineraryItemEditorTarget: Identifiable {
    case new(day: Date)
    case existing(UUID)

    var id: String {
        switch self {
        case .new(let day):       return "new-\(day.timeIntervalSince1970)"
        case .existing(let uuid): return uuid.uuidString
        }
    }
}

// MARK: - Item row

private struct ItineraryItemRow: View {
    let item: LocalItineraryItem
    let onTap: () -> Void

    var body: some View {
        let kind = item.kindEnum
        Button(action: onTap) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: kind.icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Tokens.accent(for: .itineraries))
                    .frame(width: 24, height: 24)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(item.title)
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: Space.sm) {
                        Text(kind.displayName.uppercased())
                            .font(.edEyebrow)
                            .foregroundStyle(Tokens.muted)

                        let trimmed = item.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            Text("·")
                                .font(.edEyebrow)
                                .foregroundStyle(Tokens.mutedSoft)
                            Text(trimmed)
                                .font(.edSubheadline)
                                .foregroundStyle(Tokens.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.displayName): \(item.title). Tap to edit.")
    }
}

// MARK: - Item editor sheet

private struct ItineraryItemEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let trip: LocalTrip
    let target: ItineraryItemEditorTarget

    @State private var title: String = ""
    @State private var kind: ItineraryKind = .activity
    @State private var dayDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var notes: String = ""
    @State private var loaded: Bool = false
    @FocusState private var titleFocused: Bool

    private let titleMaxLength = 96
    private let notesMaxLength = 1000

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        kindField
                        titleField
                        dayField
                        notesField
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle(isEditing ? "Edit item" : "New item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        save()
                        dismiss()
                    }
                    .disabled(trimmedTitle.isEmpty)
                    .foregroundStyle(trimmedTitle.isEmpty ? Tokens.muted : Tokens.ink)
                }
            }
        }
        .onAppear { loadIfNeeded() }
    }

    // MARK: - Fields

    private var kindField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Kind").eyebrow()
            HStack(spacing: Space.sm) {
                ForEach(ItineraryKind.allCases) { option in
                    KindChip(kind: option, isSelected: option == kind) {
                        kind = option
                    }
                }
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Title").eyebrow()
            TextField(placeholder(for: kind), text: $title)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
                .submitLabel(.done)
                .focused($titleFocused)
                .onChange(of: title) { _, newValue in
                    if newValue.count > titleMaxLength {
                        title = String(newValue.prefix(titleMaxLength))
                    }
                }
                .accessibilityLabel("Title")
        }
    }

    private var dayField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Day").eyebrow()
            HStack {
                Text("Date").font(.edBody).foregroundStyle(Tokens.inkSoft)
                Spacer()
                // Trip dates aren't a hard constraint here — picking outside
                // the range keeps the item visible under an "Outside trip"
                // section, so the user can still extend the trip later
                // without losing the item.
                DatePicker("", selection: $dayDate, displayedComponents: .date)
                    .labelsHidden()
                    .tint(Tokens.accent(for: .itineraries))
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Notes").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Address, time, anything to remember…")
                        .font(.edBody)
                        .foregroundStyle(Tokens.mutedSoft)
                        .padding(.horizontal, Space.md + 4)
                        .padding(.vertical, Space.md + 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $notes)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .frame(minHeight: 96, alignment: .topLeading)
                    .onChange(of: notes) { _, newValue in
                        if newValue.count > notesMaxLength {
                            notes = String(newValue.prefix(notesMaxLength))
                        }
                    }
                    .accessibilityLabel("Notes")
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private func placeholder(for kind: ItineraryKind) -> String {
        switch kind {
        case .stay:       return "e.g. Hanoi Hilton"
        case .activity:   return "e.g. Halong Bay tour"
        case .place:      return "e.g. Hội An old town"
        case .restaurant: return "e.g. Bún chả Hương Liên"
        }
    }

    // MARK: - Persistence

    private var isEditing: Bool {
        if case .existing = target { return true }
        return false
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        switch target {
        case .new(let day):
            dayDate = Calendar.current.startOfDay(for: day)
            // Default kind heuristic: if the day is the trip's first day,
            // most users add a Stay first. Otherwise default to Activity.
            if Calendar.current.isDate(day, inSameDayAs: trip.startDate) {
                kind = .stay
            } else {
                kind = .activity
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                titleFocused = true
            }
        case .existing(let uuid):
            let descriptor = FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                title = existing.title
                kind = existing.kindEnum
                dayDate = existing.dayDate
                notes = existing.notes
            }
        }
    }

    private func save() {
        let cleanTitle = trimmedTitle
        guard !cleanTitle.isEmpty else { return }
        let cleanNotes = trimmedNotes
        let normalisedDay = Calendar.current.startOfDay(for: dayDate)

        switch target {
        case .new:
            let nextSort = nextSortOrder(for: normalisedDay)
            let item = LocalItineraryItem(
                tripUUID: trip.clientUUID,
                dayDate: normalisedDay,
                kind: kind,
                title: cleanTitle,
                notes: cleanNotes,
                sortOrder: nextSort
            )
            modelContext.insert(item)
        case .existing(let uuid):
            let descriptor = FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.title = cleanTitle
                existing.kindEnum = kind
                if Calendar.current.startOfDay(for: existing.dayDate) != normalisedDay {
                    // Day moved: re-sortOrder so the item lands at the end of
                    // the new day instead of slotting into the old position.
                    existing.sortOrder = nextSortOrder(for: normalisedDay)
                }
                existing.dayDate = normalisedDay
                existing.notes = cleanNotes
                existing.updatedAt = Date()
            }
        }
        try? modelContext.save()
    }

    /// Append-on-create ordering: max sortOrder for the day + 1. Falls back to
    /// 0 when the day has no existing items.
    private func nextSortOrder(for day: Date) -> Int {
        let tripID = trip.clientUUID
        let descriptor = FetchDescriptor<LocalItineraryItem>(
            predicate: #Predicate { $0.tripUUID == tripID && $0.dayDate == day }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        return (existing.map(\.sortOrder).max() ?? -1) + 1
    }
}

// MARK: - Kind chip

private struct KindChip: View {
    let kind: ItineraryKind
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: kind.icon)
                    .font(.system(size: 12, weight: .regular))
                Text(kind.displayName)
                    .font(.edFootnote)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? Tokens.accentFg : Tokens.inkSoft)
            .background(
                isSelected ? Tokens.accent(for: .itineraries) : Tokens.surface,
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(isSelected ? Color.clear : Tokens.border, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
