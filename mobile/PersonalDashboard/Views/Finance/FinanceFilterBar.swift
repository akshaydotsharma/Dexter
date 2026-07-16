import SwiftUI
import SwiftData

/// Preset windows offered in the date-range picker. The date row shows the
/// four "primary" presets as chips (`topRowPresets`); the rolling-window and
/// year-ago presets (`customSheetPresets`) live as quick buttons inside the
/// Custom sheet, which also exposes manual From/To pickers (#211).
enum FinanceDateRangePreset: String, CaseIterable, Identifiable, Hashable {
    case thisMonth
    case lastMonth
    case thisYear
    case lastYear
    case last30
    case last90
    case custom

    var id: String { rawValue }

    /// Primary presets rendered as chips in the top date row (#211).
    static let topRowPresets: [FinanceDateRangePreset] = [.thisMonth, .lastMonth, .thisYear]

    /// Quick-range presets offered as buttons inside the Custom sheet (#211).
    static let customSheetPresets: [FinanceDateRangePreset] = [.last30, .last90, .lastYear]

    /// True for any preset reached through the Custom sheet (a picked range or
    /// one of the quick buttons). Drives the highlighted state + label of the
    /// single "Custom" chip in the date row.
    var isCustomFamily: Bool {
        switch self {
        case .last30, .last90, .lastYear, .custom: return true
        case .thisMonth, .lastMonth, .thisYear:    return false
        }
    }

    var displayName: String {
        switch self {
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .thisYear:  return "This year"
        case .lastYear:  return "Last year"
        case .last30:    return "Last 30 days"
        case .last90:    return "Last 90 days"
        case .custom:    return "Custom"
        }
    }

    /// Header label for the dashboard band (#187). Spelled-out variants of
    /// the (space-constrained) chip labels; `.custom` is filled in by the
    /// caller with the concrete date span since it needs the picked dates.
    var dashboardLabel: String {
        switch self {
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .thisYear:  return "This year"
        case .lastYear:  return "Last year"
        case .last30:    return "Last 30 days"
        case .last90:    return "Last 90 days"
        case .custom:    return "Custom range"
        }
    }

