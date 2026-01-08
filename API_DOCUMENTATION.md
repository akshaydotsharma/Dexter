# Personal Dashboard API Documentation

## Base URL
- **Local Development:** `http://localhost:3000/api`
- **Production:** `https://your-railway-app.railway.app/api`

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CLIENT (React)                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ TodoWidget  │  │ NotesWidget │  │ ListsWidget │  │ Dashboard/Chatbot   │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘ │
│         │                │                │                     │            │
│         └────────────────┴────────────────┴─────────────────────┘            │
│                                   │                                          │
│                          api.js (Axios)                                      │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │ HTTP/REST
                                   ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                           SERVER (Express.js)                                │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                         API Routes                                    │   │
│  │  /api/todos    /api/notes    /api/lists    /api/stats    /api/ai     │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                   │                                          │
│                          db.js (pg Pool)                                     │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │ SQL Queries
                                   ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                         DATABASE (PostgreSQL)                                │
│                                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │    todos    │  │    notes    │  │    lists    │  │  dashboard_config   │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └─────────────────────┘ │
│         │                │                │                                  │
│  ┌──────┴──────┐  ┌──────┴──────┐  ┌──────┴──────┐                          │
│  │ todo_history│  │ note_history│  │ list_history│                          │
│  └─────────────┘  └─────────────┘  └─────────────┘                          │
│                          │                                                   │
│                   ┌──────┴──────┐                                            │
│                   │ note_folders│                                            │
│                   └─────────────┘                                            │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Database Schema

### Entity Relationship Diagram

```
┌─────────────────────┐
│       todos         │
├─────────────────────┤
│ PK id               │
│    title            │
│    description      │
│    completed        │
│    due_date         │
│    tag              │
│    created_at       │
│    updated_at       │
│    deleted_at       │
└──────────┬──────────┘
           │ 1:N
           ▼
┌─────────────────────┐
│    todo_history     │
├─────────────────────┤
│ PK id               │
│ FK todo_id          │
│    action           │
│    field_changed    │
│    old_value        │
│    new_value        │
│    timestamp        │
└─────────────────────┘


┌─────────────────────┐       ┌─────────────────────┐
│    note_folders     │       │       notes         │
├─────────────────────┤       ├─────────────────────┤
│ PK id               │◄──┐   │ PK id               │
│    name             │   │   │ FK folder_id ───────┘
│    created_at       │   │   │    title            │
└──────────┬──────────┘   │   │    content          │
           │              │   │    created_at       │
           │              │   │    updated_at       │
           │              │   └──────────┬──────────┘
           │              │              │
           │    1:N       │    1:N       │
           ▼              │              ▼
┌─────────────────────────┴──────────────────────────┐
│                   note_history                      │
├────────────────────────────────────────────────────┤
│ PK id                                              │
│    note_id (references notes.id OR note_folders.id)│
│    entity_type ('note' | 'folder')                 │
│    action                                          │
│    field_changed                                   │
│    old_value                                       │
│    new_value                                       │
│    timestamp                                       │
└────────────────────────────────────────────────────┘


┌─────────────────────┐
│       lists         │
├─────────────────────┤
│ PK id               │
│    title            │
│    items (JSONB)    │
│    created_at       │
└──────────┬──────────┘
           │ 1:N
           ▼
┌─────────────────────┐
│    list_history     │
├─────────────────────┤
│ PK id               │
│ FK list_id          │
│    action           │
│    field_changed    │
│    old_value        │
│    new_value        │
│    timestamp        │
└─────────────────────┘


┌─────────────────────┐
│  dashboard_config   │
├─────────────────────┤
│ PK id (always 1)    │
│    layout_preference│
└─────────────────────┘
```

---

## Table Descriptions

### Core Data Tables

