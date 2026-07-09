import SwiftUI
import Combine

struct ListsView: View {
    @State private var viewModel = ListsViewModel()
    @State private var showingNewList = false
    @State private var showingProperties = false
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
                        },
                        onProperties: { showingProperties = true }
                    )
                    ListDetailContent(viewModel: viewModel, listId: id)
                        .sheet(isPresented: $showingProperties) {
                            ListPropertiesSheet(viewModel: viewModel, list: list)
                        }
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
        // Live-refresh when the voice-capture or chat path writes a list / item.
        .onReceive(NotificationCenter.default.publisher(for: .localStoreDidChange)) { _ in
            Task { await viewModel.load() }
        }
        .task { await viewModel.load() }
        .onAppear {
            // Activity timeline deep-link consumption. Same shape as TasksView:
            // focus carries the clientUUID. Scroll + pulse on the matching row
            // is a follow-up; clear here so the focus doesn't loop.
            if router.focus?.section == .lists {
                router.focus = nil
            }
            syncBackHandler()
        }
        .onDisappear {
            // Don't strip a back handler we didn't install — another surface
            // may have set its own when this view was off-screen.
            if selectedListId != nil {
                router.leadingEdgeBackHandler = nil
            }
        }
        .onChange(of: selectedListId) { _, _ in syncBackHandler() }
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

    // MARK: - Back-swipe wiring
    //
    // Captures the @State binding so the closure stored on the router can
    // pop the list detail back to the lists root. Mirror of NotesView's
    // syncBackHandler — see that file for the rationale.
    private func syncBackHandler() {
        let listBinding = $selectedListId
        if selectedListId != nil {
            router.leadingEdgeBackHandler = {
                withAnimation(.easeOut(duration: 0.2)) {
                    listBinding.wrappedValue = nil
                }
            }
        } else {
            router.leadingEdgeBackHandler = nil
        }
    }

    private var rootList: some View {
        // `List` (not `ScrollView { LazyVStack }`) so each list row can opt
        // into native `.swipeActions`. Paper aesthetic preserved via clear
        // row backgrounds, hidden separators, and `.scrollContentBackground`.
        List {
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
    /// Opens the list properties sheet (name + icon + color). Tap-to-rename on
    /// the title stays as-is; this is the entry point for icon/color editing.
    let onProperties: () -> Void

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
            Button(action: onProperties) {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityLabel("List appearance")
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
        let accent = list.resolvedColor
        HStack(spacing: Space.md) {
            // Per-list identity chip: colored square + SF Symbol in the left slot.
            ListIconChip(icon: list.resolvedIcon, color: accent, size: 40)

            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text(list.title)
                        .font(.edBodyMedium)
                        .foregroundStyle(Tokens.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Tokens.mutedSoft)
                }
                if total > 0 {
                    HStack(spacing: Space.xs) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Tokens.paper2).frame(height: 4)
                                Capsule()
                                    .fill(accent)
                                    .frame(width: geo.size.width * (Double(completed) / Double(max(total, 1))), height: 4)
                            }
                        }
                        .frame(height: 4)
                        Text("\(completed)/\(total)")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .monospacedDigit()
                    }
                } else {
                    Text("Empty")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.md)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .paperBorder(Tokens.border, radius: 26)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

private struct ListDetailContent: View {
    @Bindable var viewModel: ListsViewModel
    let listId: UUID
    @State private var newItemText: String = ""
    // Tap-below inline draft state. Modelled the same way as TasksView:
    // a boolean flag for "draft active" plus a non-optional String for the
    // text. The earlier optional-binding pattern (`Binding($draftText)` from
    // a `String?`) crashed when commitDraft set draftText = nil while the
    // TextField was still mid-edit.
    @State private var draftActive: Bool = false
    @State private var draftText: String = ""
    @FocusState private var draftFocused: Bool
    // Item Details sheet: holds the item currently being edited (with its array
    // index, needed to route the save through the view-model's index-based API).
    @State private var editingItem: EditingItem?
    // New-item flow (FAB): presents the Item Details popover in editable-name
    // mode. Nothing is created until Save — Cancel creates nothing.
    @State private var creatingItem = false

