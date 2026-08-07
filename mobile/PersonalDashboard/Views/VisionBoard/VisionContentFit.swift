import Foundation
import CoreGraphics

/// How much of a block's list fits inside it (#446).
///
/// Small arithmetic, and the reason it is tested rather than eyeballed is that
/// every way it goes wrong looks like a slightly-off card rather than like a
/// bug: a row clipped by the bottom edge, a `+N more` that lies about the count,
/// content hidden while empty space sits under it. None of those announce
/// themselves, and the only manual check is resizing a block by hand and
/// counting rows — the loop this feature already spent four rounds in.
///
/// So it lives here, pure, and is unit tested in `VisionContentFitTests` from
/// the iOS suite, alongside `VisionBoardLayout` and `VisionHitTest`. NOT inside
/// `VisionBlockCard`, where the only way to check it would be to click.
///
/// Tasks and items are ONE list of one row height, so this no longer divides a
/// budget between two kinds — the first pass did, when items rendered as short
/// grey lines. What is left is the part that was never simple: an overflow
/// summons a `+N more` row, that row costs height, and paying for it can hide a
/// row that would otherwise have fitted.
enum VisionContentFit {

    /// What a block should render, given its budget.
    struct Fit: Equatable {
        /// How many rows to show inline.
        var rows: Int
        /// How many did not fit.
        var hidden: Int
    }

    /// Fit `rows` into `budget` points.
    ///
    /// - Parameters:
    ///   - budget: height available for the list, after the card's chrome (rail,
    ///     padding, title, intent, meta line, add row) has been taken out. May be
    ///     negative on a block resized down past its contents, which is a normal
    ///     state and yields an all-hidden fit rather than a negative row count.
    ///   - ceiling: the tier's own cap regardless of space. Three at medium,
    ///     unbounded at large — a tall medium block deliberately leaves space
    ///     empty rather than listing everything.
    static func fit(budget: CGFloat, rows: Int, ceiling: Int = .max) -> Fit {
        let total = max(0, rows)
        let shown = min(total, min(ceiling, rowCount(in: budget)))
        guard total - shown > 0 else { return Fit(rows: shown, hidden: 0) }

        // Something overflowed, so the `+N more` row is now on screen and has to
        // come out of the same budget.
        let withMore = budget - VisionBlockMetrics.moreRow - VisionBlockMetrics.tileSpacing
        let squeezed = min(total, min(ceiling, rowCount(in: withMore)))
        return Fit(rows: squeezed, hidden: total - squeezed)
    }

    /// Rendered height of `count` rows, gaps included. Zero for none, so the
    /// caller never adds a gap above an empty list.
    static func height(ofRows count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * VisionBlockMetrics.tileHeight
            + CGFloat(count - 1) * VisionBlockMetrics.tileSpacing
    }

    // MARK: - Internals

    /// How many rows fit in `budget`.
    ///
    /// The `+ tileSpacing` is what makes the last row free of a trailing gap: n
    /// rows occupy `n × height + (n − 1) × spacing`, so the budget is short by
    /// exactly one spacing of being divisible by the unit. Without it a block
    /// sized to hold three rows exactly would show two.
    private static func rowCount(in budget: CGFloat) -> Int {
        guard budget > 0 else { return 0 }
        let unit = VisionBlockMetrics.tileHeight + VisionBlockMetrics.tileSpacing
        return max(0, Int(((budget + VisionBlockMetrics.tileSpacing) / unit).rounded(.down)))
    }
}
