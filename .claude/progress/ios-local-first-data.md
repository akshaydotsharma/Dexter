# iOS local-first data layer

**Status**: in-progress
**Started**: 2026-05-03
**Last Updated**: 2026-05-03 SGT
**Ticket**: #14
**Branch**: `feat/ios-local-first-data`

## Objective
Make iOS todos, notes, and lists fully usable when the Mac is off. Local-first store on iPhone (SwiftData) with background sync to the Express + Postgres backend on the Mac. Conflict resolution is last-write-wins by `updated_at`, with `version` for delta sync.

## Phases

### Phase 1: Server schema + sync primitives (this session)
- [ ] Add `version BIGINT NOT NULL DEFAULT 1` to todos, notes, lists, note_folders
- [ ] Add `client_uuid UUID UNIQUE` to todos, notes, lists, note_folders
- [ ] Add `deleted_at TIMESTAMP` to notes, lists, note_folders (todos already has)
- [ ] Ensure `updated_at` exists everywhere (lists, note_folders need it)
- [ ] Trigger that bumps `version` and `updated_at` on every UPDATE
- [ ] All write paths in `server/index.js` return `version` and `client_uuid` in their JSON
- [ ] Server tests pass

### Phase 2: Server sync endpoints (this session or next)
- [ ] `GET /api/sync/changes?since_version=N` returns delta across todos, notes, lists, note_folders since the version watermark, including soft-deletes
- [ ] `POST /api/sync/upsert` accepts a batch of client changes keyed by `client_uuid`, with conflict resolution: server wins if its `updated_at` is newer; otherwise apply client change
- [ ] Server tests cover: insert by client_uuid, update by client_uuid, delete, conflict resolution

### Phase 3: iOS SwiftData scaffold
- [ ] `Models/Local/LocalTodo.swift` (and Note, List, NoteFolder later)
- [ ] `Cache/SwiftDataStore.swift` boot + container
- [ ] `Cache/Outbox.swift` for queued mutations (create/update/delete)
- [ ] `Sync/SyncEngine.swift` with `pullChanges()` + `pushOutbox()`
- [ ] Hook into app lifecycle: drain outbox + pull on foreground, on push-notification (later), on connectivity restored

### Phase 4: Migrate Todos widget end-to-end
- [ ] `TodoService` reads from SwiftData first, falls back to API on miss
- [ ] All writes go to SwiftData + enqueue outbox
- [ ] `TodosViewModel` switches to SwiftData `@Query`
- [ ] Retire `CacheStore.Key.todos` once green
- [ ] Device QA: airplane mode add/edit/delete, reconnect, verify convergence

### Phase 5: Migrate Notes
- [ ] Same pattern as Todos. Folders included.

### Phase 6: Migrate Lists / Checklists
- [ ] Same pattern. Note: `lists.items` is JSONB; the items array is part of the row, not separate rows.

### Phase 7: Cleanup + ship
- [ ] Retire `CacheStore` entirely
- [ ] Document conflict semantics in CLAUDE.md
- [ ] Open PR linked to #14
- [ ] Device QA evidence in ticket comment

## Completed Steps
- [x] Phase 1: schema additions + sync triggers + tests (5 new tests, 2026-05-03)
- [x] Phase 2: sync endpoints + soft-delete switch for notes/lists/folders + tests (7 new tests, 2026-05-03)
- [x] Phase 3: iOS SwiftData scaffold — LocalTodo @Model, SwiftDataStore container, SyncEngine pull+push, SyncWatermark, SyncWireFormat DTOs, app-launch sync wiring (2026-05-03). Build succeeds.

## Current Step
Phase 4: migrate Todos widget to read from SwiftData.
- Rewrite `TodoService` so create/update/delete operate on `LocalTodo` first, then enqueue (set `needsSync = true`) for the next sync push. Read paths fetch LocalTodo and project to `Todo` DTOs.
- Rewrite `TodosViewModel` to source `[Todo]` from `SwiftDataStore.shared.context.fetch(LocalTodo)` instead of the API. `load()` becomes "trigger sync, then refetch from local store".
- Validate on a real device per `dev-workflow.md`: airplane-mode add/edit/delete, reconnect, watch the sync settle.
- Note: `ChatViewModel` and the AI capture flow also call `TodoService.create` etc — confirm those paths still work after the rewrite (they should, as the API surface stays the same shape).

## Phase 4 callsite map (compiled before starting)
- `TodoService` is consumed by: `TodosViewModel`, `ChatViewModel` (chat-to-drafts confirmation), the App Intent capture flow.
- All three should keep working because the public method signatures don't change — only the implementation moves from "POST/PUT/DELETE API call" to "write to SwiftData + queue for sync".

## Blockers
None.

## Key Decisions Made
- 2026-05-03: SwiftData over Core Data / SQLite. iOS 17+ minimum is fine.
- 2026-05-03: Last-write-wins by `updated_at`. No CRDTs.
- 2026-05-03: `client_uuid` UUID column lets iOS create rows offline with a stable identity. Server still keeps integer PK for backward compat.
- 2026-05-03: `version BIGINT` per row, monotonic across the whole DB (or per table; deciding in Phase 1).
- 2026-05-03: Soft-delete everywhere (notes, lists, folders) so deletes can sync.

## Files Modified
(filled in as we go)

## Context for Next Session
Read this file. Then check `git log feat/ios-local-first-data` for what's already shipped. Then resume from "Current Step".
