import SwiftUI
import SwiftData

/// Top-level surface where the user plans trips (issue #104).
///
/// The root view shows all `LocalTrip`s sorted by start date descending.
/// Tapping a trip swaps the header in place to a detail header and renders
/// `TripDetailView` below it — same inline-swap pattern `ListsView` uses, no
/// `NavigationStack`. The leading-edge back gesture pops the detail back to
/// the root via `router.leadingEdgeBackHandler`.
///
/// Both create and edit go through `TripEditorSheet` keyed by an
/// `Identifiable` `TripEditorTarget`, mirroring `PersonalVocabularyView`.
/// Deleting a trip cascades manually: every `LocalItineraryItem` whose
/// `tripUUID` matches is deleted before the trip itself.
struct ItinerariesView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var router: AppRouter

    @Query(sort: \LocalTrip.startDate, order: .reverse) private var trips: [LocalTrip]

    /// Drives the trip editor sheet. `.new` for create, `.existing(_)` for edit.
    @State private var editingTrip: TripEditorTarget?

    /// `nil` means root list is showing. Setting a UUID swaps to detail.
    @State private var selectedTripUUID: UUID?

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                if let id = selectedTripUUID, let trip = trips.first(where: { $0.clientUUID == id }) {
                    TripDetailHeader(
                        trip: trip,
                        onBack: {
                            withAnimation(.easeOut(duration: 0.2)) { selectedTripUUID = nil }
                        },
                        onEdit: { editingTrip = .existing(id) }
                    )
                    TripDetailView(trip: trip)
                } else {
                    TopBar(
                        title: "Itineraries",
                        onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
                    )
                    rootContent
                }
            }

            if selectedTripUUID == nil {
                Button {
                    editingTrip = .new
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
                .padding(.trailing, 22)
                .padding(.bottom, BottomTabBarMetrics.height + Space.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .accessibilityLabel("New trip")
            }
        }
        .activeSection(.itineraries)
        .onAppear {
            consumeFocus()
            syncBackHandler()
        }
        .onChange(of: router.focus) { _, _ in consumeFocus() }
        .onDisappear {
            if selectedTripUUID != nil {
                router.leadingEdgeBackHandler = nil
            }
        }
        .onChange(of: selectedTripUUID) { _, _ in syncBackHandler() }
        .sheet(item: $editingTrip) { target in
            TripEditorSheet(target: target)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Root content

    @ViewBuilder
    private var rootContent: some View {
        if trips.isEmpty {
            emptyState
        } else {
            tripList
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "airplane")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("Plan your next trip")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
            Text("Add a destination and date range, then lay out the day-by-day timeline of stays, activities, places, and restaurants.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.lg)
    }

    /// Trips ordered by travel date (issue #210): upcoming/current trips first,
    /// ascending so the soonest sits at the top, then past trips below,
    /// most-recently-ended first. A trip counts as current until its end date
    /// passes, so a trip spanning today stays in the upcoming group.
    private var orderedTrips: [LocalTrip] {
        let today = Calendar.current.startOfDay(for: .now)
        let upcoming = trips
            .filter { $0.endDate >= today }
            .sorted { ($0.startDate, $0.endDate) < ($1.startDate, $1.endDate) }
        let past = trips
            .filter { $0.endDate < today }
            .sorted { ($0.endDate, $0.startDate) > ($1.endDate, $1.startDate) }
        return upcoming + past
    }

    private var tripList: some View {
        List {
            ForEach(orderedTrips) { trip in
                TripRow(trip: trip, itemCount: itemCount(for: trip)) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        selectedTripUUID = trip.clientUUID
                    }
                }
                .swipeToDeleteTrash {
                    delete(trip)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.lg, bottom: Space.xs, trailing: Space.lg))
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
    }

    // MARK: - Activity deep-link consumption

    /// The Activity timeline sets `router.focus` to a `.itineraries` focus whose
    /// `id` is the trip UUID, then pushes this section. Open that trip's detail
    /// and clear the focus so it doesn't re-fire. If the trip can't be resolved
    /// (deleted since), we just clear focus and leave the root list showing.
    private func consumeFocus() {
        guard let focus = router.focus, focus.section == .itineraries else { return }
        if trips.contains(where: { $0.clientUUID == focus.id }) {
            withAnimation(.easeOut(duration: 0.2)) { selectedTripUUID = focus.id }
        }
        router.focus = nil
    }

    // MARK: - Back-swipe wiring (mirrors ListsView.syncBackHandler)

    private func syncBackHandler() {
        let binding = $selectedTripUUID
        if selectedTripUUID != nil {
            router.leadingEdgeBackHandler = {
                withAnimation(.easeOut(duration: 0.2)) {
                    binding.wrappedValue = nil
                }
            }
        } else {
            router.leadingEdgeBackHandler = nil
        }
    }

    // MARK: - Persistence

    /// Cascade delete: items first (so no orphans linger in the store), then
    /// the trip. Same pattern Lists uses for embedded items, just spelled out
    /// across two model types.
    private func delete(_ trip: LocalTrip) {
        let tripID = trip.clientUUID
        let descriptor = FetchDescriptor<LocalItineraryItem>(
            predicate: #Predicate { $0.tripUUID == tripID }
        )
        if let items = try? modelContext.fetch(descriptor) {
            for item in items { modelContext.delete(item) }
        }
        modelContext.delete(trip)
        try? modelContext.save()
    }

    /// Cheap count for the row badge. Item counts will be small enough that a
    /// per-row fetch is fine for a skeleton; revisit if a trip ever holds
    /// hundreds of items.
    private func itemCount(for trip: LocalTrip) -> Int {
        let tripID = trip.clientUUID
        let descriptor = FetchDescriptor<LocalItineraryItem>(
            predicate: #Predicate { $0.tripUUID == tripID }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

// MARK: - Editor target

/// Identifiable wrapper used as the `.sheet(item:)` payload for the trip
/// editor. Carries the UUID (not the live model) so the sheet stays stateless
/// across re-renders.
enum TripEditorTarget: Identifiable {
    case new
    case existing(UUID)

    var id: String {
        switch self {
        case .new:                return "new"
        case .existing(let uuid): return uuid.uuidString
        }
    }
}

// MARK: - Row

private struct TripRow: View {
    let trip: LocalTrip
    let itemCount: Int
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(trip.name)
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
            }

            HStack(spacing: Space.sm) {
                Text(Self.formatRange(start: trip.startDate, end: trip.endDate))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 10, weight: .regular))
                    Text("\(itemCount)")
                }
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 2)
                .background(Tokens.paper2, in: Capsule())
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.md)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .paperBorder(Tokens.border, radius: 26)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel("\(trip.name), \(Self.formatRange(start: trip.startDate, end: trip.endDate)). Tap to open.")
    }

    /// "1 May – 10 May 2026" / "28 Dec 2026 – 3 Jan 2027" / single-day
    /// "5 Mar 2026". Year is suppressed on the start side when both dates
    /// share the same year.
    static func formatRange(start: Date, end: Date) -> String {
        let cal = Calendar.current
        let sameDay = cal.isDate(start, inSameDayAs: end)
        let sameYear = cal.component(.year, from: start) == cal.component(.year, from: end)

        let startNoYear = start.formatted(.dateTime.day().month(.abbreviated))
        let endFull = end.formatted(.dateTime.day().month(.abbreviated).year())
        let startFull = start.formatted(.dateTime.day().month(.abbreviated).year())

        if sameDay { return startFull }
        if sameYear { return "\(startNoYear) – \(endFull)" }
        return "\(startFull) – \(endFull)"
    }
}

