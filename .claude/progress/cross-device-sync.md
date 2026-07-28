# Cross-device sync (iOS <-> macOS)

**Status**: PHASE 2 SHIPPED and working on both real devices (2026-07-28), including the #363 manual refresh affordance. Applying enabled on the Mac only. Phase 3 not started.
**Started**: 2026-07-27
**Last Updated**: 2026-07-28
**Estimated Remaining**: phase 3 (attachments, compaction, bootstrap) is the next unit of work

## Objective

Give Dexter Notes/Reminders-style sync between the iPhone and the Mac: edit on either device, changes propagate, an offline device catches up correctly. No CloudKit, because free personal-team signing does not allow it.

## Completed Steps

- [x] Audited the data layer and existing backup stack (2026-07-27)
- [x] Ruled out snapshot-as-truth and settled on an append-only oplog (2026-07-27)
- [x] Agreed the free hand-rolled path over paying for CloudKit (2026-07-27)
- [x] Raised epic #347 and phase 0+1 issue #348, linked as sub-issue (2026-07-27)
- [x] Design doc written to `docs/design/202607 - Cross-Device Sync - Concept.md` (2026-07-27)
- [x] Raised #349 (verify wipe-and-restore) as a blocking prerequisite for phase 2 (2026-07-27)
- [x] Implemented phases 0+1: sidecar models, oplog wire format, folder layer, diff-based change detection, dry-run inbound, triggers, detailed status UI (2026-07-27)
- [x] Fixed #336 (override-store modal blocks automation) because it made phase 0+1 unverifiable (2026-07-27)
- [x] Verified with a two-store rig on the Mac; results on #348 and in PR #350 (2026-07-27)
- [x] PR #350 opened (2026-07-27)

## Completed since (all merged to main)

- [x] #350 phases 0+1 merged; shipped to Mac and iPhone (build 916)
- [x] #352 macOS Sync was a clipped empty modal; now an anchored popover on `Form` (#351)
- [x] #355 iCloud forked the shared `devices/` directory, so neither device ever saw the other (#353). Layout is now flat: `DexterSync-<deviceUUID>/` at the top level, so no device creates a path another device creates. Plus republish-if-log-missing, without which the layout change deadlocks sync silently
- [x] #357 peer cursors were never pruned, so retired devices lingered forever (#356). Plus `DEXTER_SYNC_FOLDER` so test tooling stops writing to the app's real UserDefaults
- [x] #358 per-device backup filenames (#354), so two devices stop overwriting one `Dexter-Backup.zip`
- [x] #349 wipe-and-restore round trip VERIFIED and closed. Recovery procedure is delete-the-store-then-import, `-wal` included

**Phase 1 is working end-to-end on the real Mac and iPhone.** Each publishes its log, discovers the other, decodes its ops, and applies nothing.

## Phase 2 (done, merged, shipped)

- [x] #360 apply with record-level LWW (#359). Reused `DataImportService` via a new `Mode`; restore keeps `.skipExisting` unchanged. Replace is delete-then-insert so a forgotten field is structurally impossible
- [x] #358 per-device backup filenames (#354)
- [x] #349 restore round trip verified, then RE-verified after the importer change
- [x] #362 a disposable store can no longer publish to the real sync folder (#361)
- [x] #364 post `localStoreDidChange` after applying, so manual-fetch views re-read (#363)
- [x] #365 manual refresh affordance, closing #363: `syncRefreshable` runs a real pass before reloading on iOS; macOS gets a toolbar button plus Refresh Cmd-R in a new Sync menu. Also made `pass()` coalesce instead of dropping, and gave Today the `localStoreDidChange` observer it was missing

Confirmed working by Akshay on the real Mac and iPhone: a change on the phone applies on the Mac, and a delete removes it.

**Current config: applying is ON for the Mac only** (`sync.applyEnabled`), so changes flow one direction and the untested concurrent-edit path cannot trigger.

## Current Step

- [ ] Live with phase 2 one-directional for a while, then consider enabling apply on the phone too
  - The moment both sides apply, simultaneous edits of ONE record become reachable. That path is deterministic by construction (Lamport + device-id tiebreak, total order) but has never been driven on real hardware.
- [ ] Hands-on pass on #365's two macOS controls (the toolbar button and Cmd-R). Neither could be driven autonomously: with Akshay's own DexterMac running, System Events resolves `application process "DexterMac"` to the wrong instance, and the test window opened on another Space. Rendering and the menu's existence WERE verified.

