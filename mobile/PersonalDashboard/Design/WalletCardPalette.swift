import SwiftUI

/// The colour set one ticket card is drawn in (#398).
///
/// Every colour `TicketCardView` used to hardcode as an itinerary violet now
/// arrives through here, so the same card renders in a different colour per kind
/// without the view knowing anything about kinds. `.itinerary` reproduces the
/// previous values exactly, and it is the default, so the trip timeline is
/// unchanged by this existing.
///
/// Colours are `Color.paper(light, dark)` pairs rather than single hexes: a
/// card sits on paper in light mode and on near-black in dark, and a tint that
/// reads as "a coloured ticket" in one reads as "a muddy rectangle" in the
/// other. Each kind therefore carries its own dark-mode value, tuned so the
/// band stays saturated enough to identify the card at a glance while the body
/// stays quiet enough for ink to keep contrast.
struct WalletCardPalette {
    /// Eyebrow text, hero glyphs, MAP chip. The card's identity colour.
    let accent: Color
    /// Solid header band behind the collapsed strip and the expanded card's
    /// title. This is the colour you actually recognise the card by in a stack.
    let band: Color
    /// The far end of the header's diagonal gradient. A flat rectangle of colour
    /// reads as a UI element; a header with a gradient across it reads as printed
    /// stock, which is the difference the deck lives or dies on.
    let bandDeep: Color
    /// Ink on top of `band`. Near-white in both themes: the band is saturated in
    /// both, so it does not flip.
    let bandInk: Color
    /// Top of the body wash, under the band.
    let tintTop: Color
    /// Bottom of the body wash. Settles toward the neutral surface so text keeps
    /// its contrast.
    let tintBottom: Color
    let border: Color
    /// Thin vertical rule between facts cells.
    let factRule: Color
    /// The tear-off stub's paper, and the ink on it.
    ///
    /// Tinted per kind rather than the flat white the trip timeline uses: a
    /// white slab at the bottom of a coloured card reads as a hole rather than
    /// part of the ticket. Still LIGHT in both themes, because it is paper and
    /// because the barcode plate that sits on it has to stay scannable.
    let stubPaper: Color
    let stubInk: Color
    let stubMuted: Color

    /// The original #222 violet. Default everywhere, so the trip timeline keeps
    /// the exact colours it had before cards became colour-coded.
    static let itinerary = WalletCardPalette(
        accent: Color.paper(0x6D28D9, 0xA78BFA),
        band: Color.paper(0x6D28D9, 0x5B21B6),
        bandDeep: Color.paper(0x4C1D95, 0x3B1A80),
        bandInk: Color.paper(0xFFFFFF, 0xF5F3FF),
        tintTop: Color.paper(0xF1EAFB, 0x272033),
        tintBottom: Color.paper(0xFCFAFF, 0x1A1620),
        border: Color.paper(0xE3D7F4, 0x3C3352),
        factRule: Color.paper(0xE1D8F0, 0x352E48),
        stubPaper: Color(hex: 0xF3EDFC),
        stubInk: Color(hex: 0x2A2135),
        stubMuted: Color(hex: 0x6B6280)
    )

    /// Flights. Deep aviation blue.
    static let boardingPass = WalletCardPalette(
        accent: Color.paper(0x1D4ED8, 0x93B4FF),
        band: Color.paper(0x1D4ED8, 0x1E3A8A),
        bandDeep: Color.paper(0x1E3A8A, 0x152C6B),
        bandInk: Color.paper(0xFFFFFF, 0xEFF6FF),
        tintTop: Color.paper(0xE8F0FE, 0x1B2233),
        tintBottom: Color.paper(0xFAFCFF, 0x151A24),
        border: Color.paper(0xD3E1F8, 0x2E3D57),
        factRule: Color.paper(0xD9E4F7, 0x2A3750),
        stubPaper: Color(hex: 0xE9F0FC),
        stubInk: Color(hex: 0x16233A),
        stubMuted: Color(hex: 0x566780)
    )