| Table | Purpose | Records |
|-------|---------|---------|
| `todos` | Stores user tasks with due dates, tags, and soft-delete support | Active and deleted tasks |
| `notes` | Stores user notes with optional folder organization | All notes |
| `note_folders` | Organizes notes into folders/categories | Folder metadata |
| `lists` | Stores checklists with items as JSONB | All checklists |
| `dashboard_config` | Single-row table for user preferences | 1 row always |

### Audit/History Tables

| Table | Tracks | Purpose |
|-------|--------|---------|
| `todo_history` | All changes to `todos` | Audit trail for task changes |
| `note_history` | Changes to `notes` AND `note_folders` | Unified audit for notes system |
| `list_history` | All changes to `lists` | Audit trail for list changes |

---

## Detailed Table Schemas

### `todos` - Task Management

**Description:** Primary table for storing user tasks/todos. Supports soft-delete pattern where deleted tasks have `deleted_at` set instead of being permanently removed, allowing for task restoration.

**Relationships:**
- One-to-Many with `todo_history` (each todo can have multiple history entries)

| Column | Type | Default | Nullable | Description |
|--------|------|---------|----------|-------------|
| `id` | SERIAL | Auto-increment | NO | Primary key, unique identifier |
| `title` | TEXT | - | NO | Task title (required) |
| `description` | TEXT | NULL | YES | Optional detailed description |
| `completed` | BOOLEAN | FALSE | NO | Task completion status |
| `due_date` | TIMESTAMP | NULL | YES | Optional due date and time |
| `tag` | TEXT | NULL | YES | Category tag (e.g., "work", "personal", "urgent") |
| `created_at` | TIMESTAMP | CURRENT_TIMESTAMP | NO | When the task was created |
| `updated_at` | TIMESTAMP | CURRENT_TIMESTAMP | NO | Last modification time |
| `deleted_at` | TIMESTAMP | NULL | YES | Soft delete timestamp (NULL = active, set = deleted) |

**Indexes:** Primary key on `id`

**Example Row:**
```json
{
  "id": 1,
  "title": "Complete quarterly report",
  "description": "Include sales figures and projections",
  "completed": false,
  "due_date": "2025-12-20T17:00:00.000Z",
  "tag": "work",
  "created_at": "2025-12-15T10:30:00.000Z",
  "updated_at": "2025-12-16T14:22:00.000Z",
  "deleted_at": null
}
```

---

### `todo_history` - Task Audit Log

**Description:** Audit trail table that tracks all changes made to todos. Every create, update, delete, and restore action is logged with before/after values for complete change tracking.

**Relationships:**
- Many-to-One with `todos` (multiple history entries per todo)

| Column | Type | Default | Nullable | Description |
|--------|------|---------|----------|-------------|
| `id` | SERIAL | Auto-increment | NO | Primary key, unique identifier |
| `todo_id` | INTEGER | - | NO | Reference to the todo that was changed |
| `action` | TEXT | - | NO | Action type: `created`, `updated`, `completed`, `uncompleted`, `deleted`, `restored`, `permanently_deleted` |
| `field_changed` | TEXT | NULL | YES | Which field was modified (NULL for create/delete actions) |
| `old_value` | TEXT | NULL | YES | Previous value before change (NULL for create) |
| `new_value` | TEXT | NULL | YES | New value after change (NULL for delete) |
| `timestamp` | TIMESTAMP | CURRENT_TIMESTAMP | NO | When the action occurred |

**Indexes:** Primary key on `id`

**Action Types:**
| Action | Trigger | field_changed | old_value | new_value |
|--------|---------|---------------|-----------|-----------|
| `created` | New todo created | NULL | NULL | JSON of created todo |
| `updated` | Field modified | Field name | Old field value | New field value |
| `completed` | completed → true | `completed` | `false` | `true` |
| `uncompleted` | completed → false | `completed` | `true` | `false` |
| `deleted` | Soft delete | NULL | JSON of todo | NULL |
| `restored` | Restore from trash | NULL | NULL | JSON of restored todo |
| `permanently_deleted` | Hard delete | NULL | JSON of todo | NULL |

