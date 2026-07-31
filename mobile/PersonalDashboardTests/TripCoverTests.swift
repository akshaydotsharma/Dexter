import XCTest
@testable import PersonalDashboard

/// Trip cover photography (#428).
///
/// Three pieces of this feature are pure functions with no network and no store,
/// and all three are the kind of thing that fails silently:
///
/// - The hue is derived from a byte hash of `clientUUID` specifically because
///   `String.hashValue` is randomly seeded per process. Using it would change
///   every trip's colour on every launch, which reads as a rendering glitch and
///   is close to impossible to attribute. Pinning a known UUID to a known palette
///   entry is what makes that regression a test failure instead of a mystery.
/// - The quality gate is the only thing between an encyclopedic lead image and a
///   flag stretched across the band.
/// - The query normaliser is what turns a trip label into a page title.
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

    /// Pins the algorithm to concrete outputs, recorded from the implementation.
    /// A change here re-colours every existing trip, so it should read as a
    /// deliberate decision rather than slip through inside a refactor.
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

    /// Different trips should not all land on one colour. Not a distribution
    /// proof, just a guard against a hash that collapses (e.g. summing bytes with
    /// no multiplier, where two swapped bytes collide).
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

    // MARK: - Glyph table

    func testGlyphMapsTripShapedKeywords() {
        XCTAssertEqual(TripCoverArt.glyph(for: "Bali beach break"), "beach.umbrella")
        XCTAssertEqual(TripCoverArt.glyph(for: "Hakuba ski week"), "snowflake")
        XCTAssertEqual(TripCoverArt.glyph(for: "Lisbon work offsite"), "briefcase")
        XCTAssertEqual(TripCoverArt.glyph(for: "West coast road trip"), "beach.umbrella")
        XCTAssertEqual(TripCoverArt.glyph(for: "Rohan's wedding"), "gift")
        XCTAssertEqual(TripCoverArt.glyph(for: "Annapurna trek"), "mountain.2")
        XCTAssertEqual(TripCoverArt.glyph(for: "Interrail Europe"), "tram")
        XCTAssertEqual(TripCoverArt.glyph(for: "Family Christmas"), "house")
    }

    /// The default is a plane, not `checklist`. `ListAppearance.infer(from:)`
    /// would have given the latter, which is why this feature has its own table.
    func testGlyphFallsBackToAirplane() {
        XCTAssertEqual(TripCoverArt.glyph(for: "Vietnam"), "airplane")
        XCTAssertEqual(TripCoverArt.glyph(for: ""), "airplane")
        XCTAssertEqual(TripCoverArt.glyph(for: "Japan 2026"), "airplane")
    }

    /// Both of the less common symbols must exist on the deployment baseline, or
    /// the band renders blank.
    func testUncommonSymbolsExistOnTheBaseline() {
        XCTAssertTrue(ListAppearance.isValidSymbol("mountain.2"))
        XCTAssertTrue(ListAppearance.isValidSymbol("snowflake"))
        XCTAssertTrue(ListAppearance.isValidSymbol("beach.umbrella"))
        XCTAssertTrue(ListAppearance.isValidSymbol("tram"))
    }

    // MARK: - Query normalisation

    func testPageTitleStripsYearsAndPossessives() {
        let t = WikimediaTripCoverProvider.pageTitle(from:)
        XCTAssertEqual(t("Japan 2026"), "Japan")
        XCTAssertEqual(t("2027 Vietnam"), "Vietnam")
        XCTAssertEqual(t("Rohan's wedding"), "Rohan wedding")
        XCTAssertEqual(t("Rohan’s wedding"), "Rohan wedding")
        XCTAssertEqual(t("  Bali   "), "Bali")
        XCTAssertEqual(t("Hanoi, Vietnam"), "Hanoi Vietnam")
    }

    /// A four-digit number that is not a year must survive: stripping any four
    /// digits would mangle real place names.
    func testPageTitleKeepsNonYearNumbers() {
        XCTAssertEqual(WikimediaTripCoverProvider.pageTitle(from: "Area 51"), "Area 51")
        XCTAssertEqual(WikimediaTripCoverProvider.pageTitle(from: "Highway 1620"), "Highway 1620")
    }

    func testPageTitleOfAnEmptyOrYearOnlyNameIsEmpty() {
        XCTAssertEqual(WikimediaTripCoverProvider.pageTitle(from: ""), "")
        XCTAssertEqual(WikimediaTripCoverProvider.pageTitle(from: "2026"), "")
    }

    // MARK: - Quality gate

    private func candidate(_ url: String, _ w: Int, _ h: Int) -> TripCoverCandidate {
        TripCoverCandidate(
            imageURL: URL(string: url)!,
            pixelWidth: w,
            pixelHeight: h,
            attribution: nil,
            attributionURL: nil
        )
    }

    func testGateAcceptsARealLandscapePhotograph() {
        XCTAssertTrue(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/Hanoi_Old_Quarter.jpg", 2400, 1600)
        ))
        // Right at the bounds.
        XCTAssertTrue(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/City.jpg", 900, 300)   // exactly 3.0:1
        ))
        XCTAssertTrue(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/City.jpg", 990, 900)   // exactly 1.1:1
        ))
    }

    /// The encyclopedic-lead-image problem, which is the reason the gate exists.
    func testGateRejectsEncyclopedicArtwork() {
        let rejects = [
            "Flag_of_Vietnam.svg",
            "Flag_of_Japan.png",
            "Coat_of_arms_of_Portugal.png",
            "Coat%20of%20Arms_of_Spain.png",
            "Vietnam_locator_map.png",
            // The case that exposed the ticket's `\bmap\b`: `_` is a word
            // character, so `\b` never fires between "Map" and "_of", and every
            // locator map sailed through the gate. Now bounded on letters.
            "Map_of_Bali.jpg",
            "world-map.png",
            "Great_Seal_of_the_United_States.png",
            "Company_logo.png",
            "National_emblem.png",
            "Tokyo_montage.jpg",
            "Paris_collage.jpg",
            "Timelapse.ogv"
        ]
        for name in rejects {
            XCTAssertFalse(
                WikimediaTripCoverProvider.passesGate(
                    candidate("https://upload.wikimedia.org/x/\(name)", 2400, 1600)
                ),
                "\(name) should not have passed the gate"
            )
        }
    }

    func testGateRejectsBadGeometry() {
        // Too small to fill an 868pt band at 2x without upscaling.
        XCTAssertFalse(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/Hanoi.jpg", 640, 400)
        ))
        // Portrait: a 2.4:1 band would throw most of it away.
        XCTAssertFalse(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/Tower.jpg", 1200, 1600)
        ))
        // Panorama: the band would show a slice of its middle.
        XCTAssertFalse(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/Skyline.jpg", 4000, 800)
        ))
        // Degenerate.
        XCTAssertFalse(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/Broken.jpg", 1200, 0)
        ))
    }

    /// The gate reads the FILENAME, so a rejected word in the host or the
    /// directory path must not reject an otherwise good photograph.
    func testGateOnlyInspectsTheFilename() {
        XCTAssertTrue(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/maps/logo/Hanoi_Old_Quarter.jpg", 2400, 1600)
        ))
    }

    /// The other half of tightening `map`: real place names that merely contain
    /// the letters must still get their photograph.
    func testGateDoesNotRejectPlacesThatContainMap() {
        for name in ["Maputo_skyline.jpg", "Mapo_District_Seoul.jpg", "Sanmap.jpg", "Kathmandu_valley.jpg"] {
            XCTAssertTrue(
                WikimediaTripCoverProvider.passesGate(
                    candidate("https://upload.wikimedia.org/x/\(name)", 2400, 1600)
                ),
                "\(name) is a place photograph and should have passed"
            )
        }
    }

    // MARK: - Attribution cleanup

    func testAttributionStripsHTML() {
        XCTAssertEqual(
            WikimediaTripCoverProvider.strippingHTML(
                "<a href=\"//commons.wikimedia.org/wiki/User:Someone\" title=\"User:Someone\">Someone</a>"
            ),
            "Someone"
        )
        XCTAssertEqual(
            WikimediaTripCoverProvider.strippingHTML("Jane &amp; John Doe"),
            "Jane & John Doe"
        )
        XCTAssertEqual(WikimediaTripCoverProvider.strippingHTML("  <span>CC BY-SA 4.0</span> "), "CC BY-SA 4.0")
    }

    // MARK: - Three-valued state

    /// `none` must be a settled answer and `failed` must not be, or a placeless
    /// trip re-hits the network on every launch forever.
    @MainActor
    func testNeedsFetchTreatsTheThreeStatesDifferently() {
        let service = TripCoverService()
        let trip = LocalTrip(name: "Work offsite", startDate: .now, endDate: .now)

        // Never attempted.
        XCTAssertTrue(service.needsFetch(trip))

        // Searched, nothing suitable. Settled — this is the runaway guard.
        trip.coverImageState = TripCoverState.none.rawValue
        XCTAssertFalse(service.needsFetch(trip))

        // Transient failure. Retry.
        trip.coverImageState = TripCoverState.failed.rawValue
        XCTAssertTrue(service.needsFetch(trip))

        // Resolved but with no path at all: nothing to draw, so re-fetch.
        trip.coverImageState = TripCoverState.resolved.rawValue
        trip.coverImagePath = nil
        XCTAssertTrue(service.needsFetch(trip))

        // Resolved with a path whose file is not on this device — the sync case.
        // Must read as un-fetched so the sweep re-derives it from the source URL.
        trip.coverImagePath = "trip-covers/does-not-exist-on-this-device.jpg"
        XCTAssertTrue(service.needsFetch(trip))

        // An unrecognised string from a newer build: retry rather than give up.
        trip.coverImageState = "something-else"
        XCTAssertTrue(service.needsFetch(trip))
    }

    // MARK: - Migration safety

    /// Every cover field must be optional with a nil default. A trip constructed
    /// the way every pre-existing row will be read back must report no cover and
    /// no attempt, or the lightweight migration is not the additive one this
    /// change claims to be.
    func testNewFieldsDefaultToNil() {
        let trip = LocalTrip(name: "Vietnam", startDate: .now, endDate: .now)
        XCTAssertNil(trip.coverImagePath)
        XCTAssertNil(trip.coverImageSourceURL)
        XCTAssertNil(trip.coverImageAttribution)
        XCTAssertNil(trip.coverImageAttributionURL)
        XCTAssertNil(trip.coverImageState)
    }
}
