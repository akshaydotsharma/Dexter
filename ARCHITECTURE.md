# Architecture Documentation

## System Overview

The Personal Dashboard is a monorepo containing a client-server architecture. It provides a unified interface for managing tasks, notes, and lists with a responsive design that works on both desktop and mobile.

```
personal-dashboard/
├── client/          # React frontend
├── server/          # Express backend
├── package.json     # Root package with dev scripts
└── docs/            # Documentation
```

```mermaid
graph TD
    Client[React Client<br/>Port 5173] <--> API[Express API<br/>Port 3000]
    API <--> DB[(PostgreSQL)]
    API <--> AI[AI Services<br/>OpenAI/Gemini]
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
- **AI Integration**: OpenAI API, Google Gemini API
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
- `/api/todos` - Task CRUD operations
- `/api/notes` - Note CRUD operations
- `/api/note-folders` - Folder management
- `/api/lists` - List CRUD operations
- `/api/stats` - Dashboard statistics
- `/api/dashboard/config` - Widget visibility settings
- `/api/chat` - AI chat endpoint

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
- `dashboard_config` - Stores widget visibility preferences

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
Create `server/.env`:
```
DATABASE_URL=postgresql://user:pass@host:5432/dbname
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
```

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
