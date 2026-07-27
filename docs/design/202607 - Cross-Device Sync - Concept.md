# Cross-device sync design

Epic: #347 | Phase 0+1: #348
Decision date: 2026-07-27

## Problem

Dexter runs on two devices (iPhone and Mac) and each keeps its own local SwiftData store with no connection between them. A task added on the phone never appears on the Mac. CloudKit, iCloud key-value store and iCloud Documents all require the paid Apple Developer Program, and we are staying on free personal-team signing (decision: 2026-07-27). So we hand-roll sync.

Target behaviour is what Notes and Reminders give you: edit on either device, changes propagate, a device that was offline catches up correctly when it comes back.

## Why not "the backup is the data source"

The first idea considered was treating the existing rolling backup zip as shared truth: every change uploads a fresh snapshot, both devices read from it.

This cannot be made safe. A full-state snapshot has no way to express a deletion except "absent means deleted". As soon as one device is stale, that rule either resurrects records you deleted or wipes records the other device just created. There is no variant of snapshot-as-truth that survives a stale device, and a stale device is guaranteed here (the phone can sit unopened for days).

So we sync a log of changes, not a picture of state.

## Architecture

Transport already exists. `BackupService` holds a security-scoped bookmark to a user-picked iCloud Drive folder and writes through `NSFileCoordinator`. iCloud syncs that folder with no entitlements required. Sync reuses it.

Inside the shared folder, **each device writes only to its own subdirectory**. This is the most important decision in the design. iCloud Drive resolves two devices writing the same file by silently creating conflict copies, which would corrupt a shared log. Per-device directories make file-level write conflicts structurally impossible. Log segments are sealed and immutable once rolled, so iCloud only ever uploads new files and never rewrites one.

Each device appends its own ops and tails its peers' directories, applying ops it has not seen.

## Two decisions that keep the blast radius small

**No changes to the existing 15 `@Model` classes.** SwiftData migrations on a live store are the one failure mode that can lose everything, and only 4 of 15 models currently have a `deletedAt`. Rather than add clocks and tombstones across the schema, all sync state lives in new additive sidecar models (tombstones, Lamport clock, shadow hashes). Adding a model is the safe migration; touching 15 existing ones is not.

**Local changes are detected by diffing, not by instrumenting writes.** Writes reach the store from services, the AI tool-use dispatcher, email ingest, statement import and the archive importer. Emitting an op at each mutation site means that missing one site causes that data to silently never sync, which is the worst failure mode because everything looks healthy. Instead we keep a content hash per record in a shadow table and diff the store against it on each pass. This catches every mutation site including undiscovered ones, requires no audit of the service layer, and costs milliseconds at personal scale. A record in the shadow but absent from the store is a delete.

## Conflict resolution

Lamport counter per device rather than wall clock, so ordering survives clock skew between the phone and the Mac. Deterministic tiebreak on device id.

Phase 2 ships record-level last-writer-wins. Field-level LWW is deferred to phase 4 and only if the coarser rule proves annoying in practice. The difference: ticking a task complete on the phone while renaming it on the Mac keeps one edit under record-level and both under field-level. Rare for a single person with two devices, and field-level is where the row count and complexity live.

**Hard invariant: absence never means delete.** A local record is removed only when an explicit tombstone op arrives. This is what makes staleness safe.

## Latency expectations

Correctness holds in every case below. Only latency degrades, and this is where the free path is genuinely worse than CloudKit.

- Both apps open: seconds. macOS can watch the folder with FSEvents for near-instant pickup.
- Phone backgrounded: syncs on next foreground. Reliable background sync is not available without entitlements.
- Phone unopened for days: it is days behind, then catches up correctly on open.

## Phases

- [ ] #348 Phases 0 and 1 (landing together): shared folder handshake, device identity, detailed sync status UI, outbound oplog running in dry run
- [ ] Phase 2: inbound apply, tombstones, record-level LWW, behind a Settings toggle
- [ ] Phase 3: attachments as content-addressed blobs, log compaction, new-device bootstrap
- [ ] Phase 4 (conditional): field-level LWW, only if phase 2 clobbering proves annoying

Phase 1 exists as a dry run specifically so change capture can be verified over several days before anything is allowed to write.

## Risks

- **iCloud Drive is not a database.** No ordering guarantees between files, eventual consistency, occasional conflict copies. Immutable per-device segments absorb most of this. Any mutable pointer file is a hint only; the segments present on disk are the truth.
- **A stale or moved bookmark silently stops sync.** Needs a visible health indicator, not a silent failure. This is part of why the status UI is detailed.
- **The archive importer is additive-only.** It skips records whose UUID already exists, which is right for restore and wrong for sync. It needs an upsert path in phase 2 or 3. This is the one existing component the work genuinely changes.
- **The macOS sandbox is currently off** (dev-only, run from Xcode). Bookmark behaviour shifts once it is enabled, so revisit before any distribution.
- **One user-global store shared across worktrees.** Existing serialisation discipline applies to two-device testing too.

## Out of scope

- Multi-user or shared-with-others sync. Single user, multiple devices only.
- Real-time collaborative editing.
- iPad.
- Reviving the Express server as a sync backend (considered and rejected: contradicts the on-device direction, needs the Mac always on, and the phone loses sync off Tailscale).
