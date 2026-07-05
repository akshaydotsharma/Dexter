import SwiftUI
import SwiftData

/// Unified, reverse-chronological history of everything Dexter has parsed from
/// external documents (#234): credit-card / bank statement imports and
/// forwarded booking / receipt emails, in one place.
///
/// Two live sources are merged in memory and sorted newest-first:
///   • `LocalStatementImport` — one row per statement import (counts + file).
///   • `LocalEmailIngestLog`  — one row per forwarded email (outcome + summary).
///
/// A third, reconstructed source covers statements imported BEFORE #234 (which
/// left no `LocalStatementImport` record): existing `.pdf`-source expenses are
/// grouped by file name, shown with an expense count and flagged "counts
/// unavailable" so no numbers are fabricated. Files that already have a real
/// record are skipped so nothing is double-counted (mirrors how ActivityView
/// collapses `.pdf` expenses by `statementFileName`).
struct ParsedFilesView: View {
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \LocalStatementImport.createdAt, order: .reverse)
    private var statementImports: [LocalStatementImport]

    @Query(sort: \LocalEmailIngestLog.createdAt, order: .reverse)
    private var emailLogs: [LocalEmailIngestLog]

    // Needed to reconstruct pre-#234 statement imports from their expenses.
    @Query private var expenses: [LocalExpense]

    @State private var filter: Filter = .all
    @State private var searchText: String = ""
    @State private var presented: PresentedSheet?

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        intro
                        searchField
                        filterChips
                        listCard
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.lg)
                    .padding(.bottom, 64)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Parsed files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $presented) { sheet in
                switch sheet {
                case .statement(let record):
                    StatementDetailView(
                        title: record.fileName.isEmpty ? displayTitle(for: record) : record.fileName,
                        subtitle: statementSubtitle(for: record),
                        countsAvailable: true,
                        truncated: record.possiblyTruncated,
                        expenseUUIDs: record.importedExpenseUUIDStrings
                    )
                case .reconstructed(let recon):
                    StatementDetailView(
                        title: recon.title,
                        subtitle: recon.countsLine,
                        countsAvailable: false,
                        truncated: false,
                        expenseUUIDs: recon.expenseUUIDs
                    )
                case .email(let entry):
                    ParsedEmailDetailView(entry: entry)
                }
            }
        }
    }

    // MARK: - Sections

    private var intro: some View {
        Text("Everything Dexter has read from your statements and forwarded emails, newest first. Tap a row to see what it added.")
            .font(.edSubheadline)
            .foregroundStyle(Tokens.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchField: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.muted)
            TextField("Search file, subject, or sender", text: $searchText)
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

    private var filterChips: some View {
        HStack(spacing: Space.sm) {
            ForEach(Filter.allCases) { option in
                let isActive = option == filter
                Button {
                    guard option != filter else { return }
                    withAnimation(.easeOut(duration: 0.15)) { filter = option }
                } label: {
                    Text(option.label)
                        .font(.edSubheadline)
                        .foregroundStyle(isActive ? Tokens.accentActivity : Tokens.inkSoft)
                        .padding(.horizontal, Space.md)
                        .frame(minHeight: 36)
                        .background(
                            Capsule().fill(isActive ? Tokens.accentActivity.opacity(0.12) : Tokens.paper2)
                        )
                        .overlay(
                            Capsule().stroke(
                                isActive ? Tokens.accentActivity.opacity(0.35) : Tokens.border,
                                lineWidth: 0.5
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var listCard: some View {
        let rows = visibleRows
        if rows.isEmpty {
            Text(emptyMessage)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.lg)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                .paperBorder()
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { divider }
                    rowView(row)
                }
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .paperBorder()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Tokens.divider)
            .frame(height: 0.5)
            .padding(.leading, Space.lg)
    }

    // MARK: - Row views

    @ViewBuilder
    private func rowView(_ row: ParsedRow) -> some View {
        switch row {
        case .statement(let record):
            historyRow(
                icon: "doc.text.fill",
                tint: Tokens.accentFinance,
                title: record.fileName.isEmpty ? displayTitle(for: record) : record.fileName,
                subtitle: statementSubtitle(for: record),
                date: record.createdAt
            ) { presented = .statement(record) }
        case .reconstructed(let recon):
            historyRow(
                icon: "doc.text",
                tint: Tokens.mutedSoft,
                title: recon.title,
                subtitle: recon.countsLine,
                date: recon.createdAt
            ) { presented = .reconstructed(recon) }
        case .email(let entry):
            historyRow(
                icon: entry.outcomeEnum.icon,
                tint: color(for: entry.outcomeEnum),
                title: entry.subject.isEmpty ? "(no subject)" : entry.subject,
                subtitle: emailSubtitle(for: entry),
                date: entry.createdAt
            ) { presented = .email(entry) }
        }
    }

    private func historyRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        date: Date,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                    Text(date, format: .dateTime.month().day().year().hour().minute())
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                }
                Spacer(minLength: Space.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
                    .padding(.top, 2)
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Row model + merge

    private enum Filter: CaseIterable, Identifiable {
        case all, statements, emails
        var id: String {
            switch self {
            case .all: return "all"
            case .statements: return "statements"
            case .emails: return "emails"
            }
        }
        var label: String {
            switch self {
            case .all: return "All"
            case .statements: return "Statements"
            case .emails: return "Emails"
            }
        }
        func includes(_ row: ParsedRow) -> Bool {
            switch self {
            case .all: return true
            case .emails:
                if case .email = row { return true }
                return false
            case .statements:
                if case .email = row { return false }
                return true
            }
        }
    }

    private enum ParsedRow: Identifiable {
        case statement(LocalStatementImport)
        case reconstructed(ReconstructedStatement)
        case email(LocalEmailIngestLog)

        var id: String {
            switch self {
            case .statement(let s): return "stmt:\(s.clientUUID.uuidString)"
            case .reconstructed(let r): return r.id
            case .email(let e): return "mail:\(e.clientUUID.uuidString)"
            }
        }

        var sortDate: Date {
            switch self {
            case .statement(let s): return s.createdAt
            case .reconstructed(let r): return r.createdAt
            case .email(let e): return e.createdAt
            }
        }
    }

    private struct ReconstructedStatement: Identifiable {
        let id: String
        let title: String
        let expenseCount: Int
        let createdAt: Date
        let expenseUUIDs: [String]

        var countsLine: String {
            let n = expenseCount
            return "\(n) expense\(n == 1 ? "" : "s") · counts unavailable"
        }
    }

    private enum PresentedSheet: Identifiable {
        case statement(LocalStatementImport)
        case reconstructed(ReconstructedStatement)
        case email(LocalEmailIngestLog)

        var id: String {
            switch self {
            case .statement(let s): return "stmt:\(s.clientUUID.uuidString)"
            case .reconstructed(let r): return r.id
            case .email(let e): return "mail:\(e.clientUUID.uuidString)"
            }
        }
    }

    /// The merged, filtered, sorted rows shown in the list.
    private var visibleRows: [ParsedRow] {
        var rows: [ParsedRow] = statementImports.map { .statement($0) }
        rows.append(contentsOf: reconstructedStatements.map { .reconstructed($0) })
        rows.append(contentsOf: emailLogs.map { .email($0) })

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows
            .filter { filter.includes($0) }
            .filter { q.isEmpty || matches($0, q) }
            .sorted { $0.sortDate > $1.sortDate }
    }

    /// File names that already have a real `LocalStatementImport` record — their
    /// expenses must NOT be reconstructed, or the file would appear twice.
    private var recordedFileNames: Set<String> {
        Set(
            statementImports
                .map { $0.fileName.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// Group `.pdf`-source expenses that have no matching real record into
    /// reconstructed statement rows. Mirrors ActivityView's grouping: prefer the
    /// file name, then the parsed attribution label, then the import day.
    private var reconstructedStatements: [ReconstructedStatement] {
        let recorded = recordedFileNames
        var groups: [String: (title: String, rows: [LocalExpense])] = [:]

        for expense in expenses where expense.sourceEnum == .pdf {
            let fileName = expense.statementFileName.trimmingCharacters(in: .whitespacesAndNewlines)
            // A file already captured by a real record is fully represented by
            // that record — skip its rows so it isn't reconstructed too.
            if !fileName.isEmpty && recorded.contains(fileName) { continue }

            let label = expense.statementLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let key: String
            let title: String
            if !fileName.isEmpty {
                key = "file:\(fileName)"; title = fileName
            } else if !label.isEmpty {
                key = "label:\(label)"; title = label
            } else {
                let day = Calendar.current.startOfDay(for: expense.createdAt)
                key = "day:\(day.timeIntervalSince1970)"; title = "Statement import"
            }
            groups[key, default: (title, [])].rows.append(expense)
        }

        return groups.map { key, group in
            let maxCreated = group.rows.map(\.createdAt).max() ?? Date()
            return ReconstructedStatement(
                id: "recon:\(key)",
                title: group.title,
                expenseCount: group.rows.count,
                createdAt: maxCreated,
                expenseUUIDs: group.rows.map(\.clientUUID)
            )
        }
    }

    private func matches(_ row: ParsedRow, _ needle: String) -> Bool {
        switch row {
        case .statement(let s):
            return s.fileName.lowercased().contains(needle)
                || s.statementLabel.lowercased().contains(needle)
        case .reconstructed(let r):
            return r.title.lowercased().contains(needle)
        case .email(let e):
            return e.subject.lowercased().contains(needle)
                || e.sender.lowercased().contains(needle)
                || e.summary.lowercased().contains(needle)
        }
    }

    // MARK: - Copy helpers

    /// Compact count breakdown for a statement row, e.g.
    /// "12 imported (2 credits) · 8 skipped · 5 ignored". Zero buckets are
    /// omitted so a clean import reads simply. No em dashes.
    private func statementSubtitle(for record: LocalStatementImport) -> String {
        var parts: [String] = []
        if record.imported > 0 {
            var head = "\(record.imported) imported"
            if record.refunds > 0 {
                head += " (\(record.refunds) credit\(record.refunds == 1 ? "" : "s"))"
            }
            parts.append(head)
        }
        if record.skippedDuplicates > 0 { parts.append("\(record.skippedDuplicates) skipped") }
        if record.ignoredNonSpend > 0 { parts.append("\(record.ignoredNonSpend) ignored") }
        if record.deposits > 0 { parts.append("\(record.deposits) deposit\(record.deposits == 1 ? "" : "s") skipped") }
        if record.failed > 0 { parts.append("\(record.failed) failed") }
        var line = parts.isEmpty ? "No transactions imported" : parts.joined(separator: " · ")
        if record.possiblyTruncated {
            line += " · may be incomplete"
        }
        return line
    }

    private func displayTitle(for record: LocalStatementImport) -> String {
        let label = record.statementLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Statement import" : label
    }

    private func emailSubtitle(for entry: LocalEmailIngestLog) -> String {
        var pieces: [String] = [entry.outcomeEnum.displayName]
        let sender = entry.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sender.isEmpty { pieces.append(sender) }
        let summary = entry.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { pieces.append(summary) }
        return pieces.joined(separator: " · ")
    }

    private func color(for outcome: EmailIngestOutcome) -> Color {
        switch outcome {
        case .added:   return Tokens.success
        case .skipped: return Tokens.muted
        case .failed:  return Tokens.danger
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .all:
            return "Nothing parsed yet. Import a statement in Finance or forward a booking email to your receipts inbox to get started."
        case .statements:
            return "No statement imports yet. Import a statement PDF from the Finance screen."
        case .emails:
            return "No forwarded emails processed yet. Forward a hotel, flight, or receipt email to your inbox."
        }
    }
}

// MARK: - Statement detail

/// Shows the expenses a single statement import produced. For a real record we
/// resolve its stored expense UUIDs; for a reconstructed (pre-#234) import we
/// pass the grouped expense UUIDs. Either way the rows are resolved live so a
/// later deletion is reflected here.
private struct StatementDetailView: View {
    let title: String
    let subtitle: String
    let countsAvailable: Bool
    let truncated: Bool
    let expenseUUIDs: [String]

    @Environment(\.dismiss) private var dismiss
    @Query private var allExpenses: [LocalExpense]

    private var expenses: [LocalExpense] {
        let ids = Set(expenseUUIDs)
        return allExpenses
            .filter { ids.contains($0.clientUUID) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        header
                        if !countsAvailable {
                            unavailableNote
                        }
                        if truncated {
                            truncatedNote
                        }
                        expenseSection
                    }
                    .padding(Space.lg)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Statement import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
            Text(subtitle)
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
        }
    }

    private var unavailableNote: some View {
        Text("This statement was imported before Dexter kept per-import counts, so only its expenses are shown.")
            .font(.edCaption)
            .foregroundStyle(Tokens.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.md)
            .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    private var truncatedNote: some View {
        Text("Part of this statement was too long to read in one pass, so some transactions may be missing.")
            .font(.edCaption)
            .foregroundStyle(Tokens.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.md)
            .background(Tokens.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    @ViewBuilder
    private var expenseSection: some View {
        Text("Expenses").eyebrow()
        if expenses.isEmpty {
            Text("No expenses from this import are in your data. They may have been deleted.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: Space.sm) {
                ForEach(expenses, id: \.clientUUID) { expense in
                    ExpenseRow(expense: expense, onTap: {})
                }
            }
        }
    }
}

// MARK: - Email detail

/// Detail for a single email-ingest log entry: outcome, subject, sender,
/// summary, and (for an "added" entry) an Undo action that deletes the exact
/// items / expenses that ingest added, via `EmailIngestService.undo`. Mirrors
/// the diagnostics block the previous receipts-inbox screen showed, now with
/// undo surfaced in-app.
private struct ParsedEmailDetailView: View {
    let entry: LocalEmailIngestLog
    @Environment(\.dismiss) private var dismiss

    @State private var undone = false

    private var canUndo: Bool {
        entry.outcomeEnum == .added
            && (!entry.addedItemUUIDList.isEmpty || !entry.addedExpenseUUIDList.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        field("Outcome", entry.outcomeEnum.displayName)
                        field("Subject", entry.subject.isEmpty ? "(none)" : entry.subject)
                        if !entry.sender.isEmpty { field("From", entry.sender) }
                        field("Summary", entry.summary)
                        if canUndo && !undone {
                            undoButton
                        }
                        monospaceBlock("Parsed body the model received",
                                       entry.debugBody.isEmpty ? "(not recorded)" : entry.debugBody)
                        monospaceBlock("Trips the model could match against",
                                       entry.debugTripContext.isEmpty ? "(not recorded)" : entry.debugTripContext)
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle("Email detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var undoButton: some View {
        Button(role: .destructive) {
            _ = EmailIngestService().undo(logUUID: entry.clientUUID)
            undone = true
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "arrow.uturn.left.circle")
                    .font(.system(size: 15))
                Text("Undo this import")
                    .font(.edBody)
            }
            .foregroundStyle(Tokens.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).eyebrow()
            Text(value)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .textSelection(.enabled)
        }
    }

    private func monospaceBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).eyebrow()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Tokens.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.md)
                .background(Tokens.paper2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .textSelection(.enabled)
        }
    }
}
