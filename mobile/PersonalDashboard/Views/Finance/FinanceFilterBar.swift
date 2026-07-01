import SwiftUI
import SwiftData

/// Preset windows offered in the date-range chip row. "Custom" pops a
/// date-range picker; everything else maps to a calendar-derived range.
enum FinanceDateRangePreset: String, CaseIterable, Identifiable, Hashable {
    case thisMonth
    case lastMonth
    case last30
    case last90
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .last30:    return "30d"
        case .last90:    return "90d"
        case .custom:    return "Custom"
        }
    }
}

/// Aggregated filter state owned by `FinanceView`. Bound into the filter
/// bar and read by `ExpenseService.expenses(filter:)`.
struct FinanceFilterState: Equatable {
    var datePreset: FinanceDateRangePreset = .thisMonth
    var customStart: Date = Date()
    var customEnd: Date = Date()
    var categories: Set<ExpenseCategory> = []
    var sources: Set<ExpenseSource> = []
    /// Person / Event tag filters (#183). Empty = no constraint.
    var people: Set<UUID> = []
    var events: Set<UUID> = []

    /// Materialise the filter into a concrete `ExpenseFilter` honoured by
    /// the service layer. `searchText` is appended separately by the view
    /// because it lives on a `.searchable` binding.
    func resolvedFilter(searchText: String?) -> ExpenseFilter {
        var filter = ExpenseFilter()
        filter.dateRange = resolvedDateRange()
        if !categories.isEmpty { filter.categories = categories }
        if !sources.isEmpty { filter.sources = sources }
        if !people.isEmpty { filter.people = people }
        if !events.isEmpty { filter.events = events }
        filter.searchText = searchText
        return filter
    }

    private func resolvedDateRange() -> ClosedRange<Date>? {
        let cal = Calendar.current
        let now = Date()
        switch datePreset {
        case .thisMonth:
            let bounds = ExpenseDateRanges.monthBounds(for:now)
            return bounds.0...bounds.1
        case .lastMonth:
            let prev = cal.date(byAdding: .month, value: -1, to: now) ?? now
            let bounds = ExpenseDateRanges.monthBounds(for:prev)
            return bounds.0...bounds.1
        case .last30:
            guard let start = cal.date(byAdding: .day, value: -30, to: now) else { return nil }
            return cal.startOfDay(for: start)...now
        case .last90:
            guard let start = cal.date(byAdding: .day, value: -90, to: now) else { return nil }
            return cal.startOfDay(for: start)...now
        case .custom:
            let lo = cal.startOfDay(for: min(customStart, customEnd))
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(customStart, customEnd)))?
                .addingTimeInterval(-1) ?? customEnd
            return lo...hi
        }
    }
}

/// Horizontal scroll of chips: date range presets, category multi-select,
/// source multi-select. Custom date range opens a sheet.
struct FinanceFilterBar: View {
    @Binding var state: FinanceFilterState

    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var people: [LocalPerson]

    @Query(sort: [SortDescriptor(\LocalEvent.updatedAt, order: .reverse)])
    private var events: [LocalEvent]

    @State private var customDateSheetVisible: Bool = false
    @State private var categorySheetVisible: Bool = false
    @State private var sourceSheetVisible: Bool = false
    @State private var personSheetVisible: Bool = false
    @State private var eventSheetVisible: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.sm) {
                // Date range chips
                ForEach(FinanceDateRangePreset.allCases) { preset in
                    chip(
                        label: preset == .custom ? customLabel : preset.displayName,
                        icon: preset == .custom ? "calendar" : nil,
                        selected: state.datePreset == preset,
                        action: {
                            if preset == .custom {
                                customDateSheetVisible = true
                            } else {
                                state.datePreset = preset
                            }
                        }
                    )
                }

                divider

                // Category filter chip — opens multi-select sheet
                chip(
                    label: categorySummary,
                    icon: "line.3.horizontal.decrease.circle",
                    selected: !state.categories.isEmpty,
                    action: { categorySheetVisible = true }
                )

                // Source filter chip
                chip(
                    label: sourceSummary,
                    icon: "antenna.radiowaves.left.and.right",
                    selected: !state.sources.isEmpty,
                    action: { sourceSheetVisible = true }
                )

                // Person filter chip — only when there are people to filter by.
                if !people.isEmpty {
                    chip(
                        label: personSummary,
                        icon: "person",
                        selected: !state.people.isEmpty,
                        action: { personSheetVisible = true }
                    )
                }

                // Event filter chip — only when there are events to filter by.
                if !events.isEmpty {
                    chip(
                        label: eventSummary,
                        icon: "calendar",
                        selected: !state.events.isEmpty,
                        action: { eventSheetVisible = true }
                    )
                }

                if hasActiveFilters {
                    chip(
                        label: "Clear",
                        icon: "xmark",
                        selected: false,
                        action: {
                            state.categories.removeAll()
                            state.sources.removeAll()
                            state.people.removeAll()
                            state.events.removeAll()
                        }
                    )
                }
            }
            .padding(.horizontal, Space.lg)
        }
        .sheet(isPresented: $customDateSheetVisible) {
            CustomDateRangeSheet(start: $state.customStart, end: $state.customEnd, onApply: {
                state.datePreset = .custom
            })
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $categorySheetVisible) {
            CategoryMultiSelectSheet(selection: $state.categories)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $sourceSheetVisible) {
            SourceMultiSelectSheet(selection: $state.sources)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $personSheetVisible) {
            PersonMultiSelectSheet(selection: $state.people)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $eventSheetVisible) {
            EventMultiSelectSheet(selection: $state.events)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var hasActiveFilters: Bool {
        !state.categories.isEmpty || !state.sources.isEmpty
            || !state.people.isEmpty || !state.events.isEmpty
    }

    private var customLabel: String {
        if state.datePreset == .custom {
            let fmt = DateFormatter()
            fmt.dateFormat = "d MMM"
            return "\(fmt.string(from: state.customStart)) – \(fmt.string(from: state.customEnd))"
        }
        return "Custom"
    }

    private var categorySummary: String {
        switch state.categories.count {
        case 0: return "Categories"
        case 1: return state.categories.first?.displayName ?? "Categories"
        default: return "\(state.categories.count) categories"
        }
    }

    private var sourceSummary: String {
        switch state.sources.count {
        case 0: return "Sources"
        case 1: return state.sources.first?.displayName ?? "Sources"
        default: return "\(state.sources.count) sources"
        }
    }

    private var personSummary: String {
        switch state.people.count {
        case 0: return "People"
        case 1:
            if let uuid = state.people.first,
               let person = people.first(where: { $0.clientUUID == uuid }) {
                return person.name
            }
            return "1 person"
        default: return "\(state.people.count) people"
        }
    }

    private var eventSummary: String {
        switch state.events.count {
        case 0: return "Events"
        case 1:
            if let uuid = state.events.first,
               let event = events.first(where: { $0.clientUUID == uuid }) {
                return event.name
            }
            return "1 event"
        default: return "\(state.events.count) events"
        }
    }

    private func chip(label: String, icon: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(label)
                    .font(.edFootnote)
            }
            .foregroundStyle(selected ? Tokens.accentFg : Tokens.inkSoft)
            .padding(.horizontal, Space.md)
            .padding(.vertical, 6)
            .background(selected ? Tokens.accentFinance : Tokens.surface, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(selected ? Color.clear : Tokens.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Tokens.divider)
            .frame(width: 0.5, height: 20)
            .padding(.horizontal, 2)
    }
}