// MARK: - Detail header

/// Header shown above `TripDetailView` when a trip is selected. Mirrors
/// `ListDetailHeader` in `ListsView.swift`: back chevron + label, centred
/// title, trailing affordance (Edit instead of Delete because trip edits
/// span name + dates + notes and warrant the full sheet).
private struct TripDetailHeader: View {
    let trip: LocalTrip
    let onBack: () -> Void
    let onEdit: () -> Void

    /// Drives the read-only calendar popover (#230). Held locally so the
    /// change stays contained to the header and the `.popover` anchors to the
    /// calendar button.
    @State private var showingCalendar = false

    var body: some View {
        HStack(spacing: Space.md) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Trips")
                }
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text(trip.name)
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Text(TripRow.formatRange(start: trip.startDate, end: trip.endDate))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                showingCalendar = true
            } label: {
                Image(systemName: "calendar")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityLabel("View calendar")
            .popover(isPresented: $showingCalendar) {
                TripCalendarPopover(trip: trip)
            }
            Button(action: onEdit) {
                Image(systemName: "square.and.pencil")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityLabel("Edit trip")
        }
        .padding(.horizontal, Space.md)
        .frame(height: 56)
        .background(Tokens.paper.overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.divider).frame(height: 0.5)
        })
    }
}

// MARK: - Trip editor sheet

