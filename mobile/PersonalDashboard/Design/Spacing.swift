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
}

// MARK: - Corner radius

enum Radius {
    static let sm:   CGFloat = 6
    static let md:   CGFloat = 10
    static let lg:   CGFloat = 12
    static let xl:   CGFloat = 16
    static let pill: CGFloat = 999
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
