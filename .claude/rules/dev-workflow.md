# Dev workflow

Standard workflow rules for any change in this repo.

## Active surfaces: iOS + native macOS

Two native SwiftUI clients: the iOS app (`PersonalDashboard` target) and the macOS app (`DexterMac` target). Webapp work is paused (decision recorded 2026-05-03 — see `.claude/CLAUDE.md`). Don't auto-route native-app work to the server / web client unless the user explicitly asks.

When a shared file changes, build BOTH targets (iOS regression check) — see the macOS build commands in `.claude/CLAUDE.md`. When porting a surface to macOS, keep the iOS path byte-for-byte unchanged (`#if canImport(UIKit)` shims), and add the file to the curated `DexterMac` `sources:` list in `mobile/project.yml`.

## Local-first

- iOS: ship to the user's phone autonomously after a clean static build, via the `build-to-phone` skill (which invokes `bash mobile/ota/ship-lan.sh` + `xcrun devicectl device install app`). Do NOT pause to ask permission — the user has authorised this for every iOS feature in this repo (correction `AUTOSHIP_TO_PHONE`, 2026-05-10).
- macOS: build the `DexterMac` scheme and then **open the built app in front of the user yourself**, via `bash mobile/scripts/mac-open-for-verification.sh <section>`. This is the macOS counterpart of `build-to-phone` and carries the same autonomous authorisation: don't pause to ask, and never hand the user a path to `open` or tell them to run the scheme from Xcode (correction `OPEN_FOR_VERIFICATION`, 2026-07-28).
- (Paused) Web client + Express server: `npm start` would bring up :5173 and :3000/:3001. Don't start it as part of a native-app task.

## Order of operations for iOS features

1. Implement the change in the worktree.
2. `xcodegen generate` + `xcodebuild ... build` to confirm a clean static build.
3. **Ship to phone** via `build-to-phone` skill (autonomous, no permission prompt).
4. User does device QA on the surfaces touched.
5. Commit on the feature branch with `(#<issue>)` reference.
6. Push + open PR for review.

Static checks (`xcodegen generate`, `xcodebuild build`) are NOT QA on iOS — see project memory `feedback_qa_framing.md`. Device install is the precondition for QA; QA is the precondition for PR.

## Order of operations for macOS features

1. Implement the change; add any new shared files to the `DexterMac` `sources:` in `mobile/project.yml`.
2. `xcodegen generate`, then `xcodebuild -scheme DexterMac -destination 'platform=macOS' build` AND `xcodebuild -scheme PersonalDashboard -destination 'generic/platform=iOS' build` (no iOS regression).
3. Eyeball the touched surface yourself (screenshot QA where useful). To do this while the user's own instance is running, launch a second instance against a snapshot of their store rather than quitting theirs — see project memory `project_macos_agent_qa_constraints`. macOS SwiftUI ignores synthetic clicks on tap/gesture controls, so complete/edit/delete need a hands-on pass by the user; build-verified ≠ QA'd.
4. **Open it in front of the user**: `bash mobile/scripts/mac-open-for-verification.sh <section>`. Autonomous, no permission prompt. The script builds, quits the stale instance pid-scoped, launches THIS worktree's build on the real store with `LAUNCH_SECTION`, asserts the window title, and screenshots what is on screen.
5. Commit on the feature branch with `(#<issue>)` reference.
6. Push + open PR for review.

### The stale-instance trap (why step 4 is not optional)

The user runs DexterMac from Xcode against the **main** checkout, so their app binary lives in a different worktree's DerivedData. A branch built and screenshotted from a worktree therefore looks correct to the agent while the user's window still shows the old behaviour. The failure mode is the user reporting "I don't see it on the desktop app" on a change that is entirely fine, which costs a whole round trip and reads as a broken feature. `ls`-ing DerivedData paths is not a check anyone should have to do; step 4 closes it.

One caveat the script cannot resolve for you: quitting the running app discards in-memory state, and **Chat turns are not persisted**. If the user might be mid-conversation in Chat, say so in the same message rather than quitting silently.

## Tests before declaring done

- iOS changes that touch behaviour MUST land on the phone (step 3 above) before the feature is reported as done.
- macOS changes MUST build clean on the `DexterMac` scheme AND not regress the iOS build, AND be open on screen from this worktree's build (step 4 above) before being reported as done; flag any tap/gesture-control behaviour as pending the user's hands-on QA.
- (Paused) Server tests: `cd server && npm test` against `dexter_test`. Only run if the user asked for a server change.
- (Paused) Web frontend smoke at `http://localhost:5173`. Only run if the user asked for a web change.

## Commits link to issues

- Every change tied to a GitHub issue ends its commit message with `(#<issue>)` so the commit shows up under the issue's timeline. Example: `fix(ios): prompt for Local Network permission on launch (#13)`.
- Standalone commits (chore, docs, harness updates) don't need an issue ref — they're self-explanatory from the message.
- Commit message format: conventional-commits style — `feat(scope): …`, `fix(scope): …`, `chore(scope): …`, `docs(scope): …`. Scopes used in this repo: `server`, `client`, `mobile`, `ios`, `macos`, `ota`, `capture`, `chat`, `claude`.

## Branching

- Application code (anything outside `.claude/` and `*.md` at repo root) MUST go through a feature branch + PR. Never push to `main` directly.
- Harness-only changes (`.claude/**`) and docs-only changes (top-level `*.md`) MAY commit straight to `main` — they're metadata, no functional risk, and the PR cycle adds friction without value.
- Branch names: `feat/<slug>`, `fix/<slug>`, `chore/<slug>`. Slug should match the issue's intent in 3-6 words.
- After merge, delete the branch (`gh pr merge --squash --delete-branch`).

## Secrets

- See `~/.claude/rules/no-secrets.md` (global). Same rules: never commit `.env`, never inline tokens in source. Use `*.env.example` templates.
