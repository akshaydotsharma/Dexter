import Foundation
import CoreGraphics

/// Pure grid arithmetic for the vision board (#446).
///
/// Kept out of the view and the view model on purpose: overlap and free-slot
/// search are the two pieces of this feature that are genuinely easy to get
/// subtly wrong, and they are the two pieces that can be reasoned about with no
/// SwiftUI, no store, and no gesture state in scope.
enum VisionBoardLayout {

    /// One block's occupied rectangle, in cells.
    struct Slot: Equatable {
        var col: Int
        var row: Int
        var w: Int
        var h: Int

        func overlaps(_ other: Slot) -> Bool {
            col < other.col + other.w
                && other.col < col + w
                && row < other.row + other.h
                && other.row < row + h
        }
    }

    /// Whether `slot` can be placed without touching any block other than
    /// `excluding` (the one being dragged or resized, which must not collide
    /// with where it currently is).
    static func isFree(_ slot: Slot, in blocks: [VisionBlock], excluding: UUID?) -> Bool {
        guard slot.col >= 0, slot.row >= 0 else { return false }
        for block in blocks where block.id != excluding {
            let occupied = Slot(col: block.col, row: block.row, w: block.w, h: block.h)
            if slot.overlaps(occupied) { return false }
        }
        return true
    }

    /// The nearest legal slot to `desired`, searching outward in rings.
    ///
    /// The concept doc is explicit that an overlapping drop NUDGES rather than
    /// refuses, so this is the whole "invalid drop" story: in normal operation
    /// there is always an answer and the target slot always shows a legal
    /// destination. `nil` means the search exhausted `maxRings` without finding
    /// anywhere, which is what the grey (never red) slot renders.
    ///
    /// Ring order rather than a scan of the whole canvas because the answer is
    /// almost always one cell away, and a full scan of a board-sized grid on
    /// every pointer move during a drag is work nobody sees.
    static func nearestFreeSlot(
        to desired: Slot,
        in blocks: [VisionBlock],
        excluding: UUID?,
        maxRings: Int = 24
    ) -> Slot? {
        if isFree(desired, in: blocks, excluding: excluding) { return desired }

        for ring in 1...maxRings {
            var best: Slot?
            var bestDistance = Double.greatestFiniteMagnitude

            for dRow in -ring...ring {
                for dCol in -ring...ring {
                    // Only the perimeter of this ring; the interior was covered
                    // by a previous, strictly nearer pass.
                    guard abs(dRow) == ring || abs(dCol) == ring else { continue }
                    var candidate = desired
                    candidate.col += dCol
                    candidate.row += dRow
                    guard candidate.col >= 0, candidate.row >= 0 else { continue }
                    guard isFree(candidate, in: blocks, excluding: excluding) else { continue }

                    // Euclidean, so a diagonal neighbour loses to an orthogonal
                    // one at the same ring. Chebyshev rings with a Euclidean
                    // tie-break is what makes the nudge feel like it went the
                    // short way rather than the first way found.
                    let distance = Double(dCol * dCol + dRow * dRow)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = candidate
                    }
                }
            }
            if let best { return best }
        }
        return nil
    }

    /// The canvas size needed to hold `blocks`, plus room to keep going.
    ///
    /// The canvas grows on demand, which is why "no free slot anywhere" is
    /// nearly unreachable: there is always more board below and to the right.
    /// `viewport` sets the floor so an empty or sparse board still fills the
    /// window and double-click-to-create works anywhere you can see.
    static func canvasSize(for blocks: [VisionBlock], viewport: CGSize) -> CGSize {
        let maxCol = blocks.map { $0.col + $0.w }.max() ?? 0
        let maxRow = blocks.map { $0.row + $0.h }.max() ?? 0
        // Two spare cells past the last block in each axis: enough to drop a new
        // block beyond everything without the scroll extent jumping as you drag.
        let width  = CGFloat(maxCol + 2) * VisionGrid.cellWidth
        let height = CGFloat(maxRow + 2) * VisionGrid.cellHeight
        return CGSize(
            width:  max(width,  viewport.width),
            height: max(height, viewport.height)
        )
    }
}
