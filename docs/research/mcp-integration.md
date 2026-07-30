# Exposing Dexter to Claude Code (MCP / CLI)

Goal: let Claude Code read and mutate Dexter data (todos, notes, lists, itineraries) from the terminal the same way it already reads Slack, Gmail, etc.

## The core constraint

Claude Code is a process on the Mac. Dexter data lives in SwiftData **on the iPhone**. Every "integration" we look at boils down to one question:

**Where does Claude Code's MCP server fetch data from?**

Three honest answers, ranked by effort vs. reliability:

| Path | Where data is served from | Effort | Reliability | $ cost |
|---|---|---|---|---|
| **A. Mac-side mirror (revive server)** | Local Postgres on Mac, fed by iOS sync | Low (server already built) | High (works offline) | $0 |
| **B. Phone-as-server** | NWListener inside iOS app, over Tailscale | Medium | Low (needs phone unlocked + app foregrounded) | $0 |
| **C. CloudKit** | Apple's iCloud servers | High | Highest | $99/yr (paid Apple Developer) |

## Prerequisites assessment (what you have today)

Confirmed by walking the repo:

- **Paused Express server** at `server/` with **full CRUD already implemented** for todos / notes / lists / folders, plus `/api/sync/upsert` and `/api/sync/changes` sync endpoints. ~40 routes ready to go.
- **Postgres locally**, schema in `server/schema.sql`, migration in `server/migration.sql`.
- **SwiftData models** (`LocalTodo`, `LocalNote`, `LocalList`, `LocalNoteFolder`) keyed on `clientUUID` — same key the server uses for sync.
- **Tailscale** on Mac + iPhone (already used per the `LocalNetworkPermissionPrimer` work).
- **Node 20+** + Anthropic API key (already in `.env`).
- **Free Apple Developer (personal team)** — blocks CloudKit, iCloud KV, iCloud Documents. Confirmed in CLAUDE.md gotchas.

You do **not** have:
- A live data source on the Mac (the server is paused; the iOS app no longer pushes to it as of 2026-05-03).
- Multi-device sync.
- Any existing MCP server for Dexter.

## Recommendation: Path A (Mac-side mirror)

Revive the server as a **read/write mirror** of the on-phone SwiftData. iOS remains the source of truth; the Mac holds the latest known state and gets updated when the phone is reachable.

### Why this beats the alternatives

- **You already wrote the API.** `/api/todos`, `/api/notes`, `/api/lists` all exist with create/read/update/delete. The sync endpoints exist. No new backend work — just rewire and slim down.
- **It works when the phone is asleep / out of network.** Claude Code can still read your last known todos at 11pm without your phone being unlocked. Path B can't do this.
- **Writes flow naturally.** MCP write → server → next iOS sync pull picks it up. (Same loop as a normal multi-device app.)
- **The 2026-05-03 "iOS-first, no server in the path" decision is preserved** — the server is *not* on the iPhone's critical path for AI or capture. It's a side-channel mirror that Claude Code reads. If the Mac is off, the iOS app keeps working unchanged.

### Architecture

```
iPhone (source of truth)              Mac
┌─────────────────────┐               ┌──────────────────────────────────┐
│ SwiftData           │               │  Postgres (mirror)                │
│  └─ LocalTodo       │ ── sync ───▶ │   └─ todos / notes / lists         │
│  └─ LocalNote       │   (REST)      │                                    │
│  └─ LocalList       │               │  ┌─────────────────────────────┐   │
└─────────────────────┘               │  │ dexter-mcp (Node, stdio)     │   │
        ▲                              │  │  tools: list_todos,          │   │
        │ writes flow back              │  │         search_notes,        │   │
        │ on next iOS pull              │  │         add_todo, ...        │   │
        │                              │  └────────────┬─────────────────┘   │
        │                              │               │                     │
        └──────── REST ────────────────┤  ◀── Claude Code MCP client ────────┤
                                       └──────────────────────────────────┘
```

### Setup steps

