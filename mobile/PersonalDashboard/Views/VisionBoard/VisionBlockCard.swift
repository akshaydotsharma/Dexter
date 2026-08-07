import SwiftUI

#if os(macOS)
import AppKit

/// One block on the vision board (#446).
///
/// Renders at three tiers driven by the block's OWN column count, never the
/// window's, and re-tiers live during a resize — growing from one column to two
/// makes tiles appear under your hand, which is the point of the exercise and
/// must not be deferred to drop.
///
/// The card draws and nothing else. Every click that lands on its chrome — the
/// drag, the resize, selection, the click on empty canvas — belongs to
/// `VisionPointerView`, which sits on top of the whole canvas. Its own
/// interactive children keep their clicks by publishing their frames with
/// `.visionPassThrough()`, which is what makes the layer above transparent over
/// them.
///
/// The card used to be `.focusable()` and to own the keyboard. Both are gone.
/// `.focusable()` is the prime suspect for having eaten the block's mouse-down
/// all along — SwiftUI handles a click on a focusable view through its own
/// responder path, before any gesture sees it — and the keyboard moved with it
/// to `VisionPointerView.keyDown`, because removing an accessible route rather
/// than relocating it would not have been a fix.
struct VisionBlockCard: View {
    let viewModel: VisionBoardViewModel
    /// The block to render. During a resize the board passes a copy with the
    /// QUANTISED `w`/`h`, so everything derived from cells — the tier, the tile
    /// capacity, the dimension readout — recomputes from one source and changes
    /// once per cell crossed.
    let block: VisionBlock
    /// The card's rendered size in points, when that is not simply the block's
    /// cell size. Non-nil only during a resize, where the edge has to sit under
    /// the pointer between cells; the two diverge by up to half a cell, and
    /// tiering off this instead of off `block` is what would make the interior
    /// flicker on every boundary.
    let liveSize: CGSize?
    let isSelected: Bool
    /// Whether the pointer is over this block. Supplied by the board rather than
    /// read with `.onHover`, because the pointer layer covers every card and
    /// AppKit, not SwiftUI, is what now knows where the mouse is.
    let isHovered: Bool
    let isDragging: Bool
    let isResizing: Bool
    /// True while a tile from another block is being dragged over this one.
    let isDropTarget: Bool
    /// Keyboard cursor within this block's tile stack, or nil when the cursor is
    /// elsewhere. Lives in `VisionInteraction` now that the key handling does.
    let tileCursor: Int?
    /// A block created a moment ago opens with its title selected, so naming it
    /// is the same motion as making it. The card consumes the flag on appear.
    let beginsInTitleEdit: Bool
    let onTitleEditBegan: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hovering: Bool { isHovered }
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    @State private var addDraft = ""
    @FocusState private var addFocused: Bool
    @State private var showingAllTiles = false
    @State private var showingAttach = false
    /// What the add row's field will make on Return.
    @State private var addKind: VisionAddKind = .task
    /// The note currently holding a caret, or nil.
    ///
    /// Owned here rather than by `VisionNoteRow` so that starting an edit on one
    /// note ends it on any other by construction, and so that a note created
    /// from the menu can be opened in edit by the code that created it.
    @State private var editingNoteID: UUID?

    /// Continuous while a resize is in hand or settling, the block's cell size
    /// otherwise. When the session finally clears, this expression flips from
    /// one to the other inside the settle spring, which IS the spring into the
    /// target size — there is no separate animation to keep in step.
    private var renderedSize: CGSize {
        liveSize ?? VisionGrid.blockSize(columns: block.w, rows: block.h)
    }

    private var style: VisionBlockStyle { VisionBlockStyle(state: block.state) }
    private var tier: VisionBlockTier { block.tier }
    private var tiles: [Todo] { viewModel.tiles(for: block) }
    private var urgency: VisionUrgency { VisionUrgency.derive(from: tiles) }
    private var hasIntent: Bool { !(block.intent ?? "").isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            VisionStateRail(style: style)
            interior
        }
        .frame(
            width: renderedSize.width,
            height: renderedSize.height,
            alignment: .top
        )
        .background(style.bodyFill)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(borderOverlay)
        .overlay(selectionHalo)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .overlay { dimensionReadout }
        .modifier(BlockShadow(dragging: isDragging, hovering: hovering))
        .scaleEffect(isDragging ? 1.02 : 1.0)
        .opacity(isDragging ? 0.92 : 1.0)
        // No hover scale, on purpose. On this board size IS meaning: a block
        // that grows on hover makes a claim it does not mean, and on a dense
        // board the growth would overlap its neighbours.
        .animation(motion(.easeOut(duration: 0.12)), value: hovering)
        // No gesture and no `contentShape`. The card is inert to the pointer;
        // `VisionPointerView` above it resolves every click against
        // `VisionHitTest` and drives `VisionInteraction` directly. Nothing
        // card-spanning may be added back here — a recogniser on the card is
        // exactly what made the drag unreachable in the first place, and now it
        // would simply never fire, which is worse because it would look like a
        // wiring mistake rather than a precedence one.
        .onAppear {
            guard beginsInTitleEdit else { return }
            beginTitleEdit()
            onTitleEditBegan()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Arrow keys move this block. Option and arrow keys resize it.")
    }

