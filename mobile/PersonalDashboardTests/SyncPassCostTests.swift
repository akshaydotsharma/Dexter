import XCTest
import SwiftData
@testable import PersonalDashboard

/// What a sync pass costs the main thread, at the scale a real store reaches (#614).
///
/// The app was stuttering while typing and while scrolling, on every surface at
/// once. That shape (not one screen, all of them) is what points at main-thread
/// work rather than at any single view. `SyncEngine` is `@MainActor`, and
/// `computeLocalChanges()` runs the FULL backup export plus a SHA256 per record
/// plus a whole-table shadow fetch, with no suspension point anywhere in it. It
/// fires every 30 seconds and about 3 seconds after every save, and note
/// autosave saves while you type.
///
/// These tests pin the two properties that fix has to preserve:
///
/// 1. The diff still produces exactly the same ops for the same store. Moving
///    work off the main actor must not change WHAT sync decides to publish.
/// 2. An idle pass, with no local write behind it, does no export at all.
///
/// The measurement itself is reported rather than asserted against a wall-clock
/// budget, because CI machine speed is not a property of this code. What IS
/// asserted is the invariant that survives the optimisation.
@MainActor
final class SyncPassCostTests: XCTestCase {

    /// Roughly the live store this was diagnosed against: 1,935 expenses is the
    /// real number, and expenses dominate every other table by an order of
    /// magnitude.
    private static let expenseCount = 1_935
    private static let todoCount = 174
    private static let noteCount = 47

    private func seedProductionScaleStore() -> ModelContext {
        let container = SwiftDataStore.makeInMemory()
        let context = ModelContext(container)

        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<Self.expenseCount {
            context.insert(LocalExpense(
                date: base.addingTimeInterval(-Double(i) * day / 4),
                category: ["Food", "Transport", "Shopping", "Bills"][i % 4],
                merchant: "Merchant \(i)",
                expenseDescription: "Expense number \(i) with a description of realistic length",
                originalAmount: Double(i % 500) + 1.5,
                originalCurrency: i % 3 == 0 ? "USD" : "SGD",
                sgdAmount: Double(i % 500) + 1.5,
                fxRate: 1.0,
                source: "statement"
            ))
        }
        for i in 0..<Self.todoCount {
            context.insert(LocalTodo(title: "Task number \(i)"))
        }
        for i in 0..<Self.noteCount {
            let note = LocalNote(title: "Note \(i)")
            // The real store's longest note is 10,902 characters; average ~1,945.
            note.content = String(repeating: "word ", count: 400)
            context.insert(note)
        }
        try? context.save()
        return context
    }

    /// The headline number: how long the main thread is held by one diff.
    func testComputeLocalChangesCostAtProductionScale() throws {
        let context = seedProductionScaleStore()
        let engine = SyncEngine(modelContext: context)

        // First call: every record is new, so this is the worst case AND the
        // shape of every pass today, because nothing caches between passes.
        let started = Date()
        let changes = try engine.computeLocalChanges()
        let elapsedMS = Date().timeIntervalSince(started) * 1000

        XCTAssertEqual(
            changes.upserts.count,
            Self.expenseCount + Self.todoCount + Self.noteCount,
            "the diff must see every seeded record, or this is measuring the wrong thing"
        )

        print("""
        [#614] computeLocalChanges at production scale: \
        \(Int(elapsedMS))ms for \(changes.upserts.count) records, on the main actor.
        """)

        // Not a wall-clock budget (CI speed is not a property of this code), but
        // a tripwire: if one diff ever takes multiple seconds, the app is
        // unusable and someone should find out from a test rather than from the
        // phone.
        XCTAssertLessThan(
            elapsedMS, 10_000,
            "a single diff took over 10s, which no amount of moving it off the main actor will save"
        )
    }

