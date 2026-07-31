# Dexter Security Audit Report

**Date:** 2026-07-31
**Auditor:** OWASP audit skill (Claude Code)
**Scope:** exposed secrets, missing auth checks, unsafe endpoints
**Surfaces:** iOS app (`mobile/`), Express server (`server/`), React webapp (`client/`), deploy config (`render.yaml`), OTA scripts
**Standards:** OWASP Top 10:2025, OWASP Top 10 for LLM Applications v1.1
**Mode:** Full audit. Static review + safe read-only reachability probe against the user's own deployed service. No writes, no destructive requests, no real data extracted.
**Prior audit:** `security/reports/2026-05-28_owasp_audit_report.md` (this report tracks its findings to closure)

---

## Executive Summary

The headline is a delta between git and production, not a new code defect.

The May audit's two Critical findings (C2 no auth, C3 CORS wildcard with credentials) were **fixed in code** on 2026-05-29 (commit `357aa85`). They were **never fixed in production**. The Render service `dexter-api` is still live at `https://personal-dashboard-g0w8.onrender.com`, serving a **pre-fix build**: all 47 routes reachable with zero authentication, and the CORS wildcard confirmed present by response header. `render.yaml` still carries `autoDeploy: true`.

The only thing preventing full data exfiltration and destruction today is an unrelated accident: the Supabase database behind it is gone, so every query fails. One reconnected `DATABASE_URL` restores complete public read/write/delete access to the dataset.

Secrets hygiene is clean. No credential has ever been committed to this repo. iOS credential storage (Keychain, `AfterFirstUnlock`, never logged) is correct. All SQL is parameterised. Zip/pkpass parsing is bounds-checked and in-memory. Prompt-injection hardening was added to both the chat and email LLM paths since May and is materially better than a prompt-only defence usually is.

### Top 3 (Fix Now)

1. **P0-1. Unauthenticated production API is live and running a pre-fix build** (A01 + A07 + A05). Verified reachable. Delete the service; do not merely redeploy.
2. **P0-2. Public error responses leak infrastructure identifiers** (A09). `GET /api/sync/changes` currently returns the Supabase project ref to anonymous callers.
3. **P0-3. Rotate the `OPENAI_API_KEY` held in the Render dashboard** (A02). It lives on a service that has been publicly exposed and unattended since May.

### Buckets

- **Fix Now:** P0-1, P0-2, P0-3
- **Fix Next:** P1-1 (DB TLS validation off), P1-2 (ATS disabled app-wide), P1-3 (email-ingest sender allowlist)
- **Fix Later:** P2-1 (CSP `unsafe-inline`), P2-2 (baked API keys now redundant), P2-3 (in-memory rate-limit store), P2-4 (unused `@google/generative-ai` dep), P2-5 (Google Fonts without SRI)

---

## Scope and Assumptions

**In scope:** server routes/middleware/queries, deploy config, iOS credential storage and network surfaces, LLM prompt construction and tool permissions, zip/attachment parsing, git history for secrets, dependency audit.

**Out of scope:** authenticated dynamic testing (no auth exists to test), macOS host security, Anthropic/OpenAI platform security, transitive dependency review beyond `npm audit`, network attacks on the user's LAN.

**Probe conduct:** GET-only requests to the user's own Render service, plus one `Origin`-header request to fingerprint the running build. No POST/PUT/DELETE was issued. No database contents were retrieved (the DB was down).

---

## Attack Surface Summary

| Surface | State | Auth |
|---|---|---|
| `dexter-api` on Render | **LIVE, publicly reachable** (verified 2026-07-31) | **None** |
| `dexter-client` on Render | 404, not serving | n/a |
| Express routes | 47 across `index.js` + `sync.js`, incl. DELETE and `/api/ai/execute` | **None** |
| iOS → Anthropic | `api.anthropic.com`, HTTPS | key in Keychain, else Info.plist |
| iOS → OpenAI (voice) | HTTPS | key in Keychain, else Info.plist |
| iOS → IMAP | `imap.gmail.com:993` TLS | app password in Keychain |
| Email ingest → LLM | untrusted email body + attachment text | 2-tool allowlist, auto-executes |
| Chat → LLM | user turn + SwiftData context | 23 tools; `delete_*` requires confirm |
| Capture/Shortcut → LLM | Shortcut input | 23 tools, auto-executes (accepted decision) |
| OTA install | Cloudflare quick tunnel, ephemeral | none (short-lived) |

---

## Findings Overview