    var body: some View {
        if let list = viewModel.lists.first(where: { $0.id == listId }) {
            VStack(spacing: 0) {
                // Header strip — count + "Edit" affordance is implicit via long-press.
                // Tapping the strip while a draft is active dismisses the draft.
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
                .contentShape(Rectangle())
                // Tapping the header strip commits any in-progress edit: draftFocused = false
                // covers the tap-below draft; hideKeyboard() covers a focused item row.
                .onTapGesture { draftFocused = false; hideKeyboard() }

                Rectangle().fill(Tokens.divider).frame(height: 0.5)
                    .padding(.horizontal, Space.lg)

                // Items list — always rendered so tap-below works even when empty.
                // Chrome stripped to keep the editorial calm look.
                List {
                    // Existing items live in their own section so .onMove stays scoped to them.
                    Section {
                        // Empty state row — only when no items and no draft is active.
                        if list.items.isEmpty && !draftActive {
                            Text("No items yet. Add one below.")
                                .font(.edBody)
                                .foregroundStyle(Tokens.muted)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, Space.lg)
                                .listRowBackground(Tokens.paper)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: Space.lg, bottom: 2, trailing: Space.lg))
                        }

                        // Keyed by item.id (UUID) — not array offset — so the
                        // checked-to-bottom reorder animates as a move rather
                        // than a cross-fade. The per-iteration `index` is still
                        // the row's current array position, which is what the
                        // view-model methods take.
                        ForEach(Array(list.items.enumerated()), id: \.element.id) { index, item in
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
                                onOpenDetails: {
                                    editingItem = EditingItem(index: index, item: item)
                                },
                                isDraftActive: draftActive,
                                onTapWhileDraftActive: { draftFocused = false }
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
                        if draftActive {
                            // Draft is active: show an inline editable row mirroring ItemRow.
                            DraftItemRow(
                                text: $draftText,
                                isFocused: $draftFocused,
                                onSubmit: { commitDraft(in: list, keepFocus: true) },
                                onFocusLost: { commitDraft(in: list, keepFocus: false) }
                            )
                            .listRowBackground(Tokens.paper)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: Space.lg, bottom: 2, trailing: Space.lg))
                        }
                        // Add strip — one row-height tap target right after the last item.
                        // Tapping here starts a new item (or dismisses an active draft).
                        Color.clear
                            .frame(height: 44)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if draftActive { draftFocused = false; hideKeyboard() }
                                else { startDraft() }
                            }
                            .listRowBackground(Tokens.paper)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())

                        // Dismiss filler — the rest of the empty space below. Tapping here only
                        // commits/deselects the current inline edit (or draft); it never adds.
                        Color.clear
                            .frame(minHeight: 160)
                            .contentShape(Rectangle())
                            .onTapGesture { draftFocused = false; hideKeyboard() }
                            .listRowBackground(Tokens.paper)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
                .scrollDismissesKeyboard(.interactively)
                // Floating "+" FAB, matching the app-wide root FAB. Scoped to the
                // List (not the outer VStack) so its bottom edge sits right at the
                // top of the docked addItemBar — it floats just above the bar with
                // no hardcoded offsets. Hidden while an inline draft is active so it
                // never covers the row being typed (mirrors TasksView).
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        creatingItem = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
                    .padding(.trailing, 22)
                    .padding(.bottom, Space.sm)
                    .opacity(draftActive ? 0 : 1)
                    .animation(.easeOut(duration: 0.15), value: draftActive)
                }

                addItemBar(list: list)
                    // Tapping the addItemBar commits any in-progress edit: draftFocused = false
                    // covers the tap-below draft; hideKeyboard() covers a focused item row.
                    // simultaneousGesture fires alongside the inner TextField tap so the
                    // bar's own text field can still receive focus normally.
                    .simultaneousGesture(TapGesture().onEnded { draftFocused = false; hideKeyboard() })
            }
            .sheet(item: $editingItem) { editing in
                // Guard against a stale index if the list mutated while the sheet
                // was queued — clamp to the current name for the header.
                ItemDetailsSheet(
                    itemName: editing.item.text,
                    initialURL: editing.item.url,
                    onSave: { newURL in
                        Task { await viewModel.setItemURL(in: list, at: editing.index, to: newURL) }
                    },
                    onDelete: {
                        Haptics.destructive()
                        Task { await viewModel.removeItem(from: list, at: editing.index) }
                    }
                )
            }
            .sheet(isPresented: $creatingItem) {
                // New-item mode: editable name + link. Creation is deferred to
                // Save so Cancel leaves no orphan blank item. addItem inserts at
                // index 0, so a supplied URL is applied to index 0 right after.
                ItemDetailsSheet(
                    itemName: "",
                    initialURL: "",
                    onSave: { _ in },
                    onDelete: {},
                    nameEditable: true,
                    onCreate: { name, url in
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedName.isEmpty else { return }
                        Task {
                            await viewModel.addItem(to: list, text: trimmedName)
                            if !url.isEmpty {
                                await viewModel.setItemURL(in: list, at: 0, to: url)
                            }
                        }
                    }
                )
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
        draftActive = true
        draftText = ""
        // Give the List time to insert the DraftItemRow into the hierarchy before focusing.
        DispatchQueue.main.async { draftFocused = true }
    }

    /// Commits whatever is in draftText.
    /// - keepFocus: true = chain creation (Return key path); false = dismiss (focus-loss path).
    private func commitDraft(in list: Checklist, keepFocus: Bool) {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty draft: silently dismiss.
            draftActive = false
            draftText = ""
            draftFocused = false
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
            draftActive = false
            draftText = ""
            draftFocused = false
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
    /// Opens the Item Details sheet (ⓘ button on every row).
    let onOpenDetails: () -> Void
    /// When a tap-below draft is active in the parent, suppress beginEditing so the
    /// tap only dismisses the draft keyboard — nothing re-steals first responder.
    var isDraftActive: Bool = false
    /// Called back to the parent when this row is tapped while a draft is active,
    /// so the parent can flip draftFocused = false and trigger the focus-loss → commitDraft cycle.
    var onTapWhileDraftActive: () -> Void = {}

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: Space.md) {
            // Empty Button action: the high-priority tap gesture below is the single
            // source of the toggle. This guarantees one toggle per tap even while the
            // inline field is focused (iOS's "first tap dismisses keyboard" would
            // otherwise eat a plain row/Button tap).
            Button(action: {}) {
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
            .highPriorityGesture(TapGesture().onEnded { handleToggle() })

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
            Spacer(minLength: Space.sm)

            // Link chip — only when the item has a resolvable URL. Its own tap
            // target (buttonStyle .plain) opens the link and does NOT fall
            // through to the row's rename tap. Mirrors the TasksView MAP chip.
            if !isEditing, let url = item.linkURL {
                Button {
                    openURL(url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 10, weight: .regular))
                        Text("LINK")
                            .font(.edEyebrow)
                            .textCase(.uppercase)
                            .tracking(1.4)
                    }
                    .foregroundStyle(Tokens.accentLists)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Tokens.accentLists.opacity(0.12), in: Capsule(style: .continuous))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open link")
            }

            // Info button — on every row, low-contrast. Opens Item Details.
            // Its own tap target so it never triggers the row's inline rename.
            if !isEditing {
                Button(action: onOpenDetails) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Tokens.mutedSoft)
                        .frame(width: 30, height: 30, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Item details")
            }
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.md)
        .contentShape(Rectangle())
        .onTapGesture {
            // When a tap-below draft is active, actively flip draftFocused in the parent
            // so the focus-loss → commitDraft → dismiss cycle fires immediately.
            // We still return early so this row does not enter its own edit flow.
            if isDraftActive {
                onTapWhileDraftActive()
                return
            }
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

    /// Single-tap toggle. If the row is mid inline-edit, persist any rename first
    /// (commit ends editing), then always toggle checked state.
    private func handleToggle() {
        if isEditing { commit() }
        onToggle()
    }
}

