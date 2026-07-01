import SwiftUI
import SwiftData
import UIKit

/// Source channel for the "+" capture menu. Drives both the picker
/// presentation flags and the downstream `ExpenseSource` we tag the
/// resulting expense with.
enum FinanceCaptureSource {
    case camera
    case photoLibrary
    case pdf
}

/// Finance v1 surface (#114). Phase B adds receipt capture on top of the
/// Phase A list / dashboard:
///
/// - The "+" button is now a menu with Scan / Photo / PDF / Manual.
/// - Scan / Photo / PDF: capture the asset, save it under
///   `Documents/receipts/`, ask Claude to extract structured fields, then
///   open AddExpenseSheet with the values prefilled.
/// - Manual: opens the blank form as before.
/// - Receipt assets follow the expense lifecycle — deleting an expense
///   also deletes its receipt file.
struct FinanceView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var router: AppRouter

    @Query(
        sort: [
            SortDescriptor(\LocalExpense.date, order: .reverse),
            SortDescriptor(\LocalExpense.createdAt, order: .reverse)
        ]
    ) private var allExpenses: [LocalExpense]

    @State private var filterState = FinanceFilterState()
    @State private var searchText: String = ""

    /// Identifier for the AddExpense sheet. `.new` for the + button,
    /// `.existing(uuid)` for tap-to-edit on a row.
    @State private var editingTarget: ExpenseEditorTarget?

    /// Expense the user has swiped-to-delete and we're confirming.
    @State private var pendingDelete: LocalExpense?

    // MARK: - Capture flow state

    @State private var showingCamera: Bool = false
    @State private var showingPhotoLibrary: Bool = false
    @State private var showingPDFPicker: Bool = false

    /// Separate file-picker flag for the batch statement import (#184). Kept
    /// distinct from `showingPDFPicker` (the single-receipt path) so the two
    /// PDF flows don't share presentation state.
    @State private var showingStatementPicker: Bool = false

    /// On-screen overlay while Vision runs. The receipt file is already
    /// saved before this flips on, so cancelling here just opens the
    /// AddExpenseSheet with the receipt attached and no prefilled fields.
    @State private var extractionInProgress: Bool = false

    /// On-screen overlay while a statement is parsed + imported (#184).
    /// Distinct from `extractionInProgress` so the two overlays can show
    /// their own copy ("Reading receipt…" vs "Importing statement…").
    @State private var statementImportInProgress: Bool = false

    /// Summary shown after a statement import completes (#184), e.g.
    /// "Imported 42 · Skipped 8 duplicates · Ignored 5 payments/refunds".
    @State private var statementImportSummary: String?

    /// Surfaced to the user when extraction fails with no usable receipt
    /// to attach (e.g. file save failed). Successful saves with failed
    /// Vision fall through to AddExpenseSheet with a banner instead.
    @State private var captureErrorMessage: String?

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: "Finance",
                    onMenu: {
                        withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true }
                    }
                )
                content
            }

            captureMenuButton

            if extractionInProgress {
                extractionOverlay
            }

            if statementImportInProgress {
                statementImportOverlay
            }
        }
        .activeSection(.finance)
        .sheet(item: $editingTarget) { target in
            AddExpenseSheet(target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data in
                showingCamera = false
                handleCaptureData(data, source: .camera)
            }
            .ignoresSafeArea()
        }
        .photoLibraryPicker(isPresented: $showingPhotoLibrary) { data in
            handleCaptureData(data, source: .photoLibrary)
        }
        .pdfPicker(isPresented: $showingPDFPicker) { data in
            handleCaptureData(data, source: .pdf)
        }
        .pdfPicker(isPresented: $showingStatementPicker) { data in
            handleStatementData(data)
        }
        .alert(
            "Statement import",
            isPresented: statementSummaryBinding,
            presenting: statementImportSummary
        ) { _ in
            Button("OK", role: .cancel) { statementImportSummary = nil }
        } message: { summary in
            Text(summary)
        }
        .alert(
            "Couldn't process receipt",
            isPresented: captureErrorBinding,
            presenting: captureErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { captureErrorMessage = nil }
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            "Delete this expense?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete {
                    delete(row)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text(pendingDelete.map { confirmationMessage(for: $0) } ?? "")
        }
    }

    // MARK: - Capture menu + overlay

    private var captureMenuButton: some View {
        Menu {
            // .camera path is hidden in the simulator (and other no-camera
            // hardware) — the UIImagePickerController would silently fall
            // back to .photoLibrary, which makes the two top items
            // confusingly redundant.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    startScan(.camera)
                } label: {
                    Label("Scan receipt", systemImage: "camera")
                }
            }
            Button {
                startScan(.photoLibrary)
            } label: {
                Label("Photo from library", systemImage: "photo.on.rectangle")
            }
            Button {
                startScan(.pdf)
            } label: {
                Label("PDF from Files", systemImage: "doc.text")
            }
            Button {
                showingStatementPicker = true
            } label: {
                Label("Import statement", systemImage: "doc.text.magnifyingglass")
            }
            Divider()
            Button {
                editingTarget = .new
            } label: {
                Label("Enter manually", systemImage: "pencil")
            }
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
        .padding(.trailing, 22)
        .padding(.bottom, BottomTabBarMetrics.height + Space.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityLabel("Add expense")
    }

    private var extractionOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: Space.md) {
                ProgressView()
                    .tint(Tokens.ink)
                Text("Reading receipt…")
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
        .transition(.opacity)
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reading receipt")
    }

    /// Overlay shown while a statement is parsed + imported (#184). Same shape
    /// as `extractionOverlay` but with copy that reflects the batch operation,
    /// which can take a while for a full statement.
    private var statementImportOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: Space.md) {
                ProgressView()
                    .tint(Tokens.ink)
                Text("Importing statement…")
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                Text("Reading transactions and skipping duplicates")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.lg)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
        .transition(.opacity)
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing statement")
    }

    // MARK: - Capture lifecycle

    private func startScan(_ source: FinanceCaptureSource) {
        switch source {
        case .camera:        showingCamera = true
        case .photoLibrary:  showingPhotoLibrary = true
        case .pdf:           showingPDFPicker = true
        }
    }

    /// Common entry point for all three pickers. `data == nil` is a user
    /// cancel; we just bail. Otherwise persist + extract.
    private func handleCaptureData(_ data: Data?, source: FinanceCaptureSource) {
        guard let data else { return }
        Task { await processCapturedAsset(data: data, captureSource: source) }
    }

    /// Save the asset to disk, kick off Vision, then open AddExpenseSheet
    /// with either prefilled fields (success) or just the receipt attached
    /// (failure). Receipt save errors bubble up to the alert; Vision errors
    /// don't — those are non-fatal because the user can fill in the form.
    private func processCapturedAsset(data: Data, captureSource: FinanceCaptureSource) async {
        let storage = ReceiptStorage.shared
        let client = AnthropicClient()

        // 1. Persist the file. For images we compress ONCE here and use the
        //    same JPEG bytes for both the disk save and the Vision call —
        //    otherwise the original raw camera data (HEIC, multi-MB)
        //    overflows Anthropic's 5 MB base64 limit and the API rejects it.
        let relativePath: String
        let expenseSource: ExpenseSource
        let visionImageData: Data?  // nil for PDFs, otherwise the compressed JPEG
        do {
            switch captureSource {
            case .camera:
                let compressed = try storage.compress(imageData: data)
                relativePath = try storage.saveCompressedJpeg(compressed)
                expenseSource = .receipt
                visionImageData = compressed
            case .photoLibrary:
                let compressed = try storage.compress(imageData: data)
                relativePath = try storage.saveCompressedJpeg(compressed)
                expenseSource = .photo
                visionImageData = compressed
            case .pdf:
                relativePath = try storage.save(pdfData: data)
                expenseSource = .pdf
                visionImageData = nil
            }
        } catch {
            captureErrorMessage = error.localizedDescription
            return
        }

        // 2. Show progress, run Vision.
        withAnimation(.easeInOut(duration: 0.15)) {
            extractionInProgress = true
        }
        defer {
            withAnimation(.easeInOut(duration: 0.15)) {
                extractionInProgress = false
            }
        }

        do {
            let extracted: ExtractedExpense
            switch captureSource {
            case .camera, .photoLibrary:
                extracted = try await client.extractExpense(
                    imageData: visionImageData ?? data,
                    mediaType: "image/jpeg"
                )
            case .pdf:
                extracted = try await client.extractExpense(pdfData: data)
            }
            let prefill = PrefilledExpense.fromExtraction(
                extracted,
                receiptImagePath: relativePath,
                source: expenseSource
            )
            editingTarget = .prefilled(prefill)
        } catch {
            // Save the receipt regardless; open the form with a banner.
            let message: String = {
                if let typed = error as? ReceiptExtractionError {
                    return typed.localizedDescription
                }
                return "We saved your receipt but couldn't read it. Fill in the details below."
            }()
            let prefill = PrefilledExpense.fromFailure(
                receiptImagePath: relativePath,
                source: expenseSource,
                message: message
            )
            editingTarget = .prefilled(prefill)
        }
    }

    private var captureErrorBinding: Binding<Bool> {
        Binding(
            get: { captureErrorMessage != nil },
            set: { newValue in if !newValue { captureErrorMessage = nil } }
        )
    }

    // MARK: - Statement import (#184)

    /// Entry point for the statement file picker. `data == nil` is a cancel.
    private func handleStatementData(_ data: Data?) {
        guard let data else { return }
        Task { await importStatement(pdfData: data) }
    }

    /// Parse the statement PDF and batch-import every purchase/fee/interest
    /// line, deduping against existing expenses. No per-row review — survivors
    /// are inserted directly and the outcome is surfaced as a summary. Parse
    /// failures show the "couldn't process" alert; a successful parse with zero
    /// transactions still shows a (benign) summary explaining nothing matched.
    private func importStatement(pdfData: Data) async {
        withAnimation(.easeInOut(duration: 0.15)) {
            statementImportInProgress = true
        }
        defer {
            withAnimation(.easeInOut(duration: 0.15)) {
                statementImportInProgress = false
            }
        }

        do {
            let result = try await StatementImporter.default().importStatement(pdfData: pdfData)
            statementImportSummary = result.summaryLine
        } catch {
            let message: String = {
                if let typed = error as? StatementExtractionError {
                    return typed.localizedDescription
                }
                return "We couldn't read this statement. Make sure it's a text-based PDF (not a photo) and try again."
            }()
            captureErrorMessage = message
        }
    }

    private var statementSummaryBinding: Binding<Bool> {
        Binding(
            get: { statementImportSummary != nil },
            set: { newValue in if !newValue { statementImportSummary = nil } }
        )
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        if allExpenses.isEmpty {
            emptyState
        } else {
            populatedContent
        }
    }

    private var populatedContent: some View {
        let filtered = filteredExpenses
        let stats = computeStats()
        return ScrollView {
            VStack(spacing: Space.lg) {
                FinanceDashboardBand(stats: stats)
                    .padding(.horizontal, Space.lg)

                searchField
                    .padding(.horizontal, Space.lg)

                FinanceFilterBar(state: $filterState)

                if filtered.isEmpty {
                    noResultsState
                        .padding(.top, Space.xl)
                } else {
                    expenseList(filtered: filtered)
                        .padding(.horizontal, Space.lg)
                }

                Color.clear.frame(height: 96)
            }
            .padding(.vertical, Space.lg)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Inline search input. Project convention is to avoid `.searchable`
    /// (which needs a `NavigationStack` wrapper) and instead drop a paper
    /// search field into the scroll view — see TasksView / NotesView for
    /// the same pattern.
    private var searchField: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.muted)
            TextField("Search merchant or description", text: $searchText)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Tokens.mutedSoft)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    // MARK: - Expense list grouped by day

    private func expenseList(filtered: [LocalExpense]) -> some View {
        let groups = groupedByDay(filtered)
        return VStack(spacing: Space.lg) {
            ForEach(groups, id: \.day) { group in
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack {
                        Text(dayHeader(for: group.day))
                            .eyebrow()
                        Spacer()
                        Text(FinanceDashboardBand.formatSGD(group.total))
                            .font(.edFootnote)
                            .monospacedDigit()
                            .foregroundStyle(Tokens.muted)
                    }
                    VStack(spacing: Space.xs) {
                        ForEach(group.rows) { row in
                            ExpenseRow(expense: row) {
                                editingTarget = .existing(row.clientUUID)
                            }
                            .swipeToDeleteTrash {
                                pendingDelete = row
                            }
                        }
                    }
                }
            }
        }
    }

    private struct DailyGroup {
        let day: Date
        let total: Double
        let rows: [LocalExpense]
    }

    private func groupedByDay(_ rows: [LocalExpense]) -> [DailyGroup] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: rows) { cal.startOfDay(for: $0.date) }
        return dict.keys.sorted(by: >).map { day in
            let dayRows = dict[day] ?? []
            let total = dayRows.reduce(0) { $0 + $1.sgdAmount }
            return DailyGroup(day: day, total: total, rows: dayRows)
        }
    }

    private func dayHeader(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }

        let formatter = DateFormatter()
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: Date())
        formatter.dateFormat = sameYear ? "EEE d MMM" : "EEE d MMM yyyy"
        return formatter.string(from: day)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("No expenses yet")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
            Text("Tap the + button to log your first expense, or say \"I spent $20 on lunch\" in chat.")
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

    private var noResultsState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("No expenses match these filters")
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
            Button("Reset filters") {
                filterState.categories.removeAll()
                filterState.sources.removeAll()
                filterState.datePreset = .thisMonth
                searchText = ""
            }
            .font(.edFootnote)
            .foregroundStyle(Tokens.accentFinance)
            .padding(.top, Space.xs)
        }
        .padding(.horizontal, Space.xl)
    }

    // MARK: - Filtering + stats

    private var filteredExpenses: [LocalExpense] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = filterState.resolvedFilter(searchText: trimmed.isEmpty ? nil : trimmed)
        return allExpenses.filter { matches($0, filter: filter) }
    }

    /// In-view filter matcher. Mirrors `ExpenseService.matches` but inlined
    /// so we don't fetch through the service when SwiftData already gave
    /// us the array via `@Query`.
    private func matches(_ expense: LocalExpense, filter: ExpenseFilter) -> Bool {
        if let range = filter.dateRange {
            if !range.contains(expense.date) { return false }
        }
        if let categories = filter.categories, !categories.isEmpty {
            if !categories.contains(expense.categoryEnum) { return false }
        }
        if let sources = filter.sources, !sources.isEmpty {
            if !sources.contains(expense.sourceEnum) { return false }
        }
        if let search = filter.searchText?.lowercased(), !search.isEmpty {
            let merchant = expense.merchant?.lowercased() ?? ""
            let description = expense.expenseDescription?.lowercased() ?? ""
            if !merchant.contains(search) && !description.contains(search) {
                return false
            }
        }
        return true
    }

    /// Stats for the dashboard band. Always uses the FULL expense set
    /// (not the filtered list) so the band always reflects "your real
    /// finances" — filters only narrow the list below.
    private func computeStats() -> FinanceDashboardStats {
        let cal = Calendar.current
        let now = Date()
        let (monthStart, monthEnd) = ExpenseDateRanges.monthBounds(for: now)
        let prev = cal.date(byAdding: .month, value: -1, to: now) ?? now
        let (prevStart, prevEnd) = ExpenseDateRanges.monthBounds(for: prev)

        let monthRows = allExpenses.filter { $0.date >= monthStart && $0.date <= monthEnd }
        let prevRows = allExpenses.filter { $0.date >= prevStart && $0.date <= prevEnd }

        let monthTotal = monthRows.reduce(0) { $0 + $1.sgdAmount }
        let prevTotal = prevRows.reduce(0) { $0 + $1.sgdAmount }

        var byCategory: [ExpenseCategory: Double] = [:]
        for row in monthRows {
            byCategory[row.categoryEnum, default: 0] += row.sgdAmount
        }
        let topCategories = byCategory
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { (category: $0.key, total: $0.value) }

        // Daily totals for last 30 days inclusive.
        let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))?
            .addingTimeInterval(-1) ?? now
        let startSpark = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now)) ?? now
        let recent30 = allExpenses.filter { $0.date >= startSpark && $0.date <= endOfToday }
        var dailyDict: [Date: Double] = [:]
        for row in recent30 {
            let day = cal.startOfDay(for: row.date)
            dailyDict[day, default: 0] += row.sgdAmount
        }
        var dailyTotals: [(date: Date, total: Double)] = []
        for offset in 0..<30 {
            if let day = cal.date(byAdding: .day, value: offset, to: startSpark) {
                dailyTotals.append((day, dailyDict[day] ?? 0))
            }
        }

        return FinanceDashboardStats(
            monthTotal: monthTotal,
            previousMonthTotal: prevTotal,
            topCategories: topCategories,
            dailyTotals: dailyTotals
        )
    }

    // MARK: - Delete confirmation

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { newValue in if !newValue { pendingDelete = nil } }
        )
    }

    private func confirmationMessage(for expense: LocalExpense) -> String {
        let label = expense.merchant?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? expense.expenseDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? expense.categoryEnum.displayName
        let amount = FinanceDashboardBand.formatSGD(expense.sgdAmount)
        return "\(label) · \(amount)"
    }

    private func delete(_ expense: LocalExpense) {
        // Receipt file is the expense's only off-row dependency, so its
        // lifecycle is tied to the row. Clean up first, then the row —
        // if the file delete fails (read-only volume, etc.) we still
        // proceed with the SwiftData delete; the orphaned file is a
        // bytes-wasted nuisance, not a correctness bug.
        if let path = expense.receiptImagePath {
            try? ReceiptStorage.shared.delete(relativePath: path)
        }
        modelContext.delete(expense)
        try? modelContext.save()
    }
}
