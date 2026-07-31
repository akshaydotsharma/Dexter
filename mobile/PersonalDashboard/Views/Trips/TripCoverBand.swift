import SwiftUI

/// Which of the three travel states a trip is in (#428).
///
/// A named type rather than two Bools passed down from `TripsView`: the band, the
/// type ramp and the card border all vary by state, and three call sites reading
/// `isPast: true, isActive: false` is how one of them eventually gets it wrong.
enum TripPhase {
    case active
    case upcoming
    case past
}

// MARK: - Cover band

/// The full-bleed destination photo band across the top of a trip tile (#428).
///
/// Nothing is ever drawn on the artwork. The alternative — full-cover art with a
/// scrim and the text on top — was measured and rejected: white text needs a
/// backdrop luminance at or below 0.183 to clear 4.5:1, a bright sky sits near
/// 0.85, so the scrim would need roughly 0.85 opacity to be safe and would destroy
/// the image it sat on. Keeping text off the image means this tile introduces no new
/// contrast pair at all.
///
/// The cover is a generated illustration, cropped at cache time so the skyline's base
/// sits on the seam divider with empty sky above it. See `TripCoverCrop`.
///
/// Reads a local file, synchronously, through `TripCoverImageCache`. Makes NO
/// network call on any render path — generation happens on write and in the launch
/// repair sweep — which is what makes "there is no loading state" a fact rather than
/// an aspiration. It matters more here than it did for photography: a spinner tied to
/// a 30-second generation would be a 30-second spinner.
///
/// No `Material` and no `.blur` is introduced anywhere in this view, so
/// `accessibilityReduceTransparency` does not apply to it. Stated so a future
/// audit does not have to re-derive it.
struct TripCoverBand: View {
    let trip: LocalTrip
    let phase: TripPhase

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // `Color.clear` is the sizing driver and the artwork rides in an overlay,
        // deliberately. Putting the photo itself in the aspect-ratio chain lets it
        // keep its own width-derived size when the `minHeight` clamp lifts the
        // frame — which happens on a 320pt device, where the card is 288pt wide
        // and 288/2.4 is exactly the 120pt floor, and a Past band is 288/4 = 72pt
        // against an 84pt floor. That would leave 12pt of paper above and below a
        // supposedly full-bleed photograph. An overlay is proposed the frame's
        // resolved size, so the artwork fills whatever height the clamps produce.
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            // MEASURED, not decorative. `.aspectRatio(_, contentMode: .fit)` under
            // a `maxHeight` clamp does not clamp the height and keep the width — it
            // preserves the ratio by shrinking the WIDTH. Above the width where the
            // ceiling bites (528pt for 2.4 × 220, and again for 4.0 × 132) the band
            // stops at 528pt and sits centred in the card: 39% of an 868pt macOS
            // pane and 61% of a 1368pt one left as bare paper. Verified by
            // rendering the chain at 288 / 361 / 398 / 388 / 868 / 1368pt and
            // counting uncovered pixels.
            //
            // Reclaiming the width here fixes it at every tested width in both
            // bands with the heights unchanged. `maxWidth`, never `maxHeight`: an
            // unbounded height on this band inside a `List` is the hazard the whole
            // no-`GeometryReader` rule exists to avoid.
            .frame(maxWidth: .infinity)
            .overlay { artwork }
            .clipped()
            // Past only: an adaptive veil over the whole band. `Tokens.paper`
            // because it IS a light/dark pair, so it lifts the image in light mode
            // and darkens it in dark mode, which is correct in both.
            .overlay {
                if phase == .past {
                    Tokens.paper.opacity(TripCoverMetrics.pastVeilOpacity)
                }
            }
            // Bottom-edge veil, so a blown-out sky does not dissolve into the
            // card's paper and lose the band's bottom edge.
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, Tokens.coverSeamVeil],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: TripCoverMetrics.veilHeight)
                .allowsHitTesting(false)
            }
            // Seam rule. `Tokens.border`, not `Tokens.divider`, which vanishes on
            // lighter surfaces in light mode.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Tokens.border)
                    .frame(height: TripCoverMetrics.seamHeight)
            }
            // The band is decorative-redundant: the destination is named in text
            // immediately below it.
            .accessibilityHidden(true)
            // A repair sweep or a write-time generation can land while the list is on
            // screen, so the glyph art swaps to the illustration in place. Opacity
            // only, 200ms, skipped under reduce-motion (precedent: `InkOrb`). This
            // fade is the ONLY thing the user sees of a 30-second generation, which is
            // why it earns its keep here more than it did under photography.
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.2),
                value: trip.coverImagePath
            )
    }

    // MARK: - Artwork

    @ViewBuilder
    private var artwork: some View {
        if let image = TripCoverImageCache.image(forRelativePath: trip.coverImagePath) {
            Image(platformImage: image)
                .resizable()
                // `.fill` with the default CENTRE focal point. The cached file is
                // ALREADY cropped to the band's 4:1 at cache time, so in practice
                // there is nothing left to crop here and this only absorbs the few
                // points of rounding between the file's ratio and the resolved band.
                // Doing the real cropping here instead would put it on the render
                // path, where a bad result would be intermittent rather than
                // inspectable.
                .aspectRatio(contentMode: .fill)
                .saturation(saturation)
                .clipped()
                .transition(.opacity)
        } else {
            // Not a placeholder. Same band height, same seam rule, same text block
            // below it, so the list's rhythm is identical either way. This is what a
            // trip whose name is not a place keeps permanently, and what every trip
            // shows for the tens of seconds before its illustration lands.
            TripCoverGeneratedArt(
                hue: TripCoverArt.hue(for: trip.clientUUID),
                glyph: TripCoverArt.glyph(for: trip.name),
                watermark: TripCoverMetrics.watermark
            )
            .saturation(saturation)
            .transition(.opacity)
        }
    }

    // MARK: - Geometry

    /// One geometry for every phase. Past recedes by treatment, not by size.
    private var ratio: CGFloat { TripCoverMetrics.ratio }

    private var minHeight: CGFloat { TripCoverMetrics.minHeight }

    /// The accessibility clamp is a `min`, not a replacement, so it can only ever
    /// shorten the band and never accidentally grow it.
    private var maxHeight: CGFloat {
        guard dynamicTypeSize >= .accessibility1 else { return TripCoverMetrics.maxHeight }
        return min(TripCoverMetrics.maxHeight, TripCoverMetrics.accessibilityMaxHeight)
    }

    private var saturation: Double {
        phase == .past ? TripCoverMetrics.pastSaturation : 1.0
    }

}

