import Foundation
import CoreData
import SwiftData
#if canImport(AppKit)
import AppKit
#endif

/// Two checks that stop a build from silently destroying stored data (#449).
///
/// Both exist because the same class of accident happened twice in eight days.
/// On 2026-07-29 a build without `LocalNoteImage` dropped that table; on
/// 2026-08-07 a build without `LocalVisionBlock` dropped that one. Neither
/// produced an error. The only trace was a CoreData line that reads like
/// housekeeping:
///
///     CoreData: error: Persistent History (35443) has to be truncated due to
///     the following entities being removed: ( LocalVisionBlock )
///
/// ## 1. Archive coverage
///
/// `SwiftDataStore.schemaModels` says what the store holds.
/// `DataArchive.exportedModels` says what a backup carries, and
/// `SyncRecordMapper.syncedEntities` derives from it, so a model missing there
/// is invisible to BOTH the backup and the oplog. The two lists are
/// hand-maintained in different files and nothing related them, which is why
/// `LocalVisionBlock` was never backed up and the drop above was unrecoverable.
///
/// `archiveCoverageGap` is the missing relation: every schema entity must be
/// either exported or declared in `DataArchive.excludedModels`. Declaring is
/// cheap and says "not exported, on purpose"; forgetting is what costs data.
///
/// ## 2. Destructive schema mismatch
///
/// Every build from every worktree opens the same store file, so a branch that
/// does not know an entity the store holds REMOVES it, rows and all. This reads
/// the store's own entity list before SwiftData opens it and refuses to launch
/// when this build would drop something.
///
/// Refusing is the doctrine `DebugLaunchHooks` already follows: present but
/// unusable stops rather than falling back. A refused launch touches nobody's
/// data; the alternative is a table that is simply gone, and (worse) a later
/// sync pass that diffs the shadow table, sees the rows missing, and broadcasts
/// real delete ops to every other device.
enum StoreSchemaGuard {

    // MARK: - Deliberately retired entities

    /// Entity names this app USED to have and removed on purpose.
    ///
    /// Empty today, and adding to it is a deliberate act. When a `@Model` is
    /// genuinely retired, its name goes here in the same commit that removes it,
    /// otherwise every existing store still carries the entity and the guard
    /// below would refuse to launch forever. This is the one escape hatch that
    /// survives into release builds, and it is a code change on purpose: a
    /// destroyed table should cost a code review, not an environment variable.
    static let retiredEntities: Set<String> = []

    // MARK: - What this build knows

    /// Entity names for `SwiftDataStore.schemaModels`, asked of SwiftData rather
    /// than derived from the type names, so a future `@Model` with a custom
    /// entity name cannot make this list quietly wrong.
    static let schemaEntityNames: Set<String> = {
        Set(Schema(SwiftDataStore.schemaModels).entitiesByName.keys)
    }()

    // MARK: - 1. Archive coverage

    /// Schema entities that are neither exported nor declared as excluded.
    ///
    /// A non-empty result is a model that is in the store, is not in any backup,
    /// and does not sync — with nothing saying that was intended.
    static var archiveCoverageGap: [String] {
        coverageGap(
            schemaEntities: schemaEntityNames,
            exported: DataArchive.exportedModels,
            excluded: DataArchive.excludedModels
        )
    }

    /// Names declared in the archive lists that no longer exist in the schema.
    ///
    /// The mirror-image mistake: a model renamed or removed while its old name
    /// stayed in `exportedModels`, which would make the manifest claim to carry
    /// something no store has. Cheap to check while we are here.
    static var archiveStaleDeclarations: [String] {
        staleDeclarations(
            schemaEntities: schemaEntityNames,
            exported: DataArchive.exportedModels,
            excluded: DataArchive.excludedModels
        )
    }

