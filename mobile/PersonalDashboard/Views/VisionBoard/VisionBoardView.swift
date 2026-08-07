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
/// Free position and free size, snapped to a lattice. Not masonry and not
/// Kanban, because the board earns its keep through spatial memory: "the heavy
/// one" is always top-left and you stop reading the titles. Auto-packing
/// destroys that, since adding one block moves everything else.
///
/// macOS only for now. A 3000pt canvas on a 393pt screen is a pan-and-zoom toy,
/// so the phone will render the same blocks as a single ordered column rather
/// than the same canvas — which is why position and size are stored as content
/// and not as layout.
///
/// ### The pointer is AppKit's
///
/// Everything here draws; nothing here recognises a gesture. `VisionPointerLayer`
/// sits on top of the canvas and owns hit testing, drag, resize, hover, clicks
/// on empty canvas and the keyboard. Read the header of `VisionPointerLayer.swift`
/// for why — briefly, four rounds of SwiftUI gesture fixes never made the block
/// drag work once, and the architecture that fixes it is the one whose behaviour
/// can be asserted with no window, no key status and no screen.
struct VisionBoardView: View {
    @State private var viewModel = VisionBoardViewModel()
    @State private var interaction = VisionInteraction()
    /// Frames of every SwiftUI control inside a block that still handles its own
    /// clicks. Published by `.visionPassThrough()`, consumed by the pointer
    /// layer's `hitTest`.
    @State private var exclusions: [CGRect] = []
    @Bindable var router: AppRouter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()

            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    canvas(viewport: proxy.size)
                }
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
            interaction.reduceMotion = reduceMotion
        }
        .onChange(of: reduceMotion) { interaction.reduceMotion = reduceMotion }
        // Tiles are real tasks, so anything that writes a task elsewhere — the
        // Shortcut capture path, chat, the Tasks surface in another window —
        // has to be able to change what this board shows.
        .onReceive(NotificationCenter.default.publisher(for: .localStoreDidChange)) { _ in
            Task { await viewModel.load() }
        }
    }

    // MARK: - Canvas

    private func canvas(viewport: CGSize) -> some View {
        let size = VisionBoardLayout.canvasSize(for: viewModel.blocks, viewport: viewport)

        return ZStack(alignment: .topLeading) {
            // The floor. Always drawn, stronger while something is in hand.
            // Its own `.animation`, not the container's: an animation modifier
            // out here would also catch the dragged block's offset and stop it
            // tracking the pointer 1:1.
            VisionGridLattice(size: size, active: interaction.isManipulating)
                .animation(instantIfReduced(.easeOut(duration: 0.12)), value: interaction.isManipulating)

            // Only over empty canvas, only where a new block actually fits, and
            // never while manipulating — the strengthened lattice has already
            // taken over the job.
            //
            // The "actually fits" clause is what makes the plus honest: the
            // ghost is drawn from the same `creationSlot` the click consults, so
            // the outline is the block you are about to make, at the position
            // you are about to make it, and its absence is the only place a
            // click deselects instead.
            Group {
                if let cell = interaction.hoverCell,
                   !interaction.isManipulating,
                   let slot = creationSlot(col: cell.col, row: cell.row) {
                    VisionGhostCell(slot: slot)
                        .transition(.opacity)
                }
            }
            .animation(instantIfReduced(.easeOut(duration: 0.12)), value: interaction.isManipulating)

            if let drag = interaction.drag {
                VisionOriginSlot(slot: drag.origin)
                // Always legal now: the target is wherever the pointer is, and
                // whatever is there gets out of the way. There is no longer an
                // "occupied" outcome for this to render.
                VisionTargetSlot(slot: drag.target ?? drag.origin)
                    .animation(instantIfReduced(.snappy(duration: 0.12)), value: drag.target)
            }

            // Where the cascade WOULD put each displaced block. Outlines only:
            // the blocks themselves do not move until the mouse comes up.
            ForEach(interaction.displacementGhosts, id: \.id) { ghost in
                VisionDisplacementGhost(slot: ghost.slot)
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

            // Topmost, and the only thing on this canvas that handles a click.
            VisionPointerLayer(
                interaction: interaction,
                blocks: viewModel.blocks,
                exclusions: exclusions,
                canvasSize: size,
                tileCounts: tileCounts,
                onCanvasClick: { col, row in
                    // The ghost, the click and the creation all read this one
                    // answer, so the plus can never point at a cell the block
                    // does not land in.
                    guard creationSlot(col: col, row: row) != nil else { return false }
                    Task { await createBlock(col: col, row: row) }
                    return true
                },
                commit: { frames in await viewModel.applyLayout(frames) },
                onNudge: { id, dCol, dRow in Task { await nudge(id, dCol: dCol, dRow: dRow) } },
                onResizeBy: { id, dW, dH in Task { await resizeBy(id, dW: dW, dH: dH) } },
                onToggleTile: { id, index in toggleTile(blockID: id, index: index) }
            )
            .frame(width: size.width, height: size.height)
            .zIndex(30)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: VisionCanvasSpace.name)
        .onPreferenceChange(VisionInteractiveRectsKey.self) { rects in
            // Cheap to write and safe to write mid-gesture, which is the point
            // of the whole rewrite: a SwiftUI re-render can no longer tear down
            // pointer handling, because pointer handling is not a SwiftUI
            // gesture any more.
            exclusions = rects
        }
    }

    /// Tile counts for the keyboard cursor, which is all the pointer layer needs
    /// to know about tasks.
    private var tileCounts: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: viewModel.blocks.map { ($0.id, viewModel.tiles(for: $0).count) })
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
            isHovered: interaction.hoveredBlock == block.id,
            isDragging: isDragging,
            isResizing: interaction.isResizing(block.id),
            isDropTarget: interaction.tileDropTarget == block.id,
            tileCursor: interaction.selected == block.id ? interaction.tileCursor : nil,
            beginsInTitleEdit: interaction.pendingTitleEdit == block.id,
            onTitleEditBegan: { interaction.pendingTitleEdit = nil }
        )
        .offset(x: origin.x, y: origin.y)
        // Displaced neighbours slide when the drop lands; the block in hand does
        // not (the animation resolves to nil for it). Scoped to this one
        // modifier and this one value on purpose — the file's standing rule is
        // that no animation may be allowed to catch the dragged block's offset,
        // and a container-level `.animation` is exactly how that happens.
        .animation(interaction.displacementAnimation(for: block.id), value: origin)
        .zIndex(isDragging ? 10 : 0)
        // Moving a task between blocks. The transferable is the task's UUID
        // string; `attach` enforces one-block-per-task on the way in, so the
        // source block does not have to be told about the move.
        //
        // Untouched by the pointer layer above it: AppKit finds a dragging
        // destination among views registered for the dragged types rather than
        // by hit testing, and `VisionPointerView` registers none.
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
            Task { await viewModel.attach(taskID: id, to: block.id) }
            return true
        } isTargeted: { targeted in
            interaction.tileDropTarget = targeted ? block.id : nil
        }
    }

    // MARK: - Keyboard move and resize

    /// The keyboard routes push exactly as the pointer routes do.
    ///
    /// They have to: arrows and ⌥-arrows are the accessible equivalent of the
    /// drag and the grip, and an equivalent that refuses where the pointer
    /// succeeds is not one.
    private func nudge(_ id: UUID, dCol: Int, dRow: Int) async {
        guard let block = viewModel.blocks.first(where: { $0.id == id }) else { return }
        await push(block, to: VisionBoardLayout.Slot(
            col: max(0, block.col + dCol),
            row: max(0, block.row + dRow),
            w: block.w,
            h: block.h
        ))
    }

    private func resizeBy(_ id: UUID, dW: Int, dH: Int) async {
        guard let block = viewModel.blocks.first(where: { $0.id == id }) else { return }
        await push(block, to: VisionBoardLayout.Slot(
            col: block.col,
            row: block.row,
            w: max(VisionGrid.minColumns, block.w + dW),
            h: max(VisionGrid.minRows, block.h + dH)
        ))
    }

    /// Put `block` at `target` and shove whatever is in the way, in one write.
    private func push(_ block: VisionBlock, to target: VisionBoardLayout.Slot) async {
        let current = VisionBoardLayout.Slot(col: block.col, row: block.row, w: block.w, h: block.h)
        guard target != current else { return }
        var frames = VisionBoardLayout.displacements(
            moving: block.id, to: target, in: viewModel.blocks
        )
        frames[block.id] = target
        await viewModel.applyLayout(frames)
    }

    private func toggleTile(blockID: UUID, index: Int) {
        guard let block = viewModel.blocks.first(where: { $0.id == blockID }) else { return }
        let tiles = viewModel.tiles(for: block)
        guard tiles.indices.contains(index) else { return }
        Task {
            await viewModel.toggleTask(
                tiles[index].id, sinkDelay: reduceMotion ? nil : .milliseconds(400)
            )
        }
    }

    // MARK: - Creation

    /// The slot a click at this cell would fill, or nil if it would fill none.
    ///
    /// One function, two callers — the ghost and the pointer layer's click —
    /// because the whole of defect two was those disagreeing. The footprint is
    /// the real one a block is created at, not the minimum block: a preview that
    /// understates the size can sit happily in a gap the block cannot fit in,
    /// and then creation nudges it elsewhere and the plus turns out to have been
    /// pointing at the wrong cell.
    ///
    /// Deliberately no nearest-free-slot fallback. Nudging is right when the
    /// user is steering a block with the pointer and can see where it went; it
    /// is wrong for a plus sitting on a specific cell, which has made a promise
    /// about that cell. Where the promise cannot be kept there is no plus.
    private func creationSlot(col: Int, row: Int) -> VisionBoardLayout.Slot? {
        let slot = VisionBoardLayout.Slot(
            col: col, row: row, w: VisionGrid.newColumns, h: VisionGrid.newRows
        )
        return VisionBoardLayout.isFree(slot, in: viewModel.blocks, excluding: nil) ? slot : nil
    }

    /// Creates at that cell, with the title already in edit: naming a block is
    /// part of making one, not a second step you have to discover.
    private func createBlock(col: Int, row: Int) async {
        guard creationSlot(col: col, row: row) != nil else { return }
        if let id = await viewModel.createBlock(at: col, row: row) {
            interaction.selected = id
            interaction.pendingTitleEdit = id
        }
    }

    /// The toolbar and ⌘N entry point. Scans reading order for the first slot a
    /// default-sized block fits in, so the new block lands where you would have
    /// put it rather than on top of something.
    private func createBlockAtFirstFreeSlot() async {
        let desired = VisionBoardLayout.Slot(
            col: 0, row: 0, w: VisionGrid.newColumns, h: VisionGrid.newRows
        )
        let slot = VisionBoardLayout.nearestFreeSlot(
            to: desired, in: viewModel.blocks, excluding: nil
        ) ?? desired
        if let id = await viewModel.createBlock(at: slot.col, row: slot.row) {
            interaction.selected = id
            interaction.pendingTitleEdit = id
        }
    }

    // MARK: - Motion

    /// The animations that degrade to nothing at all under reduced motion.
    private func instantIfReduced(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Probe

/// An out-of-UI audit trail for the two gestures on this board, off unless
/// `DEXTER_VISION_PROBE` is set.
///
/// Kept after the AppKit rewrite, and shrunk. A gesture-lifecycle bug is
/// invisible to a build and invisible to a screenshot: the only thing that
/// distinguishes "the drag ended" from "the drag is wedged and the block happens
/// to be sitting in the right place" is whether the end ran. The headless suite
/// is now the primary evidence for that, so this is a field aid rather than the
/// proof it used to be.
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

#endif
