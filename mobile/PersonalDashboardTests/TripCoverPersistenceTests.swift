import XCTest
import SwiftData
import CoreGraphics
import ImageIO
@testable import PersonalDashboard

/// Does generated cover art actually SURVIVE (#428)?
///
/// Device QA found art that generated, appeared, and was gone on relaunch. That whole
/// class of bug is invisible to a static build and to any single-session test: the
/// in-memory model is mutated, the view observes it, the illustration fades in, and
/// everything looks correct right up until the process restarts.
///
/// So these tests do the only thing that can catch it. They run the real service
/// against a real FILE-BACKED store, then open a **second `ModelContainer` on the same
/// file** and assert what actually landed on disk. A second container reading the same
/// file is exactly the relaunch condition, which makes this an honest automation of the
/// round trip rather than a proxy for it.
///
/// The one thing these do NOT cover is the app process itself relaunching — scene
/// wiring, `.task` ordering, the sweep's once-per-process latch. That needs the app,
/// and it is called out as such rather than implied.
@MainActor
final class TripCoverPersistenceTests: XCTestCase {

    private var storeDirectory: URL!
    private var storeURL: URL!
    private var writtenPaths: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        storeDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trip-cover-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        storeURL = storeDirectory.appendingPathComponent("Store.sqlite")
        writtenPaths = []
    }

    override func tearDown() async throws {
        // Cover files land in the test host's Documents, so clean up after ourselves
        // rather than leaving art from every run behind.
        for path in writtenPaths {
            try? ReceiptStorage.tripCovers.delete(relativePath: path)
        }
        try? FileManager.default.removeItem(at: storeDirectory)
        try await super.tearDown()
    }

    // MARK: - The round trip

    /// Generate art, then prove the three fields are on DISK by reading them back
    /// through a different container.
    func testGeneratedArtSurvivesIntoANewContainer() async throws {
        let tripID = UUID()

        // ---- Session one: a real container, a real trip, a real generation. ----
        do {
            let container = try makeContainer()
            let context = ModelContext(container)
            context.insert(LocalTrip(
                clientUUID: tripID, name: "Hong Kong", startDate: .now, endDate: .now
            ))
            try context.save()

            let service = TripCoverService(
                provider: StubArtProvider(), storage: .tripCovers, context: context
            )
            await service.resolveOnWrite(tripUUID: tripID)

            // In-memory state: this is all the device QA session could see, and it was
            // correct there too.
            let inMemory = try XCTUnwrap(fetch(tripID, in: context))
            XCTAssertEqual(inMemory.coverImageState, TripCoverState.resolved.rawValue)
            XCTAssertEqual(inMemory.coverArtPromptVersion, TripCoverPrompt.version)
            let path = try XCTUnwrap(inMemory.coverImagePath, "no path was stamped")
            writtenPaths.append(path)

            // The bytes are on disk.
            XCTAssertNotNil(
                ReceiptStorage.tripCovers.load(relativePath: path),
                "the cover file should exist at the stamped path"
            )
        }

        // ---- Session two: a NEW container on the same file. The relaunch. ----
        let reopened = try makeContainer()
        let freshContext = ModelContext(reopened)
        let restored = try XCTUnwrap(
            fetch(tripID, in: freshContext),
            "the trip itself did not persist, so the store never received the insert"
        )

        XCTAssertEqual(
            restored.coverImageState, TripCoverState.resolved.rawValue,
            "coverImageState did not reach the store — art would regenerate every launch"
        )
        XCTAssertEqual(
            restored.coverArtPromptVersion, TripCoverPrompt.version,
            "coverArtPromptVersion did not reach the store — every launch would re-bill"
        )
        let restoredPath = try XCTUnwrap(
            restored.coverImagePath,
            "coverImagePath did not reach the store: THIS is art that appears and then vanishes"
        )
        XCTAssertNotNil(
            ReceiptStorage.tripCovers.load(relativePath: restoredPath),
            "the file the persisted path points at is missing"
        )
    }

    /// The backfill must be idempotent. A trip already holding current-version art is
    /// never regenerated, so a relaunch costs ZERO generations rather than re-billing
    /// the whole library every time the app opens.
    func testSecondPassGeneratesNothingForArtThatAlreadyExists() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let ids = (0..<4).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            context.insert(LocalTrip(
                clientUUID: id, name: "City \(i)", startDate: .now, endDate: .now
            ))
        }
        try context.save()

        let provider = StubArtProvider()
        let first = TripCoverService(provider: provider, storage: .tripCovers, context: context)
        await first.runRepairSweep()

        XCTAssertEqual(provider.callCount, 4, "all four trips should be filled in ONE pass")
        for id in ids {
            let trip = try XCTUnwrap(fetch(id, in: context))
            let path = try XCTUnwrap(trip.coverImagePath)
            writtenPaths.append(path)
        }

        // A second service instance is a fresh process as far as the once-per-launch
        // latch is concerned.
        let secondProvider = StubArtProvider()
        let second = TripCoverService(
            provider: secondProvider, storage: .tripCovers, context: context
        )
        await second.runRepairSweep()
        XCTAssertEqual(
            secondProvider.callCount, 0,
            "a relaunch must not regenerate art that is already current"
        )
    }

    /// A save that cannot succeed must be VISIBLE. Swallowing it is what turns a
    /// persistence failure into "it worked, then it vanished", which costs a device QA
    /// round trip to even notice.
    func testAFailedPersistRecordsFailedRatherThanReportingSuccess() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let tripID = UUID()
        context.insert(LocalTrip(
            clientUUID: tripID, name: "Hong Kong", startDate: .now, endDate: .now
        ))
        try context.save()

        let service = TripCoverService(
            provider: FailingArtProvider(), storage: .tripCovers, context: context
        )
        await service.resolveOnWrite(tripUUID: tripID)

        let trip = try XCTUnwrap(fetch(tripID, in: context))
        XCTAssertEqual(
            trip.coverImageState, TripCoverState.failed.rawValue,
            "a generation failure must record `failed` so the sweep retries"
        )
        XCTAssertNil(trip.coverImagePath)

        // And `failed` must persist, or the retry decision is lost on relaunch.
        let reopened = ModelContext(try makeContainer())
        let restored = try XCTUnwrap(fetch(tripID, in: reopened))
        XCTAssertEqual(restored.coverImageState, TripCoverState.failed.rawValue)
    }

    /// A name that is not a place settles on the permanent `none` and never calls the
    /// model. At tens of seconds and real money per attempt, this is the guard that
    /// matters most.
    func testNonPlaceNameNeverCallsTheModelAndPersistsNone() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let tripID = UUID()
        context.insert(LocalTrip(
            clientUUID: tripID, name: "Work offsite", startDate: .now, endDate: .now
        ))
        try context.save()

        let provider = StubArtProvider()
        let service = TripCoverService(provider: provider, storage: .tripCovers, context: context)
        await service.resolveOnWrite(tripUUID: tripID)

        XCTAssertEqual(provider.callCount, 0, "a non-place must not reach the image model")

        let reopened = ModelContext(try makeContainer())
        let restored = try XCTUnwrap(fetch(tripID, in: reopened))
        XCTAssertEqual(restored.coverImageState, TripCoverState.none.rawValue)
    }

    // MARK: - The render-path cache

    /// A miss must NEVER be cached.
    ///
    /// This is the defect that produced the reported symptom. The cache was
    /// `[String: PlatformImage?]`, and `if let cached = entries[path]` on a dictionary
    /// of optionals unwraps one level, so a stored `nil` was a cache HIT returning nil.
    /// One transient miss blanked that trip for the rest of the process, and nothing
    /// could recover it: a trip whose art is present and correct on disk is never
    /// regenerated, so no new key was ever minted.
    ///
    /// Asserted as the sequence that matters: ask for a path before its file exists,
    /// then write the file and ask again. The second answer must be the image.
    func testCacheDoesNotPoisonAPathThatArrivesLate() throws {
        TripCoverImageCache.reset()
        let relativePath = "trip-covers/late-\(UUID().uuidString).jpg"

        // Nothing on disk yet: a miss, and it must not be remembered as one.
        XCTAssertNil(TripCoverImageCache.image(forRelativePath: relativePath))

        // The file arrives.
        let jpeg = try XCTUnwrap(smallJPEG())
        _ = try ReceiptStorage.tripCovers.write(data: jpeg, relativePath: relativePath)
        writtenPaths.append(relativePath)

        XCTAssertNotNil(
            TripCoverImageCache.image(forRelativePath: relativePath),
            "a path that missed once must be retried, not blanked for the session"
        )
    }

    /// A success IS cached, which is the whole reason the cache exists: the band reads
    /// synchronously on every render and decoding a JPEG per row in a scrolling list
    /// would be far too expensive.
    func testCacheServesRepeatedReadsFromMemory() throws {
        TripCoverImageCache.reset()
        let relativePath = "trip-covers/hit-\(UUID().uuidString).jpg"
        let jpeg = try XCTUnwrap(smallJPEG())
        _ = try ReceiptStorage.tripCovers.write(data: jpeg, relativePath: relativePath)
        writtenPaths.append(relativePath)

        let first = TripCoverImageCache.image(forRelativePath: relativePath)
        XCTAssertNotNil(first)

        // Delete the file: a cached success must still answer, proving it came from
        // memory rather than from a fresh read.
        try ReceiptStorage.tripCovers.delete(relativePath: relativePath)
        XCTAssertNotNil(
            TripCoverImageCache.image(forRelativePath: relativePath),
            "a decoded cover should be served from memory on later renders"
        )
    }

    func testCacheIgnoresNilAndEmptyPaths() {
        TripCoverImageCache.reset()
        XCTAssertNil(TripCoverImageCache.image(forRelativePath: nil))
        XCTAssertNil(TripCoverImageCache.image(forRelativePath: ""))
    }

    // MARK: - Helpers

    /// A tiny valid JPEG, via the same encoder the app uses.
    private func smallJPEG() -> Data? {
        let ctx = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// A file-backed container on this test's own store file, carrying the app's real
    /// schema so the migration behaviour is the real one.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SwiftDataStore.schemaModels)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func fetch(_ uuid: UUID, in context: ModelContext) throws -> LocalTrip? {
        try context.fetch(
            FetchDescriptor<LocalTrip>(predicate: #Predicate { $0.clientUUID == uuid })
        ).first
    }
}

// MARK: - Stub providers

/// Returns a synthetic skyline the real crop can actually process: flat background,
/// five bars sitting on a groundline, sized like the model's own output.
private final class StubArtProvider: TripCoverArtProvider, @unchecked Sendable {
    private(set) var callCount = 0

    func illustration(forDestination destination: String) async throws -> Data {
        callCount += 1
        return Self.skylinePNG()
    }

    static func skylinePNG() -> Data {
        let width = 1536, height = 1024
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0.25, green: 0.22, blue: 0.19, alpha: 1)
        // Mass across rows 800...1000, measured from the top.
        let barWidth = width / 11
        for i in 0..<5 {
            ctx.fill(CGRect(
                x: barWidth + i * barWidth * 2,
                y: height - 1000 - 1,
                width: barWidth,
                height: 201
            ))
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

private struct FailingArtProvider: TripCoverArtProvider {
    func illustration(forDestination destination: String) async throws -> Data {
        throw TripCoverArtProviderError.badStatus(429, "rate limited")
    }
}