/// Identifies the list item currently open in the details sheet. The index is
/// the item's position in the list at the moment the sheet was opened — the save
/// routes through the view-model's index-based `setItemURL`.
private struct EditingItem: Identifiable {
    let index: Int
    let item: ChecklistItem
    var id: UUID { item.id }
}

/// Item Details sheet. Framed around item properties (currently just the link)
/// so more fields can be added later without renaming the surface. Structurally
/// modelled on TaskEditorSheet.
private struct ItemDetailsSheet: View {
    let itemName: String
    let initialURL: String
    let onSave: (String) -> Void
    let onDelete: () -> Void
    /// New-item mode: the name becomes an editable text field and Save routes
    /// through `onCreate(name, url)` instead of `onSave(url)`. Defaults to false
    /// so the existing (edit-an-existing-item) caller is unchanged.
    var nameEditable: Bool = false
    /// Called on Save in new-item mode with the entered (name, url). Nil for the
    /// existing-item path, which keeps using `onSave`.
    var onCreate: ((String, String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var nameText: String = ""
    @State private var urlText: String = ""
    @State private var showingDeleteConfirmation = false
    @FocusState private var nameFocused: Bool

    /// Save is only blocked in new-item mode with an empty name. Existing-item
    /// edits can always save (URL may legitimately be cleared).
    private var canSave: Bool {
        !nameEditable || !nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The current field value coerced into a URL (bare host → https). `nil`
    /// when empty, so the Open button stays hidden. Mirrors TaskEditorSheet.
    private var editorURL: URL? {
        let stored = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return nil }
        if let u = URL(string: stored), u.scheme != nil { return u }
        return URL(string: "https://\(stored)")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                            Text("Item").eyebrow()
                            if nameEditable {
                                TextField("Type item name…", text: $nameText)
                                    .focused($nameFocused)
                                    .font(.edBody)
                                    .foregroundStyle(Tokens.ink)
                                    .padding(Space.md)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                    .paperBorder(Tokens.border, radius: Radius.md)
                            } else {
                                Text(itemName)
                                    .font(.edBody)
                                    .foregroundStyle(Tokens.ink)
                                    .padding(Space.md)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                    .paperBorder(Tokens.border, radius: Radius.md)
                            }
                        }
                        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                            Text("Link (URL)").eyebrow()
                            HStack(spacing: Space.sm) {
                                TextField("Paste a link", text: $urlText)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .keyboardType(.URL)
                                    .font(.edBody)
                                    .foregroundStyle(Tokens.ink)
                                    .padding(Space.md)
                                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                    .paperBorder(Tokens.border, radius: Radius.md)
                                if let url = editorURL {
                                    Button {
                                        openURL(url)
                                    } label: {
                                        Image(systemName: "arrow.up.right.square")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(Tokens.accentLists)
                                            .frame(width: 48, height: 48)
                                            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                            .paperBorder(Tokens.border, radius: Radius.md)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Open link")
                                }
                            }
                        }

                        // Canonical destructive action, matching the itinerary
                        // item editor. Confirmation dialog before the delete;
                        // routes through the same removeItem path the row swipe /
                        // context menu uses. Hidden in new-item mode — there's
                        // nothing to delete until Save creates the item.
                        if !nameEditable {
                            DeleteRowButton(title: "Delete item") {
                                showingDeleteConfirmation = true
                            }
                            .padding(.top, Space.sm)
                        }
                    }
                    .padding(Space.lg)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(nameEditable ? "New item" : "Item details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if nameEditable {
                            onCreate?(nameText.trimmingCharacters(in: .whitespacesAndNewlines), url)
                        } else {
                            onSave(url)
                        }
                        dismiss()
                    }
                    .foregroundStyle(canSave ? Tokens.ink : Tokens.muted)
                    .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "Delete this item?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
            .onAppear {
                urlText = initialURL
                nameText = itemName
                // Auto-focus the name field in new-item mode so the keyboard is
                // up and the cursor active immediately. Deferred to the next
                // runloop tick — SwiftUI drops focus set too early in a freshly
                // presented sheet (same pattern as startDraft's focus set).
                if nameEditable {
                    DispatchQueue.main.async { nameFocused = true }
                }
            }
        }
    }
}