**Example Row:**
```json
{
  "id": 15,
  "todo_id": 3,
  "action": "completed",
  "field_changed": "completed",
  "old_value": "false",
  "new_value": "true",
  "timestamp": "2025-12-17T14:30:00Z"
}
```

### `note_folders` - Note Organization

**Description:** Organizational structure for grouping related notes. Folders provide a hierarchical way to categorize notes. Deleting a folder cascades to delete all notes within it.

**Relationships:**
- One-to-Many with `notes` (each folder can contain multiple notes)
- One-to-Many with `note_history` (folder changes are tracked via entity_type='folder')

| Column | Type | Default | Nullable | Description |
|--------|------|---------|----------|-------------|
| `id` | SERIAL | Auto-increment | NO | Primary key, unique identifier |
| `name` | TEXT | - | NO | Folder name (required, displayed in UI) |
| `created_at` | TIMESTAMP | CURRENT_TIMESTAMP | NO | When the folder was created |

**Indexes:** Primary key on `id`

**Cascade Behavior:** When a folder is deleted, all notes with that `folder_id` are also deleted (ON DELETE CASCADE).

**Example Row:**
```json
{
  "id": 1,
  "name": "Work Projects",
  "created_at": "2025-12-10T09:00:00.000Z"
}
```

### `notes` - Notes Storage

**Description:** Primary table for storing user notes. Notes can optionally belong to a folder for organization. Both title and content support free-form text, and content can include markdown formatting.

**Relationships:**
- Many-to-One with `note_folders` (each note can belong to one folder, or none)
- One-to-Many with `note_history` (note changes are tracked via entity_type='note')

| Column | Type | Default | Nullable | Description |
|--------|------|---------|----------|-------------|
| `id` | SERIAL | Auto-increment | NO | Primary key, unique identifier |
| `folder_id` | INTEGER | NULL | YES | Foreign key to `note_folders` (NULL = unfiled note) |
| `title` | TEXT | NULL | YES | Note title (optional, displayed in note list) |
| `content` | TEXT | NULL | YES | Note content body (supports markdown formatting) |
| `created_at` | TIMESTAMP | CURRENT_TIMESTAMP | NO | When the note was created |
| `updated_at` | TIMESTAMP | CURRENT_TIMESTAMP | NO | Last modification time |

**Indexes:** Primary key on `id`, Foreign key on `folder_id`

**Foreign Key Constraint:** `folder_id` REFERENCES `note_folders(id)` ON DELETE CASCADE

**Example Row:**
```json
{
  "id": 5,
  "folder_id": 1,
  "title": "Project Requirements",
  "content": "# Requirements\n\n## Must Have\n- User authentication\n- Dashboard view\n\n## Nice to Have\n- Dark mode",
  "created_at": "2025-12-12T11:00:00.000Z",
  "updated_at": "2025-12-16T15:45:00.000Z"
}
```

### `note_history` - Note & Folder Audit Log

**Description:** Unified audit trail table that tracks all changes made to both notes and folders. Uses the `entity_type` column to differentiate between note and folder history entries. This polymorphic design allows a single table to track history for the entire notes system.

**Relationships:**
- Many-to-One with `notes` (when entity_type='note')
- Many-to-One with `note_folders` (when entity_type='folder')

| Column | Type | Default | Nullable | Description |
|--------|------|---------|----------|-------------|
| `id` | SERIAL | Auto-increment | NO | Primary key, unique identifier |
| `note_id` | INTEGER | - | NO | Reference ID (note ID when entity_type='note', folder ID when entity_type='folder') |
| `entity_type` | TEXT | 'note' | NO | Discriminator: `note` or `folder` |
| `action` | TEXT | - | NO | Action type: `created`, `updated`, `deleted`, `moved` |
| `field_changed` | TEXT | NULL | YES | Which field was modified (NULL for create/delete) |
| `old_value` | TEXT | NULL | YES | Previous value before change (NULL for create) |
| `new_value` | TEXT | NULL | YES | New value after change (NULL for delete) |
| `timestamp` | TIMESTAMP | CURRENT_TIMESTAMP | NO | When the action occurred |

