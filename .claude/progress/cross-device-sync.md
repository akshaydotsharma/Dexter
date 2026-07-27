# Cross-device sync (iOS <-> macOS)

**Status**: in-progress (design agreed, implementation not started)
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

## Current Step

- [ ] Implement phases 0 and 1 together (#348)
  - Nothing written yet. No branch cut.
  - Scope and acceptance criteria are fully specified on #348, including the detailed sync status UI.

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

- `docs/design/202607 - Cross-Device Sync - Concept.md` (new, design record)
- `.claude/progress/cross-device-sync.md` (new, this file)

No application code touched yet.

## Context for Next Session

**Findings from the audit that shape the implementation:**

- `BackupService` already holds a security-scoped bookmark to a user-picked iCloud Drive folder and writes through `NSFileCoordinator`. Sync reuses this rather than adding a second picker.
- The whole backup/export/import stack is already in the curated `DexterMac` sources list, so both platforms have a starting point.
- The schema has **zero `@Relationship`** edges. Everything is flat with UUID foreign keys. This removes a whole class of graph-sync problems.
- All 15 models carry `@Attribute(.unique) var clientUUID`. Useful for sync identity, and it stays (only CloudKit would have forced its removal).
- Sync-relevant fields are inconsistent today: only `LocalTodo`, `LocalNote`, `LocalList`, `LocalNoteFolder` have `deletedAt`. Several models have no `updatedAt` at all. Decision 4 above means we do **not** fix this by editing the models; the oplog and tombstone sidecar carry it instead.
- `DataImportService` is **additive-only** (`where !existing.contains(dto.clientUUID)`). Correct for restore, wrong for sync. It needs an upsert path in phase 2 or 3. This is the one existing component the work genuinely changes.
- `DataExportService` produces a self-verifying zip (manifest schema v1, per-model counts, `receipts/` and `tickets/` attachments). Reuse it as the phase 3 snapshot format for new-device bootstrap instead of inventing one.

**Traps to remember:**

- iCloud files may not be materialised locally. Request download and check downloading status before concluding a file is missing.
- Treat any mutable pointer file (a HEAD or manifest) as a hint. The segments present on disk are the truth, because a pointer file can fork.
- When applying a remote op, update the shadow hash in the same transaction, or the next diff pass re-emits it as a local change and the two devices ping-pong forever.
- macOS sandbox is currently off (dev-only). Bookmark behaviour changes once enabled; revisit before distribution.
- One user-global SwiftData store shared across worktrees and agents. Serialise app launches during two-device testing.