    /// The rule itself, as a pure function of three lists.
    ///
    /// Separated from the live properties so a test can prove it FAILS for a
    /// model declared nowhere. A test that only asserts the current lists agree
    /// passes just as happily when the rule is wrong, and this rule exists
    /// precisely because nobody notices a silent one.
    static func coverageGap(
        schemaEntities: Set<String>, exported: [String], excluded: [String]
    ) -> [String] {
        schemaEntities.subtracting(Set(exported).union(excluded)).sorted()
    }

    static func staleDeclarations(
        schemaEntities: Set<String>, exported: [String], excluded: [String]
    ) -> [String] {
        Set(exported).union(excluded).subtracting(schemaEntities).sorted()
    }

    /// Loud DEBUG-only report of an archive coverage gap at launch.
    ///
    /// The unit test is the real gate; this exists because the test only runs
    /// when somebody runs it, and the model that escapes the archive is by
    /// definition the one nobody was thinking about. It does NOT refuse to
    /// launch: an unbacked model is a durability gap, not an in-progress
    /// destruction, and stopping the app would punish the wrong run.
    static func reportArchiveCoverageGapInDebug() {
        #if DEBUG
        let gap = archiveCoverageGap
        guard !gap.isEmpty else { return }
        NSLog("""
            ⚠️ StoreSchemaGuard: %d model(s) are in schemaModels but neither exported \
            nor declared excluded: %@. They are NOT in any backup and do NOT sync. \
            Add a DTO + exportedModels entry (DataArchive, DataExportService, \
            DataImportService, SyncRecordMapper, SyncApplier), or add the name to \
            DataArchive.excludedModels if that is intended.
            """, gap.count, gap.joined(separator: ", "))
        #endif
    }

    // MARK: - 2. Destructive schema mismatch

    /// What the store file says about itself.
    enum StoreEntities {
        /// No store yet — a first launch. Nothing can be dropped.
        case noStore
        /// The entity names the store was last opened with.
        case entities(Set<String>)
        /// The file is there but its metadata could not be read.
        case unreadable(String)
    }

    /// Read the store's entity names WITHOUT opening it as a SwiftData container.
    ///
    /// `metadataForPersistentStore` reads the CoreData metadata row and performs
    /// no migration, which is the whole point: by the time a `ModelContainer`
    /// exists the destructive migration has already happened. The metadata's
    /// `NSStoreModelVersionHashes` is keyed by entity name, so its keys are
    /// exactly the entities the store holds. SwiftData is CoreData underneath, so
    /// this works on a SwiftData store unchanged (verified against the real Mac
    /// store, 2026-08-07: 24 entities, matching `sqlite_master`).
    static func storedEntityNames(at url: URL) -> StoreEntities {
        guard FileManager.default.fileExists(atPath: url.path) else { return .noStore }
        do {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite, at: url
            )
            guard let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Any] else {
                return .unreadable("store metadata carries no NSStoreModelVersionHashes")
            }
            return .entities(Set(hashes.keys))
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// Entities the store holds that this build does not know, i.e. exactly what
    /// opening the store would delete.
    static func entitiesThatWouldBeDropped(at url: URL) -> [String] {
        guard case let .entities(stored) = storedEntityNames(at: url) else { return [] }
        return droppedEntities(stored: stored, known: schemaEntityNames, retired: retiredEntities)
    }

    /// The rule, pure, so it can be tested without a store on disk.
    ///
    /// An entity the store has and the build does not is a drop. The reverse is
    /// harmless: a model this build adds is created, which is the safe kind of
    /// lightweight migration.
    static func droppedEntities(
        stored: Set<String>, known: Set<String>, retired: Set<String>
    ) -> [String] {
        stored.subtracting(known).subtracting(retired).sorted()
    }