private struct NewListSheet: View {
    let viewModel: ListsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""

    /// Live inferred appearance from the title so the user sees the identity the
    /// keyword mapper will assign. If they never open the picker, this is what
    /// gets saved (create() defaults to the same inference).
    private var inferred: (icon: String, colorHex: String) {
        ListAppearance.infer(from: title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                VStack(alignment: .leading, spacing: Space.lg) {
                    HStack(spacing: Space.md) {
                        ListIconChip(
                            icon: ListAppearance.resolvedIconName(inferred.icon),
                            color: ListAppearance.color(forHex: inferred.colorHex),
                            size: 44
                        )
                        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                            Text("Title").eyebrow()
                            TextField("List title", text: $title)
                                .font(.edBody)
                                .foregroundStyle(Tokens.ink)
                                .padding(Space.md)
                                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                .paperBorder(Tokens.border, radius: Radius.md)
                        }
                    }
                    Text("An icon and color are picked automatically from the title. You can change them later from the list.")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                    Spacer()
                }
                .padding(Space.lg)
            }
            .animation(.easeOut(duration: 0.2), value: inferred.colorHex)
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

/// Edit a list's name, icon, and color. Reached from the header's appearance
/// button. Applying routes through `updateAppearance`, so the tile + Today row
/// reflect the change immediately.
private struct ListPropertiesSheet: View {
    let viewModel: ListsViewModel
    let list: Checklist
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedIcon: String = ListAppearance.defaultIcon
    @State private var selectedColorHex: String = ListAppearance.defaultColorHex

    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 6)

