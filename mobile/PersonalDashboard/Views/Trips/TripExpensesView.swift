import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The expenses tab of a trip's detail screen (#258).
///
/// Trip expenses are ordinary `LocalExpense` rows joined by `tripUUID` (the FK
/// added in #177), enriched with the settle-up split metadata (#258). This
/// view surfaces three things: header stats (group total, the user's share,
/// count), netted settle-up balances ("Rohan is owed S$140"), and the expense
/// list itself. Adding / editing goes through `AddExpenseSheet` with a trip
/// context, driven by the parent `TripDetailView` (which owns the sheet + FAB).
/// Participants are managed in the trip editor (Edit trip on the Itineraries
/// list), not here.
///
/// Amounts default to the currency each expense was CAPTURED in — a trip's
/// spend reads naturally in euros on a Europe trip. A toggle on the stats card
/// converts the whole tab to the chosen display currency on demand.
struct TripExpensesView: View {
    let trip: LocalTrip

    /// Tapping a row bubbles the expense's clientUUID up so the parent opens
    /// the editor (the parent owns the sheet + trip context).
    let onEditExpense: (String) -> Void

    /// Trip expenses, newest first. Filtered by the trip FK in the query.
    @Query private var expenses: [LocalExpense]

    /// People, so participant names / colours resolve for the settle-up rows.
    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var people: [LocalPerson]

    /// Whose numbers the summary card shows (and, for non-default selections,
    /// which expenses the list narrows to). Multi-select; never empty.
    /// Defaults to just the user — the tab's core question is "how much have
    /// I spent on this trip".
    @State private var filterParties: Set<SplitPartyID> = [.me]
    /// Currency the summary card renders in. `nil` = the Settings display
    /// currency; otherwise one of the currencies captured on this trip
    /// (converted through the trip's own frozen FX observations).
    @State private var filterCurrency: String? = nil

    /// Which sheet this tab is showing. ONE `.sheet` modifier driven by an
    /// item, not two `.sheet(isPresented:)` stacked on the same view — SwiftUI
    /// honours only one presentation of a kind per view, the same trap that
    /// silently broke a second `.fileImporter` here in #261.
    @State private var activeSheet: TripExpenseSheet?

    /// Report export in flight (#528). Rendering the PDF runs on the main
    /// actor (`ImageRenderer` is main-actor only), so the control reports
    /// itself busy rather than looking dead for the render.
    @State private var isExporting: Bool = false
    /// The currency the NEXT export is written in. Seeded from what the tab is
    /// showing when the options sheet opens, then owned by the sheet.
    @State private var exportCurrency: String? = nil
    /// Set by the sheet's Export button so the run starts AFTER the sheet is
    /// gone. On macOS the export ends in an `NSSavePanel`, and a modal panel
    /// raised from under a sheet that is still dismissing is the popover trap
    /// from #416 in a different costume. Waiting for `onDismiss` avoids it.
    @State private var pendingExport: Bool = false
    /// Surfaced under the summary card when an export fails. Cancelling the
    /// share sheet or the save panel is not a failure and sets nothing.
    @State private var exportError: String?

    /// Expense the user has swiped-to-delete and we're confirming (#264).
    @State private var pendingDelete: LocalExpense?

    @Environment(\.modelContext) private var modelContext

    init(trip: LocalTrip, onEditExpense: @escaping (String) -> Void) {
        self.trip = trip
        self.onEditExpense = onEditExpense
        let tripID = trip.clientUUID
        // Rows removed from the trip (#264) stay in the store to keep backing
        // the Finance list, but no trip surface — totals, settle-up, list —
        // may see them. Filtering in the predicate covers all of them at once.
        _expenses = Query(
            filter: #Predicate<LocalExpense> { $0.tripUUID == tripID && !$0.hiddenFromTrip },
            sort: [
                SortDescriptor(\.date, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse)
            ]
        )
    }

