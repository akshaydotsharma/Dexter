import SwiftUI

// MARK: - Spacing scale

enum Space {
    static let xxs:  CGFloat = 2
    static let xs:   CGFloat = 4
    static let sm:   CGFloat = 8
    static let md:   CGFloat = 12
    static let lg:   CGFloat = 16
    static let xl:   CGFloat = 24
    static let xxl:  CGFloat = 32
    static let xxxl: CGFloat = 48

    // MARK: - Semantic spacing

    /// Vertical gap between a form field's label (eyebrow) and its input
    /// control. Standardized across every editor / detail / settings sheet so
    /// the label-over-field rhythm reads the same everywhere. Sits between
    /// `xs` (too tight) and `md`.
    static let fieldLabelGap: CGFloat = 8

    /// Trailing gutter for a `List` row that carries a trailing control (the
    /// info icon on task / list-item rows). Tight on macOS so the icon hugs the
    /// window edge instead of leaving a wide right-hand gap (issue #285); iOS
    /// keeps the symmetric `lg` gutter, byte-for-byte unchanged.
    ///
    /// Superseded on macOS by `.contentRowInsets()` (#339), which zeroes the
    /// row inset entirely and lets the row's own padding set the margin. Kept
    /// for any surface still setting insets by hand.
    static var rowTrailingGutter: CGFloat {
        #if os(macOS)
        Space.xs
        #else
        Space.lg
        #endif
    }
}

// MARK: - Row insets (issue #339)

extension View {
    /// `listRowInsets` for a row that already owns its horizontal padding.
    ///
    /// On macOS every list surface was paying its inset twice: a row with 16pt
    /// of internal padding sat inside a 16pt `listRowInsets`, so content began
    /// 32pt from the pane edge and the row's hairline stopped 16pt short of
    /// both edges. Lists read as not reaching the right edge of the window, and
    /// Trips rows started further in than the rule above them.
    ///
    /// Zeroing the horizontal inset on macOS makes the row span the pane, so
    /// hairlines and selection run edge to edge and the single content margin
    /// is the one the row itself declares (`RowMetrics.horizontalPadding`).
    /// That margin is also what the section headers use, which is why headers
    /// and rows now line up.
    ///
    /// iOS keeps the `Space.lg` gutter its floating cards need, unchanged.
    ///
    /// - Parameter vertical: the row's existing vertical inset, per surface.
    func contentRowInsets(vertical: CGFloat = 0) -> some View {
        #if os(macOS)
        return listRowInsets(EdgeInsets(top: vertical, leading: 0, bottom: vertical, trailing: 0))
        #else
        return listRowInsets(EdgeInsets(top: vertical, leading: Space.lg, bottom: vertical, trailing: Space.lg))
        #endif
    }
}

// MARK: - Flat content rows (issue #303)

/// Metrics for a flat content row, shared by every section that lists records.
///
/// These exist as tokens rather than per-file literals on purpose. Two font
/// literals in this codebase have already inverted because a numeric
/// relationship was asserted in a comment instead of expressed in code
/// (`TaskRowMetrics.titleFont` and `MacClearTextField`'s NSFont, both #301).
/// Row padding relates across six surfaces in five files, so the same mistake
/// is available here and would be harder to spot.
///
/// macOS converges on Activity's flat row, which the audit measured as the
/// closest thing in the app to the Reminders and Mail reference: no card, no
/// border, hairline separators, and the pane's own background showing through.
/// iOS keeps its gapped cards, so every value below is unchanged there.
enum RowMetrics {
    /// Vertical padding inside a row.
    static var verticalPadding: CGFloat {
        #if os(macOS)
        6
        #else
        Space.sm + 2
        #endif
    }

    /// Horizontal padding inside a row. Wider on macOS because a flat row has
    /// no card inset of its own to sit within.
    static var horizontalPadding: CGFloat {
        #if os(macOS)
        Space.lg
        #else
        Space.md
        #endif
    }

    /// Leading icon chip. iOS keeps the 36pt touch-scaled chip.
    static var iconChip: CGFloat {
        #if os(macOS)
        26
        #else
        36
        #endif
    }