// MARK: - Custom date range sheet

private struct CustomDateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var start: Date
    @Binding var end: Date
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                VStack(spacing: Space.lg) {
                    DatePicker("From", selection: $start, in: ...Date(), displayedComponents: .date)
                        .tint(Tokens.accentFinance)
                    DatePicker("To", selection: $end, in: start...Date(), displayedComponents: .date)
                        .tint(Tokens.accentFinance)
                    Spacer()
                }
                .padding(Space.lg)
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply()
                        dismiss()
                    }
                    .foregroundStyle(Tokens.ink)
                }
            }
        }
    }
}

// MARK: - Category multi-select sheet

private struct CategoryMultiSelectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Set<ExpenseCategory>

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                List {
                    ForEach(ExpenseCategory.allCases) { cat in
                        Button {
                            if selection.contains(cat) {
                                selection.remove(cat)
                            } else {
                                selection.insert(cat)
                            }
                        } label: {
                            HStack(spacing: Space.sm) {
                                Image(systemName: cat.sfSymbol)
                                    .foregroundStyle(Tokens.accentFinance)
                                    .frame(width: 24)
                                Text(cat.displayName)
                                    .foregroundStyle(Tokens.ink)
                                Spacer()
                                if selection.contains(cat) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Tokens.accentFinance)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Tokens.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
            }
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { selection.removeAll() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
    }
}

// MARK: - Source multi-select sheet

private struct SourceMultiSelectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Set<ExpenseSource>

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                List {
                    ForEach(ExpenseSource.allCases) { source in
                        Button {
                            if selection.contains(source) {
                                selection.remove(source)
                            } else {
                                selection.insert(source)
                            }
                        } label: {
                            HStack(spacing: Space.sm) {
                                Image(systemName: source.sfSymbol)
                                    .foregroundStyle(Tokens.accentFinance)
                                    .frame(width: 24)
                                Text(source.displayName)
                                    .foregroundStyle(Tokens.ink)
                                Spacer()
                                if selection.contains(source) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Tokens.accentFinance)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Tokens.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { selection.removeAll() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
    }
}

// MARK: - Person multi-select sheet (#183)

private struct PersonMultiSelectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Set<UUID>

    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var people: [LocalPerson]

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                List {
                    ForEach(people, id: \.clientUUID) { person in
                        Button {
                            if selection.contains(person.clientUUID) {
                                selection.remove(person.clientUUID)
                            } else {
                                selection.insert(person.clientUUID)
                            }
                        } label: {
                            HStack(spacing: Space.sm) {
                                Circle()
                                    .fill(Color(personHex: person.colorHex))
                                    .frame(width: 12, height: 12)
                                Text(person.name)
                                    .foregroundStyle(Tokens.ink)
                                Spacer()
                                if selection.contains(person.clientUUID) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Tokens.accentFinance)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Tokens.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { selection.removeAll() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
    }
}

// MARK: - Event multi-select sheet (#183)

private struct EventMultiSelectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Set<UUID>

    @Query(sort: [SortDescriptor(\LocalEvent.updatedAt, order: .reverse)])
    private var events: [LocalEvent]

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                List {
                    ForEach(events, id: \.clientUUID) { event in
                        Button {
                            if selection.contains(event.clientUUID) {
                                selection.remove(event.clientUUID)
                            } else {
                                selection.insert(event.clientUUID)
                            }
                        } label: {
                            HStack(spacing: Space.sm) {
                                Image(systemName: "calendar")
                                    .foregroundStyle(Tokens.accentFinance)
                                    .frame(width: 24)
                                Text(event.name)
                                    .foregroundStyle(Tokens.ink)
                                Spacer()
                                if selection.contains(event.clientUUID) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Tokens.accentFinance)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Tokens.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
            }
            .navigationTitle("Events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { selection.removeAll() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
    }
}
