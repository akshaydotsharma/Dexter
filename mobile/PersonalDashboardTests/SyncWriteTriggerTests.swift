import XCTest
import SwiftData
@testable import PersonalDashboard

/// The write-triggered durability pass (#449).
///
/// A change lives in exactly one SQLite file until a sync pass copies it into
/// the shared folder. Waiting up to 33s for the timer — or, on the phone, until
/// the app is next foregrounded or backgrounded — is what made the 2026-08-07
/// loss total. `SyncCoordinator.startObservingWrites` closes that by debouncing
/// a FULL pass off `ModelContext.didSave`.
///
/// Two assumptions carry that path, and both are asserted here rather than
/// trusted: that a save announces itself at all, and that a pass's own sidecar
/// writes are recognisable, so publishing a change cannot schedule an endless
/// chain of passes.
@MainActor
final class SyncWriteTriggerTests: XCTestCase {

    /// `didSave` fires for an ordinary write and names the entity it touched.
    ///
    /// This is why the trigger listens to `didSave` rather than
    /// `localStoreDidChange`, which #449 proposed: that notification is posted
    /// by hand at about nine call sites and NOT by the service layer, so adding
    /// a task in the UI posts nothing at all. `didSave` cannot be forgotten at a
    /// new call site.
    func testASaveAnnouncesTheEntityItTouched() throws {
        let container = SwiftDataStore.makeInMemory()
        let context = ModelContext(container)

        var seen: Set<String> = []
        let received = expectation(description: "didSave")
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { note in
            let names = SyncCoordinator.entityNames(in: note)
            guard !names.isEmpty else { return }
            seen.formUnion(names)
            received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        context.insert(LocalTodo(title: "durability"))
        try context.save()

        wait(for: [received], timeout: 5)
        XCTAssertTrue(
            seen.contains("LocalTodo"),
            "a save must name the entities it touched, or the trigger cannot tell a "
            + "user write from sync's own bookkeeping. Saw: \(seen.sorted())"
        )
    }

    func testAPassOwnBookkeepingDoesNotCountAsAWrite() {
        XCTAssertTrue(SyncCoordinator.isSyncBookkeepingOnly(["SyncShadow"]))
        XCTAssertTrue(SyncCoordinator.isSyncBookkeepingOnly(["SyncShadow", "SyncPeerCursor"]))
        XCTAssertTrue(
            SyncCoordinator.isSyncBookkeepingOnly(
                ["SyncDeviceState", "SyncShadow", "SyncTombstone", "SyncPeerCursor"]
            )
        )
    }

    func testARealChangeAlwaysCountsAsAWrite() {
        XCTAssertFalse(SyncCoordinator.isSyncBookkeepingOnly(["LocalTodo"]))
        // A pass that applies a peer's change writes both. It is a real change:
        // this device now holds data no backup of it carries yet.
        XCTAssertFalse(SyncCoordinator.isSyncBookkeepingOnly(["SyncShadow", "LocalTodo"]))
        // An unrecognised notification shape must fail towards durability: an
        // extra pass costs a few seconds, a missed one costs the data.
        XCTAssertFalse(SyncCoordinator.isSyncBookkeepingOnly([]))
    }
}