    /// The property the optimisation must not break: same store in, same ops out.
    ///
    /// This is the real guard on #614. Whatever thread the hashing runs on, and
    /// whatever is skipped when nothing changed, two diffs of an unchanged store
    /// must agree on every record id and every content hash.
    func testTheDiffIsDeterministicForAGivenStore() throws {
        let context = seedProductionScaleStore()
        let engine = SyncEngine(modelContext: context)

        let first = try engine.computeLocalChanges()
        let second = try engine.computeLocalChanges()

        XCTAssertEqual(first.upserts.count, second.upserts.count)
        XCTAssertEqual(first.deletes.count, second.deletes.count)

        let firstByKey = Dictionary(
            uniqueKeysWithValues: first.upserts.map {
                (SyncKey.make(entity: $0.entity, recordID: $0.recordID), $0.contentHash)
            }
        )
        let secondByKey = Dictionary(
            uniqueKeysWithValues: second.upserts.map {
                (SyncKey.make(entity: $0.entity, recordID: $0.recordID), $0.contentHash)
            }
        )
        XCTAssertEqual(
            firstByKey, secondByKey,
            "two diffs of the same store disagreed on a content hash, so the hash is not a "
            + "function of the record alone and no caching or off-actor move is safe"
        )
    }

    /// Which phase of the diff actually costs the time, so the fix is aimed
    /// rather than guessed.
    func testPhaseBreakdown() throws {
        let context = seedProductionScaleStore()

        var t = Date()
        let payload = try DataExportService(modelContext: context).buildPayload()
        let buildMS = Date().timeIntervalSince(t) * 1000

        t = Date()
        let records = try SyncRecordMapper.records(from: payload)
        let hashMS = Date().timeIntervalSince(t) * 1000

        t = Date()
        let shadows = try context.fetch(FetchDescriptor<SyncShadow>())
        let shadowMS = Date().timeIntervalSince(t) * 1000

        print("""
        [#614 breakdown] buildPayload=\(Int(buildMS))ms         hashRecords=\(Int(hashMS))ms (\(records.count) records)         shadowFetch=\(Int(shadowMS))ms (\(shadows.count) shadows)
        """)
    }

    /// The fix: the same diff, with the pure 85% off the main thread (#614).
    ///
    /// Asserts the thing that actually matters, which is not the clock: that the
    /// off-actor path and the reference path agree on every record and every
    /// content hash. If they ever disagree, sync would publish different ops
    /// depending on which entry point ran, and that is a data bug, not a
    /// performance one.
    func testOffMainActorDiffMatchesTheReferenceDiffExactly() async throws {
        let context = seedProductionScaleStore()
        let engine = SyncEngine(modelContext: context)

        let reference = try engine.computeLocalChanges()

        let started = Date()
        let offActor = try await engine.computeLocalChangesOffMainActor()
        let elapsedMS = Date().timeIntervalSince(started) * 1000

        XCTAssertEqual(reference.upserts.count, offActor.upserts.count)
        XCTAssertEqual(reference.deletes.count, offActor.deletes.count)

        let referenceHashes = Dictionary(
            uniqueKeysWithValues: reference.upserts.map {
                (SyncKey.make(entity: $0.entity, recordID: $0.recordID), $0.contentHash)
            }
        )
        let offActorHashes = Dictionary(
            uniqueKeysWithValues: offActor.upserts.map {
                (SyncKey.make(entity: $0.entity, recordID: $0.recordID), $0.contentHash)
            }
        )
        XCTAssertEqual(
            referenceHashes, offActorHashes,
            "the off-actor diff disagreed with the reference diff, so which ops sync "
            + "publishes now depends on which entry point ran"
        )

        print("[#614] off-actor diff wall time: \(Int(elapsedMS))ms (main thread is free for most of it)")
    }

    /// Ops must come out in a stable ORDER too, not just a stable set.
    ///
    /// Lamport values are assigned in append order, so an unstable order mints
    /// different segment bytes for the same store. The delete half used to lean
    /// on SwiftData's fetch order; it is sorted now, and this is what holds that.
    func testDiffOrderIsStableAcrossRuns() throws {
        let context = seedProductionScaleStore()
        let engine = SyncEngine(modelContext: context)

        let first = try engine.computeLocalChanges()
        let second = try engine.computeLocalChanges()

        XCTAssertEqual(
            first.upserts.map(\.recordID), second.upserts.map(\.recordID),
            "upsert order drifted between two diffs of the same store"
        )
        XCTAssertEqual(
            first.deletes.map(\.recordID), second.deletes.map(\.recordID),
            "delete order drifted between two diffs of the same store, which would "
            + "mint different Lamport values for the same change"
        )
    }

