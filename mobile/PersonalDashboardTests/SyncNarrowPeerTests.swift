import XCTest
import SwiftData
import CoreGraphics
import ImageIO
@testable import PersonalDashboard

/// Can an older peer erase a column it has never heard of? (#428)
///
/// Measured on the user's phone before this fix: five `LocalTrip` rows had
/// `coverImagePath`, `coverImageState` and `coverArtPromptVersion` all NULL while
/// fifteen cover JPEGs sat in `Documents/trip-covers/`. His Mac was running a build
/// predating those fields, so its `LocalTrip` upserts carried no cover keys, and the
/// applier's `.replaceMatching` rewrote each row from that narrower payload. `updatedAt`
/// moved with every erasure, which is what made it look like a local write had failed.
///
/// ## The peer here is genuinely narrow, not a same-schema stand-in
///
/// This matters enough to be explicit about. The ops are built by hand as raw JSON with
/// the cover keys **removed**, which is byte-for-byte what an older build emits. A test
/// that encoded a current `ItineraryDTO` and left its cover fields nil would produce the
/// same wire bytes only by accident of `encodeIfPresent`, and would keep passing if the
/// merge rule were later written to compare DTO defaults instead of key presence. The
/// bug lives in the difference between "key absent" and "value nil", so the test has to
/// control the keys.
@MainActor
final class SyncNarrowPeerTests: XCTestCase {

