import SwiftUI

#if os(macOS)
import AppKit

/// The vision board's pointer handling, in AppKit (#446).
///
/// ### Why this is not a SwiftUI gesture
///
/// Four rounds of SwiftUI gesture fixes shipped and the block drag never once
/// worked. Two confident diagnoses were wrong. The symptom the user reported —
/// *"sometimes it expands, sometimes it doesn't"* — is recogniser racing, not a
/// logic bug: an ancestor `DragGesture`, a card-wide `onTapGesture`, the grip's
/// own `DragGesture` and `.focusable()`'s mouse-down handling were all live over
/// the same pixels, and which one claimed a given click was neither documented
/// nor stable. On top of that, `onEnded` is a happy path rather than a
/// guarantee: a gesture torn down by a view update simply never delivers it, and
/// that is how the board could be left wedged.
///
/// AppKit has neither problem. `hitTest` names exactly one view for a point;
/// that view gets `mouseDown`, every `mouseDragged`, and the matching `mouseUp`
/// **even if the pointer leaves the view or the window**. There is no
/// precedence to reason about and no recogniser to lose, so the entire wedge
/// class disappears and the `NSEvent` monitors that used to guard against it are
/// gone with it.
///
/// ### Why it is testable without a window
///
/// That was the design constraint, not a nice-to-have. Driving the real app was
/// tried and cannot be made to work: modern macOS cooperative activation refuses
/// key-window status to a background-launched app, and mouse events posted to a
/// non-key window are treated as activation clicks rather than drags.
///
/// So the split is deliberate. `VisionHitTest` decides *where the pointer is*
/// and `VisionInteraction` decides *what that means*; both are pure and take no
/// AppKit types. What is left here is event plumbing: convert a location,
/// resolve it, call one method. `VisionPointerViewTests` constructs this view,
/// synthesises `NSEvent`s, calls `mouseDown` / `mouseDragged` / `mouseUp`
/// directly and asserts on the interaction and on an in-memory store. No window,
/// no key status, no screen.
///
/// ### Blocks stay SwiftUI
///
/// Only pointer routing moved. Everything a block draws is still SwiftUI, and
/// its interactive children — tile checkboxes and their context menus, the
/// title, `+N more`, the ellipsis menu, the add-task field — still handle their
/// own clicks. They publish their frames through `VisionInteractiveRectsKey`,
/// this view is handed them as `exclusions`, and `hitTest` returns `nil` over
/// them so the event falls through to SwiftUI underneath. The exclusion list is
/// an input to the pure resolver, so "does a click on a checkbox start a drag"
/// is a unit test rather than a thing you find out by clicking.
final class VisionPointerView: NSView {

    // MARK: Inputs, pushed by the representable

    var interaction: VisionInteraction?
    var blocks: [VisionBlock] = []
    /// Interactive SwiftUI child frames, in canvas space.
    var exclusions: [CGRect] = []
    /// The subset of `exclusions` that edits text. Cursor only; hit testing
    /// treats them exactly like any other pass-through.
    var textRects: [CGRect] = []
    var canvasSize: CGSize = .zero
    /// How many tiles each block has, for the keyboard tile cursor. A count
    /// rather than the tiles themselves: this view has no business holding
    /// tasks, and the only thing the cursor needs is where it may not go.
    var tileCounts: [UUID: Int] = [:]

    /// The pointer's last known position in canvas space. Kept so a gesture can
    /// restore the right cursor when it ends: `mouseMoved` is silent while a
    /// button is down, so at `mouseUp` this is the only record of where the
    /// pointer actually is.
    private var lastPointerPoint: CGPoint = .zero

    // MARK: Outputs

    /// A click on empty canvas. Returns whether it made a block.
    ///
    /// The board answers, not this view: whether a block fits at a cell is a
    /// question about the board's contents, and it is the same `creationSlot`
    /// call the ghost is drawn from. Keeping it there is what makes the plus
    /// honest — the outline you see, the cell the click uses and the block that
    /// appears all come from one answer. A `false` is the only place a click on
    /// the canvas drops the selection instead.
    var onCanvasClick: ((Int, Int) -> Bool)?
    /// The one write path for a completed drag or resize.
    var commit: (([UUID: VisionBoardLayout.Slot]) async -> Void)?
    /// Keyboard move and resize, in whole cells.
    var onNudge: ((UUID, Int, Int) -> Void)?
    var onResizeBy: ((UUID, Int, Int) -> Void)?
    /// Return or Space on the keyboard tile cursor.
    var onToggleTile: ((UUID, Int) -> Void)?