    var body: some View {
        Group {
            if expenses.isEmpty {
                emptyState
            } else {
                populated
            }
        }
        .alert(
            "Remove this expense?",
            isPresented: deleteDialogBinding
        ) {
            Button("Remove", role: .destructive) {
                if let row = pendingDelete {
                    delete(row)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map { deleteMessage(for: $0) } ?? "")
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { newValue in if !newValue { pendingDelete = nil } }
        )
    }

    private func deleteMessage(for expense: LocalExpense) -> String {
        let label = expense.merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? expense.expenseDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? expense.categoryEnum.displayName
        let amount = Self.formatOriginal(expense.originalAmount, code: expense.originalCurrency.uppercased())
        if expense.hiddenFromFinance {
            return "\(label) · \(amount)"
        }
        return "\(label) · \(amount)\nRemoves it from this trip only — it stays in your finances."
    }

    /// Trip-side delete honouring the per-surface visibility model (#264): a
    /// row still visible in Finance is only HIDDEN from the trip; a row the
    /// user already removed from Finance has no remaining surface and is
    /// physically deleted (receipt file cleaned up unless a sibling row from
    /// the same multi-expense import still references it).
    private func delete(_ expense: LocalExpense) {
        if !expense.hiddenFromFinance {
            expense.hiddenFromTrip = true
            try? modelContext.save()
            return
        }
        if let path = expense.receiptImagePath {
            let all = (try? modelContext.fetch(FetchDescriptor<LocalExpense>())) ?? []
            let stillReferenced = all.contains {
                $0.clientUUID != expense.clientUUID && $0.receiptImagePath == path
            }
            if !stillReferenced {
                try? ReceiptStorage.shared.delete(relativePath: path)
            }
        }
        modelContext.delete(expense)
        try? modelContext.save()
    }

    // MARK: - Populated

    private var populated: some View {
        ScrollView {
            VStack(spacing: Space.lg) {
                personSummaryCard
                statsCard
                if !balances.isEmpty {
                    settleUpCard
                }
                expenseList
                Color.clear.frame(height: 96)
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $activeSheet, onDismiss: runPendingExport) { sheet in
            switch sheet {
            case .filter:
                TripExpenseFilterSheet(
                    participants: participantPeople,
                    currencyOptions: filterCurrencyOptions,
                    displayCode: displayCurrencyCode,
                    parties: $filterParties,
                    currency: $filterCurrency
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .renamePerson(let id):
                // A second `.sheet` on this view would be silently dropped, so
                // the rename goes through the same item-driven presentation as
                // the other two (see `activeSheet`).
                if let person = people.first(where: { $0.clientUUID == id }) {
                    RenamePersonSheet(person: person)
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                }
            case .exportOptions:
                TripExportOptionsSheet(
                    currencyOptions: filterCurrencyOptions,
                    displayCode: displayCurrencyCode,
                    currency: $exportCurrency,
                    onExport: { pendingExport = true }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    /// Trip participants resolved to live person records, preserving order.
    private var participantPeople: [LocalPerson] {
        trip.participantPersonUUIDs.compactMap { id in
            people.first { $0.clientUUID == id }
        }
    }

    // MARK: - Person summary (filterable)

    /// Currencies the summary can render in: every capture currency on the
    /// trip. The Settings display currency is the `nil` option and always
    /// offered first by the sheet.
    private var filterCurrencyOptions: [String] {
        totalsByCurrency.map { $0.code }.filter { $0 != displayCurrencyCode }
    }

    /// Aggregate conversion rate (code → SGD) observed on this trip's own
    /// expenses: total frozen SGD over total captured amount. Weighted by
    /// spend, stable across extraction noise, and works offline. Nil when the
    /// trip has no usable observation for the code.
    private func tripRateToSGD(for code: String) -> Double? {
        let matching = expenses.filter { $0.originalCurrency.uppercased() == code }
        let original = matching.reduce(0) { $0 + $1.originalAmount }
        let sgd = matching.reduce(0) { $0 + $1.sgdAmount }
        guard original > 0, sgd > 0 else { return nil }
        return sgd / original
    }

    /// Format a home-currency (SGD) value in the summary's selected currency.
    private func formatFiltered(_ sgdValue: Double) -> String {
        formatMoney(sgdValue, in: filterCurrency)
    }

    /// The same conversion against an EXPLICIT currency, so the report can be
    /// written in one the tab is not currently showing (#528). `nil` means the
    /// Settings display currency.
    private func formatMoney(_ sgdValue: Double, in currencyCode: String?) -> String {
        guard let code = currencyCode, code != displayCurrencyCode else {
            return FinanceDashboardBand.formatMoney(sgdValue)
        }
        if code == "SGD" {
            return Self.formatOriginal(sgdValue, code: code)
        }
        guard let rate = tripRateToSGD(for: code) else {
            return FinanceDashboardBand.formatMoney(sgdValue)
        }
        return Self.formatOriginal(sgdValue / rate, code: code)
    }

    /// Selected party names in stable order: You first, then trip-participant
    /// order.
    private var selectedPartyNames: [String] {
        var names: [String] = []
        if filterParties.contains(.me) { names.append("You") }
        for person in participantPeople where filterParties.contains(.person(person.clientUUID)) {
            names.append(person.name)
        }
        return names
    }

    /// "Your spend" / "Rohan's spend" / "You + Rohan" / "3 people".
    private var summaryTitle: String {
        let names = selectedPartyNames
        if filterParties == [.me] { return "Your spend" }
        if names.count == 1 { return names[0] == "You" ? "Your spend" : "\(names[0])'s spend" }
        if names.count == 2 { return "\(names[0]) + \(names[1])" }
        return "\(names.count) people"
    }

    /// Short list-header suffix for the active selection.
    private var selectionShortLabel: String {
        let names = selectedPartyNames
        if names.count <= 2 { return names.joined(separator: " + ") }
        return "\(names.count) people"
    }

    /// The card that answers "how much have I spent on this trip" — and the
    /// same for any set of participants via the filter. Spent = their combined
    /// consumed share across the bills; Paid = what they fronted; the net line
    /// is their combined settle-up position.
    private var personSummaryCard: some View {
        let allTotals = TripSettlement.totals(expenses: expenses)
        let paid = filterParties.reduce(0) { $0 + (allTotals[$1]?.paid ?? 0) }
        let owed = filterParties.reduce(0) { $0 + (allTotals[$1]?.owed ?? 0) }
        let net = paid - owed
        let meOnly = filterParties == [.me]
        let single = filterParties.count == 1
        let owedLabel: String = {
            if meOnly { return net >= 0 ? "You are owed" : "You owe" }
            if single { return net >= 0 ? "Is owed" : "Owes" }
            return net >= 0 ? "Owed" : "Owe"
        }()
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.md) {
                Text(summaryTitle).eyebrow()
                Spacer()
                exportButton
                filterButton
            }

            // Spent = consumed share of the bills; Paid = fronted out of
            // pocket; the net tile is Paid − Spent (their settle-up position).
            HStack(alignment: .firstTextBaseline) {
                Text("Spent")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                Spacer()
                Text(formatFiltered(owed))
                    .font(.edDisplay)
                    .foregroundStyle(Tokens.ink)
                    .tracking(-0.6)
            }

            HStack(spacing: Space.lg) {
                statTile(label: "Paid", value: formatFiltered(paid))
                statTile(label: owedLabel, value: formatFiltered(abs(net)))
            }
            .padding(.top, Space.xs)

            if let exportError {
                Text(exportError)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    /// Download the trip's expenses as a PDF report (#528). Sits beside the
    /// filter control because the two are read together: the filter decides
    /// what the ledger lists, and this exports exactly that.
    private var exportButton: some View {
        Button {
            // Seed the picker with what the tab is showing, so the obvious
            // path is one extra tap.
            exportCurrency = filterCurrency
            exportError = nil
            activeSheet = .exportOptions
        } label: {
            Group {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Tokens.accentFinance)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isExporting || expenses.isEmpty)
        .accessibilityLabel("Download these expenses as a PDF report")
    }

    private var filterButton: some View {
        Button {
            activeSheet = .filter
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Tokens.accentFinance)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter by people and currency")
    }

    // MARK: - Currency mode

    /// Per-currency signed totals in capture currency, largest spend first.
    private var totalsByCurrency: [(code: String, total: Double, myShare: Double)] {
        var totals: [String: (total: Double, myShare: Double)] = [:]
        for expense in expenses {
            let code = expense.originalCurrency.uppercased()
            var entry = totals[code] ?? (0, 0)
            entry.total += expense.signedOriginal
            entry.myShare += expense.myShareOriginal
            totals[code] = entry
        }
        return totals
            .map { (code: $0.key, total: $0.value.total, myShare: $0.value.myShare) }
            .sorted { abs($0.total) > abs($1.total) }
    }

    /// Non-nil when every expense was captured in the same currency — the only
    /// case where settle-up can run natively in the capture currency.
    private var singleCurrencyCode: String? {
        let codes = Set(expenses.map { $0.originalCurrency.uppercased() })
        return codes.count == 1 ? codes.first : nil
    }

    /// "EUR 1,240.50", signed. Capture-currency counterpart of
    /// `FinanceDashboardBand.formatMoney` (which converts to the display
    /// currency and uses its symbol).
    static func formatOriginal(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let amount = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        return "\(code) \(amount)"
    }

    private var displayCurrencyCode: String {
        FinanceSettings.displayCurrencyCode.uppercased()
    }

    // MARK: - Stats card

    private var groupTotalSGD: Double {
        expenses.reduce(0) { $0 + $1.signedSGD }
    }

    /// Whether the per-currency breakdown adds information: hidden when the
    /// trip has a single currency that IS the display currency (the Total row
    /// would just repeat it).
    private var showsCurrencyBreakdown: Bool {
        let totals = totalsByCurrency
        if totals.count == 1, totals[0].code == displayCurrencyCode { return false }
        return !totals.isEmpty
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("Group total").eyebrow()
                Spacer()
                Text("^[\(expenses.count) expense](inflect: true)")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                // As-added spend, one same-weight line per capture currency.
                if showsCurrencyBreakdown {
                    ForEach(totalsByCurrency, id: \.code) { entry in
                        Text(Self.formatOriginal(entry.total, code: entry.code))
                            .font(.edBodyMedium)
                            .monospacedDigit()
                            .foregroundStyle(Tokens.inkSoft)
                    }
                    Divider().background(Tokens.divider)
                }
                // The one number that sums the whole trip: converted into the
                // display currency chosen in Settings.
                HStack(alignment: .firstTextBaseline) {
                    Text("Total")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                    Spacer()
                    Text(formatFiltered(groupTotalSGD))
                        .font(.edDisplay)
                        .foregroundStyle(Tokens.ink)
                        .tracking(-0.6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    private func statTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
            Text(value)
                .font(.edBodyMedium)
                .monospacedDigit()
                .foregroundStyle(Tokens.inkSoft)
        }
    }

    // MARK: - Settle up

    /// True when the settle-up card can run natively in the capture currency:
    /// the whole trip shares one currency. A mixed-currency trip has no
    /// meaningful "as added" net, so it falls back to the display currency
    /// (flagged in the card).
    private var settlesInCaptureCurrency: Bool {
        singleCurrencyCode != nil
    }

    /// Netted per-party balances, sorted with the user first, then the people
    /// who are owed the most. Only parties whose net is more than a cent show.
    private var balances: [TripSettlement.Balance] {
        if settlesInCaptureCurrency {
            return TripSettlement.compute(expenses: expenses) { $0.signedOriginal }
        }
        return TripSettlement.compute(expenses: expenses)
    }

    private func settleAmount(_ value: Double) -> String {
        if settlesInCaptureCurrency, let code = singleCurrencyCode {
            return Self.formatOriginal(value, code: code)
        }
        return FinanceDashboardBand.formatMoney(value)
    }

    private var settleUpCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("Settle up").eyebrow()
                if singleCurrencyCode == nil {
                    Spacer()
                    Text("in \(displayCurrencyCode) · mixed currencies")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                }
            }
            VStack(spacing: Space.sm) {
                ForEach(balances) { balance in
                    settleRow(balance)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.lg)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.lg)
    }

    /// One settle-up line. The NAME is a rename control; the rest of the line
    /// is not (#530).
    ///
    /// This is where a participant's name is actually met — the trip sheet's
    /// participant row is where the list is managed, which is a different
    /// errand and not where anyone looks to correct a name. The split mirrors
    /// the participant chip: the name renames, everything around it is inert,
    /// so no gesture on this row can swallow another.
    ///
    /// "You" is never a control. The user is not a `LocalPerson` and has no
    /// name to edit.
    private func settleRow(_ balance: TripSettlement.Balance) -> some View {
        // Positive net = owed money (green); negative = owes (ink). The amount
        // is shown as a magnitude; the phrasing carries the direction.
        let owed = balance.net > 0
        return HStack(spacing: Space.sm) {
            Circle()
                .fill(partyColor(balance.party))
                .frame(width: 10, height: 10)
            // Nested in their own HStack at a word's spacing: the row's own
            // `Space.sm` between the two Texts reads as a double space and
            // breaks the line into two phrases.
            HStack(spacing: 4) {
                settleName(balance.party)
                Text(suffix(for: balance))
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            Text(settleAmount(abs(balance.net)))
                .font(.edFootnoteStrong)
                .monospacedDigit()
                .foregroundStyle(owed ? Tokens.success : Tokens.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phrase(for: balance)) \(settleAmount(abs(balance.net)))")
    }

    /// "You are owed" / "You owe" / "Rohan is owed" / "Sam owes".
    ///
    /// Still built whole for the accessibility label, which reads the line as
    /// one sentence. The rendered line composes it from `settleName` and
    /// `suffix` so the name alone can be a control (#530).
    private func phrase(for balance: TripSettlement.Balance) -> String {
        let name: String
        switch balance.party {
        case .me:             name = "You"
        case .person(let id): name = personName(id)
        }
        return "\(name) \(suffix(for: balance))"
    }

    /// The verb half of the line. "You" takes the second person, a named
    /// person the third.
    private func suffix(for balance: TripSettlement.Balance) -> String {
        let owed = balance.net > 0
        switch balance.party {
        case .me:      return owed ? "are owed" : "owe"
        case .person:  return owed ? "is owed" : "owes"
        }
    }

    /// The name half. A button for a person whose record still exists, plain
    /// text for the user and for a person deleted out from under a split.
    @ViewBuilder
    private func settleName(_ party: SplitPartyID) -> some View {
        switch party {
        case .person(let id) where people.contains(where: { $0.clientUUID == id }):
            Button {
                activeSheet = .renamePerson(id)
            } label: {
                Text(personName(id))
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename \(personName(id))")
        case .me, .person:
            Text(party == .me ? "You" : "Someone")
                .font(.edFootnote)
                .foregroundStyle(Tokens.inkSoft)
                .lineLimit(1)
        }
    }

    private func personName(_ id: UUID) -> String {
        people.first { $0.clientUUID == id }?.name ?? "Someone"
    }

    private func partyColor(_ party: SplitPartyID) -> Color {
        switch party {
        case .me:
            return Tokens.accentFinance
        case .person(let id):
            if let person = people.first(where: { $0.clientUUID == id }) {
                return Color(personHex: person.colorHex)
            }
            return Tokens.accentFinance
        }
    }

    // MARK: - Expense list

    /// Whether an expense involves the given party — they paid it, or they
    /// hold a positive share of the split.
    private func involves(_ expense: LocalExpense, party: SplitPartyID) -> Bool {
        let payer: SplitPartyID = expense.paidByPersonUUID.map { .person($0) } ?? .me
        if payer == party { return true }
        return expense.splits.contains { entry in
            guard entry.shares > 0 else { return false }
            let entryParty: SplitPartyID = entry.personID.map { .person($0) } ?? .me
            return entryParty == party
        }
    }

    /// The list narrows to expenses involving ANY selected participant; the
    /// default You-only selection keeps the full list (the summary card
    /// already answers the "my spend" question without hiding group context).
    private var visibleExpenses: [LocalExpense] {
        guard filterParties != [.me] else { return Array(expenses) }
        return expenses.filter { expense in
            filterParties.contains { involves(expense, party: $0) }
        }
    }

    private var expenseList: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(filterParties == [.me] ? "Expenses" : "Expenses · \(selectionShortLabel)").eyebrow()
            // Same flat-row construction as the Finance list, since both render
            // `ExpenseRow` (issue #303). The scope gives the rows their people /
            // trips lookup in one fetch rather than two per row (#442).
            ExpenseRowLookupScope {
                VStack(spacing: RowMetrics.interRowSpacing) {
                    ForEach(visibleExpenses) { expense in
                        ExpenseRow(expense: expense, showsOriginalFirst: true) {
                            onEditExpense(expense.clientUUID)
                        }
                        .swipeToDeleteTrash {
                            pendingDelete = expense
                        }
                    }
                }
            }
            if filterParties != [.me] && visibleExpenses.isEmpty {
                Text("No expenses involve this selection yet.")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }
        }
    }

    // MARK: - Report export (#528)

    /// The trip's own state, handed to the report builder.
    ///
    /// Nothing here is recomputed: the money formatters are the tab's, and
    /// `tripRateToSGD` is the conversion the tab already converts with, so the
    /// report can only say what the tab says.
    ///
    /// `expenses` — the whole trip — is what goes in, NOT `visibleExpenses`.
    /// The people filter is a reading aid for the tab; the report is the
    /// group's record of the trip and every section of it covers everyone.
    private func reportInput(currency: String?) -> TripExpenseReportInput {
        let order: [SplitPartyID] = [.me] + participantPeople.map { .person($0.clientUUID) }
        return TripExpenseReportInput(
            tripName: trip.name,
            startDate: trip.startDate,
            endDate: trip.endDate,
            allExpenses: Array(expenses),
            participantOrder: order,
            reportCurrencyCode: currency ?? displayCurrencyCode,
            exportDate: Date(),
            displayName: { party in
                switch party {
                case .me:             return "You"
                case .person(let id): return personName(id)
                }
            },
            displayMoney: { formatMoney($0, in: currency) },
            captureMoney: { value, code in Self.formatOriginal(value, code: code) },
            tripRateToSGD: { tripRateToSGD(for: $0) }
        )
    }

    /// Runs after the options sheet has fully dismissed, so the macOS save
    /// panel is raised from the window rather than from under a closing sheet.
    private func runPendingExport() {
        guard pendingExport else { return }
        pendingExport = false
        let currency = exportCurrency
        Task { await exportReport(currency: currency) }
    }

    private func exportReport(currency: String?) async {
        guard !expenses.isEmpty, !isExporting else { return }
        exportError = nil
        isExporting = true
        defer { isExporting = false }

        do {
            let report = TripExpenseReport.make(reportInput(currency: currency))
            let url = try TripExpenseReportPDF.write(report)
            try await ExportDelivery.deliver(
                fileAt: url,
                contentTypes: [.pdf],
                panelTitle: "Save trip expense report"
            )
        } catch {
            exportError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                Image(systemName: "wallet.bifold")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Tokens.mutedSoft)
                Spacer().frame(height: Space.md)
                Text("No expenses yet")
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.center)
                Spacer().frame(height: Space.xs)
                Text(trip.participantPersonUUIDs.isEmpty
                     ? "Tap + to log a trip expense. Add people in Edit trip to split the bill."
                     : "Tap + to log a trip expense and split it with your group.")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.lg)
    }
}

// MARK: - Sheet routing

/// The sheets this tab can show. An item-driven `.sheet` rather than one
/// `isPresented` flag per sheet: SwiftUI honours a single presentation of a
/// kind per view, so a second `.sheet(isPresented:)` on the same view would
/// silently never appear.
private enum TripExpenseSheet: Identifiable, Hashable {
    case filter
    case exportOptions
    /// Rename the person behind a settle-up line (#530). Carries the id, not
    /// the record: an enum case has to be `Hashable` for `Identifiable`, and
    /// the view resolves the id back to a live `LocalPerson` anyway.
    case renamePerson(UUID)

    var id: String {
        switch self {
        case .filter:                return "filter"
        case .exportOptions:         return "exportOptions"
        case .renamePerson(let id):  return "renamePerson-\(id.uuidString)"
        }
    }
}

// MARK: - Export options sheet

/// Chooses what the exported report is written in (#528).
///
/// The currency is asked for at export time rather than inherited from the
/// tab's own currency toggle, because the two answer different questions: the
/// toggle is how the person reading the screen wants to read it, and this is
/// what the group being sent the PDF should read. Seeded from the tab's
/// current choice, so agreeing with it is one tap.
private struct TripExportOptionsSheet: View {
    /// Trip capture currencies, excluding the display currency. The same set
    /// the filter sheet offers.
    let currencyOptions: [String]
    let displayCode: String
    @Binding var currency: String?
    /// Called before dismissing. The caller starts the export from the
    /// sheet's `onDismiss`, never from here.
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Report currency").eyebrow()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.sm) {
                                currencyChip(nil, label: displayCode)
                                ForEach(currencyOptions, id: \.self) { code in
                                    currencyChip(code, label: code)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        Text("Totals, the settle-up table and the transfers are all written in this currency, converted with the rates frozen on this trip's expenses. Each expense in the ledger keeps the currency it was captured in.")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.mutedSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        onExport()
                        dismiss()
                    } label: {
                        Text("Export PDF")
                            .font(.edBodyMedium)
                            .foregroundStyle(Tokens.accentFg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.md)
                            .background(Tokens.accentFinance, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(Space.lg)
            }
            .background(Tokens.paper)
            .navigationTitle("Export report")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        // A macOS sheet with no intrinsic height collapses to its toolbar
        // (#474). The content here is short, so it gets an explicit frame.
        .frame(width: 420, height: 300)
        #endif
    }

    private func currencyChip(_ code: String?, label: String) -> some View {
        let selected = currency == code
        return Button {
            currency = code
        } label: {
            Text(label)
                .font(.edFootnote)
                .foregroundStyle(selected ? Tokens.accentFg : Tokens.ink)
                .padding(.horizontal, Space.md)
                .padding(.vertical, 6)
                .background(
                    selected ? Tokens.accentFinance : Tokens.surface2,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "\(label), selected" : label)
    }
}

// MARK: - Filter sheet

/// People + currency filter for the trip expenses summary (#258). People are
/// multi-select — the summary card shows the combined spend/paid/net of the
/// selection and the list narrows to expenses involving any of them. Currency
/// picks what the summary renders in — the Settings display currency, or any
/// currency captured on the trip.
private struct TripExpenseFilterSheet: View {
    let participants: [LocalPerson]
    /// Trip capture currencies, excluding the display currency.
    let currencyOptions: [String]
    let displayCode: String
    @Binding var parties: Set<SplitPartyID>
    @Binding var currency: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Show spend for").eyebrow()
                        VStack(spacing: 0) {
                            partyRow(.me, name: "You", colorHex: nil)
                            ForEach(participants, id: \.clientUUID) { person in
                                Divider().background(Tokens.divider)
                                partyRow(.person(person.clientUUID), name: person.name, colorHex: person.colorHex)
                            }
                        }
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                        .paperBorder(Tokens.border, radius: Radius.md)
                    }

                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Currency").eyebrow()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.sm) {
                                currencyChip(nil, label: displayCode)
                                ForEach(currencyOptions, id: \.self) { code in
                                    currencyChip(code, label: code)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        Text("Converted with the rates frozen on this trip's expenses.")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.mutedSoft)
                    }
                }
                .padding(Space.lg)
            }
            .background(Tokens.paper)
            .navigationTitle("Filter")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Toggle a party in the multi-select. The selection can never go empty —
    /// removing the last member snaps back to You.
    private func toggle(_ rowParty: SplitPartyID) {
        if parties.contains(rowParty) {
            parties.remove(rowParty)
            if parties.isEmpty { parties = [.me] }
        } else {
            parties.insert(rowParty)
        }
    }

    private func partyRow(_ rowParty: SplitPartyID, name: String, colorHex: String?) -> some View {
        let selected = parties.contains(rowParty)
        return Button {
            toggle(rowParty)
        } label: {
            HStack(spacing: Space.sm) {
                Circle()
                    .fill(colorHex.map { Color(personHex: $0) } ?? Tokens.accentFinance)
                    .frame(width: 10, height: 10)
                Text(name)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(selected ? Tokens.accentFinance : Tokens.mutedSoft)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "\(name), selected" : name)
    }

    private func currencyChip(_ code: String?, label: String) -> some View {
        let selected = currency == code
        return Button {
            currency = code
        } label: {
            Text(label)
                .font(.edFootnote)
                .foregroundStyle(selected ? Tokens.accentFg : Tokens.ink)
                .padding(.horizontal, Space.md)
                .padding(.vertical, 6)
                .background(
                    selected ? Tokens.accentFinance : Tokens.surface2,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "\(label), selected" : label)
    }
}

// MARK: - Settlement math

/// Pure settle-up computation over a trip's expenses (#258).
///
/// Runs on a caller-supplied signed amount per expense — the frozen
/// home-currency `signedSGD` by default (correct for mixed-currency trips),
/// or `signedOriginal` when the whole trip shares one capture currency. For
/// each party the net position is `totalPaid - totalOwedShare`: positive means
/// the party is owed money by the group, negative means they owe. The group
/// nets to zero.
///
/// An UNSPLIT expense is owed entirely by the USER, matching
/// `LocalExpense.myShareSGD`. When the user also paid it the row nets to zero
/// and creates no balance, which is right for a personal cost logged against
/// the trip. When someone else fronted it, the user owes them the full amount
/// (#504).
enum TripSettlement {
    struct Balance: Identifiable {
        let party: SplitPartyID
        /// Signed net in the caller's amount basis. > 0 owed money, < 0 owes.
        let net: Double
        var id: SplitPartyID { party }
    }

    /// Below this magnitude (half a cent) a party counts as settled and is
    /// dropped from the list.
    private static let epsilon = 0.005

    /// Per-party (paid, owed) totals in the caller's amount basis. `paid` is
    /// what the party fronted; `owed` is their consumed share of the bills.
    /// The building block behind both the netted balances and the per-person
    /// summary card ("spent" = owed, "is owed" = paid - owed).
    static func totals(
        expenses: [LocalExpense],
        amount: (LocalExpense) -> Double = { $0.signedSGD }
    ) -> [SplitPartyID: (paid: Double, owed: Double)] {
        var totals: [SplitPartyID: (paid: Double, owed: Double)] = [:]

        for expense in expenses {
            let value = amount(expense)
            let payer: SplitPartyID = expense.paidByPersonUUID.map { .person($0) } ?? .me
            totals[payer, default: (0, 0)].paid += value

            let splits = expense.splits
            let totalShares = splits.reduce(0) { $0 + max($1.shares, 0) }
            guard !splits.isEmpty, totalShares > 0 else {
                // Unsplit (or degenerate): the cost is the USER's in full, which
                // is what `LocalExpense.myShareSGD` already assumes. It used to
                // credit the payer instead (#504). The two agreed only while an
                // unsplit row implied the user paid; now that another person can
                // front an unsplit bill, crediting the payer would net it to zero
                // and hide a real debt, while Finance still counted it as the
                // user's spend. An unsplit expense paid by someone else means the
                // user owes them the whole amount.
                totals[.me, default: (0, 0)].owed += value
                continue
            }
            for entry in splits {
                let shares = max(entry.shares, 0)
                guard shares > 0 else { continue }
                let party: SplitPartyID = entry.personID.map { .person($0) } ?? .me
                totals[party, default: (0, 0)].owed += value * Double(shares) / Double(totalShares)
            }
        }
        return totals
    }

    static func compute(
        expenses: [LocalExpense],
        amount: (LocalExpense) -> Double = { $0.signedSGD }
    ) -> [Balance] {
        let totals = totals(expenses: expenses, amount: amount)
        var balances: [Balance] = totals.map { party, entry in
            Balance(party: party, net: entry.paid - entry.owed)
        }
        balances.removeAll { abs($0.net) < epsilon }

        // User first, then people owed the most, then people who owe the most.
        balances.sort { lhs, rhs in
            if lhs.party == .me { return true }
            if rhs.party == .me { return false }
            return lhs.net > rhs.net
        }
        return balances
    }
}
