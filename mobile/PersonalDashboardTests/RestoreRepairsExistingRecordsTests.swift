import XCTest
import SwiftData
@testable import PersonalDashboard

/// Repairing records a lossy archive already created (#366).
///
/// The field case: the Mac's store was seeded from a pre-#335 iPhone archive
/// whose expense records carried 14 fields instead of 25. Every dropped field
/// landed at its default, so 27 trip expenses came back as loose Finance rows
/// with `tripUUID` nil and `hiddenFromFinance` false. Restoring the CORRECT
/// archive afterwards did nothing at all: merge is keyed on `clientUUID`, those
/// UUIDs were already present, so every row was skipped and the commit button
/// was disabled for reporting nothing to do.
///
/// These tests pin both halves of the fix: the preview gate has to be
/// mode-aware (otherwise repair is unreachable at exactly the moment it is
/// needed), and repair has to overwrite matching rows while leaving records the
/// archive does not mention alone. The insert-only default is pinned too, since
/// #349 verified the recovery path against those semantics.
///
/// Everything runs against an isolated in-memory store and a zip built in the
/// test's own temp dir. Driving the real `preview(url:)` + `commit(preview:mode:)`
/// path rather than hand-building a `Preview` is deliberate: the bug lived in
/// the counts feeding the gate, which a hand-built preview would bypass.
@MainActor
final class RestoreRepairsExistingRecordsTests: XCTestCase {

    private var store: SwiftDataStore!
    private var tempDir: URL!

    /// The expense that reproduces the field case, by its real UUID.
    private let expenseUUID = "b45140b7-ce4b-4f2a-85e6-b412461eca08"
    private let tripUUID = "000E0A91-68AB-4244-BE65-04ED7F2A5260"

