import SwiftUI

#if os(macOS)

/// The canvas's own furniture (#446): the lattice, the ghost cell, the drag
/// slots, and the empty-board invitation.
///
/// All of it is `accessibilityHidden`. Every one of these is pointer feedback;
/// the keyboard route to the same outcomes is on the block itself.

// MARK: - The lattice

/// Dots at every cell corner. **Always on**, and stronger while a block is
/// being dragged or resized.
///
/// This reverses the original design-system argument, which was that
/// placeability should be revealed by attention rather than printed on the
/// ground. Reviewed and overturned on 2026-08-06: the board is a *place*, and a
/// place you are asked to arrange things in should show you its floor. A grid
/// that only exists while you are already committed to a drag tells you where a
/// block will land but never helps you decide to move one, and the idle canvas
/// it left behind read as an empty document rather than a surface with slots.
///
/// The whole risk in reversing it was turning warm paper into graph paper, so
/// the idle values are pitched at the threshold: 1.4pt dots at a delta of
/// roughly fifteen levels from `Tokens.paper` in either theme, on a pitch of
/// 184 × 68pt. From a normal viewing distance an empty board still reads as one
/// calm surface, and you notice the lattice only when you look for it — which is
/// exactly the moment you want it.
///
/// 1.4pt rather than the 1.5pt the reveal-on-attention version used, and the
/// sizes matter more than they look: below about 1.2pt the antialiasing eats
/// most of the delta and the dot goes from faint to absent, so a dot that is
/// too small has to be made too DARK to compensate, and then it reads as grit
/// rather than as texture.
///
/// Strengthening rather than appearing also buys something the fade never
/// could: the grid the drag snaps to is visibly the same grid that was there
/// before you picked the block up.
///
/// A `Shape` rather than a `Canvas`: the tokens are dynamic light/dark pairs,
/// and a filled shape lets SwiftUI resolve them exactly the way every other
/// token in the app is resolved instead of routing them through
/// `GraphicsContext`. Roughly 470 dots on a 3000 × 2000 canvas, which is one
/// cheap path — and now a permanently retained one, which is why it stayed a
/// single path rather than becoming a per-cell view.
struct VisionGridLattice: View {
    let size: CGSize
    /// True while a block is being moved or resized.
    let active: Bool

    var body: some View {
        DotLattice(dotSize: active ? 1.8 : 1.4)
            .fill(active ? Tokens.visionLatticeActive : Tokens.visionLattice)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct DotLattice: Shape {
    var dotSize: CGFloat

    /// So the dots grow into the stronger state rather than popping. Without
    /// this the colour would crossfade while the radius jumped, which reads as
    /// two separate events.
    var animatableData: CGFloat {
        get { dotSize }
        set { dotSize = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = dotSize / 2
        var y: CGFloat = 0
        while y <= rect.height {
            var x: CGFloat = 0
            while x <= rect.width {
                path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: dotSize, height: dotSize))
                x += VisionGrid.cellWidth
            }
            y += VisionGrid.cellHeight
        }
        return path
    }
}

// MARK: - The ghost cell

/// A single cell-sized outline under the pointer over empty canvas.
///
/// Sized at the minimum block (1 × 2) and placed at the snapped cell, so it is a
/// truthful preview of what a double-click produces rather than decoration. It
/// JUMPS between cells rather than sliding, which is the same discrete-versus-
/// continuous contrast that communicates snapping during a drag.
struct VisionGhostCell: View {
    let col: Int
    let row: Int

    var body: some View {
        let size = VisionGrid.blockSize(columns: VisionGrid.minColumns, rows: VisionGrid.minRows)
        let origin = VisionGrid.origin(col: col, row: row)

        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Tokens.surface.opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(Tokens.borderStrong, style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
            )
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Tokens.mutedSoft)
            }
            .frame(width: size.width, height: size.height)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Drag slots

/// Where the block will land. Accent, because the accent's one job on this board
/// is "the system is responding to you".
///
/// `legal == false` renders grey, never red. Red means "you did something
/// wrong"; nothing is wrong, there is simply nowhere of this size left, and the
/// canvas grows on demand so it should be nearly unreachable in the first place.
struct VisionTargetSlot: View {
    let slot: VisionBoardLayout.Slot
    let legal: Bool

    var body: some View {
        let size = VisionGrid.blockSize(columns: slot.w, rows: slot.h)
        let origin = VisionGrid.origin(col: slot.col, row: slot.row)
        let tint = legal ? Tokens.accentVision : Tokens.mutedSoft

        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(tint.opacity(legal ? 0.10 : 0.14))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(tint, style: StrokeStyle(lineWidth: 0.5, dash: [5, 4]))
            )
            .frame(width: size.width, height: size.height)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Where the block came from. Outline only, no fill.
///
/// `Tokens.border`, deliberately not `Tokens.divider`: divider disappears on
/// light surfaces in light mode, which is the trap this codebase has already
/// hit and written down.
struct VisionOriginSlot: View {
    let slot: VisionBoardLayout.Slot

    var body: some View {
        let size = VisionGrid.blockSize(columns: slot.w, rows: slot.h)
        let origin = VisionGrid.origin(col: slot.col, row: slot.row)

        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .stroke(Tokens.border, style: StrokeStyle(lineWidth: 0.5, dash: [5, 4]))
            .frame(width: size.width, height: size.height)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Resize target

/// Where a resize will land, while the block's own edge is still following the
/// pointer between cells.
///
/// The same dashed accent hairline as `VisionTargetSlot`, so the two snap
/// previews read as one idea. The one deliberate difference is that this has no
/// fill: it is drawn ON TOP of the block being resized (it has to be, or
/// shrinking would hide it behind the very block it is describing), and a 10%
/// accent wash over a card would tint that card's own content.
struct VisionResizeTargetSlot: View {
    let slot: VisionBoardLayout.Slot

    var body: some View {
        let size = VisionGrid.blockSize(columns: slot.w, rows: slot.h)
        let origin = VisionGrid.origin(col: slot.col, row: slot.row)

        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .stroke(Tokens.accentVision, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .frame(width: size.width, height: size.height)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Empty board

/// Centred in the VIEWPORT, not the canvas, so it stays put if the canvas is
/// scrolled.
///
/// No illustration and no icon in a circle. The ghost block teaches the object
/// model — this is what a block is, this is roughly how big — in a way copy
/// cannot, and it is also the primary action.
struct VisionEmptyBoard: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Nothing on the board yet")
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
            Text("Double-click anywhere to add the first thing you're carrying.")
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .padding(.top, Space.sm)

            Button(action: onCreate) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(Tokens.borderStrong, style: StrokeStyle(lineWidth: 0.5, dash: [6, 5]))
                    .frame(
                        width: VisionGrid.blockSize(columns: 2, rows: 3).width,
                        height: VisionGrid.blockSize(columns: 2, rows: 3).height
                    )
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Tokens.mutedSoft)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Space.xl)
            .accessibilityLabel("Add the first block")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
