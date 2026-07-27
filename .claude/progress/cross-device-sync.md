# Cross-device sync (iOS <-> macOS)

**Status**: in-progress (phases 0+1 implemented, PR #350 open, awaiting review + dry-run soak)
**Started**: 2026-07-27
**Last Updated**: 2026-07-27
**Estimated Remaining**: phases 0+1 are the next unit of work; phases 2-4 follow

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

## Current Step

- [ ] PR #350 review, then a multi-day dry-run soak on real data
  - Branch: `feat/cross-device-sync-phase-0-1`. Both targets build clean.
  - The soak is the actual deliverable of phase 1: watch Settings -> Sync on both devices for a few days and confirm pending counts match what was actually changed. That is the evidence phase 2 is allowed to start.
  - Still unverified: real two-device sync, and edit/delete driven through the UI rather than sqlite3. Neither can damage data while nothing is applied.

## Next Steps

- [ ] Phase 2: inbound apply, tombstones, record-level LWW, behind a Settings toggle
- [ ] Phase 3: attachments as content-addressed blobs, log compaction, new-device bootstrap
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

**Traps found the hard way this session (all cost a debugging round each):**

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
