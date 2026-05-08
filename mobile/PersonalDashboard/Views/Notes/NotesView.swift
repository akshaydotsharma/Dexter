import SwiftUI

struct NotesView: View {
    @State private var viewModel = NotesViewModel()
    @State private var showingNewFolder = false
    @State private var selectedNoteId: UUID?
    @State private var selectedFolder: NoteFolder?
    @State private var pendingFolderLaunchId: UUID? = {
        if let raw = ProcessInfo.processInfo.environment["LAUNCH_FOLDER_ID"], let id = UUID(uuidString: raw) { return id }
        return nil
    }()

    @Bindable var router: AppRouter

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                if let id = selectedNoteId, let note = viewModel.notes.first(where: { $0.id == id }) {
                    NoteDetailContent(
                        viewModel: viewModel,
                        note: note,
                        onClose: {
                            withAnimation(.easeOut(duration: 0.2)) { selectedNoteId = nil }
                        }
                    )
                } else if let folder = selectedFolder {
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
                        },
                        onAddNote: {
                            Task { await createBlankNote(folderId: folder.id) }
                        }
                    )
                    folderNotesList(folder)
                } else {
                    TopBar(
                        title: "Notes",
                        onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
                    )
                    rootList
                }
            }

            if selectedNoteId == nil && selectedFolder == nil {
                HStack(spacing: Space.sm) {
                    Button {
                        showingNewFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(EdIconSquareButtonStyle(kind: .secondary))
                    Button {
                        Task { await createBlankNote(folderId: nil) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(EdIconSquareButtonStyle(kind: .primary))
                }
                .padding(.trailing, 22)
                .padding(.bottom, BottomTabBarMetrics.height + Space.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .activeSection(.notes)
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
        }
        .sheet(isPresented: $showingNewFolder) {
            NewFolderSheet(viewModel: viewModel)
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
                        .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.lg, bottom: Space.xs, trailing: Space.lg))
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
                            .swipeToDeleteTrash {
                                Task { await viewModel.deleteNote(note) }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.lg, bottom: Space.xs, trailing: Space.lg))
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
        .refreshable { await viewModel.load() }
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
                        .swipeToDeleteTrash {
                            Task { await viewModel.deleteNote(note) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.lg, bottom: Space.xs, trailing: Space.lg))
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
        .refreshable { await viewModel.load() }
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .eyebrow()
            .textCase(nil)
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.paper)
    }

    // MARK: - Note actions

    private func open(note: Note) {
        withAnimation(.easeOut(duration: 0.2)) { selectedNoteId = note.id }
    }

    private func createBlankNote(folderId: UUID?) async {
        guard let new = await viewModel.createNote(title: nil, content: nil, folderId: folderId) else { return }
        withAnimation(.easeOut(duration: 0.2)) { selectedNoteId = new.id }
    }
}

private struct FolderDetailHeader: View {
    let folder: NoteFolder
    let onBack: () -> Void
    let onRename: (String) -> Void
    let onAddNote: () -> Void

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
            Button(action: onAddNote) {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.ink)
            }
            .accessibilityLabel("New note")
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
        Button(action: onTap) {
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
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NoteRow: View {
    let note: Note
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                Text((note.title?.isEmpty == false ? note.title! : "Untitled"))
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                if let content = note.content, !content.isEmpty {
                    Text(content)
                        .font(.edSubheadline)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(1)
                }
                Text(note.updatedAt, style: .relative)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            .navigationBarTitleDisplayMode(.inline)
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
    @FocusState private var contentFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Tokens.divider).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    TextField("Untitled", text: $title, axis: .vertical)
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

                    TextEditor(text: $content)
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                        .scrollContentBackground(.hidden)
                        .background(Tokens.paper)
                        .frame(minHeight: 320)
                        .focused($contentFocused)
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.xxxl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Tokens.paper)
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
