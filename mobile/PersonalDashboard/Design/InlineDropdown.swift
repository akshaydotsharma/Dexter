import SwiftUI

/// A dropdown whose options open INSIDE the form rather than over it (#540).
///
/// `Menu` is the shortest way to offer a few choices, but its panel belongs to
/// the system: system font, system row metrics, system checkmarks, and a
/// different panel again on macOS. In a sheet where every other surface is a
/// `Tokens.surface` box with a hairline border, that panel is the one control
/// the design system cannot reach.
///
/// This keeps the closed appearance the other fields already have and grows
/// the options beneath the trigger as more rows of the same box. Nothing
/// overlays, so there is no popover lifetime to manage, no anchor to lose, and
/// no platform fork: iOS and macOS render the same control.
///
/// Suited to a handful of options that belong to the form. A long or
/// searchable list still wants a surface of its own.
struct InlineDropdown<Trigger: View, Options: View>: View {
    @Binding var isExpanded: Bool

    /// The resting content: whatever identifies the current selection. The
    /// chevron and the padding are drawn here, so the caller supplies only the
    /// leading half of the row.
    @ViewBuilder var trigger: () -> Trigger

    /// The option rows, usually `InlineDropdownRow`s.
    @ViewBuilder var options: () -> Options

    #if os(macOS)
    @State private var hovering = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Space.sm) {
                    trigger()
                    Spacer(minLength: Space.sm)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.muted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().background(Tokens.divider)
                VStack(spacing: 0) { options() }
            }
        }
        .background(background, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(borderColor, radius: Radius.md)
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        #if os(macOS)
        // Stripping the system chrome takes the button's own highlight with
        // it, and without a hover response a full-width surface reads as a
        // static caption rather than something you can open. Same rule
        // `DropdownFieldSurface` follows, so the two match when side by side.
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        #endif
    }

    private var background: Color {
        #if os(macOS)
        return hovering && !isExpanded ? Tokens.surface2 : Tokens.surface
        #else
        return Tokens.surface
        #endif
    }

    private var borderColor: Color {
        #if os(macOS)
        return hovering || isExpanded ? Tokens.borderStrong : Tokens.border
        #else
        return isExpanded ? Tokens.borderStrong : Tokens.border
        #endif
    }
}

/// What an `InlineDropdownRow` draws in its leading slot. The slot is a fixed
/// width whether or not it holds anything, so labels line up down the list and
/// with the trigger above it.
enum InlineDropdownGlyph {
    case dot(Color)
    case symbol(String)
    case none
}

/// One option in an `InlineDropdown`: a leading glyph, a label, and a
/// checkmark when it is the current choice.
struct InlineDropdownRow: View {
    let glyph: InlineDropdownGlyph
    let label: String
    var isSelected: Bool = false
    /// Renders in the accent rather than the ink. For a row that performs an
    /// action instead of choosing a value, like "Multiple people…".
    var isAction: Bool = false
    let action: () -> Void

    #if os(macOS)
    @State private var hovering = false
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                glyphView
                    .frame(width: 24, alignment: .leading)
                Text(label)
                    .font(.edBody)
                    .foregroundStyle(isAction ? Tokens.accentFinance : Tokens.ink)
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.accentFinance)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm + 2)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
    }

    @ViewBuilder
    private var glyphView: some View {
        switch glyph {
        case .dot(let color):
            Circle().fill(color).frame(width: 10, height: 10)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isAction ? Tokens.accentFinance : Tokens.muted)
        case .none:
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private var rowBackground: Color {
        #if os(macOS)
        return hovering ? Tokens.surface2 : Color.clear
        #else
        return Color.clear
        #endif
    }
}

/// The hairline between groups of options, e.g. above an action row.
struct InlineDropdownDivider: View {
    var body: some View {
        Divider().background(Tokens.divider)
    }
}