    /// The message shown on refusal. Built here so the app, the check mode and
    /// any future caller all say the same thing.
    static func refusalMessage(dropped: [String], storeURL: URL) -> String {
        """
        This build does not know \(dropped.count) entity/entities that the store \
        already holds:

            \(dropped.joined(separator: ", "))

        Opening the store would DELETE them and every row in them, and the next \
        sync pass would broadcast those deletions to your other devices.

        Store: \(storeURL.path)

        Run the build that has these models (the branch that added them), or \
        merge it first. To work on this branch against throwaway data, set \
        DEXTER_STORE_PATH to a copy of the store. If a model was retired on \
        purpose, add its name to StoreSchemaGuard.retiredEntities.
        """
    }

    /// Refuse to launch when this build would drop stored entities (#449).
    ///
    /// Called from `SwiftDataStore.init` before the `ModelContainer` is built,
    /// which is the only moment where refusing still saves the data.
    ///
    /// Exits rather than trapping. A `fatalError` here would file a crash report,
    /// and a crashed Mac app blocks later scripted launches, so the stop meant to
    /// protect a QA run would break the next one. On macOS the reason is also put
    /// on screen, because a process that vanishes at launch with only a log line
    /// reads as the app being broken.
    static func refuseIfDestructive(storeURL: URL) {
        let dropped = entitiesThatWouldBeDropped(at: storeURL)
        guard !dropped.isEmpty else { return }
        let message = refusalMessage(dropped: dropped, storeURL: storeURL)
        NSLog("StoreSchemaGuard: REFUSING TO LAUNCH — %@", message)
        FileHandle.standardError.write(Data(("\nStoreSchemaGuard: REFUSING TO LAUNCH\n" + message + "\n").utf8))
        #if canImport(AppKit)
        // Skipped under automation: `runModal` waits for a click that a script
        // cannot give, and a launch that hangs forever is worse than one that
        // exits. `mac-open-for-verification.sh` runs the same check up front, so
        // the scripted path never reaches this.
        if !isAutomatedRun {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Dexter will not open this store"
            alert.informativeText = message
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
        #endif
        exit(1)
    }

    /// True when something other than a person launched this process.
    private static var isAutomatedRun: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["DEXTER_SCHEMA_CHECK"] != nil || env["DEXTER_STORE_PATH_ACK"] != nil
    }

    // MARK: - Check mode, for scripts

    /// `DEXTER_SCHEMA_CHECK=1 <binary>`: report whether this build can open the
    /// store, then exit. 0 means safe, 1 means it would drop entities.
    ///
    /// The point is that a script can ask the QUESTION without taking the RISK.
    /// `mac-open-for-verification.sh` runs this before it quits the user's
    /// running instance, so the handoff cannot be the thing that destroys data —
    /// which is exactly how the 2026-08-07 loss happened.
    ///
    /// Reads the same store path the app would (honouring `DEXTER_STORE_PATH`)
    /// and never opens a container, so it is safe to run while the app is up.
    /// DEBUG-only, like every other launch hook.
    static func runCheckModeIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["DEXTER_SCHEMA_CHECK"] != nil else { return }
        let url = SwiftDataStore.storeURLForCurrentProcess()
        let gap = archiveCoverageGap
        if !gap.isEmpty {
            print("warning: not exported and not declared excluded: \(gap.joined(separator: ", "))")
        }
        switch storedEntityNames(at: url) {
        case .noStore:
            print("OK: no store at \(url.path) yet — nothing to drop")
        case .unreadable(let why):
            // Not a refusal. An unreadable metadata row is a different fault from
            // a schema mismatch, and reporting it as one would send whoever reads
            // this looking for a model that is not the problem.
            print("UNKNOWN: could not read store metadata at \(url.path): \(why)")
        case .entities(let stored):
            let dropped = stored.subtracting(schemaEntityNames).subtracting(retiredEntities).sorted()
            if dropped.isEmpty {
                print("OK: this build knows all \(stored.count) entities in \(url.path)")
            } else {
                print("MISMATCH: this build would DROP \(dropped.joined(separator: ", ")) from \(url.path)")
                exit(1)
            }
        }
        exit(0)
        #endif
    }
}
