# Dev workflow

Standard workflow rules for any change in this repo.

## Active surface: iOS only

Webapp work is paused (decision recorded 2026-05-03 — see `.claude/CLAUDE.md`). Don't auto-route iOS work to the server / web client unless the user explicitly asks.

## Local-first

- Never auto-deploy. The user runs the deploy step themselves.
- iOS is OTA via `bash mobile/ota/ship-lan.sh` → `xcrun devicectl device install app --device <UDID> /tmp/ota/app.ipa` over wifi. No more Tailscale dance for iOS — `ship.sh` is legacy.
- (Paused) Web client + Express server: `npm start` would bring up :5173 and :3000/:3001. Don't start it as part of an iOS task.

## Tests before declaring done

- iOS changes that touch behaviour (not just syntax) MUST be installed on a real device via `bash mobile/ota/ship-lan.sh` + `devicectl device install` before declaring done. Static checks (`xcodegen generate`, `xcodebuild build`) are NOT QA on iOS — see project memory `feedback_qa_framing.md`.
- (Paused) Server tests: `cd server && npm test` against `personal_dashboard_test`. Only run if the user asked for a server change.
- (Paused) Web frontend smoke at `http://localhost:5173`. Only run if the user asked for a web change.

## Commits link to issues

- Every change tied to a GitHub issue ends its commit message with `(#<issue>)` so the commit shows up under the issue's timeline. Example: `fix(ios): prompt for Local Network permission on launch (#13)`.
- Standalone commits (chore, docs, harness updates) don't need an issue ref — they're self-explanatory from the message.
- Commit message format: conventional-commits style — `feat(scope): …`, `fix(scope): …`, `chore(scope): …`, `docs(scope): …`. Scopes used in this repo: `server`, `client`, `mobile`, `ios`, `ota`, `capture`, `chat`, `claude`.

## Branching

- Application code (anything outside `.claude/` and `*.md` at repo root) MUST go through a feature branch + PR. Never push to `main` directly.
- Harness-only changes (`.claude/**`) and docs-only changes (top-level `*.md`) MAY commit straight to `main` — they're metadata, no functional risk, and the PR cycle adds friction without value.
- Branch names: `feat/<slug>`, `fix/<slug>`, `chore/<slug>`. Slug should match the issue's intent in 3-6 words.
- After merge, delete the branch (`gh pr merge --squash --delete-branch`).

## Secrets

- See `~/.claude/rules/no-secrets.md` (global). Same rules: never commit `.env`, never inline tokens in source. Use `*.env.example` templates.
