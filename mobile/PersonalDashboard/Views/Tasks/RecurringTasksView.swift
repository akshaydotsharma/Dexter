import SwiftUI
import SwiftData

/// Management surface for recurring-task templates (#524). Presented as a sheet
/// from Tasks, mirroring the recurring-expense sheet Finance has had since #236.
///
/// One row per template, whatever it has generated. Editing or deleting a
/// template only changes what it makes NEXT: the tasks it already created are
/// ordinary tasks and stay exactly where they are, which may well be open in
/// front of the user.
struct RecurringTasksView: View {
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\RecurringTask.createdAt, order: .reverse)])
    private var templates: [RecurringTask]

    @State private var editorTarget: EditorTarget?
    @State private var pendingDelete: RecurringTask?

    private enum EditorTarget: Identifiable {
        case new
        case edit(RecurringTask)

        var id: String {
            switch self {
            case .new:              return "new"
            case .edit(let row):    return "edit:\(row.clientUUID)"
            }
        }
    }

    private var active: [RecurringTask] { templates.filter { $0.isActive } }
    private var paused: [RecurringTask] { templates.filter { !$0.isActive } }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("Recurring")
            .inlineNavigationTitle()
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
                    .foregroundStyle(Tokens.accentTasks)
                    .accessibilityLabel("Add recurring task")
                }
            }
        }
        // macOS only: a sheet with no explicit size collapses to its toolbar
        // (#474). On iPhone this minWidth is wider than the screen, so it has to
        // stay out of the iOS tree entirely.
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new:
                RecurringTaskEditorSheet(template: nil)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            case .edit(let template):
                RecurringTaskEditorSheet(template: template)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .alert("Stop repeating this task?", isPresented: deleteDialogBinding) {
            Button("Stop repeating", role: .destructive) {
                if let row = pendingDelete { delete(row) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "\($0.title). Tasks it already made are kept." } ?? "")
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

    private func section(title: String, rows: [RecurringTask]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).eyebrow()
            VStack(spacing: RowMetrics.interRowSpacing) {
                ForEach(rows, id: \.clientUUID) { template in
                    RecurringTaskRow(
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
            Image(systemName: "repeat")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("Nothing repeats yet")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
            Text("Set up a task that comes back, like taking the bins out or paying the rent, and Dexter adds it to your list as each date approaches.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
            Button {
                editorTarget = .new
            } label: {
                Text("Add a recurring task")
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.accentTasks)
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

    private func toggle(_ template: RecurringTask) {
        try? RecurringTaskService.default().setActive(template, !template.isActive)
        // Resuming may put a task in the list right now, if the next date is
        // already inside the lead window.
        if template.isActive {
            Task { await RecurringTaskCoordinator.shared.runPass() }
        }
    }

    private func delete(_ template: RecurringTask) {
        try? RecurringTaskService.default().delete(template)
    }
}

/// One template row. Tap to edit; the trailing button pauses and resumes.
private struct RecurringTaskRow: View {
    let template: RecurringTask
    let onTap: () -> Void
    let onToggleActive: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "repeat")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(template.isActive ? Tokens.accentTasks : Tokens.muted)
                .frame(width: 36, height: 36)
                .background(Tokens.paper2, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(template.title)
                    .font(.edBody)
                    .foregroundStyle(template.isActive ? Tokens.ink : Tokens.muted)
                    .lineLimit(1)
                Text(secondaryLine)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(2)
            }

            Spacer(minLength: Space.sm)

            Button(action: onToggleActive) {
                Image(systemName: template.isActive ? "pause.circle" : "play.circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(template.isActive ? Tokens.muted : Tokens.accentTasks)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(template.isActive ? "Pause" : "Resume")
        }
        .flatContentRow(iOSVerticalPadding: Space.sm + 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(template.title), \(secondaryLine). Tap to edit.")
    }

    /// The rule, then when the next one lands. A paused template says so instead
    /// of showing a next date it is not going to honour.
    private var secondaryLine: String {
        var pieces = [template.ruleSummary]
        if template.isActive {
            if let next = RecurringTaskService.default().nextDate(for: template) {
                pieces.append("next \(Self.dateFormatter.string(from: next))")
            } else {
                pieces.append("finished")
            }
        } else {
            pieces.append("paused")
        }
        return pieces.joined(separator: " · ")
    }

    /// "1 Jan 27". The year is always shown, not only when it differs from this
    /// one: a yearly rule's next date is routinely a year out, and this list puts
    /// templates of every cadence next to each other, so a row without a year
    /// reads as "soon" beside a row that means it.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yy"
        return formatter
    }()
}