| ID | Title | Severity | Category | Status vs May |
|----|-------|----------|----------|---------------|
| P0-1 | Unauthenticated prod API live, serving pre-fix build | **Critical** | A01 + A07 + A05 | C2/C3 fixed in code, **live in prod** |
| P0-2 | `err.message` returned to anonymous callers; leaks Supabase project ref | **High** | A09 | H2, unfixed |
| P0-3 | `OPENAI_API_KEY` on an exposed, unattended Render service | **High** | A02 | new |
| P1-1 | DB TLS validation disabled in production | **High** | A02 | H4, unfixed |
| P1-2 | `NSAllowsArbitraryLoads` disables ATS app-wide | **High** | A02 | H1, unfixed |
| P1-3 | Email ingest has no sender allowlist | **Medium** | LLM01 + LLM08 | partially mitigated |
| P2-1 | Helmet CSP allows `unsafe-inline` script/style | **Medium** | A05 | H3, unfixed |
| P2-2 | API keys baked into IPA (now redundant) | **Low** | A02 | M3, mitigable |
| P2-3 | Rate-limit uses in-memory store | **Low** | A04 | L1, unfixed |
| P2-4 | `@google/generative-ai` declared, unused | **Low** | A06 | M7, unfixed |
| P2-5 | Google Fonts without SRI | **Low** | A08 | M5, unfixed |

### Verified clean

- **No secrets in the repo or its history.** `git ls-files` + full-history object scan + `git log -S` on key prefixes: only `.env.example` placeholders (`sk-ant-replace-with-your-own-key`). `.env` is gitignored and untracked.
- **No SQL injection.** Every query parameterised. `sync.js` interpolates `${table}`, but only from the hardcoded `TABLES` const (`sync.js:31`); columns come from the `TABLE_SCHEMAS` allowlist. Not user-controlled.
- **iOS credential storage is correct.** IMAP app password and user API keys in Keychain (`kSecAttrAccessibleAfterFirstUnlock`), never logged, never returned by the `hasPassword` accessor.
- **Zip/pkpass parsing is safe.** `ZipArchiveReader` is in-memory (no filesystem extraction, so no zip-slip), with bounds checks and a 16 MB per-entry inflate cap against declared-size bombs.
- **`npm audit`: 0 vulnerabilities.**
- **LLM prompt hardening present** in both `ChatToDrafts.swift:188` and `EmailToItinerary.swift:1294`, explicitly naming the untrusted blocks and the attacker-controllable email body.

---

## Detailed Findings

### P0-1: Unauthenticated production API is live and running a pre-fix build

**Category:** A01 (Broken Access Control) + A07 (Authentication Failures) + A05 (Misconfiguration)
**Severity:** Critical. **Confirmed**

**Description:** `dexter-api` remains deployed on Render and answers anonymous requests from the internet. It is running a build from before the 2026-05-29 hardening commit, so both May Criticals are live in production despite reading as fixed in git.

**Evidence:**

Reachability, GET-only:
```
GET /api/config       -> HTTP 500  {"error":"An internal server error occurred"}
GET /api/todos        -> HTTP 500
GET /api/notes        -> HTTP 500
GET /api/sync/changes -> HTTP 500  {"error":"(ENOTFOUND) tenant/user postgres.kuvuabrokctvvewzcchu not found"}
```
The app is routing and executing handlers. The 500s are database failures, not rejections.

Build fingerprint. The removed CORS wildcard is still active:
```
$ curl -H "Origin: https://evil.up.railway.app" .../api/config
access-control-allow-origin: https://evil.up.railway.app
access-control-allow-credentials: true
```
`server/index.js:62-80` on `main` has no wildcard branch. An arbitrary attacker-controlled origin being reflected proves the running instance predates that commit.

The in-code mitigation cannot help a stale deploy:
```javascript
// server/index.js:2299-2302
const HOST = process.env.HOST || '127.0.0.1';
app.listen(PORT, HOST, ...)
```
And redeploy is armed: `render.yaml:10` `autoDeploy: true`.

**Exploit scenario:** Anyone with the URL calls `DELETE /api/notes/:id`, `POST /api/ai/execute`, or `GET /api/sync/changes` with no credential. Today every call 500s because the Supabase instance is gone. Restore or repoint `DATABASE_URL` (or let `autoDeploy` pick up a push where someone sets it) and the entire dataset becomes world-readable and world-destroyable. `POST /api/ai/execute` additionally spends the server's LLM budget for anonymous callers.

