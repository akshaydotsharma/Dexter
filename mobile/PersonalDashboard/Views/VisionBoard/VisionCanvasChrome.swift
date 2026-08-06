import SwiftUI

#if os(macOS)

/// The canvas's own furniture (#446): the lattice, the ghost cell, the drag
/// slots, and the empty-board invitation.
///
/// The principle behind all of it: **placeability is revealed by attention, not
/// printed on the ground.** A permanent dot grid turns a warm-paper surface into
/// graph paper and pays visual noise across every square point of a 3000pt
/// canvas in exchange for information the user needs at exactly one moment. So
/// the idle canvas is `Tokens.paper` and nothing else, and each piece below
/// appears only while it is being used.
///
/// All of it is `accessibilityHidden`. Every one of these is pointer feedback;
/// the keyboard route to the same outcomes is on the block itself.

// MARK: - Level 3: the full lattice

/// Dots at every cell corner, shown only while a block is being dragged or
/// resized.
///
/// A `Shape` rather than a `Canvas`: `Tokens.borderStrong` is a dynamic
/// light/dark pair, and a filled shape lets SwiftUI resolve it exactly the way
/// every other token in the app is resolved instead of routing it through
/// `GraphicsContext`. Roughly 470 dots on a 3000 × 2000 canvas, which is one
/// cheap path.
struct VisionGridLattice: View {
    let size: CGSize

    var body: some View {
        DotLattice(dotSize: 1.5)
            .fill(Tokens.borderStrong.opacity(0.35))
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct DotLattice: Shape {
    let dotSize: CGFloat

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

// MARK: - Level 2: the ghost cell

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
