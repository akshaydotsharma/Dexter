import SwiftUI

// MARK: - Editorial Calm typography
//
// Custom fonts: Calistoga (display serif), Inter (sans body), JetBrains Mono.
// All TTFs live in Resources/Fonts and are registered in Info.plist via UIAppFonts.
// If a custom font fails to load at runtime, .custom() silently falls back to the
// system font, so the layout still works on devices that didn't ship the font.

/// Point sizes for the Editorial Calm ramp, per platform (issue #294).
///
/// The ramp was authored for iOS and shared verbatim, so every string rendered
/// roughly 20 to 25 percent too large on the Mac: `edBody` was 16pt where the
/// macOS system body is 13pt. Individual surfaces had started working around it
/// locally (Tasks hardcodes a 15pt row title on macOS), which is the signal that
/// the scale itself was wrong rather than any one view.
///
/// Only the point sizes differ. Token names, weights, `relativeTo:` text styles,
/// and the hierarchy between steps are identical on both platforms, so nothing
/// downstream has to know which platform it is on.
///
/// **The iOS column is the shipped ramp, unchanged.** Every value in the `#else`
/// branch is the literal that previously sat inline in the token below it.
private enum EdSize {
    #if os(macOS)
    // Desktop ramp. Mapped onto macOS system conventions: body 13, headline 13
    // semibold, caption 10. See docs/design/macos-design-language.md section 1.
    static let display:        CGFloat = 22
    static let title:          CGFloat = 17
    static let heading:        CGFloat = 13
    static let body:           CGFloat = 13
    static let subheadline:    CGFloat = 12
    static let footnote:       CGFloat = 11
    static let caption:        CGFloat = 10
    static let eyebrow:        CGFloat = 10
    static let mono:           CGFloat = 11
    /// Tracking tuned for an 11pt eyebrow reads loose at 10pt, so it tightens.
    static let eyebrowTracking: CGFloat = 0.8
    #else
    // iOS ramp. Unchanged from the original inline literals.
    static let display:        CGFloat = 28
    static let title:          CGFloat = 22
    static let heading:        CGFloat = 17
    static let body:           CGFloat = 16
    static let subheadline:    CGFloat = 15
    static let footnote:       CGFloat = 13
    static let caption:        CGFloat = 12
    static let eyebrow:        CGFloat = 11
    static let mono:           CGFloat = 13
    static let eyebrowTracking: CGFloat = 1.4
    #endif
}

extension Font {
    private static func calistoga(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Calistoga-Regular", size: size, relativeTo: style)
    }

    private static func inter(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .medium:    name = "Inter-Medium"
        case .semibold:  name = "Inter-SemiBold"
        default:         name = "Inter-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    private static func jbMono(_ size: CGFloat, relativeTo style: Font.TextStyle = .footnote) -> Font {
        .custom("JetBrainsMono-Regular", size: size, relativeTo: style)
    }

    // Editorial Calm scale
    static let edDisplay     = calistoga(EdSize.display, relativeTo: .largeTitle)
    static let edTitle       = calistoga(EdSize.title, relativeTo: .title2)
    static let edHeading     = inter(EdSize.heading, weight: .semibold, relativeTo: .headline)
    static let edBody        = inter(EdSize.body, relativeTo: .body)
    static let edBodyMedium  = inter(EdSize.body, weight: .medium, relativeTo: .body)
    static let edSubheadline = inter(EdSize.subheadline, relativeTo: .subheadline)
    static let edFootnote    = inter(EdSize.footnote, weight: .medium, relativeTo: .footnote)
    static let edFootnoteStrong = inter(EdSize.footnote, weight: .semibold, relativeTo: .footnote) // bold footnote, e.g. the prominent time line on itinerary tiles
    static let edCaption     = inter(EdSize.caption, relativeTo: .caption)
    static let edEyebrow     = inter(EdSize.eyebrow, weight: .semibold, relativeTo: .caption2) // pair with .textCase(.uppercase) and .tracking(EdSize.eyebrowTracking)
    static let edMono        = jbMono(EdSize.mono, relativeTo: .footnote)
}

// MARK: - Eyebrow modifier

struct Eyebrow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.edEyebrow)
            .textCase(.uppercase)
            .tracking(EdSize.eyebrowTracking)
            .foregroundStyle(Tokens.muted)
    }
}

extension View {
    /// Renders a label as an Editorial Calm eyebrow:
    /// uppercase, tracked, semibold 11pt on iOS / 10pt on macOS, muted.
    func eyebrow() -> some View { modifier(Eyebrow()) }
}
