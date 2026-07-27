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
