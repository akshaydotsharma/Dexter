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
        // Right at the bounds: the 1400px floor, 3.0:1, and 1.1:1.
        XCTAssertTrue(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/City.jpg", 1400, 467)
        ))
        XCTAssertTrue(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/City.jpg", 1540, 1400)
        ))
    }

    /// The floor was raised from 900 to 1400 (see `minimumPixelWidth`). 1024x768
    /// is the real `Pho_quay.JPG`, which used to win for "Vietnam" and is the
    /// specific weak result the raise was measured against.
    func testGateEnforcesTheRaisedResolutionFloor() {
        XCTAssertFalse(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/Pho_quay.JPG", 1024, 768)
        ))
        XCTAssertTrue(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/Cua_Tung_Beach.jpg", 2822, 1829)
        ))
    }

    // MARK: - Corpus order

    /// Wikivoyage BEFORE Wikipedia, pinned.
    ///
    /// This is the whole design and it is invisible at every call site. A travel
    /// guide's image pool is scenery by construction; an encyclopedia's is not, and
    /// searching Wikipedia first is what produced an 1859 painting of the Siege of
    /// Saigon for "Vietnam" and a medieval scroll for "Japan". If a future change
    /// reorders these, that regression comes straight back and nothing else in the
    /// suite would notice.
    func testCorpusOrderPutsWikivoyageFirst() {
        XCTAssertEqual(
            WikimediaTripCoverProvider.corpusOrder,
            [.wikivoyage, .wikipedia]
        )
        XCTAssertEqual(WikimediaTripCoverProvider.Corpus.wikivoyage.rawValue, "en.wikivoyage.org")
        XCTAssertEqual(WikimediaTripCoverProvider.Corpus.wikipedia.rawValue, "en.wikipedia.org")
        // Every corpus in the enum must be in the search order, or adding one
        // silently does nothing.
        XCTAssertEqual(
            Set(WikimediaTripCoverProvider.corpusOrder),
            Set(WikimediaTripCoverProvider.Corpus.allCases)
        )
    }

    /// Wikivoyage's `summary` lead image is deliberately NOT trusted: measured, it
    /// is a globe SVG for Vietnam and a district map for Lisbon. Its `media-list`
    /// is the useful part.
    func testOnlyWikipediaContributesALeadImage() {
        XCTAssertFalse(WikimediaTripCoverProvider.Corpus.wikivoyage.usesLeadImage)
        XCTAssertTrue(WikimediaTripCoverProvider.Corpus.wikipedia.usesLeadImage)
    }

    /// Both corpora lead with a map for the destinations this feature was tuned on,
    /// so the gate has to reject them or every trip gets a map. Real filenames and
    /// real measured dimensions from live responses.
    ///
    /// Both are now caught by NAME. Lisbon's used to be caught only by the 1.1:1
    /// aspect floor, which meant one landscape administrative map would have won;
    /// `districts` and `freguesias` closed that.
    func testGateRejectsTheLeadingMapOfEachCorpus() {
        let vietnamRegions = candidate(
            "https://upload.wikimedia.org/x/Vietnam_Regions_Map.png", 1992, 3331
        )
        XCTAssertFalse(WikimediaTripCoverProvider.passesGate(vietnamRegions))
        XCTAssertFalse(WikimediaTripCoverProvider.passesNameGate("File:Vietnam_Regions_Map.png"))

        let lisbonDistricts = candidate(
            "https://upload.wikimedia.org/x/Lisboa_freguesias_-_Wikivoyage_City_districts_divison.png",
            3249, 3036
        )
        XCTAssertFalse(WikimediaTripCoverProvider.passesGate(lisbonDistricts))
        XCTAssertFalse(
            WikimediaTripCoverProvider.passesNameGate(
                "File:Lisboa_freguesias_-_Wikivoyage_City_districts_divison.png"
            ),
            "By name, not by luck of the aspect floor"
        )
    }

    // MARK: - The administrative-map class

    /// Maps whose filenames never contain the word "map". Every name here is a real
    /// live response for one of the user's own destinations, so this is a
    /// regression test against his actual data rather than an invented case.
    func testNameGateRejectsAdministrativeMaps() {
        let rejects = [
            "File:Italy_regions.png",                                             // Italy
            "File:Lisboa_freguesias_-_Wikivoyage_City_districts_divison.png",     // Lisbon
            "File:Japan_topo_en.jpg",                                             // Japan
            "File:Bali2022OSM.png",                                               // Bali
            "File:Spain_provinces.png",
            "File:France_administrative_divisions.png",
            "File:Germany_political.png",
            "File:India_subdivisions.png",
            "File:Nepal_topographic.jpg"
        ]
        for name in rejects {
            XCTAssertFalse(
                WikimediaTripCoverProvider.passesNameGate(name),
                "\(name) is an administrative map and should not have passed"
            )
        }
    }

    /// The strongest single case in the class: this was the FIRST name-plausible
    /// candidate for "Hong Kong", one of the user's four real trips, at 4416x3312 —
    /// comfortably through every geometry check, so nothing else would have stopped
    /// it. It is a close-up of a boundary marker stone.
    ///
    /// Also the case that killed the date-filter idea: its `DateTimeOriginal` is
    /// 2010-04-17, because it is a modern photograph OF an old stone, not an old
    /// photograph. A pre-1970 reject would not have touched it.
    func testNameGateRejectsTheHongKongBoundaryStone() {
        XCTAssertFalse(WikimediaTripCoverProvider.passesNameGate(
            "File:City_Boundary_1903_-_Old_Peak_Road.jpg"
        ))
        XCTAssertFalse(WikimediaTripCoverProvider.passesGate(
            candidate("https://upload.wikimedia.org/x/City_Boundary_1903_-_Old_Peak_Road.jpg", 4416, 3312)
        ))
    }

    /// Plurals are deliberate. The singular forms appear in ordinary place names,
    /// so matching them would reject real photographs of real places.
    func testAdministrativeRejectsAreScopedToPlurals() {
        for name in [
            "File:Mapo_District_Seoul.jpg",
            "File:Yunnan_Province_terraces.jpg",
            "File:Region_of_Tuscany_sunset.jpg"
        ] {
            XCTAssertTrue(
                WikimediaTripCoverProvider.passesNameGate(name),
                "\(name) is a place photograph and should have passed"
            )
        }
    }

    /// `osm` is letter-bounded so it catches `Bali2022OSM.png` without eating a
    /// word that merely contains those letters.
    func testOSMRejectIsLetterBounded() {
        XCTAssertFalse(WikimediaTripCoverProvider.passesNameGate("File:Bali2022OSM.png"))
        XCTAssertTrue(WikimediaTripCoverProvider.passesNameGate("File:Cosmos_flowers_Hokkaido.jpg"))
        XCTAssertTrue(WikimediaTripCoverProvider.passesNameGate("File:Osmania_University_Hyderabad.jpg"))
    }

    /// The three covers the user will actually see. Pinned so a future reject word
    /// cannot quietly take one of his trips back to generated art.
    func testTheUsersRealCoversStillPassTheNameGate() {
        for name in [
            "File:13-08-08-hongkong-by-RalfR-Panorama2.jpg",                        // Hong Kong
            "File:Pu_La_Deshpande_garden_1.JPG",                                    // Pune
            "File:Vue_des_toits_depuis_la_Sainte-Trinité-des-Monts,_Rome,_Italy.jpg" // Italy
        ] {
            XCTAssertTrue(
                WikimediaTripCoverProvider.passesNameGate(name),
                "\(name) is a live-verified cover for one of the user's trips"
            )
        }
    }

    // MARK: - Stub corpus rule

    /// A Wikivoyage page offering one or two images is a stub, not a guide, so the
    /// "scenery by construction" argument does not hold and Wikipedia is the better
    /// source. Measured: Hakuba's Wikivoyage page has exactly one image — a train —
    /// which beat Wikipedia's ski-resort photo purely by corpus order.
    func testStubThresholdAppliesToWikivoyageOnly() {
        XCTAssertEqual(WikimediaTripCoverProvider.Corpus.wikivoyage.stubThreshold, 3)
        // nil, not a number: Wikipedia is already the fallback, and a threshold
        // there would only turn usable covers into `none`.
        XCTAssertNil(WikimediaTripCoverProvider.Corpus.wikipedia.stubThreshold)
    }

    /// The stub decision is counted on name-plausible candidates, so it costs no
    /// extra request. This is the function that count comes from: it dedupes on the
    /// API's own title normalisation, drops rejects, and caps.
    func testNamePlausibleTitlesDedupesGatesAndCaps() {
        let input = [
            "File:Hanoi_Old_Quarter.jpg",
            "File:Hanoi Old Quarter.jpg",        // same file, API spelling
            "File:Vietnam_Regions_Map.png",      // rejected by name
            "File:Cua_Tung_Beach.jpg"
        ]
        let out = WikimediaTripCoverProvider.namePlausibleTitles(input, limit: 12)
        XCTAssertEqual(out.count, 2, "one duplicate collapsed, one map rejected")
        XCTAssertEqual(out.first, "File:Hanoi_Old_Quarter.jpg", "page order preserved")

        // The cap is honoured, which is what keeps a 74-image page cheap.
        let many = (0..<40).map { "File:Photo_\($0).jpg" }
        XCTAssertEqual(WikimediaTripCoverProvider.namePlausibleTitles(many, limit: 12).count, 12)

        // A page of nothing but maps counts as zero, so it reads as a stub and
        // falls through rather than resolving to a map.
        let allMaps = ["File:A_regions.png", "File:B_districts.png", "File:C_locator.svg"]
        XCTAssertTrue(WikimediaTripCoverProvider.namePlausibleTitles(allMaps, limit: 12).isEmpty)
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

    // MARK: - Name gate (runs before any metadata request)

    /// A rasterised SVG thumbnail is named `NNNpx-Foo.svg.png`, so its extension
    /// says "png" while the artwork is vector. This is what let
    /// `Bali_in_Indonesia_(special_marker).svg.png` through in a live run.
    func testNameGateRejectsRasterisedVectors() {
        XCTAssertFalse(WikimediaTripCoverProvider.passesNameGate("960px-Flag_of_Vietnam.svg.png"))
        XCTAssertFalse(WikimediaTripCoverProvider.passesNameGate("1280px-Bali_in_Indonesia_(special_marker).svg.png"))
        XCTAssertFalse(WikimediaTripCoverProvider.passesNameGate("File:Vietnam_(orthographic_projection).svg"))
        XCTAssertFalse(WikimediaTripCoverProvider.passesNameGate("File:Location_Vietnam_ASEAN.svg"))
        XCTAssertFalse(WikimediaTripCoverProvider.passesNameGate("Timelapse.webm"))
        XCTAssertFalse(WikimediaTripCoverProvider.passesNameGate("Animation.gif"))
    }

    func testNameGateAcceptsPhotographs() {
        XCTAssertTrue(WikimediaTripCoverProvider.passesNameGate("File:Ho_Chi_Minh_City_Skyline.jpg"))
        XCTAssertTrue(WikimediaTripCoverProvider.passesNameGate("Hakuba_Happo-one_Winter_Resort.JPG"))
        XCTAssertTrue(WikimediaTripCoverProvider.passesNameGate("Lisboa_-_Portugal_(52597836992).jpg"))
    }

    // MARK: - Upload URL unwrapping

    /// `summary` hands back a thumbnail URL, not the original. Both of the
    /// thumbnailer's transformations have to be undone or the metadata lookup that
    /// supplies the real dimensions and the credit line misses.
    func testFileNameUnwrapsThumbnailURLs() {
        let f = { (s: String) in
            WikimediaTripCoverProvider.fileName(fromUploadURL: URL(string: s)!)
        }
        // Size prefix plus a raster extension bolted onto a vector original.
        XCTAssertEqual(
            f("https://upload.wikimedia.org/wikipedia/commons/thumb/2/21/Flag_of_Vietnam.svg/960px-Flag_of_Vietnam.svg.png"),
            "Flag_of_Vietnam.svg"
        )
        // Size prefix only.
        XCTAssertEqual(
            f("https://upload.wikimedia.org/wikipedia/commons/thumb/a/b/Hanoi.jpg/1280px-Hanoi.jpg"),
            "Hanoi.jpg"
        )
        // An original, untouched.
        XCTAssertEqual(
            f("https://upload.wikimedia.org/wikipedia/commons/9/95/Ho_Chi_Minh_City_Skyline.jpg"),
            "Ho_Chi_Minh_City_Skyline.jpg"
        )
        // Percent-encoded parentheses survive as characters.
        XCTAssertEqual(
            f("https://upload.wikimedia.org/wikipedia/commons/thumb/2/28/Vietnam_%28orthographic_projection%29.svg/500px-Vietnam_%28orthographic_projection%29.svg.png"),
            "Vietnam_(orthographic_projection).svg"
        )
        // A real `.png` photograph must NOT be mistaken for a rasterised vector.
        XCTAssertEqual(
            f("https://upload.wikimedia.org/wikipedia/commons/thumb/a/b/Skyline.png/900px-Skyline.png"),
            "Skyline.png"
        )
    }

    /// The MediaWiki API answers with spaces where the request had underscores, so
    /// candidates are matched on a canonical form or every lookup misses.
    func testNormalisedTitleMatchesTheAPIsOwnCasing() {
        XCTAssertEqual(
            WikimediaTripCoverProvider.normalisedTitle("File:Flag_of_Vietnam.svg"),
            WikimediaTripCoverProvider.normalisedTitle("File:Flag of Vietnam.svg")
        )
    }

    // MARK: - URL hygiene

    /// Wikivoyage appends `utm_source` / `utm_campaign` / `utm_content` to the URLs
    /// it hands back. They must never reach `coverImageSourceURL`, which is the
    /// portable identity of a cover: the self-heal re-fetch reads it on a device
    /// that has the row but not the file, and two rows differing only by
    /// `utm_content` would read as two different covers.
    func testTrackingParametersAreStripped() {
        let strip = { (s: String) in
            WikimediaTripCoverProvider.strippingTrackingParameters(s)?.absoluteString
        }
        XCTAssertEqual(
            strip("https://upload.wikimedia.org/wikipedia/commons/thumb/1/15/Cua_Tung_Beach.jpg/500px-Cua_Tung_Beach.jpg?utm_source=en.wikivoyage.org&utm_campaign=parser&utm_content=thumbnail"),
            "https://upload.wikimedia.org/wikipedia/commons/thumb/1/15/Cua_Tung_Beach.jpg/500px-Cua_Tung_Beach.jpg"
        )
        // No query at all: unchanged, and no stray "?" left behind.
        XCTAssertEqual(
            strip("https://upload.wikimedia.org/wikipedia/commons/1/15/Cua_Tung_Beach.jpg"),
            "https://upload.wikimedia.org/wikipedia/commons/1/15/Cua_Tung_Beach.jpg"
        )
        // A non-tracking parameter is preserved rather than blanket-stripped.
        XCTAssertEqual(
            strip("https://example.org/a.jpg?page=2&utm_source=x"),
            "https://example.org/a.jpg?page=2"
        )
    }

    /// Wikimedia's API etiquette enforces a descriptive agent with a contact route;
    /// a bare default gets HTTP errors from the Commons API, which in this feature
    /// would surface as a `failed` state and a silent retry loop. One constant, so
    /// the metadata calls and the byte download cannot drift apart.
    func testUserAgentIsDescriptiveAndContactable() {
        let ua = TripCoverUserAgent.value
        XCTAssertTrue(ua.hasPrefix("Dexter/"))
        XCTAssertTrue(ua.contains("https://"), "Wikimedia asks for a contact route in the UA")
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
