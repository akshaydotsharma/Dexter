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
                // Deliberately NO `.scrollDisabled(interaction.isManipulating)`.
                //
                // It was here to stop the canvas scrolling out from under a
                // drag, and it bought nothing: a left-drag never pans an AppKit
                // scroll view in the first place. Scrolling on this platform is
                // the wheel and the two-finger swipe, neither of which a drag
                // can be confused with, so removing it changes nothing a user
                // can do.
                //
                // It went because flipping it on the first `onChanged` mutated
                // a modifier on an ANCESTOR of the block mid-gesture, which is
                // a known way to have SwiftUI tear an in-flight gesture down.
                // Being honest about the evidence: removing it did NOT on its
                // own change the observed behaviour in a scripted drag, so it
                // is not established as the trigger for the wedge in #446 —
                // what IS established is that `onEnded` can go missing, and the
                // pointer-up monitor is what makes that survivable. This stays
                // out because it is a hazard with no upside, not because it was
                // convicted.
                //
                // If a scroll lock is ever wanted back, it must be driven by
                // something that cannot change while a gesture is in flight.
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
            // Captured explicitly rather than through `self`: this view is a
            // struct, and a closure that outlives the render it was installed
            // in would otherwise be reading a stale copy of it. Both of these
            // are reference types held in `@State`, so they are the same
            // objects everyone else is reading.
            let vm = viewModel
            interaction.reduceMotion = reduceMotion
            interaction.onEscape = { [weak interaction] in interaction?.cancelManipulation() }
            interaction.onPointerUp = { [weak interaction] in
                guard let interaction else { return }
                Self.endActiveGesture(interaction: interaction, viewModel: vm)
            }
            await VisionSelfTest.runIfRequested()
        }
        .onChange(of: reduceMotion) { interaction.reduceMotion = reduceMotion }
        // Tiles are real tasks, so anything that writes a task elsewhere — the
        // Shortcut capture path, chat, the Tasks surface in another window —
        // has to be able to change what this board shows.
        .onReceive(NotificationCenter.default.publisher(for: .localStoreDidChange)) { _ in
            Task { await viewModel.load() }
        }
        .onDisappear {
            Self.endActiveGesture(interaction: interaction, viewModel: viewModel)
            interaction.stopPointerMonitors()
        }
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
                    let next: VisionInteraction.Cell?
                    switch phase {
                    case .active(let point):
                        let cell = VisionGrid.cell(at: point)
                        next = VisionInteraction.Cell(col: cell.col, row: cell.row)
                    case .ended:
                        next = nil
                    }
                    guard next != interaction.hoverCell else { return }
                    withAnimation(motion(.easeOut(duration: 0.14))) { interaction.hoverCell = next }
                }

            // The floor. Always drawn, stronger while something is in hand.
            // Its own `.animation`, not the container's: an animation modifier
            // out here would also catch the dragged block's offset and stop it
            // tracking the pointer 1:1.
            VisionGridLattice(size: size, active: interaction.isManipulating)
                .animation(instantIfReduced(.easeOut(duration: 0.12)), value: interaction.isManipulating)

            // Only over empty canvas, and never while manipulating — the
            // strengthened lattice has already taken over the job.
            //
            // Wrapped so the fade transition has an animation in scope without
            // putting one on the whole canvas. Reduced motion keeps this one:
            // at 140ms of pure opacity it is inside what reduced motion permits,
            // and removing it would remove feedback rather than movement.
            Group {
                if let cell = interaction.hoverCell, !interaction.isManipulating {
                    VisionGhostCell(col: cell.col, row: cell.row)
                        .transition(.opacity)
                }
            }
            .animation(instantIfReduced(.easeOut(duration: 0.12)), value: interaction.isManipulating)

            if let drag = interaction.drag {
                VisionOriginSlot(slot: drag.origin)
                VisionTargetSlot(slot: drag.target ?? drag.origin, legal: drag.target != nil)
                    .animation(instantIfReduced(.snappy(duration: 0.12)), value: drag.target)
            }

            ForEach(viewModel.blocks) { block in
                blockView(block, canvas: size)
            }

            // Above the blocks, because a shrink would otherwise hide the
            // outline behind the very block it is describing.
            if let resize = interaction.resize, !resize.settling {
                VisionResizeTargetSlot(slot: resize.target)
                    .animation(instantIfReduced(.snappy(duration: 0.12)), value: resize.target)
                    .zIndex(20)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    // MARK: - One block

    private func blockView(_ block: VisionBlock, canvas: CGSize) -> some View {
        // During a resize the card renders the LIVE size, so the tier, the tile
        // count and the readout all recompute under the pointer rather than at
        // drop. That is the whole point of resizing on this surface.
        let live = interaction.liveFrame(for: block)
        let isDragging = interaction.drag?.id == block.id
        let origin = interaction.renderOrigin(for: block, canvas: canvas)

        return VisionBlockCard(
            viewModel: viewModel,
            block: live,
            liveSize: interaction.liveSize(for: block),
            isSelected: interaction.selected == block.id,
            isDragging: isDragging,
            isResizing: interaction.isResizing(block.id),
            isDropTarget: interaction.tileDropTarget == block.id,
            beginsInTitleEdit: interaction.pendingTitleEdit == block.id,
            onTitleEditBegan: { interaction.pendingTitleEdit = nil },
            onNudge: { dCol, dRow in Task { await nudge(block, dCol: dCol, dRow: dRow) } },
            onResizeBy: { dW, dH in Task { await resizeBy(block, dW: dW, dH: dH) } },
            onResizeDrag: { translation in resizeDrag(block, translation: translation) },
            onResizeEnd: { Self.endActiveGesture(interaction: interaction, viewModel: viewModel) },
            onSelect: { interaction.selected = block.id }
        )
        .offset(x: origin.x, y: origin.y)
        .zIndex(isDragging ? 10 : 0)
        // `.gesture`, deliberately not `.highPriorityGesture`. The card's own
        // children — the tile checkboxes, the resize grip, the ellipsis menu —
        // must win for gestures that start on them, and a low-priority drag
        // with a 4pt threshold still recognises everywhere else on the card.
        .gesture(dragGesture(block, canvas: canvas))
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
    ///
    /// `.global`, not the default `.local`. Local space belongs to the view the
    /// gesture is attached to, and this one is being moved by the gesture's own
    /// output — the class of feedback loop that makes a drag fight the pointer.
    /// Global space is pure pointer travel and cannot be fed back into.
    private func dragGesture(_ block: VisionBlock, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if interaction.drag?.id != block.id {
                    interaction.beginDrag(block)
                    interaction.startPointerMonitors()
                    NSCursor.closedHand.set()
                    VisionProbe.line("drag.begin id=\(block.id) from=\(block.col),\(block.row)")
                }
                guard let drag = interaction.drag, !drag.settling else { return }
                let start = VisionGrid.origin(col: drag.origin.col, row: drag.origin.row)
                interaction.setDragPosition(
                    CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height),
                    blockSize: VisionGrid.blockSize(columns: drag.origin.w, rows: drag.origin.h),
                    canvas: canvas
                )
                VisionProbe.line("drag.changed t=\(Int(value.translation.width)),\(Int(value.translation.height)) pos=\(Int(interaction.drag?.position.x ?? -1)),\(Int(interaction.drag?.position.y ?? -1))")
                updateDragTarget(block)
            }
            .onEnded { _ in
                VisionProbe.line("drag.onEnded")
                Self.endActiveGesture(interaction: interaction, viewModel: viewModel)
            }
    }

    private func updateDragTarget(_ block: VisionBlock) {
        guard let drag = interaction.drag else { return }
        // Rounded, not floored: the block should snap to whichever cell it is
        // MOSTLY over, which is what makes a half-cell nudge feel decisive.
        let desired = VisionBoardLayout.Slot(
            col: max(0, Int((drag.position.x / VisionGrid.cellWidth).rounded())),
            row: max(0, Int((drag.position.y / VisionGrid.cellHeight).rounded())),
            w: drag.origin.w,
            h: drag.origin.h
        )
        // Overlap nudges to the nearest free slot rather than refusing, so it
        // never feels like a fight.
        let resolved = VisionBoardLayout.nearestFreeSlot(
            to: desired, in: viewModel.blocks, excluding: block.id
        )
        if resolved != drag.target {
            interaction.drag?.target = resolved
            if resolved != nil { alignmentHaptic() }
        }
    }

    // MARK: - Resize

    /// The block's edge tracks the pointer continuously and unquantised; the
    /// dashed outline shows the cell it will land in; on release it springs into
    /// that cell using the same spring the drag settles with, so the two
    /// interactions are recognisably one system.
    ///
    /// The content still re-tiers live, off the QUANTISED width — tier it off
    /// the continuous width and the layout flickers between one and two columns
    /// every time the pointer sits on a cell boundary.
    private func resizeDrag(_ block: VisionBlock, translation: CGSize) {
        if interaction.resize?.id != block.id {
            interaction.beginResize(block)
            interaction.startPointerMonitors()
            VisionProbe.line("resize.begin id=\(block.id) from=\(block.w)x\(block.h)")
        }
        guard let session = interaction.resize, !session.settling else { return }

        let base = VisionGrid.blockSize(columns: session.origin.w, rows: session.origin.h)
        let wanted = CGSize(
            width:  base.width  + translation.width,
            height: base.height + translation.height
        )

        // What the pointer is asking for in cells, and the largest that fits.
        let desiredW = Int(((wanted.width  + VisionGrid.gutter) / VisionGrid.cellWidth ).rounded())
        let desiredH = Int(((wanted.height + VisionGrid.gutter) / VisionGrid.cellHeight).rounded())
        let legal = VisionBoardLayout.largestFreeSize(
            at: session.origin,
            desiredW: desiredW,
            desiredH: desiredH,
            in: viewModel.blocks,
            excluding: block.id
        )

        // Below the minimum the edge simply stops following, with no error
        // state; into a neighbour it stops too, because growth cannot displace
        // a block the user placed deliberately. The ceiling is applied ONLY on
        // the axis a neighbour actually cut short — otherwise it would also
        // clamp the perfectly legal half-cell of travel past a rounding
        // boundary, and the edge would stick every time it crossed one.
        let floor = VisionGrid.blockSize(columns: VisionGrid.minColumns, rows: VisionGrid.minRows)
        let ceilingW = legal.w < desiredW
            ? VisionGrid.blockSize(columns: legal.w, rows: 1).width
            : CGFloat.greatestFiniteMagnitude
        let ceilingH = legal.h < desiredH
            ? VisionGrid.blockSize(columns: 1, rows: legal.h).height
            : CGFloat.greatestFiniteMagnitude

        interaction.resize?.live = CGSize(
            width:  min(max(wanted.width,  floor.width),  ceilingW),
            height: min(max(wanted.height, floor.height), ceilingH)
        )

        if legal.w != session.w || legal.h != session.h {
            interaction.resize?.w = legal.w
            interaction.resize?.h = legal.h
            // On each cell change, not continuously: a haptic that fires on
            // every pointer sample is a buzz, not a signal.
            alignmentHaptic()
        }
    }

    // MARK: - Ending a gesture

    /// The single exit from a drag or a resize, and the only place either one
    /// commits.
    ///
    /// Static, and reachable from four callers, because correctness must not
    /// rest on `onEnded`. A gesture torn down by a view update never delivers
    /// it, and that is how the board wedged in #446: session set, lattice up,
    /// both slots up, block frozen at an uncommitted position with no way back
    /// short of quitting. A scripted drag reproduces the missing `onEnded`
    /// directly — the events go in, the drag begins, and no end ever arrives.
    /// So the pointer-up monitor
    /// (`VisionInteraction.startPointerMonitors`) calls this too, both gestures'
    /// `onEnded` call it if they survive to run, and `onDisappear` calls it if
    /// the surface goes away mid-gesture. Whichever arrives first wins;
    /// `settling` is set synchronously so the others are no-ops.
    ///
    /// The commit is awaited BEFORE the session is dropped, deliberately. Drop
    /// it first and the block renders for a frame at its old cell — it springs
    /// back to where it came from and then teleports to where it went. Awaiting
    /// means the base position is already the destination when the session
    /// clears, so the spring runs from the pointer straight into the slot.
    @MainActor
    private static func endActiveGesture(
        interaction: VisionInteraction,
        viewModel: VisionBoardViewModel
    ) {
        interaction.stopPointerMonitors()

        if let drag = interaction.drag, !drag.settling {
            interaction.drag?.settling = true
            NSCursor.openHand.set()
            let target = drag.target
            VisionProbe.line("drag.end target=\(target.map { "\($0.col),\($0.row)" } ?? "none")")
            Task { @MainActor in
                // No legal slot anywhere: the block springs back to origin. The
                // canvas grows on demand, so this is nearly unreachable.
                if let target, target != drag.origin {
                    await viewModel.setFrame(
                        drag.id, col: target.col, row: target.row, w: target.w, h: target.h
                    )
                }
                withAnimation(interaction.settle) { interaction.drag = nil }
                VisionProbe.line("drag.settled")
            }
        }

        if let resize = interaction.resize, !resize.settling {
            interaction.resize?.settling = true
            VisionProbe.line("resize.end target=\(resize.w)x\(resize.h)")
            Task { @MainActor in
                if resize.w != resize.origin.w || resize.h != resize.origin.h {
                    await viewModel.setFrame(
                        resize.id,
                        col: resize.origin.col, row: resize.origin.row,
                        w: resize.w, h: resize.h
                    )
                }
                withAnimation(interaction.settle) { interaction.resize = nil }
                VisionProbe.line("resize.settled")
            }
        }
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

    /// The ones that degrade to nothing at all.
    private func instantIfReduced(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Probe

/// An out-of-UI audit trail for the two gestures on this board, off unless
/// `DEXTER_VISION_PROBE` is set.
///
/// Same justification as `SyncLog`, and earned the same way. A gesture-lifecycle
/// bug is invisible to a build and invisible to a screenshot: the only thing
/// that distinguishes "the drag ended" from "the drag is wedged and the block
/// happens to be sitting in the right place" is whether the end ran. Writing
/// begin/end/settled to stderr makes that assertable from a script, which is how
/// the `.scrollDisabled` teardown above was pinned down and how the fix was
/// proved rather than assumed.
///
/// stderr rather than `NSLog` alone, for the reason `SyncLog` records: `NSLog`
/// stops reaching a launching shell once the process connects to the window
/// server.
enum VisionProbe {
    static let enabled = ProcessInfo.processInfo.environment["DEXTER_VISION_PROBE"] != nil

    static func line(_ message: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("VISIONPROBE \(message)\n").utf8))
    }
}