**Indexes:** Primary key on `id`

**Entity Type Values:**
| entity_type | note_id references | Tracked entity |
|-------------|-------------------|----------------|
| `note` | `notes.id` | Individual notes |
| `folder` | `note_folders.id` | Note folders |

**Action Types:**
| Action | Trigger | field_changed | old_value | new_value |
|--------|---------|---------------|-----------|-----------|
| `created` | New note/folder created | NULL | NULL | JSON of created entity |
| `updated` | Field modified | Field name | Old field value | New field value |
| `deleted` | Note/folder deleted | NULL | JSON of entity | NULL |
| `moved` | Note moved to different folder | `folder_id` | Old folder ID | New folder ID |

**Example Rows:**
```json
// Note history entry
{
  "id": 8,
  "note_id": 5,
  "entity_type": "note",
  "action": "updated",
  "field_changed": "content",
  "old_value": "Old content here",
  "new_value": "Updated content with more details",
  "timestamp": "2025-12-16T15:45:00Z"
}

// Folder history entry
{
  "id": 12,
  "note_id": 1,
  "entity_type": "folder",
  "action": "updated",
  "field_changed": "name",
  "old_value": "Work",
  "new_value": "Work Projects",
  "timestamp": "2025-12-17T09:30:00Z"
}
```

### `lists` - Checklist Storage

**Description:** Primary table for storing checklists/lists. Items within a list are stored as a JSONB array, allowing flexible item management without separate table joins. Each item has text content and a checked status for tracking completion.

**Relationships:**
- One-to-Many with `list_history` (list changes are tracked in history)

| Column | Type | Default | Nullable | Description |
|--------|------|---------|----------|-------------|
| `id` | SERIAL | Auto-increment | NO | Primary key, unique identifier |
| `title` | TEXT | - | NO | List title (required, displayed in list header) |
| `items` | JSONB | '[]' | NO | Array of list items with structure `[{text: string, checked: boolean}]` |
| `created_at` | TIMESTAMP | CURRENT_TIMESTAMP | NO | When the list was created |

**Indexes:** Primary key on `id`

**JSONB Items Structure:**
```json
[
  {"text": "Item description", "checked": false},
  {"text": "Completed item", "checked": true}
]
```

**Example Row:**
```json
{
  "id": 3,
  "title": "Weekly Groceries",
  "items": [
    {"text": "Milk", "checked": true},
    {"text": "Bread", "checked": true},
    {"text": "Eggs", "checked": false},
    {"text": "Cheese", "checked": false}
  ],
  "created_at": "2025-12-14T08:00:00.000Z"
}
```

### `list_history` - List Audit Log

**Description:** Audit trail table that tracks all changes made to lists, including list-level operations (create, update, delete) and item-level operations (add, remove, check, uncheck). Provides granular tracking of checklist modifications.

**Relationships:**
- Many-to-One with `lists` (multiple history entries per list)

| Column | Type | Default | Nullable | Description |
|--------|------|---------|----------|-------------|
| `id` | SERIAL | Auto-increment | NO | Primary key, unique identifier |
| `list_id` | INTEGER | - | NO | Reference to the list that was changed |
| `action` | TEXT | - | NO | Action type (see Action Types below) |
| `field_changed` | TEXT | NULL | YES | Which field was modified (NULL for create/delete) |
| `old_value` | TEXT | NULL | YES | Previous value before change (NULL for create) |
| `new_value` | TEXT | NULL | YES | New value after change (NULL for delete) |
| `timestamp` | TIMESTAMP | CURRENT_TIMESTAMP | NO | When the action occurred |

**Indexes:** Primary key on `id`

