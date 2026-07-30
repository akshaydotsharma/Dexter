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

/// Carries the tear line's position up from wherever it is drawn to the card
/// that has to punch its notches there.
///
/// An ANCHOR rather than a resolved number, on purpose. The first version
/// measured `proxy.frame(in: .named(…))` against a coordinate space the card
/// declared — and when that name does not resolve, SwiftUI does not complain,
/// it quietly returns GLOBAL coordinates. A tear line 800pt down the screen
/// then failed the shape's "inside the card" guard and the notches silently
/// vanished, which is exactly what happened to every card in the deck while the
/// detail sheet (sitting near the top of the window, so global ≈ local) kept
/// working. An anchor is resolved by the reader's own `GeometryProxy`, so it is
/// always in the card's coordinates and cannot fall back to anything else.
struct TicketNotchKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Publish this view's bounds as the enclosing ticket's tear line.
    func ticketNotchAnchor() -> some View {
        anchorPreference(key: TicketNotchKey.self, value: .bounds) { $0 }
    }

    /// Read the tear line published by `ticketNotchAnchor()`, resolved in THIS
    /// view's coordinate space, and hand back its vertical centre.
    func readingTicketNotch(_ onChange: @escaping (CGFloat?) -> Void) -> some View {
        backgroundPreferenceValue(TicketNotchKey.self) { anchor in
            GeometryReader { proxy in
                let midY = anchor.map { proxy[$0].midY }
                Color.clear
                    .onAppear { onChange(midY) }
                    .onChange(of: midY) { _, new in onChange(new) }
            }
        }
    }
}
