import XCTest
import CoreGraphics
import ImageIO
@testable import PersonalDashboard

/// Trip cover illustration (#428).
///
/// The photography-era tests are gone with the code they pinned: the corpus order,
/// the ~20 filename reject rules, the stub-page threshold, the `imageinfo` metadata
/// shapes and the attribution rendering. They asserted behaviour that no longer
/// exists, and leaving them would have been worse than deleting them. Git history has
/// them if photography is ever revisited.
///
/// What is tested here is what can fail silently:
///
/// - The **crop**, which is the fiddly part. It runs on artwork nobody has inspected,
///   and both of its failure modes look plausible in code — anchoring on the sky
///   instead of the ground, or clipping a tower instead of scaling.
/// - The **hue**, still derived from a byte hash rather than `String.hashValue`.
/// - **Place-ness**, which is the only thing keeping `coverImageState`'s `none` case
///   meaningful now that an image model will illustrate any string on request.
/// - The **prompt version**, which is the only mechanism for invalidating cached art.
final class TripCoverTests: XCTestCase {

    // MARK: - Deterministic hue

    /// Asserted on the palette INDEX, not on the `Color`.
    ///
    /// `Color.paper(_:_:)` builds a fresh `UIColor`/`NSColor` with a fresh provider
    /// closure on every call, so two `Color`s for the same palette entry are never
    /// `==`. A test that compared hues directly failed while the code was correct,
    /// which is why `paletteIndex(for:)` is exposed.
    func testPaletteIndexIsStableForTheSameUUID() {
        let uuid = UUID(uuidString: "5B2A9F3C-1D4E-4A7B-8C90-11223344AABB")!
        let first = TripCoverArt.paletteIndex(for: uuid)
        for _ in 0..<50 {
            XCTAssertEqual(TripCoverArt.paletteIndex(for: uuid), first)
        }
    }

    /// Pins the algorithm to concrete outputs, recorded from the implementation. A
    /// change here re-colours every existing trip, so it should read as a deliberate
    /// decision rather than slip through inside a refactor.
    func testPaletteIndexPinsKnownUUIDs() {
        let expected: [String: Int] = [
            "00000000-0000-0000-0000-000000000000": 0,
            "5B2A9F3C-1D4E-4A7B-8C90-11223344AABB": 1,
            "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF": 0,
            "1A2B3C4D-5E6F-4071-8293-A4B5C6D7E8F9": 0
        ]
        for (raw, index) in expected {
            let actual = TripCoverArt.paletteIndex(for: UUID(uuidString: raw)!)
            XCTAssertEqual(actual, index, "\(raw) moved from palette \(index) to \(actual)")
            XCTAssertTrue(ListAppearance.palette.indices.contains(actual))
        }
    }

    /// Not a distribution proof, just a guard against a hash that collapses (e.g.
    /// summing bytes with no multiplier, where two swapped bytes collide).
    func testPaletteIndexSpreadsAcrossThePalette() {
        var seen = Set<Int>()
        for _ in 0..<200 {
            seen.insert(TripCoverArt.paletteIndex(for: UUID()))
        }
        XCTAssertGreaterThanOrEqual(
            seen.count, 6,
            "200 random trips only reached \(seen.count) of \(ListAppearance.palette.count) palette colours"
        )
    }

    // MARK: - Glyph fallback

    /// Still load-bearing after the pivot: this art is what a trip whose name is not a
    /// place keeps permanently, and what every trip shows for the tens of seconds
    /// before its illustration lands.
    func testGlyphMapsTripShapedKeywords() {
        XCTAssertEqual(TripCoverArt.glyph(for: "Bali beach break"), "beach.umbrella")
        XCTAssertEqual(TripCoverArt.glyph(for: "Hakuba ski week"), "snowflake")
        XCTAssertEqual(TripCoverArt.glyph(for: "Lisbon work offsite"), "briefcase")
        XCTAssertEqual(TripCoverArt.glyph(for: "Rohan's wedding"), "gift")
        XCTAssertEqual(TripCoverArt.glyph(for: "Annapurna trek"), "mountain.2")
        XCTAssertEqual(TripCoverArt.glyph(for: "Interrail Europe"), "tram")
        XCTAssertEqual(TripCoverArt.glyph(for: "Family Christmas"), "house")
    }

