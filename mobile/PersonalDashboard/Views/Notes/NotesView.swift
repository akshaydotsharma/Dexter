import SwiftUI
import Combine

struct NotesView: View {
    @State private var viewModel = NotesViewModel()
    @State private var showingNewFolder = false
    @State private var selectedNoteId: UUID?
    @State private var selectedFolder: NoteFolder?
    /// Drives the macOS folder-rename alert (issue #291). iOS renames inline
    /// by tapping the folder title in `FolderDetailHeader`.
    @State private var renamingFolder = false
    @State private var folderRenameDraft = ""
    /// Whether the Archive is showing instead of the notes root (#374). A sibling
    /// of `selectedNoteId` / `selectedFolder`, so a note opened from the Archive
    /// closes back to the Archive.
    @State private var showingArchive = false
    @State private var pendingFolderLaunchId: UUID? = {
        if let raw = ProcessInfo.processInfo.environment["LAUNCH_FOLDER_ID"], let id = UUID(uuidString: raw) { return id }
        return nil
    }()

    @Bindable var router: AppRouter

    var body: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()

            VStack(spacing: 0) {
                // `viewModel.note(id:)` rather than a search of `viewModel.notes`:
                // the note may be archived (opened from the Archive), in which
                // case it lives in `archivedNotes` (#374).
                if let id = selectedNoteId, let note = viewModel.note(id: id) {
                    NoteDetailContent(
                        viewModel: viewModel,
                        note: note,
                        onClose: {
                            withAnimation(.easeOut(duration: 0.2)) { selectedNoteId = nil }
                        }
                    )
                } else if let folder = selectedFolder {
                    // iOS: in-view folder header (tap title to rename). macOS:
                    // back + rename live in the native toolbar; rename opens a
                    // small alert since there's no in-view title to tap (#291).
                    #if os(iOS)
                    FolderDetailHeader(
                        folder: folder,
                        onBack: {
                            withAnimation(.easeOut(duration: 0.2)) { selectedFolder = nil }
                        },
                        onRename: { newName in
                            Task {
                                await viewModel.renameFolder(folder, to: newName)
                                if let updated = viewModel.folders.first(where: { $0.id == folder.id }) {
                                    selectedFolder = updated
                                }
                            }
                        }
                    )
                    #endif
                    folderNotesList(folder)
                        .macDetailChrome(
                            title: folder.name,
                            onBack: {
                                withAnimation(.easeOut(duration: 0.2)) { selectedFolder = nil }
                            },
                            actions: {
                                Button {
                                    folderRenameDraft = folder.name
                                    renamingFolder = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .help("Rename folder")
                            }
                        )
                } else if showingArchive {
                    // The Archive: a flat list of archived notes across all
                    // folders (#374). Same chrome split as an open folder — an
                    // in-view back header on iOS, native toolbar on macOS.
                    #if os(iOS)
                    ArchiveHeader(backTitle: "Notes", onBack: closeArchive)
                    #endif
                    archiveList
                        .macDetailChrome(title: "Archive", subtitle: "Notes", onBack: closeArchive)
                } else {
                    // iOS: in-view top bar, and the create-folder affordance
                    // overlays the top-right of the list area so it doesn't
                    // take layout space — Folders/Unfiled start at the same
                    // vertical level as Lists/Tasks.
                    //
                    // macOS: no top bar; the folder-add is a native toolbar
                    // button (see `.macSectionChrome` below) and the list sits
                    // flush under the window title bar, so the overlay hack —
                    // which mis-aligned the UNFILED header — is dropped (#283).
                    #if os(iOS)
                    TopBar(
                        title: "Notes",
                        onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } },
                        trailing: {
                            // Archive goes in the top bar; folder-add keeps its
                            // overlay position below. Two homes, but the top-bar
                            // slot is the one shared with Lists, so "where is my
                            // archive" has a single answer across sections (#374).
                            TopBarIconButton(
                                systemName: "archivebox",
                                accessibilityLabel: "Archived notes",
                                action: openArchive
                            )
                        }
                    )
                    rootList
                        .overlay(alignment: .topTrailing) {
                            Button {
                                showingNewFolder = true
                            } label: {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 18, weight: .regular))
                                    .foregroundStyle(Tokens.ink)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("New folder")
                            .padding(.trailing, Space.sm)
                        }
                    #else
                    rootList
                        .macSectionChrome("Notes") {
                            // Two controls in the one trailing slot. The closure
                            // is a plain ViewBuilder feeding a single
                            // `ToolbarItem`, so these land in the same Liquid
                            // Glass group rather than as separate pills (#374).
                            Button(action: openArchive) {
                                Image(systemName: "archivebox")
                            }
                            .help("Archived notes")
                            .accessibilityLabel("Archived notes")
                            Button {
                                showingNewFolder = true
                            } label: {
                                Image(systemName: "folder.badge.plus")
                            }
                            // Default toolbar button style, NOT `.plain`. #289
                            // used a bare glyph so it would not read as merged
                            // with the round AS coin, but `.plain` also strips
                            // the padding macOS puts inside a toolbar control,
                            // so the icon sat flush against the leading curve of
                            // the grouped Liquid Glass pill while the refresh
                            // icon beside it was inset (#368). Matching refresh
                            // gives both the same breathing room.
                            .accessibilityLabel("New folder")
                        }
                        // File > New Note / Cmd-N on the notes root, creating an
                        // unfiled note. An open folder publishes its own action
                        // so the note lands in that folder instead, per the
                        // ruling on #295. The folder-add button above stays a
                        // toolbar control rather than taking Cmd-N, since a
                        // section's Cmd-N creates its primary record and Notes'
                        // primary record is a note, not a folder.
                        #if os(macOS)
                        .focusedSceneValue(\.newItemAction, NewItemAction(title: "New Note") {
                            Task { await createBlankNote(folderId: nil) }
                        })
                        #endif
                    #endif
                }
            }

            // No create FAB inside the Archive: a new note is created active, so
            // it would not appear in the list you are looking at (#374).
            if selectedNoteId == nil && !showingArchive {
                Button {
                    Task { await createBlankNote(folderId: selectedFolder?.id) }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
                .padding(.trailing, 22)
                .padding(.bottom, BottomTabBarMetrics.fabBottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .activeSection(.notes)
        // Section vs detail chrome is applied per-branch above (issue #291):
        // the root list gets `.macSectionChrome`, an open folder/note gets
        // `.macDetailChrome` so the native toolbar carries back + actions and
        // the window title tracks the open item instead of staying on "Notes".
        // Live-refresh when the voice-capture or chat path writes a note.
        .onReceive(NotificationCenter.default.publisher(for: .localStoreDidChange)) { _ in
            Task { await viewModel.load() }
        }
        .task {
            await viewModel.load()
            if let id = pendingFolderLaunchId,
               let folder = viewModel.folders.first(where: { $0.id == id }) {
                selectedFolder = folder
                pendingFolderLaunchId = nil
            }
        }
        .onAppear {
            // Activity timeline deep-link consumption. Same shape as the
            // other surfaces: focus carries the clientUUID (folder UUID when
            // `isFolder` is true). Scroll + pulse on the matching row is a
            // follow-up; clear here so the focus doesn't loop.
            if router.focus?.section == .notes {
                router.focus = nil
            }
            syncBackHandler()
        }
        .onDisappear {
            // Don't strip a back handler we didn't install. NotesView appears
            // and disappears when toggled in/out of the surface stack; another
            // surface may have set its own handler in the meantime.
            if selectedNoteId != nil || selectedFolder != nil {
                router.leadingEdgeBackHandler = nil
            }
        }
        .onChange(of: selectedNoteId) { _, _ in syncBackHandler() }
        .onChange(of: selectedFolder?.id) { _, _ in syncBackHandler() }
        .onChange(of: showingArchive) { _, _ in syncBackHandler() }
        .sheet(isPresented: $showingNewFolder) {
            NewFolderSheet(viewModel: viewModel)
        }
        .alert("Rename folder", isPresented: $renamingFolder) {
            TextField("Folder name", text: $folderRenameDraft)
                .paperFieldOnMac()
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let folder = selectedFolder else { return }
                let trimmed = folderRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != folder.name else { return }
                Task {
                    await viewModel.renameFolder(folder, to: trimmed)
                    if let updated = viewModel.folders.first(where: { $0.id == folder.id }) {
                        selectedFolder = updated
                    }
                }
            }
        }
        .alert("Couldn't load notes",
               isPresented: Binding(
                   get: { viewModel.errorMessage != nil },
                   set: { if !$0 { viewModel.errorMessage = nil } }
               )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Root list (folders + unfiled)

    private var rootList: some View {
        // `List` (not `ScrollView { LazyVStack }`) so each folder/note row can
        // opt into native `.swipeActions`. Paper aesthetic preserved with
        // clear row backgrounds and hidden separators.
        List {
            if !viewModel.folders.isEmpty {
                Section {
                    ForEach(viewModel.folders) { folder in
                        FolderRow(
                            folder: folder,
                            count: viewModel.notes(in: folder).count,
                            onTap: {
                                withAnimation(.easeOut(duration: 0.2)) { selectedFolder = folder }
                            }
                        )
                        .swipeToDeleteTrash {
                            Task { await viewModel.deleteFolder(folder) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contentRowInsets(vertical: Space.xs)
                    }
                } header: {
                    sectionEyebrow("Folders")
                }
            }

            let unfiled = viewModel.notes(in: nil)
            if !unfiled.isEmpty {
                Section {
                    ForEach(unfiled) { note in
                        NoteRow(note: note) { open(note: note) }
                            .swipeToArchiveOrDelete(
                                onArchive: { Task { await viewModel.setArchived(note, true) } },
                                onDelete: { Task { await viewModel.deleteNote(note) } }
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .contentRowInsets(vertical: Space.xs)
                    }
                } header: {
                    sectionEyebrow("Unfiled")
                }
            }

            if viewModel.folders.isEmpty && viewModel.notes.isEmpty && !viewModel.isLoading {
                Text("No notes yet. Tap + to start.")
                    .font(.edBody)
                    .foregroundStyle(Tokens.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Space.xxxl)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: Space.lg, bottom: 0, trailing: Space.lg))
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
        .syncRefreshable { await viewModel.load() }
    }

    private func folderNotesList(_ folder: NoteFolder) -> some View {
        let inFolder = viewModel.notes(in: folder)
        return List {
            if inFolder.isEmpty {
                Text("No notes in \(folder.name) yet.")
                    .font(.edBody)
                    .foregroundStyle(Tokens.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Space.xxxl)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: Space.lg, leading: Space.lg, bottom: 0, trailing: Space.lg))
            } else {
                ForEach(inFolder) { note in
                    NoteRow(note: note) { open(note: note) }
                        .swipeToArchiveOrDelete(
                            onArchive: { Task { await viewModel.setArchived(note, true) } },
                            onDelete: { Task { await viewModel.deleteNote(note) } }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contentRowInsets(vertical: Space.xs)
                }
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
        .syncRefreshable { await viewModel.load() }
    }

    // MARK: - Note actions

    private func open(note: Note) {
        withAnimation(.easeOut(duration: 0.2)) { selectedNoteId = note.id }
    }

    private func createBlankNote(folderId: UUID?) async {
        guard let new = await viewModel.createNote(title: nil, content: nil, folderId: folderId) else { return }
        withAnimation(.easeOut(duration: 0.2)) { selectedNoteId = new.id }
    }

    // MARK: - Back-swipe wiring
    //
    // Captures @State via Bindings so the closures stored on the router can
    // mutate this view's selection state. Setting `wrappedValue = nil` writes
    // back through to @State storage, mirroring how SwiftUI passes bindings
    // around. Re-runs whenever sub-state changes so the handler always pops
    // the most-nested screen first (note before folder).
    private func syncBackHandler() {
        let noteBinding = $selectedNoteId
        let folderBinding = $selectedFolder
        let archiveBinding = $showingArchive
        if selectedNoteId != nil {
            router.leadingEdgeBackHandler = {
                withAnimation(.easeOut(duration: 0.2)) {
                    noteBinding.wrappedValue = nil
                }
            }
        } else if selectedFolder != nil {
            router.leadingEdgeBackHandler = {
                withAnimation(.easeOut(duration: 0.2)) {
                    folderBinding.wrappedValue = nil
                }
            }
        } else if showingArchive {
            // Least-nested of the three, so it is checked last: a note opened
            // from the Archive pops to the Archive first (#374).
            router.leadingEdgeBackHandler = {
                withAnimation(.easeOut(duration: 0.2)) {
                    archiveBinding.wrappedValue = false
                }
            }
        } else {
            router.leadingEdgeBackHandler = nil
        }
    }

    private func openArchive() {
        withAnimation(.easeOut(duration: 0.2)) { showingArchive = true }
    }

    private func closeArchive() {
        withAnimation(.easeOut(duration: 0.2)) { showingArchive = false }
    }

    /// The Archive (#374). Flat across folders, using the same `NoteRow` and row
    /// insets as the index so an archived note reads as itself.
    private var archiveList: some View {
        List {
            if viewModel.archivedNotes.isEmpty {
                Text("Nothing archived yet. Swipe a note to archive it.")
                    .font(.edBody)
                    .foregroundStyle(Tokens.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Space.xxxl)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: Space.lg, bottom: 0, trailing: Space.lg))
            } else {
                ForEach(viewModel.archivedNotes) { note in
                    NoteRow(note: note) { open(note: note) }
                        .swipeToUnarchiveOrDelete(
                            onUnarchive: { Task { await viewModel.setArchived(note, false) } },
                            onDelete: { Task { await viewModel.deleteNote(note) } }
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contentRowInsets(vertical: Space.xs)
                }
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
        // Intentionally NO `.macTamedListSelection()` here, even though the Lists
        // archive has it: the Notes root list does not have it either, and the
        // Archive is supposed to be the same view with a different data source.
        // Adding it on one side only would make the Archive and the index render
        // differently on macOS. Whether Notes should tame selection at all is a
        // pre-existing question for both, not something to change on one branch.
        .syncRefreshable { await viewModel.load() }
    }
}

private struct FolderDetailHeader: View {
    let folder: NoteFolder
    let onBack: () -> Void
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Notes")
                }
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            Spacer()
            if isEditing {
                TextField("", text: $draft)
                    .paperFieldOnMac()
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.center)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, nowFocused in
                        if !nowFocused { commit() }
                    }
                    .accessibilityLabel("Folder name")
            } else {
                Text(folder.name)
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draft = folder.name
                        isEditing = true
                        focused = true
                    }
                    .accessibilityLabel("Folder name, tap to rename")
            }
            Spacer()
            // Invisible counter-weight so the folder title stays optically
            // centered now that the inline + has moved to the floating FAB
            // at the bottom right (consistent with every other surface).
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, Space.md)
        .frame(height: 56)
        .background(Tokens.paper.overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.divider).frame(height: 0.5)
        })
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != folder.name {
            onRename(trimmed)
        }
        isEditing = false
        focused = false
    }
}