    /// Wording for the dashboard delta chip (#187). Calendar-month/year presets
    /// read naturally as "vs last/prior <period>"; the rolling-window and custom
    /// presets compare against the preceding span of equal length.
    var deltaComparisonLabel: String {
        switch self {
        case .thisMonth: return "vs last month"
        case .lastMonth: return "vs prior month"
        case .thisYear:  return "vs last year"
        case .lastYear:  return "vs prior year"
        case .last30, .last90, .custom: return "vs previous period"
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
    /// "Imported from" provenance filter (#245). Empty = no constraint.
    var importSources: Set<ImportSourceSelection> = []
    /// True once the user has tapped any date-preset chip (or committed a custom
    /// range) this session (#245). Until then the default `.thisMonth` window is
    /// a SOFT view, not a hard filter: it constrains the landing list but is
    /// dropped the moment another dimension is active, so picking e.g. an older
    /// "Imported from" statement doesn't get silently ANDed away by "this month".
    var dateExplicitlySet: Bool = false

    /// Whether any non-date dimension is currently active (incl. free-text
    /// search, which lives on the view's `.searchable` binding and is threaded
    /// in here). Drives the soft-date rule.
    func hasOtherFilters(searchText: String?) -> Bool {
        if !categories.isEmpty || !sources.isEmpty || !people.isEmpty
            || !events.isEmpty || !importSources.isEmpty { return true }
        if let search = searchText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !search.isEmpty { return true }
        return false
    }

    /// The date range constrains results IFF the user explicitly picked a date,
    /// OR no other filter is active (the landing view). Otherwise the default
    /// date window is dropped so the other filter searches all-time.
    func dateConstrains(searchText: String?) -> Bool {
        dateExplicitlySet || !hasOtherFilters(searchText: searchText)
    }

    /// Materialise the filter into a concrete `ExpenseFilter` honoured by
    /// the service layer. `searchText` is appended separately by the view
    /// because it lives on a `.searchable` binding.
    func resolvedFilter(searchText: String?) -> ExpenseFilter {
        var filter = ExpenseFilter()
        // Soft default date (#245): only constrain by date when the rule says so.
        // A nil `dateRange` makes both matchers skip the date check entirely.
        filter.dateRange = dateConstrains(searchText: searchText) ? resolvedDateRange() : nil
        if !categories.isEmpty { filter.categories = categories }
        if !sources.isEmpty { filter.sources = sources }
        if !people.isEmpty { filter.people = people }
        if !events.isEmpty { filter.events = events }
        if !importSources.isEmpty { filter.importSources = importSources }
        filter.searchText = searchText
        return filter
    }

    /// Concrete date window for the dashboard band (#187). Unlike
    /// `resolvedFilter().dateRange` (which is optional to model "no date
    /// constraint"), this always returns a range so the dashboard has a
    /// definite window to total, chart, and compute a delta over. Falls back
    /// to the current calendar month if a component add ever fails.
    func dashboardDateRange() -> ClosedRange<Date> {
        if let range = resolvedDateRange() { return range }
        let bounds = ExpenseDateRanges.monthBounds(for: Date())
        return bounds.0...bounds.1
    }

    /// Compact date span shown in the dashboard header for a `.custom` range,
    /// e.g. "3 Jun – 18 Jun". Same format as the filter chip's custom label.
    func customDashboardLabel() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM"
        let lo = min(customStart, customEnd)
        let hi = max(customStart, customEnd)
        return "\(fmt.string(from: lo)) – \(fmt.string(from: hi))"
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
        case .thisYear:
            let bounds = ExpenseDateRanges.yearBounds(for: now)
            return bounds.0...bounds.1
        case .lastYear:
            let prev = cal.date(byAdding: .year, value: -1, to: now) ?? now
            let bounds = ExpenseDateRanges.yearBounds(for: prev)
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

/// Finance filter bar (#211). A primary date row — four quick preset chips
/// plus a trailing "more filters" icon — sits above the list. The Custom chip
/// opens a sheet with quick ranges + manual From/To pickers; the icon opens a
/// sheet holding the Person / Event / Category / Source multi-selects and shows
/// an accent dot when any of those non-date filters is active.
struct FinanceFilterBar: View {
    @Binding var state: FinanceFilterState
    /// Whether the date range is actually constraining right now (#245). Computed
    /// by the view from the full filter state incl. free-text search. When false
    /// (date soft-dropped because another filter is active and no date chip was
    /// tapped) NO date chip is highlighted, so the row doesn't imply a date
    /// filter that isn't applied.
    var dateConstrains: Bool

    @State private var customDateSheetVisible: Bool = false
    @State private var moreFiltersSheetVisible: Bool = false

    var body: some View {
        HStack(spacing: Space.sm) {
            // Primary date row: scrolls if the chips overflow, so the trailing
            // filter icon always stays pinned to the right edge.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    ForEach(FinanceDateRangePreset.topRowPresets) { preset in
                        chip(
                            label: preset.displayName,
                            icon: nil,
                            // Highlight only when the date is actually applied
                            // (#245): a soft-dropped default shows no selection.
                            selected: dateConstrains && state.datePreset == preset,
                            action: {
                                state.datePreset = preset
                                // Any tap makes the date an explicit, hard filter.
                                state.dateExplicitlySet = true
                            }
                        )
                    }

                    // Single Custom chip — highlighted whenever the active preset
                    // was reached through the Custom sheet (a picked range or a
                    // quick button), with its label reflecting that choice.
                    chip(
                        label: customLabel,
                        icon: "calendar",
                        selected: dateConstrains && state.datePreset.isCustomFamily,
                        action: { customDateSheetVisible = true }
                    )
                }
                .padding(.leading, Space.lg)
                .padding(.trailing, Space.xs)
            }

            filterIconButton
                .padding(.trailing, Space.lg)
        }
        .sheet(isPresented: $customDateSheetVisible) {
            CustomDateRangeSheet(
                start: $state.customStart,
                end: $state.customEnd,
                onApplyCustom: {
                    state.datePreset = .custom
                    state.dateExplicitlySet = true
                },
                onSelectPreset: {
                    state.datePreset = $0
                    state.dateExplicitlySet = true
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $moreFiltersSheetVisible) {
            MoreFiltersSheet(
                datePreset: $state.datePreset,
                dateExplicitlySet: $state.dateExplicitlySet,
                categories: $state.categories,
                sources: $state.sources,
                people: $state.people,
                events: $state.events,
                importSources: $state.importSources
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Trailing icon that opens the non-date filters. Tints accent and shows a
    /// dot badge whenever any of person / event / category / source is active.
    private var filterIconButton: some View {
        Button {
            moreFiltersSheetVisible = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(hasActiveFilters ? Tokens.accentFinance : Tokens.inkSoft)
                .overlay(alignment: .topTrailing) {
                    if hasActiveFilters {
                        Circle()
                            .fill(Tokens.accentFinance)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Tokens.paper, lineWidth: 1.5))
                            .offset(x: 3, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More filters")
        .accessibilityValue(hasActiveFilters ? "Filters active" : "No filters active")
    }

    private var hasActiveFilters: Bool {
        !state.categories.isEmpty || !state.sources.isEmpty
            || !state.people.isEmpty || !state.events.isEmpty
            || !state.importSources.isEmpty
    }

    /// Label for the Custom chip: the picked span for `.custom`, the quick
    /// preset's name when one is active, otherwise the plain "Custom".
    private var customLabel: String {
        switch state.datePreset {
        case .custom:
            let fmt = DateFormatter()
            fmt.dateFormat = "d MMM"
            return "\(fmt.string(from: state.customStart)) – \(fmt.string(from: state.customEnd))"
        case .last30, .last90, .lastYear:
            return state.datePreset.displayName
        default:
            return "Custom"
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
}

// MARK: - Custom date range sheet

/// Date-range picker sheet (#211). Offers the rolling-window / year-ago quick
/// presets as buttons, plus manual From/To pickers for an arbitrary span.
/// Tapping a quick preset applies it and dismisses; "Apply" commits the manual
/// range as a `.custom` preset.
private struct CustomDateRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var start: Date
    @Binding var end: Date
    /// Commit the manual From/To span as a `.custom` range.
    let onApplyCustom: () -> Void
    /// Apply one of the quick presets (last30 / last90 / lastYear).
    let onSelectPreset: (FinanceDateRangePreset) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Space.lg) {
                    // Quick presets — one tap applies + dismisses.
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Quick ranges")
                            .eyebrow()
                        HStack(spacing: Space.sm) {
                            ForEach(FinanceDateRangePreset.customSheetPresets) { preset in
                                Button {
                                    onSelectPreset(preset)
                                    dismiss()
                                } label: {
                                    Text(preset.displayName)
                                        .font(.edFootnote)
                                        .foregroundStyle(Tokens.inkSoft)
                                        .padding(.horizontal, Space.md)
                                        .padding(.vertical, 6)
                                        .background(Tokens.surface, in: Capsule())
                                        .overlay(Capsule().stroke(Tokens.border, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Manual span.
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Custom range")
                            .eyebrow()
                        DatePicker("From", selection: $start, in: ...Date(), displayedComponents: .date)
                            .tint(Tokens.accentFinance)
                        DatePicker("To", selection: $end, in: start...Date(), displayedComponents: .date)
                            .tint(Tokens.accentFinance)
                    }

                    Spacer()
                }
                .padding(Space.lg)
            }
            .navigationTitle("Date range")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApplyCustom()
                        dismiss()
                    }
                    .foregroundStyle(Tokens.ink)
                }
            }
        }
    }
}

// MARK: - More filters sheet (#211)

/// Consolidates the Person / Event / Category / Source multi-selects — formerly
/// four always-visible chips each with its own sheet (#183) — into a single
/// sheet reached from the date row's filter icon. Each dimension is a
/// collapsed-by-default `DisclosureGroup` (#211) that shows its selection
/// summary ("All" / "N selected") and expands to the multi-select on tap;
/// "Clear" resets all four at once.
private struct MoreFiltersSheet: View {
    @Environment(\.dismiss) private var dismiss
    // Date bindings so "Clear" can return to the default This Month landing view
    // (#245): reset the preset AND drop the explicit-date flag so the date goes
    // back to being a soft default.
    @Binding var datePreset: FinanceDateRangePreset
    @Binding var dateExplicitlySet: Bool
    @Binding var categories: Set<ExpenseCategory>
    @Binding var sources: Set<ExpenseSource>
    @Binding var people: Set<UUID>
    @Binding var events: Set<UUID>
    @Binding var importSources: Set<ImportSourceSelection>

    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var allPeople: [LocalPerson]

    @Query(sort: [SortDescriptor(\LocalEvent.updatedAt, order: .reverse)])
    private var allEvents: [LocalEvent]

    // Backing data for the "Imported from" dimension (#245): every expense,
    // used to count rows per bucket. A bucket only appears when it currently
    // holds at least one expense (#251) — deleting a statement's rows (via the
    // Finance list or the AI `clear_expenses` tool) drops it from the filter.
    @Query private var allExpenses: [LocalExpense]

    // Per-dimension expansion state. Collapsed by default (#211).
    @State private var personExpanded = false
    @State private var eventExpanded = false
    @State private var categoryExpanded = false
    @State private var sourceExpanded = false
    @State private var importSourceExpanded = false

    private var hasActiveFilters: Bool {
        !categories.isEmpty || !sources.isEmpty || !people.isEmpty
            || !events.isEmpty || !importSources.isEmpty
    }

    /// A distinct statement the user can filter by, plus the count of expenses
    /// currently attributed to it. Derived purely from the live expenses: a
    /// statement lists only while it still has rows (#251). Labels found on
    /// expenses cover both current and legacy imports (statements predating the
    /// batch model still carry a `statementLabel` on their rows).
    private struct StatementOption: Identifiable {
        let label: String
        let count: Int
        var id: String { label }
    }

    private var statementOptions: [StatementOption] {
        // Count expenses per trimmed, non-empty statement label across the
        // current set. Only labels with a live count survive (#251), so a
        // statement whose rows were all deleted no longer appears.
        var counts: [String: Int] = [:]
        for expense in allExpenses {
            let label = expense.statementLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            counts[label, default: 0] += 1
        }
        return counts.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { StatementOption(label: $0, count: counts[$0] ?? 0) }
    }

    /// Number of expenses currently in the fixed "Manually added" bucket
    /// (anything that isn't a receipt and carries no statement label). Drives
    /// whether the row shows (#251).
    private var manualImportCount: Int {
        allExpenses.filter { ImportSourceSelection.manual.matches($0) }.count
    }

    /// Number of expenses currently in the "Receipts" bucket. Drives whether
    /// the row shows (#251).
    private var receiptsImportCount: Int {
        allExpenses.filter { ImportSourceSelection.receipts.matches($0) }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                List {
                    // Person — only when there are people to filter by.
                    if !allPeople.isEmpty {
                        DisclosureGroup(isExpanded: $personExpanded) {
                            ForEach(allPeople, id: \.clientUUID) { person in
                                toggleRow(selected: people.contains(person.clientUUID)) {
                                    toggle(person.clientUUID, in: &people)
                                } label: {
                                    Circle()
                                        .fill(Color(personHex: person.colorHex))
                                        .frame(width: 12, height: 12)
                                        .frame(width: 24)
                                    Text(person.name)
                                        .foregroundStyle(Tokens.ink)
                                }
                            }
                        } label: {
                            dimensionLabel("Person", summary: summary(people.count))
                        }
                        .tint(Tokens.accentFinance)
                        .listRowBackground(Tokens.surface)
                    }

                    // Event — only when there are events to filter by.
                    if !allEvents.isEmpty {
                        DisclosureGroup(isExpanded: $eventExpanded) {
                            ForEach(allEvents, id: \.clientUUID) { event in
                                toggleRow(selected: events.contains(event.clientUUID)) {
                                    toggle(event.clientUUID, in: &events)
                                } label: {
                                    Image(systemName: "calendar")
                                        .foregroundStyle(Tokens.accentFinance)
                                        .frame(width: 24)
                                    Text(event.name)
                                        .foregroundStyle(Tokens.ink)
                                }
                            }
                        } label: {
                            dimensionLabel("Event", summary: summary(events.count))
                        }
                        .tint(Tokens.accentFinance)
                        .listRowBackground(Tokens.surface)
                    }

                    DisclosureGroup(isExpanded: $categoryExpanded) {
                        ForEach(ExpenseCategory.allCases) { cat in
                            toggleRow(selected: categories.contains(cat)) {
                                toggle(cat, in: &categories)
                            } label: {
                                Image(systemName: cat.sfSymbol)
                                    .foregroundStyle(Tokens.accentFinance)
                                    .frame(width: 24)
                                Text(cat.displayName)
                                    .foregroundStyle(Tokens.ink)
                            }
                        }
                    } label: {
                        dimensionLabel("Category", summary: summary(categories.count))
                    }
                    .tint(Tokens.accentFinance)
                    .listRowBackground(Tokens.surface)

                    DisclosureGroup(isExpanded: $sourceExpanded) {
                        ForEach(ExpenseSource.allCases) { source in
                            toggleRow(selected: sources.contains(source)) {
                                toggle(source, in: &sources)
                            } label: {
                                Image(systemName: source.sfSymbol)
                                    .foregroundStyle(Tokens.accentFinance)
                                    .frame(width: 24)
                                Text(source.displayName)
                                    .foregroundStyle(Tokens.ink)
                            }
                        }
                    } label: {
                        dimensionLabel("Source", summary: summary(sources.count))
                    }
                    .tint(Tokens.accentFinance)
                    .listRowBackground(Tokens.surface)

                    // Imported from — provenance buckets (#245). Sits alongside
                    // Source: Source is the raw capture channel, this is the
                    // import batch an expense came from (manual / receipts /
                    // each statement). Each bucket shows only while it holds a
                    // live expense, and the whole dimension hides when empty
                    // (#251) — mirrors the Person/Event dimensions above.
                    if manualImportCount > 0 || receiptsImportCount > 0 || !statementOptions.isEmpty {
                        DisclosureGroup(isExpanded: $importSourceExpanded) {
                            if manualImportCount > 0 {
                                toggleRow(selected: importSources.contains(.manual)) {
                                    toggle(.manual, in: &importSources)
                                } label: {
                                    Image(systemName: "pencil")
                                        .foregroundStyle(Tokens.accentFinance)
                                        .frame(width: 24)
                                    Text("Manually added")
                                        .foregroundStyle(Tokens.ink)
                                }
                            }

                            if receiptsImportCount > 0 {
                                toggleRow(selected: importSources.contains(.receipts)) {
                                    toggle(.receipts, in: &importSources)
                                } label: {
                                    Image(systemName: "doc.text.viewfinder")
                                        .foregroundStyle(Tokens.accentFinance)
                                        .frame(width: 24)
                                    Text("Receipts")
                                        .foregroundStyle(Tokens.ink)
                                }
                            }

                            if !statementOptions.isEmpty {
                                Text("Statements")
                                    .font(.edFootnote)
                                    .foregroundStyle(Tokens.muted)
                                    .listRowBackground(Tokens.surface)
                                ForEach(statementOptions) { option in
                                    statementRow(option)
                                }
                            }
                        } label: {
                            dimensionLabel("Imported from", summary: summary(importSources.count))
                        }
                        .tint(Tokens.accentFinance)
                        .listRowBackground(Tokens.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
            }
            .navigationTitle("Filters")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        categories.removeAll()
                        sources.removeAll()
                        people.removeAll()
                        events.removeAll()
                        importSources.removeAll()
                        // Back to the default This Month landing view (#245).
                        datePreset = .thisMonth
                        dateExplicitlySet = false
                    }
                    .foregroundStyle(Tokens.muted)
                    .disabled(!hasActiveFilters)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
    }

    /// "All" when nothing is picked, otherwise "N selected" — the collapsed
    /// summary shown next to each dimension name (#211).
    private func summary(_ count: Int) -> String {
        count == 0 ? "All" : "\(count) selected"
    }

    /// Collapsed row label: dimension name on the left, selection summary on
    /// the right. The DisclosureGroup supplies the leading chevron.
    private func dimensionLabel(_ name: String, summary: String) -> some View {
        HStack {
            Text(name)
                .foregroundStyle(Tokens.ink)
            Spacer()
            Text(summary)
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
        }
    }

    /// Insert-or-remove `value` in a selection set (the toggle idiom shared by
    /// all four dimensions).
    private func toggle<T: Hashable>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }

    /// A single statement row for the "Imported from" dimension (#245): icon +
    /// label, a muted expense count, and a trailing checkmark when selected.
    /// Styled to match `toggleRow` but carries the per-statement count between
    /// the label and the checkmark.
    private func statementRow(_ option: StatementOption) -> some View {
        let selected = importSources.contains(.statement(label: option.label))
        return Button {
            toggle(.statement(label: option.label), in: &importSources)
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Tokens.accentFinance)
                    .frame(width: 24)
                Text(option.label)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.sm)
                Text("\(option.count)")
                    .font(.edFootnote)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.muted)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Tokens.accentFinance)
                }
            }
            // Stretch to the full row width and make the whole rect (incl. the
            // transparent space the Spacer occupies) tappable, not just the
            // rendered text/icon glyphs (#245 follow-up: tap target bug).
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Tokens.surface)
    }

    /// One selectable row: a leading label (icon/swatch + text) and a trailing
    /// checkmark when selected. Mirrors the old per-sheet row styling.
    private func toggleRow<Label: View>(
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                label()
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Tokens.accentFinance)
                }
            }
            // Stretch to the full row width and make the whole rect (incl. the
            // transparent space the Spacer occupies) tappable, not just the
            // rendered text/icon glyphs (#245 follow-up: tap target bug).
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Tokens.surface)
    }
}