private struct TripEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let target: TripEditorTarget

    @State private var name: String = ""
    @State private var startDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var endDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var notes: String = ""
    @State private var loaded: Bool = false
    @FocusState private var nameFocused: Bool

    /// Trip participants for expense splitting (#258). Held as an ordered list
    /// of `LocalPerson.clientUUID`s; encoded to `participantsData` on save.
    @State private var participantUUIDs: [UUID] = []
    /// Selection binding for the reused `PersonPickerSheet` (find-or-create).
    @State private var pickedParticipant: ExpenseTag?
    @State private var showingParticipantPicker: Bool = false

    /// All people, so the stored participant UUIDs resolve to names + colours.
    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var allPeople: [LocalPerson]

    private let nameMaxLength = 64
    private let notesMaxLength = 1000

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        nameField
                        dateFields
                        participantsField
                        notesField
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle(isEditing ? "Edit trip" : "New trip")
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
                    .disabled(trimmedName.isEmpty)
                    .foregroundStyle(trimmedName.isEmpty ? Tokens.muted : Tokens.ink)
                }
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: startDate) { _, newStart in
            // Keep end >= start. Adjust silently rather than reject.
            if endDate < newStart { endDate = newStart }
        }
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Destination").eyebrow()
            TextField("e.g. Vietnam", text: $name)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
                .submitLabel(.done)
                .focused($nameFocused)
                .onChange(of: name) { _, newValue in
                    if newValue.count > nameMaxLength {
                        name = String(newValue.prefix(nameMaxLength))
                    }
                }
                .accessibilityLabel("Destination")
        }
    }

    private var dateFields: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Dates").eyebrow()
            VStack(spacing: Space.sm) {
                HStack {
                    Text("Start").font(.edBody).foregroundStyle(Tokens.inkSoft)
                    Spacer()
                    DatePicker("", selection: $startDate, displayedComponents: .date)
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                }
                Rectangle().fill(Tokens.divider).frame(height: 0.5)
                HStack {
                    Text("End").font(.edBody).foregroundStyle(Tokens.inkSoft)
                    Spacer()
                    DatePicker("", selection: $endDate, in: startDate..., displayedComponents: .date)
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                }
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Participants for expense splitting (#258). Colcoured person chips with a
    /// remove affordance, plus an "Add" chip that opens the reused
    /// `PersonPickerSheet` (find-or-create by name). Horizontally scrollable so
    /// a large group never blows out the sheet width.
    private var participantsField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Participants").eyebrow()
                Spacer()
                // Headcount includes the user — "3 going" means You + 2.
                Text("\(participantPeople.count + 1) going")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    youChip
                    ForEach(participantPeople, id: \.clientUUID) { person in
                        participantChip(person)
                    }
                    addParticipantChip
                }
                .padding(.vertical, 2)
            }
        }
        .sheet(isPresented: $showingParticipantPicker) {
            PersonPickerSheet(selection: $pickedParticipant)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: pickedParticipant) { _, newValue in
            if let tag = newValue, !participantUUIDs.contains(tag.uuid) {
                participantUUIDs.append(tag.uuid)
            }
            // Reset so picking the same person twice in a row still fires.
            pickedParticipant = nil
        }
    }

    /// Resolved participant records, preserving the stored order.
    private var participantPeople: [LocalPerson] {
        participantUUIDs.compactMap { id in allPeople.first { $0.clientUUID == id } }
    }

    /// The user's own chip — always first, not removable. Makes the headcount
    /// readable at a glance ("You, Rohan, Sam" = 3 going).
    private var youChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Tokens.accentFinance)
                .frame(width: 8, height: 8)
            Text("You")
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 6)
        .background(Tokens.surface2, in: Capsule())
        .accessibilityLabel("You are going")
    }

    private func participantChip(_ person: LocalPerson) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(personHex: person.colorHex))
                .frame(width: 8, height: 8)
            Text(person.name)
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
            Button {
                participantUUIDs.removeAll { $0 == person.clientUUID }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tokens.mutedSoft)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(person.name)")
        }
        .padding(.leading, Space.sm)
        .padding(.trailing, Space.xs + 2)
        .padding(.vertical, 6)
        .background(Tokens.surface2, in: Capsule())
    }

    private var addParticipantChip: some View {
        Button {
            showingParticipantPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add")
                    .font(.edFootnote)
            }
            .foregroundStyle(Tokens.accent(for: .itineraries))
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .background(Tokens.accent(for: .itineraries).opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add participant")
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
                    Text("Anything to remember about this trip…")
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

    // MARK: - Persistence

    private var isEditing: Bool {
        if case .existing = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        if case let .existing(uuid) = target {
            let descriptor = FetchDescriptor<LocalTrip>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                name = existing.name
                startDate = existing.startDate
                endDate = existing.endDate
                notes = existing.notes
                participantUUIDs = existing.participantPersonUUIDs
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                nameFocused = true
            }
        }
    }

    private func save() {
        let cleanName = trimmedName
        guard !cleanName.isEmpty else { return }
        let cleanNotes = trimmedNotes
        let cal = Calendar.current
        let normalisedStart = cal.startOfDay(for: startDate)
        let normalisedEnd = cal.startOfDay(for: endDate)

        switch target {
        case .new:
            let trip = LocalTrip(
                name: cleanName,
                startDate: normalisedStart,
                endDate: normalisedEnd,
                notes: cleanNotes
            )
            trip.participantPersonUUIDs = participantUUIDs
            modelContext.insert(trip)
        case .existing(let uuid):
            let descriptor = FetchDescriptor<LocalTrip>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.name = cleanName
                existing.startDate = normalisedStart
                existing.endDate = normalisedEnd
                existing.notes = cleanNotes
                existing.participantPersonUUIDs = participantUUIDs
                existing.updatedAt = Date()
            } else {
                let trip = LocalTrip(
                    name: cleanName,
                    startDate: normalisedStart,
                    endDate: normalisedEnd,
                    notes: cleanNotes
                )
                trip.participantPersonUUIDs = participantUUIDs
                modelContext.insert(trip)
            }
        }
        try? modelContext.save()
    }
}
