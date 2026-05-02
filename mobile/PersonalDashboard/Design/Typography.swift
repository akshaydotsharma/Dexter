import SwiftUI

// MARK: - Editorial Calm typography
//
// Custom fonts: Calistoga (display serif), Inter (sans body), JetBrains Mono.
// All TTFs live in Resources/Fonts and are registered in Info.plist via UIAppFonts.
// If a custom font fails to load at runtime, .custom() silently falls back to the
// system font, so the layout still works on devices that didn't ship the font.

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
    static let edDisplay     = calistoga(28, relativeTo: .largeTitle)
    static let edTitle       = calistoga(22, relativeTo: .title2)
    static let edHeading     = inter(17, weight: .semibold, relativeTo: .headline)
    static let edBody        = inter(16, relativeTo: .body)
    static let edBodyMedium  = inter(16, weight: .medium, relativeTo: .body)
    static let edSubheadline = inter(15, relativeTo: .subheadline)
    static let edFootnote    = inter(13, weight: .medium, relativeTo: .footnote)
    static let edCaption     = inter(12, relativeTo: .caption)
    static let edEyebrow     = inter(11, weight: .semibold, relativeTo: .caption2) // pair with .textCase(.uppercase) and .tracking(1.4)
    static let edMono        = jbMono(13, relativeTo: .footnote)
}

// MARK: - Eyebrow modifier

struct Eyebrow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.edEyebrow)
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(Tokens.muted)
    }
}

extension View {
    /// Renders a label as an Editorial Calm eyebrow:
    /// uppercase, tracked, semibold 11pt, muted.
    func eyebrow() -> some View { modifier(Eyebrow()) }
}
