import SwiftUI
import UIKit

struct ListsView: View {
    @State private var viewModel = ListsViewModel()
    @State private var showingNewList = false
    @State private var selectedListId: UUID? = {
        if let raw = ProcessInfo.processInfo.environment["LAUNCH_LIST_ID"], let id = UUID(uuidString: raw) { return id }
        return nil
    }()

    @Bindable var router: AppRouter

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                if let id = selectedListId, let list = viewModel.lists.first(where: { $0.id == id }) {
                    ListDetailHeader(
                        title: list.title,
                        onBack: {
                            withAnimation(.easeOut(duration: 0.2)) { selectedListId = nil }
                        },
                        onRename: { newTitle in
                            Task { await viewModel.rename(list, to: newTitle) }
                        },
                        onDelete: {
                            Task {
                                await viewModel.delete(list)
                                selectedListId = nil
                            }
                        }
                    )
                    ListDetailContent(viewModel: viewModel, listId: id)
                } else {
                    TopBar(
                        title: "Lists",
                        onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
                    )
                    rootList
                }
            }

            if selectedListId == nil {
                Button {
                    showingNewList = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
                .padding(.trailing, 22)
                .padding(.bottom, BottomTabBarMetrics.height + Space.sm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .activeSection(.lists)
        .task { await viewModel.load() }
        .onAppear {
            // Activity timeline deep-link consumption. Same shape as TasksView:
            // focus carries the clientUUID. Scroll + pulse on the matching row
            // is a follow-up; clear here so the focus doesn't loop.
            if router.focus?.section == .lists {
                router.focus = nil
            }
        }
        .sheet(isPresented: $showingNewList) {
            NewListSheet(viewModel: viewModel)
        }
        .alert("Couldn't load lists",
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

    private var rootList: some View {
        // `List` (not `ScrollView { LazyVStack }`) so each list row can opt
        // into native `.swipeActions`. Paper aesthetic preserved via clear
        // row backgrounds, hidden separators, and `.scrollContentBackground`.
        List {
            Section {
                if viewModel.lists.isEmpty && !viewModel.isLoading {
                    Text("No lists yet. Tap + to start.")
                        .font(.edBody)
                        .foregroundStyle(Tokens.muted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Space.xxxl)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: Space.lg, bottom: 0, trailing: Space.lg))
                } else {
                    ForEach(viewModel.lists) { list in
                        ListSummaryRow(list: list) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                selectedListId = list.id
                            }
                        }
                        .swipeToDeleteTrash {
                            Task { await viewModel.delete(list) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.lg, bottom: Space.xs, trailing: Space.lg))
                    }
                }
            } header: {
                sectionEyebrow("All Lists")
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
        .refreshable { await viewModel.load() }
    }
}

private struct ListDetailHeader: View {
    let title: String
    let onBack: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Lists")
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
                    .accessibilityLabel("List title")
            } else {
                Text(title)
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draft = title
                        isEditing = true
                        focused = true
                    }
                    .accessibilityLabel("List title, tap to rename")
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityLabel("Delete list")
        }
        .padding(.horizontal, Space.md)
        .frame(height: 56)
        .background(Tokens.paper.overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.divider).frame(height: 0.5)
        })
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != title {
            onRename(trimmed)
        }
        isEditing = false
        focused = false
    }
}

private struct ListSummaryRow: View {
    let list: Checklist
    let onTap: () -> Void

    var body: some View {
        let total = list.items.count
        let completed = list.items.filter(\.checked).count
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text(list.title)
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "number")
                            .font(.system(size: 10, weight: .regular))
                        Text("\(total)")
                    }
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 2)
                    .background(Tokens.paper2, in: Capsule())
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Tokens.mutedSoft)
                }
                if total > 0 {
                    HStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Tokens.paper2).frame(height: 4)
                                Capsule()
                                    .fill(Tokens.accentLists)
                                    .frame(width: geo.size.width * (Double(completed) / Double(max(total, 1))), height: 4)
                            }
                        }
                        .frame(height: 4)
                        Text("\(completed)/\(total)")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                    }
                } else {
                    Text("Empty")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
        .buttonStyle(.plain)
    }
}