    /// The write kicked off by the last completed gesture.
    ///
    /// Production never reads it. The headless tests await it, because a commit
    /// that lands after the assertion is a test that proves nothing, and the
    /// alternative — sleeping and hoping — is the flakiest thing a suite can
    /// contain.
    private(set) var commitTask: Task<Void, Never>?

    // MARK: Geometry

    /// Canvas space is top-left origin, y downward — the space
    /// `VisionGrid.origin(col:row:)` produces and `VisionHitTest` expects. A
    /// flipped view means no conversion anywhere, so there is no second
    /// coordinate convention to get wrong.
    override var isFlipped: Bool { true }

    private var frames: [VisionHitTest.Frame] {
        blocks.map(VisionHitTest.Frame.init)
    }

    private func block(_ id: UUID) -> VisionBlock? {
        blocks.first { $0.id == id }
    }

    /// The event's location in canvas space.
    ///
    /// `convert(_:from: nil)` is the real path: it maps window base coordinates
    /// into this view's flipped space, wherever SwiftUI has placed it inside the
    /// scroll view.
    ///
    /// With no window there is no base coordinate system to convert FROM, and
    /// AppKit's answer is undefined rather than wrong. The unit tests are
    /// written to the other reading, which is the same one a window gives when
    /// this view is the canvas: `locationInWindow` already IS the canvas point.
    /// Stated here rather than hidden in the tests, because it is the one part
    /// of this file the headless suite does not exercise.
    private func canvasPoint(for event: NSEvent) -> CGPoint {
        guard window != nil else { return event.locationInWindow }
        return convert(event.locationInWindow, from: nil)
    }

    // MARK: Hit testing

