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
                .presentationDetents([.large])
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
                        entries: cluster.entries,
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
        // True vertical centre of the available area below the trip header.
        VStack(spacing: 0) {
            Spacer()
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
            Spacer()
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

    /// `(day, entries)` clusters in ascending date order. Stays expand into
    /// two entries (check-in on dayDate, check-out on endDate) when endDate
    /// is set and differs from dayDate. Within a day: untimed entries render
    /// first (in sortOrder), then timed entries sorted ascending by the
    /// entry's effective time (`startTime` for single/check-in,
    /// `endTime` for check-out).
    private var grouped: [(day: Date, entries: [TimelineEntry])] {
        let cal = Calendar.current
        var buckets: [Date: [TimelineEntry]] = [:]

        for item in items {
            let kind = item.kindEnum
            let inDay = cal.startOfDay(for: item.dayDate)

            if kind == .stay, let endDate = item.endDate {
                let outDay = cal.startOfDay(for: endDate)
                buckets[inDay, default: []].append(.stayCheckIn(item: item))
                if outDay != inDay {
                    buckets[outDay, default: []].append(.stayCheckOut(item: item))
                }
            } else {
                buckets[inDay, default: []].append(.single(item: item))
            }
        }

        return buckets.keys.sorted().map { day in
            let raw = buckets[day] ?? []
            let sorted = raw.sorted { lhs, rhs in
                switch (lhs.effectiveTime, rhs.effectiveTime) {
                case (nil, nil):
                    if lhs.item.sortOrder != rhs.item.sortOrder {
                        return lhs.item.sortOrder < rhs.item.sortOrder
                    }
                    return lhs.item.createdAt < rhs.item.createdAt
                case (nil, _):
                    return true   // untimed entries pin to the top of the day
                case (_, nil):
                    return false
                case let (l?, r?):
                    if l != r { return l < r }
                    return lhs.item.sortOrder < rhs.item.sortOrder
                }
            }
            return (day: day, entries: sorted)
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
    /// Distance from the cluster leading edge to the rail centerline. The
    /// day eyebrow's dot, every item marker, and the rail itself all share
    /// this x-position, so they form a clean vertical column.
    static let railLeading: CGFloat = 16
    /// Distance from cluster leading edge to the item card's leading edge.
    /// Equals `railLeading + markerRadius + gutter` (~11pt gutter past the
    /// marker outer edge).
    static let cardLeading: CGFloat = 32
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

// MARK: - Timeline entries (one row on the timeline)

/// A single "event" the timeline renders. A non-stay item produces one
/// `.single` entry on its `dayDate`. A stay with an `endDate` distinct from
/// `dayDate` produces TWO entries: `.stayCheckIn` on `dayDate` and
/// `.stayCheckOut` on `endDate`. A stay without an `endDate` (legacy) or a
/// same-day stay collapses to a single `.stayCheckIn` entry.
enum TimelineEntry: Identifiable {
    case single(item: LocalItineraryItem)
    case stayCheckIn(item: LocalItineraryItem)
    case stayCheckOut(item: LocalItineraryItem)

    var id: String {
        switch self {
        case .single(let item):       return "single-\(item.clientUUID.uuidString)"
        case .stayCheckIn(let item):  return "in-\(item.clientUUID.uuidString)"
        case .stayCheckOut(let item): return "out-\(item.clientUUID.uuidString)"
        }
    }

    var item: LocalItineraryItem {
        switch self {
        case .single(let item), .stayCheckIn(let item), .stayCheckOut(let item):
            return item
        }
    }

    /// The effective time for sort order and marker fill. `startTime` for
    /// single + check-in events; `endTime` for check-out events.
    var effectiveTime: Date? {
        switch self {
        case .single(let item):       return item.startTime
        case .stayCheckIn(let item):  return item.startTime
        case .stayCheckOut(let item): return item.endTime
        }
    }

    /// The "Anytime / Check-in / Check-out · HH:mm" line shown inside the
    /// card below the kind chip.
    var dateTimeLine: String {
        let timeFormat: (Date) -> String = { $0.formatted(.dateTime.hour().minute()) }
        switch self {
        case .single(let item):
            if let t = item.startTime { return timeFormat(t) }
            return "Anytime"
        case .stayCheckIn(let item):
            if let t = item.startTime { return "Check-in · \(timeFormat(t))" }
            return "Check-in"
        case .stayCheckOut(let item):
            if let t = item.endTime { return "Check-out · \(timeFormat(t))" }
            return "Check-out"
        }
    }
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
/// `markerCenterFromRowTop` constant. The day eyebrow's dot is indented to
/// share the marker x-position, so day dot + every marker form a vertical
/// column.
private struct TripDayCluster: View {
    let trip: LocalTrip
    let day: Date
    let entries: [TimelineEntry]
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
        // Indent so the dot's centerline sits at `railLeading`, lined up
        // with every item marker below it.
        .padding(.leading, TimelineLayout.railLeading - TimelineLayout.dayDotDiameter / 2)
        .frame(height: 36)
    }

    // MARK: Items + rail

    private var itemsStack: some View {
        // The rail lives as a background rect behind the items VStack, with
        // top/bottom padding equal to `markerCenterFromRowTop` so it starts
        // at the first marker center and ends at the last marker center.
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(entries) { entry in
                TripTimelineRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(entry.item) }
                    .contextMenu {
                        Button(role: .destructive) {
                            onDelete(entry.item)
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
        // horizontal center lands on `railLeading`. Single-entry days
        // suppress the rail entirely — there's nothing to connect.
        if entries.count > 1 {
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

/// One row on the timeline: marker column | card. Uniform structure:
/// title (1 line) → kind chip → date/time line. Tiles are the same height
/// across all kinds so the column feels like a real timeline rather than a
/// jagged list.
private struct TripTimelineRow: View {
    let entry: TimelineEntry

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            markerColumn
            card
        }
    }

    /// Fixed-width column whose center sits on `railLeading`. The marker
    /// itself is vertically padded so its centerline aligns with the card
    /// title's first line.
    private var markerColumn: some View {
        Group {
            if entry.effectiveTime != nil {
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
        .frame(width: TimelineLayout.cardLeading, alignment: .center)
        .padding(.top, TimelineLayout.markerCenterFromRowTop - TimelineLayout.markerDiameter / 2)
    }

    private var card: some View {
        let item = entry.item
        let kind = item.kindEnum

        return VStack(alignment: .leading, spacing: Space.xs) {
            Text(item.title)
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: Space.sm) {
                TripKindChip(kind: kind)
                Spacer(minLength: 0)
            }

            Text(entry.dateTimeLine)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
                .truncationMode(.tail)
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
    /// For non-stay kinds: the item's day (with time when `hasTime` is on).
    /// For stay: the check-in date+time.
    @State private var dayDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var hasTime: Bool = false
    /// Stay only: the check-out date+time. Defaulted to `dayDate + 1 day` when
    /// the kind first switches to stay.
    @State private var endDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var hasEndTime: Bool = false
    @State private var notes: String = ""
    @State private var loaded: Bool = false
    @State private var showingDeleteConfirmation: Bool = false
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
                        primaryDateField
                        if kind == .stay {
                            endDateField
                        }
                        notesField
                        if isEditing {
                            deleteButton
                                .padding(.top, Space.sm)
                        }
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
            .confirmationDialog(
                "Delete this item?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deleteItem()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: kind) { _, newKind in
            // Switching to stay: make sure check-out is at least the day after
            // check-in. Switching away from stay: reset the end-time flag so
            // the persisted shape matches what's hidden in the UI.
            let cal = Calendar.current
            if newKind == .stay {
                let inDay = cal.startOfDay(for: dayDate)
                let outDay = cal.startOfDay(for: endDate)
                if outDay <= inDay {
                    endDate = cal.date(byAdding: .day, value: 1, to: inDay) ?? inDay
                }
            } else {
                hasEndTime = false
            }
        }
        .onChange(of: dayDate) { _, newValue in
            // Keep check-out >= check-in for stay items.
            guard kind == .stay else { return }
            let cal = Calendar.current
            let inDay = cal.startOfDay(for: newValue)
            let outDay = cal.startOfDay(for: endDate)
            if outDay < inDay {
                endDate = cal.date(byAdding: .day, value: 1, to: inDay) ?? inDay
            }
        }
        .onChange(of: hasTime) { _, newValue in
            // Toggling time on: if the current Date is at midnight, seed a 9 AM
            // default so the picker doesn't open showing 12:00 AM.
            guard newValue else { return }
            dayDate = seededTime(on: dayDate, defaultHour: 9)
        }
        .onChange(of: hasEndTime) { _, newValue in
            guard newValue else { return }
            // Default check-out time: 11 AM (most hotels). Same midnight
            // guard as the check-in time toggle.
            endDate = seededTime(on: endDate, defaultHour: 11)
        }
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

    /// Primary date picker. For non-stay kinds: label "Date". For stay:
    /// label "Check-in". Picker displays date alone or date + time depending
    /// on `hasTime`, so the time renders inline with the date (no narrow
    /// truncated time-only picker).
    private var primaryDateField: some View {
        let label = kind == .stay ? "Check-in" : "Date"
        return VStack(alignment: .leading, spacing: Space.sm) {
            Text(label).eyebrow()
            VStack(spacing: 0) {
                HStack {
                    DatePicker(
                        "",
                        selection: $dayDate,
                        displayedComponents: hasTime ? [.date, .hourAndMinute] : .date
                    )
                    .labelsHidden()
                    .tint(Tokens.accent(for: .itineraries))
                    Spacer(minLength: 0)
                }
                .padding(Space.md)

                Divider().background(Tokens.divider)

                HStack {
                    Text("Include time").font(.edBody).foregroundStyle(Tokens.inkSoft)
                    Spacer()
                    Toggle("", isOn: $hasTime)
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                }
                .padding(Space.md)
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Stay-only second picker for the check-out date / time. Constrained to
    /// `>= dayDate` so the user can't pick a check-out before the check-in.
    private var endDateField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Check-out").eyebrow()
            VStack(spacing: 0) {
                HStack {
                    DatePicker(
                        "",
                        selection: $endDate,
                        in: Calendar.current.startOfDay(for: dayDate)...,
                        displayedComponents: hasEndTime ? [.date, .hourAndMinute] : .date
                    )
                    .labelsHidden()
                    .tint(Tokens.accent(for: .itineraries))
                    Spacer(minLength: 0)
                }
                .padding(Space.md)

                Divider().background(Tokens.divider)

                HStack {
                    Text("Include time").font(.edBody).foregroundStyle(Tokens.inkSoft)
                    Spacer()
                    Toggle("", isOn: $hasEndTime)
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                }
                .padding(Space.md)
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Returns `existing` with the time-of-day replaced by `defaultHour:00` if
    /// the existing time is midnight; otherwise leaves it as-is. Used when
    /// the "Include time" toggle flips on so the picker doesn't surface 12:00 AM.
    private func seededTime(on existing: Date, defaultHour: Int) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: existing)
        if (comps.hour ?? 0) == 0 && (comps.minute ?? 0) == 0 {
            return cal.date(bySettingHour: defaultHour, minute: 0, second: 0, of: existing) ?? existing
        }
        return existing
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

    /// Destructive "Delete item" button shown at the bottom of the editor
    /// scroll content when editing an existing item. Long-press on the tile
    /// in the timeline is still available (context menu); this gives the user
    /// a discoverable in-editor path.
    private var deleteButton: some View {
        Button(role: .destructive) {
            Haptics.destructive()
            showingDeleteConfirmation = true
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .regular))
                Text("Delete item")
                    .font(.edBodyMedium)
            }
            .foregroundStyle(Color.red)
            .frame(maxWidth: .infinity)
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete item")
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

        let cal = Calendar.current

        switch target {
        case .new(let day):
            dayDate = cal.startOfDay(for: day)
            // Default kind heuristic: a first-day item is most often a Stay.
            if cal.isDate(day, inSameDayAs: trip.startDate) {
                kind = .stay
                endDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day)) ?? dayDate
            } else {
                kind = .activity
                endDate = cal.startOfDay(for: day)
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
                    dayDate = start
                }
                if let end = existing.endDate {
                    endDate = end
                    if let endT = existing.endTime {
                        hasEndTime = true
                        endDate = endT
                    }
                } else if existing.kindEnum == .stay {
                    // Stay with no persisted endDate (legacy item before the
                    // field existed): seed a sane default of +1 day.
                    endDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: existing.dayDate)) ?? existing.dayDate
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

        // For non-stay or when "Include time" is off: persist only the day.
        // For non-stay with time on: persist the full date+time as `startTime`,
        // dayDate stays start-of-day so the grouping bucket is unambiguous.
        let startTimeValue: Date? = hasTime ? dayDate : nil

        // Stay-only end fields. Other kinds clear both.
        let endDateValue: Date? = kind == .stay ? cal.startOfDay(for: endDate) : nil
        let endTimeValue: Date? = (kind == .stay && hasEndTime) ? endDate : nil

        switch target {
        case .new:
            let nextSort = nextSortOrder(for: normalisedDay)
            let item = LocalItineraryItem(
                tripUUID: trip.clientUUID,
                dayDate: normalisedDay,
                kind: kind,
                title: cleanTitle,
                notes: cleanNotes,
                startTime: startTimeValue,
                endDate: endDateValue,
                endTime: endTimeValue,
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
                existing.startTime = startTimeValue
                existing.endDate = endDateValue
                existing.endTime = endTimeValue
                existing.updatedAt = Date()
            }
        }
        try? modelContext.save()
    }

    /// Fetch the existing item by UUID and remove it from the model context.
    /// Triggered by the in-editor "Delete item" button after the confirmation
    /// dialog. The sheet dismisses on completion; the timeline picks up the
    /// removal via the `@Query` observer.
    private func deleteItem() {
        guard case .existing(let uuid) = target else { return }
        let descriptor = FetchDescriptor<LocalItineraryItem>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try? modelContext.save()
        }
        dismiss()
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
                    .layoutPriority(1)
                Text(kind.displayName)
                    .font(.edFootnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
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
