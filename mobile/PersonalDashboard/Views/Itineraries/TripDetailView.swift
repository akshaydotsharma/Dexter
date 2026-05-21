import SwiftUI
import SwiftData

/// Vertical timeline for a single `LocalTrip` (issue #108).
///
/// Items render inside per-day clusters in ascending date order. Within a
/// day, untimed items render first (preserving their `sortOrder`), then
/// timed items sorted ascending by `startTime`. Tapping an item opens
/// `ItineraryItemEditorSheet` for edit. A single global "+" FAB at the
/// bottom-trailing creates a new item, defaulting to today (if today is
/// inside the trip range) or `trip.startDate` otherwise.
///
/// Visual spec lives in issue #108. Layout constants are pinned in
/// `TimelineLayout` below — do not improvise away from these numbers.
struct TripDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let trip: LocalTrip

    @Query private var items: [LocalItineraryItem]

    /// Drives the item editor. `.new(day:)` carries the pre-filled day;
    /// `.existing(_)` carries the item UUID for edit.
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
        ZStack {
            Tokens.paper.ignoresSafeArea()

            if grouped.isEmpty {
                emptyState
            } else {
                timelineScroll
            }

            // FAB sits above the bottom tab bar AND the home indicator. The
            // 96pt bumper at the end of the scroll content guarantees the
            // last card is not hidden by this overlay.
            fabOverlay
        }
        .sheet(item: $editingItem) { target in
            ItineraryItemEditorSheet(trip: trip, target: target)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Timeline

    private var timelineScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(grouped.enumerated()), id: \.element.day) { idx, cluster in
                    TripDayCluster(
                        trip: trip,
                        day: cluster.day,
                        items: cluster.items,
                        topPadding: idx == 0 ? Space.xl : Space.xl,
                        onTap: { item in
                            editingItem = .existing(item.clientUUID)
                        },
                        onDelete: { item in
                            Haptics.destructive()
                            delete(item)
                        }
                    )
                }
                Color.clear.frame(height: TimelineLayout.bottomBumper)
            }
            .padding(.horizontal, Space.lg)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // Vertically positioned ~45% from top of the area below the trip
        // header. We approximate that with a flexible top spacer that's
        // slightly smaller than the bottom one so the block sits above
        // dead-centre.
        VStack(spacing: 0) {
            Spacer().frame(minHeight: 0).layoutPriority(0.9)
            VStack(spacing: 0) {
                Image(systemName: "airplane.departure")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Tokens.mutedSoft)
                Spacer().frame(height: Space.md)
                Text("Nothing planned yet")
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.center)
                Spacer().frame(height: Space.xs)
                Text("Tap + to add your first stop")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 280)
            Spacer().frame(minHeight: 0).layoutPriority(1.1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.lg)
    }

    // MARK: - FAB

    private var fabOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    Haptics.light()
                    editingItem = .new(day: defaultDayForNewItem)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Tokens.accentFg)
                        .frame(width: 48, height: 48)
                        .background(Tokens.accent(for: .itineraries), in: Circle())
                        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add itinerary item")
            }
        }
        .padding(.trailing, Space.lg)
        .padding(.bottom, BottomTabBarMetrics.height + Space.sm)
        .allowsHitTesting(true)
    }

    // MARK: - Grouping

    /// `(day, items)` clusters in ascending date order. Skips days with no
    /// items (no eyebrow-only empty days). Within a day, untimed items
    /// render first (preserving `sortOrder`); then timed items sorted
    /// ascending by `startTime`, with `sortOrder` as the secondary tiebreak.
    private var grouped: [(day: Date, items: [LocalItineraryItem])] {
        let cal = Calendar.current
        let buckets = Dictionary(grouping: items) { cal.startOfDay(for: $0.dayDate) }
        return buckets.keys.sorted().map { day in
            let raw = buckets[day] ?? []
            let sorted = raw.sorted { lhs, rhs in
                switch (lhs.startTime, rhs.startTime) {
                case (nil, nil):
                    // Both untimed: existing sortOrder, then createdAt.
                    if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                    return lhs.createdAt < rhs.createdAt
                case (nil, _):
                    // Untimed first.
                    return true
                case (_, nil):
                    return false
                case let (l?, r?):
                    if l != r { return l < r }
                    return lhs.sortOrder < rhs.sortOrder
                }
            }
            return (day: day, items: sorted)
        }
    }

    /// Default day to seed the FAB-launched editor. Today if it falls
    /// within the trip's range; else the trip's start date.
    private var defaultDayForNewItem: Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.startOfDay(for: trip.startDate)
        let end = cal.startOfDay(for: trip.endDate)
        if today >= start && today <= end { return today }
        return start
    }

    // MARK: - Persistence

    private func delete(_ item: LocalItineraryItem) {
        modelContext.delete(item)
        try? modelContext.save()
    }
}