**Remediation:**
1. Delete the `dexter-api` and `dexter-client` services in the Render dashboard. Do not redeploy the fixed build: a paused-surface server has no reason to be public at all.
2. Remove `render.yaml`, or set `autoDeploy: false` and strip the service blocks, so deploy intent is explicit (same reasoning that deleted `railway.json`).
3. Confirm no other host serves this app.
4. Only if the server is ever revived: add real authentication before it binds to a public interface.

**Verification:** `curl -sS -o /dev/null -w '%{http_code}' https://personal-dashboard-g0w8.onrender.com/api/config` returns a Render-level 404 with no `access-control-*` app headers. `grep -c autoDeploy render.yaml` returns 0.

---

### P0-2: Error responses return `err.message` to anonymous callers

**Category:** A09
**Severity:** High. **Confirmed**, leaking in production right now

**Description:** The sync handlers return the raw exception message regardless of `NODE_ENV`, bypassing `sendErrorResponse` (`index.js:119-129`), which correctly redacts in production.

**Evidence:**
```javascript
// server/sync.js:76 and :223
res.status(500).json({ error: err.message });
```
Live output: `{"error":"(ENOTFOUND) tenant/user postgres.kuvuabrokctvvewzcchu not found"}`: the Supabase project ref and tenant identifier, disclosed to an unauthenticated caller. The neighbouring `/api/config` correctly returns the generic string, which is exactly the inconsistency.

Also applies to the SSE handler at `index.js:1504-1507`.

**Exploit scenario:** An attacker maps the backing infrastructure (Supabase project ref, hostnames, driver versions) without authenticating, then pivots to credential-stuffing or targeted attacks on the database tenant.

**Remediation:** Route both `sync.js` catch blocks and the SSE error path through `sendErrorResponse`. Export the helper from a shared module rather than duplicating it.

**Verification:** With `NODE_ENV=production`, force a DB failure and confirm the body is `{"error":"An internal server error occurred"}` with the detail present only in server logs.

---

### P0-3: `OPENAI_API_KEY` held in the Render dashboard of an exposed service

**Category:** A02
**Severity:** High. **Potential**, no evidence of misuse; the key value was not retrieved)

**Description:** `render.yaml:17-18` declares `OPENAI_API_KEY` with `sync: false`, so a live value was set manually in the Render dashboard. That key has sat on a publicly reachable, unauthenticated, unmonitored service since May. Its blast radius is billing.

**Evidence:**
```yaml
# render.yaml
- key: OPENAI_API_KEY
  sync: false  # Set manually in dashboard
```

**Remediation:** Rotate the key in the OpenAI console as part of deleting the service. Confirm a spend cap on the replacement. The iOS app resolves its own key from the Keychain and does not depend on this one.

**Verification:** Old key returns 401 from the OpenAI API; usage dashboard shows no activity on the old key after rotation.

---

### P1-1: Database TLS certificate validation disabled in production

**Category:** A02
**Severity:** High. **Confirmed** in code; latent while no DB is attached

**Evidence:**
```javascript
// server/db.js:14
ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false,
```

**Description:** Production encrypts the DB connection but accepts any certificate, so TLS provides no authentication of the server. An attacker positioned between app and database can present a self-signed cert and read or rewrite all traffic including credentials.

**Remediation:** Supply the provider CA bundle and set `rejectUnauthorized: true`:
```javascript
ssl: process.env.NODE_ENV === 'production'
    ? { rejectUnauthorized: true, ca: process.env.DATABASE_CA_CERT }
    : false,
```

**Verification:** Connection succeeds with the correct CA; deliberately substituting a wrong CA fails to connect.

---

### P1-2: ATS disabled application-wide on iOS

**Category:** A02
**Severity:** High. **Confirmed**

**Evidence:**
```xml
<!-- mobile/PersonalDashboard/Info.plist:43-47 -->
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
```

**Description:** A blanket opt-out to permit plain HTTP to the LAN dev server. It also removes ATS enforcement (TLS floor, forward secrecy, cert requirements) from *every* connection the app makes: Anthropic, OpenAI, Wikimedia cover fetches, IMAP. The one surface that needed it is the one paused surface.

**Remediation:** Replace the blanket flag with a scoped exception for the dev host only, so production endpoints keep ATS:
```xml
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsLocalNetworking</key><true/>
</dict>
```
`NSAllowsLocalNetworking` covers RFC1918/`.local` without weakening public connections. If a specific hostname is still needed, use `NSExceptionDomains` for that host alone.

**Verification:** Build and confirm Chat, voice, and cover fetches still work; confirm a plain-HTTP request to a public host is now blocked.

---

### P1-3: Email ingest has no sender allowlist