1. **Slim the server.** Strip out the AI endpoints (`/api/ai/*`), preferences, drafts — keep only todos / notes / lists / folders CRUD + sync. Lives on Mac only, bound to `127.0.0.1` or Tailscale interface. Run via `launchd` so it survives reboots.
2. **Add iOS push sync.** In each SwiftData write path, queue an upsert to `/api/sync/upsert` when reachable. Use `URLSession.background` so it survives the app being backgrounded for a few minutes. Bonjour discovery + Tailscale fallback (same primer pattern already in the codebase).
3. **Add iOS pull sync.** On launch + foreground, GET `/api/sync/changes?since=<lastCursor>` and merge. Last-write-wins is fine for a single-user app.
4. **Build the MCP server.** Node + `@modelcontextprotocol/sdk`. Project layout:
   ```
   tools/dexter-mcp/
     package.json
     src/index.ts            (MCP stdio transport)
     src/tools/todos.ts      (list_todos, add_todo, complete_todo, delete_todo)
     src/tools/notes.ts      (search_notes, add_note, append_to_note)
     src/tools/lists.ts      (list_lists, add_to_list, check_list_item)
   ```
   Each tool is a thin wrapper that hits the local server via `fetch('http://127.0.0.1:3001/api/...')`.
5. **Wire into Claude Code.** Two options:
   - Per-project: drop `.mcp.json` in this repo's root.
   - Global: `claude mcp add dexter --command node --args tools/dexter-mcp/dist/index.js`.
6. **Optional CLI.** Same tool functions exposed as a `dexter` binary (`dexter todos list`, `dexter notes search "groceries"`). Shares code with the MCP server. Adds ~30 min of work.

### Trade-offs to accept

- **Sync lag.** Up to a few seconds between phone write and Mac visibility. Fine for Claude Code use cases (review, summarize, batch-add).
- **Mac must be on for writes to reach the phone immediately.** When the Mac is off, writes from Claude Code queue locally and reach the phone next time both are up.
- **Two stores to debug** when something looks wrong. Mitigated by `clientUUID` being the same on both sides — easy to diff.

## When to consider Path B or C

**Path B (phone-as-server)** makes sense if you specifically want Claude Code to see *exactly* what's on the phone with zero sync staleness — useful for a debugging tool, not for daily use. The reliability hit (app must be foregrounded for the listener to stay alive) is the killer.

**Path C (CloudKit)** is the long-term right answer. If you upgrade to the paid Apple Developer Program for any other reason (TestFlight, push notifications, real iCloud sync between your own devices), the same upgrade unlocks SwiftData + CloudKit auto-sync. Then the Mac MCP can read CloudKit directly via `CKContainer` in a small Swift CLI, no Mac-side server needed.

If/when you go to Path C, the MCP tool definitions don't change — only the data layer underneath. Path A's MCP server is the right abstraction either way.

## MCP vs CLI — which one to build

Both. They're cheap to ship together if you structure the code right:

- **MCP server** is the primary: Claude Code calls it natively in every session, the model picks tools autonomously, no manual invocation. This is how Slack and Gmail feel inside Claude Code.
- **CLI** is the same logic exposed as a binary for terminal use without Claude (`dexter add "buy milk"`, `dexter notes search trip`). Shared TypeScript modules. ~30 min extra.

Don't build a CLI *only*. Claude Code can shell out to it, but you lose tool descriptions, schema validation, and the model's ability to chain calls. MCP first.

## Open questions before we build

- [ ] Is reviving the server (Path A) acceptable, given the 2026-05-03 decision was specifically to remove it from the iPhone's path? (My read: yes, because Path A keeps the server *off* the iPhone's critical path. The iOS app still works fully offline; the server is a Mac-only mirror.)
- [ ] Do we need authentication on the local server, or is binding to Tailscale + loopback enough? (My read: loopback + Tailscale-only ACL is enough for solo use. Add a bearer token if it ever leaves your tailnet.)
- [ ] Should the MCP server live in this repo (`tools/dexter-mcp/`) or as a sibling project? (My read: same repo, under `tools/`, so it ships with the iOS schema.)
- [ ] Do we want write-through tools from day one, or read-only MVP first? (My read: read-only MVP first — `list_todos`, `search_notes`, `list_lists`. Add writes once the read path is stable.)

## Estimated effort (Path A, read-only MVP)

- Slim + restart server, add launchd plist: **2 hours**
- iOS push sync hook on SwiftData writes: **3 hours**
- iOS pull sync on launch/foreground: **2 hours**
- `tools/dexter-mcp` with 4 read-only tools: **3 hours**
- Wire into Claude Code + smoke test: **30 min**

Total: **~1 day** to first useful Claude Code session that can read your Dexter data. Writes add another ~half day.