private struct FolderRow: View {
    let folder: NoteFolder
    let count: Int
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "folder")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Tokens.accentNotes)
                .frame(width: 22, height: 22)
            Text(folder.name)
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
            Spacer()
            Text("\(count)")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Tokens.mutedSoft)
        }
        .flatContentRow()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

private struct NoteRow: View {
    let note: Note
    let onTap: () -> Void

    var body: some View {
        let trimmedBody = (note.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBody = !trimmedBody.isEmpty

        return VStack(alignment: .leading, spacing: 4) {
            Text((note.title?.isEmpty == false ? note.title! : "Untitled"))
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
            if hasBody {
                Text(markdownSnippetAttributed(trimmedBody))
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
            } else {
                Text("No additional text")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.mutedSoft)
                    .lineLimit(1)
            }
            Text(note.updatedAt, style: .relative)
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatContentRow()
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

}

private struct NewFolderSheet: View {
    let viewModel: NotesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Folder name").eyebrow()
                    TextField("Name", text: $name)
                        .paperFieldOnMac()
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                        .padding(Space.md)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                        .paperBorder(Tokens.border, radius: Radius.md)
                    Spacer()
                }
                .padding(Space.lg)
            }
            .navigationTitle("New folder")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await viewModel.createFolder(name: name.trimmingCharacters(in: .whitespaces))
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .foregroundStyle(Tokens.ink)
                }
            }
        }
    }
}

