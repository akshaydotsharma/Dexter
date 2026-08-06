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
/// the idle values are pitched at the threshold: from a normal viewing distance
/// an empty board still reads as one calm surface, and you notice the lattice
/// only when you look for it — which is exactly the moment you want it.
///
/// ### Retuned for the square lattice (2026-08-07)
///
/// The pitch was 184 × 68pt and is now 68 × 68pt, so a patch of canvas carries
/// 2.7× as many dots and, at the old values, 2.7× as much ink. The dot is now
/// 1.2pt idle and 1.6pt active, down from 1.4 and 1.8, and `Tokens.visionLattice`
/// took a matching ~30% cut in contrast; together those land the field at roughly
/// 1.4× its old weight rather than 2.7×.
///
/// 1.2pt is a floor, not a preference. Below about that the antialiasing eats
/// most of the delta and the dot goes from faint to absent, so a smaller dot has
/// to be made DARKER to compensate and then it reads as grit rather than as
/// texture. That is why the correction is split across the size here and the
/// colour in `Tokens` instead of being taken out of either one alone.
///
/// Strengthening rather than appearing also buys something the fade never
/// could: the grid the drag snaps to is visibly the same grid that was there
/// before you picked the block up.
///
/// A `Shape` rather than a `Canvas`: the tokens are dynamic light/dark pairs,
/// and a filled shape lets SwiftUI resolve them exactly the way every other
/// token in the app is resolved instead of routing them through
/// `GraphicsContext`. Roughly 1,300 dots on a 3000 × 2000 canvas, up from 470,
/// which is still one cheap path — and a permanently retained one, which is why
/// it stayed a single path rather than becoming a per-cell view.
struct VisionGridLattice: View {
    let size: CGSize
    /// True while a block is being moved or resized.
    let active: Bool

    var body: some View {
        DotLattice(dotSize: active ? 1.6 : 1.2)
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

/// The block a click on empty canvas is about to make, outlined under the
/// pointer before you commit to making it.
///
/// It carries a plus, so it reads as a button, and since #446's follow-up it IS
/// one: a single click makes the block. That is the whole reason it is drawn at
/// the slot the board hands it rather than at the minimum block size it used to
/// assume. A preview one cell wide could sit in a gap that the 2 × 3 block being
/// created does not fit in, and the click would then quietly put the block
/// somewhere else — a plus pointing at the wrong cell.
///
/// It JUMPS between cells rather than sliding, which is the same discrete-
/// versus-continuous contrast that communicates snapping during a drag.
///
/// `allowsHitTesting(false)` even though it is the affordance for a click: the
/// canvas ground underneath owns every click, and gets the same answer from the
/// same `creationSlot` call that put this here. Making the ghost itself
/// clickable would be a second hit region to keep in agreement with the first.
struct VisionGhostCell: View {
    let slot: VisionBoardLayout.Slot

    var body: some View {
        let size = VisionGrid.blockSize(columns: slot.w, rows: slot.h)
        let origin = VisionGrid.origin(col: slot.col, row: slot.row)

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
/// It carried a `legal` flag, which rendered grey for "there is nowhere of this
/// size left". That state no longer exists: since #446's rework the block goes
/// exactly where the pointer puts it and the board displaces around it, so every
/// cell is a legal destination and the flag was permanently true.
struct VisionTargetSlot: View {
    let slot: VisionBoardLayout.Slot

    var body: some View {
        let size = VisionGrid.blockSize(columns: slot.w, rows: slot.h)
        let origin = VisionGrid.origin(col: slot.col, row: slot.row)
        let tint = Tokens.accentVision

        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(tint.opacity(0.10))
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
            Text("Click anywhere to add the first thing you're carrying.")
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .padding(.top, Space.sm)

            Button(action: onCreate) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(Tokens.borderStrong, style: StrokeStyle(lineWidth: 0.5, dash: [6, 5]))
                    // The size a click actually makes, read from the same
                    // constants creation reads. It was a hardcoded 2 × 3, which
                    // was correct until the lattice changed under it and then
                    // silently promised a block a third the width of the real
                    // one.
                    .frame(
                        width: VisionGrid.blockSize(
                            columns: VisionGrid.newColumns, rows: VisionGrid.newRows).width,
                        height: VisionGrid.blockSize(
                            columns: VisionGrid.newColumns, rows: VisionGrid.newRows).height
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