private struct ListDetailContent: View {
    @Bindable var viewModel: ListsViewModel
    let listId: UUID
    @State private var newItemText: String = ""
    // Tap-below inline draft state. nil = no draft active; "" = draft active (empty field).
    @State private var draftText: String? = nil
    @FocusState private var draftFocused: Bool

    var body: some View {
        if let list = viewModel.lists.first(where: { $0.id == listId }) {
            VStack(spacing: 0) {
                // Header strip — count + "Edit" affordance is implicit via long-press.
                HStack(spacing: Space.sm) {
                    Text("\(list.items.filter(\.checked).count) of \(list.items.count) items")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                    Spacer()
                    if !list.items.isEmpty {
                        Text("Hold to reorder")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.mutedSoft)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
                .padding(.bottom, Space.sm)

                Rectangle().fill(Tokens.divider).frame(height: 0.5)
                    .padding(.horizontal, Space.lg)

                // Items list — always rendered so tap-below works even when empty.
                // Chrome stripped to keep the editorial calm look.
                List {
                    // Existing items live in their own section so .onMove stays scoped to them.
                    Section {
                        // Empty state row — only when no items and no draft is active.
                        if list.items.isEmpty && draftText == nil {
                            Text("No items yet. Add one below.")
                                .font(.edBody)
                                .foregroundStyle(Tokens.muted)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, Space.lg)
                                .listRowBackground(Tokens.paper)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: Space.lg, bottom: 2, trailing: Space.lg))
                        }

                        ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                            ItemRow(
                                item: item,
                                onToggle: {
                                    Task { await viewModel.toggleItem(in: list, at: index) }
                                },
                                onRename: { newText in
                                    Task { await viewModel.renameItem(in: list, at: index, to: newText) }
                                },
                                onDelete: {
                                    Haptics.destructive()
                                    Task { await viewModel.removeItem(from: list, at: index) }
                                },
                                isDraftActive: draftText != nil
                            )
                            .swipeToDeleteTrash {
                                Task { await viewModel.removeItem(from: list, at: index) }
                            }
                            .listRowBackground(Tokens.paper)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: Space.lg, bottom: 2, trailing: Space.lg))
                        }
                        .onMove { source, destination in
                            Task { await viewModel.reorderItems(in: list, from: source, to: destination) }
                        }
                    }

                    // Tap-below section — lives after items, before addItemBar.
                    Section {
                        if let text = Binding($draftText) {
                            // Draft is active: show an inline editable row mirroring ItemRow.
                            DraftItemRow(
                                text: text,
                                isFocused: $draftFocused,
                                onSubmit: { commitDraft(in: list, keepFocus: true) },
                                onFocusLost: { commitDraft(in: list, keepFocus: false) }
                            )
                            .listRowBackground(Tokens.paper)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: Space.lg, bottom: 2, trailing: Space.lg))
                        } else {
                            // No draft: clear tap target below the last row.
                            Color.clear
                                .frame(minHeight: 200)
                                .contentShape(Rectangle())
                                .onTapGesture { startDraft() }
                                .listRowBackground(Tokens.paper)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
                .scrollDismissesKeyboard(.interactively)

                addItemBar(list: list)
            }
        } else {
            Spacer()
            Text("List not found")
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
            Spacer()
        }
    }

    // MARK: - Tap-below helpers

    private func startDraft() {
        draftText = ""
        // Give the List time to insert the DraftItemRow into the hierarchy before focusing.
        DispatchQueue.main.async { draftFocused = true }
    }

    /// Commits whatever is in draftText.
    /// - keepFocus: true = chain creation (Return key path); false = dismiss (focus-loss path).
    private func commitDraft(in list: Checklist, keepFocus: Bool) {
        let text = draftText ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty draft: silently dismiss.
            draftText = nil
            draftFocused = false
            // Belt-and-braces: ensure keyboard collapses even if something else
            // would try to steal first responder (e.g. an ItemRow tap).
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            return
        }
        // Non-empty: commit and optionally chain.
        let snapshot = list
        Task { await viewModel.addItem(to: snapshot, text: trimmed) }
        if keepFocus {
            // Chain: clear text, keep focus for next entry.
            draftText = ""
            // Re-assert focus after the text clears (SwiftUI may drop it briefly).
            DispatchQueue.main.async { draftFocused = true }
        } else {
            draftText = nil
            draftFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    private func addItemBar(list: Checklist) -> some View {
        HStack(spacing: Space.sm) {
            ZStack(alignment: .leading) {
                if newItemText.isEmpty {
                    Text("Add an item…")
                        .font(.edBody)
                        .foregroundStyle(Tokens.mutedSoft)
                        .padding(.horizontal, Space.md)
                        .allowsHitTesting(false)
                }
                TextField("", text: $newItemText)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, 10)
                    .submitLabel(.done)
                    .onSubmit { add(in: list) }
            }
            .frame(minHeight: 40)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.md)

            Button { add(in: list) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(EdSendButtonStyle(enabled: !newItemText.trimmingCharacters(in: .whitespaces).isEmpty))
            .disabled(newItemText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(Tokens.paper.overlay(alignment: .top) {
            Rectangle().fill(Tokens.divider).frame(height: 0.5)
        })
    }

    private func add(in list: Checklist) {
        let trimmed = newItemText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let snapshot = list
        newItemText = ""
        Task { await viewModel.addItem(to: snapshot, text: trimmed) }
    }
}

/// Inline draft row that appears when the user taps below the last item.
/// Mirrors the visual shape of ItemRow: stroked circle bullet + text field.
private struct DraftItemRow: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onFocusLost: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            // Empty stroked circle — identical to ItemRow's unchecked bullet.
            Circle()
                .stroke(Tokens.borderStrong, lineWidth: 2)
                .frame(width: 22, height: 22)
                .frame(width: 24, height: 24)

            TextField("New item", text: $text)
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .submitLabel(.return)
                .focused(isFocused)
                .onSubmit { onSubmit() }
                .onChange(of: isFocused.wrappedValue) { _, nowFocused in
                    if !nowFocused { onFocusLost() }
                }
                .accessibilityLabel("New item")

            Spacer()
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.md)
        .contentShape(Rectangle())
    }
}