    override func setUp() async throws {
        try await super.setUp()
        store = SwiftDataStore(container: SwiftDataStore.makeInMemory())
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("repair-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        store = nil
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The row as a lossy (pre-#335) restore left it: present, but with every
    /// field that archive dropped sitting at its default.
    private func insertDamagedExpense() {
        let expense = LocalExpense(
            clientUUID: expenseUUID,
            date: Date(timeIntervalSince1970: 1_784_131_200),
            category: "accommodation",
            merchant: "W Hong Kong",
            expenseDescription: "Accommodation Service Charge",
            originalAmount: 4449.8,
            originalCurrency: "HKD",
            sgdAmount: 732.61,
            fxRate: 0.16463903406278715,
            source: "photo",
            createdAt: Date(timeIntervalSince1970: 1_784_364_348)
        )
        store.context.insert(expense)
        try? store.context.save()
    }

    /// A complete (post-#335) archive holding the SAME expense with its trip
    /// linkage and per-surface hide flag intact, plus a person the damaged
    /// store never received.
    private func writeCompleteArchive() throws -> URL {
        let manifest: [String: Any] = [
            "schemaVersion": DataArchive.currentSchemaVersion,
            "exportedAt": "2026-07-27T14:15:08Z",
            "appVersion": "1.2.97 (903)",
            "data": [
                "tasks": [], "notes": [], "noteFolders": [],
                "lists": [], "listItems": [],
                "itineraries": [], "itineraryDays": [], "vocab": [],
                "expenses": [[
                    "clientUUID": expenseUUID,
                    "date": "2026-07-15T16:00:00Z",
                    "category": "accommodation",
                    "merchant": "W Hong Kong",
                    "expenseDescription": "Accommodation Service Charge",
                    "originalAmount": 4449.8,
                    "originalCurrency": "HKD",
                    "sgdAmount": 732.6107737725903,
                    "fxRate": 0.16463903406278715,
                    "source": "photo",
                    "createdAt": "2026-07-18T08:45:48Z",
                    "isRefund": false,
                    "dedupeDescriptor": "",
                    "dedupeKey": "",
                    "sourceReference": "",
                    "statementLabel": "",
                    "statementFileName": "",
                    "numberOfShares": 1,
                    "hiddenFromFinance": true,
                    "hiddenFromTrip": false,
                    "tripUUID": tripUUID,
                ]],
                "persons": [[
                    "clientUUID": "11111111-2222-3333-4444-555555555555",
                    "name": "Parul",
                    "colorHex": "#FF8800",
                    "createdAt": "2026-07-01T00:00:00Z",
                ]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        let url = tempDir.appendingPathComponent("Dexter-Backup.zip")
        try MiniZip.write(entries: [MiniZip.Entry(name: "manifest.json", data: data)], to: url)
        return url
    }

    private func fetchExpense() throws -> LocalExpense? {
        try store.context.fetch(FetchDescriptor<LocalExpense>())
            .first { $0.clientUUID == expenseUUID }
    }

    // MARK: - The gate

    /// The heart of #366. With every incoming UUID already present, insert-only
    /// has nothing to do and correctly reports so, but repair must report the
    /// overlap and stay committable. Before the fix both modes shared one count
    /// and the button was dead.
    func testPreviewGateIsModeAware() throws {
        insertDamagedExpense()
        let service = DataImportService(modelContext: store.context)
        let preview = try service.preview(url: try writeCompleteArchive())

        let skip = preview.counts(for: .skipExisting)[.expenses] ?? .zero
        XCTAssertEqual(skip.total, 1)
        XCTAssertEqual(skip.new, 0)
        XCTAssertEqual(skip.repaired, 0)
        XCTAssertEqual(skip.skipped, 1)

        let repair = preview.counts(for: .replaceMatching)[.expenses] ?? .zero
        XCTAssertEqual(repair.total, 1)
        XCTAssertEqual(repair.new, 0)
        XCTAssertEqual(repair.repaired, 1)
        XCTAssertEqual(repair.skipped, 0)

        // The person is absent locally, so it is a plain insert in BOTH modes.
        XCTAssertEqual(preview.counts(for: .skipExisting)[.persons]?.new, 1)
        XCTAssertEqual(preview.counts(for: .replaceMatching)[.persons]?.new, 1)

        XCTAssertTrue(preview.hasAnythingToImport(for: .replaceMatching))
        XCTAssertEqual(preview.totalRepaired(for: .replaceMatching), 1)
    }

    /// Side models joined the archive in #319 but were absent from the preview's
    /// entity list until #366, so they contributed nothing to the gate. An
    /// archive carrying ONLY side models reported nothing to import and refused
    /// to restore them.
    func testSideModelsCountTowardTheGate() throws {
        let service = DataImportService(modelContext: store.context)
        let preview = try service.preview(url: try writeCompleteArchive())

        XCTAssertEqual(preview.counts(for: .skipExisting)[.persons]?.total, 1)
        XCTAssertTrue(preview.hasAnythingToImport(for: .skipExisting))
    }

    // MARK: - Repair

    func testRepairModeHealsFieldsALossyRestoreDropped() throws {
        insertDamagedExpense()
        XCTAssertNil(try fetchExpense()?.tripUUID, "precondition: the damaged row has no trip link")

        let service = DataImportService(modelContext: store.context)
        let preview = try service.preview(url: try writeCompleteArchive())
        try service.commit(preview: preview, mode: .replaceMatching)

        let healed = try XCTUnwrap(try fetchExpense())
        XCTAssertEqual(healed.tripUUID?.uuidString.uppercased(), tripUUID)
        XCTAssertTrue(healed.hiddenFromFinance, "the row the user removed from Finance must stay removed")
        XCTAssertFalse(healed.hiddenFromTrip)
        // Still exactly one row: repaired, not duplicated.
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<LocalExpense>()).count, 1)
        // And the side model the damaged store never had is now present.
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<LocalPerson>()).count, 1)
    }

    /// The #349 contract: plain restore never overwrites. Pinned so the repair
    /// option cannot quietly become the default.
    func testSkipModeStillNeverOverwrites() throws {
        insertDamagedExpense()

        let service = DataImportService(modelContext: store.context)
        let preview = try service.preview(url: try writeCompleteArchive())
        try service.commit(preview: preview, mode: .skipExisting)

        let untouched = try XCTUnwrap(try fetchExpense())
        XCTAssertNil(untouched.tripUUID)
        XCTAssertFalse(untouched.hiddenFromFinance)
        XCTAssertEqual(try store.context.fetch(FetchDescriptor<LocalExpense>()).count, 1)
    }

    /// Why wipe-and-restore was the wrong tool for the field case: the Mac held
    /// a trip and notes the phone's archive did not. Repair must not be a
    /// disguised wipe.
    func testRecordsAbsentFromTheArchiveSurviveRepair() throws {
        insertDamagedExpense()
        let macOnly = LocalTrip(
            name: "Hong Kong",
            startDate: Date(timeIntervalSince1970: 1_794_000_000),
            endDate: Date(timeIntervalSince1970: 1_794_800_000)
        )
        store.context.insert(macOnly)
        let macOnlyExpense = LocalExpense(
            clientUUID: "99999999-9999-4999-8999-999999999999",
            category: "food",
            merchant: "Mac only",
            originalAmount: 12,
            originalCurrency: "SGD",
            sgdAmount: 12,
            fxRate: 1,
            source: "manual"
        )
        store.context.insert(macOnlyExpense)
        try store.context.save()

        let service = DataImportService(modelContext: store.context)
        let preview = try service.preview(url: try writeCompleteArchive())
        try service.commit(preview: preview, mode: .replaceMatching)

        XCTAssertEqual(try store.context.fetch(FetchDescriptor<LocalTrip>()).count, 1,
                       "a trip the archive never mentions must survive a repair")
        let expenses = try store.context.fetch(FetchDescriptor<LocalExpense>())
        XCTAssertEqual(expenses.count, 2)
        XCTAssertTrue(expenses.contains { $0.clientUUID == macOnlyExpense.clientUUID })
    }
}
