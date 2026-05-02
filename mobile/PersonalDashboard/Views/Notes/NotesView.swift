import SwiftUI

struct NotesView: View {
    @State private var viewModel = NotesViewModel()
    @State private var showingNewFolder = false
    @State private var showingNewNote = false
    @State private var editingNote: Note?
    @State private var selectedFolder: NoteFolder?
    @State private var pendingFolderLaunchId: Int? = {
        if let raw = ProcessInfo.processInfo.environment["LAUNCH_FOLDER_ID"], let id = Int(raw) { return id }
        return nil
    }()

    @Bindable var router: AppRouter
    @Binding var schemePref: ColorSchemePref

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                if let folder = selectedFolder {
                    folderDetailHeader(folder: folder)
                } else {
                    TopBar(
                        title: "Notes",
                        onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } },
                        onToggleTheme: { schemePref = schemePref.next }
                    )
                }

                if let folder = selectedFolder {
                    folderNotesList(folder)
                } else {
                    rootList
                }
            }

            ChatFAB { router.popToChat() }
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
        .sheet(isPresented: $showingNewFolder) {
            NewFolderSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingNewNote) {
            NoteEditorSheet(viewModel: viewModel, note: nil, defaultFolderId: selectedFolder?.id)
        }
        .sheet(item: $editingNote) { note in
            NoteEditorSheet(viewModel: viewModel, note: note, defaultFolderId: note.folderId)
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

    // MARK: - Folder header

    private func folderDetailHeader(folder: NoteFolder) -> some View {
        HStack(spacing: Space.md) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { selectedFolder = nil }
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
            Text(folder.name)
                .font(.edTitle)
                .foregroundStyle(Tokens.ink)
            Spacer()
            Button { showingNewNote = true } label: {
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

    // MARK: - Root list (folders + unfiled)

    private var rootList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    Spacer()
                    Button {
                        showingNewFolder = true
                    } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(EdButtonStyle(kind: .secondary, size: .sm))
                    Button {
                        showingNewNote = true
                    } label: {
                        Label("New note", systemImage: "plus")
                    }
                    .buttonStyle(EdButtonStyle(kind: .primary, size: .sm))
                }

                if !viewModel.folders.isEmpty {
                    section("Folders") {
                        VStack(spacing: Space.xs) {
                            ForEach(viewModel.folders) { folder in
                                FolderRow(
                                    folder: folder,
                                    count: viewModel.notes(in: folder).count,
                                    onTap: {
                                        withAnimation(.easeOut(duration: 0.2)) { selectedFolder = folder }
                                    }
                                )
                            }
                        }
                    }
                }

                let unfiled = viewModel.notes(in: nil)
                if !unfiled.isEmpty {
                    section("Unfiled") {
                        VStack(spacing: Space.xs) {
                            ForEach(unfiled) { note in
                                NoteRow(note: note) { editingNote = note }
                            }
                        }
                    }
                }

                if viewModel.folders.isEmpty && viewModel.notes.isEmpty && !viewModel.isLoading {
                    Text("No notes yet. Tap “New note” to start.")
                        .font(.edBody)
                        .foregroundStyle(Tokens.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Space.xxxl)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, 96)
        }
        .refreshable { await viewModel.load() }
    }

    private func folderNotesList(_ folder: NoteFolder) -> some View {
        let inFolder = viewModel.notes(in: folder)
        return ScrollView {
            LazyVStack(spacing: Space.xs) {
                if inFolder.isEmpty {
                    Text("No notes in \(folder.name) yet.")
                        .font(.edBody)
                        .foregroundStyle(Tokens.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Space.xxxl)
                } else {
                    ForEach(inFolder) { note in
                        NoteRow(note: note) { editingNote = note }
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.lg)
            .padding(.bottom, 96)
        }
        .refreshable { await viewModel.load() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title).eyebrow()
            body()
        }
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

private struct NoteEditorSheet: View {
    let viewModel: NotesViewModel
    let note: Note?
    let defaultFolderId: Int?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var folderId: Int?

    private var isEditing: Bool { note != nil }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        TextField("Untitled", text: $title)
                            .font(.edTitle)
                            .foregroundStyle(Tokens.ink)
                            .textFieldStyle(.plain)

                        if !viewModel.folders.isEmpty {
                            Picker("Folder", selection: Binding(
                                get: { folderId ?? -1 },
                                set: { folderId = $0 == -1 ? nil : $0 }
                            )) {
                                Text("None").tag(-1)
                                ForEach(viewModel.folders) { folder in
                                    Text(folder.name).tag(folder.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(Tokens.muted)
                        }

                        Rectangle().fill(Tokens.divider).frame(height: 0.5)

                        TextEditor(text: $content)
                            .font(.edBody)
                            .foregroundStyle(Tokens.ink)
                            .scrollContentBackground(.hidden)
                            .background(Tokens.paper)
                            .frame(minHeight: 240)
                    }
                    .padding(Space.lg)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                                  && content.trimmingCharacters(in: .whitespaces).isEmpty)
                        .foregroundStyle(Tokens.ink)
                }
            }
            .onAppear {
                if let note {
                    title = note.title ?? ""
                    content = note.content ?? ""
                    folderId = note.folderId
                } else {
                    folderId = defaultFolderId
                }
            }
        }
    }

    private func save() async {
        let finalTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title
        let finalContent = content.isEmpty ? nil : content
        if let existing = note {
            await viewModel.updateNote(existing, title: finalTitle, content: finalContent, folderId: folderId)
        } else {
            _ = await viewModel.createNote(title: finalTitle, content: finalContent, folderId: folderId)
        }
        dismiss()
    }
}