**Action Types:**
| Action | Trigger | field_changed | old_value | new_value |
|--------|---------|---------------|-----------|-----------|
| `created` | New list created | NULL | NULL | JSON of created list |
| `updated` | Title modified | `title` | Old title | New title |
| `deleted` | List deleted | NULL | JSON of list | NULL |
| `item_added` | New item added to list | `items` | NULL | Item text |
| `item_removed` | Item removed from list | `items` | Item text | NULL |
| `item_checked` | Item marked complete | `items` | Item text | `checked` |
| `item_unchecked` | Item unmarked | `items` | Item text | `unchecked` |

**Example Rows:**
```json
// List creation
{
  "id": 1,
  "list_id": 3,
  "action": "created",
  "field_changed": null,
  "old_value": null,
  "new_value": "{\"title\":\"Weekly Groceries\",\"items\":[]}",
  "timestamp": "2025-12-14T08:00:00Z"
}

// Item checked
{
  "id": 5,
  "list_id": 3,
  "action": "item_checked",
  "field_changed": "items",
  "old_value": "Milk",
  "new_value": "checked",
  "timestamp": "2025-12-15T10:30:00Z"
}
```

### `dashboard_config` - User Preferences

**Description:** Single-row configuration table storing user preferences for the dashboard. Currently stores widget layout order. Designed as a singleton table where id=1 always exists and is the only row.

**Relationships:**
- None (standalone configuration table)

| Column | Type | Default | Nullable | Description |
|--------|------|---------|----------|-------------|
| `id` | SERIAL | Auto-increment | NO | Primary key (always 1 for single-user app) |
| `layout_preference` | JSONB | NULL | YES | Widget layout and order configuration |

**Indexes:** Primary key on `id`

**Singleton Pattern:** This table always contains exactly one row with `id=1`. The schema includes an INSERT statement that creates this row if it doesn't exist.

**JSONB layout_preference Structure:**
```json
{
  "widgets": ["todos", "notes", "lists"]
}
```
- `widgets`: Array of widget identifiers in display order

**Example Row:**
```json
{
  "id": 1,
  "layout_preference": {
    "widgets": ["notes", "todos", "lists"]
  }
}
```

---

## API Endpoints

### Todos

#### `GET /api/todos`
Retrieve all active (non-deleted) todos.

**Response:** `200 OK`
```json
[
  {
    "id": 1,
    "title": "Complete project",
    "description": "Finish the dashboard",
    "completed": false,
    "due_date": "2025-12-20T10:00:00.000Z",
    "tag": "work",
    "created_at": "2025-12-17T08:00:00.000Z",
    "updated_at": "2025-12-17T08:00:00.000Z",
    "deleted_at": null
  }
]
```

#### `POST /api/todos`
Create a new todo.

**Request Body:**
```json
{
  "title": "New task",
  "description": "Optional description",
  "due_date": "2025-12-20T10:00:00.000Z",
  "tag": "personal"
}
```

**Response:** `201 Created`
```json
{
  "id": 2,
  "title": "New task",
  "description": "Optional description",
  "completed": false,
  "due_date": "2025-12-20T10:00:00.000Z",
  "tag": "personal",
  "created_at": "2025-12-17T09:00:00.000Z",
  "updated_at": "2025-12-17T09:00:00.000Z",
  "deleted_at": null
}
```

#### `PUT /api/todos/:id`
Update an existing todo. Only provided fields are updated.

**Request Body:**
```json
{
  "title": "Updated title",
  "description": "Updated description",
  "completed": true,
  "due_date": "2025-12-25T10:00:00.000Z",
  "tag": "urgent"
}
```

**Response:** `200 OK` - Returns updated todo object

#### `DELETE /api/todos/:id`
Soft delete a todo (sets `deleted_at` timestamp).

**Query Parameters:**
- `permanent=true` - Permanently delete the todo

**Response:** `204 No Content`

#### `POST /api/todos/:id/restore`
Restore a soft-deleted todo.

**Response:** `200 OK` - Returns restored todo object