    /// Horizontal padding for a block of flat rows laid out in a `ScrollView`
    /// rather than a `List` (Finance's day groups, recurring expenses). The
    /// `List` surfaces get the same effect from `.contentRowInsets()`; this is
    /// the hand-rolled equivalent, and it exists so those rows reach the pane
    /// edge on macOS like every other row does (#339).
    static var rowBlockPadding: CGFloat {
        #if os(macOS)
        0
        #else
        Space.lg
        #endif
    }

    /// Horizontal padding for a header sitting above such a block. It has to
    /// line up with the row CONTENT, not the row edge, so it carries the
    /// content margin on macOS and nothing on iOS, where the block's own
    /// padding already positions it.
    static var rowBlockHeaderPadding: CGFloat {
        #if os(macOS)
        RowMetrics.horizontalPadding
        #else
        0
        #endif
    }

    /// Inset for a row's leading accent rail (the task priority bar), so it
    /// doesn't sit flush against the sidebar seam once rows are full-bleed.
    static var accentRailInset: CGFloat {
        #if os(macOS)
        Space.xs
        #else
        0
        #endif
    }

    /// Horizontal inset of a task row's priority wash (#376), so the tinted
    /// pill floats instead of running into the pane edge. Same reasoning as
    /// `accentRailInset` — full-bleed rows on macOS (#339) put the row edge on
    /// the sidebar seam, and colour landing there reads as a second pane.
    static var priorityWashInset: CGFloat {
        #if os(macOS)
        Space.xs
        #else
        0
        #endif
    }

    /// Horizontal inset of a rule that separates rows in a list (the Completed
    /// divider, an add-row's section hairline, a detail header's underline).
    ///
    /// Zero on macOS, where rows are full-bleed (#339) and a rule that stopped
    /// short of the window edge would contradict the row hairlines around it.
    /// iOS keeps the `lg` inset its carded rows sit within.
    static var hairlineInset: CGFloat {
        #if os(macOS)
        0
        #else
        Space.lg
        #endif
    }

    /// Leading offset for an add-row's bullet, so it lands on the same x as the
    /// completion circle of the real rows above it. That column is one content
    /// margin in on macOS, and the old inset-plus-padding sum on iOS.
    static var addRowLeading: CGFloat {
        #if os(macOS)
        RowMetrics.horizontalPadding
        #else
        Space.lg + Space.md
        #endif
    }

    /// The ⓘ glyph that opens a row's detail view (issue #340). Task rows drew
    /// it at 18pt in a 32pt target and list-item rows at 16pt in a 30pt one, a
    /// difference visible side by side and invisible in either file on its own.
    /// Tokenised so the two cannot drift again; the larger of the two wins,
    /// since it was already the more comfortable target.
    static let rowInfoGlyph: CGFloat = 18
    /// Hit target around `rowInfoGlyph`.
    static let rowInfoTarget: CGFloat = 32

    /// Gap between rows. Zero on macOS, where a hairline does the separating;
    /// iOS keeps the gap that its cards float in.
    static var interRowSpacing: CGFloat {
        #if os(macOS)
        0
        #else
        Space.xs
        #endif
    }
}

// MARK: - Trip cover band (issue #428)

/// Metrics for the destination-photo band on a trip tile.
///
/// These live here, next to `RowMetrics`, rather than as literals inside the row
/// for the reason `RowMetrics` already spells out: Past's band is a
/// *relationship* to the normal band (shorter, wider ratio, lower ceiling), and
/// this codebase has twice had a numeric relationship silently invert because it
/// was asserted in a comment instead of expressed in code. Side by side the two
/// sets can be read as one table.
///
/// Nothing here is `.infinity`. A band that could grow without bound inside a
/// `List` row is the layout-feedback hazard this ticket set out to avoid.
enum TripCoverMetrics {
    // MARK: Band proportion — the same for every trip

    /// Width-to-height ratio of the band. Height derives from the card's width,
    /// with no `GeometryReader` — a `GeometryReader` that determines its own
    /// row's height inside a `List` feeds the layout back into itself.
    ///
    /// 4:1 for EVERY trip since the move to generated illustration. This was the
    /// shallower proportion previously reserved for Past, and it is now standard:
    /// the art is a wide shallow skyline strip on empty sky, so a 2.4:1 band would
    /// be mostly sky. It is also the proportion `TripCoverCrop` targets, so these
    /// two numbers are the same decision expressed twice — see
    /// `TripCoverCrop.bandRatio`.
    ///
    /// Past no longer differs in SIZE at all. It recedes by treatment: reduced
    /// saturation, a theme-aware veil, and a demoted name. Fixed on the band and the
    /// type, never with card-wide opacity, which would dim the text with it and drop
    /// `Tokens.muted` below 4.5:1.
    static let ratio: CGFloat = 4.0
    static let minHeight: CGFloat = 84

