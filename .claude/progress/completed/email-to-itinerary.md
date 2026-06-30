# Email-to-Itinerary (forwarded booking emails auto-add to trips)

**Status**: DONE — merged to main (squash 2c29c3d, PR #145), #143 closed. Device end-to-end QA is the user's final step.
**Started**: 2026-06-30
**Last Updated**: 2026-06-30
**Ticket**: https://github.com/akshaydotsharma/Dexter/issues/143
**Branch**: feat/email-to-itinerary @ 9e22e863f23f7553977478da46263e91e61618c3 (not pushed, no PR yet)

## Objective
Forward a booking email to dexter.receipts@gmail.com; Dexter fetches it on-device over IMAP, the on-device AI matches it to an existing trip by date/destination, and auto-adds itinerary items with a notification + undo.

## Locked decisions
- Ingestion: app auto-fetches from a dedicated inbox.
- Inbox: dexter.receipts@gmail.com.
- Auth: IMAP + Gmail app password in Keychain (NOT OAuth — chosen to avoid the 7-day testing-mode refresh-token expiry; restricted gmail.readonly scope would otherwise need full Google verification).
- Confirm flow: auto-add on match, then notify (with undo). This path un-excludes the trip tools; chat + Capture keep their no-auto-trips guard.
- No-match behavior: skip and notify. Never auto-create a trip.
- Flights/transport map to `activity` kind in v1 (no transport kind exists).

## Existing module (already built — reuse, do not rebuild)
- Models: LocalTrip (clientUUID, name, startDate, endDate, notes), LocalItineraryItem (clientUUID, tripUUID, dayDate, kind[stay|activity|place|restaurant], title, notes, startTime?, endDate?, endTime?, sortOrder). Files under mobile/PersonalDashboard/Models/Local/.
- AI tools (mobile/PersonalDashboard/AI/ToolDefinitions.swift): draft_trip, add_itinerary_item, edit_trip, delete_trip, edit_itinerary_item, delete_itinerary_item. Currently in `captureExcludedToolNames`.
- ExecuteDraftAction.swift: createTrip, addItineraryItems, updateTrip, deleteTrip, updateItineraryItem, deleteItineraryItem.
- AssistantContextBuilder.build(): renders last 20 trips (3 with full day breakdown) into LLM context — use this for matching.

## New build (v1) — DONE (commit 9e22e863)
- [x] Keychain-backed IMAP credential store + Settings UI (Settings → Automation → Receipts inbox). KeychainStore.swift, EmailInboxCredentials.swift, Views/Settings/EmailInboxView.swift.
- [x] IMAP client — hand-rolled over Network.framework (NWConnection+TLS). Chose this over an SPM lib: zero existing 3rd-party deps, narrow need (LOGIN/SELECT/UID SEARCH/UID FETCH BODY.PEEK/UID STORE), no supply-chain surface. Services/IMAPClient.swift + EmailMessage.swift (MIME parser).
- [x] Ingestion orchestrator AI/EmailToItinerary.swift — advertises ONLY add_itinerary_item to the model, so it structurally cannot create/edit/delete a trip (stronger than just un-excluding tools). Reuses ExecuteDraftAction.addItineraryItems + AssistantContextBuilder.
- [x] Idempotency: LocalProcessedEmail @Model keyed by Message-Id (fallback uidvalidity:uid), ledger written only after handling; also marks \Seen.
- [x] Fetch-on-launch/foreground + BGAppRefreshTask (EmailIngestCoordinator.swift, AppDelegate). UIBackgroundModes + BGTaskSchedulerPermittedIdentifiers added to project.yml.
- [x] Local notifications + Undo action (diffs item UUIDs before/after, deletes exactly those) + in-app recent add/skip log (LocalEmailIngestLog @Model).

## Build / ship
- xcodebuild (simulator) BUILD SUCCEEDED, clean. SourceKit "cannot find in scope" errors are stale-index false positives (per CLAUDE.md gotcha).
- Installed to "Flightmode 2.0" (iPhone 16 Pro Max) via devicectl (CoreDeviceError 4 tunnel flake on first try, --verbose retry succeeded).

## Deferred from v1
- MIME parser is pragmatic (prefers text/plain, strips HTML, recurses 1 level), not full RFC. Exotic encodings may slip.
- Newest 25 UIDs per fetch cycle (backlog catches up over cycles).
- No automated XCTest (test target is UI-only); brittle pure fns validated via standalone script.
- Notification auth requested lazily on first ready fetch, not cold launch.

## Codebase note worth remembering
- Agent reports `captureExcludedToolNames` is DEFINED but never actually applied at runtime, and the capture system prompt already enables trip tools. So the "no-auto-trips guard" on Capture was nominal, not enforced. VERIFY before relying on this.

## Notes / gotchas
- Background fetch is best-effort; reliable fetch is on app open.
- App password requires 2FA on dexter.receipts@gmail.com + IMAP enabled in Gmail settings. imap.gmail.com:993 SSL.
- Anthropic key already in IPA; app password must go to Keychain, never source.

## Device QA round 1 (2026-06-30) — FOUND 2 BUGS
User forwarded a flight email + a stay/itinerary email for an existing Italy trip. Both SKIPPED.
Activity log showed:
- Flight = "(no subject)": "No matching trip. ...does not contain any booking info. Appears to be just a signature." => PARSER FAILURE on forwarded email (only extracted signature; subject also not parsed).
- Stay = "Fwd: Your itinerary - IZDHBW": "No matching trip. I cannot add this booking to any existing trip." => AI parsed it fine but DECLINED. Italy trip confirmed to EXIST with matching dates => CONTEXT/RANKING BUG: AssistantContextBuilder ranks trips by updatedAt desc (top 20, full detail top 3); upcoming Italy trip buried/absent, so AI never saw it.

## Fix pass (round 2) — confirmed scope
1. Forwarded-email parsing: handle Fwd: wrappers, nested/attached original (message/rfc822), HTML-only bodies, and forwarded-subject extraction. Must surface the actual booking content, not the signature.
2. Matching context: for the EMAIL path, feed ALL trips (name + date range + id), biased toward upcoming/date-relevant trips, not the chat recency ranking. Do NOT change chat's AssistantContextBuilder behavior.
3. Diagnostics + retry: store raw parsed body (~first 1000 chars) + the trip-context the AI saw on LocalEmailIngestLog; write a row on the failed/exception branch too; add a "Re-scan (ignore processed)" affordance so the SAME forwarded emails can be re-tested without re-forwarding (idempotency ledger currently blocks retry).
4. Flight still maps to `activity` kind (no transport kind in v1).
Then re-ship to phone, user re-QAs.

## Fix pass round 2 — DONE + shipped (commit 8ad77ba)
- Parsing rewrite: detects forwarded-message blocks, recovers original Subject/From, recurses message/rfc822, HTML parts scored by booking signals (so signature/footer loses), Fwd/Fw/Re subject normalization.
- Matching: new AssistantContextBuilder.tripsForMatching() lists ALL trips (id, name, range, upcoming-first), used by EmailToItinerary only. build() untouched for chat/capture. Prompt now lenient on destination (FCO/MXP -> Italy).
- Diagnostics: LocalEmailIngestLog gains debugBody + debugTripContext (additive, migration-safe); activity rows now TAPPABLE to a detail sheet (parsed body + trip context). Failed/exception branch now writes a visible log row.
- Re-scan (ignore processed) button added to Receipts inbox UI -> re-runs same forwarded emails without re-forwarding.
- Clean xcodebuild, installed to phone. PR not opened.

## Re-QA round 2 finding: bookings are PDF ATTACHMENTS, not body text
User forwards Airbnb bookings as PDF attachments; the email body is near-empty, so parsing found nothing. Confirmed via sample files in ~/Downloads:
- "Your trip overview - Airbnb.pdf" + "Florence trip.pdf" = same Airbnb Florence booking. TEXT-BASED PDFs (selectable text layer + a header photo). Contain: Home in Florence / check-in Mon 7 Sept 2:00pm / checkout Wed 9 Sept 11:00am / conf HM84R8EPNF / Via dell' Oriuolo 9, Florence, Tuscany 50122, Italy. NOTE: no YEAR in the PDF ("in 2 months" => Sept 2026) - matcher must infer year.

## Fix pass round 3 (attachments) — in progress
Add attachment extraction to the email ingest path:
- Pull non-text MIME parts (Content-Disposition: attachment), base64-decode, keep filename + content-type + bytes.
- PDF: PDFKit text extraction FIRST (cheap; these PDFs have full text). Fallback to Claude document block only if no/sparse text layer (scanned).
- Images: Claude image block. .ics: parse VEVENT to text.
- Extend AnthropicClient to carry document/image content blocks for the email path.
- Caps on count/size to bound tokens (prefer PDF text extraction over shipping 1.8MB files).
- Matching prompt: infer missing year from trip range / current date.
- debugBody should include extracted attachment text.
- Validate against the two ~/Downloads sample PDFs. Then re-ship.