    // MARK: - Interior

    private var interior: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if tier != .small, hasIntent {
                Text(block.intent ?? "")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
                    .padding(.top, Space.xxs)
            }
            if !tiles.isEmpty {
                metaLine.padding(.top, Space.xs)
            }
            if tier != .small {
                contentStack.padding(.top, Space.md)
            }
            Spacer(minLength: 0)
            if tier == .large {
                addRow
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Header

    /// `.top`, not `.firstTextBaseline`.
    ///
    /// The trailing half of this row holds a `Menu` and a `Capsule`, neither of
    /// which has a text baseline, so a baseline-aligned stack would resolve
    /// theirs from their own bottom edge and drag the glyph and the title down
    /// with them. The leading group keeps a baseline stack internally, which is
    /// where it actually matters (a 10pt glyph beside 13pt type).
    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Image(systemName: block.state.glyph)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(style.hue)
                    .accessibilityHidden(true)

                if tier == .large {
                    // The explicit text carrier for state, at the size where
                    // there is room for it. Overridden to the state hue rather
                    // than the eyebrow default, which is why `Eyebrow` now
                    // takes a colour.
                    Text(block.state.eyebrow)
                        .eyebrow(style.hue)
                        .padding(.leading, Space.xs)
                }

                titleView
                    .padding(.leading, Space.sm)
            }

            Spacer(minLength: Space.sm)

            // At medium and large the chip lives here, at the header's trailing
            // edge. At small it moves down to the meta line: 172pt of width has
            // to go to the title, and the spec's size-specific layout wins over
            // the generic header diagram above it.
            if tier != .small, !style.suppressesUrgency {
                VisionUrgencyChip(urgency: urgency, tier: tier)
            }