#### `GET /api/todos/:id/history`
Get history for a specific todo.

**Response:** `200 OK`
```json
[
  {
    "id": 1,
    "todo_id": 1,
    "action": "completed",
    "field_changed": "completed",
    "old_value": "false",
    "new_value": "true",
    "timestamp": "2025-12-17T10:00:00Z"
  }
]
```

#### `GET /api/todo-history`
Get all todo history entries.

**Query Parameters:**
- `limit` (default: 50) - Maximum number of entries to return

**Response:** `200 OK`
```json
[
  {
    "id": 1,
    "todo_id": 1,
    "action": "created",
    "field_changed": null,
    "old_value": null,
    "new_value": "{\"title\":\"New task\"}",
    "timestamp": "2025-12-17T10:00:00Z",
    "todo_title": "New task"
  }
]
```

---

### Note Folders

#### `GET /api/note-folders`
Get all note folders.

**Response:** `200 OK`
```json
[
  {
    "id": 1,
    "name": "Work Notes",
    "created_at": "2025-12-17T08:00:00.000Z"
  }
]
```

#### `POST /api/note-folders`
Create a new folder.

**Request Body:**
```json
{
  "name": "Personal"
}
```

**Response:** `201 Created`

#### `PUT /api/note-folders/:id`
Rename a folder.

**Request Body:**
```json
{
  "name": "New Folder Name"
}
```

**Response:** `200 OK`

#### `DELETE /api/note-folders/:id`
Delete a folder (cascades to delete all notes in folder).

**Response:** `204 No Content`

---

### Notes

#### `GET /api/notes`
Get all notes, optionally filtered by folder.

**Query Parameters:**
- `folder_id` - Filter by folder ID

**Response:** `200 OK`
```json
[
  {
    "id": 1,
    "folder_id": 1,
    "title": "Meeting Notes",
    "content": "# Meeting Notes\n\n- Item 1\n- Item 2",
    "created_at": "2025-12-17T08:00:00.000Z",
    "updated_at": "2025-12-17T09:00:00.000Z"
  }
]
```

#### `POST /api/notes`
Create a new note.

**Request Body:**
```json
{
  "title": "New Note",
  "content": "Note content here",
  "folder_id": 1
}
```

**Response:** `201 Created`

#### `PUT /api/notes/:id`
Update a note.

**Request Body:**
```json
{
  "title": "Updated Title",
  "content": "Updated content",
  "folder_id": 2
}
```

**Response:** `200 OK`

#### `DELETE /api/notes/:id`
Delete a note.

**Response:** `204 No Content`

#### `GET /api/notes/:id/history`
Get history for a specific note.

**Response:** `200 OK`
```json
[
  {
    "id": 1,
    "note_id": 1,
    "entity_type": "note",
    "action": "updated",
    "field_changed": "title",
    "old_value": "Old Title",
    "new_value": "New Title",
    "timestamp": "2025-12-17T10:00:00Z"
  }
]
```

#### `GET /api/note-history`
Get all note and folder history entries.

**Query Parameters:**
- `limit` (default: 50) - Maximum number of entries to return

**Response:** `200 OK`
```json
[
  {
    "id": 1,
    "note_id": 1,
    "entity_type": "note",
    "action": "created",
    "field_changed": null,
    "old_value": null,
    "new_value": "{\"title\":\"New Note\"}",
    "timestamp": "2025-12-17T10:00:00Z",
    "note_title": "New Note"
  },
  {
    "id": 2,
    "note_id": 1,
    "entity_type": "folder",
    "action": "created",
    "field_changed": null,
    "old_value": null,
    "new_value": "{\"name\":\"Work\"}",
    "timestamp": "2025-12-17T09:00:00Z",
    "note_title": "Work"
  }
]
```

---

### Lists

#### `GET /api/lists`
Get all lists.

