import SwiftUI
import SwiftData

#if os(macOS)

/// Pick folders and notes out of the Apple Notes app and import them (#396).
///
/// macOS only, because Apple ships no way to read Notes on iOS. Imported notes
/// reach the iPhone through the existing sync.
struct AppleNotesImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private enum Phase {
        case loading
        case picking([AppleNotesReader.Folder])
        case importing(done: Int, total: Int)
        case finished(AppleNotesImportService.Outcome)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var selected: Set<String> = []
    @State private var expanded: Set<String> = []
    /// Notes already brought across, greyed out and not selectable, so the screen
    /// shows why a folder that looks full has nothing to import.
    @State private var alreadyImported: Set<String> = []

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("Import from Apple Notes")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                        .disabled(isBusy)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .task { await load() }
    }

    private var isBusy: Bool {
        switch phase {
        case .loading, .importing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            centred {
                ProgressView()
                    .controlSize(.large)
                    .tint(Tokens.muted)
                Text("Reading your Notes library…")
                    .font(.edBody)
                    .foregroundStyle(Tokens.muted)
                Text("A few hundred notes takes a moment. Nothing is imported yet.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.mutedSoft)
            }

        case .picking(let folders):
            picker(folders: folders)

        case .importing(let done, let total):
            centred {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 220)
                    .tint(Tokens.ink)
                Text("Importing \(done) of \(total)…")
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                Text("Notes with photos take longer, since each picture is compressed on the way in.")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.mutedSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.xl)
            }

        case .finished(let outcome):
            finishedScreen(outcome)

        case .failed(let message):
            centred {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Tokens.danger)
                Text("Couldn't read Notes")
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                Text(message)
                    .font(.edBody)
                    .foregroundStyle(Tokens.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.xl)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.plain)
                    .padding(.top, Space.sm)
                    .foregroundStyle(Tokens.ink)
            }
        }
    }

    // MARK: - Picker

    private func picker(folders: [AppleNotesReader.Folder]) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(folders) { folder in
                        folderRow(folder)
                        if expanded.contains(folder.id) {
                            ForEach(folder.notes) { note in
                                noteRow(note)
                            }
                        }
                        Rectangle().fill(Tokens.divider).frame(height: 0.5)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)
            }

            footer(folders: folders)
        }
    }

    private func folderRow(_ folder: AppleNotesReader.Folder) -> some View {
        let importable = folder.notes.filter { !alreadyImported.contains($0.id) }
        let selectedCount = folder.notes.filter { selected.contains($0.id) }.count
        let allSelected = !importable.isEmpty && selectedCount == importable.count

        return HStack(spacing: Space.sm) {
            Button {
                if expanded.contains(folder.id) { expanded.remove(folder.id) }
                else { expanded.insert(folder.id) }
            } label: {
                Image(systemName: expanded.contains(folder.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            Button {
                toggleFolder(folder)
            } label: {
                Image(systemName: allSelected ? "checkmark.square.fill"
                      : (selectedCount > 0 ? "minus.square.fill" : "square"))
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(selectedCount > 0 ? Tokens.ink : Tokens.mutedSoft)
            }
            .buttonStyle(.plain)
            .disabled(importable.isEmpty)

            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.accentNotes)

            Text(folder.name)
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)

            Spacer(minLength: Space.sm)

            if importable.isEmpty, !folder.notes.isEmpty {
                Text("all imported")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            Text("\(folder.notes.count)")
                .font(.edFootnote)
                .monospacedDigit()
                .foregroundStyle(Tokens.muted)
        }
        .padding(.vertical, Space.sm)
        .contentShape(Rectangle())
    }

    private func noteRow(_ note: AppleNotesReader.NoteRef) -> some View {
        let isImported = alreadyImported.contains(note.id)
        return HStack(spacing: Space.sm) {
            Button {
                if selected.contains(note.id) { selected.remove(note.id) }
                else { selected.insert(note.id) }
            } label: {
                Image(systemName: selected.contains(note.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(selected.contains(note.id) ? Tokens.ink : Tokens.mutedSoft)
            }
            .buttonStyle(.plain)
            .disabled(isImported)

            Text(note.name)
                .font(.edBody)
                .foregroundStyle(isImported ? Tokens.mutedSoft : Tokens.inkSoft)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Space.sm)

            if isImported {
                Text("imported")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            } else if let modified = note.modified {
                Text(modified.formatted(.dateTime.year().month(.abbreviated).day()))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
        }
        .padding(.leading, Space.xl + Space.sm)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func footer(folders: [AppleNotesReader.Folder]) -> some View {
        let count = selected.count
        return VStack(spacing: Space.sm) {
            Rectangle().fill(Tokens.divider).frame(height: 0.5)
            HStack(spacing: Space.md) {
                Button(count == 0 ? "Select all" : "Clear selection") {
                    if count == 0 {
                        selected = Set(
                            folders.flatMap(\.notes).map(\.id)
                        ).subtracting(alreadyImported)
                    } else {
                        selected.removeAll()
                    }
                }
                .buttonStyle(.plain)
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)

                Spacer()

                Text(count == 0 ? "Nothing selected"
                     : (count == 1 ? "1 note selected" : "\(count) notes selected"))
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)

                Button {
                    Task { await runImport(folders: folders) }
                } label: {
                    Text("Import")
                        .font(.edBodyMedium)
                        .foregroundStyle(count > 0 ? Color.white : Tokens.mutedSoft)
                        .padding(.horizontal, Space.lg)
                        .frame(height: 34)
                        .background(
                            count > 0 ? Tokens.ink : Tokens.paper2,
                            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.md)
        }
        .background(Tokens.paper)
    }

    // MARK: - Finished

    private func finishedScreen(_ outcome: AppleNotesImportService.Outcome) -> some View {
        centred {
            Image(systemName: outcome.failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(outcome.failed > 0 ? Tokens.warning : Tokens.success)
            Text(outcome.imported == 0 ? "Nothing imported" : "Imported \(outcome.imported) note\(outcome.imported == 1 ? "" : "s")")
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)

            VStack(alignment: .leading, spacing: 4) {
                if outcome.imagesImported > 0 {
                    detail("\(outcome.imagesImported) image\(outcome.imagesImported == 1 ? "" : "s") brought across")
                }
                if outcome.skipped > 0 {
                    detail("\(outcome.skipped) already imported, left alone")
                }
                if outcome.nonImageAttachmentsSkipped > 0 {
                    detail("\(outcome.nonImageAttachmentsSkipped) non-image attachment\(outcome.nonImageAttachmentsSkipped == 1 ? "" : "s") skipped (PDFs and scans aren't supported yet)")
                }
                if outcome.failed > 0 {
                    detail("\(outcome.failed) couldn't be read: \(outcome.failedNoteNames.prefix(3).joined(separator: ", "))")
                }
            }
            .padding(.top, Space.xs)

            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.edBodyMedium)
                .foregroundStyle(Color.white)
                .padding(.horizontal, Space.xl)
                .frame(height: 38)
                .background(Tokens.ink, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .padding(.top, Space.md)
        }
    }

    private func detail(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.xs) {
            Text("•").foregroundStyle(Tokens.mutedSoft)
            Text(text)
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: Space.sm) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Space.xl)
    }

    // MARK: - Actions

    private func toggleFolder(_ folder: AppleNotesReader.Folder) {
        let importable = folder.notes.filter { !alreadyImported.contains($0.id) }.map(\.id)
        let allSelected = !importable.isEmpty && importable.allSatisfy { selected.contains($0) }
        if allSelected {
            for id in importable { selected.remove(id) }
        } else {
            for id in importable { selected.insert(id) }
        }
    }

    private func load() async {
        phase = .loading
        do {
            let folders = try await AppleNotesReader.library()
            let records = try modelContext.fetch(FetchDescriptor<AppleNotesImportRecord>())
            alreadyImported = Set(records.map(\.appleNoteID))
            selected = []
            phase = .picking(folders)
        } catch {
            phase = .failed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    private func runImport(folders: [AppleNotesReader.Folder]) async {
        let service = AppleNotesImportService()
        do {
            let plan = try service.plan(folders: folders, selectedNoteIDs: selected)
            phase = .importing(done: 0, total: plan.pending.count)
            let outcome = await service.run(plan: plan) { done, total in
                phase = .importing(done: done, total: total)
            }
            phase = .finished(outcome)
        } catch {
            phase = .failed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}

#endif