    func testGlyphFallsBackToAirplane() {
        XCTAssertEqual(TripCoverArt.glyph(for: "Hong Kong"), "airplane")
        XCTAssertEqual(TripCoverArt.glyph(for: ""), "airplane")
    }

    func testUncommonSymbolsExistOnTheBaseline() {
        XCTAssertTrue(ListAppearance.isValidSymbol("mountain.2"))
        XCTAssertTrue(ListAppearance.isValidSymbol("snowflake"))
        XCTAssertTrue(ListAppearance.isValidSymbol("beach.umbrella"))
        XCTAssertTrue(ListAppearance.isValidSymbol("tram"))
    }

    // MARK: - Place-ness

    /// Fetching got this for free: a corpus lookup for "Work offsite" simply 404'd,
    /// and that 404 was what made the `none` state meaningful. An image model has no
    /// such honesty, so this local check is now the only thing standing between a
    /// non-place trip name and a confidently generated illustration of nowhere — plus
    /// tens of seconds and real money per attempt, repeatedly, since `failed` retries.
    func testPlacenessAcceptsRealDestinations() {
        for name in ["Hong Kong", "Pune", "Italy", "Bali beach break", "New York", "Hakuba"] {
            XCTAssertTrue(TripCoverPlaceness.isLikelyPlace(name), "\(name) is a place")
        }
    }

    func testPlacenessRejectsOccasions() {
        for name in ["Work offsite", "Rohan's wedding", "Dad's birthday", "Team offsite", "AWS conference"] {
            XCTAssertFalse(TripCoverPlaceness.isLikelyPlace(name), "\(name) is an occasion, not a place")
        }
    }

    func testPlacenessRejectsEmptyNames() {
        XCTAssertFalse(TripCoverPlaceness.isLikelyPlace(""))
        XCTAssertFalse(TripCoverPlaceness.isLikelyPlace("   "))
    }

    /// `work` is letter-bounded so it cannot fire inside an ordinary word. Without the
    /// bound, "Networking trip" would be judged a non-place and never get art.
    func testPlacenessWorkIsLetterBounded() {
        XCTAssertTrue(TripCoverPlaceness.isLikelyPlace("Networking trip"))
        XCTAssertFalse(TripCoverPlaceness.isLikelyPlace("Work trip to Berlin"))
    }

    // MARK: - The pinned prompt

    /// The version is the ONLY mechanism for invalidating cached art. If it stops being
    /// stored, or stops being compared, a prompt change leaves a device showing a mix of
    /// old and new art with no way to tell which is which by looking.
    func testPromptVersionIsPinned() {
        XCTAssertEqual(TripCoverPrompt.version, "1")
        XCTAssertEqual(TripCoverPrompt.model, "gpt-image-1-mini")
        XCTAssertEqual(TripCoverPrompt.size, "1536x1024")
    }

    /// One prompt for every destination, with the name substituted in. The crop depends
    /// on the composition this asks for, so the constraints that matter to it are
    /// asserted rather than left to a reading of the string.
    func testPromptSubstitutesDestinationAndKeepsItsConstraints() {
        let prompt = TripCoverPrompt.text(for: "Hong Kong")
        XCTAssertTrue(prompt.contains("Hong Kong"))
        XCTAssertTrue(prompt.contains("BOTTOM QUARTER"), "the crop's whole premise")
        XCTAssertTrue(prompt.contains("single common groundline"), "what makes a base detectable")
        XCTAssertTrue(prompt.contains("no text"), "lettering in generated art is unfixable")

        // Same prompt, different destination: nothing else varies.
        let other = TripCoverPrompt.text(for: "Pune")
        XCTAssertEqual(
            prompt.replacingOccurrences(of: "Hong Kong", with: "{d}"),
            other.replacingOccurrences(of: "Pune", with: "{d}")
        )
    }

    // MARK: - The crop

    /// The band proportion is one decision expressed in two files. If they drift, the
    /// cached art no longer matches the band it was cropped for.
    func testCropRatioMatchesTheBandMetric() {
        XCTAssertEqual(TripCoverCrop.bandRatio, Double(TripCoverMetrics.ratio))
    }

