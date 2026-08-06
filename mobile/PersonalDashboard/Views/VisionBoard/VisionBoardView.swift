import SwiftUI

#if os(macOS)
import AppKit

/// The Vision Board (#446).
///
/// One screen, everything in flight, sized by how big it actually is. Dexter can
/// already say what is due today and what is on a list; it could not say what
/// you are CARRYING. The big pieces of work in a life do not live in a task
/// list — the task list is only their debris — so this is the surface where the
/// whole load is visible at once.
///
/// Free position and free size, snapped to an invisible grid. Not masonry and
/// not Kanban, because the board earns its keep through spatial memory: "the
/// heavy one" is always top-left and you stop reading the titles. Auto-packing
/// destroys that, since adding one block moves everything else.
///
/// macOS only for now. A 3000pt canvas on a 393pt screen is a pan-and-zoom toy,
/// so the phone will render the same blocks as a single ordered column rather
/// than the same canvas — which is why position and size are stored as content
/// and not as layout.
struct VisionBoardView: View {
    @State private var viewModel = VisionBoardViewModel()
    @State private var interaction = VisionInteraction()
    @Bindable var router: AppRouter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()

            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    canvas(viewport: proxy.size)
                }
                .scrollDisabled(interaction.isManipulating)
            }

            // Centred in the VIEWPORT rather than the canvas, so it stays put
            // if the canvas is scrolled.
            if viewModel.blocks.isEmpty && !viewModel.isLoading {
                VisionEmptyBoard {
                    Task { await createBlock(col: 0, row: 0) }
                }
                .allowsHitTesting(true)
            }
        }
        .activeSection(.visionBoard)
        .macSectionChrome("Vision Board") {
            Button { Task { await createBlockAtFirstFreeSlot() } } label: {
                Image(systemName: "plus")
            }
            .help("New block")
            .accessibilityLabel("New block")
        }
        // File > New and ⌘N while the board is on screen.
        .focusedSceneValue(\.newItemAction, NewItemAction(title: "New Block") {
            Task { await createBlockAtFirstFreeSlot() }
        })
        .task {
            await viewModel.load()
            interaction.onEscape = { [weak interaction] in interaction?.cancelDrag() }
        }
        // Tiles are real tasks, so anything that writes a task elsewhere — the
        // Shortcut capture path, chat, the Tasks surface in another window —
        // has to be able to change what this board shows.
        .onReceive(NotificationCenter.default.publisher(for: .localStoreDidChange)) { _ in
            Task { await viewModel.load() }
        }
        .onDisappear { interaction.stopEscapeMonitor() }
    }

    // MARK: - Canvas

    private func canvas(viewport: CGSize) -> some View {
        let size = VisionBoardLayout.canvasSize(for: viewModel.blocks, viewport: viewport)

        return ZStack(alignment: .topLeading) {
            // The ground, and the hit area for everything that is not a block.
            Color.clear
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                // Declared before the single tap so the double registers. A
                // single click also lands here and deselects, which is the
                // right thing to happen on a click into empty canvas anyway.
                .onTapGesture(count: 2) { point in
                    let cell = VisionGrid.cell(at: point)
                    Task { await createBlock(col: cell.col, row: cell.row) }
                }
                .onTapGesture { interaction.selected = nil }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let cell = VisionGrid.cell(at: point)
                        interaction.hoverCell = VisionInteraction.Cell(col: cell.col, row: cell.row)
                    case .ended:
                        interaction.hoverCell = nil
                    }
                }

            // Level 3. Only while something is being moved or resized.
            if interaction.isManipulating {
                VisionGridLattice(size: size)
                    .transition(.opacity)
            }

            // Level 2. Only over empty canvas, and never while manipulating —
            // the lattice has already taken over the job.
            if let cell = interaction.hoverCell, !interaction.isManipulating {
                VisionGhostCell(col: cell.col, row: cell.row)
                    .transition(.opacity)
            }

            if let drag = interaction.drag {
                VisionOriginSlot(slot: drag.origin)
                VisionTargetSlot(slot: drag.target ?? drag.origin, legal: drag.target != nil)
            }

            ForEach(viewModel.blocks) { block in
                blockView(block)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Reduced motion removes MOVEMENT, never information. The lattice and
        // the snap slot are the two that become instant — their endpoints say
        // everything the transition was saying. The ghost cell's fade stays,
        // because at 140ms of pure opacity it is inside what reduced motion
        // permits and removing it would remove feedback rather than movement.
        .animation(instantIfReduced(.easeOut(duration: 0.12)), value: interaction.isManipulating)
        .animation(motion(.easeOut(duration: 0.14)), value: interaction.hoverCell)
        .animation(instantIfReduced(.snappy(duration: 0.12)), value: interaction.drag?.target)
    }

    // MARK: - One block

    private func blockView(_ block: VisionBlock) -> some View {
        // During a resize the card renders the LIVE size, so the tier, the tile
        // count and the readout all recompute under the pointer rather than at
        // drop. That is the whole point of resizing on this surface.
        let live = interaction.liveFrame(for: block)
        let origin = VisionGrid.origin(col: live.col, row: live.row)
        let isDragging = interaction.drag?.id == block.id
        let offset = isDragging ? interaction.drag?.translation ?? .zero : .zero

        return VisionBlockCard(
            viewModel: viewModel,
            block: live,
            isSelected: interaction.selected == block.id,
            isDragging: isDragging,
            isResizing: interaction.resize?.id == block.id,
            isDropTarget: interaction.tileDropTarget == block.id,
            beginsInTitleEdit: interaction.pendingTitleEdit == block.id,
            onTitleEditBegan: { interaction.pendingTitleEdit = nil },
            onNudge: { dCol, dRow in Task { await nudge(block, dCol: dCol, dRow: dRow) } },
            onResizeBy: { dW, dH in Task { await resizeBy(block, dW: dW, dH: dH) } },
            onResizeDrag: { translation in resizeDrag(block, translation: translation) },
            onResizeEnd: { Task { await commitResize(block) } },
            onSelect: { interaction.selected = block.id }
        )
        .offset(x: origin.x + offset.width, y: origin.y + offset.height)
        .zIndex(isDragging ? 10 : 0)
        // `.gesture`, deliberately not `.highPriorityGesture`. The card's own
        // children — the tile checkboxes, the resize grip, the ellipsis menu —
        // must win for gestures that start on them, and a low-priority drag
        // with a 4pt threshold still recognises everywhere else on the card.
        .gesture(dragGesture(block))
        // Moving a task between blocks. The transferable is the task's UUID
        // string; `attach` enforces one-block-per-task on the way in, so the
        // source block does not have to be told about the move.
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
            Task { await viewModel.attach(taskID: id, to: block.id) }
            return true
        } isTargeted: { targeted in
            interaction.tileDropTarget = targeted ? block.id : nil
        }
    }

    // MARK: - Block drag

    /// The block follows the pointer 1:1 and continuously; the target slot jumps
    /// discretely between legal cells. That contrast IS the snap feedback and it
    /// needs no extra flourish: the block floats free under your hand while the
    /// slot clicks into place beneath it.
    private func dragGesture(_ block: VisionBlock) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if interaction.drag?.id != block.id {
                    interaction.beginDrag(block)
                    interaction.startEscapeMonitor()
                    NSCursor.closedHand.set()
                }
                interaction.drag?.translation = value.translation
                updateDragTarget(block)
            }
            .onEnded { _ in
                NSCursor.openHand.set()
                interaction.stopEscapeMonitor()
                guard let drag = interaction.drag, drag.id == block.id else {
                    interaction.drag = nil
                    return
                }
                let target = drag.target
                withAnimation(motion(.spring(response: 0.28, dampingFraction: 0.86))) {
                    interaction.drag = nil
                }
                // No legal slot anywhere: the block springs back to origin. The
                // canvas grows on demand, so this is nearly unreachable.
                guard let target, target != drag.origin else { return }
                Task {
                    await viewModel.setFrame(
                        block.id, col: target.col, row: target.row, w: target.w, h: target.h
                    )
                }
            }
    }

    private func updateDragTarget(_ block: VisionBlock) {
        guard let drag = interaction.drag else { return }
        let origin = VisionGrid.origin(col: drag.origin.col, row: drag.origin.row)
        let moved = CGPoint(
            x: origin.x + drag.translation.width,
            y: origin.y + drag.translation.height
        )
        // Rounded, not floored: the block should snap to whichever cell it is
        // MOSTLY over, which is what makes a half-cell nudge feel decisive.
        let desired = VisionBoardLayout.Slot(
            col: max(0, Int((moved.x / VisionGrid.cellWidth).rounded())),
            row: max(0, Int((moved.y / VisionGrid.cellHeight).rounded())),
            w: drag.origin.w,
            h: drag.origin.h
        )
        // Overlap nudges to the nearest free slot rather than refusing, so it
        // never feels like a fight.
        let resolved = VisionBoardLayout.nearestFreeSlot(
            to: desired, in: viewModel.blocks, excluding: block.id
        )
        if resolved != interaction.drag?.target {
            interaction.drag?.target = resolved
            if resolved != nil { alignmentHaptic() }
        }
    }

    // MARK: - Resize

    private func resizeDrag(_ block: VisionBlock, translation: CGSize) {
        if interaction.resize?.id != block.id {
            interaction.beginResize(block)
        }
        guard let session = interaction.resize else { return }

        let desiredW = session.origin.w + Int((translation.width / VisionGrid.cellWidth).rounded())
        let desiredH = session.origin.h + Int((translation.height / VisionGrid.cellHeight).rounded())
        let candidate = VisionBoardLayout.Slot(
            col: session.origin.col,
            row: session.origin.row,
            w: max(VisionGrid.minColumns, desiredW),
            h: max(VisionGrid.minRows, desiredH)
        )
        // Below the minimum the handle simply stops following, with no error
        // state; into a neighbour it stops too, because growth cannot displace
        // a block the user placed deliberately.
        guard VisionBoardLayout.isFree(candidate, in: viewModel.blocks, excluding: block.id) else { return }
        if candidate.w != session.w || candidate.h != session.h {
            interaction.resize?.w = candidate.w
            interaction.resize?.h = candidate.h
            alignmentHaptic()
        }
    }

    private func commitResize(_ block: VisionBlock) async {
        guard let session = interaction.resize, session.id == block.id else { return }
        interaction.resize = nil
        guard session.w != block.w || session.h != block.h else { return }
        await viewModel.setFrame(block.id, col: block.col, row: block.row, w: session.w, h: session.h)
    }

    // MARK: - Keyboard move and resize

    private func nudge(_ block: VisionBlock, dCol: Int, dRow: Int) async {
        let desired = VisionBoardLayout.Slot(
            col: max(0, block.col + dCol),
            row: max(0, block.row + dRow),
            w: block.w,
            h: block.h
        )
        guard let slot = VisionBoardLayout.nearestFreeSlot(
            to: desired, in: viewModel.blocks, excluding: block.id
        ) else { return }
        await viewModel.setFrame(block.id, col: slot.col, row: slot.row, w: slot.w, h: slot.h)
    }

    private func resizeBy(_ block: VisionBlock, dW: Int, dH: Int) async {
        let candidate = VisionBoardLayout.Slot(
            col: block.col,
            row: block.row,
            w: max(VisionGrid.minColumns, block.w + dW),
            h: max(VisionGrid.minRows, block.h + dH)
        )
        guard VisionBoardLayout.isFree(candidate, in: viewModel.blocks, excluding: block.id) else { return }
        await viewModel.setFrame(
            block.id, col: candidate.col, row: candidate.row, w: candidate.w, h: candidate.h
        )
    }

    // MARK: - Creation

    /// Creates at that cell, with the title already in edit: naming a block is
    /// part of making one, not a second step you have to discover.
    private func createBlock(col: Int, row: Int) async {
        if let id = await viewModel.createBlock(at: col, row: row) {
            interaction.selected = id
            interaction.pendingTitleEdit = id
        }
    }

    /// The toolbar and ⌘N entry point. Scans reading order for the first slot a
    /// default-sized block fits in, so the new block lands where you would have
    /// put it rather than on top of something.
    private func createBlockAtFirstFreeSlot() async {
        let desired = VisionBoardLayout.Slot(col: 0, row: 0, w: 2, h: 3)
        let slot = VisionBoardLayout.nearestFreeSlot(
            to: desired, in: viewModel.blocks, excluding: nil
        ) ?? desired
        await createBlock(col: slot.col, row: slot.row)
    }

    // MARK: - Feedback

    /// `.alignment` is precisely the semantic Apple defines for a snap, and it
    /// works on Force Touch and Magic Trackpads. Silently no-ops elsewhere, so
    /// there is nothing to feature-detect.
    private func alignmentHaptic() {
        guard !reduceMotion else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Springs degrade to a short ease-out.
    private func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? .easeOut(duration: 0.15) : animation
    }

    /// The two that degrade to nothing at all.
    private func instantIfReduced(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Interaction state

/// Live pointer and selection state for the board.
///
/// A reference type rather than a pile of `@State` on the view, for one concrete
/// reason: the Escape-cancels-a-drag monitor is an `NSEvent` closure that
/// outlives the render it was installed in. A closure over a `View` struct
/// captures a stale copy; a closure over this captures the object everyone else
/// is reading.
@MainActor
@Observable
final class VisionInteraction {
    struct Cell: Equatable {
        var col: Int
        var row: Int
    }

    struct DragSession: Equatable {
        let id: UUID
        let origin: VisionBoardLayout.Slot
        var translation: CGSize = .zero
        /// Nil once the free-slot search has run out of canvas. Renders grey,
        /// never red: nothing is wrong, there is simply nowhere to put it.
        var target: VisionBoardLayout.Slot?
    }

    struct ResizeSession: Equatable {
        let id: UUID
        let origin: VisionBoardLayout.Slot
        var w: Int
        var h: Int
    }

    var selected: UUID?
    var hoverCell: Cell?
    var drag: DragSession?
    var resize: ResizeSession?
    /// The block a dragged tile is currently over.
    var tileDropTarget: UUID?
    /// A just-created block, which opens with its title in edit. Consumed by
    /// the card on appear so a later re-render cannot re-enter the edit.
    var pendingTitleEdit: UUID?

    /// Set once by the view; invoked by the key monitor.
    var onEscape: (() -> Void)?

    @ObservationIgnored private var escapeToken: Any?

    var isManipulating: Bool { drag != nil || resize != nil }

    func beginDrag(_ block: VisionBlock) {
        let origin = VisionBoardLayout.Slot(col: block.col, row: block.row, w: block.w, h: block.h)
        drag = DragSession(id: block.id, origin: origin, target: origin)
        selected = block.id
    }

    func beginResize(_ block: VisionBlock) {
        let origin = VisionBoardLayout.Slot(col: block.col, row: block.row, w: block.w, h: block.h)
        resize = ResizeSession(id: block.id, origin: origin, w: block.w, h: block.h)
        selected = block.id
    }

    /// The block's frame as it should render RIGHT NOW, live resize included.
    func liveFrame(for block: VisionBlock) -> VisionBlock {
        guard let resize, resize.id == block.id else { return block }
        var live = block
        live.w = resize.w
        live.h = resize.h
        return live
    }

    /// Drop the drag without committing. The gesture is still running until the
    /// mouse comes up; clearing the session is what makes `onEnded` a no-op.
    func cancelDrag() {
        drag = nil
        stopEscapeMonitor()
    }

    // MARK: Escape monitor

    /// A local key monitor rather than `onKeyPress`, because during a mouse drag
    /// key events go to whatever the window's first responder happens to be, and
    /// that is not reliably the block being dragged.
    func startEscapeMonitor() {
        guard escapeToken == nil else { return }
        escapeToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            self?.onEscape?()
            return nil
        }
    }

    func stopEscapeMonitor() {
        if let escapeToken { NSEvent.removeMonitor(escapeToken) }
        escapeToken = nil
    }
}

#endif
