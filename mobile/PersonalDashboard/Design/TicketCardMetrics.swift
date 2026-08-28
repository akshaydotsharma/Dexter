import CoreGraphics

/// The fixed heights that make every Wallet card the same size (#481).
///
/// A card used to be as tall as its document was chatty: the Monza F1 pass
/// printed nine issuer codes below its seat facts and stood three times the
/// height of a plain cinema ticket. In a deck of overlapping cards that reads as
/// a broken layout, and it puts the barcode — the reason the Wallet exists — at a
/// different place on every card.
///
/// So the face is built out of fixed blocks rather than out of its content. Each
/// block is sized for the worst case it must hold, content that overflows goes to
/// the back, and the sum is the same for a boarding pass, a hotel stay and a
/// race ticket alike.
///
/// The back is sized to `openBody` for the same reason: turning a card over must
/// not resize it, or the cards below it jump while you are reading.
enum TicketCardMetrics {
    /// The illustrated panel: one big value and its label per endpoint.
    static let hero: CGFloat = 116

    /// The written half: one full-width line, then a row of up to three fields.
    /// Tall enough for a two-line venue above a two-line section name, which is
    /// the longest real pair seen (`Autodromo Nazionale Monza - Monza` over
    /// `26b - Tribuna Laterale Destra`).
    ///
    /// Per platform, because the type ramp is: 16pt body on iOS against 13pt on
    /// the Mac. One shared number would either clip the phone or leave a band of
    /// empty ticket on the desktop.
    ///
    /// Includes a generous gap under the hero. Butted straight up against the
    /// artwork the facts read as a caption on it; set apart, the card has an
    /// illustrated half and a written half, which is what a printed ticket looks
    /// like. #481 traded that gap for height and the card lost the distinction.
    #if os(macOS)
    static let face: CGFloat = 144
    #else
    static let face: CGFloat = 174
    #endif

    /// The dashed tear line. Matches `PerforatedDivider`'s own frame.
    static let tear: CGFloat = 14

    /// The tear-off stub. Sized for the tallest code (a 132pt QR) plus its quiet
    /// zone and the reference line beneath it; a short PDF417 strip centres in
    /// the same box rather than shrinking the card.
    static let stub: CGFloat = 212

    /// The whole body of an open card, face or back.
    static let openBody: CGFloat = hero + face + tear + stub
}
