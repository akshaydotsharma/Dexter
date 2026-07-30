import SwiftUI

/// The silhouette of a paper ticket (#398): a rounded rectangle with a
/// semicircular notch punched out of each side at the tear line.
///
/// The notches are cut from the OUTLINE rather than painted on top, so whatever
/// is behind the card shows through them. That is the difference between a card
/// that has two grey circles drawn on it and a card that reads as a physical
/// ticket: the hole has to actually be a hole, or it stops working the moment
/// the background is not the exact colour the circle was filled with.
///
/// `notchY` is measured from the card's top edge, because the tear line's
/// position depends on the card's content (it sits above the barcode stub when
/// there is one, and under the header band when there is not). The enclosing
/// card measures it and passes it in — see `ticketNotchAnchor()`.
struct TicketShape: Shape {
    var cornerRadius: CGFloat = Radius.xl
    var notchRadius: CGFloat = 9
    /// Distance from the top edge to the centre of the notches. `nil`, or a
    /// value too close to either end, draws a plain rounded rectangle — a
    /// collapsed card in the deck is a band with no tear line to punch.
    var notchY: CGFloat?

    /// Name of the coordinate space a card establishes so its tear line can
    /// report where it sits inside the card.
    static let coordinateSpace = "walletTicket"

    func path(in rect: CGRect) -> Path {
        let base = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)
        guard let notchY,
              notchY > cornerRadius,
              notchY < rect.height - cornerRadius else { return base }

        let y = rect.minY + notchY
        var cuts = Path()
        // Each circle is centred ON the edge, so exactly half of it is removed.
        cuts.addEllipse(in: CGRect(
            x: rect.minX - notchRadius,
            y: y - notchRadius,
            width: notchRadius * 2,
            height: notchRadius * 2
        ))
        cuts.addEllipse(in: CGRect(
            x: rect.maxX - notchRadius,
            y: y - notchRadius,
            width: notchRadius * 2,
            height: notchRadius * 2
        ))
        return base.subtracting(cuts)
    }
}

// MARK: - Tear-line measurement

/// Carries the tear line's vertical position up from wherever it is drawn to the
/// card that has to punch its notches there.
struct TicketNotchKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Publish this view's vertical midpoint as the enclosing ticket's tear line.
    ///
    /// The card reads it with `.onPreferenceChange(TicketNotchKey.self)` and
    /// feeds it back into its `TicketShape`. One layout pass of lag, which is
    /// invisible: the card is already animating open when it resolves.
    func ticketNotchAnchor() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TicketNotchKey.self,
                    value: proxy.frame(in: .named(TicketShape.coordinateSpace)).midY
                )
            }
        )
    }
}
