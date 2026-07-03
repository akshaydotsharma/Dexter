import SwiftUI
import SwiftData

/// Management surface for recurring-expense templates (#236). Presented as a
/// sheet from Finance. Lists active and paused templates with add / edit /
/// pause / delete. Matches the Finance visual language (paper surfaces, finance
/// accent, rounded rows). Deleting or editing a template only affects FUTURE
/// postings — already-posted expenses stay in the ledger untouched.
struct RecurringExpensesView: View {
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\RecurringExpense.createdAt, order: .reverse)])
    private var templates: [RecurringExpense]

    /// nil = editor closed; `.some(nil)` = new template; `.some(template)` = edit.
    @State private var editorTarget: EditorTarget?
    @State private var pendingDelete: RecurringExpense?

    private enum EditorTarget: Identifiable {
        case new
        case edit(RecurringExpense)

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let t): return "edit:\(t.clientUUID)"
            }
        }
    }

    private var active: [RecurringExpense] { templates.filter { $0.isActive } }
    private var paused: [RecurringExpense] { templates.filter { !$0.isActive } }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("Recurring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        editorTarget = .new
                    } label: {
                        Image(systemName: "plus")
                    }
                    .foregroundStyle(Tokens.accentFinance)
                    .accessibilityLabel("Add recurring expense")
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new:
                RecurringExpenseEditorSheet(template: nil)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            case .edit(let template):
                RecurringExpenseEditorSheet(template: template)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            "Delete this recurring expense?",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete { delete(row) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "\(label(for: $0)). Already-posted expenses are kept." } ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if templates.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if !active.isEmpty {
                        section(title: "Active", rows: active)
                    }
                    if !paused.isEmpty {
                        section(title: "Paused", rows: paused)
                    }
                    Color.clear.frame(height: Space.xl)
                }
                .padding(Space.lg)
            }
        }
    }

    private func section(title: String, rows: [RecurringExpense]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).eyebrow()
            VStack(spacing: Space.xs) {
                ForEach(rows, id: \.clientUUID) { template in
                    RecurringExpenseRow(
                        template: template,
                        onTap: { editorTarget = .edit(template) },
                        onToggleActive: { toggle(template) }
                    )
                    .swipeToDeleteTrash {
                        pendingDelete = template
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("No recurring expenses")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
            Text("Set up a fixed monthly charge like rent or a subscription, and Dexter posts it automatically each month.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
            Button {
                editorTarget = .new
            } label: {
                Text("Add recurring expense")
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.accentFinance)
            }
            .padding(.top, Space.xs)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.lg)
    }

    // MARK: - Actions

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func toggle(_ template: RecurringExpense) {
        try? RecurringExpenseService.default().setActive(template, !template.isActive)
        // Resuming a template may make it due right now; post if so (no banner —
        // the user just tapped it).
        if template.isActive {
            Task { _ = await RecurringExpenseService.default().materialize(notify: false) }
        }
    }

    private func delete(_ template: RecurringExpense) {
        try? RecurringExpenseService.default().delete(template)
    }

    private func label(for template: RecurringExpense) -> String {
        template.merchant?.trimmedNonEmpty
            ?? template.expenseDescription?.trimmedNonEmpty
            ?? template.categoryEnum.displayName
    }
}

/// One recurring-template row. Tap to edit; the trailing button pauses/resumes.
private struct RecurringExpenseRow: View {
    let template: RecurringExpense
    let onTap: () -> Void
    let onToggleActive: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: template.categoryEnum.sfSymbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(template.isActive ? Tokens.accentFinance : Tokens.muted)
                .frame(width: 36, height: 36)
                .background(Tokens.paper2, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryLine)
                    .font(.edBody)
                    .foregroundStyle(template.isActive ? Tokens.ink : Tokens.muted)
                    .lineLimit(1)
                Text(secondaryLine)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(amountLabel)
                    .font(.edBodyMedium)
                    .monospacedDigit()
                    .foregroundStyle(template.isActive ? Tokens.ink : Tokens.muted)
                Button(action: onToggleActive) {
                    Image(systemName: template.isActive ? "pause.circle" : "play.circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(template.isActive ? Tokens.muted : Tokens.accentFinance)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(template.isActive ? "Pause" : "Resume")
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm + 2)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .paperBorder(Tokens.border, radius: 26)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var primaryLine: String {
        template.merchant?.trimmedNonEmpty
            ?? template.expenseDescription?.trimmedNonEmpty
            ?? template.categoryEnum.displayName
    }

    private var secondaryLine: String {
        var pieces = ["\(template.categoryEnum.displayName) · on the \(ordinal(template.dayOfMonth))"]
        if let end = template.endDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "d MMM yyyy"
            pieces.append("until \(fmt.string(from: end))")
        }
        if !template.isActive {
            pieces.append("paused")
        }
        return pieces.joined(separator: " · ")
    }

    private var amountLabel: String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        let amount = formatter.string(from: NSNumber(value: template.amount)) ?? String(format: "%.2f", template.amount)
        return "\(template.currency.uppercased()) \(amount)/mo"
    }

    private var accessibilityLabel: String {
        "\(primaryLine), \(amountLabel), \(secondaryLine). Tap to edit."
    }

    private func ordinal(_ n: Int) -> String {
        RecurringExpenseEditorSheet.ordinal(n)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
