# Vision Board (#446)

**Status**: in-progress
**Started**: 2026-08-06
**Last Updated**: 2026-08-07 11:50 SGT
**Branch**: `worktree-feat+vision-board` (pushed, no PR yet)
**Worktree**: `.claude/worktrees/feat+vision-board`
**Issues**: [#446](https://github.com/akshaydotsharma/Dexter/issues/446) main, [#447](https://github.com/akshaydotsharma/Dexter/issues/447) backup/sync follow-up

## Objective

A macOS canvas showing every big piece of work at once: freely positioned,
freely resized blocks holding real `LocalTodo`s as tiles. iOS gets a
single-column projection later.

## Design (settled, approved)

- `docs/design/vision-board-concept.md` — object model, product decisions
- `docs/design/vision-board-design-system.md` — visual and interaction spec

Both carry dated "superseded in review" notes where the user reversed a call.
Do not silently contradict them; amend them the same way.

Interactive prototype (approved 2026-08-06):
https://claude.ai/code/artifact/02938dbd-635c-46b4-abd0-b39bc67e0600

## Completed

- [x] Concept + design system docs (`3675673`)
- [x] Data layer, service, view model, macOS surface (`a3fc50e`)
- [x] Pointer-up safety net for a wedged drag (`e02722c`)
- [x] Removed a card-wide tap that outranked the drag (`7a5d406`)
- [x] Square 68pt lattice + push-aside solver + one-shot grid migration (`4f7e945`)
- [x] **AppKit pointer layer replacing SwiftUI gestures** (`dd1d82d`)
- [x] Grip target reaches the block corner + resize cursor (`b32de4c`)
- [x] Popover accepts first mouse; row hover; title I-beam (`db29ffa`)

## Current state

Tests, all passing and verified in the main session (not just by subagents):

- 16 macOS pointer tests (`DexterMacTests`, `-scheme DexterMac -destination 'platform=macOS' test`)
- 51 iOS tests (`VisionBoardLayoutTests` 37 + `VisionHitTestTests` 14),
  destination `platform=iOS Simulator,id=35C2BC65-8B3F-49EA-BCB8-EACC3EEA2F52`
- Both targets build clean

Two pre-existing failures in `ItineraryDocumentTests` (wallet card eligibility)
confirmed present at clean `4f7e945`. Not ours.

## Next steps

- [ ] User hands-on QA of `db29ffa`: attach-task click, row hover, title I-beam,
      grip cursor. Nothing visual or click-driven has been verified by anyone.
- [ ] Tile drag between blocks — reduced version only (`.draggable` +
      `.dropDestination`, appends rather than dropping at an index). Never QA'd.
- [ ] iOS single-column projection (out of scope for #446)
- [ ] PR once QA passes

## Context for the next session

**Do not try to drive the running app to test gestures.** macOS cooperative
activation refuses key-window status to a background-launched app while another
app holds focus. Direct binary launch, `open` as a bundle and LaunchServices
activation by bundle id all logged `selftest.key=false active=false`, and events
posted to a non-key window are treated as activation clicks. This is *why* the
pointer layer is AppKit: its behaviour is assertable headlessly by calling
`mouseDown`/`mouseDragged`/`mouseUp` directly. Add tests there, not a harness.

**Every build must be re-signed before launching.** The post-build script writes
API keys into `Info.plist` after codesign, so launchd kills the app with exit 0,
no output and no crash report. See memory
`project_macos_plist_injection_breaks_signature`. This also breaks Xcode's Run
button, which is why the user cannot run it from Xcode.

```
codesign --force --sign 4484B29B8B4228FE6CE4D0BF593A8D6B52D3035E \
  --preserve-metadata=entitlements,identifier,flags <DexterMac.app>
open -n --stderr <log> --env LAUNCH_SECTION=visionboard <DexterMac.app>
```

**Running DexterMac from `main` drops the board's table**, since main's
`schemaModels` has no `LocalVisionBlock`. Tasks and everything else are safe, and
nothing is broadcast to the phone because the model is deliberately outside
`SyncRecordMapper`.

**Do not post synthetic input to the global event tap.** Early in this work a
`CGEvent.post` landed in the user's browser during a screen-shared call.
`NSApp.postEvent` into the app's own queue is the only acceptable form, and even
that needs a key window it cannot get.

**Three diagnoses were wrong before the right one.** `.scrollDisabled` was named
and refuted; a card-wide `.onTapGesture` was named and was at most partly right;
`.focusable()` was the standing suspect when the architecture changed instead.
The lesson recorded in `dd1d82d`: intermittency in SwiftUI gestures means
recogniser racing, and it does not get fixed by reordering priorities.

## Key decisions

- Membership is an ordered UUID list on the block, never a field on `LocalTodo`
- State is manual and owns the block edge; urgency is derived and owns a chip
- Push direction is always **down**, never along travel (path-independence)
- Preview is a **shadow**: displaced blocks hold still until release
- Grid migration scales **edges**, not extents, so it provably cannot overlap