    /// Ceiling on the band's height. 192, raised from 132 in #441.
    ///
    /// Not a taste number. The cached file is 1536 × 384 px, which is 768 × 192 pt at
    /// 2×, so 192 is exactly the height at which the band displays the artwork at its
    /// native resolution. Every point above it would upscale a bitmap; every point
    /// below it throws away detail that was paid for. On a phone the width clamp bites
    /// first and the band never gets near this, so the ceiling is a macOS number in
    /// practice.
    ///
    /// The old 132 was inherited from the photography era and predates the file being
    /// a fixed 4:1 strip. It is what made a wide Mac window crop the skyline: above
    /// 528 pt of card width the band stopped being 4:1, and the artwork was scaled to
    /// the width and centre-cropped, which eats the buildings' base. `TripCoverBand`
    /// no longer scales by width at all — see the artwork rule there — so this is now
    /// only about how much of the file's own resolution the band gets to show.
    static let maxHeight: CGFloat = 192

    /// Ceiling once the user is at an accessibility text size. The text block
    /// grows several lines taller there, so the band has to give way or a single
    /// tile fills the screen.
    ///
    /// A genuinely lower ceiling again since `maxHeight` moved to 192. It stays at the
    /// old 132: a band that grows while the text block is already several lines taller
    /// is the exact combination this clamp exists to prevent, and nothing about the
    /// artwork's native size argues for spending that height on a picture there.
    static let accessibilityMaxHeight: CGFloat = 132

    // MARK: Band edge treatment

    /// Height of the clear-to-`Tokens.coverSeamVeil` gradient at the band's
    /// bottom edge.
    static let veilHeight: CGFloat = 24
    /// The seam rule under the band. `Tokens.border`, not `Tokens.divider`,
    /// which vanishes on lighter surfaces in light mode.
    static let seamHeight: CGFloat = 0.5
    /// Partial desaturation for a Past cover. `.grayscale(1.0)` reads as disabled,
    /// which would be a lie — Past trips are still tappable and still carry their
    /// expenses. 0.5 on flat illustration, slightly stronger than the 0.55 that
    /// suited photography, because the art's palette is already muted so it needs a
    /// little more to read as receded.
    static let pastSaturation: Double = 0.5
    /// Adaptive veil over the whole Past band. `Tokens.paper` because it IS an
    /// adaptive pair, so it lifts in light mode and darkens in dark mode, which
    /// is the correct direction in both. Now that Past keeps the full band height,
    /// this and the saturation do the whole job, so it is a touch stronger.
    static let pastVeilOpacity: Double = 0.12

    // MARK: Generated cover art

    /// Oversized watermark glyph on the glyph fallback art, which is what a trip
    /// whose name is not a place keeps permanently and what every trip shows while
    /// its illustration is being generated.
    ///
    /// 110pt, not the wallet `heroPanel`'s 150pt: every band is 4:1 now, so the band
    /// is as short as the old Past one was and 150pt overflowed it. One value, since
    /// Past no longer differs in size.
    static let watermark: CGFloat = 110

    // MARK: Text block

    /// Horizontal padding of the text block under the band.
    ///
    /// A deliberate departure from `RowMetrics.horizontalPadding` (12pt on iOS),
    /// which reads tight against a 328pt-wide photograph. The band sets the
    /// tile's optical width now, so the text has to be inset to match it.
    static let textHorizontalPadding: CGFloat = Space.lg
    /// Vertical padding of the text block.
    static let textVerticalPadding: CGFloat = Space.md

    /// The Active status dot on the meta line.
    static let statusDotSize: CGFloat = 6
    /// Gap between that dot and the meta text.
    static let statusDotGap: CGFloat = 6

    /// Horizontal inset of the whole card.
    ///
    /// Trips opts out of `flatContentRow()` (see `TripRow`), so it is the one
    /// section that stays a card on macOS. `contentRowInsets` zeroes the
    /// horizontal row inset there, which is right for a flat row and wrong for a
    /// 220pt photograph: it would put the photo directly on the sidebar seam.
    /// The project has already added `accentRailInset` and `priorityWashInset`
    /// for exactly this, at far lower volume. iOS needs nothing — its row inset
    /// already supplies the gutter its cards float in.
    static var cardHorizontalInset: CGFloat {
        #if os(macOS)
        Space.lg
        #else
        0
        #endif
    }
}