**Category:** LLM01 (Prompt Injection) + LLM08 (Excessive Agency)
**Severity:** Medium. **Confirmed** design gap, well mitigated

**Description:** `EmailIngestService` processes every message in the receipts inbox. Body plus extracted attachment text goes to the LLM, and successful tool calls execute with no user confirmation (`EmailToItinerary.swift:468,743` call `ExecuteDraftAction` directly). Anyone who learns `dexter.receipts@gmail.com` can submit content into the model's context.

The existing mitigations are genuinely good and bound the damage sharply:
- Only two tools are exposed, both additive: `add_itinerary_item`, `add_expense`. No create, edit, or delete of trips or anything else (`EmailToItinerary.swift:1291`).
- The system prompt names the email body as attacker-controllable and instructs refusal of embedded directives (`:1294`).
- An idempotency ledger keyed on Message-Id prevents replay.
- Per-cycle work is bounded.

Residual risk is therefore data pollution (spurious expenses or itinerary rows), not data loss. But the control is prompt-level, and prompt-level controls are probabilistic.

**Exploit scenario:** An attacker emails a crafted fake booking. Best case it is refused. Worst case a bogus expense or itinerary item lands silently on a trip, corrupting the Finance totals the trip-expense feature computes.

**Remediation:** Add a deterministic check before any LLM call. It is cheap, and it converts a probabilistic defence into a binary one:
1. Allowlist sender addresses/domains in `EmailInboxConfig` (default: the user's own addresses). Log non-matching messages as `skipped` rather than parsing them.
2. Optionally require an unguessable subject token for forwarded mail.
3. Consider surfacing email-derived items as pending until first viewed, matching the chat path's confirm posture.

**Verification:** Send a message from a non-allowlisted address; confirm the ingest log records `skipped` and no LLM request is issued.

---

### P2 findings (defence-in-depth)

- **P2-1. CSP allows `unsafe-inline`** (`index.js:40-41`, A05). Negates most XSS protection. Inert while the webapp is paused; fix with hashes/nonces before any revival.
- **P2-2. API keys baked into the IPA** (A02). `strings` recovers them. Now largely redundant: `UserAPIKeys` (#337) stores a Keychain value that takes precedence. Consider omitting the baked key from archives and entering keys once per install.
- **P2-3. Rate limits use the default in-memory store** (`index.js:83-98`, A04). Counters reset on restart. Only matters if the server revives publicly, which P0-1 argues against.
- **P2-4. `@google/generative-ai` declared but unused** (A06). Remove to cut supply-chain surface. `server/test-bytez.js` is likewise dead scaffolding.
- **P2-5. Google Fonts without SRI** (`client/index.html`, A08). Webapp only.

### Accepted risks (recorded, not defects)

- **Capture/Shortcut path auto-executes destructive tools.** Deliberate (project memory `feedback_shortcut_deletes_allowed`); chat gates `delete_*` behind confirmation while Shortcuts do not. Reachable only by someone who already controls the unlocked device. Left as-is.
- **OTA install over a Cloudflare quick tunnel.** Unauthenticated but ephemeral and torn down per ship.

---

## Remediation Backlog

| Priority | Task | Effort |
|---|---|---|
| P0 | Delete Render `dexter-api` + `dexter-client`; strip `render.yaml` | 10 min |
| P0 | Rotate `OPENAI_API_KEY`; verify spend cap | 5 min |
| P0 | Route `sync.js:76,223` + `index.js:1504` through `sendErrorResponse` | 15 min |
| P1 | `rejectUnauthorized: true` + CA bundle in `db.js` | 30 min |
| P1 | Replace `NSAllowsArbitraryLoads` with `NSAllowsLocalNetworking` | 30 min |
| P1 | Sender allowlist in email ingest, pre-LLM | 1-2 h |
| P2 | CSP nonces; drop unused deps; persistent rate-limit store; SRI | 2-3 h, only if web revives |

Verification for P0-1 and P0-3 is dashboard work in Render and OpenAI, not code, so it cannot be closed by a commit.

## Appendix: method

- `git ls-files` + full-history object enumeration + `git log -S` on `sk-ant-api` / `sk-proj-` for committed secrets
- Route inventory by grep over `app.<verb>` across `index.js`, `sync.js`, `preferences.js`
- Auth-middleware search (`authenticate|requireAuth|jwt|passport|bearer|session`): no matches
- `npm audit --omit=dev`
- Read-only reachability probe of the user's own Render service; one `Origin`-header request to fingerprint the running build. No writes issued.