    /// A silhouette that fits is bottom-anchored on its base, so the skyline rises out
    /// of the seam divider with sky above it.
    func testCropAnchorsWhenTheSilhouetteFits() throws {
        // 1536x1024 → 384px band, 15px pad. A 200px silhouette fits easily.
        let image = makeSkyline(width: 1536, height: 1024, top: 800, base: 1000, bars: 5)
        let result = try XCTUnwrap(TripCoverCrop.crop(image))

        XCTAssertEqual(result.path, .anchored)
        XCTAssertEqual(result.scale, 1.0)
        XCTAssertEqual(result.bandHeight, 384)
        XCTAssertEqual(result.silhouetteTop, 800)
        XCTAssertEqual(result.silhouetteBase, 1000)

        let out = try XCTUnwrap(decode(result.imageData))
        XCTAssertEqual(out.width, 1536)
        XCTAssertEqual(out.height, 384)
    }

    /// Orientation, asserted on pixels rather than trusted.
    ///
    /// Getting the bitmap's row order backwards would anchor the crop on the SKY and
    /// still compile, still run, and still produce a plausible-looking 4:1 image. The
    /// only way to catch it is to look at where the buildings ended up.
    func testCropPutsTheSkylineAtTheBottomWithSkyAbove() throws {
        let image = makeSkyline(width: 1536, height: 1024, top: 800, base: 1000, bars: 5)
        let result = try XCTUnwrap(TripCoverCrop.crop(image))
        let decoded = try XCTUnwrap(decode(result.imageData))
        let bitmap = try XCTUnwrap(TripCoverCrop.Bitmap(decoded))

        // The band opens on empty sky.
        XCTAssertTrue(isBackgroundRow(bitmap, y: 4), "band should open on empty sky")
        XCTAssertTrue(isBackgroundRow(bitmap, y: 100), "upper band should still be sky")

        // The base sits `pad` above the bottom edge, so the very last rows are the
        // background pad and the rows just above them are silhouette.
        let pad = Int(Double(result.bandHeight) * TripCoverCrop.padFraction)
        XCTAssertTrue(
            isBackgroundRow(bitmap, y: result.bandHeight - 2),
            "the 4% pad below the base should be background"
        )
        XCTAssertFalse(
            isBackgroundRow(bitmap, y: result.bandHeight - pad - 5),
            "rows just above the pad should carry the skyline"
        )
    }

    /// A silhouette taller than the band is SCALED, never clipped. Losing the top of a
    /// tower is far more visible than a few percent of vertical compression on flat
    /// geometric shapes.
    func testCropScalesRatherThanClippingATallSilhouette() throws {
        // A 700px silhouette against a 384px band cannot fit.
        let image = makeSkyline(width: 1536, height: 1024, top: 300, base: 1000, bars: 5)
        let result = try XCTUnwrap(TripCoverCrop.crop(image))

        XCTAssertEqual(result.path, .scaled)
        XCTAssertEqual(result.bandHeight, 384)
        XCTAssertLessThan(result.scale, 1.0)
        XCTAssertGreaterThan(result.scale, 0.4)
        // A 369px target over a 701px strip.
        XCTAssertEqual(result.scale, 369.0 / 701.0, accuracy: 0.001)

        let out = try XCTUnwrap(decode(result.imageData))
        XCTAssertEqual(out.height, 384, "the band height is fixed whichever path is taken")

        // Nothing clipped: the whole silhouette is present, so the top of the band
        // carries building rather than sky.
        let bitmap = try XCTUnwrap(TripCoverCrop.Bitmap(out))
        XCTAssertFalse(
            isBackgroundRow(bitmap, y: 3),
            "a scaled strip starts at the top of the band, so no tower is lost"
        )
    }

    /// A lone spire above the main mass must be part of the silhouette.
    ///
    /// This is the bug that shipped clipped art in the first live run. A single spire
    /// crossing a row scores exactly two transitions, so the 6-transition threshold that
    /// correctly finds the groundline silently excluded every narrow feature standing
    /// above it: 124px above Hong Kong's detected top, 106px above Pune's, which cut the
    /// Bank of China Tower's antennae and sheared Pune's clock tower flat against the
    /// frame. Italy was unaffected, which is how it survived the first review.
    func testCropIncludesALoneSpireAboveTheMass() throws {
        // Mass 700...900, plus one thin spire reaching up to row 500.
        let image = makeSkyline(
            width: 1536, height: 1024, top: 700, base: 900, bars: 5, spireTop: 500
        )
        let result = try XCTUnwrap(TripCoverCrop.crop(image))

        XCTAssertEqual(result.silhouetteTop, 500, "the spire's tip is the silhouette's top")
        XCTAssertEqual(result.silhouetteBase, 900, "the base still comes from the mass")
    }