Decided and closed (2026-07-28): **no hand-rolled pull-to-refresh on macOS.** Akshay asked why the Mac got a button instead of the gesture he originally described. macOS has no system pull-to-refresh (`.refreshable` was already on those views for both platforms and gave the Mac nothing), so it would mean bridging into `NSScrollView` to track elastic overscroll, twice over for `List` and `ScrollView` surfaces. Three reasons not to: overscroll needs something to scroll, so it dies in exactly the empty-state case where you most want to check for incoming data; an invisible gesture cannot show that a pass is running, where the button becomes a spinner; and no Mac app does it, so it is not a gesture anyone tries. Cmd-R is the real Mac equivalent of the ask. He accepted this. Revisit only if he raises it again.

## Next Steps

- [ ] Phase 3: attachments as content-addressed blobs, log compaction, new-device bootstrap
  - Attachments are the visible gap now: a synced expense can reference a receipt the other device does not have.
  - Receipts live in `~/Documents/receipts/` keyed only by UUID, shared by every store, so they are NOT store-scoped. `DEXTER_STORE_PATH` isolates the database and nothing else.
  - Compaction interacts with the #353 republish check, which currently reads "no segments" as "never published". It will need a floor marker.
- [ ] Phase 4 (conditional): field-level LWW, only if phase 2 clobbering proves annoying

## Blockers

None.

## Key Decisions Made

1. **Free path, not CloudKit** (user decision, 2026-07-27). $99/yr Apple Developer Program was offered and declined. Consequence: we own the sync engine, and iOS gets no reliable background sync.
2. **Oplog, not snapshots.** A snapshot cannot express a delete except as "absent means deleted", which is unsafe the moment a device is stale.
3. **Per-device subdirectories, immutable sealed segments.** iCloud Drive creates conflict copies when two devices write one file. Per-device dirs make file-level conflicts structurally impossible.
4. **Zero changes to the existing 15 `@Model` classes.** All sync state (tombstones, Lamport clock, shadow hashes) goes in new additive sidecar models. Migrating 15 live models is the one thing that can lose all the user's data.
5. **Change capture by diffing a shadow hash table, not by instrumenting mutation sites.** Writes arrive from services, AI tool-use, email ingest, statement import and the importer. A missed site would silently never sync while looking healthy.
6. **Lamport clocks, not wall clock**, so ordering survives phone/Mac clock skew.
7. **Record-level LWW first, field-level deferred to phase 4.** Field-level is where the complexity and row count live, and concurrent co-edit of one record is rare for one person with two devices.
8. **Hard invariant: absence never means delete.** Only an explicit tombstone op removes a local record.
9. **Phases 0 and 1 land together in one PR** (user decision), and the sync status UI is deliberately detailed (user decision) because a silently stale bookmark is a known failure mode of this transport.

## Files Modified

See commit 9ee5180 on `feat/cross-device-sync-phase-0-1`. Shape of it:

- `mobile/PersonalDashboard/Sync/` (new): SyncOp (wire format + log sink), SyncFolder (transport), SyncRecordMapper, SyncEngine (the pass), SyncCoordinator (triggers)
- `mobile/PersonalDashboard/Models/Local/SyncModels.swift` (new): the four sidecar @Models
- `mobile/PersonalDashboard/Views/Settings/SyncStatusView.swift` (new): detailed status
- `SwiftDataStore.swift`: schema list de-duplicated into one `schemaModels`, four sidecars registered, #336 modal opt-out
- `DataExportService.swift`: `buildPayload` made internal so sync reuses it
- Both app entry points: launch/foreground/timer triggers
- `project.yml`: new files added to the curated DexterMac sources

## Context for Next Session

**Findings from the audit that shape the implementation:**