    private var storeDirectory: URL!
    private var storeURL: URL!
    private var writtenPaths: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        storeDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-narrow-peer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        storeURL = storeDirectory.appendingPathComponent("Store.sqlite")
        writtenPaths = []
    }

    override func tearDown() async throws {
        for path in writtenPaths { try? ReceiptStorage.tripCovers.delete(relativePath: path) }
        try? FileManager.default.removeItem(at: storeDirectory)
        try await super.tearDown()
    }

    /// THE regression. A narrow peer renames a trip; the cover fields must survive.
    func testNarrowPeerUpsertDoesNotEraseCoverFields() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let tripID = UUID()

        let trip = LocalTrip(
            clientUUID: tripID, name: "Japan", startDate: .now, endDate: .now
        )
        let keepPath = "trip-covers/keep-me-\(UUID().uuidString).jpg"
        _ = try ReceiptStorage.tripCovers.write(data: Self.tinyJPEG(), relativePath: keepPath)
        writtenPaths.append(keepPath)
        trip.coverImagePath = keepPath
        trip.coverImageState = TripCoverState.resolved.rawValue
        trip.coverArtPromptVersion = TripCoverPrompt.version
        context.insert(trip)
        try context.save()

        // The peer knows nothing about covers, and says so by omission.
        let op = try narrowTripUpsert(
            tripID: tripID, name: "Japan 2027", lamport: 99, context: context
        )
        XCTAssertFalse(
            try keys(of: op).contains("coverImagePath"),
            "the fixture is not a narrow peer if it mentions covers at all"
        )

        let outcome = try SyncApplier(modelContext: context)
            .apply([op], localDeviceUUID: UUID())
        XCTAssertEqual(outcome.applied, 1)

        // Read through a NEW container: this is the store, not the in-memory graph.
        let restored = try XCTUnwrap(fetch(tripID, in: ModelContext(try makeContainer())))
        XCTAssertEqual(restored.name, "Japan 2027", "the peer's own field must win")
        XCTAssertEqual(
            restored.coverImagePath, keepPath,
            "a peer that has never heard of coverImagePath must not be able to null it"
        )
        XCTAssertEqual(restored.coverImageState, TripCoverState.resolved.rawValue)
        XCTAssertEqual(restored.coverArtPromptVersion, TripCoverPrompt.version)
    }

    /// The rule is general, not a cover-specific patch: the same omission protects any
    /// additively-added field. `notes` stands in for "a field the peer did send", to prove
    /// preservation is not blanket-ignoring the payload.
    func testNarrowPeerStillWinsOnFieldsItDidSend() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let tripID = UUID()

        let trip = LocalTrip(
            clientUUID: tripID, name: "Pune", startDate: .now, endDate: .now, notes: "local notes"
        )
        let punePath = "trip-covers/pune-\(UUID().uuidString).jpg"
        _ = try ReceiptStorage.tripCovers.write(data: Self.tinyJPEG(), relativePath: punePath)
        writtenPaths.append(punePath)
        trip.coverImagePath = punePath
        context.insert(trip)
        try context.save()

        let op = try narrowTripUpsert(
            tripID: tripID, name: "Pune", lamport: 42, context: context, notes: "peer notes"
        )
        _ = try SyncApplier(modelContext: context).apply([op], localDeviceUUID: UUID())

        let restored = try XCTUnwrap(fetch(tripID, in: ModelContext(try makeContainer())))
        XCTAssertEqual(restored.notes, "peer notes", "a field the peer sent must overwrite")
        XCTAssertEqual(restored.coverImagePath, punePath, "an absent field must not")
    }

    /// An explicit `null` IS an opinion and must overwrite, or the merge would make every
    /// optional permanently unclearable by any peer.
    func testExplicitNullFromAPeerDoesOverwrite() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let tripID = UUID()

        let trip = LocalTrip(clientUUID: tripID, name: "Italy", startDate: .now, endDate: .now)
        let italyPath = "trip-covers/italy-\(UUID().uuidString).jpg"
        _ = try ReceiptStorage.tripCovers.write(data: Self.tinyJPEG(), relativePath: italyPath)
        writtenPaths.append(italyPath)
        trip.coverImagePath = italyPath
        context.insert(trip)
        try context.save()

        let op = try narrowTripUpsert(
            tripID: tripID, name: "Italy", lamport: 7, context: context,
            explicitNullCoverPath: true
        )
        _ = try SyncApplier(modelContext: context).apply([op], localDeviceUUID: UUID())

        let restored = try XCTUnwrap(fetch(tripID, in: ModelContext(try makeContainer())))
        XCTAssertNil(
            restored.coverImagePath,
            "a key present with a null value is a deliberate clear and must apply"
        )
    }

    /// The merge primitive on its own, so the rule is pinned independently of the applier.
    func testPreservingFieldsAbsentHere() throws {
        let local = JSONValue.object([
            "name": .string("Japan"),
            "coverImagePath": .string("trip-covers/a.jpg"),
            "coverImageState": .string("resolved")
        ])
        let incoming = JSONValue.object([
            "name": .string("Japan 2027"),
            "coverImageState": .null
        ])
        guard case .object(let merged) = incoming.preservingFieldsAbsentHere(from: local) else {
            return XCTFail("merge should stay an object")
        }
        XCTAssertEqual(merged["name"], .string("Japan 2027"), "present key wins")
        XCTAssertEqual(merged["coverImagePath"], .string("trip-covers/a.jpg"), "absent key preserved")
        XCTAssertEqual(merged["coverImageState"], JSONValue.null, "explicit null wins")
    }

    /// A non-object payload must pass through untouched rather than trap.
    func testMergeIgnoresNonObjectPayloads() {
        XCTAssertEqual(
            JSONValue.string("x").preservingFieldsAbsentHere(from: .object(["a": .null])),
            .string("x")
        )
        XCTAssertEqual(
            JSONValue.object(["a": .null]).preservingFieldsAbsentHere(from: .string("x")),
            .object(["a": .null])
        )
    }

    // MARK: - Helpers

    /// A `LocalTrip` upsert exactly as a build predating the cover fields emits it: the
    /// current DTO encoded, then every cover key STRIPPED from the JSON.
    private func narrowTripUpsert(
        tripID: UUID,
        name: String,
        lamport: Int,
        context: ModelContext,
        notes: String = "",
        explicitNullCoverPath: Bool = false
    ) throws -> SyncOp {
        let dto = DataArchive.ItineraryDTO(
            clientUUID: tripID, name: name, startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 86_400), notes: notes,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
            participantsData: nil
        )
        let encoded = try DataArchive.makeEncoder().encode(dto)
        guard case .object(var fields) = try JSONValue.from(encoded: encoded) else {
            throw XCTSkip("DTO did not encode as an object")
        }
        for key in [
            "coverImagePath", "coverImageSourceURL", "coverImageAttribution",
            "coverImageAttributionURL", "coverImageState", "coverArtPromptVersion"
        ] {
            fields.removeValue(forKey: key)
        }
        if explicitNullCoverPath {
            fields["coverImagePath"] = .null
        }
        let payload = JSONValue.object(fields)

        // The applier re-hashes the payload and rejects a mismatch, so the hash has to be
        // of these exact bytes.
        let payloadData = try payload.encodedData()
        return SyncOp(
            opID: UUID(),
            deviceUUID: UUID(),
            lamport: Int64(lamport),
            wallClock: Date(),
            entity: "LocalTrip",
            recordID: tripID.uuidString,
            kind: .upsert,
            payload: payload,
            contentHash: SyncHash.hex(payloadData)
        )
    }

    private func keys(of op: SyncOp) throws -> Set<String> {
        guard case .object(let fields) = try XCTUnwrap(op.payload) else { return [] }
        return Set(fields.keys)
    }

    /// The cover FILE has to exist for these, because that is the device's real state:
    /// the JPEGs were on disk the whole time; only their paths were being erased.
    static func tinyJPEG() -> Data {
        let ctx = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(red: 0.4, green: 0.3, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SwiftDataStore.schemaModels)
        return try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
    }

    private func fetch(_ uuid: UUID, in context: ModelContext) throws -> LocalTrip? {
        try context.fetch(
            FetchDescriptor<LocalTrip>(predicate: #Predicate { $0.clientUUID == uuid })
        ).first
    }
}
