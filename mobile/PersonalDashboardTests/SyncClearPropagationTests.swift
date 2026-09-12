import XCTest
import SwiftData
@testable import PersonalDashboard

/// Can a device clear a field? (#516)
///
/// Measured on the user's two devices: three Italy trip expenses carried a 50/50
/// split with Papa on the Mac and no split at all on the phone, a 95 euro
/// disagreement about his own share. The phone's oplog held the whole story for
/// City Tax Rome: lamport 11578 with no `splitsData` key, 11579 WITH one, then
/// 11580 without it again, which was him clearing the split. Both devices
/// recorded lamport 11580 from the iPhone and different content hashes, so the
/// Mac applied that clear and kept the split anyway.
///
/// `preservingFieldsAbsentHere` keeps any key the payload does not carry, which
/// is what stops a peer on an older schema nulling a column it has never heard
/// of (#428). Synthesized `Codable` drops nil optionals, so a cleared field was
/// absent for exactly the same reason an unknown one is, and the receiver could
/// not tell the two apart. The sender now says which it means.
@MainActor
final class SyncClearPropagationTests: XCTestCase {

    private var storeDirectory: URL!
    private var storeURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        storeDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        storeURL = storeDirectory.appendingPathComponent("Store.sqlite")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeDirectory)
        try await super.tearDown()
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SwiftDataStore.schemaModels)
        return try ModelContainer(
            for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
    }

    private func expense(splitWithPapa: Bool, papa: UUID) -> LocalExpense {
        let row = LocalExpense(
            clientUUID: "2b30fee1-0000-4000-8000-000000000001",
            category: "bills_and_utilities",
            merchant: "City Tax Rome",
            originalAmount: 10,
            originalCurrency: "EUR",
            sgdAmount: 14.7,
            fxRate: 1.47,
            source: "manual",
            paidByPersonUUID: papa
        )
        if splitWithPapa {
            row.splits = [ExpenseSplitEntry(person: nil, shares: 1),
                          ExpenseSplitEntry(person: papa, shares: 1)]
        }
        return row
    }

    /// Build the op a device publishes for a row, through the real mapper.
    private func upsert(for row: LocalExpense, lamport: Int64, in context: ModelContext) throws -> SyncOp {
        let payload = try DataExportService(modelContext: context).buildPayload()
        let record = try XCTUnwrap(
            SyncRecordMapper.records(from: payload)
                .first { $0.entity == "LocalExpense" && $0.recordID == row.clientUUID }
        )
        return SyncOp(
            opID: UUID(),
            deviceUUID: UUID(),
            lamport: lamport,
            wallClock: Date(timeIntervalSince1970: 1_757_462_400),
            entity: record.entity,
            recordID: record.recordID,
            kind: .upsert,
            payload: record.json,
            contentHash: record.contentHash
        )
    }

    // MARK: - The reported defect

    /// THE regression, end to end: the peer cleared the split, so the split goes.
    func testClearingASplitReachesTheOtherDevice() throws {
        let papa = UUID()

        // The sending device: the row as it stands AFTER the user cleared the split.
        let senderContext = ModelContext(try ModelContainer(
            for: Schema(SwiftDataStore.schemaModels),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        ))
        let cleared = expense(splitWithPapa: false, papa: papa)
        senderContext.insert(cleared)
        try senderContext.save()
        let op = try upsert(for: cleared, lamport: 11_580, in: senderContext)

        // The receiving device still holds the split.
        let context = ModelContext(try makeContainer())
        context.insert(expense(splitWithPapa: true, papa: papa))
        try context.save()

        let outcome = try SyncApplier(modelContext: context).apply([op], localDeviceUUID: UUID())
        XCTAssertEqual(outcome.applied, 1, "the op must not be rejected as corrupt")

        let restored = try XCTUnwrap(fetchExpense(in: ModelContext(try makeContainer())))
        XCTAssertTrue(
            restored.splits.isEmpty,
            "a split the sender cleared must clear here; it stayed for three of his expenses"
        )
        XCTAssertEqual(restored.paidByPersonUUID, papa, "clearing the split must not drop the payer")
    }

    /// The clear has to be visible on the wire, because that is the only place the
    /// receiver can read the difference from a field the sender never knew.
    func testAClearedFieldTravelsAsAnExplicitNull() throws {
        let context = ModelContext(try makeContainer())
        context.insert(expense(splitWithPapa: false, papa: UUID()))
        try context.save()

        let payload = try DataExportService(modelContext: context).buildPayload()
        let record = try XCTUnwrap(SyncRecordMapper.records(from: payload).first { $0.entity == "LocalExpense" })
        guard case .object(let fields) = record.json else { return XCTFail("payload is not an object") }

        XCTAssertEqual(fields["splitsData"], JSONValue.null, "an empty split must be stated, not omitted")
        XCTAssertEqual(fields["personUUID"], JSONValue.null)
        XCTAssertNotNil(fields["merchant"], "fields that DO have a value are untouched")
    }

    // MARK: - What must not regress

    /// #428 in one line: a peer that omits a key it has never heard of still cannot
    /// null it. `SyncNarrowPeerTests` owns the full case; this pins that the rule
    /// survives the sender now filling nulls.
    func testAnAbsentKeyIsStillPreserved() {
        let local = JSONValue.object(["splitsData": .string("kept"), "merchant": .string("local")])
        let incoming = JSONValue.object(["merchant": .string("peer")])
        XCTAssertEqual(
            incoming.preservingFieldsAbsentHere(from: local),
            .object(["splitsData": .string("kept"), "merchant": .string("peer")])
        )
    }

    /// The invariant `SyncApplier.verify` enforces: an op's hash is taken over the
    /// bytes it actually ships. Hashing the encoder's output instead would reject
    /// every op on the far side as corrupt, and sync would stop dead.
    func testEveryRecordHashesWhatItShips() throws {
        let context = ModelContext(try makeContainer())
        seedOneOfEverything(into: context)
        try context.save()

        let records = try SyncRecordMapper.records(from: DataExportService(modelContext: context).buildPayload())
        XCTAssertFalse(records.isEmpty)
        for record in records {
            XCTAssertEqual(
                record.contentHash, SyncHash.hex(try record.json.encodedData()),
                "\(record.entity) would be rejected as corrupt by the receiver"
            )
        }
    }

    /// Filling must be deterministic, or every pass would see every row as changed
    /// and the two devices would publish at each other forever. The one-time
    /// re-publish this change causes has to be exactly one.
    func testHashesAreStableAcrossPasses() throws {
        let context = ModelContext(try makeContainer())
        seedOneOfEverything(into: context)
        try context.save()

        let export = DataExportService(modelContext: context)
        let first = try SyncRecordMapper.records(from: export.buildPayload())
        let second = try SyncRecordMapper.records(from: export.buildPayload())
        XCTAssertEqual(
            first.map(\.contentHash), second.map(\.contentHash),
            "a second pass over unchanged rows must produce identical hashes"
        )
    }

    /// Composite records carry their children inside them, so the nulls have to
    /// reach inside the nested object and array too: a list ships with its checklist
    /// items, and a cleared per-item link has to read as cleared on the far side.
    ///
    /// Built from the DTOs directly rather than from a stored list, because
    /// `ChecklistItem.url` is never nil coming off the model (it defaults to ""),
    /// and a test that cannot produce the nil it is about proves nothing.
    func testNullsReachInsideANestedRecord() throws {
        let composite = SyncRecordMapper.ListWithItems(
            list: DataArchive.ListDTO(
                clientUUID: UUID(),
                title: "Packing",
                position: 0,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                deletedAt: nil,
                iconName: nil,
                colorHex: nil
            ),
            items: [DataArchive.ListItemDTO(
                listClientUUID: UUID(), position: 0, text: "Charger", checked: false, url: nil
            )]
        )
        let encoded = try DataArchive.makeEncoder().encode(composite)
        let filled = JSONValue.fillingNulls(of: composite, into: try JSONValue.from(encoded: encoded))

        guard case .object(let fields) = filled,
              case .array(let items)? = fields["items"],
              case .object(let item)? = items.first
        else { return XCTFail("the composite did not carry its items as objects") }

        XCTAssertEqual(item["url"], JSONValue.null, "a nested item's cleared link must be stated too")
        XCTAssertEqual(item["text"], JSONValue.string("Charger"))

        guard case .object(let list)? = fields["list"] else { return XCTFail("no nested list object") }
        XCTAssertEqual(list["deletedAt"], JSONValue.null, "the nested parent is walked as well")
    }

    /// A DTO that renamed its keys is left exactly as encoded: filling from property
    /// labels there would invent keys the decoder ignores and change the hash for
    /// nothing. No DTO does this today, which is why the guard needs a test of its own.
    func testAStructWithRenamedKeysIsLeftAlone() throws {
        struct Renamed: Codable {
            let name: String
            let note: String?
            enum CodingKeys: String, CodingKey {
                case name = "n"
                case note = "x"
            }
        }
        let value = Renamed(name: "Rome", note: nil)
        let json = try JSONValue.from(encoded: DataArchive.makeEncoder().encode(value))
        XCTAssertEqual(JSONValue.fillingNulls(of: value, into: json), json)
    }

    // MARK: - Helpers

    private func fetchExpense(in context: ModelContext) throws -> LocalExpense? {
        try context.fetch(FetchDescriptor<LocalExpense>()).first
    }

    /// One row per shape the filler has to walk: a plain record, a record with a
    /// nested array, and one with cleared optionals.
    private func seedOneOfEverything(into context: ModelContext) {
        let papa = UUID()
        context.insert(expense(splitWithPapa: false, papa: papa))
        context.insert(LocalTodo(title: "Check reddit forums"))
        context.insert(LocalNote(title: "Rome", content: "trip notes"))
        let list = LocalList(title: "Packing")
        list.items = [ChecklistItem(text: "Charger")]
        context.insert(list)
        context.insert(LocalTrip(clientUUID: UUID(), name: "Italy", startDate: .now, endDate: .now))
    }
}