// MARK: - Vision Board grid (issue #446)

/// Snap lattice for the board.
///
/// A "cell" INCLUDES its gutter, so a block occupying `c × r` cells renders at
/// `c*cellWidth - gutter` by `r*cellHeight - gutter`. Expressing it this way
/// means the gutter cannot drift out of sync with the snap unit, which is the
/// failure mode `RowMetrics` above warns about for related numbers held apart:
/// two literals that must agree, asserted in a comment rather than in code, have
/// already silently inverted twice in this codebase.
///
/// **The lattice is square** (#446, revised 2026-08-07). It was 184 × 68, which
/// made a block travel nearly three cells horizontally for every one vertically
/// and made "one cell" mean two different distances depending on which way you
/// pushed. Both axes now use the VERTICAL pitch, 68pt, because that was the one
/// already tuned against the card's interior rhythm — a 56pt block cell plus the
/// 12pt gutter. Widths therefore quantise nearly three times as finely, which is
/// the whole point: a block can now be the width it wants to be.
///
/// Everything that used to be expressed in columns had to be re-derived, and
/// every block already on disk had to be rescaled. See
/// `VisionBoardLayout.migrateToSquareGrid` for the rescale and `schemaVersion`
/// below for how a block records which lattice it was written under.
enum VisionGrid {
    static let gutter: CGFloat = Space.md   // 12

    /// The one pitch, both axes: 56pt of block + 12pt gutter.
    static let cell: CGFloat = 68

    /// Held as separate names so the axis a call site means stays legible, and
    /// so a future non-square lattice is one edit rather than a hunt. They are
    /// the same number today and `cell` is the only literal.
    static var cellWidth:  CGFloat { cell }
    static var cellHeight: CGFloat { cell }

    /// The lattice generation a stored block's `col`/`w` are expressed in.
    ///
    /// 0 (or a missing value) is the original 184pt-wide lattice; 1 is the
    /// square one. Bump this ONLY when a change invalidates stored column
    /// numbers, and add the matching arm to
    /// `VisionBoardLayout.migrateToSquareGrid`. The marker is what makes the
    /// rescale one-shot: it is written in the same save as the new coordinates,
    /// so a block is either fully on the old lattice or fully on the new one and
    /// there is no state in which a second pass would scale it twice.
    static let schemaVersion = 1

    /// Minimum block: 3 × 2 cells = 192 × 124pt.
    ///
    /// 3 columns, not 1, because the minimum is a PHYSICAL claim — it is the
    /// narrowest card that still fits rail, header and meta line — and the
    /// square lattice changed what a column is worth. 1 column used to mean
    /// 172pt; the nearest the finer pitch can get is 3 cells at 192pt (2 cells
    /// is 124pt, which is 48pt short rather than 20pt over).
    static let minColumns = 3
    static let minRows    = 2

    /// The size a newly created block gets: 5 × 3 cells = 328 × 192pt, the
    /// medium tier. The old default was 2 × 3 = 356 × 192pt; 5 cells is the
    /// closest the finer pitch gets without going over.
    ///
    /// Named rather than defaulted at three call sites, because the ghost cell
    /// under the pointer is a preview of exactly this and a click on it makes
    /// exactly this. The moment the preview and the creation disagree about the
    /// footprint, the plus is pointing at a cell the block will not land in.
    static let newColumns = 5
    static let newRows    = 3

    /// Tier boundaries in POINTS OF RENDERED WIDTH, never in columns.
    ///
    /// Columns were the wrong unit for this: the tier is a statement about how
    /// much type fits across the card, which is a physical quantity, and pinning
    /// it to the lattice meant changing the lattice silently re-tiered every
    /// block on the board. In points the same three tiers survive this change
    /// and the next one.
    ///
    /// The two values are chosen to be stable under the migration's rounding
    /// rather than to sit exactly on the old boundaries (172 / 356 / 540). A
    /// block rescaled from the old lattice lands within half a cell of its old
    /// width, so each boundary sits in the gap between the WORST case of the
    /// tier below and the BEST case of the tier above:
    ///
    /// | was      | rescales to  | rendered  | boundary | tier   |
    /// |----------|--------------|-----------|----------|--------|
    /// | 1 col    | 2 or 3 cells | 124 / 192 |          | small  |
    /// |          |              |           | **240**  |        |
    /// | 2 cols   | 5 or 6 cells | 328 / 396 |          | medium |
    /// |          |              |           | **500**  |        |
    /// | 3 cols   | 8 or 9 cells | 532 / 600 |          | large  |
    ///
    /// Both boundaries also reproduce the old tiers exactly when fed the old
    /// lattice's widths (172 → small, 356 → medium, 540 → large), so nothing
    /// about the intent moved; only the unit did.
    static let mediumMinWidth: CGFloat = 240
    static let largeMinWidth:  CGFloat = 500

