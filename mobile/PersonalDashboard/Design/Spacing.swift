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
    static var rowTrailingGutter: CGFloat {
        #if os(macOS)
        Space.xs
        #else
        Space.lg
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