// MARK: - Generated cover art

/// Cover art for a trip with no photograph: a wash in the trip's own hue with an
/// oversized glyph bleeding off the trailing edge (#428).
///
/// This is the construction `TicketCardView.heroPanel` already ships, reused
/// deliberately rather than invented. A photo-less trip should read as the same
/// kind of object as a wallet card, not as a hole where a photo failed. The one
/// difference is that nothing sits on top of this art, so the wash and the glyph
/// carry a little more weight than the hero panel's do.
struct TripCoverGeneratedArt: View {
    let hue: Color
    let glyph: String
    let watermark: CGFloat

    var body: some View {
        ZStack(alignment: .trailing) {
            Tokens.surface2
            LinearGradient(
                colors: [hue.opacity(0.20), hue.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: glyph)
                // Fixed point size, not a scaling `Font`: this is artwork, and a
                // watermark that grew with the user's text size would swallow the
                // band exactly when the band is at its shortest.
                .font(.system(size: watermark, weight: .light))
                .foregroundStyle(hue.opacity(0.10))
                .rotationEffect(.degrees(-12))
                .offset(x: 44, y: 12)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Hue + glyph

/// Deterministic visual identity for a trip's generated cover (#428).
enum TripCoverArt {

    /// The trip's hue, drawn from `ListAppearance.palette` so the feature adds no
    /// new colour: all eight entries are existing section accents, each already a
    /// light/dark pair.
    ///
    /// Indexed by a byte hash of `clientUUID`, and NOT by `String.hashValue`.
    /// Swift's string hashing is randomly seeded per process, so a trip's colour
    /// would change on every launch — a bug that would look like a rendering
    /// glitch and be near-impossible to attribute.
    static func hue(for uuid: UUID) -> Color {
        ListAppearance.palette[paletteIndex(for: uuid)].color
    }

    /// The palette index, exposed separately because it is the part that has to be
    /// deterministic and the part a test can actually assert on: `Color.paper(_:_:)`
    /// mints a fresh platform colour with a fresh provider closure on every call,
    /// so two `Color`s for the same palette entry are never `==`. Comparing hues
    /// directly would give a test that fails while the code is correct.
    static func paletteIndex(for uuid: UUID) -> Int {
        var accumulator: UInt64 = 0
        withUnsafeBytes(of: uuid.uuid) { bytes in
            for byte in bytes {
                accumulator = accumulator &* 131 &+ UInt64(byte)
            }
        }
        return Int(accumulator % UInt64(ListAppearance.palette.count))
    }

    private struct GlyphRule {
        let keywords: [String]
        let symbol: String
    }

    /// Trip-shaped keywords, checked top to bottom.
    ///
    /// Deliberately NOT an extension of `ListAppearance.infer(from:)`: that
    /// mapper's default is `checklist`, which would be absurd on a trip cover,
    /// and its rules are tuned for list titles ("packing", "budget") rather than
    /// destinations. Two small tables that each read correctly beat one that has
    /// to serve both.
    private static let rules: [GlyphRule] = [
        .init(keywords: ["beach", "island", "coast"], symbol: "beach.umbrella"),
        .init(keywords: ["ski", "snow", "alps"], symbol: "snowflake"),
        .init(keywords: ["offsite", "work", "conference"], symbol: "briefcase"),
        .init(keywords: ["road trip"], symbol: "car"),
        .init(keywords: ["wedding", "birthday"], symbol: "gift"),
        .init(keywords: ["hike", "trek", "safari"], symbol: "mountain.2"),
        .init(keywords: ["train", "rail"], symbol: "tram"),
        .init(keywords: ["home", "family"], symbol: "house")
    ]

    /// `airplane` is the default, matching the Trips section's own icon.
    static let defaultGlyph = "airplane"

    /// A guaranteed-renderable SF Symbol for this trip name.
    ///
    /// Every result goes through `ListAppearance.isValidSymbol(_:)`, including the
    /// default: `mountain.2` and `snowflake` are both on the iOS 17 / macOS 14
    /// baseline, but a runtime check costs nothing and a blank band would be a
    /// far worse outcome than a plane.
    static func glyph(for tripName: String) -> String {
        let lowered = tripName.lowercased()
        for rule in rules where rule.keywords.contains(where: { lowered.contains($0) }) {
            if ListAppearance.isValidSymbol(rule.symbol) { return rule.symbol }
        }
        return ListAppearance.isValidSymbol(defaultGlyph) ? defaultGlyph : "airplane"
    }
}
