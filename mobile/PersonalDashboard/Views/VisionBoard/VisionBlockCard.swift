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
/// The card also owns its keyboard behaviour. Arrow keys move it, ⌥-arrows
/// resize it, Return enters the tile cursor. That lives here rather than in the
/// board view because the tile cursor is card-local state, and splitting the key
/// handling from the state it drives is how the two drift.
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
    let isDragging: Bool
    let isResizing: Bool
    /// True while a tile from another block is being dragged over this one.
    let isDropTarget: Bool
    /// A block created a moment ago opens with its title selected, so naming it
    /// is the same motion as making it. The card consumes the flag on appear.
    let beginsInTitleEdit: Bool
    let onTitleEditBegan: () -> Void

    /// Move by whole cells. The board resolves the target against the rest of
    /// the board and persists it; the card only says which way.
    let onNudge: (Int, Int) -> Void
    /// Resize by whole cells, same split.
    let onResizeBy: (Int, Int) -> Void
    /// Live corner drag, in points, and its end.
    let onResizeDrag: (CGSize) -> Void
    let onResizeEnd: () -> Void
    /// Called when this card takes keyboard focus. NOT called from a tap — see
    /// the note on `contentShape` in `body` for why a card-wide tap recogniser
    /// cannot live here.
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hovering = false
    /// Keyboard focus on the card itself. Mirrored out to the board as
    /// selection, because this card disables its focus ring on the grounds that
    /// the selection treatment IS the focus ring — a claim that was not true
    /// until something actually joined the two.
    @FocusState private var focused: Bool
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    @State private var addDraft = ""
    @FocusState private var addFocused: Bool
    @State private var showingAllTiles = false
    @State private var showingAttach = false
    /// Keyboard cursor within the tile stack. Nil when the block itself has
    /// focus; an index once Return has been pressed to "enter" the block.
    @State private var tileCursor: Int?

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
        .onHover { hovering = $0 }
        .onContinuousHover { phase in
            // `.set()` on every mouse move rather than push/pop. A push that
            // loses its matching pop (a hover-out swallowed during a drag, a
            // view torn down mid-hover) leaves the whole app holding an open
            // hand, and there is no way back from that without another push.
            switch phase {
            case .active:
                (isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
            case .ended:
                NSCursor.arrow.set()
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()   // the selection treatment IS the focus ring
        // Which is only true if something joins them. Clicking a focusable view
        // focuses it, so this is also a selection route that involves no gesture
        // recogniser at all and therefore cannot compete with the board's drag —
        // the belt to the tap's braces. It is worth having on its own merits
        // regardless: Tab-focusing a block used to show nothing whatsoever,
        // because the ring is off and nothing else had been told.
        //
        // Gaining focus selects; losing it does not deselect. Clicking empty
        // canvas is the deselect, and a block should not lose its selection just
        // because the pointer moved into its own title field.
        .onChange(of: focused) { _, isFocused in if isFocused { onSelect() } }
        .onKeyPress(phases: .down) { handleKey($0) }
        // The hit shape for the board's drag, and deliberately NOT a tap.
        //
        // Selecting a block is a click, so a card-wide `.onTapGesture` here is
        // the obvious place to put it — and it is the reason the block could not
        // be moved at all (#446 follow-up). The move gesture lives on the board,
        // one level OUT from this card, attached with `.gesture`, which Apple
        // documents as *lower* precedence than gestures defined by the view and
        // its subviews. A tap spanning the whole card is therefore a subview
        // recogniser that outranks the drag over every point the drag cares
        // about, and it claimed the sequence before the drag could reach its
        // 4pt threshold.
        //
        // Selection now has two routes, neither of which can outrank the drag:
        // the focus change above, and a tap declared AFTER the drag in
        // `VisionBoardView.blockView` so that it ranks below it. Two, because
        // which of a same-level tap and drag actually fires is the very thing
        // this bug proves we cannot predict from the outside, and both routes
        // set the same id, so a double fire is a no-op.
        //
        // Anything genuinely card-local — the title, the tiles, the grip, the
        // menu — keeps its own recogniser here and still outranks the board's
        // drag, which is the same precedence rule read the other way round, and
        // is what keeps the resize grip's own drag safe.
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
                tileStack.padding(.top, Space.md)
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
        } else {
            Text(block.title)
                .font(.edHeading)
                .foregroundStyle(style.titleColor)
                .lineLimit(tier == .small ? 1 : 2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                // Single click, caret lands in it. Never a long press, never a
                // context-menu Rename.
                .onTapGesture { beginTitleEdit() }
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
        .allowsHitTesting(hovering)
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

    // MARK: - Tiles

    @ViewBuilder
    private var tileStack: some View {
        let all = tiles
        let capacity = tileCapacity
        let shown = Array(all.prefix(capacity))
        let hidden = all.count - shown.count

        VStack(alignment: .leading, spacing: VisionBlockMetrics.tileSpacing) {
            if all.isEmpty {
                // Never an empty tile skeleton: a bordered empty rectangle reads
                // as a broken tile, not as an invitation.
                Text("No tasks yet")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.mutedSoft)
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, todo in
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if hidden > 0 {
                    Button {
                        showingAllTiles = true
                    } label: {
                        Text("+\(hidden) more")
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                    }
                    .buttonStyle(.plain)
                    .macAnchoredPopover(isPresented: $showingAllTiles, preferredEdge: .minY) {
                        VisionAllTilesPopover(
                            viewModel: viewModel,
                            block: block,
                            onToggle: { toggle($0) }
                        )
                    }
                }
            }
        }
        .animation(motion(.easeOut(duration: 0.18)), value: all.map(\.id))
    }

    /// How many tiles fit, by arithmetic on `VisionBlockMetrics` rather than by
    /// measuring.
    ///
    /// A `GeometryReader` here would be reading back a height this card set
    /// itself (`rows × cellHeight - gutter`), and during a resize it would feed
    /// the layout into itself — the hazard `TripCoverMetrics` documents. The
    /// budget below is deliberately conservative: it always reserves two lines
    /// for the title, so a one-line title shows one fewer tile than it strictly
    /// could. The other way round clips the add row off the bottom of the card,
    /// and only one of those is a visual defect.
    private var tileCapacity: Int {
        guard tier != .small else { return 0 }

        let height = VisionGrid.blockSize(columns: block.w, rows: block.h).height
        var budget = height
        budget -= VisionGrid.railHeight
        budget -= Space.md * 2                              // card padding
        budget -= VisionBlockMetrics.titleLine * 2          // title, worst case
        if hasIntent { budget -= VisionBlockMetrics.intentLine + Space.xxs }
        if !tiles.isEmpty { budget -= VisionBlockMetrics.metaLine + Space.xs }
        budget -= Space.md                                  // gap above the stack
        if tier == .large { budget -= VisionBlockMetrics.addRowBlock }

        let raw = rows(in: budget)
        // The cap of 3 holds even on a tall medium block. A 2 × 8 block showing
        // twelve tiles is exactly the "300 lines of task text" failure the
        // concept doc rules out; the `+N more` row anchors to the foot and the
        // space between is left empty, which is the honest rendering of "you
        // made this tall, and medium blocks do not list everything".
        let ceiling = tier == .medium ? 3 : Int.max
        if tiles.count <= min(raw, ceiling) { return min(raw, ceiling) }

        // Overflow, so the `+N more` row has to be paid for out of the same
        // budget before the remaining rows are counted.
        let withMore = budget - VisionBlockMetrics.moreRow - VisionBlockMetrics.tileSpacing
        return max(0, min(rows(in: withMore), ceiling))
    }

    private func rows(in budget: CGFloat) -> Int {
        guard budget > 0 else { return 0 }
        let unit = VisionBlockMetrics.tileHeight + VisionBlockMetrics.tileSpacing
        return max(0, Int(((budget + VisionBlockMetrics.tileSpacing) / unit).rounded(.down)))
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
        }
        .padding(.top, Space.sm)
    }

    private func commitAddRow() {
        let text = addDraft
        addDraft = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            await viewModel.addTask(title: text, to: block.id)
            // Focus is deliberately NOT reset: `MacClearTextField` keeps the
            // field first responder on Return so you can keep going.
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
    private var resizeGrip: some View {
        ResizeGripShape()
            .stroke(Tokens.mutedSoft, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: VisionBlockMetrics.resizeTarget, height: VisionBlockMetrics.resizeTarget)
            .contentShape(Rectangle())
            .padding(Space.sm)
            .opacity(hovering || isResizing ? 1 : 0)
            .animation(motion(.easeOut(duration: 0.12)), value: hovering)
            // `.global`, not the default `.local`. The grip is pinned to the
            // card's bottom-trailing corner, so as the card grows the grip's own
            // coordinate space moves with it — in local space the pointer would
            // appear to stop moving and the resize would fight itself. Global
            // space is pure pointer travel.
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { onResizeDrag($0.translation) }
                    .onEnded { _ in onResizeEnd() }
            )
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

    // MARK: - Keyboard

    /// Arrows move, ⌥-arrows resize: the accessible route to both drag and
    /// resize, and the reason the resize handle itself is
    /// `accessibilityHidden`.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let resizing = press.modifiers.contains(.option)

        switch press.key {
        case .upArrow:
            if let cursor = tileCursor { tileCursor = max(0, cursor - 1); return .handled }
            resizing ? onResizeBy(0, -1) : onNudge(0, -1)
            return .handled
        case .downArrow:
            if let cursor = tileCursor { tileCursor = min(tiles.count - 1, cursor + 1); return .handled }
            resizing ? onResizeBy(0, 1) : onNudge(0, 1)
            return .handled
        case .leftArrow:
            guard tileCursor == nil else { return .ignored }
            resizing ? onResizeBy(-1, 0) : onNudge(-1, 0)
            return .handled
        case .rightArrow:
            guard tileCursor == nil else { return .ignored }
            resizing ? onResizeBy(1, 0) : onNudge(1, 0)
            return .handled
        case .`return`:
            // Enter the block: focus moves to its first tile. From there Return
            // and Space toggle, up and down walk the stack, Escape comes back.
            if let cursor = tileCursor, tiles.indices.contains(cursor) {
                toggle(tiles[cursor])
            } else if !tiles.isEmpty {
                tileCursor = 0
            }
            return .handled
        case .space:
            if let cursor = tileCursor, tiles.indices.contains(cursor) {
                toggle(tiles[cursor])
            } else if !tiles.isEmpty {
                tileCursor = 0
            }
            return .handled
        case .escape:
            guard tileCursor != nil else { return .ignored }
            tileCursor = nil
            return .handled
        default:
            return .ignored
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
