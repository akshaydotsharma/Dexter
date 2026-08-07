import SwiftUI

/// The block-state appearance table (#446), in one place so it can be read as a
/// table rather than reassembled from five call sites.
///
/// State is carried by the block's EDGE — a 3pt top rail, the border style, and
/// a 10pt header glyph — and never by a tile interior. Priority is carried by a
/// tile interior and never by the edge. That separation is the rule the whole
/// board rests on: a Waiting block full of P1 tasks would otherwise be amber on
/// amber and the two signals would be indistinguishable at board zoom.
///
/// Within the edge, four sub-signals distinguish state and only ONE of them is
/// hue: rail pattern, glyph shape, body fill, and colour. Desaturate the board
/// and every state is still identifiable. That is the acceptance criterion, not
/// a nicety.
struct VisionBlockStyle {
    let state: BlockState

    /// How the 3pt top rail is drawn.
    enum Rail: Equatable {
        case solid
        /// Dash pattern in points.
        case dashed([CGFloat])
        /// No rail. The slot is still 3pt tall and holds a hairline, so
        /// switching a block to Idea or Done reflows nothing.
        case absent
    }

    var hue: Color { Tokens.state(for: state) }

    var rail: Rail {
        switch state {
        case .idea:    return .absent
        case .active:  return .solid
        case .ongoing: return .solid
        case .waiting: return .dashed([6, 4])
        case .done:    return .absent
        }
    }

    /// Border colour at rest. Active gets an ink border rather than the neutral
    /// one: it is the loudest state and it earns a heavier perimeter, which also
    /// means the loudest signal on the board is encoded by weight rather than by
    /// a colour anyone has to be able to see.
    var borderColor: Color {
        switch state {
        case .idea:    return Tokens.borderStrong
        case .active:  return Tokens.ink.opacity(0.22)
        default:       return Tokens.border
        }
    }

    /// Idea's border is dashed. Together with the absent rail and the
    /// `lightbulb`, that is what separates it from Done — which shares its
    /// `Tokens.muted` hue exactly, deliberately, so neither depends on colour.
    var borderDash: [CGFloat]? {
        state == .idea ? [4, 3] : nil
    }

    /// Done settles toward the canvas without becoming it.
    ///
    /// Recession is by TREATMENT, never by whole-block opacity. Opacity would
    /// dim the text with the card and drop `Tokens.muted` below the 4.5:1 floor
    /// — the identical trap `TripCoverMetrics.pastVeilOpacity` documents for a
    /// past trip. Same trap, same answer.
    var bodyFill: Color {
        state == .done ? Tokens.paper2 : Tokens.surface
    }

    /// Title and meta colour.
    ///
    /// Done uses `inkSoft`, NOT `muted`. `Tokens.muted` on `paper2` in light mode
    /// measures 4.17:1, under the floor; `inkSoft` is 8.57:1. The Done GLYPH may
    /// stay `muted` because a glyph is a non-text graphic with a 3:1 floor.
    var titleColor: Color {
        state == .done ? Tokens.inkSoft : Tokens.ink
    }

    /// Progress bar fill. Monochrome always — progress is not state, and letting
    /// it borrow state's colour would make the block carry the same signal three
    /// times until the eye started reading progress as urgency.
    var progressFill: Color {
        state == .done ? Tokens.muted : Tokens.inkSoft
    }

    /// A finished block has no urgency, and showing `overdue by 3` on it would
    /// be a lie.
    var suppressesUrgency: Bool { state == .done }
}

// MARK: - Rail

/// A 3pt bar along a block's top edge, clipped by the card shape so it takes the
/// top corner radius and reads as part of the block rather than a bar sitting
/// on it.
struct VisionStateRail: View {
    let style: VisionBlockStyle

    var body: some View {
        Group {
            switch style.rail {
            case .solid:
                Rectangle().fill(style.hue)
            case .dashed(let pattern):
                DashedBar(dash: pattern).fill(style.hue)
            case .absent:
                // The slot keeps its height and holds a hairline, so a state
                // change never moves the header down or up by 3pt.
                Color.clear.overlay(alignment: .top) {
                    Rectangle().fill(Tokens.border).frame(height: 0.5)
                }
            }
        }
        .frame(height: VisionGrid.railHeight)
        .accessibilityHidden(true)
    }
}

/// A dashed horizontal bar as a fillable `Shape`.
///
/// `strokedPath` rather than a stroked `Path` in a `Canvas`: a Canvas would have
/// to resolve `Tokens`' dynamic light/dark colours through `GraphicsContext`,
/// and a plain filled shape lets SwiftUI resolve them the way every other token
/// in the app is resolved.
private struct DashedBar: Shape {
    let dash: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path.strokedPath(StrokeStyle(lineWidth: rect.height, dash: dash))
    }
}
