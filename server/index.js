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

// TODOS
app.get('/api/todos', async (req, res) => {
    try {
        const { rows } = await db.query('SELECT * FROM todos ORDER BY created_at DESC');
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
        res.status(201).json(rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.put('/api/todos/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { title, description, completed, due_date, tag } = req.body;

        console.log('=== UPDATE TODO REQUEST ===');
        console.log('ID:', id);
        console.log('Request body:', req.body);
        console.log('due_date value:', due_date);
        console.log('due_date type:', typeof due_date);

        // Build dynamic update query based on provided fields
        const updates = [];
        const values = [];
        let paramCount = 1;

        if (title !== undefined) {
            updates.push(`title = $${paramCount++}`);
            values.push(title);
        }
        if (description !== undefined) {
            updates.push(`description = $${paramCount++}`);
            values.push(description);
        }
        if (completed !== undefined) {
            updates.push(`completed = $${paramCount++}`);
            values.push(completed);
        }
        if (due_date !== undefined) {
            updates.push(`due_date = $${paramCount++}`);
            values.push(due_date);
            console.log('Adding due_date to update:', due_date);
        }
        if (tag !== undefined) {
            updates.push(`tag = $${paramCount++}`);
            values.push(tag);
        }

        if (updates.length === 0) {
            return res.status(400).json({ error: 'No fields to update' });
        }

        values.push(id);
        const query = `UPDATE todos SET ${updates.join(', ')} WHERE id = $${paramCount} RETURNING *`;
        console.log('SQL Query:', query);
        console.log('Values:', values);

        const { rows } = await db.query(query, values);
        console.log('Updated todo:', rows[0]);
        console.log('=== END UPDATE ===\n');

        res.json(rows[0]);
    } catch (err) {
        console.error('Error updating todo:', err);
        res.status(500).json({ error: err.message });
    }
});

app.delete('/api/todos/:id', async (req, res) => {
    try {
        const { id } = req.params;
        await db.query('DELETE FROM todos WHERE id = $1', [id]);
        res.status(204).send();
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

app.post('/api/notes', async (req, res) => {
    try {
        const { title, content, folder_id } = req.body;
        const { rows } = await db.query(
            'INSERT INTO notes (title, content, folder_id, updated_at) VALUES ($1, $2, $3, CURRENT_TIMESTAMP) RETURNING *',
            [title, content, folder_id || null]
        );
        res.status(201).json(rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.put('/api/notes/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { title, content, folder_id } = req.body;
        const { rows } = await db.query(
            'UPDATE notes SET title = $1, content = $2, folder_id = $3, updated_at = CURRENT_TIMESTAMP WHERE id = $4 RETURNING *',
            [title, content, folder_id !== undefined ? folder_id : null, id]
        );
        res.json(rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.delete('/api/notes/:id', async (req, res) => {
    try {
        const { id } = req.params;
        await db.query('DELETE FROM notes WHERE id = $1', [id]);
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

app.post('/api/lists', async (req, res) => {
    try {
        const { title, items } = req.body;
        const { rows } = await db.query('INSERT INTO lists (title, items) VALUES ($1, $2) RETURNING *', [title, JSON.stringify(items)]);
        res.status(201).json(rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.put('/api/lists/:id', async (req, res) => {
    try {
        const { id } = req.params;
        const { title, items } = req.body;
        const { rows } = await db.query('UPDATE lists SET title = $1, items = $2 WHERE id = $3 RETURNING *', [title, JSON.stringify(items), id]);
        res.json(rows[0]);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.delete('/api/lists/:id', async (req, res) => {
    try {
        const { id } = req.params;
        await db.query('DELETE FROM lists WHERE id = $1', [id]);
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