// MARK: - Layout constants

/// Locked numbers for the trip-detail timeline. Spec lives on issue #108;
/// do not change these values without re-locking the spec there.
enum TimelineLayout {
    /// Distance from the cluster leading edge to the rail centerline.
    static let railLeading: CGFloat = 34
    /// Width reserved at the leading edge for the time label column.
    static let timeColumnWidth: CGFloat = 56
    /// Distance from cluster leading edge to the item card's leading edge.
    static let cardLeading: CGFloat = 44
    /// Diameter of each item's marker dot.
    static let markerDiameter: CGFloat = 10
    /// Diameter of the day eyebrow's leading dot.
    static let dayDotDiameter: CGFloat = 6
    /// Thickness of the vertical rail line.
    static let railWidth: CGFloat = 1
    /// Bottom safe-area bumper so the FAB never covers the last card.
    static let bottomBumper: CGFloat = 96
    /// Vertical offset (from row top) at which the marker's centerline
    /// aligns with the first line of the item card's title. Driven by the
    /// 12pt card vertical padding (`Space.md`) plus the title's first-line
    /// half-height for `.edBodyMedium` (≈10pt).
    static let markerCenterFromRowTop: CGFloat = 22
}

// MARK: - Editor target

/// Identifiable wrapper used as the `.sheet(item:)` payload for the item
/// editor. `.new(day:)` carries the pre-filled day from the FAB; `.existing(_)`
/// carries the UUID for edit.
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

// MARK: - Day cluster