**Response:** `200 OK`
```json
[
  {
    "id": 1,
    "title": "Shopping List",
    "items": [
      {"text": "Milk", "checked": false},
      {"text": "Bread", "checked": true}
    ],
    "created_at": "2025-12-17T08:00:00.000Z"
  }
]
```

#### `POST /api/lists`
Create a new list.

**Request Body:**
```json
{
  "title": "Grocery List",
  "items": [
    {"text": "Eggs", "checked": false},
    {"text": "Butter", "checked": false}
  ]
}
```

**Response:** `201 Created`

#### `PUT /api/lists/:id`
Update a list.

**Request Body:**
```json
{
  "title": "Updated List Title",
  "items": [
    {"text": "Item 1", "checked": true},
    {"text": "Item 2", "checked": false}
  ]
}
```

**Response:** `200 OK`

#### `DELETE /api/lists/:id`
Delete a list.

**Response:** `204 No Content`

#### `GET /api/lists/:id/history`
Get history for a specific list.

**Response:** `200 OK`

#### `GET /api/list-history`
Get all list history entries.

**Query Parameters:**
- `limit` (default: 50) - Maximum number of entries to return

**Response:** `200 OK`
```json
[
  {
    "id": 1,
    "list_id": 1,
    "action": "item_checked",
    "field_changed": "items",
    "old_value": "Buy groceries",
    "new_value": "checked",
    "timestamp": "2025-12-17T10:00:00Z",
    "list_title": "Shopping List"
  }
]
```

---

### Dashboard

#### `GET /api/stats`
Get dashboard statistics with weekly trends.

**Response:** `200 OK`
```json
{
  "todos": {
    "total": 15,
    "trend": 20
  },
  "notes": {
    "total": 8,
    "trend": -10
  },
  "lists": {
    "total": 5,
    "trend": 0
  }
}
```

- `total` - Total count of items
- `trend` - Percentage change compared to previous week

#### `GET /api/config`
Get dashboard configuration.

**Response:** `200 OK`
```json
{
  "id": 1,
  "layout_preference": {
    "widgets": ["todos", "notes", "lists"]
  }
}
```

#### `PUT /api/config`
Update dashboard configuration.

**Request Body:**
```json
{
  "layout_preference": {
    "widgets": ["notes", "todos", "lists"]
  }
}
```

**Response:** `200 OK`

---

### AI Assistant

#### `POST /api/ai/parse`
Parse natural language input to create todos, notes, or lists.

**Request Body:**
```json
{
  "input": "Remind me to call mom tomorrow at 3pm"
}
```

**Response:** `200 OK`
```json
{
  "success": true,
  "action": "CREATE_TODO",
  "message": "Created todo: \"Call mom\"",
  "data": {
    "id": 5,
    "title": "Call mom",
    "due_date": "2025-12-18T15:00:00.000Z"
  },
  "parsed": {
    "title": "Call mom",
    "due_date": "2025-12-18T15:00:00.000Z"
  }
}
```

**Supported Actions:**
- `CREATE_TODO` - Creates a new task
- `CREATE_NOTE` - Creates a new note
- `CREATE_LIST` - Creates a new checklist
- `UNKNOWN` - Could not parse intent

---

## Error Responses

All endpoints return errors in the following format:

**Response:** `4xx/5xx`
```json
{
  "error": "Error message description"
}
```

Common HTTP Status Codes:
- `400 Bad Request` - Invalid request body
- `404 Not Found` - Resource not found
- `500 Internal Server Error` - Server-side error

---

## Timestamp Format

All timestamps in history endpoints are returned in **RFC 3339** format:
```
YYYY-MM-DDTHH:MM:SSZ
```
Example: `2025-12-17T10:30:00Z`

---

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | Yes | PostgreSQL connection string |
| `PORT` | No | Server port (default: 3000) |
| `NODE_ENV` | No | Environment: `development` or `production` |
| `ANTHROPIC_API_KEY` | No | Required for AI parsing feature (Claude) |
| `VITE_API_URL` | No | Client-side API URL override |
