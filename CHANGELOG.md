# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-05-03

### Added
- **Native iOS app** (`mobile/`): SwiftUI client with Today, Tasks, Lists, Notes, Chat, and Settings screens. Drag-to-reorder list items, full-screen note detail, read-only offline cache, OTA install pipeline (`mobile/ota/ship.sh`) using a Cloudflare quick tunnel + `itms-services://` install for free personal-team distribution.
- **Streaming chat (SSE)**: `POST /api/ai/parse/stream` emits a typewriter-style stream of `drafts` then `text` chunks then `done`. Both web and iOS clients consume the same wire format.
- **Drag-to-reorder backend**: `PATCH /api/{todos,notes,lists,note_folders}/:id/reorder` with a shared `computeNewPosition` helper, gap-1000 sequential `position INTEGER` columns, and concurrent-safe transactions (`SELECT ... FOR UPDATE`).
- **Preferences API**: `GET /api/dashboard/config` hydrates the full preferences object with defaults; `PATCH /api/dashboard/config/preferences` accepts partial updates, validates with Zod, and deep-merges so unrelated keys (like `widgets`) survive partial writes.
- **Web chat surfaces v2**: paper bubbles, SuccessRow component, `useChat` hook, Editorial Calm design tokens.
- **Notes "All Notes" view** surfaces unfiled notes; creating from that view leaves the note unfiled.
- **Server tests**: `server/tests/` with `node --test` against a dedicated `dexter_test` database. Helpers + migration + reorder + preferences specs.

### Changed
- **AI provider switched from OpenAI to Anthropic Claude** via `@ai-sdk/anthropic`. `ANTHROPIC_API_KEY` is now required; legacy `OPENAI_API_KEY` only powers diagnostic scripts.
- **Repo hygiene**: `server/.env.example` rewritten for the Anthropic stack; `client/.env.example` added; README has a real getting-started section. Both `.env` files stay gitignored.
- **iOS API URL** defaults to `http://localhost:3000/api` (was a personal Cloudflare tunnel). The `API_URL` env-var override is preserved for physical-device builds.

### Fixed
- **iOS SSE parser** was stuck because `URLSession.AsyncBytes.lines` collapses consecutive newlines, so the blank-line SSE delimiter never arrived and events were never dispatched. Now flushes when a new `event:` header arrives while data is buffered.
- **iOS Draft decoding** silently dropped every draft because the server emits the payload under `data` while the Swift struct expected `draftData` (mapped to `draft_data` after snake_case conversion). Added explicit `CodingKeys` on `Draft`.

## [1.0.0] - 2025-12-17

### Added
- **Dashboard**: Main dashboard view with stats tiles and widget grid
- **Tasks (TodoWidget)**: Full task management with inline editing, due dates, tags, filtering, and completion tracking
- **Notes (NotesWidget)**: Two-panel notes interface with folder organization
- **Lists (ListsWidget)**: Checklist manager with expandable items
- **AI Assistant**: Chat interface with OpenAI/Gemini integration
- **Responsive Design**: Mobile-first design with hamburger menu and touch-optimized interfaces
- **Audit Logging**: History tables tracking all changes to todos, notes, and lists
- **Soft Deletes**: Todos support soft deletion for data recovery
- **Stats Overview**: Dashboard statistics showing totals and trends
- **Widget Visibility**: Configurable widget display on dashboard
- **Version Display**: App version shown in sidebar

### Technical
- React 19 with Vite 7 build system
- Express 5 backend with PostgreSQL database
- Tailwind CSS 4 for styling
- MUI components for date pickers
- Railway deployment configuration
- Node.js 20+ requirement

## [0.1.0] - 2025-12-10

### Added
- Initial project setup with React (Client) and Express (Server).
- Basic README.md and ARCHITECTURE.md documentation.
- Project structure scaffolding.