/// One day's eyebrow + rail + items. The rail is drawn as a background
/// rectangle behind the items VStack, anchored top/bottom to the first
/// and last marker centers via vertical padding equal to the
/// `markerCenterFromRowTop` constant.
private struct TripDayCluster: View {
    let trip: LocalTrip
    let day: Date
    let items: [LocalItineraryItem]
    let topPadding: CGFloat
    let onTap: (LocalItineraryItem) -> Void
    let onDelete: (LocalItineraryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dayEyebrow
                .padding(.top, topPadding)
                .padding(.bottom, Space.md)

            itemsStack
        }
    }

    // MARK: Eyebrow

    private var dayEyebrow: some View {
        let cal = Calendar.current
        let tripStart = cal.startOfDay(for: trip.startDate)
        let tripEnd = cal.startOfDay(for: trip.endDate)
        let withinTrip = day >= tripStart && day <= tripEnd
        let dayNumber = cal.dateComponents([.day], from: tripStart, to: day).day.map { $0 + 1 } ?? 0
        let weekdayDate = day
            .formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            .uppercased()

        return HStack(spacing: Space.sm) {
            Circle()
                .fill(Tokens.accent(for: .itineraries))
                .frame(width: TimelineLayout.dayDotDiameter, height: TimelineLayout.dayDotDiameter)
            HStack(spacing: 0) {
                if withinTrip {
                    Text("DAY \(dayNumber)")
                        .font(.edEyebrow)
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .foregroundStyle(Tokens.accent(for: .itineraries))
                } else {
                    Text("OUTSIDE TRIP")
                        .font(.edEyebrow)
                        .textCase(.uppercase)
                        .tracking(1.4)
                        .foregroundStyle(Tokens.muted)
                }
                Text(" · ")
                    .font(.edEyebrow)
                    .foregroundStyle(Tokens.mutedSoft)
                Text(weekdayDate)
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(Tokens.muted)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 36)
    }

    // MARK: Items + rail

    private var itemsStack: some View {
        // The rail lives as a background rect behind the items VStack, with
        // top/bottom padding equal to `markerCenterFromRowTop` so it starts
        // at the first marker center and ends at the last marker center.
        // ZStack(.topLeading) places it at x = railLeading - railWidth/2.
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(items) { item in
                TripTimelineRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(item) }
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .background(railOverlay, alignment: .topLeading)
    }

    @ViewBuilder
    private var railOverlay: some View {
        // Single rail. Top/bottom padding clip the rect to marker
        // centerlines (each marker sits `markerCenterFromRowTop` below its
        // row's top edge). `.offset(x:)` slides the 1pt-wide rect so its
        // horizontal center lands on `railLeading`. Single-item days
        // suppress the rail entirely — there's nothing to connect.
        if items.count > 1 {
            Rectangle()
                .fill(Tokens.border)
                .frame(width: TimelineLayout.railWidth)
                .padding(.top, TimelineLayout.markerCenterFromRowTop)
                .padding(.bottom, TimelineLayout.markerCenterFromRowTop)
                .offset(x: TimelineLayout.railLeading - TimelineLayout.railWidth / 2)
                .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Timeline row

/// One item row: time | marker | card. Marker centerline aligns with the
/// card title's first line; time label baseline aligns horizontally with
/// the marker.
private struct TripTimelineRow: View {
    let item: LocalItineraryItem

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            timeColumn
            markerColumn
            Spacer().frame(width: 4)
            card
        }
    }

    private var timeColumn: some View {
        // Width 28pt: time text right-aligned to its trailing edge, which
        // sits 6pt before the rail centerline at 34pt. The remaining 28pt
        // up to the marker column is "negative space" — see spec.
        Group {
            if let start = item.startTime {
                Text(start.formatted(.dateTime.hour().minute()))
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Color.clear
            }
        }
        .frame(width: 28, alignment: .trailing)
        .padding(.top, TimelineLayout.markerCenterFromRowTop - 8)
    }

    private var markerColumn: some View {
        // 12pt-wide column; marker centered horizontally puts the dot at
        // local x=6, and the column is offset to start at 28pt, so marker
        // centerline lands at 28+6=34pt from cluster leading. ✓
        ZStack {
            if item.startTime != nil {
                Circle()
                    .fill(Tokens.accent(for: .itineraries))
                    .frame(width: TimelineLayout.markerDiameter, height: TimelineLayout.markerDiameter)
            } else {
                Circle()
                    .fill(Tokens.paper)
                    .frame(width: TimelineLayout.markerDiameter, height: TimelineLayout.markerDiameter)
                    .overlay(
                        Circle()
                            .strokeBorder(Tokens.accent(for: .itineraries), lineWidth: 1.5)
                    )
            }
        }
        .frame(width: 12, alignment: .center)
        .padding(.top, TimelineLayout.markerCenterFromRowTop - TimelineLayout.markerDiameter / 2)
    }

    private var card: some View {
        let kind = item.kindEnum
        let trimmedNotes = item.notes.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: Space.xs) {
            Text(item.title)
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)

            HStack(spacing: Space.sm) {
                TripKindChip(kind: kind)
                Spacer(minLength: 0)
            }

            if !trimmedNotes.isEmpty {
                Text(trimmedNotes)
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }
}

// MARK: - Kind chip (timeline variant)

/// Capsule chip for an item's kind. Distinct from the picker chip in the
/// editor sheet (which is selectable / accent-tinted). This one is
/// display-only: surface2 background, accent-tinted icon, soft ink label.
private struct TripKindChip: View {
    let kind: ItineraryKind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Tokens.accent(for: .itineraries))
            Text(kind.displayName.uppercased())
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(Tokens.inkSoft)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Tokens.surface2, in: Capsule(style: .continuous))
    }
}

