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
    /// Where the caret is, board-wide. Not `@State` here: the rules for moving
    /// it are ordering-sensitive and had to become testable — see
    /// `VisionItemEditor`.
    let editor: VisionItemEditor
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
    /// The board's one open popover, or nil. Not `@State` here for the same
    /// reason `isHovered` is not: the thing that has to CLOSE it on a click is
    /// the AppKit pointer layer, which cannot reach a SwiftUI view's state. See
    /// `VisionInteraction.popover`.
    let openPopover: VisionInteraction.Popover?
    let onPopover: (VisionInteraction.Popover?) -> Void
    /// True while this block's ellipsis menu is on screen, false once it is
    /// gone. Freezes the board's hover for the menu's life so the ellipsis stays
    /// visible under it, and closes any popover, since one thing at a time is
    /// the whole point of a menu.
    let onMenuTracking: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hovering: Bool { isHovered }
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var addDraft = ""
    /// Both plain `@State` rather than `@FocusState`, for the reason recorded on
    /// `VisionTileRow.focused`: SwiftUI owns a `@FocusState` value and resets one
    /// that no view has bound with `.focused(_:)`, so the field mounts unfocused
    /// and the rename needs a second click. `MacClearTextField` takes a plain
    /// `Binding<Bool>` and drives AppKit's first responder itself, which is the
    /// whole reason it exists.
    @State private var titleFocused = false
    @State private var addFocused = false

    /// Bindings onto the board's single popover value. Derived rather than
    /// stored, so two cards can never both believe they have one open.
    private var showingAllTiles: Binding<Bool> {
        popoverBinding(.overflow(block.id))
    }

    private var showingAttach: Binding<Bool> {
        popoverBinding(.attach(block.id))
    }

    private func popoverBinding(_ kind: VisionInteraction.Popover) -> Binding<Bool> {
        Binding(
            get: { openPopover == kind },
            // A false only clears what this binding actually owns. `NSPopover`
            // reports its own close through here, and a report arriving late
            // must not take down a popover that has since opened elsewhere.
            set: { open in
                if open {
                    onPopover(kind)
                } else if openPopover == kind {
                    onPopover(nil)
                }
            }
        )
    }

    /// Continuous while a resize is in hand or settling, the block's cell size
    /// otherwise. When the session finally clears, this expression flips from
    /// one to the other inside the settle spring, which IS the spring into the
    /// target size — there is no separate animation to keep in step.
    private var renderedSize: CGSize {
        liveSize ?? VisionGrid.blockSize(columns: block.w, rows: block.h)
    }

    private var style: VisionBlockStyle { VisionBlockStyle(state: block.state) }
    private var tier: VisionBlockTier { block.tier }
    /// The block's whole list, both kinds, in the order every surface uses.
    private var rows: [VisionRow] { viewModel.rows(for: block) }
    /// Urgency is derived from DUE DATES, which only a task has. An item carries
    /// no date, so it cannot raise or lower the rung — which is right: the chip
    /// answers "is something about to bite", and a line you wrote to yourself
    /// has no deadline to bite you with.
    private var urgency: VisionUrgency { VisionUrgency.derive(from: viewModel.tiles(for: block)) }
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
        // A popover with nothing left to reveal closes itself.
        //
        // It exists to show the rows that do not fit. Once they all fit — the
        // block was made taller, or a row was removed — it is a second copy of
        // the list already on the card, floating over the board, and the control
        // that would dismiss it (`+N more`) is gone too. That is exactly the
        // screenshot reported on 2026-08-07: six items on the card and the same
        // six in a panel below it.
        //
        // Held back while an item is being edited, because the caret may be IN
        // the popover and pulling the panel out from under a half-typed line
        // would lose it. The close then happens when the edit ends, which is the
        // next render.
        .onChange(of: contentFit.hidden) { _, hidden in
            guard hidden == 0, editor.editingID == nil else { return }
            guard openPopover == .overflow(block.id) else { return }
            onPopover(nil)
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
            if !rows.isEmpty {
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
    ///
    /// Visible for as long as anything it opened is on screen, not just while
    /// the pointer is on the card. A menu or a popover with no visible control
    /// behind it is a panel from nowhere — see `ellipsisIsVisible`.
    private var ellipsisSlot: some View {
        MacMenuButton(entries: menuEntries, onTrackingChange: onMenuTracking) {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.muted)
                .frame(width: VisionBlockMetrics.ellipsisSlot, height: VisionBlockMetrics.ellipsisSlot)
                .contentShape(Rectangle())
        }
        .frame(width: VisionBlockMetrics.ellipsisSlot, height: VisionBlockMetrics.ellipsisSlot)
        .opacity(ellipsisIsVisible ? 1 : 0)
        // The slot is always hittable now, not gated on `hovering` the way it
        // was. Its rect is published to the pointer layer unconditionally — a
        // dead zone that only sometimes accepts a click is worse than an
        // invisible control, and you cannot reach this corner without hovering
        // it, which is what makes it visible.
        .visionPassThrough()
        .accessibilityLabel("Block actions")
        .macAnchoredPopover(
            isPresented: showingAttach,
            // The board owns dismissal; see `MacAnchoredPopover.behavior`.
            behavior: .applicationDefined,
            preferredEdge: .minY
        ) {
            VisionAttachTaskPopover(viewModel: viewModel, blockID: block.id) {
                showingAttach.wrappedValue = false
            }
        }
    }

    /// The ellipsis is on screen while the pointer is on the card, and for as
    /// long as anything it opened is still up.
    ///
    /// Hover alone is not enough. An open menu takes the pointer off the card,
    /// and a popover outlives the hover that produced it, so the control that
    /// opened either one would fade out from under it — leaving a panel with
    /// nothing behind it to say where it came from. `menuTracking` covers the
    /// first case by freezing hover for the menu's life; this covers the second.
    private var ellipsisIsVisible: Bool {
        hovering || openPopover == .attach(block.id)
    }

    /// Built on press by `MacMenuButton`, so the state checkmark is current.
    private func menuEntries() -> [MacMenuEntry] {
        var entries: [MacMenuEntry] = [.header("State")]
        entries += BlockState.allCases.map { state in
            .item(
                title: state.displayName,
                systemImage: state.glyph,
                isOn: state == block.state
            ) {
                Task { await viewModel.setState(block.id, to: state) }
            }
        }
        entries.append(.separator)
        entries.append(
            .item(title: "Attach existing task…") { showingAttach.wrappedValue = true }
        )
        entries.append(.separator)
        entries.append(
            .item(title: "Delete block", systemImage: "trash") {
                Task { await viewModel.deleteBlock(block.id) }
            }
        )
        return entries
    }

    // MARK: - Progress and urgency

    /// Derived: completed rows over total, BOTH kinds. An item counts because
    /// `3/8` is a claim about the list you are looking at, and a list where half
    /// the ticks did not move the number would be lying about itself.
    ///
    /// MONOCHROME, always. Progress is not
    /// state and must not borrow state's colour, or the block would carry the
    /// same signal three times and the eye would start reading progress as
    /// urgency.
    ///
    /// Suppressed entirely on an empty block. `0/0` is noise, not information.
    private var metaLine: some View {
        let done = rows.filter(\.completed).count
        let total = rows.count

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

    /// The block's list: its tasks and its own items, one stack, one order.
    ///
    /// One stack because they are one list. The first pass rendered items in
    /// their own group above the tiles, with their own row height and their own
    /// cap, which made the block answer "where is this stored" before it
    /// answered "what is left to do". Order comes from
    /// `VisionBoardViewModel.rows(for:)` so this and the overflow popover cannot
    /// drift apart.
    @ViewBuilder
    private var contentStack: some View {
        let fit = contentFit
        let shown = visibleRows(limit: fit.rows)

        VStack(alignment: .leading, spacing: VisionBlockMetrics.tileSpacing) {
            if rows.isEmpty {
                // Never an empty row skeleton: a bordered empty rectangle reads
                // as a broken tile, not as an invitation.
                Text("Nothing here yet")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.mutedSoft)
            }

            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                rowView(row, cursor: index)
            }

            if fit.hidden > 0 {
                Button {
                    showingAllTiles.wrappedValue = true
                } label: {
                    Text("+\(fit.hidden) more")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
                .buttonStyle(.plain)
                .visionPassThrough()
                // Anchored to the button that opens it, so the arrow points at
                // `+N more` and the panel is visibly what that row promised.
                //
                // This was moved away twice and both moves were wrong. Off the
                // button it could be ORPHANED: the row lives inside
                // `if fit.hidden > 0`, and when that goes false SwiftUI tears
                // the representable down with the popover still on screen,
                // leaving a panel nothing alive can close. That is now fixed
                // where it belongs — `dismantleNSView` closes whatever is
                // showing — so the anchor is free to sit where it makes sense.
                //
                // The two cases where this row disappears mid-popover are a
                // block grown until nothing is hidden, and a block shrunk to
                // the small tier. Closing is the right answer in both, so the
                // teardown is not a workaround here; it is the behaviour.
                .macAnchoredPopover(
                    isPresented: showingAllTiles,
                    // Stays up while you work in it; `MacAnchoredPopover` closes
                    // it on the first click outside its own window.
                    behavior: .applicationDefined,
                    // Directly below `+N more`, arrow pointing at it. Anchored
                    // to the card instead, it hung under the whole block as a
                    // detached slab with nothing to say which control opened it.
                    preferredEdge: .minY
                ) {
                    VisionAllTilesPopover(viewModel: viewModel, editor: editor, block: block)
                }
            }

            addItemRow
        }
        .animation(motion(.easeOut(duration: 0.18)), value: rows.map(\.id))
    }

    /// A deliberate plain function rather than a `@ViewBuilder`.
    ///
    /// Three of `VisionTileRow`'s callbacks are nil for one kind of row and a
    /// closure for the other, and `isTask ? { … } : nil` gives the type checker
    /// nothing to infer the closure's type from. Binding them as typed locals
    /// first needs statements, which a `@ViewBuilder` body will not take.
    private func rowView(_ row: VisionRow, cursor: Int) -> some View {
        let isItem = !row.isTask
        var beginEdit: (() -> Void)?
        var commitText: ((String, Bool) -> Void)?
        var cancelEdit: (() -> Void)?
        var removeFromBoard: (() -> Void)?

        if isItem {
            // An item's text belongs to the block, so a click drops a caret in.
            // A task's belongs to Tasks, and renaming it from here would be the
            // board editing a record it only borrows.
            beginEdit = { editor.begin(row.id, in: .card) }
            commitText = { text, continuing in
                Task {
                    await editor.commit(
                        row.id, in: block.id, text: text,
                        continuing: continuing, surface: .card
                    )
                }
            }
            cancelEdit = { Task { await editor.cancel(row.id, in: block.id) } }
        } else {
            removeFromBoard = {
                Task { await viewModel.detach(taskID: row.id, from: block.id) }
            }
        }

        return VisionTileRow(
            row: row,
            showsDue: true,
            isEditing: isItem && editor.editingID(in: .card) == row.id,
            onToggle: { toggle(row) },
            onBeginEdit: beginEdit,
            onCommit: commitText,
            onCancel: cancelEdit,
            onRemoveFromBoard: removeFromBoard,
            onRemove: {
                Task {
                    if row.isTask {
                        await viewModel.deleteTask(row.id, from: block.id)
                    } else {
                        await viewModel.deleteItem(row.id, from: block.id)
                    }
                }
            }
        )
        .overlay {
            if tileCursor == cursor {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .stroke(Tokens.accentVision, lineWidth: 1)
            }
        }
        // Only a task can be dragged to another block. An item has no meaning
        // anywhere but here, so dropping one on a neighbour would either lose it
        // or silently promote it to something it is not.
        .visionDraggable(row.isTask ? row.id.uuidString : nil)
        // The whole row: the checkbox, the context menu, the remove button, the
        // in-place edit, and the drag that moves a task to another block all
        // belong to SwiftUI and all need the pointer layer to step aside.
        .visionPassThrough()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The `+` that puts a new item on the block.
    ///
    /// Directly under the last row, which is where the list ends and therefore
    /// where the next thing goes. Always visible, never hover-revealed: it is
    /// the only way to create anything on a block, and at medium it is the only
    /// adder of any kind.
    private var addItemRow: some View {
        Button(action: addItem) {
            HStack(spacing: Space.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    // Lands on the same vertical line as the checkboxes above.
                    .frame(width: 26, alignment: .center)
                Text("Add item")
                    .font(.edSubheadline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Tokens.mutedSoft)
            .frame(height: VisionBlockMetrics.addItemRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add an item that stays on this block")
        .visionPassThrough()
    }

    /// The first `limit` rows, except that the item being edited is always among
    /// them.
    ///
    /// Items append, so a full block puts the one you just asked for beyond the
    /// fold — and a caret you cannot see, in a field that commits on blur,
    /// silently eats what you type. The one being edited takes the last visible
    /// slot instead, which keeps the row count and the `+N more` total exactly
    /// where they were.
    private func visibleRows(limit: Int) -> [VisionRow] {
        var shown = Array(rows.prefix(limit))
        guard
            let editingItemID = editor.editingID,
            !shown.contains(where: { $0.id == editingItemID }),
            let editing = rows.first(where: { $0.id == editingItemID })
        else { return shown }
        // Nothing fit at all, so one row overflows for the length of the edit.
        // Better than a field with no pixels, which is the alternative.
        if !shown.isEmpty { shown.removeLast() }
        shown.append(editing)
        return shown
    }

    /// How many rows this block shows.
    ///
    /// Pure, and in `VisionContentFit` — the whole calculation, not just the
    /// division at the end of it. The budget used to be computed here, which is
    /// exactly where the reported `+2 more`-above-empty-space defect lived: one
    /// line below anything a test could reach. See `VisionContentFit.fit(for:rows:)`.
    private var contentFit: VisionContentFit.Fit {
        VisionContentFit.fit(for: block, rows: rows.count)
    }

    /// Add an item and drop a caret straight into it.
    ///
    /// The row appears blank and in edit, which is the same motion as making a
    /// block. If the user types nothing and clicks away, committing empty text
    /// removes it again, so an abandoned add leaves the card exactly as it was.
    private func addItem() {
        Task { await editor.addItem(to: block.id, in: .card) }
    }

    /// The 400ms pause before a completed row sinks. Without it the row
    /// disappears out from under the pointer at the moment of the click, and the
    /// click feels like it did something else. The delay lets you see the check
    /// land on the row you actually clicked, then the row leaves.
    ///
    /// Both kinds go through here with the same delay. They are one list to the
    /// person clicking, so a tick that behaved differently depending on where
    /// the row happens to be stored would read as a bug.
    private func toggle(_ row: VisionRow) {
        let delay: Duration? = reduceMotion ? nil : .milliseconds(400)
        Task {
            if row.isTask {
                await viewModel.toggleTask(row.id, sinkDelay: delay)
            } else {
                await viewModel.toggleItem(row.id, in: block.id, sinkDelay: delay)
            }
        }
    }

    // MARK: - Add task row (large only)

    /// Creates a real `LocalTodo` and files it here — the one adder that puts
    /// something in Tasks as well as on the board.
    ///
    /// Kept alongside the inline `+ Add item`, which is the primary create and
    /// exists at every tier. The two make visually identical rows and differ
    /// only in where the row also shows up, so the labels have to carry the
    /// whole distinction: "item" stays here, "task" goes to Tasks. That is a
    /// choice worth offering rather than guessing at, which is why the
    /// short-lived menu that made you pick a kind BEFORE typing is gone — it put
    /// the decision in front of the words.
    private var addRow: some View {
        VStack(spacing: Space.sm) {
            // `Tokens.border`, not `Tokens.divider`. The block body is
            // `surface`, and divider is unreliable on light surfaces in light
            // mode — a trap this codebase has already hit.
            Rectangle()
                .fill(Tokens.border)
                .frame(height: 0.5)

            HStack(spacing: Space.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.mutedSoft)
                    // Aligns with the tile checkboxes above it.
                    .frame(width: 26 - Space.sm, alignment: .center)

                MacClearTextField(
                    placeholder: "Add task",
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
        .help("Add a task, which also appears in Tasks")
    }

    private func commitAddRow() {
        let text = addDraft
        addDraft = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            // Focus is deliberately NOT reset: `MacClearTextField` keeps the
            // field first responder on Return so you can keep going.
            await viewModel.addTask(title: text, to: block.id)
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
        let done = rows.filter(\.completed).count
        var parts = [block.title, block.state.displayName]
        if !style.suppressesUrgency, urgency.rung > 0 {
            parts.append(urgency.accessibilityPhrase)
        }
        parts.append("\(done) of \(rows.count) done")
        parts.append("Column \(block.col + 1), row \(block.row + 1), \(block.w) by \(block.h) cells")
        return parts.joined(separator: ". ")
    }
}

// MARK: - Conditional drag

private extension View {
    /// `.draggable` when `payload` is non-nil, untouched otherwise.
    ///
    /// A helper rather than an `if` in the body because the two branches of an
    /// `if` are different view types, so SwiftUI treats the row as a DIFFERENT
    /// view when the condition flips — which tears down its `@State` and would
    /// drop an in-progress edit. This keeps one identity.
    @ViewBuilder
    func visionDraggable(_ payload: String?) -> some View {
        if let payload {
            draggable(payload)
        } else {
            self
        }
    }
}

// MARK: - Shadow

/// `shadowSm` at rest, `shadowMd` on hover, `shadowLg` while dragging. A
/// modifier rather than three chained conditionals so the card body reads as
/// one statement about elevation.
/// Internal rather than private so `BlockShadowRebuildTests` can host it. The
/// property it has to keep — that flipping `hovering` does not rebuild what it
/// wraps — is not visible in this file and cost a whole afternoon to find.
struct BlockShadow: ViewModifier {
    let dragging: Bool
    let hovering: Bool

    /// The same three levels as `shadowLg` / `shadowMd` / `shadowSm`, as values
    /// rather than as branches. See `body`.
    private var level: (opacity: Double, radius: CGFloat, y: CGFloat) {
        if dragging { return (0.10, 20, 10) }
        if hovering { return (0.08, 6, 4) }
        return (0.04, 2, 1)
    }

    /// `content` appears EXACTLY ONCE, and that is not a style preference.
    ///
    /// This used to read `if dragging { content.shadowLg() } else if hovering {
    /// … }`, which puts `content` in three arms of a `_ConditionalContent`. When
    /// `hovering` flips, SwiftUI swaps arms — and swapping arms means destroying
    /// the subtree in the old one and building a fresh copy in the new one. The
    /// whole card, every time the pointer arrives or leaves.
    ///
    /// Almost everything survives that invisibly, because SwiftUI views are
    /// values and rebuilding them is cheap. `NSViewRepresentable` does not: the
    /// rebuild ran `dismantleNSView` on the coordinator holding the open
    /// `NSPopover`, which closed it without clearing the binding, and the next
    /// re-render opened a new one. That is the reported *"I see the pop-up and
    /// then it disappears; when I move my mouse it comes back"* — measured, at
    /// `makeNSView` 3.032 / `dismantleNSView` 3.184 against a probe that did
    /// nothing but set `hoveredBlock`.
    ///
    /// Interpolating the values instead also makes the shadow animate with the
    /// card's 0.12s hover animation rather than snapping between three presets.
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(level.opacity), radius: level.radius, x: 0, y: level.y)
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
