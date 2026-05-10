import SwiftUI
import SwiftData

/// Top-level surface where the user teaches the assistant their personal
/// vocabulary — company names, products, jargon — so the LLM prefers those
/// terms when speech-to-text gets them wrong.
///
/// Lives in the side drawer (issue #100 follow-up). Mirrors the shell shape
/// of `TodayView` / `HelpCenterView`: shared `TopBar` with a hamburger that
/// opens the drawer, no leading-edge back handler (the drawer is the way
/// out of this surface).
///
/// Data lives in `LocalKeyword` (SwiftData). The list reads via FetchDescriptor
/// keyed on `term` ascending. Add / edit go through a single sheet
/// (`KeywordEditorSheet`); deletes use the canonical swipe-trash interaction.
struct PersonalVocabularyView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var router: AppRouter

    /// Surface state. `editing` drives the sheet: `.new` for a fresh entry,
    /// `.existing(_)` for editing a row. The sheet binding is the
    /// `Identifiable` wrapper, so SwiftUI re-renders the editor each time
    /// the user taps a different row.
    @State private var editing: EditorTarget?

    /// Live keyword list, sorted by term ascending. Decoupled from the
    /// SwiftData fetch via `@Query` so updates from the editor sheet (insert,
    /// edit, delete) reflect without manual reloads.
    @Query(sort: \LocalKeyword.term, order: .forward) private var keywords: [LocalKeyword]

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    title: "Personal vocabulary",
                    onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
                )
                content
            }

            // Floating "+" button mirrors the affordance used on Lists / Notes.
            Button {
                editing = .new
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
            .padding(.trailing, 22)
            .padding(.bottom, BottomTabBarMetrics.height + Space.sm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .accessibilityLabel("Add term")
        }
        .activeSection(.vocabulary)
        .sheet(item: $editing) { target in
            KeywordEditorSheet(target: target)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if keywords.isEmpty {
            emptyState
        } else {
            keywordList
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "character.book.closed")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("Teach the assistant your words")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
            Text("Company names, products, jargon — anything it might mishear. The assistant will prefer these when interpreting what you say.")
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

    private var keywordList: some View {
        // `List` (not `ScrollView { LazyVStack }`) so each row participates in
        // the canonical swipe-to-delete-trash interaction. Paper aesthetic
        // preserved with hidden separators and clear row backgrounds.
        List {
            ForEach(keywords) { keyword in
                KeywordRow(keyword: keyword) {
                    editing = .existing(keyword.clientUUID)
                }
                .swipeToDeleteTrash {
                    delete(keyword)
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

    // MARK: - Actions

    private func delete(_ keyword: LocalKeyword) {
        modelContext.delete(keyword)
        try? modelContext.save()
    }
}

// MARK: - Editor target

/// Identifiable wrapper used as the `.sheet(item:)` payload. Carrying the
/// UUID (not the model instance) keeps the sheet stateless across re-renders.
enum EditorTarget: Identifiable {
    case new
    case existing(UUID)

    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let uuid): return uuid.uuidString
        }
    }
}

// MARK: - Row

private struct KeywordRow: View {
    let keyword: LocalKeyword
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(keyword.term)
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)

                let trimmed = keyword.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    Text(trimmed)
                        .font(.edSubheadline)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(keyword.term). Tap to edit.")
    }
}

// MARK: - Editor sheet

/// Single sheet for both add and edit. Avoids the dual-flow complexity that
/// NavigationLink-based detail screens carry, and matches the pattern used by
/// `NewListSheet` / `NewFolderSheet` elsewhere in the app.
private struct KeywordEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let target: EditorTarget

    @State private var term: String = ""
    @State private var notes: String = ""
    @State private var loaded: Bool = false
    @FocusState private var termFocused: Bool

    /// Visual cap. The model itself doesn't truncate — we just stop the text
    /// field from accepting more characters. The LLM will trim long inputs
    /// anyway; this is purely so a typo-loop can't blow up the prompt.
    private let termMaxLength = 64
    private let notesMaxLength = 280

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        termField
                        notesField
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle(isEditing ? "Edit term" : "New term")
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
                    .disabled(trimmedTerm.isEmpty)
                    .foregroundStyle(trimmedTerm.isEmpty ? Tokens.muted : Tokens.ink)
                }
            }
        }
        .onAppear { loadIfNeeded() }
    }

    // MARK: - Fields

    private var termField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Term").eyebrow()

            TextField("e.g. Envisso", text: $term)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
                .submitLabel(.done)
                .focused($termFocused)
                .onChange(of: term) { _, newValue in
                    if newValue.count > termMaxLength {
                        term = String(newValue.prefix(termMaxLength))
                    }
                }
                .accessibilityLabel("Term")
        }
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

            // Multi-line. Min height ≈ 3 lines so the affordance reads as
            // "more than a single field" and the user knows they can elaborate.
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("What it means, when to prefer it…")
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

    private var trimmedTerm: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        if case let .existing(uuid) = target {
            // Hydrate from the store. If the row was deleted between tap and
            // sheet appearance, the editor stays empty and behaves like new —
            // saving will be blocked because the term field is empty.
            let descriptor = FetchDescriptor<LocalKeyword>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                term = existing.term
                notes = existing.notes
            }
        } else {
            // New entry: focus the term field once the sheet has settled so
            // the keyboard rises without fighting the sheet's own animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                termFocused = true
            }
        }
    }

    private func save() {
        let cleanTerm = trimmedTerm
        guard !cleanTerm.isEmpty else { return }
        let cleanNotes = trimmedNotes

        switch target {
        case .new:
            let keyword = LocalKeyword(term: cleanTerm, notes: cleanNotes)
            modelContext.insert(keyword)
        case .existing(let uuid):
            let descriptor = FetchDescriptor<LocalKeyword>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.term = cleanTerm
                existing.notes = cleanNotes
                existing.updatedAt = Date()
            } else {
                // Fell out from under us (rare). Insert as new so the user's
                // edit isn't lost.
                let keyword = LocalKeyword(term: cleanTerm, notes: cleanNotes)
                modelContext.insert(keyword)
            }
        }
        try? modelContext.save()
    }
}
