import SwiftUI

/// The app's own segmented strip (#559).
///
/// ### Why this exists rather than `.pickerStyle(.segmented)`
///
/// The native control is a different design language wearing our spacing. It
/// draws its own greys, its own hairline dividers and its own system font, none
/// of which come from `Tokens` or the `ed*` ramp, so a screen that uses it has
/// one element that does not repaint with the rest of the app when a token
/// moves. It also sizes its segments by dividing the width evenly and then
/// TRUNCATING, so a five-segment strip at 390 pt turns into five abbreviations.
///
/// This strip is the same two surfaces the app already uses everywhere else: a
/// `surface2` track with a `surface` pill riding inside it, both bordered. A
/// reader who knows what a selected row looks like in Finance already knows what
/// a selected tab looks like here.
///
/// ### Why the selection is weight and surface, not hue
///
/// The first section to adopt it is Meals, where hue means a verdict about a day
/// and nothing else (see `MealStatPill`). A strip that filled the selected tab
/// with the section accent would put the only other coloured object on the
/// screen directly above a card whose colours are readings. So selection is
/// carried by the raised surface, the stronger border and the heavier label,
/// which are three signals that all survive greyscale.
///
/// `tint` exists for the sections that have colour to spend. It defaults to
/// `Tokens.ink`, which is also `accentChat` and `accentDashboard`, so the
/// default is a real value in the palette and not an opt-out.
///
/// ### Fit at phone width
///
/// Five labels at `.edFootnote` (13 pt on iOS) inside 358 pt of content width
/// give roughly 71 pt a tab, and the longest word this section needs is
/// "History" at about 48 pt. `minimumScaleFactor` is the guard for an
/// accessibility text size rather than the normal case; `lineLimit(1)` keeps a
/// long label from making the strip two rows tall.
struct EdTabStrip<Tab: Hashable & Identifiable>: View {

    let tabs: [Tab]
    @Binding var selection: Tab
    /// The visible word for a tab. Passed in rather than required on the type,
    /// so a section can adopt the strip without adding a protocol to its enum.
    let label: (Tab) -> String
    /// Colour of the selected label. Defaults to ink: see the note above.
    var tint: Color = Tokens.ink
    /// What the strip as a whole is choosing between, spoken before the tabs.
    var accessibilityName: String = "View"

    /// Drives the pill's slide. Held here so the pill is ONE view moving rather
    /// than one appearing while another disappears, which is what makes the
    /// motion read as a selection instead of a redraw.
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isSelected = tab == selection
                Button {
                    guard tab != selection else { return }
                    withAnimation(.easeOut(duration: 0.18)) { selection = tab }
                } label: {
                    Text(label(tab))
                        .font(isSelected ? .edFootnoteStrong : .edFootnote)
                        .foregroundStyle(isSelected ? tint : Tokens.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.sm)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                    .fill(Tokens.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                                            .stroke(Tokens.borderStrong, lineWidth: 0.5)
                                    )
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(tab))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }
}