    /// Rail, coach, ferry. Teal, distinct from the flight blue at a glance.
    static let transit = WalletCardPalette(
        accent: Color.paper(0x0F766E, 0x5EEAD4),
        band: Color.paper(0x0F766E, 0x115E59),
        bandDeep: Color.paper(0x115E59, 0x0B4642),
        bandInk: Color.paper(0xFFFFFF, 0xECFDF5),
        tintTop: Color.paper(0xE6F5F3, 0x152826),
        tintBottom: Color.paper(0xF9FDFC, 0x121D1C),
        border: Color.paper(0xCFE8E4, 0x24443F),
        factRule: Color.paper(0xD6ECE8, 0x224039),
        stubPaper: Color(hex: 0xE4F2EF),
        stubInk: Color(hex: 0x11302C),
        stubMuted: Color(hex: 0x4E6C66)
    )

    /// Concerts, matches, theatre. Warm magenta, the loudest of the set because
    /// an event ticket is the one you hunt for in a hurry at a turnstile.
    static let event = WalletCardPalette(
        accent: Color.paper(0xBE185D, 0xF9A8D4),
        band: Color.paper(0xBE185D, 0x9D174D),
        bandDeep: Color.paper(0x9D174D, 0x74103A),
        bandInk: Color.paper(0xFFFFFF, 0xFDF2F8),
        tintTop: Color.paper(0xFCE9F1, 0x2B1721),
        tintBottom: Color.paper(0xFFFAFC, 0x1D1218),
        border: Color.paper(0xF5D4E3, 0x4A2437),
        factRule: Color.paper(0xF2D8E4, 0x452133),
        stubPaper: Color(hex: 0xFCE8F1),
        stubInk: Color(hex: 0x33101F),
        stubMuted: Color(hex: 0x795065)
    )

    /// Hotels and accommodation. Amber, so a stay never reads as travel.
    static let stay = WalletCardPalette(
        accent: Color.paper(0xB45309, 0xFBBF24),
        band: Color.paper(0xB45309, 0x92400E),
        bandDeep: Color.paper(0x92400E, 0x6E300A),
        bandInk: Color.paper(0xFFFFFF, 0xFFFBEB),
        tintTop: Color.paper(0xFBEFDD, 0x2A2015),
        tintBottom: Color.paper(0xFFFCF7, 0x1D1710),
        border: Color.paper(0xF0DFC5, 0x4A381F),
        factRule: Color.paper(0xEDDCC4, 0x453520),
        stubPaper: Color(hex: 0xFBEEDB),
        stubInk: Color(hex: 0x33230F),
        stubMuted: Color(hex: 0x776043)
    )

    /// The catch-all: memberships, parking, anything else scannable. Slate, so
    /// it reads as "a pass" rather than borrowing another kind's meaning.
    static let pass = WalletCardPalette(
        accent: Color.paper(0x475569, 0xCBD5E1),
        band: Color.paper(0x475569, 0x334155),
        bandDeep: Color.paper(0x334155, 0x232C3A),
        bandInk: Color.paper(0xFFFFFF, 0xF8FAFC),
        tintTop: Color.paper(0xEDF1F5, 0x1E232B),
        tintBottom: Color.paper(0xFBFCFD, 0x161A20),
        border: Color.paper(0xDCE3EA, 0x333C48),
        factRule: Color.paper(0xE0E6EC, 0x2F3742),
        stubPaper: Color(hex: 0xEDF1F5),
        stubInk: Color(hex: 0x1B222B),
        stubMuted: Color(hex: 0x59636F)
    )
}

extension WalletCardKind {
    /// The colours this kind's cards are drawn in.
    var palette: WalletCardPalette {
        switch self {
        case .boardingPass: return .boardingPass
        case .transit:      return .transit
        case .event:        return .event
        case .stay:         return .stay
        case .pass:         return .pass
        }
    }
}
