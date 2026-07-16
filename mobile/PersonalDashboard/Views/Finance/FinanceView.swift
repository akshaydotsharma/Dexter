import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

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

    /// Which flow the PDF picker serves. SwiftUI honours only one
    /// `.fileImporter` per view — stacking a second silently breaks both — so
    /// the single-receipt and statement paths share one picker and dispatch
    /// on this purpose (#261).
    @State private var pdfPickPurpose: PDFPickPurpose = .receipt

    private enum PDFPickPurpose {
        case receipt
        case statement
    }

    /// Presents the recurring-expense management sheet (#236).
    @State private var showingRecurring: Bool = false

    /// In-flight capture / import jobs, rendered as non-blocking "Processing…"
    /// rows pinned above the expense list (#186). Modelled as an array (not a
    /// bool) so two uploads in a row show two rows and the list stays fully
    /// interactive while extraction / import runs in the background.
    @State private var processingJobs: [ProcessingJob] = []

    /// Summary shown after a statement import completes (#184), e.g.
    /// "Imported 42 · Skipped 8 duplicates · Ignored 5 payments/refunds".
    @State private var statementImportSummary: String?

    /// Surfaced to the user when extraction fails with no usable receipt
    /// to attach (e.g. file save failed). Successful saves with failed
    /// Vision fall through to AddExpenseSheet with a banner instead.
    @State private var captureErrorMessage: String?

    var body: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()

            VStack(spacing: 0) {
                // iOS in-view top bar; macOS uses the native window toolbar
                // via `.macSectionChrome` below (issue #283).
                #if os(iOS)
                TopBar(
                    title: "Finance",
                    onMenu: {
                        withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true }
                    }
                )
                #endif
                content
            }

            captureMenuButton
        }
        .activeSection(.finance)
        .macSectionChrome("Finance")
        .task {
            // Warm the chosen display currency's FX factor so month/day/
            // category totals render in it on first paint (#220). SGD is a
            // no-op passthrough; a failed fetch leaves the last cached factor.
            await FXService.default().refreshDisplayRate()
        }
        .sheet(item: $editingTarget) { target in
            AddExpenseSheet(target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingRecurring) {
            RecurringExpensesView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Camera capture is iOS-only: `.fullScreenCover` and
        // UIImagePickerController don't exist on macOS. The menu item that
        // presents this (below) is likewise gated, so `showingCamera` never
        // flips on macOS. Photo-library / PDF / statement / manual all stay.
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data in
                showingCamera = false
                handleCaptureData(data, source: .camera)
            }
            .ignoresSafeArea()
        }
        #endif
        .photoLibraryPicker(isPresented: $showingPhotoLibrary) { data in
            handleCaptureData(data, source: .photoLibrary)
        }
        .pdfPicker(isPresented: $showingPDFPicker) { data, fileName in
            switch pdfPickPurpose {
            case .receipt:   handleCaptureData(data, source: .pdf)
            case .statement: handleStatementData(data, fileName: fileName)
            }
        }
        .alert(
            // Source-agnostic: this summary now backs both statement imports
            // and multi-expense photo imports (#247).
            "Import complete",
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
            // confusingly redundant. Also entirely gated off on macOS, which
            // has no UIImagePickerController camera capture (issue #281).
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    startScan(.camera)
                } label: {
                    Label("Scan receipt", systemImage: "camera")
                }
            }
            #endif
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
                pdfPickPurpose = .statement
                showingPDFPicker = true
            } label: {
                Label("Import statement", systemImage: "doc.text.magnifyingglass")
            }
            Divider()
            Button {
                editingTarget = .new
            } label: {
                Label("Enter manually", systemImage: "pencil")
            }
            Button {
                showingRecurring = true
            } label: {
                Label("Recurring expenses", systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
        .padding(.trailing, 22)
        .padding(.bottom, BottomTabBarMetrics.fabBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityLabel("Add expense")
    }

    // MARK: - Capture lifecycle

    private func startScan(_ source: FinanceCaptureSource) {
        switch source {
        case .camera:        showingCamera = true
        case .photoLibrary:  showingPhotoLibrary = true
        case .pdf:
            pdfPickPurpose = .receipt
            showingPDFPicker = true
        }
    }

    /// Common entry point for all three pickers. `data == nil` is a user
    /// cancel; we just bail. Otherwise persist + extract.
    private func handleCaptureData(_ data: Data?, source: FinanceCaptureSource) {
        guard let data else { return }
        Task { await processCapturedAsset(data: data, captureSource: source) }
    }

    /// Save the asset to disk, show a non-blocking "Processing…" row, then run
    /// Vision in the background (#186). On success we AUTO-ADD the expense right
    /// away (mirroring what `AddExpenseSheet.save()` did for the `.prefilled`
    /// case) and open the sheet on that now-real row so the user confirms /
    /// tweaks an existing expense — never a second insert. On failure we fall
    /// back to the old behaviour: open the form with the receipt attached and
    /// an error banner. Receipt save errors bubble up to the alert; Vision
    /// errors don't — those are non-fatal because the user can fill in the form.
    private func processCapturedAsset(data: Data, captureSource: FinanceCaptureSource) async {
        let storage = ReceiptStorage.shared
        let client = AnthropicClient()

        // 1. Show the non-blocking "Processing" row IMMEDIATELY — before any
        //    compression, disk I/O, or the Vision call — so the user gets
        //    instant confirmation the capture was accepted (#200 follow-up).
        //    Previously the row only appeared after the synchronous HEIC→JPEG
        //    compress finished on the main actor, which read as a lag on
        //    multi-MB photos. Removed on every exit path.
        let job = ProcessingJob(kind: .receipt)
        withAnimation(.easeInOut(duration: 0.15)) {
            processingJobs.append(job)
        }
        defer {
            withAnimation(.easeInOut(duration: 0.15)) {
                processingJobs.removeAll { $0.id == job.id }
            }
        }

        // 2. Persist the file. For images we compress ONCE here and use the
        //    same JPEG bytes for both the disk save and the Vision call —
        //    otherwise the original raw camera data (HEIC, multi-MB)
        //    overflows Anthropic's 5 MB base64 limit and the API rejects it.
        //    Compression (decode + downsize + re-encode) is the expensive
        //    step, so it runs OFF the main actor via `Task.detached` — that
        //    keeps the row we just added rendering and the list responsive
        //    instead of freezing the main thread until the JPEG is ready.
        let relativePath: String
        let expenseSource: ExpenseSource
        let visionImageData: Data?  // nil for PDFs, otherwise the compressed JPEG
        do {
            switch captureSource {
            case .camera:
                let compressed = try await Task.detached(priority: .userInitiated) {
                    try storage.compress(imageData: data)
                }.value
                relativePath = try storage.saveCompressedJpeg(compressed)
                expenseSource = .receipt
                visionImageData = compressed
            case .photoLibrary:
                let compressed = try await Task.detached(priority: .userInitiated) {
                    try storage.compress(imageData: data)
                }.value
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

        // 3. Run Vision in the background; the processing row is already visible.
        do {
            switch captureSource {
            case .camera, .photoLibrary:
                // A photo can hold MULTIPLE expenses — several receipts in one
                // shot, or a printed/handwritten list of transactions for
                // different merchants (#247). Extract them ALL, then route on
                // count: 0 → failure fallback, 1 → today's single-receipt
                // behaviour, 2+ → batch auto-import (like a statement).
                let lines = try await client.extractExpenses(
                    imageData: visionImageData ?? data,
                    mediaType: "image/jpeg"
                )
                await handleExtractedPhotoLines(
                    lines,
                    receiptImagePath: relativePath,
                    source: expenseSource
                )
            case .pdf:
                // PDF stays on the single-expense path, unchanged.
                let extracted = try await client.extractExpense(pdfData: data)
                let prefill = PrefilledExpense.fromExtraction(
                    extracted,
                    receiptImagePath: relativePath,
                    source: expenseSource
                )
                await autoAddThenEdit(prefill: prefill)
            }
        } catch {
            // Save the receipt regardless; open the form with a banner. No row
            // was created, so `.prefilled` inserting on save is correct here.
            let message: String = {
                if let typed = error as? ReceiptExtractionError {
                    return typed.localizedDescription
                }
                if let typed = error as? StatementExtractionError {
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

    /// Route the expenses extracted from ONE photo (#247). Called only for the
    /// image path (camera / library); PDFs never reach here.
    ///   - 0 lines: extraction returned nothing usable. Receipt is already
    ///     saved, so fall back to the review sheet with a banner (same as a
    ///     thrown extraction error).
    ///   - 1 line: today's behaviour. Prefill from the single line and
    ///     auto-add + open the sheet to confirm — exactly one row inserted.
    ///   - 2+ lines: auto-import all of them through the SAME batch pipeline the
    ///     statement path uses (dedupe + FX + insert), sharing the one saved
    ///     receipt image across every row, and surface the count summary. No
    ///     per-row review sheet in this case.
    private func handleExtractedPhotoLines(
        _ lines: [ExtractedStatementLine],
        receiptImagePath: String,
        source: ExpenseSource
    ) async {
        switch lines.count {
        case 0:
            let prefill = PrefilledExpense.fromFailure(
                receiptImagePath: receiptImagePath,
                source: source,
                message: "We saved your photo but couldn't read any expenses. Fill in the details below."
            )
            editingTarget = .prefilled(prefill)
        case 1:
            let prefill = PrefilledExpense.from(
                line: lines[0],
                receiptImagePath: receiptImagePath,
                source: source
            )
            await autoAddThenEdit(prefill: prefill)
        default:
            // Reuse the statement batch importer. Empty meta + nil fileName so
            // nothing masquerades as a statement (no attribution label, no
            // payment method, no statement history entry). `possiblyTruncated`
            // is false — a photo is a single non-chunked request.
            let result = await StatementImporter.default().insert(
                lines: lines,
                fileName: nil,
                source: source,
                receiptImagePath: receiptImagePath,
                recordsImportHistory: false,
                possiblyTruncated: false
            )
            statementImportSummary = result.summaryLine
        }
    }

    /// Persist the extracted expense immediately, then open the edit sheet on
    /// the saved row (#186). This is the "auto-add then confirm" path: the row
    /// appears in the list the instant extraction succeeds, and the sheet edits
    /// that existing `LocalExpense` rather than inserting a second one.
    ///
    /// Insert logic mirrors `AddExpenseSheet.save()` for `.prefilled` (FX
    /// convert → `service.addExpense` → attach receipt path). If we can't build
    /// a valid row (no usable amount, or FX conversion fails), we fall back to
    /// the review sheet with the fields prefilled so `AddExpenseSheet` handles
    /// the insert on save — again, no double-insert.
    private func autoAddThenEdit(prefill: PrefilledExpense) async {
        guard let amount = prefill.amount, amount > 0 else {
            // Nothing solid to persist yet — let the user complete the form.
            editingTarget = .prefilled(prefill)
            return
        }

        let store = SwiftDataStore.shared
        let fx = FXService(store: store)
        let service = ExpenseService(store: store)
        let currency = (prefill.currency?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0.uppercased()
        } ?? "SGD"

        do {
            let conversion = try await fx.convert(amount, from: currency)
            let row = try service.addExpense(
                date: prefill.date ?? Date(),
                category: prefill.category ?? .other,
                merchant: prefill.merchant,
                expenseDescription: prefill.descriptionText,
                originalAmount: amount,
                originalCurrency: currency,
                sgdAmount: conversion.sgdAmount,
                fxRate: conversion.rate,
                paymentMethod: nil,
                source: prefill.source
            )
            row.receiptImagePath = prefill.receiptImagePath
            try modelContext.save()
            // Open the sheet on the now-real row so confirm/adjust edits it.
            editingTarget = .existing(row.clientUUID)
        } catch {
            // FX or persistence failed — hand off to the review sheet, which
            // retries the conversion on save. The row wasn't created.
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
    /// `fileName` (e.g. "Citi_May2026.pdf") labels the processing banner (#189).
    private func handleStatementData(_ data: Data?, fileName: String?) {
        guard let data else { return }
        Task { await importStatement(pdfData: data, fileName: fileName) }
    }

    /// Parse the statement PDF and batch-import every purchase/fee/interest
    /// line, deduping against existing expenses. No per-row review — survivors
    /// are inserted directly and the outcome is surfaced as a summary. Parse
    /// failures show the "couldn't process" alert; a successful parse with zero
    /// transactions still shows a (benign) summary explaining nothing matched.
    private func importStatement(pdfData: Data, fileName: String? = nil) async {
        // Non-blocking processing row while the batch import runs (#186); the
        // list stays interactive and multiple imports can queue up. When we
        // know the picked file name, label the row "Importing <name>…" so it's
        // clear which statement is being processed (#189).
        let bannerLabel = fileName
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            .map { "Importing \($0)…" }
        let job = ProcessingJob(kind: .statement, overrideLabel: bannerLabel)
        withAnimation(.easeInOut(duration: 0.15)) {
            processingJobs.append(job)
        }
        defer {
            withAnimation(.easeInOut(duration: 0.15)) {
                processingJobs.removeAll { $0.id == job.id }
            }
        }

        do {
            let result = try await StatementImporter.default().importStatement(pdfData: pdfData, fileName: fileName)
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
        if !allExpenses.contains(where: { !$0.hiddenFromFinance }) {
            emptyState
        } else {
            populatedContent
        }
    }

    private var populatedContent: some View {
        let filtered = filteredExpenses
        let stats = computeStats(range: dashboardRange, preset: filterState.datePreset, filter: resolvedFilter)
        return ScrollView {
            VStack(spacing: Space.lg) {
                FinanceDashboardBand(
                    stats: stats,
                    headerLabel: dashboardHeaderLabel,
                    deltaComparisonLabel: filterState.datePreset.deltaComparisonLabel
                )
                .padding(.horizontal, Space.lg)

                FinanceFilterBar(state: $filterState, dateConstrains: dateConstrains)

                // In-flight capture / import jobs (#186). Rendered as a status
                // banner between the filter chips and the search field — NOT
                // inside the expense list — so it reads as "something is
                // happening in the background", never as a transaction row.
                // Grouped under a "Processing" eyebrow header (#200) so it's
                // clear the rows are in-flight work; the whole block — header
                // included — disappears when nothing is in flight.
                if !processingJobs.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack {
                            Text("Processing")
                                .eyebrow()
                            Spacer()
                            if processingJobs.count > 1 {
                                Text("\(processingJobs.count)")
                                    .font(.edFootnote)
                                    .monospacedDigit()
                                    .foregroundStyle(Tokens.muted)
                            }
                        }
                        VStack(spacing: Space.xs) {
                            ForEach(processingJobs) { job in
                                FinanceProcessingRow(job: job)
                            }
                        }
                    }
                    .padding(.horizontal, Space.lg)
                }

                searchField
                    .padding(.horizontal, Space.lg)

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
                .noAutocapitalization()
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
                        Text(FinanceDashboardBand.formatMoney(group.total))
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
            // Net refunds into the day-group header total (#206), and count only
            // the user's share of any split trip expense (#258) so the per-day
            // header matches the my-share dashboard total.
            let total = dayRows.reduce(0) { $0 + $1.myShareSGD }
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
                filterState.people.removeAll()
                filterState.events.removeAll()
                filterState.importSources.removeAll()
                filterState.datePreset = .thisMonth
                // Return to the default This Month landing view (#245): drop the
                // explicit-date flag so the date goes back to being a soft view.
                filterState.dateExplicitlySet = false
                searchText = ""
            }
            .font(.edFootnote)
            .foregroundStyle(Tokens.accentFinance)
            .padding(.top, Space.xs)
        }
        .padding(.horizontal, Space.xl)
    }

    // MARK: - Filtering + stats

    /// The active filter (date preset + non-date dimensions + search), shared
    /// by both the list (`filteredExpenses`) and the dashboard band
    /// (`computeStats`) so the two stay in lockstep (#211).
    private var resolvedFilter: ExpenseFilter {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return filterState.resolvedFilter(searchText: trimmed.isEmpty ? nil : trimmed)
    }

    /// Whether the date range is actually constraining the list right now (#245),
    /// factoring in the free-text search that lives on the `.searchable` binding.
    /// Passed to `FinanceFilterBar` so the chip row de-highlights when the date
    /// has been soft-dropped in favour of another filter.
    private var dateConstrains: Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return filterState.dateConstrains(searchText: trimmed.isEmpty ? nil : trimmed)
    }

    private var filteredExpenses: [LocalExpense] {
        allExpenses.filter { matches($0, filter: resolvedFilter) }
    }

    /// In-view filter matcher. Mirrors `ExpenseService.matches` but inlined
    /// so we don't fetch through the service when SwiftData already gave
    /// us the array via `@Query`.
    private func matches(_ expense: LocalExpense, filter: ExpenseFilter) -> Bool {
        // Removed-from-Finance rows (#264) stay in the store to back their
        // trip's settle-up, but no Finance surface — list, dashboard band,
        // insights — may see them. Guard here so every aggregation site that
        // funnels through this matcher is covered at once.
        if expense.hiddenFromFinance { return false }
        if let range = filter.dateRange {
            if !range.contains(expense.date) { return false }
        }
        if let categories = filter.categories, !categories.isEmpty {
            if !categories.contains(expense.categoryEnum) { return false }
        }
        if let sources = filter.sources, !sources.isEmpty {
            if !sources.contains(expense.sourceEnum) { return false }
        }
        if let people = filter.people, !people.isEmpty {
            guard let personUUID = expense.personUUID, people.contains(personUUID) else { return false }
        }
        if let events = filter.events, !events.isEmpty {
            guard let eventUUID = expense.eventUUID, events.contains(eventUUID) else { return false }
        }
        // "Imported from" dimension (#245): OR within the selected buckets. Kept
        // identical to the mirrored copy in `ExpenseService.matches`.
        if let importSources = filter.importSources, !importSources.isEmpty {
            if !importSources.contains(where: { $0.matches(expense) }) { return false }
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

    /// Concrete window the dashboard totals + charts over (#187). Driven by the
    /// selected date-range preset so the band tracks the same period as the
    /// list. As of #211 the band also honours the non-date filters (person /
    /// event / category / source / search) — see `computeStats` — so it sums
    /// exactly the rows shown in the list, not the whole window.
    private var dashboardRange: ClosedRange<Date> {
        filterState.dashboardDateRange()
    }

    /// Header label for the band, reflecting the selected preset (#187).
    /// `.custom` folds in the concrete date span; the rest are fixed words.
    private var dashboardHeaderLabel: String {
        if filterState.datePreset == .custom {
            return filterState.customDashboardLabel()
        }
        return filterState.datePreset.dashboardLabel
    }

    /// Stats for the dashboard band (#187, #211). Applies the FULL active filter
    /// — person / event / category / source / search — on top of the date
    /// window, so the band sums exactly the rows shown in the list. The same
    /// non-date filters are applied to the preceding comparison window too, so
    /// the delta compares like-for-like. `filter.dateRange` is overridden
    /// per-window (`range` for the headline, `prevRange` for the delta); the
    /// caller's date range is ignored here in favour of those windows.
    private func computeStats(range: ClosedRange<Date>, preset: FinanceDateRangePreset, filter: ExpenseFilter) -> FinanceDashboardStats {
        let cal = Calendar.current

        // Non-date filters applied to both windows; the date range is swapped
        // in per-window below so each window keeps its own bounds.
        var rangeFilter = filter
        rangeFilter.dateRange = range
        let rangeRows = allExpenses.filter { matches($0, filter: rangeFilter) }
        // All dashboard-band figures net refunds (#206) AND count only the
        // user's share of split trip expenses (#258) — "my share counts": the
        // headline total, the delta comparison, the category bars, the average
        // per month, and the sparkline all sum `myShareSGD`.
        let rangeTotal = rangeRows.reduce(0) { $0 + $1.myShareSGD }

        // Average monthly spend: normalise the period total to a 30.44-day month,
        // using elapsed time (range start -> earlier of range end and now) so
        // ongoing periods like "This year" divide by months so far, not a full 12.
        let now = Date()
        let effectiveEnd = min(range.upperBound, now)
        let elapsedDays = max(1.0, effectiveEnd.timeIntervalSince(range.lowerBound) / 86_400.0)
        let monthsElapsed = max(1.0, elapsedDays / 30.437)   // avg Gregorian month length
        let averagePerMonth = rangeTotal / monthsElapsed

        // Preceding comparison window. Calendar-month presets compare against
        // the previous CALENDAR month (so month-length differences don't skew
        // the delta and "This month" keeps its exact prior behaviour); rolling
        // and custom windows compare against the prior span of EQUAL LENGTH,
        // ending just before the range start.
        let prevRange: ClosedRange<Date>
        switch preset {
        case .thisMonth, .lastMonth:
            let prevMonthRef = cal.date(byAdding: .month, value: -1, to: range.lowerBound) ?? range.lowerBound
            let bounds = ExpenseDateRanges.monthBounds(for: prevMonthRef)
            prevRange = bounds.0...bounds.1
        case .thisYear, .lastYear:
            // Compare against the previous CALENDAR year (mirrors the month
            // presets) so the delta isn't skewed by leap-year length (#211).
            let prevYearRef = cal.date(byAdding: .year, value: -1, to: range.lowerBound) ?? range.lowerBound
            let bounds = ExpenseDateRanges.yearBounds(for: prevYearRef)
            prevRange = bounds.0...bounds.1
        case .last30, .last90, .custom:
            let span = range.upperBound.timeIntervalSince(range.lowerBound)
            let prevEnd = range.lowerBound.addingTimeInterval(-1)
            let prevStart = prevEnd.addingTimeInterval(-span)
            prevRange = prevStart...prevEnd
        }
        var prevFilter = filter
        prevFilter.dateRange = prevRange
        let prevRows = allExpenses.filter { matches($0, filter: prevFilter) }
        let prevTotal = prevRows.reduce(0) { $0 + $1.myShareSGD }

        var byCategory: [ExpenseCategory: Double] = [:]
        for row in rangeRows {
            byCategory[row.categoryEnum, default: 0] += row.myShareSGD
        }
        let topCategories = byCategory
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { (category: $0.key, total: $0.value) }

        // Sparkline: one bucket per calendar day across the selected range,
        // inclusive of both ends. Days with no spend draw a flat segment.
        let sparkStart = cal.startOfDay(for: range.lowerBound)
        let sparkEndDay = cal.startOfDay(for: range.upperBound)
        let dayCount = (cal.dateComponents([.day], from: sparkStart, to: sparkEndDay).day ?? 0) + 1
        var dailyDict: [Date: Double] = [:]
        for row in rangeRows {
            let day = cal.startOfDay(for: row.date)
            dailyDict[day, default: 0] += row.myShareSGD
        }
        var dailyTotals: [(date: Date, total: Double)] = []
        for offset in 0..<max(dayCount, 1) {
            if let day = cal.date(byAdding: .day, value: offset, to: sparkStart) {
                dailyTotals.append((day, dailyDict[day] ?? 0))
            }
        }

        return FinanceDashboardStats(
            monthTotal: rangeTotal,
            previousMonthTotal: prevTotal,
            topCategories: topCategories,
            dailyTotals: dailyTotals,
            averagePerMonth: averagePerMonth
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
        // Match the amount the row leads with: the user's share for a group
        // split, the full amount otherwise (#264).
        let shown = expense.isGroupSplit ? abs(expense.myShareSGD) : expense.sgdAmount
        let amount = FinanceDashboardBand.formatMoney(shown)
        if expense.tripUUID != nil && !expense.hiddenFromTrip {
            return "\(label) · \(amount)\nRemoves it from your finances only — it stays on the trip."
        }
        return "\(label) · \(amount)"
    }

    private func delete(_ expense: LocalExpense) {
        // Per-surface delete (#264): a trip expense still visible on its trip
        // is only hidden from Finance — the shared row keeps backing the
        // trip's totals and settle-up, so the receipt file must survive too.
        if expense.tripUUID != nil && !expense.hiddenFromTrip {
            expense.hiddenFromFinance = true
            try? modelContext.save()
            return
        }
        // Receipt file is the expense's only off-row dependency, so its
        // lifecycle is tied to the row. Clean up first, then the row —
        // if the file delete fails (read-only volume, etc.) we still
        // proceed with the SwiftData delete; the orphaned file is a
        // bytes-wasted nuisance, not a correctness bug.
        //
        // A multi-expense photo import (#247) feeds ONE receipt image to N
        // rows, all sharing the same `receiptImagePath`. Only delete the file
        // once NO OTHER expense still references it — otherwise deleting one of
        // the sibling rows would orphan the receipt the others still show.
        if let path = expense.receiptImagePath {
            let stillReferenced = allExpenses.contains {
                $0.clientUUID != expense.clientUUID && $0.receiptImagePath == path
            }
            if !stillReferenced {
                try? ReceiptStorage.shared.delete(relativePath: path)
            }
        }
        modelContext.delete(expense)
        try? modelContext.save()
    }
}
