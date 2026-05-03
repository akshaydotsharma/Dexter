# Dev workflow

Standard workflow rules for any change in this repo.

## Local-first

- Never auto-deploy. The user runs the deploy step themselves.
- Backend deploy is via Railway; frontend is served as static files from `client/dist` by the same Express process. iOS is OTA via `ship.sh` / `ship-lan.sh`.
- Dev server is `npm start` (runs server + client together via concurrently). Default ports: client `:5173`, server `:3000` (auto-falls-through to `:3001` if `:3000` is taken).

## Tests before declaring done

- Server changes MUST run `cd server && npm test` and pass before commit. Test DB is `personal_dashboard_test` (one-time `createdb personal_dashboard_test`).
- Frontend changes MUST be smoke-tested in the browser at `http://localhost:5173` before commit. Verify the golden path AND the surfaces around the change for regressions.
- iOS changes that touch behaviour (not just syntax) MUST be installed on a real device via `bash mobile/ota/ship-lan.sh` or `ship.sh` before declaring done. Static checks (`xcodegen generate`, type-check) are NOT QA on iOS — see project memory `feedback_qa_framing.md`.

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
