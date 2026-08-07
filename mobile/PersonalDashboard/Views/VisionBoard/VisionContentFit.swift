import Foundation
import CoreGraphics

/// How much of a block's contents fit inside it (#446).
///
/// A block holds two lists that compete for the same vertical budget: its own
/// notes and the tasks it borrows. Deciding how many of each to show is small
/// arithmetic with several ways to be quietly wrong — showing a row that then
/// clips off the bottom edge, or paying for the `+N more` row twice, or hiding
/// content while leaving empty space under it — and none of those announce
/// themselves. They just look like a slightly-off card.
///
/// So it lives here, pure, and is unit-tested in `VisionContentFitTests` from
/// the iOS suite, alongside `VisionBoardLayout` and `VisionHitTest`. NOT inside
/// `VisionBlockCard`, where the only way to check it would be to resize a block
/// by hand and count rows — which is the exact loop this feature already spent
/// four rounds in.
///
/// Notes are laid out ABOVE tiles and get first claim on the budget. Reading
/// order on a block goes from what it is to what is left to do: title, intent,
/// the block's own lines, then the tasks. It also means the thing you can only
/// see here outranks the thing you can also see in Tasks.
enum VisionContentFit {

    /// What a block should render, given its budget.
    struct Fit: Equatable {
        /// How many notes to show inline.
        var notes: Int
        /// How many tiles to show inline.
        var tiles: Int
        /// Everything that did not fit, notes and tiles together, as one number.
        ///
        /// One count rather than two because it backs one button. `+3 more` is
        /// the truth the user needs; splitting it into `+1 note, +2 tasks` would
        /// be a more precise answer to a question nobody asked, on a card whose
        /// entire design brief is to fit on a board with thirty others.
        var hidden: Int
    }

    /// Fit `notes` and `tiles` into `budget` points.
    ///
    /// - Parameters:
    ///   - budget: height available for the whole content stack, after the
    ///     card's chrome (rail, padding, title, intent, meta line, add row) has
    ///     been taken out. May be negative on a block resized down past its
    ///     contents, which is a normal state and yields an all-hidden fit rather
    ///     than a negative row count.
    ///   - tileCeiling: the tier's own cap on tiles regardless of space. Three
    ///     at medium, unbounded at large — a tall medium block deliberately
    ///     leaves space empty rather than listing everything.
    static func fit(
        budget: CGFloat,
        notes: Int,
        tiles: Int,
        tileCeiling: Int = .max
    ) -> Fit {
        let notesShown = min(
            max(0, notes),
            min(VisionBlockMetrics.maxInlineNotes, noteRows(in: budget))
        )

        // Charged only when both groups are present, because it is the gap
        // BETWEEN them. Charging it unconditionally would cost every
        // notes-only block one tile's worth of nothing.
        let separator = (notesShown > 0 && tiles > 0) ? VisionBlockMetrics.tileSpacing : 0
        let afterNotes = budget - height(ofNotes: notesShown) - separator

        let tilesShown = min(max(0, tiles), min(tileCeiling, tileRows(in: afterNotes)))
        let hidden = (notes - notesShown) + (tiles - tilesShown)
        guard hidden > 0 else {
            return Fit(notes: notesShown, tiles: tilesShown, hidden: 0)
        }

        // Something overflowed, so the `+N more` row is now on screen and has to
        // come out of the same budget. Only the tiles are re-fitted: the notes
        // are already capped at four and re-cutting them here would mean the
        // arithmetic could take away a row it had just granted, for a button
        // that appeared BECAUSE of an overflow further down the card.
        let withMore = afterNotes - VisionBlockMetrics.moreRow - VisionBlockMetrics.tileSpacing
        let squeezed = min(max(0, tiles), min(tileCeiling, tileRows(in: withMore)))
        return Fit(
            notes: notesShown,
            tiles: squeezed,
            hidden: (notes - notesShown) + (tiles - squeezed)
        )
    }

    /// Rendered height of `count` notes, gaps included. Zero for none, so the
    /// caller never adds a gap above an empty group.
    static func height(ofNotes count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * VisionBlockMetrics.noteRow
            + CGFloat(count - 1) * VisionBlockMetrics.noteSpacing
    }

    // MARK: - Internals

    /// How many rows of `row` points, separated by `spacing`, fit in `budget`.
    ///
    /// The `+ spacing` is what makes the last row free of a trailing gap: n rows
    /// occupy `n × row + (n − 1) × spacing`, so the budget is short by exactly
    /// one spacing of being divisible by the unit. Without it a block sized to
    /// hold three tiles exactly would show two.
    ///
    /// Both dimensions are passed rather than a combined unit. Deriving the
    /// spacing back out of a unit means the two callers are told apart by a
    /// float comparison, and the day `noteRow + noteSpacing` happens to equal
    /// `tileHeight + tileSpacing` it silently starts using the wrong one.
    private static func rows(in budget: CGFloat, row: CGFloat, spacing: CGFloat) -> Int {
        guard budget > 0, row > 0 else { return 0 }
        return max(0, Int(((budget + spacing) / (row + spacing)).rounded(.down)))
    }

    private static func noteRows(in budget: CGFloat) -> Int {
        rows(in: budget, row: VisionBlockMetrics.noteRow, spacing: VisionBlockMetrics.noteSpacing)
    }

    private static func tileRows(in budget: CGFloat) -> Int {
        rows(in: budget, row: VisionBlockMetrics.tileHeight, spacing: VisionBlockMetrics.tileSpacing)
    }
}
