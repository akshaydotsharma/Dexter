import SwiftUI
import SwiftData

/// Modal sheet that lets the user wipe one or more on-device data
/// categories. Two steps inside the same sheet: select what to reset,
/// then type-to-confirm before the destructive action runs.
///
/// Itineraries cascade `LocalTrip` + `LocalItineraryItem`; Notes cascade
/// `LocalNote` + `LocalNoteFolder`. Other categories are flat.
struct ResetDataView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private enum Phase { case select, confirm }

    enum Category: String, CaseIterable, Identifiable {
        case itineraries
        case vocabulary
        case notes
        case lists
        case tasks

        var id: String { rawValue }

        var label: String {
            switch self {
            case .itineraries: return "Itineraries"
            case .vocabulary:  return "Vocabulary"
            case .notes:       return "Notes"
            case .lists:       return "Lists"
            case .tasks:       return "Tasks"
            }
        }

        var icon: String {
            switch self {
            case .itineraries: return "airplane"
            case .vocabulary:  return "character.book.closed"
            case .notes:       return "doc.text"
            case .lists:       return "list.bullet"
            case .tasks:       return "checkmark.square"
            }
        }

        /// Singular noun for the confirmation breakdown (used with item counts).
        var singular: String {
            switch self {
            case .itineraries: return "itinerary"
            case .vocabulary:  return "vocabulary word"
            case .notes:       return "note"
            case .lists:       return "list"
            case .tasks:       return "task"
            }
        }

        /// Plural form for the breakdown.
        var plural: String {
            switch self {
            case .itineraries: return "itineraries"
            case .vocabulary:  return "vocabulary words"
            case .notes:       return "notes"
            case .lists:       return "lists"
            case .tasks:       return "tasks"
            }
        }
    }

    @State private var phase: Phase = .select
    @State private var selected: Set<Category> = []
    @State private var counts: [Category: Int] = [:]
    @State private var confirmText: String = ""
    @State private var isResetting: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                Group {
                    switch phase {
                    case .select:  selectStep
                    case .confirm: confirmStep
                    }
                }
            }
            .navigationTitle("Reset data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase == .confirm {
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                phase = .select
                                confirmText = ""
                                errorMessage = nil
                            }
                        } label: {
                            HStack(spacing: Space.xxs) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                        }
                        .foregroundStyle(Tokens.muted)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                        .disabled(isResetting)
                }
            }
        }
        .onAppear(perform: recomputeCounts)
    }

    // MARK: - Select step

    private var selectStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("Choose which on-device data to permanently delete. This can't be undone.")
                    .font(.edBody)
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, Space.xs)

                ResetSection {
                    ResetRow(
                        icon: "trash",
                        label: "All data",
                        count: totalCount,
                        isOn: allSelectableSelected,
                        disabled: nonEmptySelectable.isEmpty,
                        emphasized: true
                    ) {
                        toggleAll()
                    }
                }

                ResetSection {
                    VStack(spacing: 0) {
                        ForEach(Array(Category.allCases.enumerated()), id: \.element.id) { index, cat in
                            ResetRow(
                                icon: cat.icon,
                                label: cat.label,
                                count: counts[cat] ?? 0,
                                isOn: selected.contains(cat),
                                disabled: (counts[cat] ?? 0) == 0,
                                emphasized: false
                            ) {
                                toggle(cat)
                            }
                            if index < Category.allCases.count - 1 {
                                Rectangle()
                                    .fill(Tokens.divider)
                                    .frame(height: 0.5)
                                    .padding(.leading, Space.lg)
                            }
                        }
                    }
                }

                resetSelectedButton

                Spacer(minLength: Space.xl)
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, 96)
        }
    }

    private var resetSelectedButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { phase = .confirm }
        } label: {
            Text("Reset selected")
                .font(.edBodyMedium)
                .foregroundStyle(selected.isEmpty ? Tokens.mutedSoft : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    selected.isEmpty ? Tokens.dangerSoft : Tokens.danger,
                    in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(selected.isEmpty)
        .padding(.top, Space.sm)
    }

    // MARK: - Confirm step

    private var confirmStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("This will permanently delete:")
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)

                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(selected.sorted(by: { $0.rawValue < $1.rawValue })) { cat in
                            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                                Text("•")
                                    .foregroundStyle(Tokens.muted)
                                Text(breakdownLine(for: cat))
                                    .font(.edBody)
                                    .foregroundStyle(Tokens.ink)
                            }
                        }
                    }

                    Text("This can't be undone.")
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.danger)
                        .padding(.top, Space.xs)
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
                .paperBorder()

                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Type")
                        .font(.edBody)
                        .foregroundStyle(Tokens.inkSoft)
                    + Text(" reset ")
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                    + Text("to confirm")
                        .font(.edBody)
                        .foregroundStyle(Tokens.inkSoft)

                    TextField("reset", text: $confirmText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                        .padding(Space.md)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .paperBorder(Tokens.border, radius: Radius.md)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.md)
                        .background(Tokens.dangerSoft, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }

                Button(action: performReset) {
                    HStack(spacing: Space.sm) {
                        if isResetting {
                            ProgressView().tint(.white)
                        }
                        Text(isResetting ? "Resetting…" : "Reset")
                            .font(.edBodyMedium)
                    }
                    .foregroundStyle(canConfirm ? Color.white : Tokens.mutedSoft)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        canConfirm ? Tokens.danger : Tokens.dangerSoft,
                        in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canConfirm || isResetting)

                Spacer(minLength: Space.xl)
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - State helpers

    /// Set of categories that currently have at least one item — the only
    /// ones the user can meaningfully toggle on.
    private var nonEmptySelectable: Set<Category> {
        Set(Category.allCases.filter { (counts[$0] ?? 0) > 0 })
    }

    /// True when every non-empty category is selected (drives the
    /// All Data master toggle's visual state).
    private var allSelectableSelected: Bool {
        let pool = nonEmptySelectable
        return !pool.isEmpty && pool.isSubset(of: selected)
    }

    private var totalCount: Int {
        Category.allCases.reduce(0) { $0 + (counts[$1] ?? 0) }
    }

    /// Confirm button enables when the user types `reset` (case-insensitive,
    /// trimmed of whitespace).
    private var canConfirm: Bool {
        confirmText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "reset"
    }

    private func breakdownLine(for cat: Category) -> String {
        let n = counts[cat] ?? 0
        let noun = n == 1 ? cat.singular : cat.plural
        return "\(n) \(noun)"
    }

    // MARK: - Actions

    private func toggle(_ category: Category) {
        guard (counts[category] ?? 0) > 0 else { return }
        if selected.contains(category) {
            selected.remove(category)
        } else {
            selected.insert(category)
        }
    }

    private func toggleAll() {
        let pool = nonEmptySelectable
        guard !pool.isEmpty else { return }
        if allSelectableSelected {
            selected.removeAll()
        } else {
            selected = pool
        }
    }

    private func recomputeCounts() {
        counts[.itineraries] = (try? modelContext.fetchCount(FetchDescriptor<LocalTrip>())) ?? 0
        counts[.vocabulary]  = (try? modelContext.fetchCount(FetchDescriptor<LocalKeyword>())) ?? 0
        counts[.notes]       = (try? modelContext.fetchCount(FetchDescriptor<LocalNote>())) ?? 0
        counts[.lists]       = (try? modelContext.fetchCount(FetchDescriptor<LocalList>())) ?? 0
        counts[.tasks]       = (try? modelContext.fetchCount(FetchDescriptor<LocalTodo>())) ?? 0
    }

    private func performReset() {
        guard canConfirm, !isResetting else { return }
        isResetting = true
        errorMessage = nil

        do {
            for cat in selected {
                switch cat {
                case .itineraries:
                    try modelContext.delete(model: LocalItineraryItem.self)
                    try modelContext.delete(model: LocalTrip.self)
                case .vocabulary:
                    try modelContext.delete(model: LocalKeyword.self)
                case .notes:
                    try modelContext.delete(model: LocalNote.self)
                    try modelContext.delete(model: LocalNoteFolder.self)
                case .lists:
                    try modelContext.delete(model: LocalList.self)
                case .tasks:
                    try modelContext.delete(model: LocalTodo.self)
                }
            }
            try modelContext.save()
            Haptics.destructive()
            dismiss()
        } catch {
            isResetting = false
            errorMessage = "Couldn't reset data: \(error.localizedDescription)"
        }
    }
}

// MARK: - Sub-views

/// Card wrapper that matches the SettingsSection look (surface fill +
/// paper border) but without the eyebrow title — the section header
/// would be redundant here since the sheet already has a navigation
/// title and an intro paragraph.
private struct ResetSection<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .paperBorder()
    }
}

private struct ResetRow: View {
    let icon: String
    let label: String
    let count: Int
    let isOn: Bool
    let disabled: Bool
    let emphasized: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(disabled ? Tokens.mutedSoft : (emphasized ? Tokens.danger : Tokens.muted))
                    .frame(width: 22)

                Text(label)
                    .font(emphasized ? .edBodyMedium : .edBody)
                    .foregroundStyle(disabled ? Tokens.mutedSoft : Tokens.ink)

                Spacer(minLength: Space.md)

                Text("\(count)")
                    .font(.edFootnote)
                    .monospacedDigit()
                    .foregroundStyle(disabled ? Tokens.mutedSoft : Tokens.muted)

                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isOn ? Tokens.danger : (disabled ? Tokens.border : Tokens.borderStrong),
                            lineWidth: 1
                        )
                        .frame(width: 22, height: 22)
                        .background(
                            isOn ? Tokens.danger : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
