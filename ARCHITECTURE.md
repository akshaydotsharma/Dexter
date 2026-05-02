# Architecture Documentation

## System Overview

The Personal Dashboard is a monorepo with three deliverables: a React web client, a Node.js/Express API, and a native SwiftUI iOS app. All three speak the same REST + SSE surface area on port 3000. Tasks, notes, and lists live in PostgreSQL; chat / AI drafts run on Anthropic Claude via the Vercel AI SDK.

```
personal-dashboard/
├── client/          # React frontend (web)
├── server/          # Express backend
├── mobile/          # Native iOS app (SwiftUI)
├── docs/            # Design references and screenshots
└── package.json     # Root scripts (concurrently runs client + server)
```

```mermaid
graph TD
    Web[React Client<br/>Port 5173] <--> API[Express API<br/>Port 3000]
    iOS[Native iOS App<br/>SwiftUI + URLSession SSE] <--> API
    API <--> DB[(PostgreSQL)]
    API <--> AI[Anthropic Claude<br/>via Vercel AI SDK]
```

## Frontend Architecture

The frontend is built with **React 19** using **Vite 7** as the build tool.

### Tech Stack
- **Framework**: React 19
- **Build Tool**: Vite 7
- **Styling**: Tailwind CSS 4 (utility-first)
- **UI Components**: MUI (Material-UI) for date pickers
- **Icons**: Lucide React
- **HTTP Client**: Axios
- **Date Handling**: date-fns, dayjs

### Directory Structure
```
client/src/
├── components/       # Reusable UI components
│   ├── Button.jsx
│   ├── Card.jsx
│   ├── Input.jsx
│   ├── Sidebar.jsx
│   ├── StatsCard.jsx
│   ├── DateTimePicker.jsx
│   ├── TodoWidget.jsx      # Task management widget
│   ├── NotesWidget.jsx     # Notes with folders widget
│   ├── ListsWidget.jsx     # Checklist widget
│   ├── ChatPopover.jsx     # AI chat interface
│   └── DashboardView.jsx
├── pages/            # Page-level components
│   └── LanguageInputPage.jsx
├── services/         # API service layer
│   └── api.js        # Axios API client
├── utils/            # Utility functions
├── App.jsx           # Main app with routing
├── main.jsx          # Entry point
└── index.css         # Global styles
```

### Key Components

#### TodoWidget
Full-featured task management with:
- Inline editing (title, description, tags)
- Due date picker with categorization (overdue, today, this week)
- Tag system with custom tags
- Completed tasks toggle
- Filter by tag

#### NotesWidget
Two-panel notes interface:
- Folder management (create, rename, delete)
- Notes within folders
- Inline editing for notes
- Mobile: Single panel with navigation
- Desktop: Side-by-side folders and notes

#### ListsWidget
Checklist/collection manager:
- Create lists with items
- Check/uncheck items
- Expandable list view

### Responsive Design
- **Mobile (<768px)**: Single column layout, hamburger menu, touch-optimized
- **Desktop (>=768px)**: Multi-column dashboard, sidebar navigation

## Backend Architecture

The backend is a **Node.js** application using **Express 5**.

### Tech Stack
- **Framework**: Express 5
- **Database**: PostgreSQL (via `pg` library)
- **AI Integration**: Anthropic Claude via `@ai-sdk/anthropic` (Vercel AI SDK). The active code path uses `ANTHROPIC_API_KEY`; legacy `OPENAI_API_KEY` only powers diagnostic scripts.
- **Streaming**: Server-Sent Events for chat (`/api/ai/parse/stream`).
- **Validation**: Zod for request schemas (preferences, reorder).
- **Hardening**: Helmet for headers, `express-rate-limit` per route group.
- **Environment**: dotenv for configuration

### Directory Structure
```
server/
├── index.js          # Main server file with all routes
├── db.js             # PostgreSQL connection pool
├── schema.sql        # Database schema
├── migration.sql     # Schema migrations
├── prompts/          # AI prompt templates
└── .env              # Environment variables
```

### API Design
RESTful API with the following endpoint groups:
- `/api/todos` - Task CRUD, including `PATCH /api/todos/:id/reorder`
- `/api/notes` - Note CRUD, including `PATCH /api/notes/:id/reorder` (supports cross-folder moves via optional `folder_id`)
- `/api/note-folders` - Folder management, including `PATCH /api/note-folders/:id/reorder`
- `/api/lists` - List CRUD, including `PATCH /api/lists/:id/reorder`
- `/api/stats` - Dashboard statistics
- `/api/dashboard/config` - Hydrates the full preferences object (widgets + theme + density + sidebar default + landing view) with defaults
- `/api/dashboard/config/preferences` - `PATCH` for partial preferences updates (Zod-validated, deep-merged)
- `/api/ai/parse` - Single-shot chat-to-drafts (LLM tool-call pipeline)
- `/api/ai/parse/stream` - SSE streaming variant (typewriter-style; consumed by both web and iOS clients)
- `/api/ai/execute` - Confirms a pending draft into a real entity

