import SwiftUI

enum ButtonKind {
    case primary
    case secondary
    case ghost
}

enum ButtonSize {
    case sm, md
}

/// Editorial Calm button styles. Apply via `.buttonStyle(EdButtonStyle(kind: .primary))`.
struct EdButtonStyle: ButtonStyle {
    var kind: ButtonKind = .primary
    var size: ButtonSize = .md
    var fullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let (fg, bg, stroke): (Color, Color, Color?) = {
            switch kind {
            case .primary:   return (Tokens.paper, Tokens.ink, nil)
            case .secondary: return (Tokens.ink, Tokens.surface, Tokens.border)
            case .ghost:     return (Tokens.muted, .clear, nil)
            }
        }()

        let hpad: CGFloat = (size == .sm) ? 12 : 14
        let vpad: CGFloat = (size == .sm) ? 6  : 8
        let font: Font   = (size == .sm) ? .edFootnote : .edBody

        return configuration.label
            .font(font)
            .foregroundStyle(fg)
            .padding(.horizontal, hpad)
            .padding(.vertical, vpad)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(bg, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(stroke ?? .clear, lineWidth: stroke == nil ? 0 : 0.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Pill chip button (example prompt chips, filter chips)

struct EdChipStyle: ButtonStyle {
    var emphasized: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.edFootnote)
            .foregroundStyle(Tokens.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                (configuration.isPressed ? Tokens.paper2 : Tokens.surface),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(configuration.isPressed ? Tokens.borderStrong : Tokens.border, lineWidth: 0.5)
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Round icon-only button (40×40)

struct EdIconButtonStyle: ButtonStyle {
    var tint: Color = Tokens.muted
    var size: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                configuration.isPressed ? Tokens.paper2 : Color.clear,
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Icon-circle button (48pt floating FAB, for Notes / Lists overlay actions)

struct EdIconCircleButtonStyle: ButtonStyle {
    var kind: ButtonKind = .primary

    func makeBody(configuration: Configuration) -> some View {
        let (fg, bg, stroke): (Color, Color, Color?) = {
            switch kind {
            case .primary:   return (Tokens.paper, Tokens.ink, nil)
            case .secondary: return (Tokens.ink, Tokens.surface, Tokens.border)
            case .ghost:     return (Tokens.muted, .clear, nil)
            }
        }()

        return configuration.label
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(fg)
            .frame(width: 48, height: 48)
            .background(bg, in: Circle())
            .overlay(Circle().stroke(stroke ?? .clear, lineWidth: stroke == nil ? 0 : 0.5))
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Send button (filled accent square)

struct EdSendButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = enabled ? Tokens.ink : Tokens.paper2
        let fg: Color = enabled ? Tokens.paper : Tokens.mutedSoft
        return configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(fg)
            .frame(width: 40, height: 40)
            .background(bg, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