    /// Rendered size of a block occupying `columns × rows` cells.
    static func blockSize(columns: Int, rows: Int) -> CGSize {
        CGSize(
            width:  CGFloat(columns) * cellWidth  - gutter,
            height: CGFloat(rows)    * cellHeight - gutter
        )
    }

    /// Top-left origin of the cell at `(col, row)`.
    static func origin(col: Int, row: Int) -> CGPoint {
        CGPoint(x: CGFloat(col) * cellWidth, y: CGFloat(row) * cellHeight)
    }

    /// The cell a canvas point falls in. Clamped at zero: a drag that runs off
    /// the top or leading edge should pin to the first cell rather than produce
    /// a negative column that no free-slot search can satisfy.
    static func cell(at point: CGPoint) -> (col: Int, row: Int) {
        (max(0, Int((point.x / cellWidth).rounded(.down))),
         max(0, Int((point.y / cellHeight).rounded(.down))))
    }

    /// Height of the state rail along a block's top edge.
    static let railHeight: CGFloat = 3
}

/// Interior metrics for a vision block, held next to the grid rather than as
/// literals inside the card.
///
/// These exist because the card has to decide how many tiles fit WITHOUT a
/// `GeometryReader`. The block's height is already known exactly (it is
/// `rows × cellHeight - gutter`), so reading it back from layout would be
/// measuring a number we set ourselves, and inside a resize gesture it would
/// feed the layout into itself — the same hazard `TripCoverMetrics` documents.
/// So capacity is arithmetic on this table instead.
///
/// The type heights are estimates of a rendered line, not measurements. They
/// are deliberately a touch generous: over-estimating shows one fewer tile than
/// would fit, under-estimating clips the `+N more` row off the bottom of the
/// card, and only one of those is a visual defect.
enum VisionBlockMetrics {
    /// One line of `.edHeading` (Inter SemiBold 13 on macOS).
    static let titleLine: CGFloat = 17
    /// One line of `.edSubheadline` (Inter 12), the intent line.
    static let intentLine: CGFloat = 15
    /// The progress-and-urgency meta line.
    static let metaLine: CGFloat = 16
    /// A tile, at the 26pt minimum that matches `RowMetrics.iconChip` on macOS.
    static let tileHeight: CGFloat = 26
    /// Gap between tiles.
    static let tileSpacing: CGFloat = Space.xs
    /// The `+N more` button row.
    static let moreRow: CGFloat = 14
    /// Rule plus add-row, at large only.
    static let addRowBlock: CGFloat = 26 + Space.sm + 0.5
    /// Reserved square for the hover-revealed ellipsis menu. Always occupied at
    /// rest so hovering a block shifts nothing.
    static let ellipsisSlot: CGFloat = 24
    /// Hit target for the bottom-right resize grip. Below the 24pt pointer
    /// minimum on purpose: the visible grip glyph carries the affordance, the
    /// whole corner reveals it on hover, and ⌥-arrow is the accessible route.
    static let resizeTarget: CGFloat = 20