## Database Schema

### Core Tables

#### `todos`
| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL | Primary key |
| title | TEXT | Task title (required) |
| description | TEXT | Optional description |
| completed | BOOLEAN | Completion status |
| due_date | TIMESTAMP | Optional due date |
| tag | TEXT | Optional tag |
| created_at | TIMESTAMP | Creation timestamp |
| updated_at | TIMESTAMP | Last update timestamp |
| deleted_at | TIMESTAMP | Soft delete timestamp |

#### `note_folders`
| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL | Primary key |
| name | TEXT | Folder name (required) |
| created_at | TIMESTAMP | Creation timestamp |

#### `notes`
| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL | Primary key |
| folder_id | INTEGER | FK to note_folders |
| title | TEXT | Note title |
| content | TEXT | Note content |
| created_at | TIMESTAMP | Creation timestamp |
| updated_at | TIMESTAMP | Last update timestamp |

#### `lists`
| Column | Type | Description |
|--------|------|-------------|
| id | SERIAL | Primary key |
| title | TEXT | List title (required) |
| items | JSONB | Array of list items |
| created_at | TIMESTAMP | Creation timestamp |

### Audit Tables
- `todo_history` - Tracks all todo changes
- `note_history` - Tracks note and folder changes
- `list_history` - Tracks list changes

### Configuration
- `dashboard_config` - Stores `layout_preference` JSONB (widgets, theme, density, sidebar default, landing view, etc.). Always row id=1.

### Position columns (drag-to-reorder)
All four user-ordered tables (`todos`, `notes`, `lists`, `note_folders`) carry a nullable `position INTEGER`, backfilled with gap-1000 sequential values per scope (notes partition by `folder_id`; everything else global). Inserts append (`MAX(position) + 1000`); the `computeNewPosition` helper picks midpoints and renumbers when gaps collapse to <= 1.

## iOS Architecture

The iOS app lives in `mobile/PersonalDashboard/` and is structured as:

```
mobile/PersonalDashboard/
├── App/                # AppConfig (API base URL resolution)
├── Models/             # Codable structs (Draft, ChatRequest, etc.)
├── Services/           # API client, AIStreamingService (SSE consumer)
├── ViewModels/         # ChatViewModel, list view-models
├── Views/              # SwiftUI views (Today, Tasks, Lists, Notes, Chat, Settings)
└── Cache/              # Read-only on-disk cache for offline reads
```

The `.xcodeproj` is generated by `xcodegen` from `mobile/project.yml` and is gitignored — never edit it directly. SSE chat is read with `URLSession.AsyncBytes`; the parser flushes on a new `event:` header because `bytes.lines` collapses the blank-line delimiter.

### iOS distribution

Free personal-team development signing (7-day expiry). The OTA install pipeline at `mobile/ota/ship.sh` does the full archive + Cloudflare quick tunnel + `itms-services://` install in one shot. `AppConfig.swift` reads `API_URL` env var if set, else defaults to `http://localhost:3000/api`.

## Development Workflow

### Prerequisites
- Node.js >= 20.0.0
- PostgreSQL database
- Environment variables configured

### Running Locally
```bash
# Install all dependencies
npm run install:all

# Start both client and server in development mode
npm run dev
```

This runs:
- Frontend dev server on `http://localhost:5173`
- Backend API server on `http://localhost:3000`

### Building for Production
```bash
npm run build        # Build client
npm run start:prod   # Start production server
```

### Environment Variables
Copy the templates and fill in your own:
```bash
cp server/.env.example server/.env
cp client/.env.example client/.env   # optional
```

Minimum required in `server/.env`:
```
DATABASE_URL=postgresql://user:pass@host:5432/dbname
ANTHROPIC_API_KEY=sk-ant-...
PORT=3000
```

Both `.env` files are gitignored. Never commit real keys.

## Deployment

The application is configured for deployment on **Railway**:
- `.node-version` and `.nvmrc` specify Node 20
- `railway.json` contains deployment configuration
- Production build serves static files from `client/dist`

## Key Design Decisions

1. **Monorepo Structure**: Simplifies deployment and development
2. **Single index.js**: All routes in one file for simplicity (suitable for current scale)
3. **Soft Deletes**: Todos use `deleted_at` for data recovery
4. **Audit Logging**: History tables track all changes for debugging
5. **JSONB for Lists**: Flexible item storage without separate table
6. **Mobile-First Responsive**: Components adapt to screen size