    /// Transparent over SwiftUI's own controls, opaque everywhere else.
    ///
    /// Returning `nil` is what lets a checkbox, the title, `+N more`, the
    /// ellipsis menu and the add-task field keep working while this view sits
    /// on top of every one of them. AppKit then continues its search into the
    /// SwiftUI host underneath, which is the standard overlay pattern and the
    /// reason blocks did not have to be rebuilt in AppKit.
    ///
    /// Drag-and-drop is unaffected: AppKit finds a dragging destination among
    /// views REGISTERED for the dragged types, not by hit testing, and this view
    /// registers none. Tile drags between blocks still land on the SwiftUI
    /// `dropDestination` below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        switch VisionHitTest.resolve(point: local, blocks: frames, exclusions: exclusions) {
        case .passThrough:
            return nil
        case .grip, .body, .canvas:
            return self
        }
    }

    // MARK: Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let interaction else { return }
        window?.makeFirstResponder(self)

        let point = canvasPoint(for: event)
        switch VisionHitTest.resolve(point: point, blocks: frames, exclusions: exclusions) {
        case .grip(let id):
            guard let block = block(id) else { return }
            interaction.beginResize(block, from: point)
            // Held for the whole gesture. `mouseMoved` does not fire while a
            // button is down, so without this the cursor reverts the instant the
            // pointer leaves the grip rect, which is immediately.
            Self.diagonalResize.set()
            VisionProbe.line("resize.begin id=\(id) from=\(block.w)x\(block.h)")

        case .body(let id):
            guard let block = block(id) else { return }
            interaction.beginDrag(block, grabbedAt: point)
            NSCursor.closedHand.set()
            VisionProbe.line("drag.begin id=\(id) from=\(block.col),\(block.row)")

        case .canvas(let col, let row):
            // A ghost carrying a plus is a button, and a button that needs two
            // clicks is a lie — so a single click creates. Where no block fits,
            // the click means what it always meant and drops the selection.
            interaction.tileCursor = nil
            guard interaction.claimCreation() else { return }
            if onCanvasClick?(col, row) != true { interaction.selected = nil }

        case .passThrough:
            // Unreachable through `hitTest`, which already returned nil here.
            // Reachable by direct invocation, which is how the tests assert that
            // a click on a checkbox starts nothing.
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let interaction else { return }
        let point = canvasPoint(for: event)
        lastPointerPoint = point

        if interaction.drag != nil {
            if interaction.updateDrag(to: point, canvas: canvasSize, blocks: blocks) {
                alignmentHaptic()
            }
        } else if interaction.resize != nil {
            if interaction.updateResize(to: point, blocks: blocks) {
                alignmentHaptic()
            }
        }
    }

    /// AppKit delivers this for any `mouseDown` this view accepted, even when
    /// the pointer has since left the view or the window entirely. That is the
    /// whole reason the `NSEvent` monitor safety net is gone.
    override func mouseUp(with event: NSEvent) {
        endGesture()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let interaction else { return }
        let point = canvasPoint(for: event)
        switch VisionHitTest.resolve(point: point, blocks: frames, exclusions: exclusions) {
        case .grip(let id), .body(let id):
            // Select, and stop. A right click that acts on one block while
            // another one is visibly selected is the failure mode worth
            // avoiding; the block's own actions stay on the ellipsis menu, and
            // tile context menus are SwiftUI's and reach it through `hitTest`.
            interaction.selected = id
        case .canvas:
            interaction.selected = nil
        case .passThrough:
            super.rightMouseDown(with: event)
        }
    }

    // MARK: Cursors

    /// The bottom-right resize cursor.
    ///
    /// macOS 15 finally exposed `frameResize(position:directions:)`; before it,
    /// AppKit's only diagonal cursor was the private
    /// `_windowResizeNorthWestSouthEastCursor`, which is not worth shipping. The
    /// target deploys to macOS 14, so the fallback is drawn here: a north-west
    /// to south-east double arrow, white-haloed so it survives both the light
    /// paper and the near-black ground.
    ///
    /// Built once. A cursor rebuilt on every mouse-moved is a new `NSCursor` and
    /// a new backing image several hundred times a second.
    private static let diagonalResize: NSCursor = {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(x: 6, y: 6))
            shaft.line(to: NSPoint(x: 18, y: 18))

            func head(at tip: NSPoint, dx: CGFloat, dy: CGFloat) -> NSBezierPath {
                let path = NSBezierPath()
                path.move(to: tip)
                path.line(to: NSPoint(x: tip.x + dx, y: tip.y))
                path.move(to: tip)
                path.line(to: NSPoint(x: tip.x, y: tip.y + dy))
                return path
            }
            let arrows = [
                head(at: NSPoint(x: 6, y: 6), dx: 6, dy: 6),
                head(at: NSPoint(x: 18, y: 18), dx: -6, dy: -6)
            ]

            // Halo first, glyph over it, so the cursor reads on any ground.
            NSColor.white.setStroke()
            for path in [shaft] + arrows {
                path.lineWidth = 4
                path.lineCapStyle = .round
                path.stroke()
            }
            NSColor.black.setStroke()
            for path in [shaft] + arrows {
                path.lineWidth = 1.75
                path.lineCapStyle = .round
                path.stroke()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        lastPointerPoint = canvasPoint(for: event)
        updateHover(at: lastPointerPoint)
    }

    override func mouseExited(with event: NSEvent) {
        guard let interaction, !interaction.isManipulating else { return }
        interaction.hoveredBlock = nil
        interaction.hoverCell = nil
        NSCursor.arrow.set()
    }

    /// Hover asks `VisionHitTest.block(at:in:)` rather than `resolve`, on
    /// purpose. Moving the pointer onto a tile must not read as leaving the
    /// block: the grip and the ellipsis are revealed on block hover and would
    /// flicker off the moment you moved toward a checkbox.
    private func updateHover(at point: CGPoint) {
        guard let interaction, !interaction.isManipulating else { return }

        if let id = VisionHitTest.block(at: point, in: frames) {
            if interaction.hoveredBlock != id { interaction.hoveredBlock = id }
            if interaction.hoverCell != nil { interaction.hoverCell = nil }
        } else {
            if interaction.hoveredBlock != nil { interaction.hoveredBlock = nil }
            let cell = VisionGrid.cell(at: point)
            let next = VisionInteraction.Cell(col: cell.col, row: cell.row)
            if interaction.hoverCell != next { interaction.hoverCell = next }
        }
        applyCursor(at: point)
    }

    /// What the pointer should look like at `point`.
    ///
    /// One place, because the cursor has to be right after a gesture ends as
    /// well as while hovering, and those two used to disagree: `endGesture` set
    /// an open hand unconditionally, so finishing a resize with the pointer
    /// still on the grip showed a hand until you happened to move.
    ///
    /// The grip's cursor is the whole reason this is not just `openHand`. The
    /// design system said the glyph carried the affordance on its own, since
    /// AppKit exposed no public diagonal cursor; reversed in review 2026-08-07
    /// because it did not survive contact. A corner that looks like the rest of
    /// the card gets aimed at, missed, and moves the block instead of widening
    /// it, and an open hand over a resize handle is the interface lying.
    private func applyCursor(at point: CGPoint) {
        guard
            let id = VisionHitTest.block(at: point, in: frames),
            let frame = frames.last(where: { $0.id == id })
        else {
            NSCursor.arrow.set()
            return
        }
        if VisionHitTest.gripRect(in: frame.rect).contains(point) {
            Self.diagonalResize.set()
        } else if textRects.contains(where: { $0.contains(point) }) {
            // A click here puts a caret in, so say so. This is the title's
            // cursor: it read as the block's open hand before, which promised a
            // move and delivered an edit.
            NSCursor.iBeam.set()
        } else if exclusions.contains(where: { $0.contains(point) }) {
            // A button, a checkbox, a menu. The Mac arrow, as everywhere else in
            // the app — not the open hand, because these do not move anything.
            NSCursor.arrow.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    // MARK: Keyboard

    /// Arrows move, ⌥-arrows resize, Tab walks the board, Return and Space enter
    /// a block and tick its tiles, Escape backs out.
    ///
    /// This used to be `.onKeyPress` on a `.focusable()` card, and `.focusable()`
    /// is the prime suspect for having eaten the block's mouse-down all along:
    /// clicking a focusable SwiftUI view is handled by SwiftUI's own responder
    /// path before any gesture sees it. Removing it is only safe because the
    /// keyboard route came with it — an accessible equivalent that stops working
    /// is not one.
    override func keyDown(with event: NSEvent) {
        guard let interaction else { return super.keyDown(with: event) }

        // 53 = Escape. Read by keyCode rather than by characters, because during
        // a drag the modifier state and the input source both stop being
        // predictable.
        if event.keyCode == 53 {
            if interaction.isManipulating {
                interaction.cancelManipulation()
            } else if interaction.tileCursor != nil {
                interaction.tileCursor = nil
            } else {
                interaction.selected = nil
            }
            return
        }

        if event.keyCode == 48 {   // Tab
            cycleSelection(backwards: event.modifierFlags.contains(.shift))
            return
        }

        guard let id = interaction.selected, let block = block(id) else {
            return super.keyDown(with: event)
        }
        let resizing = event.modifierFlags.contains(.option)
        let tiles = tileCounts[id] ?? 0

        switch event.keyCode {
        case 126:   // up
            if let cursor = interaction.tileCursor {
                interaction.tileCursor = max(0, cursor - 1)
            } else if resizing {
                onResizeBy?(id, 0, -1)
            } else {
                onNudge?(id, 0, -1)
            }
        case 125:   // down
            if let cursor = interaction.tileCursor {
                interaction.tileCursor = min(max(0, tiles - 1), cursor + 1)
            } else if resizing {
                onResizeBy?(id, 0, 1)
            } else {
                onNudge?(id, 0, 1)
            }
        case 123:   // left
            guard interaction.tileCursor == nil else { return }
            resizing ? onResizeBy?(id, -1, 0) : onNudge?(id, -1, 0)
        case 124:   // right
            guard interaction.tileCursor == nil else { return }
            resizing ? onResizeBy?(id, 1, 0) : onNudge?(id, 1, 0)
        case 36, 76, 49:   // Return, keypad Enter, Space
            if let cursor = interaction.tileCursor, cursor < tiles {
                onToggleTile?(block.id, cursor)
            } else if tiles > 0 {
                interaction.tileCursor = 0
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// Tab order is reading order, top to bottom then left to right — the same
    /// order the iOS projection stacks its single column in, so the two surfaces
    /// agree about sequence. `blocks` already arrives sorted that way.
    private func cycleSelection(backwards: Bool) {
        guard let interaction, !blocks.isEmpty else { return }
        interaction.tileCursor = nil
        guard let current = interaction.selected,
              let index = blocks.firstIndex(where: { $0.id == current }) else {
            interaction.selected = (backwards ? blocks.last : blocks.first)?.id
            return
        }
        let next = (index + (backwards ? -1 : 1) + blocks.count) % blocks.count
        interaction.selected = blocks[next].id
    }

    // MARK: Ending

    /// The single exit from a drag or a resize, and the only place either one
    /// commits.
    ///
    /// Reachable from `mouseUp` and from teardown. The commit is awaited BEFORE
    /// the session is dropped, deliberately: drop it first and the block renders
    /// for a frame at its old cell, so it springs back to where it came from and
    /// then teleports to where it went.
    func endGesture() {
        guard let interaction, let frames = interaction.finishManipulation() else { return }
        applyCursor(at: lastPointerPoint)
        VisionProbe.line("gesture.end frames=\(frames.count)")

        let commit = self.commit
        commitTask = Task { @MainActor in
            await commit?(frames)
            withAnimation(interaction.settle) {
                interaction.drag = nil
                interaction.resize = nil
            }
            VisionProbe.line("gesture.settled")
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // The surface is going away mid-gesture. Commit what was in hand rather
        // than losing it: the user let go of nothing, but they also cannot get
        // back to a session whose view no longer exists.
        if newWindow == nil { endGesture() }
    }

    private func alignmentHaptic() {
        guard interaction?.reduceMotion != true else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - SwiftUI bridge

/// Hosts `VisionPointerView` as the topmost layer of the canvas.
struct VisionPointerLayer: NSViewRepresentable {
    let interaction: VisionInteraction
    let blocks: [VisionBlock]
    let exclusions: [CGRect]
    let textRects: [CGRect]
    let canvasSize: CGSize
    let tileCounts: [UUID: Int]
    let onCanvasClick: (Int, Int) -> Bool
    let commit: ([UUID: VisionBoardLayout.Slot]) async -> Void
    let onNudge: (UUID, Int, Int) -> Void
    let onResizeBy: (UUID, Int, Int) -> Void
    let onToggleTile: (UUID, Int) -> Void

    func makeNSView(context: Context) -> VisionPointerView {
        let view = VisionPointerView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: VisionPointerView, context: Context) {
        apply(to: view)
    }

    static func dismantleNSView(_ view: VisionPointerView, coordinator: ()) {
        view.endGesture()
    }

    private func apply(to view: VisionPointerView) {
        view.interaction = interaction
        view.blocks = blocks
        view.exclusions = exclusions
        view.textRects = textRects
        view.canvasSize = canvasSize
        view.tileCounts = tileCounts
        view.onCanvasClick = onCanvasClick
        view.commit = commit
        view.onNudge = onNudge
        view.onResizeBy = onResizeBy
        view.onToggleTile = onToggleTile
    }
}

// MARK: - Pass-through registry

/// Frames of every SwiftUI child that owns its own clicks, in canvas space.
///
/// The pointer layer covers the whole board, so anything SwiftUI still handles
/// has to say where it is. Collecting it as a preference rather than as a
/// hand-maintained list means a control that is added to a block cannot be
/// forgotten here — it publishes its own rect or it does not work, and the
/// failure is immediate rather than latent.
struct VisionInteractiveRectsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

enum VisionCanvasSpace {
    /// The named coordinate space every published rect is measured in. The
    /// canvas rather than the window, so a scroll does not invalidate the whole
    /// exclusion list.
    static let name = "visionCanvas"
}

/// Rects that edit text rather than act on a click.
///
/// A separate key rather than a richer `VisionInteractiveRectsKey`, because hit
/// testing does not care about the difference and the resolver's signature is
/// worth keeping narrow. Only the cursor cares.
struct VisionTextRectsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

/// What the pointer should look like over a pass-through control.
enum VisionPassThroughCursor {
    /// Buttons, checkboxes, menus. The Mac arrow, as everywhere else.
    case control
    /// A field or a click-to-edit label. An I-beam.
    case text
}

extension View {
    /// Let this control keep its own clicks: publish its frame so the pointer
    /// layer makes itself transparent over it.
    ///
    /// `cursor` exists because the layer sets the cursor on every mouse-moved
    /// and would otherwise paint the whole card with the block's open hand. A
    /// hand over a click-to-edit title says "pick this up", when what it does is
    /// put a caret in it.
    func visionPassThrough(cursor: VisionPassThroughCursor = .control) -> some View {
        background(
            GeometryReader { proxy in
                let rect = proxy.frame(in: .named(VisionCanvasSpace.name))
                Color.clear
                    .preference(key: VisionInteractiveRectsKey.self, value: [rect])
                    .preference(key: VisionTextRectsKey.self, value: cursor == .text ? [rect] : [])
            }
        )
    }
}

#endif