/// Full-screen note detail per DESIGN_SPEC §10.4. Edits are auto-saved
/// when the user taps Done or otherwise leaves the view; there is no
/// modal Cancel/Save pair.
private struct NoteDetailContent: View {
    @Bindable var viewModel: NotesViewModel
    let note: Note
    let onClose: () -> Void

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var folderId: UUID?
    @State private var hasLoaded = false
    @State private var mode: NoteEditMode = .preview
    @FocusState private var contentFocused: Bool

    enum NoteEditMode { case edit, preview }

    var body: some View {
        VStack(spacing: 0) {
            // iOS: in-view header row. macOS: back + preview-toggle + delete
            // live in the native window toolbar via `.macDetailChrome` below,
            // and the note's own big title field stays in the content (#291).
            #if os(iOS)
            header
            Rectangle().fill(Tokens.divider).frame(height: 0.5)
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    TextField("Untitled", text: $title, axis: .vertical)
                        .paperFieldOnMac()
                        .font(.edDisplay)
                        .foregroundStyle(Tokens.ink)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)

                    if !viewModel.folders.isEmpty {
                        Menu {
                            Button("None") { folderId = nil }
                            ForEach(viewModel.folders) { folder in
                                Button(folder.name) { folderId = folder.id }
                            }
                        } label: {
                            HStack(spacing: Space.xs) {
                                Image(systemName: "folder")
                                    .font(.system(size: 13, weight: .regular))
                                Text(currentFolderName)
                                    .font(.edFootnote)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Tokens.muted)
                            .padding(.horizontal, Space.md)
                            .padding(.vertical, Space.xs)
                            .background(Tokens.paper2, in: Capsule())
                        }
                    }

                    Rectangle().fill(Tokens.divider).frame(height: 0.5)

                    bodyEditor
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
                // Clear the floating bottom nav so the last lines of a long
                // note aren't hidden behind it (matches the list view inset).
                .padding(.bottom, BottomTabBarMetrics.height + Space.lg)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Tokens.paper)
        .macDetailChrome(
            title: title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : title,
            subtitle: note.updatedAt.formatted(.relative(presentation: .named)),
            onBack: {
                Task {
                    await persistIfChanged()
                    onClose()
                }
            },
            actions: {
                Button { togglePreview() } label: {
                    Image(systemName: mode == .edit ? "eye" : "pencil")
                }
                .help(mode == .edit ? "Preview note" : "Edit note")
                Button(role: .destructive) {
                    Task {
                        await viewModel.deleteNote(note)
                        onClose()
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete note")
            }
        )
        .onAppear {
            if !hasLoaded {
                title = note.title ?? ""
                content = note.content ?? ""
                folderId = note.folderId
                hasLoaded = true
            }
        }
        .onDisappear {
            Task { await persistIfChanged() }
        }
    }

    @ViewBuilder
    private var bodyEditor: some View {
        switch mode {
        case .edit:
            // MarkdownEditor wraps UITextView so the format toolbar can wrap
            // the user's selection (or insert at cursor) when they tap a
            // formatting button. The toolbar lives in the textView's
            // inputAccessoryView, so it rides above the keyboard.
            MarkdownEditor(
                text: $content,
                isFocused: $contentFocused,
                minHeight: 320,
                placeholder: "Start writing. Use the bar above the keyboard for headings, bold, lists…"
            )
            .frame(minHeight: 320)
        case .preview:
            // Empty notes shouldn't render an empty MarkdownView (which would
            // collapse to zero height and look broken). Show a quiet hint
            // pointing the user back to edit mode.
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Nothing to preview yet. Tap the pencil to write.")
                    .font(.edBody)
                    .foregroundStyle(Tokens.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Space.xl)
            } else {
                MarkdownView(text: content, bodyColor: Tokens.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Button {
                Task {
                    await persistIfChanged()
                    onClose()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Notes")
                }
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            Spacer()
            Text(note.updatedAt, style: .relative)
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
            Button {
                togglePreview()
            } label: {
                Image(systemName: mode == .edit ? "eye" : "pencil")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityLabel(mode == .edit ? "Preview note" : "Edit note")
            Button {
                Task {
                    await viewModel.deleteNote(note)
                    onClose()
                }
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityLabel("Delete note")
        }
        .padding(.horizontal, Space.md)
        .frame(height: 56)
        .background(Tokens.paper)
    }

    /// Flip between edit and preview. Drops the keyboard before showing the
    /// preview so the accessory toolbar doesn't briefly hang around, then
    /// refocuses when returning to edit. Shared by the iOS header button and
    /// the macOS toolbar action (issue #291).
    private func togglePreview() {
        if mode == .edit { contentFocused = false }
        withAnimation(.easeOut(duration: 0.15)) {
            mode = (mode == .edit) ? .preview : .edit
        }
        if mode == .edit {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                contentFocused = true
            }
        }
    }

    private var currentFolderName: String {
        guard let id = folderId,
              let folder = viewModel.folders.first(where: { $0.id == id }) else {
            return "Unfiled"
        }
        return folder.name
    }

    private func persistIfChanged() async {
        let finalTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title
        let finalContent = content.isEmpty ? nil : content
        if finalTitle != note.title || finalContent != note.content || folderId != note.folderId {
            await viewModel.updateNote(note, title: finalTitle, content: finalContent, folderId: folderId)
        }
    }
}