    private var accent: Color { ListAppearance.color(forHex: selectedColorHex) }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        // Live preview + name field.
                        HStack(spacing: Space.md) {
                            ListIconChip(icon: selectedIcon, color: accent, size: 48)
                            VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                                Text("Name").eyebrow()
                                TextField("List name", text: $name)
                                    .font(.edBody)
                                    .foregroundStyle(Tokens.ink)
                                    .padding(Space.md)
                                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                                    .paperBorder(Tokens.border, radius: Radius.md)
                            }
                        }

                        // Color swatches.
                        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
                            Text("Color").eyebrow()
                            HStack(spacing: Space.sm) {
                                ForEach(ListAppearance.palette) { swatch in
                                    let isSelected = swatch.id == selectedColorHex
                                    Circle()
                                        .fill(swatch.color)
                                        .frame(width: 34, height: 34)
                                        .overlay(
                                            Circle()
                                                .stroke(Tokens.ink, lineWidth: isSelected ? 2 : 0)
                                                .padding(-3)
                                        )
                                        .overlay {
                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 13, weight: .bold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                        .contentShape(Circle())
                                        .onTapGesture {
                                            Haptics.tick()
                                            withAnimation(.easeOut(duration: 0.15)) { selectedColorHex = swatch.id }
                                        }
                                        .accessibilityLabel(swatch.name)
                                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                                }
                                Spacer(minLength: 0)
                            }
                        }

                        // Icon grid, grouped by theme.
                        VStack(alignment: .leading, spacing: Space.md) {
                            Text("Icon").eyebrow()
                            ForEach(ListAppearance.iconGroups) { group in
                                VStack(alignment: .leading, spacing: Space.sm) {
                                    Text(group.id)
                                        .font(.edCaption)
                                        .foregroundStyle(Tokens.muted)
                                    LazyVGrid(columns: iconColumns, spacing: Space.sm) {
                                        ForEach(group.symbols, id: \.self) { symbol in
                                            iconCell(symbol)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(Space.lg)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("List appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await viewModel.updateAppearance(
                                list,
                                iconName: selectedIcon,
                                colorHex: selectedColorHex,
                                title: trimmed.isEmpty ? nil : trimmed
                            )
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .foregroundStyle(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Tokens.muted : Tokens.ink)
                }
            }
            .onAppear {
                name = list.title
                selectedIcon = list.resolvedIcon
                // Resolve to a palette key so the matching swatch highlights even
                // when the stored value is a name or unknown hex.
                selectedColorHex = ListAppearance.matchedPaletteColor(list.colorHex)?.id
                    ?? ListAppearance.defaultColorHex
            }
        }
    }

    private func iconCell(_ symbol: String) -> some View {
        let isSelected = symbol == selectedIcon
        return RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(isSelected ? accent.opacity(0.16) : Tokens.surface)
            .frame(height: 46)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? accent : Tokens.inkSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(isSelected ? accent : Tokens.border, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.tick()
                withAnimation(.easeOut(duration: 0.12)) { selectedIcon = symbol }
            }
            .accessibilityLabel(symbol)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