// MARK: - Item editor sheet

/// Same sheet as before, extended with an optional time picker. Kind /
/// title / day / notes flows are unchanged; the new "Time" section sits
/// between "Day" and "Notes" and gates the time picker behind a toggle.
///
/// Persisted shape: when the toggle is OFF, `LocalItineraryItem.startTime`
/// is `nil`. When ON, `startTime` is `dayDate` combined with the hour and
/// minute from `timeOfDay`. Storing a full `Date` (not a clock-time) means
/// the timeline can sort timed items lexicographically and the day
/// grouping stays driven by `dayDate` alone.
struct ItineraryItemEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let trip: LocalTrip
    let target: ItineraryItemEditorTarget

    @State private var title: String = ""
    @State private var kind: ItineraryKind = .activity
    @State private var dayDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var hasTime: Bool = false
    /// Holds the hours/minutes for the time picker while the sheet is
    /// open. The persisted `startTime` is rebuilt on save by combining
    /// `dayDate` + the time-of-day extracted from this value.
    @State private var timeOfDay: Date = {
        let cal = Calendar.current
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }()
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
                        timeField
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
                    KindPickerChip(kind: option, isSelected: option == kind) {
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
                DatePicker("", selection: $dayDate, displayedComponents: .date)
                    .labelsHidden()
                    .tint(Tokens.accent(for: .itineraries))
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var timeField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Time").eyebrow()
            VStack(spacing: 0) {
                HStack {
                    Text("Add time").font(.edBody).foregroundStyle(Tokens.inkSoft)
                    Spacer()
                    Toggle("", isOn: $hasTime)
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                }
                .padding(Space.md)

                if hasTime {
                    Divider().background(Tokens.divider)
                    HStack {
                        Text("Start").font(.edBody).foregroundStyle(Tokens.inkSoft)
                        Spacer()
                        DatePicker("", selection: $timeOfDay, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .tint(Tokens.accent(for: .itineraries))
                    }
                    .padding(Space.md)
                }
            }
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
            // Default kind heuristic: a first-day item is most often a Stay.
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
                if let start = existing.startTime {
                    hasTime = true
                    timeOfDay = start
                }
            }
        }
    }

    private func save() {
        let cleanTitle = trimmedTitle
        guard !cleanTitle.isEmpty else { return }
        let cleanNotes = trimmedNotes
        let cal = Calendar.current
        let normalisedDay = cal.startOfDay(for: dayDate)

        // Combine the day (date-only) with the time-of-day picker if the
        // toggle is on. Falling back to dayDate keeps the call total in
        // case the time-of-day extraction fails (it shouldn't).
        let combinedStart: Date? = {
            guard hasTime else { return nil }
            let comps = cal.dateComponents([.hour, .minute], from: timeOfDay)
            return cal.date(
                bySettingHour: comps.hour ?? 0,
                minute: comps.minute ?? 0,
                second: 0,
                of: normalisedDay
            )
        }()

        switch target {
        case .new:
            let nextSort = nextSortOrder(for: normalisedDay)
            let item = LocalItineraryItem(
                tripUUID: trip.clientUUID,
                dayDate: normalisedDay,
                kind: kind,
                title: cleanTitle,
                notes: cleanNotes,
                startTime: combinedStart,
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
                if cal.startOfDay(for: existing.dayDate) != normalisedDay {
                    // Day moved: re-sortOrder so the item lands at the end of
                    // the new day instead of slotting into the old position.
                    existing.sortOrder = nextSortOrder(for: normalisedDay)
                }
                existing.dayDate = normalisedDay
                existing.notes = cleanNotes
                existing.startTime = combinedStart
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

// MARK: - Kind picker chip (editor sheet)

/// Selectable chip used inside the editor sheet's Kind row. Distinct from
/// `TripKindChip` (display-only chip on the timeline).
private struct KindPickerChip: View {
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
