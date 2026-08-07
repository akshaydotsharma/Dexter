import XCTest
import SwiftData
@testable import PersonalDashboard

/// The relation between the hand-maintained model lists (#449).
///
/// `SwiftDataStore.schemaModels` says what the store holds.
/// `DataArchive.exportedModels` says what a backup carries, and
/// `SyncRecordMapper.syncedEntities` derives from it, so a model in the first
/// list and neither of the others is in the store, in no backup, and not in the
/// oplog. That is what `LocalVisionBlock` was when a build without it dropped
/// the table on 2026-08-07, which is why the loss was unrecoverable.
///
/// Nothing related the lists, so nothing could fail. These tests are that
/// relation.
///
/// Still NOT asserted here, and worth knowing: that a model in `exportedModels`
/// has a `map(...)` line in `SyncRecordMapper` and cases in `SyncApplier`.
/// Proving those needs a payload carrying one of every DTO, and the DTOs have
/// required fields, so the fixture would cost more than it catches. A model
/// missing there is at least loud — `SyncApplier` logs "skipping unknown
/// entity" — where a model missing from `exportedModels` is silent.
final class SchemaCoverageTests: XCTestCase {

    // MARK: - The rule holds today

    func testEverySchemaModelIsExportedOrDeclaredExcluded() {
        let gap = StoreSchemaGuard.archiveCoverageGap
        XCTAssertTrue(
            gap.isEmpty,
            """
            \(gap.joined(separator: ", ")) is in SwiftDataStore.schemaModels but neither \
            exported nor declared excluded, so it is in NO backup and does NOT sync.

            Fix by wiring it through the archive: a DTO and an exportedModels entry in \
            DataArchive, a fetch in DataExportService, a mapping in DataImportService, a \
            map(...) line in SyncRecordMapper, and upsert/delete cases in SyncApplier.

            If it genuinely should not be backed up (per-device bookkeeping, a refetchable \
            cache), add the name to DataArchive.excludedModels and say why there.
            """
        )
    }

    func testNoArchiveDeclarationNamesAModelTheSchemaDoesNotHave() {
        let stale = StoreSchemaGuard.archiveStaleDeclarations
        XCTAssertTrue(
            stale.isEmpty,
            "\(stale.joined(separator: ", ")) is declared in DataArchive but is not in "
            + "schemaModels. A renamed or removed model left its old name behind."
        )
    }

    func testAModelIsNotBothExportedAndExcluded() {
        let both = Set(DataArchive.exportedModels).intersection(DataArchive.excludedModels)
        XCTAssertTrue(both.isEmpty, "declared twice, with opposite meanings: \(both.sorted())")
    }

    /// The manifest claims a count for every model it says it carries, and
    /// `DataImportService.verifyManifestClaims` rejects an archive where a
    /// claimed model has no count. So a model added to `exportedModels` and
    /// missed in the counts map makes every archive written afterwards fail to
    /// import — surfacing as "your backup is corrupt" long after the change.
    @MainActor
    func testEveryExportedModelHasAManifestCount() {
        let counted = Set(DataImportService.actualCounts(for: .empty).keys)
        let exported = Set(DataArchive.exportedModels)
        XCTAssertEqual(
            exported.subtracting(counted), [],
            "exported but not counted in DataImportService.actualCounts — every archive "
            + "written by this build would be rejected on import"
        )
        XCTAssertEqual(
            counted.subtracting(exported), [],
            "counted but not in exportedModels"
        )
    }

    // MARK: - The rule actually catches things

    /// The assertion above passes whether the rule is right or vacuous. This is
    /// the one that proves it bites: a model added to the schema and nowhere
    /// else is reported, by name.
    func testTheRuleReportsAModelDeclaredNowhere() {
        let gap = StoreSchemaGuard.coverageGap(
            schemaEntities: StoreSchemaGuard.schemaEntityNames.union(["LocalBrandNewThing"]),
            exported: DataArchive.exportedModels,
            excluded: DataArchive.excludedModels
        )
        XCTAssertEqual(gap, ["LocalBrandNewThing"])
    }