private struct ItemRow: View {
    let item: ChecklistItem
    let onToggle: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    /// When a tap-below draft is active in the parent, suppress beginEditing so the
    /// tap only dismisses the draft keyboard — nothing re-steals first responder.
    var isDraftActive: Bool = false

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .stroke(item.checked ? Tokens.success : Tokens.borderStrong, lineWidth: 2)
                        .background(item.checked ? Tokens.success.clipShape(Circle()) : nil)
                        .frame(width: 22, height: 22)
                    if item.checked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Tokens.paper)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(isEditing)

            if isEditing {
                TextField("", text: $draft)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, nowFocused in
                        if !nowFocused { commit() }
                    }
                    .accessibilityLabel("Rename item")
            } else {
                Text(item.text)
                    .font(.edBody)
                    .strikethrough(item.checked)
                    .foregroundStyle(item.checked ? Tokens.mutedSoft : Tokens.ink)
            }
            Spacer()
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.md)
        .contentShape(Rectangle())
        .onTapGesture {
            // When a tap-below draft is active, ignore the tap entirely.
            // The draft's TextField loses focus naturally, commitDraft fires,
            // and the keyboard collapses without anything re-stealing focus.
            guard !isDraftActive else { return }
            if !isEditing { beginEditing() }
        }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func beginEditing() {
        draft = item.text
        isEditing = true
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != item.text {
            onRename(trimmed)
        }
        isEditing = false
        focused = false
    }
}

private struct NewListSheet: View {
    let viewModel: ListsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Title").eyebrow()
                    TextField("List title", text: $title)
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                        .padding(Space.md)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                        .paperBorder(Tokens.border, radius: Radius.md)
                    Spacer()
                }
                .padding(Space.lg)
            }
            .navigationTitle("New list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await viewModel.create(title: title.trimmingCharacters(in: .whitespaces))
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .foregroundStyle(Tokens.ink)
                }
            }
        }
    }
}