            ellipsisSlot
        }
        .help("\(block.state.displayName). \(urgency.accessibilityPhrase)")
    }

    @ViewBuilder
    private var titleView: some View {
        if editingTitle {
            // Inter SemiBold, not the field's Regular default. `.edHeading` and
            // `.edBody` are both 13pt on macOS and differ only in weight, so the
            // default would change the title's weight the instant it is clicked.
            MacClearTextField(
                placeholder: "Untitled",
                text: $titleDraft,
                // `MacClearTextField` takes a plain `Binding<Bool>`; bridging
                // from `@FocusState` by hand is the same shape the Tasks add-row
                // uses, and `FocusState.wrappedValue`'s setter is nonmutating so
                // the closure is legal inside `body`.
                isFocused: Binding(get: { titleFocused }, set: { titleFocused = $0 }),
                onSubmit: { commitTitle() },
                onFocusChange: { focused in if !focused { commitTitle() } },
                fontName: "Inter-SemiBold"
            )
            .frame(height: VisionBlockMetrics.titleLine)
            .visionPassThrough(cursor: .text)
        } else {
            Text(block.title)
                .font(.edHeading)
                .foregroundStyle(style.titleColor)
                .lineLimit(tier == .small ? 1 : 2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                // Single click, caret lands in it. Never a long press, never a
                // context-menu Rename. The tap survives the pointer layer above
                // because the title publishes its own rect.
                .onTapGesture { beginTitleEdit() }
                // `.text`, so the pointer says "caret goes here" rather than
                // wearing the block's open hand. A hand over a title promises a
                // move and delivers an edit.
                .visionPassThrough(cursor: .text)
        }
    }

    private func beginTitleEdit() {
        titleDraft = block.title
        editingTitle = true
        titleFocused = true
    }

    /// Always 24 × 24, `opacity 0` until hover. Reserved rather than inserted so
    /// hovering a block shifts nothing.
    private var ellipsisSlot: some View {
        Menu {
            Picker("State", selection: stateBinding) {
                ForEach(BlockState.allCases) { state in
                    Label(state.displayName, systemImage: state.glyph).tag(state)
                }
            }
            Divider()
            Button("Attach existing task…") { showingAttach = true }
            // Here as well as on the add row, because the add row only exists at
            // large and a medium block has to be able to take a note too.
            Button("Add note") { addNote() }
            Divider()
            Button(role: .destructive) {
                Task { await viewModel.deleteBlock(block.id) }
            } label: {
                Label("Delete block", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.muted)
                .frame(width: VisionBlockMetrics.ellipsisSlot, height: VisionBlockMetrics.ellipsisSlot)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: VisionBlockMetrics.ellipsisSlot, height: VisionBlockMetrics.ellipsisSlot)
        .opacity(hovering ? 1 : 0)
        // The slot is always hittable now, not gated on `hovering` the way it
        // was. Its rect is published to the pointer layer unconditionally — a
        // dead zone that only sometimes accepts a click is worse than an
        // invisible control, and you cannot reach this corner without hovering
        // it, which is what makes it visible.
        .visionPassThrough()
        .accessibilityLabel("Block actions")
        .macAnchoredPopover(isPresented: $showingAttach, preferredEdge: .minY) {
            VisionAttachTaskPopover(viewModel: viewModel, blockID: block.id) {
                showingAttach = false
            }
        }
    }

    private var stateBinding: Binding<BlockState> {
        Binding(
            get: { block.state },
            set: { newValue in Task { await viewModel.setState(block.id, to: newValue) } }
        )
    }

    // MARK: - Progress and urgency

    /// Derived: completed tiles over total. MONOCHROME, always. Progress is not
    /// state and must not borrow state's colour, or the block would carry the
    /// same signal three times and the eye would start reading progress as
    /// urgency.
    ///
    /// Suppressed entirely on an empty block. `0/0` is noise, not information.
    private var metaLine: some View {
        let done = tiles.filter(\.completed).count
        let total = tiles.count

        return HStack(spacing: Space.sm) {
            if tier != .small {
                Capsule()
                    .fill(Tokens.border)
                    .frame(maxWidth: 88)
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(style.progressFill)
                                .frame(width: proxy.size.width * fraction(done, total))
                        }
                    }
                    .accessibilityHidden(true)
            }

            Text("\(done)/\(total)")
                .font(.edCaption)
                .foregroundStyle(style.state == .done ? Tokens.inkSoft : Tokens.muted)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(motion(.easeOut(duration: 0.18)), value: done)

            if tier == .small {
                Spacer(minLength: Space.xs)
                if !style.suppressesUrgency {
                    VisionUrgencyChip(urgency: urgency, tier: tier)
                }
            }
        }
        .frame(height: VisionBlockMetrics.metaLine)
    }

    private func fraction(_ done: Int, _ total: Int) -> CGFloat {
        total > 0 ? CGFloat(done) / CGFloat(total) : 0
    }

    // MARK: - Contents

    /// The block's notes and then its tiles, in one stack.
    ///
    /// One stack rather than two, because they share a height budget and a
    /// `+N more` button. Notes come first: reading order on a block runs from
    /// what it is to what is left to do, and the lines that exist only here
    /// outrank the ones you can also see in Tasks.
    @ViewBuilder
    private var contentStack: some View {
        let fit = contentFit
        let shownNotes = visibleNotes(limit: fit.notes)
        let shownTiles = Array(tiles.prefix(fit.tiles))

        VStack(alignment: .leading, spacing: VisionBlockMetrics.tileSpacing) {
            if !shownNotes.isEmpty {
                VStack(alignment: .leading, spacing: VisionBlockMetrics.noteSpacing) {
                    ForEach(shownNotes) { note in
                        VisionNoteRow(
                            note: note,
                            isEditing: editingNoteID == note.id,
                            onBeginEdit: { editingNoteID = note.id },
                            onCommit: { text in commitNote(note, to: text) },
                            onDelete: {
                                editingNoteID = nil
                                Task { await viewModel.deleteNote(note.id, from: block.id) }
                            }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            if tiles.isEmpty, block.notes.isEmpty {
                // Never an empty tile skeleton: a bordered empty rectangle reads
                // as a broken tile, not as an invitation. Suppressed once there
                // are notes — a block with three lines on it is not empty, and
                // saying so under them would be arguing with what is on screen.
                Text("No tasks yet")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.mutedSoft)
            }

            ForEach(Array(shownTiles.enumerated()), id: \.element.id) { index, todo in
                VisionTileRow(
                    todo: todo,
                    showsDue: true,
                    onToggle: { toggle(todo) },
                    onRemove: { Task { await viewModel.detach(taskID: todo.id, from: block.id) } },
                    onDelete: { Task { await viewModel.deleteTask(todo.id, from: block.id) } }
                )
                .overlay {
                    if tileCursor == index {
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .stroke(Tokens.accentVision, lineWidth: 1)
                    }
                }
                .draggable(todo.id.uuidString)
                // The whole row: the checkbox, the context menu, the remove
                // button, and the drag that moves a task to another block all
                // belong to SwiftUI and all need the pointer layer to step
                // aside.
                .visionPassThrough()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if fit.hidden > 0 {
                Button {
                    showingAllTiles = true
                } label: {
                    Text("+\(fit.hidden) more")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
                .buttonStyle(.plain)
                .visionPassThrough()
                .macAnchoredPopover(isPresented: $showingAllTiles, preferredEdge: .minY) {
                    VisionAllTilesPopover(
                        viewModel: viewModel,
                        block: block,
                        onToggle: { toggle($0) }
                    )
                }
            }
        }
        .animation(motion(.easeOut(duration: 0.18)), value: tiles.map(\.id))
        .animation(motion(.easeOut(duration: 0.18)), value: block.notes.map(\.id))
    }

    /// The first `limit` notes, except that the one being edited is always among
    /// them.
    ///
    /// Notes append, so a block already showing its maximum puts the note you
    /// just asked for beyond the fold — and a caret you cannot see, in a field
    /// that commits on blur, silently eats what you type. The one being edited
    /// takes the last visible slot instead, which keeps the row count and the
    /// `+N more` total exactly where they were.
    private func visibleNotes(limit: Int) -> [VisionNote] {
        var shown = Array(block.notes.prefix(limit))
        guard
            let editingNoteID,
            !shown.contains(where: { $0.id == editingNoteID }),
            let editing = block.notes.first(where: { $0.id == editingNoteID })
        else { return shown }
        // Nothing fit at all, so one row overflows for the length of the edit.
        // Better than a field with no pixels, which is the alternative.
        if !shown.isEmpty { shown.removeLast() }
        shown.append(editing)
        return shown
    }

    /// How many notes and tiles this block shows.
    ///
    /// The arithmetic itself is in `VisionContentFit`, which is pure and unit
    /// tested. What is left here is the budget: how much height the card has
    /// after its own chrome.
    ///
    /// Measured by arithmetic and never by a `GeometryReader`, which would be
    /// reading back a height this card set itself (`rows × cellHeight - gutter`)
    /// and, during a resize, feeding the layout into itself — the hazard
    /// `TripCoverMetrics` documents. Deliberately conservative: it always
    /// reserves two lines for the title, so a one-line title shows one fewer row
    /// than it strictly could. The other way round clips the add row off the
    /// bottom of the card, and only one of those is a visual defect.
    private var contentFit: VisionContentFit.Fit {
        guard tier != .small else { return .init(notes: 0, tiles: 0, hidden: 0) }

        var budget = VisionGrid.blockSize(columns: block.w, rows: block.h).height
        budget -= VisionGrid.railHeight
        budget -= Space.md * 2                              // card padding
        budget -= VisionBlockMetrics.titleLine * 2          // title, worst case
        if hasIntent { budget -= VisionBlockMetrics.intentLine + Space.xxs }
        if !tiles.isEmpty { budget -= VisionBlockMetrics.metaLine + Space.xs }
        budget -= Space.md                                  // gap above the stack
        if tier == .large { budget -= VisionBlockMetrics.addRowBlock }

        // The cap of 3 holds even on a tall medium block. A 2 × 8 block showing
        // twelve tiles is exactly the "300 lines of task text" failure the
        // concept doc rules out; the `+N more` row anchors to the foot and the
        // space between is left empty, which is the honest rendering of "you
        // made this tall, and medium blocks do not list everything".
        return VisionContentFit.fit(
            budget: budget,
            notes: block.notes.count,
            tiles: tiles.count,
            tileCeiling: tier == .medium ? 3 : .max
        )
    }

    /// Commit an edited note and leave edit mode.
    ///
    /// Empty text removes the note; the service owns that rule so the `+` route,
    /// the popover and this all agree about it. Unchanged text writes nothing —
    /// clicking a note and clicking away should not bump `updatedAt` and make
    /// the block look edited.
    private func commitNote(_ note: VisionNote, to text: String) {
        editingNoteID = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != note.text else { return }
        Task { await viewModel.setNoteText(note.id, in: block.id, to: trimmed) }
    }

    /// Add a note and drop a caret straight into it.
    ///
    /// The row appears blank and in edit, which is the same motion as making a
    /// block. If the user types nothing and clicks away, committing empty text
    /// deletes it again, so an abandoned add leaves the card exactly as it was.
    private func addNote() {
        Task {
            guard let id = await viewModel.addNote(to: block.id) else { return }
            editingNoteID = id
        }
    }

    /// The 400ms pause before a completed tile sinks. Without it the tile
    /// disappears out from under the pointer at the moment of the click, and the
    /// click feels like it did something else. The delay lets you see the check
    /// land on the row you actually clicked, then the row leaves.
    private func toggle(_ todo: Todo) {
        Task {
            await viewModel.toggleTask(todo.id, sinkDelay: reduceMotion ? nil : .milliseconds(400))
        }
    }

    // MARK: - Add row (large only)

    /// Always visible at large, never hover-revealed: hiding the create
    /// affordance on the primary authoring surface would be wrong.
    private var addRow: some View {
        VStack(spacing: Space.sm) {
            // `Tokens.border`, not `Tokens.divider`. The block body is
            // `surface`, and divider is unreliable on light surfaces in light
            // mode — a trap this codebase has already hit.
            Rectangle()
                .fill(Tokens.border)
                .frame(height: 0.5)

            HStack(spacing: Space.sm) {
                addKindMenu

                MacClearTextField(
                    placeholder: addKind.placeholder,
                    text: $addDraft,
                    isFocused: Binding(get: { addFocused }, set: { addFocused = $0 }),
                    onSubmit: { commitAddRow() },
                    onFocusChange: { _ in },
                    placeholderColor: Tokens.mutedSoft
                )
            }
            .padding(.horizontal, Space.sm)
            .frame(height: 26)
            // On focus the row takes the shape of a tile, previewing what it is
            // about to create.
            .background(
                addFocused ? Tokens.surface2 : Color.clear,
                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
            .visionPassThrough()
        }
        .padding(.top, Space.sm)
    }

    /// Switches what the field makes. The glyph is the answer, so the control
    /// says what it will do before you commit rather than after.
    ///
    /// A menu on the leading glyph rather than a segmented control beside the
    /// field: the add row is 26pt tall inside a card that may be 172pt wide, and
    /// a second visible control would cost more width than the whole feature is
    /// worth. The placeholder text carries the same answer for anyone who does
    /// not read the glyph.
    private var addKindMenu: some View {
        Menu {
            Picker("Add", selection: $addKind) {
                ForEach(VisionAddKind.allCases) { kind in
                    Label(kind.menuLabel, systemImage: kind.glyph).tag(kind)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: addKind.glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Tokens.mutedSoft)
                // Aligns with the tile checkboxes above it.
                .frame(width: 26 - Space.sm, alignment: .center)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26 - Space.sm)
        .help("Add a task or a note")
        .accessibilityLabel("What to add")
    }

    private func commitAddRow() {
        let text = addDraft
        addDraft = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            // Focus is deliberately NOT reset in either branch:
            // `MacClearTextField` keeps the field first responder on Return so
            // you can keep going.
            switch addKind {
            case .task:
                await viewModel.addTask(title: text, to: block.id)
            case .note:
                await viewModel.addNote(to: block.id, text: text)
            }
        }
    }

    private func commitTitle() {
        let text = titleDraft
        editingTitle = false
        titleFocused = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty title reverts. A block is never untitled.
        guard !trimmed.isEmpty, trimmed != block.title else { return }
        Task { await viewModel.rename(block.id, to: trimmed) }
    }

    // MARK: - Chrome

    @ViewBuilder
    private var borderOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        if isSelected {
            // 1pt, the one deliberate departure from the 0.5pt hairline rule in
            // the whole app: selection has to be unambiguous at board zoom and a
            // hairline is not.
            shape.stroke(Tokens.accentVision, lineWidth: 1)
        } else if isDragging {
            shape.stroke(Tokens.accentVision.opacity(0.6), lineWidth: 1)
        } else if isDropTarget {
            shape.stroke(Tokens.accentVision.opacity(0.45), lineWidth: 1)
        } else if let dash = style.borderDash {
            shape.stroke(style.borderColor, style: StrokeStyle(lineWidth: 0.5, dash: dash))
        } else {
            shape.stroke(hovering ? Tokens.borderStrong : style.borderColor, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var selectionHalo: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Radius.card + 2, style: .continuous)
                .stroke(Tokens.accentVision.opacity(0.16), lineWidth: 3)
                .padding(-2)
        }
    }

    /// The Mac scroller-grip idiom. Ships `NSCursor.arrow`: AppKit exposes no
    /// public diagonal resize cursor, and `.crosshair` is wrong (it means
    /// "precise point", not "drag corner"). The visible glyph carries the
    /// affordance.
    ///
    /// Purely a glyph now: `allowsHitTesting(false)` and no gesture at all. The
    /// grip's hit target is `VisionHitTest.gripRect(in:)`, derived from the same
    /// `resizeTarget` and `Space.sm` this padding uses, so what you can see and
    /// what you can grab are one constant rather than two that can drift apart
    /// unnoticed.
    private var resizeGrip: some View {
        ResizeGripShape()
            .stroke(Tokens.mutedSoft, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: VisionBlockMetrics.resizeTarget, height: VisionBlockMetrics.resizeTarget)
            .padding(Space.sm)
            .opacity(hovering || isResizing ? 1 : 0)
            .animation(motion(.easeOut(duration: 0.12)), value: hovering)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// `.edMono` because it is a measurement, and mono keeps the capsule from
    /// jittering in width as the digits change.
    @ViewBuilder
    private var dimensionReadout: some View {
        if isResizing {
            Text("\(block.w) × \(block.h)")
                .font(.edMono)
                .foregroundStyle(Tokens.muted)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xxs)
                .background(Tokens.surface.opacity(0.9), in: Capsule())
                .overlay(Capsule().stroke(Tokens.border, lineWidth: 0.5))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Motion

    /// Every spring and every transition on the board goes through here, so
    /// reduced motion is one decision rather than fifteen. It removes MOVEMENT,
    /// never information: each animation's endpoint still says what it said.
    private func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.15) : animation
    }

    // MARK: - Accessibility

    /// Position and size are read aloud because on this board they ARE content,
    /// not layout.
    private var accessibilityLabel: String {
        let done = tiles.filter(\.completed).count
        var parts = [block.title, block.state.displayName]
        if !style.suppressesUrgency, urgency.rung > 0 {
            parts.append(urgency.accessibilityPhrase)
        }
        parts.append("\(done) of \(tiles.count) tasks")
        parts.append("Column \(block.col + 1), row \(block.row + 1), \(block.w) by \(block.h) cells")
        return parts.joined(separator: ". ")
    }
}

// MARK: - Add kind

/// What the large block's add row is about to make.
///
/// A task leaves the block and goes on to live in Tasks. A note never leaves.
/// That is the entire distinction and it is worth one control, because the two
/// are indistinguishable at the moment of typing and very different afterwards.
enum VisionAddKind: String, CaseIterable, Identifiable {
    case task
    case note

    var id: String { rawValue }

    var placeholder: String {
        switch self {
        case .task: "Add task"
        case .note: "Add note"
        }
    }

    var menuLabel: String {
        switch self {
        case .task: "Task"
        case .note: "Note"
        }
    }

    /// `plus` for a task, keeping the add row exactly as it was for the case
    /// that was already there. `text.append` for a note, which is the closest
    /// thing SF Symbols has to "another line on this list".
    var glyph: String {
        switch self {
        case .task: "plus"
        case .note: "text.append"
        }
    }
}

// MARK: - Shadow

/// `shadowSm` at rest, `shadowMd` on hover, `shadowLg` while dragging. A
/// modifier rather than three chained conditionals so the card body reads as
/// one statement about elevation.
private struct BlockShadow: ViewModifier {
    let dragging: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        if dragging {
            content.shadowLg()
        } else if hovering {
            content.shadowMd()
        } else {
            content.shadowSm()
        }
    }
}

// MARK: - Resize grip glyph

/// Two diagonal strokes, 10pt and 6pt, hugging the bottom-right corner.
private struct ResizeGripShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let long: CGFloat = 10 / 1.4142
        let short: CGFloat = 6 / 1.4142
        path.move(to: CGPoint(x: rect.maxX - long, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - long))
        path.move(to: CGPoint(x: rect.maxX - short, y: rect.maxY - 5))
        path.addLine(to: CGPoint(x: rect.maxX - 5, y: rect.maxY - short))
        return path
    }
}

#endif
