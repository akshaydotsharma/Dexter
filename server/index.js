require('dotenv').config();
const express = require('express');
const cors = require('cors');
const db = require('./db');
const fs = require('fs');
const path = require('path');
const OpenAI = require('openai');
const { SYSTEM_PROMPT } = require('./prompts/systemPrompt');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

// Serve static files from React build in production
if (process.env.NODE_ENV === 'production') {
    app.use(express.static(path.join(__dirname, '../client/dist')));
}

// Initialize Database Schema
const initDb = async () => {
    try {
        const schema = fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8');
        await db.query(schema);
        console.log('Database initialized successfully');
    } catch (err) {
        console.error('Error initializing database:', err);
    }
};

// API Routes

// Helper function to log todo history
const logTodoHistory = async (todoId, action, fieldChanged = null, oldValue = null, newValue = null) => {
    try {
        await db.query(
            'INSERT INTO todo_history (todo_id, action, field_changed, old_value, new_value) VALUES ($1, $2, $3, $4, $5)',
            [todoId, action, fieldChanged, oldValue, newValue]
        );
    } catch (err) {
        console.error('Error logging todo history:', err);
    }
};

// Helper function to log note history
const logNoteHistory = async (noteId, action, fieldChanged = null, oldValue = null, newValue = null) => {
    try {
        await db.query(
            'INSERT INTO note_history (note_id, action, field_changed, old_value, new_value) VALUES ($1, $2, $3, $4, $5)',
            [noteId, action, fieldChanged, oldValue, newValue]
        );
    } catch (err) {
        console.error('Error logging note history:', err);
    }
};

// Helper function to log list history
const logListHistory = async (listId, action, fieldChanged = null, oldValue = null, newValue = null) => {
    try {
        await db.query(
            'INSERT INTO list_history (list_id, action, field_changed, old_value, new_value) VALUES ($1, $2, $3, $4, $5)',
            [listId, action, fieldChanged, oldValue, newValue]
        );
    } catch (err) {
        console.error('Error logging list history:', err);
    }
};

// TODOS
app.get('/api/todos', async (req, res) => {
    try {
        const { rows } = await db.query('SELECT * FROM todos WHERE deleted_at IS NULL ORDER BY created_at DESC');
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
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
        res.status(500).json({ error: err.message });
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
        res.status(500).json({ error: err.message });
    }
});

app.post('/api/todos', async (req, res) => {
    try {
        const { title, description, due_date, tag } = req.body;
        const { rows } = await db.query(
            'INSERT INTO todos (title, description, due_date, tag) VALUES ($1, $2, $3, $4) RETURNING *',
            [title, description || null, due_date || null, tag || null]
        );
        const todo = rows[0];

        // Log creation
        await logTodoHistory(todo.id, 'created', null, null, JSON.stringify({ title, description, due_date, tag }));

        res.status(201).json(todo);
    } catch (err) {
        res.status(500).json({ error: err.message });
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
        res.status(500).json({ error: err.message });
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
        res.status(500).json({ error: err.message });
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
        res.status(500).json({ error: err.message });
    }
});