// MARK: - Interaction state

/// Live pointer and selection state for the board.
///
/// A reference type rather than a pile of `@State` on the view, for one concrete
/// reason: the monitors below are `NSEvent` closures that outlive the render
/// they were installed in. A closure over a `View` struct captures a stale copy;
/// a closure over this captures the object everyone else is reading.
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
        /// The block's top-left in canvas points, ALREADY clamped to the canvas
        /// by `setDragPosition`. Held as a position rather than a translation so
        /// there is no unclamped intermediate for a render to read.
        var position: CGPoint
        /// Nil once the free-slot search has run out of canvas. Renders grey,
        /// never red: nothing is wrong, there is simply nowhere to put it.
        var target: VisionBoardLayout.Slot?
        /// Set synchronously the moment the gesture ends, before the async
        /// commit, so a second ending is a no-op.
        var settling = false
    }

    struct ResizeSession: Equatable {
        let id: UUID
        let origin: VisionBoardLayout.Slot
        /// The cell-quantised destination. Drives the tier, the tile budget, the
        /// dimension readout and the dashed outline.
        var w: Int
        var h: Int
        /// The unquantised size in points, which is what the card actually
        /// renders at, so its edge stays under the pointer instead of jumping a
        /// whole cell at a time.
        var live: CGSize
        var settling = false

        var target: VisionBoardLayout.Slot {
            VisionBoardLayout.Slot(col: origin.col, row: origin.row, w: w, h: h)
        }
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

    /// Mirrored from the environment by the view, because the monitors and the
    /// settle animation run outside any view's body.
    var reduceMotion = false

    /// Set once by the view; invoked by the key and pointer monitors.
    var onEscape: (() -> Void)?
    var onPointerUp: (() -> Void)?

    @ObservationIgnored private var escapeToken: Any?
    @ObservationIgnored private var pointerUpToken: Any?

    var isManipulating: Bool { drag != nil || resize != nil }

    /// One spring for both gestures, so a drop and a resize release read as the
    /// same physical event.
    var settle: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.86)
    }

    func beginDrag(_ block: VisionBlock) {
        let origin = VisionBoardLayout.Slot(col: block.col, row: block.row, w: block.w, h: block.h)
        drag = DragSession(
            id: block.id,
            origin: origin,
            position: VisionGrid.origin(col: block.col, row: block.row),
            target: origin
        )
        selected = block.id
    }

    /// The ONLY mutator for a dragged block's position, and it clamps. There is
    /// deliberately no way to set an unclamped one.
    func setDragPosition(_ point: CGPoint, blockSize: CGSize, canvas: CGSize) {
        drag?.position = VisionBoardLayout.clampedOrigin(point, size: blockSize, in: canvas)
    }

    func beginResize(_ block: VisionBlock) {
        let origin = VisionBoardLayout.Slot(col: block.col, row: block.row, w: block.w, h: block.h)
        resize = ResizeSession(
            id: block.id,
            origin: origin,
            w: block.w,
            h: block.h,
            live: VisionGrid.blockSize(columns: block.w, rows: block.h)
        )
        selected = block.id
    }

    /// Where a block draws, resting or in hand. Every path goes through the
    /// clamp, so a block outside the canvas is not a state this view can reach.
    func renderOrigin(for block: VisionBlock, canvas: CGSize) -> CGPoint {
        let size = VisionGrid.blockSize(columns: block.w, rows: block.h)
        if let drag, drag.id == block.id {
            return VisionBoardLayout.clampedOrigin(drag.position, size: size, in: canvas)
        }
        return VisionBoardLayout.clampedOrigin(
            VisionGrid.origin(col: block.col, row: block.row), size: size, in: canvas
        )
    }

    /// The block's frame as it should TIER right now: quantised, so the layout
    /// changes once per cell crossed rather than flickering on the boundary.
    func liveFrame(for block: VisionBlock) -> VisionBlock {
        guard let resize, resize.id == block.id else { return block }
        var live = block
        live.w = resize.w
        live.h = resize.h
        return live
    }

    /// The block's rendered size in points: continuous under the pointer, and
    /// still continuous through the settle, so the spring has somewhere to
    /// travel from when the session finally clears.
    func liveSize(for block: VisionBlock) -> CGSize? {
        guard let resize, resize.id == block.id else { return nil }
        return resize.live
    }

    /// Drives the readout and the dashed outline, which both belong to the part
    /// of a resize the user is still steering — not to the spring afterwards.
    func isResizing(_ id: UUID) -> Bool {
        guard let resize, resize.id == id else { return false }
        return !resize.settling
    }

    /// Escape. Drop whatever is in hand without committing it; the block springs
    /// back to where it started. The gesture may still be running, and clearing
    /// the session is what makes every later ending a no-op.
    func cancelManipulation() {
        guard isManipulating else { return }
        stopPointerMonitors()
        NSCursor.openHand.set()
        withAnimation(settle) {
            drag = nil
            resize = nil
        }
        VisionProbe.line("cancelled")
    }

    // MARK: Monitors

    func startPointerMonitors() {
        startEscapeMonitor()
        startPointerUpMonitor()
    }

    func stopPointerMonitors() {
        if let escapeToken { NSEvent.removeMonitor(escapeToken) }
        escapeToken = nil
        if let pointerUpToken { NSEvent.removeMonitor(pointerUpToken) }
        pointerUpToken = nil
    }

    /// A local key monitor rather than `onKeyPress`, because during a mouse drag
    /// key events go to whatever the window's first responder happens to be, and
    /// that is not reliably the block being dragged.
    private func startEscapeMonitor() {
        guard escapeToken == nil else { return }
        escapeToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            self?.onEscape?()
            return nil
        }
    }

    /// The safety net under both gestures.
    ///
    /// SwiftUI's `onEnded` is the happy path, not a guarantee: a gesture torn
    /// down by a view update is simply gone, and takes the end callback with it.
    /// The mouse coming up, on the other hand, is an event AppKit will deliver
    /// no matter what SwiftUI did with its recogniser, and once a window has
    /// taken a mouse-down it receives the matching up even if the pointer has
    /// since left the window. So this is what actually makes the board
    /// impossible to wedge.
    ///
    /// It returns the event rather than swallowing it. Swallowing would leave
    /// SwiftUI's own gesture bookkeeping believing the button is still down.
    private func startPointerUpMonitor() {
        guard pointerUpToken == nil else { return }
        pointerUpToken = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.onPointerUp?()
            return event
        }
    }
}

#endif
