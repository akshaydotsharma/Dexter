import SwiftUI

/// Which meal this is, as a control rather than a caption (#643).
///
/// ### Why it is a view of its own
///
/// The meal type is decided at the moment a meal is WRITTEN, and there are two
/// places a meal is written: the estimate preview, and the Log button under a
/// tray of picked items. Before #643 there was one dropdown, in the composer's
/// control row, and it sat above both of them — which made it look like an
/// input to the estimate when for the typed path it was only a hint the model
/// was free to ignore.
///
/// Moving it to the two write points meant two dropdowns, and two dropdowns
/// written twice is how the popover, the hover rule, the row metrics and the
/// glyph column drift apart. So it is one view used twice.
///
/// ### Why it is not a `Menu`
///
/// The same reason #540 gave: a system menu panel is the one control the design
/// system cannot reach — system font, system row metrics, system checkmarks,
/// and a different panel again on macOS. The rows here are the same
/// `InlineDropdownRow`s Finance uses, so the open state is still drawn out of
/// the design system.
///
/// ### Why it floats rather than grows
///
/// Growing the list in place pushed everything below it down the screen for a
/// choice most meals never make. A popover leaves the surface where it was.
struct MealTypeDropdown: View {

    /// The chosen type, or nil for "let Dexter decide".
    ///
    /// Nil is only reachable when `allowsAuto` is true. At the log step the
    /// value is already concrete — the model answered, or the clock did — so
    /// there is nothing left to defer and the option is not offered.
    @Binding var selection: MealType?

    /// Whether "Let Dexter decide" is one of the rows.
    ///
    /// True before anything has been decided: a tray of picked items carries no
    /// opinion about whether it is lunch, so the clock's guess is the sensible
    /// default and the user overrides it only when the clock is wrong.
    ///
    /// False in the estimate preview, where the model has already answered.
    /// Offering Auto there would mean offering to throw away an answer and
    /// replace it with a worse one.
    var allowsAuto: Bool = true

    /// The accent the selected state is drawn in.
    var accent: Color = Tokens.accentMeals

    /// Whether the trigger takes only the width its own label needs.
    ///
    /// False in a control row, where it is one of two controls sharing a line
    /// and a fixed share keeps the pair from shifting as the label changes
    /// length. True in the estimate preview's header, where it sits beside two
    /// chips on a phone: greedy there, it would claim 190pt of a 306pt row and
    /// push the confidence band off the end, or compress and truncate its own
    /// label to do it.
    var hugsContent: Bool = false

    @State private var isOpen = false
    #if os(macOS)
    @State private var isHovering = false
    #endif

    /// The width of the trigger and of the panel under it, so the two read as
    /// one control rather than as a button and a list that happen to be near
    /// each other.
    private let panelWidth: CGFloat = 240

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: selection?.sfSymbol ?? "wand.and.stars")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(selection == nil ? Tokens.muted : accent)
                    .frame(width: 24, alignment: .leading)
                Text(selection?.displayName ?? "Auto")
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Spacer(minLength: Space.sm)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokens.muted)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .frame(maxWidth: hugsContent ? nil : .infinity, alignment: .leading)
            // The metrics `EdButtonStyle` applies at `size: .md`, which is what
            // the Log button beside this one uses: 14 horizontal, 8 vertical
            // (Design/Buttons.swift, `hpad` / `vpad`). `InlineDropdown` pads
            // `Space.md` (12) all round, which made this trigger read half again
            // as tall as the button it sits next to.
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(background, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(border, radius: Radius.md)
        #if os(macOS)
        // Stripping the system chrome takes the button's own highlight with it,
        // and without a hover response a bordered surface reads as a static
        // caption rather than something you can open. The same rule
        // `InlineDropdown` follows, so this picker and the Finance one behave
        // alike under the pointer.
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        #endif
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            options
        }
        .accessibilityLabel("Meal type, \(selection?.displayName ?? "decided automatically")")
    }

    private var background: Color {
        #if os(macOS)
        return isHovering && !isOpen ? Tokens.surface2 : Tokens.surface
        #else
        return Tokens.surface
        #endif
    }

    private var border: Color {
        #if os(macOS)
        return isHovering || isOpen ? Tokens.borderStrong : Tokens.border
        #else
        return isOpen ? Tokens.borderStrong : Tokens.border
        #endif
    }

    private var options: some View {
        VStack(spacing: 0) {
            if allowsAuto {
                InlineDropdownRow(
                    glyph: .symbol("wand.and.stars"),
                    label: "Let Dexter decide",
                    isSelected: selection == nil,
                    accent: accent
                ) { select(nil) }

                InlineDropdownDivider()
            }

            ForEach(MealType.allCases) { type in
                InlineDropdownRow(
                    glyph: .symbol(type.sfSymbol),
                    label: type.displayName,
                    isSelected: selection == type,
                    accent: accent
                ) { select(type) }
            }
        }
        .padding(.vertical, Space.xs)
        .frame(width: panelWidth)
        .background(Tokens.surface)
        // The panel's chrome belongs to the system; this puts it back on the
        // design system's surface colour in both themes.
        .presentationBackground(Tokens.surface)
        // Without this an iPhone adapts a popover into a full-screen sheet,
        // which is a far bigger interruption than the inline list this
        // replaces. Available from iOS 16.4 / macOS 13.3, both below the 17.0 /
        // 14.0 deployment targets in project.yml, so no availability guard.
        .presentationCompactAdaptation(.popover)
    }

    private func select(_ type: MealType?) {
        selection = type
        isOpen = false
    }
}
