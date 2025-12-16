# Personal Dashboard API Documentation

## Base URL
- **Local Development:** `http://localhost:3000/api`
- **Production:** `https://your-railway-app.railway.app/api`

---

## Database Schema

### `todos` - Task Management
| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | SERIAL | Auto-increment | Primary key |
| `title` | TEXT | NOT NULL | Task title |
| `description` | TEXT | NULL | Optional task description |
| `completed` | BOOLEAN | FALSE | Whether task is completed |
| `due_date` | TIMESTAMP | NULL | Optional due date/time |
| `tag` | TEXT | NULL | Optional tag/category (e.g., "work", "personal") |
| `created_at` | TIMESTAMP | CURRENT_TIMESTAMP | Creation timestamp |
| `updated_at` | TIMESTAMP | CURRENT_TIMESTAMP | Last update timestamp |
| `deleted_at` | TIMESTAMP | NULL | Soft delete timestamp (NULL = active) |

### `todo_history` - Task Audit Log
| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | SERIAL | Auto-increment | Primary key |
| `todo_id` | INTEGER | NOT NULL | Reference to todo |
| `action` | TEXT | NOT NULL | Action type: `created`, `updated`, `completed`, `uncompleted`, `deleted`, `restored`, `permanently_deleted` |
| `field_changed` | TEXT | NULL | Field that was changed (NULL for create/delete) |
| `old_value` | TEXT | NULL | Previous value (NULL for create) |
| `new_value` | TEXT | NULL | New value (NULL for delete) |
| `timestamp` | TIMESTAMP | CURRENT_TIMESTAMP | When the action occurred (RFC 3339 format in responses) |

### `note_folders` - Note Organization
| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | SERIAL | Auto-increment | Primary key |
| `name` | TEXT | NOT NULL | Folder name |
| `created_at` | TIMESTAMP | CURRENT_TIMESTAMP | Creation timestamp |

### `notes` - Notes Storage
| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | SERIAL | Auto-increment | Primary key |
| `folder_id` | INTEGER | NULL | Foreign key to `note_folders` (CASCADE on delete) |
| `title` | TEXT | NULL | Note title |
| `content` | TEXT | NULL | Note content (supports markdown) |
| `created_at` | TIMESTAMP | CURRENT_TIMESTAMP | Creation timestamp |
| `updated_at` | TIMESTAMP | CURRENT_TIMESTAMP | Last update timestamp |

### `note_history` - Note & Folder Audit Log
| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | SERIAL | Auto-increment | Primary key |
| `note_id` | INTEGER | NOT NULL | Reference to note or folder (based on entity_type) |
| `entity_type` | TEXT | 'note' | Entity type: `note` or `folder` |
| `action` | TEXT | NOT NULL | Action type: `created`, `updated`, `deleted`, `moved` |
| `field_changed` | TEXT | NULL | Field that was changed (NULL for create/delete) |
| `old_value` | TEXT | NULL | Previous value (NULL for create) |
| `new_value` | TEXT | NULL | New value (NULL for delete) |
| `timestamp` | TIMESTAMP | CURRENT_TIMESTAMP | When the action occurred (RFC 3339 format in responses) |

### `lists` - Checklist Storage
| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | SERIAL | Auto-increment | Primary key |
| `title` | TEXT | NOT NULL | List title |
| `items` | JSONB | '[]' | Array of list items: `[{text: string, checked: boolean}]` |
| `created_at` | TIMESTAMP | CURRENT_TIMESTAMP | Creation timestamp |

### `list_history` - List Audit Log
| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | SERIAL | Auto-increment | Primary key |
| `list_id` | INTEGER | NOT NULL | Reference to list |
| `action` | TEXT | NOT NULL | Action type: `created`, `updated`, `deleted`, `item_added`, `item_removed`, `item_checked`, `item_unchecked` |
| `field_changed` | TEXT | NULL | Field that was changed |
| `old_value` | TEXT | NULL | Previous value |
| `new_value` | TEXT | NULL | New value |
| `timestamp` | TIMESTAMP | CURRENT_TIMESTAMP | When the action occurred (RFC 3339 format in responses) |

### `dashboard_config` - User Preferences
| Column | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | SERIAL | Auto-increment | Primary key (always 1 for single-user) |
| `layout_preference` | JSONB | NULL | Widget layout configuration |

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
| `OPENAI_API_KEY` | No | Required for AI parsing feature |
| `VITE_API_URL` | No | Client-side API URL override |
