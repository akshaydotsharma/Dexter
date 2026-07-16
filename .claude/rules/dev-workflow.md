# Dev workflow

Standard workflow rules for any change in this repo.

## Active surfaces: iOS + native macOS

Two native SwiftUI clients: the iOS app (`PersonalDashboard` target) and the macOS app (`DexterMac` target). Webapp work is paused (decision recorded 2026-05-03 — see `.claude/CLAUDE.md`). Don't auto-route native-app work to the server / web client unless the user explicitly asks.

When a shared file changes, build BOTH targets (iOS regression check) — see the macOS build commands in `.claude/CLAUDE.md`. When porting a surface to macOS, keep the iOS path byte-for-byte unchanged (`#if canImport(UIKit)` shims), and add the file to the curated `DexterMac` `sources:` list in `mobile/project.yml`.

## Local-first

- iOS: ship to the user's phone autonomously after a clean static build, via the `build-to-phone` skill (which invokes `bash mobile/ota/ship-lan.sh` + `xcrun devicectl device install app`). Do NOT pause to ask permission — the user has authorised this for every iOS feature in this repo (correction `AUTOSHIP_TO_PHONE`, 2026-05-10).
- macOS: build the `DexterMac` scheme and hand off for the user to run from Xcode. No autonomous "ship" step (it's run locally from Xcode, not installed over a wire).
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
3. Launch and eyeball the touched surface (screenshot QA where useful). Note: macOS SwiftUI ignores synthetic clicks on tap/gesture controls, so complete/edit/delete need a hands-on pass by the user — build-verified ≠ QA'd.
4. Commit on the feature branch with `(#<issue>)` reference.
5. Push + open PR for review.

## Tests before declaring done

- iOS changes that touch behaviour MUST land on the phone (step 3 above) before the feature is reported as done.
- macOS changes MUST build clean on the `DexterMac` scheme AND not regress the iOS build before being reported as done; flag any tap/gesture-control behaviour as pending the user's hands-on QA.
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