    /// With the spire included, the anchored path's no-clipping guarantee becomes real:
    /// `silhouetteHeight + pad <= bandHeight` rearranges to `cropTop <= silhouetteTop`,
    /// so the window always opens at or above the tip. It was previously vacuous,
    /// because the "top" it guaranteed was not the real top.
    func testAnchoredCropNeverOpensBelowTheSpireTip() throws {
        let image = makeSkyline(
            width: 1536, height: 1024, top: 800, base: 1000, bars: 5, spireTop: 760
        )
        let result = try XCTUnwrap(TripCoverCrop.crop(image))
        XCTAssertEqual(result.path, .anchored)
        XCTAssertEqual(result.silhouetteTop, 760)

        // The tip is inside the band, so the band's top row is sky and the spire is
        // fully present below it.
        let bitmap = try XCTUnwrap(TripCoverCrop.Bitmap(XCTUnwrap(decode(result.imageData))))
        let cropTop = result.silhouetteBase
            + Int(Double(result.bandHeight) * TripCoverCrop.padFraction)
            - result.bandHeight
        XCTAssertLessThanOrEqual(cropTop, result.silhouetteTop)
        XCTAssertTrue(isBackgroundRow(bitmap, y: 2), "sky above the tip")
    }

    /// A blank or near-uniform image has no silhouette. Reporting failure is right: the
    /// caller records `failed`, draws the glyph art, and re-rolls later. Cropping an
    /// empty band would look like a rendering bug instead.
    func testCropRejectsArtWithNoSilhouette() {
        let blank = makeSkyline(width: 1536, height: 1024, top: 0, base: 0, bars: 0)
        XCTAssertNil(TripCoverCrop.crop(blank))
    }

    /// A source shorter than the band it has to fill has nothing sensible to crop.
    func testCropRejectsASourceShorterThanTheBand() {
        let squat = makeSkyline(width: 1536, height: 200, top: 100, base: 150, bars: 5)
        XCTAssertNil(TripCoverCrop.crop(squat))
    }

    /// Sky and open water are near-uniform and must not register as silhouette. This is
    /// the failure that made "anchor to the lowest non-background pixel" worse than
    /// useless: a wide flat band of water counted as content, so the crop found the
    /// bottom of the water instead of the base of the buildings.
    func testTransitionCountIgnoresFlatBandsOfColour() {
        // One wide block spans the width with only two edges, well under the
        // 6-transition threshold, so it reads as water rather than as buildings.
        let water = makeSkyline(width: 1536, height: 1024, top: 900, base: 1000, bars: 1)
        XCTAssertNil(TripCoverCrop.crop(water), "one flat block is water, not a skyline")
    }

    // MARK: - Three-valued state

    @MainActor
    func testNeedsFetchTreatsTheThreeStatesDifferently() {
        let service = TripCoverService()
        let trip = LocalTrip(name: "Hong Kong", startDate: .now, endDate: .now)

        // Never attempted.
        XCTAssertTrue(service.needsFetch(trip))

        // Not a place. Settled — the runaway guard, and it now guards real money per
        // attempt rather than three cheap HTTP calls.
        trip.coverImageState = TripCoverState.none.rawValue
        XCTAssertFalse(service.needsFetch(trip))

        // Generation failed. Retry.
        trip.coverImageState = TripCoverState.failed.rawValue
        XCTAssertTrue(service.needsFetch(trip))

        // Resolved with no path at all: nothing to draw, so regenerate.
        trip.coverImageState = TripCoverState.resolved.rawValue
        trip.coverArtPromptVersion = TripCoverPrompt.version
        trip.coverImagePath = nil
        XCTAssertTrue(service.needsFetch(trip))

        // Resolved with a path whose file is not on this device — the sync case. Must
        // read as un-generated so the sweep re-derives it from the trip's name.
        trip.coverImagePath = "trip-covers/does-not-exist-on-this-device.jpg"
        XCTAssertTrue(service.needsFetch(trip))

        // An unrecognised string from a newer build: retry rather than give up.
        trip.coverImageState = "something-else"
        XCTAssertTrue(service.needsFetch(trip))
    }