- `BackupService` already holds a security-scoped bookmark to a user-picked iCloud Drive folder and writes through `NSFileCoordinator`. Sync reuses this rather than adding a second picker.
- The whole backup/export/import stack is already in the curated `DexterMac` sources list, so both platforms have a starting point.
- The schema has **zero `@Relationship`** edges. Everything is flat with UUID foreign keys. This removes a whole class of graph-sync problems.
- All 15 models carry `@Attribute(.unique) var clientUUID`. Useful for sync identity, and it stays (only CloudKit would have forced its removal).
- Sync-relevant fields are inconsistent today: only `LocalTodo`, `LocalNote`, `LocalList`, `LocalNoteFolder` have `deletedAt`. Several models have no `updatedAt` at all. Decision 4 above means we do **not** fix this by editing the models; the oplog and tombstone sidecar carry it instead.
- `DataImportService` is **additive-only** (`where !existing.contains(dto.clientUUID)`). Correct for restore, wrong for sync. It needs an upsert path in phase 2 or 3. This is the one existing component the work genuinely changes.
- `DataExportService` produces a self-verifying zip (manifest schema v1, per-model counts, `receipts/` and `tickets/` attachments). Reuse it as the phase 3 snapshot format for new-device bootstrap instead of inventing one.

**Field bugs that a single-device rig and code review both missed:**

- **A write from outside the UI is invisible to Tasks / Notes / Lists** until the view is recreated. They cache rows in a view model loaded by `.task`, unlike Activity / Finance / Itineraries which use live `@Query`. `localStoreDidChange` exists for exactly this and those views already observe it; sync just failed to post it (#363). Anything that mutates the store outside the UI must post it.
- **A disposable store is not disposable everywhere** (#361). `DEXTER_STORE_PATH` isolates the database only, so a scratch-store launch published into the real iCloud folder, twice. With phase 2 applying on, a test delete would have propagated to the live device. Now refused outright.

- **iCloud forks DIRECTORIES, not just files** (#353). Per-device leaf directories were not enough, because both devices independently created the shared ancestors via `createIntermediateDirectories`. Presented as "healthy folder, full op count, no peer" on both devices at once.
- **Deleting a published log deadlocks sync silently.** The shadow table records what has been published, so if the log vanishes the shadow is a lie: nothing is pending, nothing is emitted, and the peer can never bootstrap. No symptom at all. Fixed by treating the folder as authoritative for what has been published.
- **Attachments are NOT store-scoped.** Receipts live in `~/Documents/receipts/` keyed only by UUID, shared by every store. `DEXTER_STORE_PATH` isolates the database and nothing else, so "disposable store" testing still writes real attachment files.
- **Test tooling must never use the app's UserDefaults domain.** Configuring sync via `defaults write` on the bundle id had a live app adopt the scratch folder and record scratch devices as permanent peers in a real store. Use `DEXTER_SYNC_FOLDER`.

**Traps found the hard way (all cost a debugging round each):**

- **Never name a stored property `entity` on a @Model.** Collides with `NSManagedObject.entity`; compiles and builds, then aborts at runtime with a message naming neither the property nor the model. Renaming to `entityName` fixed the save but the READ still aborted with "Could not cast Swift.Optional<Any> to Swift.String" despite valid data in every row. Both models now store only `key` ("Entity|recordID") and compute the parts.
- **The #336 modal starves the whole main actor.** `NSAlert.runModal()` is a nested run loop; under automation it never returns, so async main-actor work stops at its first suspension point. Presented as a phantom SwiftData save failure.
- **A crashed macOS app blocks every later scripted launch.** macOS shows its own "reopen windows?" `runModal` via `NSPersistentUIRestorer` BEFORE `finishLaunching`, so no window and no `.task`. Looks identical to hanging at startup. Fix: `-ApplePersistenceIgnoreState YES` plus removing `~/Library/Saved Application State/<bundleid>.savedState`.
- **`pgrep -x DexterMac` matched the user's Xcode-launched instance** (state `SX`, traced, immune to kill) and made a dead test process look alive. Check the PID and start time, not just the name.
- **NSLog is invisible** once the app connects to the window server, and `log show` may drop it too. Hence `SyncLog.line`, which writes to stderr as well.

**Design traps to remember:**

- iCloud files may not be materialised locally. Request download and check downloading status before concluding a file is missing.
- Treat any mutable pointer file (a HEAD or manifest) as a hint. The segments present on disk are the truth, because a pointer file can fork.
- When applying a remote op, update the shadow hash in the same transaction, or the next diff pass re-emits it as a local change and the two devices ping-pong forever.
- macOS sandbox is currently off (dev-only). Bookmark behaviour changes once enabled; revisit before distribution.
- One user-global SwiftData store shared across worktrees and agents. Serialise app launches during two-device testing.
