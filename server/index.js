const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '.env') });


const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const db = require('./db');
const fs = require('fs');

// v2.0 AI modules
const { chatToDrafts } = require('./ai/chatToDrafts');
const draftStore = require('./ai/draftStore');

// v2 refactor helpers
const { z } = require('zod');
const { computeNewPosition } = require('./reorderHelpers');
const { mountSyncRoutes } = require('./sync');
const {
    DEFAULT_PREFERENCES,
    DEFAULT_WIDGETS,
    preferencesPatchSchema,
    deepMerge,
    hydrateLayoutPreference,
} = require('./preferences');

const app = express();
const PORT = process.env.PORT || 3000;

// =============================================================================
// SECURITY MIDDLEWARE
// =============================================================================

// Security headers with Helmet
app.use(helmet({
    contentSecurityPolicy: {
        directives: {
            defaultSrc: ["'self'"],
            scriptSrc: ["'self'", "'unsafe-inline'"],
            styleSrc: ["'self'", "'unsafe-inline'"],
            imgSrc: ["'self'", "data:", "https:"],
            connectSrc: ["'self'"],
        },
    },
    crossOriginEmbedderPolicy: false, // Disable for development compatibility
}));

// CORS configuration - restrict to known origins
const allowedOrigins = [
    'http://localhost:5173',      // Vite dev server
    'http://localhost:3000',      // Production server
    'http://127.0.0.1:5173',
    'http://127.0.0.1:3000',
];

// Add production URL if configured
if (process.env.FRONTEND_URL) {
    allowedOrigins.push(process.env.FRONTEND_URL);
}

app.use(cors({
    origin: function (origin, callback) {
        // Allow requests with no origin (same-origin requests, mobile apps, curl)
        if (!origin) {
            return callback(null, true);
        }
        if (allowedOrigins.includes(origin)) {
            return callback(null, true);
        }
        // In production, also allow the platform domains
        if (process.env.NODE_ENV === 'production') {
            if (origin.includes('.up.railway.app') || origin.includes('.onrender.com')) {
                return callback(null, true);
            }
        }
        callback(new Error('Not allowed by CORS'));
    },
    credentials: true,
    optionsSuccessStatus: 200
}));

// Rate limiting - general API limiter
const apiLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 200, // limit each IP to 200 requests per windowMs
    message: { error: 'Too many requests from this IP, please try again later' },
    standardHeaders: true,
    legacyHeaders: false,
});

// Stricter rate limiter for AI endpoints (prevent cost explosion)
const aiLimiter = rateLimit({
    windowMs: 60 * 1000, // 1 minute
    max: 15, // 15 requests per minute
    message: { error: 'AI request limit exceeded. Please wait before trying again.' },
    standardHeaders: true,
    legacyHeaders: false,
});

// Apply rate limiting to all API routes
app.use('/api', apiLimiter);

// Apply stricter rate limiting to AI endpoints
app.use('/api/ai', aiLimiter);

// Request body size limit (prevent large payload attacks)
app.use(express.json({ limit: '1mb' }));

// =============================================================================
// ERROR HANDLING HELPERS
// =============================================================================

/**
 * Safe error response - hides internal details in production
 * @param {Response} res - Express response object
 * @param {Error} err - Error object
 * @param {number} statusCode - HTTP status code (default 500)
 */
const sendErrorResponse = (res, err, statusCode = 500) => {
    // Log the full error for debugging
    console.error(`[ERROR ${statusCode}]:`, err.message, process.env.NODE_ENV !== 'production' ? err.stack : '');

    // In production, hide internal error details
    const message = process.env.NODE_ENV === 'production'
        ? 'An internal server error occurred'
        : err.message;

    res.status(statusCode).json({ error: message });
};

// Serve static files from React build in production
if (process.env.NODE_ENV === 'production') {
    app.use(express.static(path.join(__dirname, '../client/dist')));
}

// Initialize Database Schema
// schema.sql is the canonical fresh install; migration.sql is the cumulative
// idempotent diff applied on top so existing DBs pick up new columns/triggers
// without manual intervention. Both files must be safe to re-run on every boot.
const initDb = async () => {
    try {
        const schema = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');
        await db.query(schema);
        const migration = fs.readFileSync(path.join(__dirname, 'migration.sql'), 'utf8');
        await db.query(migration);
        console.log('Database initialized successfully');
    } catch (err) {
        console.error('Error initializing database:', err);
    }
};

// Mount sync routes (iOS local-first data layer, #14). These live in their
// own module to keep the wire format isolated from the legacy CRUD endpoints.
mountSyncRoutes(app, db);

// API Routes

// Helper function to log todo history
const logTodoHistory = async (todoId, action, fieldChanged = null, oldValue = null, newValue = null) => {
    console.log(`[HISTORY] Logging todo history: todoId=${todoId}, action=${action}`);
    try {
        const result = await db.query(
            'INSERT INTO todo_history (todo_id, action, field_changed, old_value, new_value) VALUES ($1, $2, $3, $4, $5) RETURNING id',
            [todoId, action, fieldChanged, oldValue, newValue]
        );
        console.log(`[HISTORY] Todo history logged successfully, id=${result.rows[0]?.id}`);
    } catch (err) {
        console.error('[HISTORY] Error logging todo history:', err.message, err.stack);
    }
};

// Helper function to log note history (supports both notes and folders)
const logNoteHistory = async (entityId, action, fieldChanged = null, oldValue = null, newValue = null, entityType = 'note') => {
    console.log(`[HISTORY] Logging ${entityType} history: id=${entityId}, action=${action}`);
    try {
        const result = await db.query(
            'INSERT INTO note_history (note_id, entity_type, action, field_changed, old_value, new_value) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id',
            [entityId, entityType, action, fieldChanged, oldValue, newValue]
        );
        console.log(`[HISTORY] ${entityType} history logged successfully, id=${result.rows[0]?.id}`);
    } catch (err) {
        console.error(`[HISTORY] Error logging ${entityType} history:`, err.message, err.stack);
    }
};

// Helper function to log list history
const logListHistory = async (listId, action, fieldChanged = null, oldValue = null, newValue = null) => {
    console.log(`[HISTORY] Logging list history: listId=${listId}, action=${action}`);
    try {
        const result = await db.query(
            'INSERT INTO list_history (list_id, action, field_changed, old_value, new_value) VALUES ($1, $2, $3, $4, $5) RETURNING id',
            [listId, action, fieldChanged, oldValue, newValue]
        );
        console.log(`[HISTORY] List history logged successfully, id=${result.rows[0]?.id}`);
    } catch (err) {
        console.error('[HISTORY] Error logging list history:', err.message, err.stack);
    }
};