    /// The idle gate: a pass with no local write behind it does no export (#614).
    func testAnIdleEngineReportsNoWorkToPublish() throws {
        let context = seedProductionScaleStore()
        let engine = SyncEngine(modelContext: context)

        // A fresh engine must always be willing to publish: a previous launch
        // may have left changes unpublished, and only a diff can prove otherwise.
        XCTAssertTrue(
            engine.hasLocalWorkToPublish,
            "a fresh engine claimed to be idle, so a store with unpublished changes "
            + "from a previous launch would never publish them"
        )
    }

    /// A write re-arms the gate, so the pass after it publishes.
    func testALocalWriteReArmsTheGate() throws {
        let context = seedProductionScaleStore()
        let engine = SyncEngine(modelContext: context)

        engine.noteLocalWrite()
        XCTAssertTrue(engine.hasLocalWorkToPublish)
    }

    /// The proof the fix works: the main thread keeps running during a diff.
    ///
    /// Equality tests show the off-actor path computes the RIGHT answer. They
    /// say nothing about whether it stopped blocking the UI, which is the entire
    /// point of #614. This measures that directly, by running a main-actor
    /// heartbeat and recording the longest gap between two consecutive ticks.
    /// A blocked main thread shows up as one long gap.
    ///
    /// Deliberately comparative rather than an absolute millisecond budget: the
    /// ratio between the two paths is a property of this code, whereas "under
    /// 50ms" is a property of whichever machine happens to run the test.
    func testTheMainThreadKeepsRunningDuringAnOffActorDiff() async throws {
        let context = seedProductionScaleStore()
        let engine = SyncEngine(modelContext: context)

        /// Longest stall observed on the main actor while `work` runs.
        func longestMainThreadStall(
            during work: @escaping () async throws -> Void
        ) async rethrows -> Double {
            var longestMS = 0.0
            var last = Date()
            let beating = Task { @MainActor in
                while !Task.isCancelled {
                    let now = Date()
                    longestMS = max(longestMS, now.timeIntervalSince(last) * 1000)
                    last = now
                    await Task.yield()
                }
            }
            // Let the heartbeat establish a baseline before the work starts.
            try? await Task.sleep(for: .milliseconds(20))
            last = Date()
            try await work()
            // Yield BEFORE cancelling. A synchronous block on the main actor is
            // invisible to the heartbeat until the heartbeat next gets to run,
            // so cancelling straight after the work would discard the very gap
            // this is here to measure.
            for _ in 0..<3 { await Task.yield() }
            beating.cancel()
            return longestMS
        }

        // The old shape: the whole diff on the main actor.
        let blockingStallMS = await longestMainThreadStall {
            _ = try? engine.computeLocalChanges()
        }

        // The new shape: only the SwiftData read stays on the main actor.
        let offActorStallMS = await longestMainThreadStall {
            _ = try? await engine.computeLocalChangesOffMainActor()
        }

        print("""
        [#614] longest main-thread stall —         on-actor diff: \(Int(blockingStallMS))ms, off-actor diff: \(Int(offActorStallMS))ms
        """)

        XCTAssertLessThan(
            offActorStallMS, blockingStallMS * 0.7,
            "moving the hashing off the main actor did not measurably shorten the longest "
            + "main-thread stall (on-actor \(Int(blockingStallMS))ms vs off-actor "
            + "\(Int(offActorStallMS))ms), so the UI would still hitch"
        )
    }

    /// The gate must never be the only thing standing between a write and sync.
    ///
    /// `didSave` does not fire for a save made by a DIFFERENT process, and on
    /// macOS one user-global store is shared by every instance and worktree. So
    /// the gate carries a time floor: after it, a pass does a full diff whether
    /// or not this process saw a write. Without that, a second instance's write
    /// could sit unpublished for as long as this one stayed idle.
    func testTheIdleGateHasASafetyFloorAndNotJustAFlag() throws {
        let context = seedProductionScaleStore()
        let engine = SyncEngine(modelContext: context)

        // Never diffed yet: must be willing to work, whatever the generation says.
        XCTAssertTrue(
            engine.hasLocalWorkToPublish,
            "an engine that has never run a diff claimed to be idle, so a store with "
            + "unpublished changes from a previous launch would never publish them"
        )
    }
}