// NOTE FOLDERS
app.get('/api/note-folders', async (req, res) => {
    try {
        const { rows } = await db.query('SELECT * FROM note_folders ORDER BY created_at DESC');
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.post('/api/note-folders', async (req, res) => {
    try {
        const { name } = req.body;
        const { rows } = await db.query('INSERT INTO note_folders (name) VALUES ($1) RETURNING *', [name]);
        res.status(201).json(rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.put('/api/note-folders/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { name } = req.body;
        const { rows } = await db.query('UPDATE note_folders SET name = $1 WHERE id = $2 RETURNING *', [name, id]);
        res.json(rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.delete('/api/note-folders/:id', async (req, res) => {
    try {
        const { id } = req.params;
        await db.query('DELETE FROM note_folders WHERE id = $1', [id]);
        res.status(204).send();
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// NOTES
app.get('/api/notes', async (req, res) => {
    try {
        const { folder_id } = req.query;
        let query = 'SELECT * FROM notes';
        let params = [];

        if (folder_id) {
            query += ' WHERE folder_id = $1';
            params.push(folder_id);
        }
        query += ' ORDER BY updated_at DESC';

        const { rows } = await db.query(query, params);
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Get note history
app.get('/api/notes/:id/history', async (req, res) => {
    try {
        const { id } = req.params;
        const { rows } = await db.query(
            `SELECT id, note_id, action, field_changed, old_value, new_value,
                    to_char(timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as timestamp
             FROM note_history WHERE note_id = $1 ORDER BY timestamp DESC`,
            [id]
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Get all note history (for dashboard/analytics)
app.get('/api/note-history', async (req, res) => {
    try {
        const { limit = 50 } = req.query;
        const { rows } = await db.query(
            `SELECT h.id, h.note_id, h.action, h.field_changed, h.old_value, h.new_value,
                    to_char(h.timestamp AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as timestamp,
                    n.title as note_title
             FROM note_history h
             LEFT JOIN notes n ON h.note_id = n.id
             ORDER BY h.timestamp DESC
             LIMIT $1`,
            [parseInt(limit)]
        );
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.post('/api/notes', async (req, res) => {
    try {
        const { title, content, folder_id } = req.body;
        const { rows } = await db.query(
            'INSERT INTO notes (title, content, folder_id, updated_at) VALUES ($1, $2, $3, CURRENT_TIMESTAMP) RETURNING *',
            [title, content, folder_id || null]
        );
        const note = rows[0];

        // Log creation
        await logNoteHistory(note.id, 'created', null, null, JSON.stringify({ title, content, folder_id: folder_id || null }));

        res.status(201).json(note);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.put('/api/notes/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { title, content, folder_id } = req.body;

        // Get current note state for history logging
        const { rows: currentRows } = await db.query('SELECT * FROM notes WHERE id = $1', [id]);
        if (currentRows.length === 0) {
            return res.status(404).json({ error: 'Note not found' });
        }
        const currentNote = currentRows[0];

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
        console.error('Error updating note:', err);
        res.status(500).json({ error: err.message });
    }
});

app.delete('/api/notes/:id', async (req, res) => {
    try {
        const { id } = req.params;

        // Get note info before deletion for logging
        const { rows: noteRows } = await db.query('SELECT title FROM notes WHERE id = $1', [id]);
        const noteTitle = noteRows.length > 0 ? noteRows[0].title : null;

        await db.query('DELETE FROM notes WHERE id = $1', [id]);

        // Log deletion
        await logNoteHistory(parseInt(id), 'deleted', null, noteTitle, null);

        res.status(204).send();
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// LISTS
app.get('/api/lists', async (req, res) => {
    try {
        const { rows } = await db.query('SELECT * FROM lists ORDER BY created_at DESC');
        res.json(rows);
    } catch (err) {
        res.status(500).json({ error: err.message });
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
        res.status(500).json({ error: err.message });
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
        res.status(500).json({ error: err.message });
    }
});

app.post('/api/lists', async (req, res) => {
    try {
        const { title, items } = req.body;
        const { rows } = await db.query('INSERT INTO lists (title, items) VALUES ($1, $2) RETURNING *', [title, JSON.stringify(items)]);
        const list = rows[0];

        // Log creation
        await logListHistory(list.id, 'created', null, null, JSON.stringify({ title, items }));

        res.status(201).json(list);
    } catch (err) {
        res.status(500).json({ error: err.message });
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
        res.status(500).json({ error: err.message });
    }
});

app.delete('/api/lists/:id', async (req, res) => {
    try {
        const { id } = req.params;

        // Get list info before deletion for logging
        const { rows: listRows } = await db.query('SELECT title FROM lists WHERE id = $1', [id]);
        const listTitle = listRows.length > 0 ? listRows[0].title : null;

        await db.query('DELETE FROM lists WHERE id = $1', [id]);

        // Log deletion
        await logListHistory(parseInt(id), 'deleted', null, listTitle, null);

        res.status(204).send();
    } catch (err) {
        res.status(500).json({ error: err.message });
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
        res.status(500).json({ error: err.message });
    }
});

// DASHBOARD CONFIG
app.get('/api/config', async (req, res) => {
    try {
        const { rows } = await db.query('SELECT * FROM dashboard_config WHERE id = 1');
        if (rows.length === 0) {
            // Should not happen due to schema init, but just in case
            res.json({ layout_preference: { widgets: ["todos", "notes", "lists"] } });
        } else {
            res.json(rows[0]);
        }
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.put('/api/config', async (req, res) => {
    try {
        const { layout_preference } = req.body;
        const { rows } = await db.query('UPDATE dashboard_config SET layout_preference = $1 WHERE id = 1 RETURNING *', [JSON.stringify(layout_preference)]);
        res.json(rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// AI PARSE ENDPOINT
app.post('/api/ai/parse', async (req, res) => {
    try {
        const { input } = req.body;

        if (!input || typeof input !== 'string') {
            return res.status(400).json({ error: 'Input is required' });
        }

        if (!process.env.OPENAI_API_KEY) {
            return res.status(500).json({ error: 'OPENAI_API_KEY is not configured' });
        }

        // Initialize OpenAI
        const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

        // Add current date to help with relative date parsing
        const today = new Date().toISOString().split('T')[0];
        const userMessage = `Today's date is ${today}. User input: "${input}"`;

        // Call OpenAI API
        const result = await openai.chat.completions.create({
            model: 'gpt-4o-mini',
            messages: [
                { role: 'system', content: SYSTEM_PROMPT },
                { role: 'user', content: userMessage }
            ],
            temperature: 0.3
        });

        const responseText = result.choices[0].message.content.trim();

        // Parse JSON response from Gemini
        let parsed;
        try {
            // Remove any markdown code blocks if present
            const cleanJson = responseText.replace(/```json\n?/g, '').replace(/```\n?/g, '').trim();
            parsed = JSON.parse(cleanJson);
        } catch (parseErr) {
            console.error('Failed to parse Gemini response:', responseText);
            return res.status(500).json({
                error: 'Failed to parse AI response',
                raw: responseText
            });
        }

        // Execute the action based on parsed result
        let dbResult;
        switch (parsed.action) {
            case 'CREATE_TODO':
                const todoData = parsed.data;
                const { rows: todoRows } = await db.query(
                    'INSERT INTO todos (title, description, due_date, tag) VALUES ($1, $2, $3, $4) RETURNING *',
                    [todoData.title, todoData.description || null, todoData.due_date || null, todoData.tag || null]
                );
                dbResult = todoRows[0];
                // Log creation to history
                await logTodoHistory(dbResult.id, 'created', null, null, JSON.stringify({ title: todoData.title, description: todoData.description, due_date: todoData.due_date, tag: todoData.tag }));
                return res.json({
                    success: true,
                    action: 'CREATE_TODO',
                    message: `Created todo: "${todoData.title}"`,
                    data: dbResult,
                    parsed: parsed.data
                });

            case 'CREATE_NOTE':
                const noteData = parsed.data;
                const { rows: noteRows } = await db.query(
                    'INSERT INTO notes (title, content) VALUES ($1, $2) RETURNING *',
                    [noteData.title, noteData.content]
                );
                dbResult = noteRows[0];
                // Log creation to history
                await logNoteHistory(dbResult.id, 'created', null, null, JSON.stringify({ title: noteData.title, content: noteData.content }));
                return res.json({
                    success: true,
                    action: 'CREATE_NOTE',
                    message: `Created note: "${noteData.title}"`,
                    data: dbResult,
                    parsed: parsed.data
                });

            case 'CREATE_LIST':
                const listData = parsed.data;
                const { rows: listRows } = await db.query(
                    'INSERT INTO lists (title, items) VALUES ($1, $2) RETURNING *',
                    [listData.title, JSON.stringify(listData.items)]
                );
                dbResult = listRows[0];
                // Log creation to history
                await logListHistory(dbResult.id, 'created', null, null, JSON.stringify({ title: listData.title, items: listData.items }));
                return res.json({
                    success: true,
                    action: 'CREATE_LIST',
                    message: `Created list: "${listData.title}" with ${listData.items.length} items`,
                    data: dbResult,
                    parsed: parsed.data
                });

            case 'UNKNOWN':
            default:
                return res.json({
                    success: false,
                    action: 'UNKNOWN',
                    message: parsed.message || "I didn't understand that. Try creating a todo, note, or list."
                });
        }
    } catch (err) {
        console.error('AI Parse Error:', err);
        res.status(500).json({ error: err.message });
    }
});

// Catch-all handler for SPA in production - must be after API routes
if (process.env.NODE_ENV === 'production') {
    app.get('/{*splat}', (req, res) => {
        res.sendFile(path.join(__dirname, '../client/dist/index.html'));
    });
}

app.listen(PORT, async () => {
    console.log(`Server is running on port ${PORT}`);
    await initDb();
});