// TODOS
app.get('/api/todos', async (req, res) => {
    try {
        const { rows } = await db.query('SELECT * FROM todos WHERE deleted_at IS NULL ORDER BY created_at DESC');
        res.json(rows);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Get todo history
app.get('/api/todos/:id/history', async (req, res) => {
    try {
        const { id } = req.params;
        const { rows } = await db.query(
            `SELECT id, todo_id, action, field_changed, old_value, new_value,
                    to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as timestamp
             FROM todo_history WHERE todo_id = $1 ORDER BY timestamp DESC`,
            [id]
        );
        res.json(rows);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Get all todo history (for dashboard/analytics)
app.get('/api/todo-history', async (req, res) => {
    try {
        const { limit = 50 } = req.query;
        const { rows } = await db.query(
            `SELECT h.id, h.todo_id, h.action, h.field_changed, h.old_value, h.new_value,
                    to_char(h.timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as timestamp,
                    t.title as todo_title
             FROM todo_history h
             LEFT JOIN todos t ON h.todo_id = t.id
             ORDER BY h.timestamp DESC
             LIMIT $1`,
            [parseInt(limit)]
        );
        res.json(rows);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.post('/api/todos', async (req, res) => {
    try {
        const { title, description, due_date, tag } = req.body;
        // New rows go to the bottom of the global active-todos scope.
        // COALESCE(MAX(...), 0) handles the empty-table case.
        const { rows } = await db.query(
            `INSERT INTO todos (title, description, due_date, tag, position)
             VALUES ($1, $2, $3, $4,
                     (SELECT COALESCE(MAX(position), 0) + 1000 FROM todos WHERE deleted_at IS NULL))
             RETURNING *`,
            [title, description || null, due_date || null, tag || null]
        );
        const todo = rows[0];

        // Log creation
        await logTodoHistory(todo.id, 'created', null, null, JSON.stringify({ title, description, due_date, tag }));

        res.status(201).json(todo);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.put('/api/todos/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { title, description, completed, due_date, tag } = req.body;

        // Get current todo state for history logging
        const { rows: currentRows } = await db.query('SELECT * FROM todos WHERE id = $1', [id]);
        if (currentRows.length === 0) {
            return res.status(404).json({ error: 'Todo not found' });
        }
        const currentTodo = currentRows[0];

        // Build dynamic update query based on provided fields
        const updates = ['updated_at = CURRENT_TIMESTAMP'];
        const values = [];
        let paramCount = 1;
        const changes = [];

        if (title !== undefined && title !== currentTodo.title) {
            updates.push(`title = $${paramCount++}`);
            values.push(title);
            changes.push({ field: 'title', old: currentTodo.title, new: title });
        }
        if (description !== undefined && description !== currentTodo.description) {
            updates.push(`description = $${paramCount++}`);
            values.push(description);
            changes.push({ field: 'description', old: currentTodo.description, new: description });
        }
        if (completed !== undefined && completed !== currentTodo.completed) {
            updates.push(`completed = $${paramCount++}`);
            values.push(completed);
            changes.push({ field: 'completed', old: currentTodo.completed, new: completed });
        }
        if (due_date !== undefined) {
            const oldDueDate = currentTodo.due_date ? currentTodo.due_date.toISOString() : null;
            if (due_date !== oldDueDate) {
                updates.push(`due_date = $${paramCount++}`);
                values.push(due_date);
                changes.push({ field: 'due_date', old: oldDueDate, new: due_date });
            }
        }
        if (tag !== undefined && tag !== currentTodo.tag) {
            updates.push(`tag = $${paramCount++}`);
            values.push(tag);
            changes.push({ field: 'tag', old: currentTodo.tag, new: tag });
        }

        if (values.length === 0) {
            return res.json(currentTodo); // No actual changes
        }

        values.push(id);
        const query = `UPDATE todos SET ${updates.join(', ')} WHERE id = $${paramCount} RETURNING *`;
        const { rows } = await db.query(query, values);

        // Log each change to history
        for (const change of changes) {
            let action = 'updated';
            if (change.field === 'completed') {
                action = change.new ? 'completed' : 'uncompleted';
            }
            await logTodoHistory(
                parseInt(id),
                action,
                change.field,
                change.old !== null ? String(change.old) : null,
                change.new !== null ? String(change.new) : null
            );
        }

        res.json(rows[0]);
    } catch (err) {
        console.error('Error updating todo:', err);
        sendErrorResponse(res, err);
    }
});

app.delete('/api/todos/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { permanent } = req.query;

        if (permanent === 'true') {
            // Permanent delete
            await db.query('DELETE FROM todos WHERE id = $1', [id]);
            await logTodoHistory(parseInt(id), 'permanently_deleted');
        } else {
            // Soft delete
            await db.query('UPDATE todos SET deleted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE id = $1', [id]);
            await logTodoHistory(parseInt(id), 'deleted');
        }

        res.status(204).send();
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Restore a soft-deleted todo
app.post('/api/todos/:id/restore', async (req, res) => {
    try {
        const { id } = req.params;
        const { rows } = await db.query(
            'UPDATE todos SET deleted_at = NULL, updated_at = CURRENT_TIMESTAMP WHERE id = $1 RETURNING *',
            [id]
        );

        if (rows.length === 0) {
            return res.status(404).json({ error: 'Todo not found' });
        }

        await logTodoHistory(parseInt(id), 'restored');
        res.json(rows[0]);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// NOTE FOLDERS
app.get('/api/note-folders', async (req, res) => {
    try {
        const { rows } = await db.query(
            'SELECT * FROM note_folders WHERE deleted_at IS NULL ORDER BY created_at DESC'
        );
        res.json(rows);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.post('/api/note-folders', async (req, res) => {
    try {
        const { name } = req.body;
        const { rows } = await db.query(
            `INSERT INTO note_folders (name, position)
             VALUES ($1, (SELECT COALESCE(MAX(position), 0) + 1000 FROM note_folders WHERE deleted_at IS NULL))
             RETURNING *`,
            [name]
        );
        const folder = rows[0];

        // Log folder creation
        await logNoteHistory(folder.id, 'created', null, null, JSON.stringify({ name }), 'folder');

        res.status(201).json(folder);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.put('/api/note-folders/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { name } = req.body;

        // Get current folder for history
        const { rows: currentRows } = await db.query('SELECT * FROM note_folders WHERE id = $1', [id]);
        const oldName = currentRows.length > 0 ? currentRows[0].name : null;

        const { rows } = await db.query('UPDATE note_folders SET name = $1 WHERE id = $2 RETURNING *', [name, id]);

        // Log folder rename
        if (oldName !== name) {
            await logNoteHistory(parseInt(id), 'updated', 'name', oldName, name, 'folder');
        }

        res.json(rows[0]);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.delete('/api/note-folders/:id', async (req, res) => {
    try {
        const { id } = req.params;

        // Get folder name before deletion
        const { rows: folderRows } = await db.query('SELECT name FROM note_folders WHERE id = $1', [id]);
        const folderName = folderRows.length > 0 ? folderRows[0].name : null;

        // Soft-delete the folder AND any notes inside it. Cascading the
        // soft-delete to children means the iOS sync engine receives a
        // tombstone per note, so local state correctly removes the whole
        // subtree without orphaned references.
        await db.withTransaction(async (client) => {
            await client.query(
                `UPDATE notes SET deleted_at = CURRENT_TIMESTAMP
                 WHERE folder_id = $1 AND deleted_at IS NULL`,
                [id]
            );
            await client.query(
                `UPDATE note_folders SET deleted_at = CURRENT_TIMESTAMP
                 WHERE id = $1 AND deleted_at IS NULL`,
                [id]
            );
        });

        // Log folder deletion
        await logNoteHistory(parseInt(id), 'deleted', null, folderName, null, 'folder');

        res.status(204).send();
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// NOTES
app.get('/api/notes', async (req, res) => {
    try {
        const { folder_id } = req.query;
        let query = 'SELECT * FROM notes WHERE deleted_at IS NULL';
        let params = [];

        if (folder_id) {
            query += ' AND folder_id = $1';
            params.push(folder_id);
        }
        query += ' ORDER BY updated_at DESC';

        const { rows } = await db.query(query, params);
        res.json(rows);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Get note history
app.get('/api/notes/:id/history', async (req, res) => {
    try {
        const { id } = req.params;
        const { rows } = await db.query(
            `SELECT id, note_id, entity_type, action, field_changed, old_value, new_value,
                    to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as timestamp
             FROM note_history WHERE note_id = $1 AND entity_type = 'note' ORDER BY timestamp DESC`,
            [id]
        );
        res.json(rows);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Get all note history (for dashboard/analytics) - includes both notes and folders
app.get('/api/note-history', async (req, res) => {
    try {
        const { limit = 50 } = req.query;
        const { rows } = await db.query(
            `SELECT h.id, h.note_id, h.entity_type, h.action, h.field_changed, h.old_value, h.new_value,
                    to_char(h.timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as timestamp,
                    CASE
                        WHEN h.entity_type = 'folder' THEN f.name
                        ELSE n.title
                    END as note_title
             FROM note_history h
             LEFT JOIN notes n ON h.note_id = n.id AND h.entity_type = 'note'
             LEFT JOIN note_folders f ON h.note_id = f.id AND h.entity_type = 'folder'
             ORDER BY h.timestamp DESC
             LIMIT $1`,
            [parseInt(limit)]
        );
        res.json(rows);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.post('/api/notes', async (req, res) => {
    try {
        const { title, content, folder_id } = req.body;
        const folderId = folder_id || null;
        console.log(`[NOTES] Creating note: title="${title}", folder_id=${folderId}`);
        // Per-folder MAX so notes append to the bottom of their folder (or
        // unfiled bucket when folder_id IS NULL).
        const { rows } = await db.query(
            `INSERT INTO notes (title, content, folder_id, position, updated_at)
             VALUES ($1, $2, $3,
                     (SELECT COALESCE(MAX(position), 0) + 1000 FROM notes
                      WHERE folder_id IS NOT DISTINCT FROM $3 AND deleted_at IS NULL),
                     CURRENT_TIMESTAMP)
             RETURNING *`,
            [title, content, folderId]
        );
        const note = rows[0];
        console.log(`[NOTES] Note created with id=${note.id}`);

        // Log creation
        await logNoteHistory(note.id, 'created', null, null, JSON.stringify({ title, content, folder_id: folder_id || null }));

        res.status(201).json(note);
    } catch (err) {
        console.error('[NOTES] Error creating note:', err.message);
        sendErrorResponse(res, err);
    }
});

app.put('/api/notes/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { title, content, folder_id } = req.body;
        console.log(`[NOTES] Updating note id=${id}: title="${title}", folder_id=${folder_id}`);

        // Get current note state for history logging
        const { rows: currentRows } = await db.query('SELECT * FROM notes WHERE id = $1', [id]);
        if (currentRows.length === 0) {
            return res.status(404).json({ error: 'Note not found' });
        }
        const currentNote = currentRows[0];
        console.log(`[NOTES] Current note state: title="${currentNote.title}", folder_id=${currentNote.folder_id}`);

        // Track changes
        const changes = [];
        if (title !== undefined && title !== currentNote.title) {
            changes.push({ field: 'title', old: currentNote.title, new: title });
        }
        if (content !== undefined && content !== currentNote.content) {
            changes.push({ field: 'content', old: currentNote.content, new: content });
        }
        const newFolderId = folder_id !== undefined ? folder_id : null;
        if (newFolderId !== currentNote.folder_id) {
            changes.push({ field: 'folder_id', old: currentNote.folder_id, new: newFolderId, action: 'moved' });
        }
        console.log(`[NOTES] Detected ${changes.length} changes:`, JSON.stringify(changes.map(c => c.field)));

        const { rows } = await db.query(
            'UPDATE notes SET title = $1, content = $2, folder_id = $3, updated_at = CURRENT_TIMESTAMP WHERE id = $4 RETURNING *',
            [title, content, newFolderId, id]
        );

        // Log each change to history
        for (const change of changes) {
            const action = change.action || 'updated';
            await logNoteHistory(
                parseInt(id),
                action,
                change.field,
                change.old !== null ? String(change.old) : null,
                change.new !== null ? String(change.new) : null
            );
        }

        res.json(rows[0]);
    } catch (err) {
        console.error('[NOTES] Error updating note:', err);
        sendErrorResponse(res, err);
    }
});

app.delete('/api/notes/:id', async (req, res) => {
    try {
        const { id } = req.params;

        // Get note info before deletion for logging
        const { rows: noteRows } = await db.query('SELECT title FROM notes WHERE id = $1', [id]);
        const noteTitle = noteRows.length > 0 ? noteRows[0].title : null;

        await db.query(
            `UPDATE notes SET deleted_at = CURRENT_TIMESTAMP
             WHERE id = $1 AND deleted_at IS NULL`,
            [id]
        );

        // Log deletion
        await logNoteHistory(parseInt(id), 'deleted', null, noteTitle, null);

        res.status(204).send();
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// LISTS
app.get('/api/lists', async (req, res) => {
    try {
        const { rows } = await db.query(
            'SELECT * FROM lists WHERE deleted_at IS NULL ORDER BY created_at DESC'
        );
        res.json(rows);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Get list history
app.get('/api/lists/:id/history', async (req, res) => {
    try {
        const { id } = req.params;
        const { rows } = await db.query(
            `SELECT id, list_id, action, field_changed, old_value, new_value,
                    to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as timestamp
             FROM list_history WHERE list_id = $1 ORDER BY timestamp DESC`,
            [id]
        );
        res.json(rows);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Get all list history (for dashboard/analytics)
app.get('/api/list-history', async (req, res) => {
    try {
        const { limit = 50 } = req.query;
        const { rows } = await db.query(
            `SELECT h.id, h.list_id, h.action, h.field_changed, h.old_value, h.new_value,
                    to_char(h.timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as timestamp,
                    l.title as list_title
             FROM list_history h
             LEFT JOIN lists l ON h.list_id = l.id
             ORDER BY h.timestamp DESC
             LIMIT $1`,
            [parseInt(limit)]
        );
        res.json(rows);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.post('/api/lists', async (req, res) => {
    try {
        const { title, items } = req.body;
        const { rows } = await db.query(
            `INSERT INTO lists (title, items, position)
             VALUES ($1, $2, (SELECT COALESCE(MAX(position), 0) + 1000 FROM lists WHERE deleted_at IS NULL))
             RETURNING *`,
            [title, JSON.stringify(items)]
        );
        const list = rows[0];

        // Log creation
        await logListHistory(list.id, 'created', null, null, JSON.stringify({ title, items }));

        res.status(201).json(list);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.put('/api/lists/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { title, items } = req.body;

        // Get current list state for history logging
        const { rows: currentRows } = await db.query('SELECT * FROM lists WHERE id = $1', [id]);
        if (currentRows.length === 0) {
            return res.status(404).json({ error: 'List not found' });
        }
        const currentList = currentRows[0];

        // Track changes
        const changes = [];
        if (title !== undefined && title !== currentList.title) {
            changes.push({ field: 'title', old: currentList.title, new: title });
        }

        // Compare items arrays
        const currentItems = currentList.items || [];
        const newItems = items || [];
        const currentItemsStr = JSON.stringify(currentItems);
        const newItemsStr = JSON.stringify(newItems);

        if (currentItemsStr !== newItemsStr) {
            // Detect specific item changes
            const currentItemTexts = currentItems.map(i => i.text || i);
            const newItemTexts = newItems.map(i => i.text || i);

            // Check for added items
            newItems.forEach(newItem => {
                const itemText = newItem.text || newItem;
                if (!currentItemTexts.includes(itemText)) {
                    changes.push({ field: 'items', action: 'item_added', old: null, new: itemText });
                }
            });

            // Check for removed items
            currentItems.forEach(oldItem => {
                const itemText = oldItem.text || oldItem;
                if (!newItemTexts.includes(itemText)) {
                    changes.push({ field: 'items', action: 'item_removed', old: itemText, new: null });
                }
            });

            // Check for checked/unchecked items
            newItems.forEach(newItem => {
                if (typeof newItem === 'object' && newItem.text) {
                    const oldItem = currentItems.find(i => (i.text || i) === newItem.text);
                    if (oldItem && typeof oldItem === 'object') {
                        if (oldItem.checked !== newItem.checked) {
                            changes.push({
                                field: 'items',
                                action: newItem.checked ? 'item_checked' : 'item_unchecked',
                                old: newItem.text,
                                new: newItem.checked ? 'checked' : 'unchecked'
                            });
                        }
                    }
                }
            });

            // If no specific changes detected, log general items update
            if (changes.filter(c => c.field === 'items').length === 0) {
                changes.push({ field: 'items', old: currentItemsStr, new: newItemsStr });
            }
        }

        const { rows } = await db.query('UPDATE lists SET title = $1, items = $2 WHERE id = $3 RETURNING *', [title, JSON.stringify(items), id]);

        // Log each change to history
        for (const change of changes) {
            const action = change.action || 'updated';
            await logListHistory(
                parseInt(id),
                action,
                change.field,
                change.old !== null ? String(change.old) : null,
                change.new !== null ? String(change.new) : null
            );
        }

        res.json(rows[0]);
    } catch (err) {
        console.error('Error updating list:', err);
        sendErrorResponse(res, err);
    }
});

app.delete('/api/lists/:id', async (req, res) => {
    try {
        const { id } = req.params;

        // Get list info before deletion for logging
        const { rows: listRows } = await db.query('SELECT title FROM lists WHERE id = $1', [id]);
        const listTitle = listRows.length > 0 ? listRows[0].title : null;

        await db.query(
            `UPDATE lists SET deleted_at = CURRENT_TIMESTAMP
             WHERE id = $1 AND deleted_at IS NULL`,
            [id]
        );

        // Log deletion
        await logListHistory(parseInt(id), 'deleted', null, listTitle, null);

        res.status(204).send();
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// DASHBOARD STATS
app.get('/api/stats', async (req, res) => {
    try {
        // Get counts and weekly comparisons
        const todosQuery = `
            SELECT
                COUNT(*) as total,
                COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days') as this_week,
                COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '14 days' AND created_at < NOW() - INTERVAL '7 days') as last_week
            FROM todos
        `;
        const notesQuery = `
            SELECT
                COUNT(*) as total,
                COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days') as this_week,
                COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '14 days' AND created_at < NOW() - INTERVAL '7 days') as last_week
            FROM notes
        `;
        const listsQuery = `
            SELECT
                COUNT(*) as total,
                COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '7 days') as this_week,
                COUNT(*) FILTER (WHERE created_at >= NOW() - INTERVAL '14 days' AND created_at < NOW() - INTERVAL '7 days') as last_week
            FROM lists
        `;

        const [todosResult, notesResult, listsResult] = await Promise.all([
            db.query(todosQuery),
            db.query(notesQuery),
            db.query(listsQuery)
        ]);

        const calculateTrend = (thisWeek, lastWeek) => {
            if (lastWeek === 0) return thisWeek > 0 ? 100 : 0;
            return Math.round(((thisWeek - lastWeek) / lastWeek) * 100);
        };

        const todos = todosResult.rows[0];
        const notes = notesResult.rows[0];
        const lists = listsResult.rows[0];

        res.json({
            todos: {
                total: parseInt(todos.total),
                trend: calculateTrend(parseInt(todos.this_week), parseInt(todos.last_week))
            },
            notes: {
                total: parseInt(notes.total),
                trend: calculateTrend(parseInt(notes.this_week), parseInt(notes.last_week))
            },
            lists: {
                total: parseInt(lists.total),
                trend: calculateTrend(parseInt(lists.this_week), parseInt(lists.last_week))
            }
        });
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// =============================================================================
// DASHBOARD CONFIG / PREFERENCES (v2)
// =============================================================================
// The dashboard_config row stores both the legacy `widgets` array and the new
// nested `preferences` object (theme, default_view, density, etc.). The
// merge/hydrate logic lives in ./preferences.js so tests can exercise it
// without spinning up Express.

app.get('/api/config', async (req, res) => {
    try {
        const { rows } = await db.query('SELECT id, layout_preference FROM dashboard_config WHERE id = 1');
        const stored = rows[0]?.layout_preference || null;
        res.json({
            id: rows[0]?.id || 1,
            layout_preference: hydrateLayoutPreference(stored),
        });
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.put('/api/config', async (req, res) => {
    try {
        const { layout_preference } = req.body;
        // Pass the raw object straight through — full overwrite is the legacy
        // contract. Callers that want partial updates use the PATCH endpoint
        // below.
        const { rows } = await db.query(
            'UPDATE dashboard_config SET layout_preference = $1 WHERE id = 1 RETURNING id, layout_preference',
            [JSON.stringify(layout_preference)]
        );
        res.json({
            id: rows[0]?.id || 1,
            layout_preference: hydrateLayoutPreference(rows[0]?.layout_preference || null),
        });
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Friendly aliases used by the v2 frontend. Behaviour is identical to /api/config.
app.get('/api/dashboard/config', async (req, res) => {
    try {
        const { rows } = await db.query('SELECT id, layout_preference FROM dashboard_config WHERE id = 1');
        res.json({
            id: rows[0]?.id || 1,
            layout_preference: hydrateLayoutPreference(rows[0]?.layout_preference || null),
        });
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

/**
 * PATCH /api/dashboard/config/preferences
 * Accepts a partial preferences object and deep-merges it into the stored
 * preferences sub-object. Does NOT touch `widgets`. Returns the full
 * hydrated layout_preference shape.
 */
app.patch('/api/dashboard/config/preferences', async (req, res) => {
    try {
        const parsed = preferencesPatchSchema.safeParse(req.body || {});
        if (!parsed.success) {
            return res.status(400).json({
                error: 'Invalid preferences payload',
                details: parsed.error.flatten(),
            });
        }
        const patch = parsed.data;

        // Read-modify-write inside a transaction so concurrent PATCHes don't
        // clobber each other. Single-user app today, but cheap to do right.
        const result = await db.withTransaction(async (client) => {
            const { rows } = await client.query(
                'SELECT layout_preference FROM dashboard_config WHERE id = 1 FOR UPDATE'
            );
            const stored = rows[0]?.layout_preference || {};
            const next = {
                widgets: Array.isArray(stored.widgets) ? stored.widgets : DEFAULT_WIDGETS.slice(),
                preferences: deepMerge(deepMerge(DEFAULT_PREFERENCES, stored.preferences || {}), patch),
            };
            const upd = await client.query(
                `INSERT INTO dashboard_config (id, layout_preference) VALUES (1, $1)
                 ON CONFLICT (id) DO UPDATE SET layout_preference = EXCLUDED.layout_preference
                 RETURNING id, layout_preference`,
                [JSON.stringify(next)]
            );
            return upd.rows[0];
        });

        res.json({
            id: result.id,
            layout_preference: hydrateLayoutPreference(result.layout_preference),
        });
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// =============================================================================
// REORDER ENDPOINTS (v2 drag-to-reorder)
// =============================================================================
// All four endpoints share the same body schema and the same midpoint /
// renumber strategy via computeNewPosition. The transaction makes
// SELECT ... FOR UPDATE + UPDATE atomic so concurrent reorders on the same
// scope don't fight.

const reorderBodySchema = z.object({
    before_id: z.number().int().nullable().optional(),
    after_id: z.number().int().nullable().optional(),
}).strict();

const noteReorderBodySchema = reorderBodySchema.extend({
    folder_id: z.number().int().nullable().optional(), // optional cross-folder move
});

/**
 * Shared reorder runner. Returns the updated row.
 *
 * @param {object} args
 * @param {string} args.table         table name (allowlisted in reorderHelpers)
 * @param {object} args.scopeFilter   columns that bound the ordering scope
 * @param {number} args.movingId
 * @param {number|null} args.beforeId
 * @param {number|null} args.afterId
 * @param {(client, newPos) => Promise<object>} args.applyUpdate updates the
 *        row's position (and any other columns the route mutates, e.g. folder
 *        moves on notes) and returns the updated row.
 */
async function runReorder({ table, scopeFilter, movingId, beforeId, afterId, applyUpdate }) {
    return db.withTransaction(async (client) => {
        const newPos = await computeNewPosition(client, table, scopeFilter, movingId, beforeId ?? null, afterId ?? null);
        return applyUpdate(client, newPos);
    });
}

app.patch('/api/todos/:id/reorder', async (req, res) => {
    try {
        const id = parseInt(req.params.id, 10);
        if (!Number.isFinite(id)) return res.status(400).json({ error: 'Invalid id' });

        const parsed = reorderBodySchema.safeParse(req.body || {});
        if (!parsed.success) {
            return res.status(400).json({ error: 'Invalid body', details: parsed.error.flatten() });
        }
        const { before_id = null, after_id = null } = parsed.data;

        const updated = await runReorder({
            table: 'todos',
            scopeFilter: { deleted_at: null }, // active todos only; matches list-render filter
            movingId: id,
            beforeId: before_id,
            afterId: after_id,
            applyUpdate: async (client, newPos) => {
                const { rows } = await client.query(
                    `UPDATE todos SET position = $1, updated_at = CURRENT_TIMESTAMP
                     WHERE id = $2 RETURNING *`,
                    [newPos, id]
                );
                return rows[0];
            }
        });

        if (!updated) return res.status(404).json({ error: 'Todo not found' });

        await logTodoHistory(id, 'reorder', 'position', null, String(updated.position));
        res.json(updated);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.patch('/api/notes/:id/reorder', async (req, res) => {
    try {
        const id = parseInt(req.params.id, 10);
        if (!Number.isFinite(id)) return res.status(400).json({ error: 'Invalid id' });

        const parsed = noteReorderBodySchema.safeParse(req.body || {});
        if (!parsed.success) {
            return res.status(400).json({ error: 'Invalid body', details: parsed.error.flatten() });
        }
        const { before_id = null, after_id = null, folder_id } = parsed.data;

        // Determine the destination folder. If folder_id is omitted from the
        // body, the note stays in its current folder. We need this BEFORE
        // computing the new position so the scope is correct.
        const { rows: noteRows } = await db.query('SELECT folder_id FROM notes WHERE id = $1', [id]);
        if (noteRows.length === 0) return res.status(404).json({ error: 'Note not found' });
        const currentFolderId = noteRows[0].folder_id;
        const targetFolderId = folder_id === undefined ? currentFolderId : folder_id;

        const updated = await runReorder({
            table: 'notes',
            scopeFilter: { folder_id: targetFolderId }, // null is allowed and treated as IS NULL
            movingId: id,
            beforeId: before_id,
            afterId: after_id,
            applyUpdate: async (client, newPos) => {
                const { rows } = await client.query(
                    `UPDATE notes SET position = $1, folder_id = $2, updated_at = CURRENT_TIMESTAMP
                     WHERE id = $3 RETURNING *`,
                    [newPos, targetFolderId, id]
                );
                return rows[0];
            }
        });

        if (!updated) return res.status(404).json({ error: 'Note not found' });

        // Audit log: emit a folder move row when the folder actually changed,
        // plus the reorder row so the position change is also recorded.
        if (folder_id !== undefined && folder_id !== currentFolderId) {
            await logNoteHistory(id, 'moved', 'folder_id',
                currentFolderId === null ? null : String(currentFolderId),
                targetFolderId === null ? null : String(targetFolderId)
            );
        }
        await logNoteHistory(id, 'reorder', 'position', null, String(updated.position));

        res.json(updated);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.patch('/api/lists/:id/reorder', async (req, res) => {
    try {
        const id = parseInt(req.params.id, 10);
        if (!Number.isFinite(id)) return res.status(400).json({ error: 'Invalid id' });

        const parsed = reorderBodySchema.safeParse(req.body || {});
        if (!parsed.success) {
            return res.status(400).json({ error: 'Invalid body', details: parsed.error.flatten() });
        }
        const { before_id = null, after_id = null } = parsed.data;

        const updated = await runReorder({
            table: 'lists',
            scopeFilter: {}, // global ordering
            movingId: id,
            beforeId: before_id,
            afterId: after_id,
            applyUpdate: async (client, newPos) => {
                const { rows } = await client.query(
                    `UPDATE lists SET position = $1 WHERE id = $2 RETURNING *`,
                    [newPos, id]
                );
                return rows[0];
            }
        });

        if (!updated) return res.status(404).json({ error: 'List not found' });

        await logListHistory(id, 'reorder', 'position', null, String(updated.position));
        res.json(updated);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

app.patch('/api/note_folders/:id/reorder', async (req, res) => {
    try {
        const id = parseInt(req.params.id, 10);
        if (!Number.isFinite(id)) return res.status(400).json({ error: 'Invalid id' });

        const parsed = reorderBodySchema.safeParse(req.body || {});
        if (!parsed.success) {
            return res.status(400).json({ error: 'Invalid body', details: parsed.error.flatten() });
        }
        const { before_id = null, after_id = null } = parsed.data;

        const updated = await runReorder({
            table: 'note_folders',
            scopeFilter: {},
            movingId: id,
            beforeId: before_id,
            afterId: after_id,
            applyUpdate: async (client, newPos) => {
                const { rows } = await client.query(
                    `UPDATE note_folders SET position = $1 WHERE id = $2 RETURNING *`,
                    [newPos, id]
                );
                return rows[0];
            }
        });

        if (!updated) return res.status(404).json({ error: 'Folder not found' });

        await logNoteHistory(id, 'reorder', 'position', null, String(updated.position), 'folder');
        res.json(updated);
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// AI CHAT ENDPOINT - v2.0: Uses Responses API with function calling, returns drafts + assistant text
app.post('/api/ai/parse', async (req, res) => {
    try {
        const { input, sessionId, timezone } = req.body;

        if (!input || typeof input !== 'string') {
            return res.status(400).json({ error: 'Input is required' });
        }

        if (!process.env.ANTHROPIC_API_KEY) {
            return res.status(500).json({ error: 'ANTHROPIC_API_KEY is not configured' });
        }

        // Process chat using chatToDrafts with Responses API
        const result = await chatToDrafts(input, {
            userId: null, // No user auth for now
            nowIso: new Date().toISOString(),
            tz: timezone || 'UTC',
            sessionId: sessionId || null
        });

        return res.json({
            success: result.drafts.length > 0 || (!result.followUpQuestion && result.errors.length === 0),
            assistantText: result.assistantText,
            drafts: result.drafts,
            followUpQuestion: result.followUpQuestion,
            errors: result.errors
        });

    } catch (err) {
        console.error('AI Chat Error:', err);
        sendErrorResponse(res, err);
    }
});

// AI CHAT STREAMING ENDPOINT
// Returns Server-Sent Events. Same logic as /api/ai/parse but emits the
// assistantText as incremental "text" deltas after the drafts are resolved,
// so the chat UI can render tokens progressively. The underlying LLM call
// is still single-shot today; when the SDK call switches to streamText,
// only this handler changes — the SSE wire format stays the same.
//
// SSE event format:
//   event: drafts   data: { drafts: [...] }
//   event: text     data: { chunk: "..." }     (zero or more)
//   event: done     data: { followUpQuestion?: string, errors: [...] }
//   event: error    data: { message: "..." }
app.post('/api/ai/parse/stream', async (req, res) => {
    const { input, sessionId, timezone } = req.body || {};

    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache, no-transform');
    res.setHeader('Connection', 'keep-alive');
    res.setHeader('X-Accel-Buffering', 'no');
    res.flushHeaders?.();

    const writeEvent = (event, data) => {
        res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    };

    try {
        if (!input || typeof input !== 'string') {
            writeEvent('error', { message: 'Input is required' });
            return res.end();
        }
        if (!process.env.ANTHROPIC_API_KEY) {
            writeEvent('error', { message: 'ANTHROPIC_API_KEY is not configured' });
            return res.end();
        }

        const result = await chatToDrafts(input, {
            userId: null,
            nowIso: new Date().toISOString(),
            tz: timezone || 'UTC',
            sessionId: sessionId || null
        });

        // Emit drafts immediately so the UI can render the preview cards.
        writeEvent('drafts', { drafts: result.drafts || [] });

        // Stream the assistant text word-by-word with a small delay to
        // produce the typewriter feel. When streamText is wired upstream
        // these deltas will arrive directly from the LLM at native cadence.
        const text = result.assistantText || '';
        if (text) {
            const tokens = text.match(/\S+\s*/g) || [text];
            for (const token of tokens) {
                writeEvent('text', { chunk: token });
                // 12ms ≈ ~80 wpm — fast but legible
                await new Promise((resolve) => setTimeout(resolve, 12));
            }
        }

        writeEvent('done', {
            followUpQuestion: result.followUpQuestion || null,
            errors: result.errors || []
        });
        res.end();
    } catch (err) {
        console.error('AI Chat Streaming Error:', err);
        writeEvent('error', { message: err?.message || 'Streaming failed' });
        res.end();
    }
});

// POST /api/ai/execute - Execute a confirmed draft
app.post('/api/ai/execute', async (req, res) => {
    try {
        const { draft_id, updatedData } = req.body;

        if (!draft_id) {
            return res.status(400).json({ error: 'draft_id is required' });
        }

        // Get the pending draft
        const draft = await draftStore.getPendingDraft(draft_id);
        if (!draft) {
            return res.status(404).json({ error: 'Draft not found or already resolved' });
        }

        const draftData = updatedData || draft.draft_data;

        // Execute the actual CRUD operation based on action type
        let result;
        let resultEntityId;

        switch (draft.action_type) {
            // ========== CREATE OPERATIONS ==========
            case 'CREATE_TODO': {
                const { rows: todoRows } = await db.query(
                    'INSERT INTO todos (title, description, due_date, tag) VALUES ($1, $2, $3, $4) RETURNING *',
                    [draftData.title, draftData.description || null, draftData.due_date || null, draftData.tag || null]
                );
                result = todoRows[0];
                resultEntityId = result.id;
                await logTodoHistory(result.id, 'created', null, null, JSON.stringify(draftData));
                break;
            }

            case 'CREATE_NOTE': {
                const { rows: noteRows } = await db.query(
                    'INSERT INTO notes (title, content, folder_id) VALUES ($1, $2, $3) RETURNING *',
                    [draftData.title, draftData.content, draftData.folder_id || null]
                );
                result = noteRows[0];
                resultEntityId = result.id;
                await logNoteHistory(result.id, 'created', null, null, JSON.stringify(draftData));
                break;
            }

            case 'CREATE_LIST': {
                const items = Array.isArray(draftData.items)
                    ? draftData.items.map(item => typeof item === 'string' ? { text: item, checked: false } : item)
                    : [];
                const { rows: listRows } = await db.query(
                    'INSERT INTO lists (title, items) VALUES ($1, $2) RETURNING *',
                    [draftData.title, JSON.stringify(items)]
                );
                result = listRows[0];
                resultEntityId = result.id;
                await logListHistory(result.id, 'created', null, null, JSON.stringify(draftData));
                break;
            }

            // ========== UPDATE OPERATIONS ==========
            case 'COMPLETE_TODO': {
                const { rows: completeTodoRows } = await db.query(
                    'UPDATE todos SET completed = $1, updated_at = CURRENT_TIMESTAMP WHERE id = $2 RETURNING *',
                    [draftData.completed, draftData.id]
                );

                if (completeTodoRows.length === 0) {
                    return res.status(404).json({ error: 'Task not found' });
                }

                result = completeTodoRows[0];
                resultEntityId = result.id;
                await logTodoHistory(result.id, draftData.completed ? 'completed' : 'uncompleted', 'completed', !draftData.completed, draftData.completed);
                break;
            }

            case 'UPDATE_TODO': {
                // Build dynamic update query based on provided fields
                const updates = [];
                const values = [];
                let paramIdx = 1;

                if (draftData.title !== undefined) {
                    updates.push(`title = $${paramIdx++}`);
                    values.push(draftData.title);
                }
                if (draftData.description !== undefined) {
                    updates.push(`description = $${paramIdx++}`);
                    values.push(draftData.description);
                }
                if (draftData.due_date !== undefined) {
                    updates.push(`due_date = $${paramIdx++}`);
                    values.push(draftData.due_date);
                }
                if (draftData.tag !== undefined) {
                    updates.push(`tag = $${paramIdx++}`);
                    values.push(draftData.tag);
                }

                if (updates.length === 0) {
                    return res.status(400).json({ error: 'No fields to update' });
                }

                values.push(draftData.id);
                const { rows: updateTodoRows } = await db.query(
                    `UPDATE todos SET ${updates.join(', ')}, updated_at = CURRENT_TIMESTAMP WHERE id = $${paramIdx} AND deleted_at IS NULL RETURNING *`,
                    values
                );

                if (updateTodoRows.length === 0) {
                    return res.status(404).json({ error: 'Task not found' });
                }

                result = updateTodoRows[0];
                resultEntityId = result.id;
                await logTodoHistory(result.id, 'updated', null, null, JSON.stringify(draftData));
                break;
            }

            case 'UPDATE_NOTE': {
                const noteUpdates = [];
                const noteValues = [];
                let noteParamIdx = 1;

                if (draftData.title !== undefined) {
                    noteUpdates.push(`title = $${noteParamIdx++}`);
                    noteValues.push(draftData.title);
                }
                if (draftData.content !== undefined) {
                    noteUpdates.push(`content = $${noteParamIdx++}`);
                    noteValues.push(draftData.content);
                }
                if (draftData.folder_id !== undefined) {
                    noteUpdates.push(`folder_id = $${noteParamIdx++}`);
                    noteValues.push(draftData.folder_id);
                }

                if (noteUpdates.length === 0) {
                    return res.status(400).json({ error: 'No fields to update' });
                }

                noteValues.push(draftData.id);
                const { rows: updateNoteRows } = await db.query(
                    `UPDATE notes SET ${noteUpdates.join(', ')}, updated_at = CURRENT_TIMESTAMP WHERE id = $${noteParamIdx} RETURNING *`,
                    noteValues
                );

                if (updateNoteRows.length === 0) {
                    return res.status(404).json({ error: 'Note not found' });
                }

                result = updateNoteRows[0];
                resultEntityId = result.id;
                await logNoteHistory(result.id, 'updated', null, null, JSON.stringify(draftData));
                break;
            }

            case 'UPDATE_LIST': {
                const listUpdates = [];
                const listValues = [];
                let listParamIdx = 1;

                if (draftData.title !== undefined) {
                    listUpdates.push(`title = $${listParamIdx++}`);
                    listValues.push(draftData.title);
                }
                if (draftData.items !== undefined) {
                    listUpdates.push(`items = $${listParamIdx++}`);
                    listValues.push(JSON.stringify(draftData.items));
                }

                if (listUpdates.length === 0) {
                    return res.status(400).json({ error: 'No fields to update' });
                }

                listValues.push(draftData.id);
                const { rows: updateListRows } = await db.query(
                    `UPDATE lists SET ${listUpdates.join(', ')} WHERE id = $${listParamIdx} RETURNING *`,
                    listValues
                );

                if (updateListRows.length === 0) {
                    return res.status(404).json({ error: 'List not found' });
                }

                result = updateListRows[0];
                resultEntityId = result.id;
                await logListHistory(result.id, 'updated', null, null, JSON.stringify(draftData));
                break;
            }

            case 'ADD_TO_LIST': {
                // Get existing list
                const { rows: existingList } = await db.query(
                    'SELECT * FROM lists WHERE id = $1',
                    [draftData.id]
                );

                if (existingList.length === 0) {
                    return res.status(404).json({ error: 'List not found' });
                }

                const currentItems = typeof existingList[0].items === 'string'
                    ? JSON.parse(existingList[0].items)
                    : existingList[0].items || [];

                const newItems = [...currentItems, ...draftData.new_items];

                const { rows: addToListRows } = await db.query(
                    'UPDATE lists SET items = $1 WHERE id = $2 RETURNING *',
                    [JSON.stringify(newItems), draftData.id]
                );

                result = addToListRows[0];
                resultEntityId = result.id;
                await logListHistory(result.id, 'updated', null, null, JSON.stringify({ added_items: draftData.new_items }));
                break;
            }

            case 'UPDATE_LIST_ITEM': {
                // Get existing list
                const { rows: listForItemEdit } = await db.query(
                    'SELECT * FROM lists WHERE id = $1',
                    [draftData.list_id]
                );

                if (listForItemEdit.length === 0) {
                    return res.status(404).json({ error: 'List not found' });
                }

                const itemsToEdit = typeof listForItemEdit[0].items === 'string'
                    ? JSON.parse(listForItemEdit[0].items)
                    : listForItemEdit[0].items || [];

                if (draftData.item_index >= itemsToEdit.length) {
                    return res.status(400).json({ error: 'Item index out of range' });
                }

                // Update the specific item
                const oldItem = { ...itemsToEdit[draftData.item_index] };
                if (draftData.text !== undefined && draftData.text.trim()) {
                    itemsToEdit[draftData.item_index].text = draftData.text;
                }
                if (draftData.checked !== undefined) {
                    itemsToEdit[draftData.item_index].completed = draftData.checked;
                    if (draftData.checked) {
                        itemsToEdit[draftData.item_index].completedAt = new Date().toISOString();
                    } else {
                        itemsToEdit[draftData.item_index].completedAt = null;
                    }
                }

                const { rows: editItemRows } = await db.query(
                    'UPDATE lists SET items = $1 WHERE id = $2 RETURNING *',
                    [JSON.stringify(itemsToEdit), draftData.list_id]
                );

                result = editItemRows[0];
                resultEntityId = result.id;
                await logListHistory(result.id, 'updated', 'item', JSON.stringify(oldItem), JSON.stringify(itemsToEdit[draftData.item_index]));
                break;
            }

            case 'REMOVE_LIST_ITEM': {
                // Get existing list
                const { rows: listForItemRemove } = await db.query(
                    'SELECT * FROM lists WHERE id = $1',
                    [draftData.list_id]
                );

                if (listForItemRemove.length === 0) {
                    return res.status(404).json({ error: 'List not found' });
                }

                const itemsToRemoveFrom = typeof listForItemRemove[0].items === 'string'
                    ? JSON.parse(listForItemRemove[0].items)
                    : listForItemRemove[0].items || [];

                if (draftData.item_index >= itemsToRemoveFrom.length) {
                    return res.status(400).json({ error: 'Item index out of range' });
                }

                // Remove the specific item
                const removedItem = itemsToRemoveFrom.splice(draftData.item_index, 1)[0];

                const { rows: removeItemRows } = await db.query(
                    'UPDATE lists SET items = $1 WHERE id = $2 RETURNING *',
                    [JSON.stringify(itemsToRemoveFrom), draftData.list_id]
                );

                result = removeItemRows[0];
                resultEntityId = result.id;
                await logListHistory(result.id, 'item_removed', 'item', JSON.stringify(removedItem), null);
                break;
            }

            case 'UPDATE_FOLDER': {
                const { rows: updateFolderRows } = await db.query(
                    'UPDATE note_folders SET name = $1 WHERE id = $2 RETURNING *',
                    [draftData.name, draftData.id]
                );

                if (updateFolderRows.length === 0) {
                    return res.status(404).json({ error: 'Folder not found' });
                }

                result = updateFolderRows[0];
                resultEntityId = result.id;
                break;
            }

            // ========== DELETE OPERATIONS ==========
            case 'DELETE_TODO': {
                const { rows: deleteTodoRows } = await db.query(
                    'UPDATE todos SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1 AND deleted_at IS NULL RETURNING *',
                    [draftData.id]
                );

                if (deleteTodoRows.length === 0) {
                    return res.status(404).json({ error: 'Task not found or already deleted' });
                }

                result = deleteTodoRows[0];
                resultEntityId = result.id;
                await logTodoHistory(result.id, 'deleted', null, null, null);
                break;
            }

            case 'DELETE_NOTE': {
                const { rows: deleteNoteRows } = await db.query(
                    'DELETE FROM notes WHERE id = $1 RETURNING *',
                    [draftData.id]
                );

                if (deleteNoteRows.length === 0) {
                    return res.status(404).json({ error: 'Note not found' });
                }

                result = deleteNoteRows[0];
                resultEntityId = result.id;
                await logNoteHistory(result.id, 'deleted', null, null, null);
                break;
            }

            case 'DELETE_LIST': {
                const { rows: deleteListRows } = await db.query(
                    'DELETE FROM lists WHERE id = $1 RETURNING *',
                    [draftData.id]
                );

                if (deleteListRows.length === 0) {
                    return res.status(404).json({ error: 'List not found' });
                }

                result = deleteListRows[0];
                resultEntityId = result.id;
                await logListHistory(result.id, 'deleted', null, null, null);
                break;
            }

            case 'DELETE_FOLDER': {
                // Move notes in folder to no folder first
                await db.query(
                    'UPDATE notes SET folder_id = NULL WHERE folder_id = $1',
                    [draftData.id]
                );

                const { rows: deleteFolderRows } = await db.query(
                    'DELETE FROM note_folders WHERE id = $1 RETURNING *',
                    [draftData.id]
                );

                if (deleteFolderRows.length === 0) {
                    return res.status(404).json({ error: 'Folder not found' });
                }

                result = deleteFolderRows[0];
                resultEntityId = result.id;
                break;
            }

            default:
                return res.status(400).json({ error: `Unsupported action type: ${draft.action_type}` });
        }

        // Update draft status to confirmed
        await draftStore.confirmDraft(draft_id, resultEntityId);

        res.json({
            success: true,
            message: `${draft.action_type.replace(/_/g, ' ')} executed successfully`,
            draft_id: parseInt(draft_id),
            result
        });

    } catch (err) {
        console.error('AI Execute Error:', err);
        sendErrorResponse(res, err);
    }
});

// AI CAPTURE ENDPOINT - one-shot voice capture for the iOS side-button flow.
//
// Takes free text, runs it through chatToDrafts, then applies "smart"
// auto-confirm:
//   - exactly 1 CREATE-type draft and no follow-up question -> auto-execute
//     and return status: "created"
//   - drafts.length === 0 with a follow-up question -> status: "needs_clarification"
//   - any other shape (multiple drafts, edit/delete drafts, etc.) ->
//     status: "needs_review" so the user opens the app and confirms in chat
//
// Auto-confirm is intentionally conservative — only safe CREATE actions go
// through silently. Edits, deletes, and multi-draft batches always fall back
// to needs_review so a misheard prompt cannot mutate or delete existing data.
app.post('/api/ai/capture', async (req, res) => {
    try {
        const { input, sessionId, timezone } = req.body || {};

        if (!input || typeof input !== 'string' || !input.trim()) {
            return res.status(400).json({ error: 'Input is required' });
        }

        if (!process.env.ANTHROPIC_API_KEY) {
            return res.status(500).json({ error: 'ANTHROPIC_API_KEY is not configured' });
        }

        const result = await chatToDrafts(input, {
            userId: null,
            nowIso: new Date().toISOString(),
            tz: timezone || 'UTC',
            sessionId: sessionId || null
        });

        const drafts = result.drafts || [];
        const followUpQuestion = result.followUpQuestion || null;
        const errors = result.errors || [];

        const isCreateAction = (t) => t === 'CREATE_TODO' || t === 'CREATE_NOTE' || t === 'CREATE_LIST';
        const summarizeDraft = (d) => ({
            id: d.id,
            type: d.entity_type,
            title: d.data?.title || d.data?.name || ''
        });

        if (errors.length > 0 && drafts.length === 0) {
            return res.json({ status: 'error', errors });
        }

        if (drafts.length === 0 && followUpQuestion) {
            return res.json({ status: 'needs_clarification', followUpQuestion });
        }

        if (drafts.length === 1 && isCreateAction(drafts[0].action_type) && !followUpQuestion) {
            const draft = drafts[0];
            const draftData = draft.data;
            let createdRow;

            switch (draft.action_type) {
                case 'CREATE_TODO': {
                    const { rows } = await db.query(
                        'INSERT INTO todos (title, description, due_date, tag) VALUES ($1, $2, $3, $4) RETURNING *',
                        [draftData.title, draftData.description || null, draftData.due_date || null, draftData.tag || null]
                    );
                    createdRow = rows[0];
                    await logTodoHistory(createdRow.id, 'created', null, null, JSON.stringify(draftData));
                    break;
                }
                case 'CREATE_NOTE': {
                    const { rows } = await db.query(
                        'INSERT INTO notes (title, content, folder_id) VALUES ($1, $2, $3) RETURNING *',
                        [draftData.title, draftData.content, draftData.folder_id || null]
                    );
                    createdRow = rows[0];
                    await logNoteHistory(createdRow.id, 'created', null, null, JSON.stringify(draftData));
                    break;
                }
                case 'CREATE_LIST': {
                    const items = Array.isArray(draftData.items)
                        ? draftData.items.map(item => typeof item === 'string' ? { text: item, checked: false } : item)
                        : [];
                    const { rows } = await db.query(
                        'INSERT INTO lists (title, items) VALUES ($1, $2) RETURNING *',
                        [draftData.title, JSON.stringify(items)]
                    );
                    createdRow = rows[0];
                    await logListHistory(createdRow.id, 'created', null, null, JSON.stringify(draftData));
                    break;
                }
            }

            await draftStore.confirmDraft(draft.id, createdRow.id);

            return res.json({
                status: 'created',
                created: [{
                    type: draft.entity_type,
                    title: draftData.title,
                    id: createdRow.id,
                    dueDate: createdRow.due_date || null
                }]
            });
        }

        // Multi-draft, edit/delete drafts, or any mixed shape: leave them
        // pending. The user opens the app and the chat surface will replay
        // these drafts so they can confirm or reject explicitly.
        return res.json({
            status: 'needs_review',
            pendingDrafts: drafts.map(summarizeDraft),
            assistantText: result.assistantText || null
        });

    } catch (err) {
        console.error('AI Capture Error:', err);
        sendErrorResponse(res, err);
    }
});

// DRAFT ACTIONS ENDPOINTS - v2.0

// Get all drafts by status
app.get('/api/drafts', async (req, res) => {
    try {
        const { status = 'pending' } = req.query;
        const drafts = await draftStore.getDraftsByStatus(status);
        res.json(drafts.map(draftStore.formatDraft));
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Get a specific draft
app.get('/api/drafts/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const draft = await draftStore.getDraftById(id);
        if (!draft) {
            return res.status(404).json({ error: 'Draft not found' });
        }
        res.json(draftStore.formatDraft(draft));
    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Confirm a draft - executes the actual CRUD operation
app.post('/api/drafts/:id/confirm', async (req, res) => {
    try {
        const { id } = req.params;
        const { updatedData } = req.body; // Optional: allow user to modify data before confirming

        // Get the draft
        const { rows: draftRows } = await db.query(
            'SELECT * FROM draft_actions WHERE id = $1 AND status = $2',
            [id, 'pending']
        );

        if (draftRows.length === 0) {
            return res.status(404).json({ error: 'Draft not found or already resolved' });
        }

        const draft = draftRows[0];
        const draftData = updatedData || draft.draft_data;

        // Execute the actual CRUD operation based on action type
        let result;
        let resultEntityId;

        switch (draft.action_type) {
            case 'CREATE_TODO':
                const { rows: todoRows } = await db.query(
                    'INSERT INTO todos (title, description, due_date, tag) VALUES ($1, $2, $3, $4) RETURNING *',
                    [draftData.title, draftData.description || null, draftData.due_date || null, draftData.tag || null]
                );
                result = todoRows[0];
                resultEntityId = result.id;
                await logTodoHistory(result.id, 'created', null, null, JSON.stringify(draftData));
                break;

            case 'CREATE_NOTE':
                const { rows: noteRows } = await db.query(
                    'INSERT INTO notes (title, content, folder_id) VALUES ($1, $2, $3) RETURNING *',
                    [draftData.title, draftData.content, draftData.folder_id || null]
                );
                result = noteRows[0];
                resultEntityId = result.id;
                await logNoteHistory(result.id, 'created', null, null, JSON.stringify(draftData));
                break;

            case 'CREATE_LIST':
                const items = Array.isArray(draftData.items)
                    ? draftData.items.map(item => typeof item === 'string' ? { text: item, checked: false } : item)
                    : [];
                const { rows: listRows } = await db.query(
                    'INSERT INTO lists (title, items) VALUES ($1, $2) RETURNING *',
                    [draftData.title, JSON.stringify(items)]
                );
                result = listRows[0];
                resultEntityId = result.id;
                await logListHistory(result.id, 'created', null, null, JSON.stringify(draftData));
                break;

            default:
                return res.status(400).json({ error: `Unsupported action type: ${draft.action_type}` });
        }

        // Update draft status to confirmed
        await db.query(
            'UPDATE draft_actions SET status = $1, resolved_at = CURRENT_TIMESTAMP, result_entity_id = $2 WHERE id = $3',
            ['confirmed', resultEntityId, id]
        );

        res.json({
            success: true,
            message: `${draft.action_type.replace('_', ' ')} confirmed and executed`,
            draft_id: parseInt(id),
            result: result
        });

    } catch (err) {
        console.error('Draft confirm error:', err);
        sendErrorResponse(res, err);
    }
});

// Reject a draft
app.post('/api/drafts/:id/reject', async (req, res) => {
    try {
        const { id } = req.params;
        const draft = await draftStore.rejectDraft(id);

        if (!draft) {
            return res.status(404).json({ error: 'Draft not found or already resolved' });
        }

        res.json({
            success: true,
            message: 'Draft rejected',
            draft_id: parseInt(id)
        });

    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Update a pending draft (modify before confirming)
app.put('/api/drafts/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { draft_data } = req.body;

        const draft = await draftStore.updateDraftData(id, draft_data);

        if (!draft) {
            return res.status(404).json({ error: 'Draft not found or already resolved' });
        }

        res.json(draftStore.formatDraft(draft));

    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Bulk confirm/reject drafts
app.post('/api/drafts/bulk', async (req, res) => {
    try {
        const { action, draft_ids } = req.body;

        if (!['confirm', 'reject'].includes(action)) {
            return res.status(400).json({ error: 'Action must be "confirm" or "reject"' });
        }

        if (!Array.isArray(draft_ids) || draft_ids.length === 0) {
            return res.status(400).json({ error: 'draft_ids must be a non-empty array' });
        }

        const results = [];
        const errors = [];

        for (const draftId of draft_ids) {
            try {
                if (action === 'confirm') {
                    // Get the draft
                    const { rows: draftRows } = await db.query(
                        'SELECT * FROM draft_actions WHERE id = $1 AND status = $2',
                        [draftId, 'pending']
                    );

                    if (draftRows.length === 0) {
                        errors.push({ id: draftId, error: 'Draft not found or already resolved' });
                        continue;
                    }

                    const draft = draftRows[0];
                    const draftData = draft.draft_data;
                    let result;
                    let resultEntityId;

                    switch (draft.action_type) {
                        case 'CREATE_TODO':
                            const { rows: todoRows } = await db.query(
                                'INSERT INTO todos (title, description, due_date, tag) VALUES ($1, $2, $3, $4) RETURNING *',
                                [draftData.title, draftData.description || null, draftData.due_date || null, draftData.tag || null]
                            );
                            result = todoRows[0];
                            resultEntityId = result.id;
                            await logTodoHistory(result.id, 'created', null, null, JSON.stringify(draftData));
                            break;

                        case 'CREATE_NOTE':
                            const { rows: noteRows } = await db.query(
                                'INSERT INTO notes (title, content, folder_id) VALUES ($1, $2, $3) RETURNING *',
                                [draftData.title, draftData.content, draftData.folder_id || null]
                            );
                            result = noteRows[0];
                            resultEntityId = result.id;
                            await logNoteHistory(result.id, 'created', null, null, JSON.stringify(draftData));
                            break;

                        case 'CREATE_LIST':
                            const items = Array.isArray(draftData.items)
                                ? draftData.items.map(item => typeof item === 'string' ? { text: item, checked: false } : item)
                                : [];
                            const { rows: listRows } = await db.query(
                                'INSERT INTO lists (title, items) VALUES ($1, $2) RETURNING *',
                                [draftData.title, JSON.stringify(items)]
                            );
                            result = listRows[0];
                            resultEntityId = result.id;
                            await logListHistory(result.id, 'created', null, null, JSON.stringify(draftData));
                            break;

                        default:
                            errors.push({ id: draftId, error: `Unsupported action type: ${draft.action_type}` });
                            continue;
                    }

                    await db.query(
                        'UPDATE draft_actions SET status = $1, resolved_at = CURRENT_TIMESTAMP, result_entity_id = $2 WHERE id = $3',
                        ['confirmed', resultEntityId, draftId]
                    );

                    results.push({ id: draftId, action: 'confirmed', result });

                } else {
                    // Reject
                    const { rows } = await db.query(
                        `UPDATE draft_actions SET status = 'rejected', resolved_at = CURRENT_TIMESTAMP
                         WHERE id = $1 AND status = 'pending' RETURNING id`,
                        [draftId]
                    );

                    if (rows.length === 0) {
                        errors.push({ id: draftId, error: 'Draft not found or already resolved' });
                    } else {
                        results.push({ id: draftId, action: 'rejected' });
                    }
                }
            } catch (err) {
                errors.push({ id: draftId, error: err.message });
            }
        }

        res.json({
            success: errors.length === 0,
            results,
            errors: errors.length > 0 ? errors : undefined
        });

    } catch (err) {
        sendErrorResponse(res, err);
    }
});

// Catch-all handler for SPA in production - must be after API routes
if (process.env.NODE_ENV === 'production') {
    app.get('/{*splat}', (req, res) => {
        res.sendFile(path.join(__dirname, '../client/dist/index.html'));
    });
}

// Only start the listener when run as the main entrypoint. Tests that need
// the app for in-process HTTP exercise the `app` export and use a random
// port via http.createServer(app).listen(0).
if (require.main === module) {
    app.listen(PORT, async () => {
        console.log(`Server is running on port ${PORT}`);
        await initDb();
    });
}

module.exports = { app, initDb };