    /// A note: one line of `.edSubheadline` with no tile chrome around it.
    ///
    /// Deliberately shorter than `tileHeight`. A note is the block's own line of
    /// text, a task is a borrowed record, and the height difference is the
    /// cheapest signal that they are not the same kind of thing.
    ///
    /// 20 and not 18, which is what a 12pt line wants. Clicking a note swaps the
    /// `Text` for an `NSTextField`, and an `NSTextField` carries cell padding a
    /// `Text` does not — at 18 it renders its descenders into the clip edge, so
    /// editing a note would visibly crop it.
    static let noteRow: CGFloat = 20
    /// Gap between notes. Tighter than `tileSpacing`, so a run of notes reads as
    /// one list rather than as several loose rows.
    static let noteSpacing: CGFloat = Space.xxs
    /// How many notes a block shows inline before the rest fold into `+N more`.
    ///
    /// A ceiling on top of whatever fits, at every tier. Notes are cheap to add
    /// and a block whose whole face is notes has stopped saying what it is —
    /// the same reason medium caps tiles at three.
    static let maxInlineNotes = 4
    /// Reserved trailing square on a tile or a note for its remove button.
    /// Always occupied, so revealing the button on hover shifts no text.
    static let rowActionSlot: CGFloat = 20
}

extension View {
    /// The one construction for a row that lists a record.
    ///
    /// Seven surfaces used a byte-identical chain of padding, a `Radius.card`
    /// surface fill, and a `paperBorder`. Converging them here rather than
    /// editing seven copies means the next change to row appearance is one
    /// edit, and a future divergence has to be deliberate.
    ///
    /// Seven, not the six the audit listed. `RecurringExpenseRow` was missed
    /// because that audit enumerated sections from screenshots, and a visual
    /// sweep can only find what it can see. The reliable check is grepping for
    /// the construction, which is how the seventh surfaced.
    ///
    /// macOS renders flat: no fill, no border, and the row's own top hairline,
    /// which is Activity's construction and the closest thing already in the app
    /// to Reminders and Mail. iOS keeps its gapped card (issue #303).
    ///
    /// - Parameter iOSVerticalPadding: the existing iOS value for this surface.
    ///   Passed in rather than tokenised, deliberately. The seven surfaces do
    ///   not agree today: 12pt on five, 10pt on the two expense rows. A single
    ///   token would read tidier and would silently move five iOS surfaces by
    ///   2pt, which is a cross-platform behaviour change disguised as cleanup.
    ///   The disagreement is real, so it stays visible at the call site until
    ///   someone decides to change iOS on purpose. Ignored on macOS, which uses
    ///   the shared metric because macOS has no such legacy to preserve.
    func flatContentRow(iOSVerticalPadding: CGFloat = Space.md) -> some View {
        #if os(macOS)
        return self
            .padding(.horizontal, RowMetrics.horizontalPadding)
            .padding(.vertical, RowMetrics.verticalPadding)
            .overlay(alignment: .top) { RowHairline() }
        #else
        return self
            .padding(.horizontal, RowMetrics.horizontalPadding)
            .padding(.vertical, iOSVerticalPadding)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.card)
        #endif
    }
}

/// The one hairline used to separate flat rows.
///
/// A single definition because the design language allows exactly one rule
/// technique: a 0.5pt `Rectangle`. The system `Divider()` resolves to a
/// different, thicker line on macOS, and the audit found one section already
/// mixing the two. Renders as nothing on iOS, where rows are carded and
/// separated by a gap instead.
struct RowHairline: View {
    var body: some View {
        #if os(macOS)
        Rectangle()
            .fill(Tokens.divider)
            .frame(height: 0.5)
        #else
        EmptyView()
        #endif
    }
}

// MARK: - Corner radius

enum Radius {
    static let sm:   CGFloat = 6
    static let md:   CGFloat = 10
    static let lg:   CGFloat = 12
    static let xl:   CGFloat = 16
    static let pill: CGFloat = 999

    /// Corner radius for a full-width content card / list-row card (Notes,
    /// Finance, Lists, Vocabulary, Trips). iOS keeps its established soft 26pt
    /// curve, byte-for-byte unchanged; macOS uses the tighter `xl` (16pt) so
    /// cards match the Today dashboard tiles and read less pill-like (#285).
    static var card: CGFloat {
        #if os(macOS)
        Radius.xl
        #else
        26
        #endif
    }
}

// MARK: - Shadows

extension View {
    func shadowSm() -> some View {
        shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
    }

    func shadowMd() -> some View {
        shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 4)
    }

    func shadowLg() -> some View {
        shadow(color: .black.opacity(0.10), radius: 20, x: 0, y: 10)
    }

    /// 0.5pt hairline border that matches the optical weight of 1px on web at 2x.
    func paperBorder(_ color: Color = Tokens.border, radius: CGFloat = Radius.xl, lineWidth: CGFloat = 0.5) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(color, lineWidth: lineWidth)
        )
    }
}