    func testDeclaringAModelExcludedClosesTheGap() {
        let schema = StoreSchemaGuard.schemaEntityNames.union(["LocalBrandNewThing"])
        XCTAssertEqual(
            StoreSchemaGuard.coverageGap(
                schemaEntities: schema,
                exported: DataArchive.exportedModels,
                excluded: DataArchive.excludedModels + ["LocalBrandNewThing"]
            ),
            []
        )
        XCTAssertEqual(
            StoreSchemaGuard.coverageGap(
                schemaEntities: schema,
                exported: DataArchive.exportedModels + ["LocalBrandNewThing"],
                excluded: DataArchive.excludedModels
            ),
            []
        )
    }

    /// The four sync sidecars are the reason the assertion could not be written
    /// before: correctly not exported, but not declared either, so there was
    /// nothing to assert against.
    func testTheSyncSidecarsAreDeclaredExcluded() {
        for name in ["SyncDeviceState", "SyncPeerCursor", "SyncShadow", "SyncTombstone"] {
            XCTAssertTrue(
                DataArchive.excludedModels.contains(name),
                "\(name) must be declared excluded, not merely absent"
            )
        }
    }

    // MARK: - Destructive schema mismatch

    func testAnEntityInTheStoreThatTheBuildLacksIsReportedAsADrop() {
        let dropped = StoreSchemaGuard.droppedEntities(
            stored: ["LocalTodo", "LocalNote", "LocalVisionBlock"],
            known: ["LocalTodo", "LocalNote"],
            retired: []
        )
        XCTAssertEqual(dropped, ["LocalVisionBlock"])
    }

    func testAModelTheBuildAddsIsNotADrop() {
        // The safe direction: opening a store with a model it has never seen
        // CREATES the table. Only the reverse destroys.
        XCTAssertEqual(
            StoreSchemaGuard.droppedEntities(
                stored: ["LocalTodo"], known: ["LocalTodo", "LocalNote"], retired: []
            ),
            []
        )
    }

    func testADeliberatelyRetiredEntityIsNotADrop() {
        // Without this escape hatch, retiring a model on purpose would leave
        // every existing store permanently unopenable.
        XCTAssertEqual(
            StoreSchemaGuard.droppedEntities(
                stored: ["LocalTodo", "LocalOldThing"],
                known: ["LocalTodo"],
                retired: ["LocalOldThing"]
            ),
            []
        )
    }

    func testThisBuildCanOpenAStoreItWroteItself() {
        // The metadata read is the whole mechanism behind the launch refusal, so
        // it is worth proving it works against a real file rather than trusting
        // it. Writes a throwaway store with the app's own schema, then asks what
        // entities it holds.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-guard-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent()
                        .appendingPathComponent(url.lastPathComponent + suffix)
                )
            }
        }
        let schema = Schema(SwiftDataStore.schemaModels)
        XCTAssertNoThrow(
            try ModelContainer(
                for: schema, configurations: [ModelConfiguration(schema: schema, url: url)]
            )
        )

        guard case let .entities(stored) = StoreSchemaGuard.storedEntityNames(at: url) else {
            return XCTFail("could not read the metadata of a store this build just wrote")
        }
        XCTAssertEqual(stored, StoreSchemaGuard.schemaEntityNames)
        XCTAssertEqual(StoreSchemaGuard.entitiesThatWouldBeDropped(at: url), [])
    }

    func testNoStoreMeansNothingCanBeDropped() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).sqlite")
        guard case .noStore = StoreSchemaGuard.storedEntityNames(at: missing) else {
            return XCTFail("a first launch must not read as a mismatch")
        }
        XCTAssertEqual(StoreSchemaGuard.entitiesThatWouldBeDropped(at: missing), [])
    }
}