    /// Art from a superseded prompt must regenerate. This also covers every fetched
    /// PHOTOGRAPH left on the device by build 1102: those have a path, a `resolved`
    /// state and a nil prompt version, so they are replaced by illustrations rather
    /// than lingering as the one photo in a list of drawings.
    @MainActor
    func testNeedsFetchRegeneratesArtFromASupersededPrompt() {
        let service = TripCoverService()
        let trip = LocalTrip(name: "Hong Kong", startDate: .now, endDate: .now)
        trip.coverImageState = TripCoverState.resolved.rawValue
        trip.coverImagePath = "trip-covers/whatever.jpg"

        trip.coverArtPromptVersion = nil
        XCTAssertTrue(service.needsFetch(trip), "a build-1102 photograph must be replaced")

        trip.coverArtPromptVersion = "0"
        XCTAssertTrue(service.needsFetch(trip), "art from an older prompt must be replaced")
    }

    // MARK: - Migration safety

    /// Every cover field optional with a nil default, and NOTHING removed. Build 1102 is
    /// installed, so the store already has the five original columns; removing an
    /// attribute triggers a lightweight migration this feature has no reason to risk.
    /// The two attribution fields are dead but deliberately kept.
    func testCoverFieldsDefaultToNilAndNoneAreRemoved() {
        let trip = LocalTrip(name: "Hong Kong", startDate: .now, endDate: .now)
        XCTAssertNil(trip.coverImagePath)
        XCTAssertNil(trip.coverImageState)
        XCTAssertNil(trip.coverArtPromptVersion)
        // Dead, kept, and still nil-defaulted.
        XCTAssertNil(trip.coverImageSourceURL)
        XCTAssertNil(trip.coverImageAttribution)
        XCTAssertNil(trip.coverImageAttributionURL)
    }

    // MARK: - Fixtures

    /// A synthetic illustration: flat background, plus `bars` evenly spaced vertical
    /// blocks spanning rows `top...base`. Each bar contributes two transitions, so
    /// `bars` of 3 or more clears the 6-transition threshold and `bars` of 1 does not.
    ///
    /// `spireTop`, when given, adds ONE narrow bar reaching from that row down to
    /// `top` — a lone spire above the mass, scoring only two transitions on its own
    /// rows, which is the case the two thresholds exist for.
    private func makeSkyline(
        width: Int, height: Int, top: Int, base: Int, bars: Int, spireTop: Int? = nil
    ) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // Warm off-white, matching what the prompt asks the model for.
        ctx.setFillColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        if bars > 0 {
            ctx.setFillColor(red: 0.25, green: 0.22, blue: 0.19, alpha: 1)
            let barWidth = width / (bars * 2 + 1)
            for i in 0..<bars {
                let x = barWidth + i * barWidth * 2
                // CGContext user space is bottom-left and `top`/`base` are measured from
                // the TOP, so flip here. Doing it in the fixture rather than in the
                // assertions keeps the tests reading in image coordinates.
                let yBottom = height - base - 1
                let barHeight = base - top + 1
                ctx.fill(CGRect(x: x, y: yBottom, width: barWidth, height: barHeight))
            }
            if let spireTop {
                // Narrow, and over one bar only, so its own rows score exactly two
                // transitions.
                let spireWidth = max(4, barWidth / 8)
                ctx.fill(CGRect(
                    x: barWidth + barWidth / 2,
                    y: height - top - 1,
                    width: spireWidth,
                    height: top - spireTop + 1
                ))
            }
        }
        return ctx.makeImage()!
    }

    private func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Whether a row is (near enough) all background, sampled the way the crop samples.
    private func isBackgroundRow(_ bitmap: TripCoverCrop.Bitmap, y: Int) -> Bool {
        let background = bitmap.pixel(4, 4)
        return bitmap.transitions(row: y, background: background) < TripCoverCrop.minTransitions
    }
}
