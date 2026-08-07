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
///
/// ### Space is the only limit
///
/// There used to be a second one: medium blocks were capped at three rows
/// regardless of height, to stop a tall board being three hundred lines of task
/// text. Reversed on report 2026-08-07, because the cap is invisible and
/// therefore reads as a bug — a block showing `+2 more` above half a card of
/// empty space is the interface refusing to use room you can see it has, with
/// nothing on screen to say why. *"If there is one space below Add item, then
/// the sub-item should show in the tile itself."*
///
/// The anti-wall-of-text guard did not go with it. It lives where it can be
/// seen: a SMALL block shows no rows at all, which is a whole tier of
/// presentation rather than a hidden subtraction, and a block that lists too
/// much can be made shorter with the same grip that made it tall.
enum VisionContentFit {

    /// What a block should render, given its budget.
    struct Fit: Equatable {
        /// How many rows to show inline.
        var rows: Int
        /// How many did not fit.
        var hidden: Int
    }

    /// What `block` should show of a list `rows` long.
    ///
    /// The card's whole answer, not just the division at the end of it. The
    /// budget arithmetic used to live in `VisionBlockCard` as a private computed
    /// property, and the defect reported on 2026-08-07 — `+2 more` above half a
    /// card of empty space — was IN that arithmetic, one line below the last
    /// thing this file could see. A test on `fit(budget:rows:)` alone would have
    /// stayed green through it, which makes the seam the bug rather than the
    /// code either side of it.
    ///
    /// Measured by arithmetic and never by a `GeometryReader`. The block's height
    /// is already known exactly (`rows × cellHeight − gutter`), so reading it
    /// back from layout would be measuring a number the card set itself, and
    /// during a resize it would feed the layout into itself — the hazard
    /// `TripCoverMetrics` documents. Deliberately conservative: it always
    /// reserves two lines for the title, so a one-line title shows one fewer row
    /// than it strictly could. The other way round clips a row off the bottom
    /// edge, and only one of those is a visual defect.
    static func fit(for block: VisionBlock, rows: Int) -> Fit {
        // Small shows no list at all — that whole tier IS the anti-wall-of-text
        // guard. `hidden: 0` rather than `hidden: rows` because the card does
        // not render the stack, so there is no `+N more` for the count to reach.
        guard block.tier != .small else { return Fit(rows: 0, hidden: 0) }

        var budget = VisionGrid.blockSize(columns: block.w, rows: block.h).height
        budget -= VisionGrid.railHeight
        budget -= Space.md * 2                              // card padding
        budget -= VisionBlockMetrics.titleLine * 2          // title, worst case
        if !(block.intent ?? "").isEmpty {
            budget -= VisionBlockMetrics.intentLine + Space.xxs
        }
        if rows > 0 { budget -= VisionBlockMetrics.metaLine + Space.xs }
        budget -= Space.md                                  // gap above the stack
        // The `+ Add item` row is content-adjacent rather than chrome: it sits
        // inside the stack and costs a gap above itself. Charged here so it can
        // never be the thing that gets clipped — it is the only way to put
        // anything on the block, so losing it costs more than losing a row.
        budget -= VisionBlockMetrics.addItemRow + VisionBlockMetrics.tileSpacing
        if block.tier == .large { budget -= VisionBlockMetrics.addRowBlock }

        return fit(budget: budget, rows: rows)
    }

    /// Fit `rows` into `budget` points.
    ///
    /// - Parameters:
    ///   - budget: height available for the list, after the card's chrome (rail,
    ///     padding, title, intent, meta line, add row) has been taken out. May be
    ///     negative on a block resized down past its contents, which is a normal
    ///     state and yields an all-hidden fit rather than a negative row count.
    static func fit(budget: CGFloat, rows: Int) -> Fit {
        let total = max(0, rows)
        let shown = min(total, rowCount(in: budget))
        guard total - shown > 0 else { return Fit(rows: shown, hidden: 0) }

        // Something overflowed, so the `+N more` row is now on screen and has to
        // come out of the same budget.
        let withMore = budget - VisionBlockMetrics.moreRow - VisionBlockMetrics.tileSpacing
        let squeezed = min(total, rowCount(in: withMore))
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
