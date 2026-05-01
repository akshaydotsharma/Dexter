/**
 * Reorder helper + endpoint tests.
 *
 * Covers:
 *  - reorder mid-list (interpolation between two neighbours)
 *  - reorder to top (afterId only)
 *  - reorder to bottom (beforeId only or both null)
 *  - reorder when neighbours are adjacent (forces renumber)
 *  - reorder a note across folders (notes endpoint specific)
 *  - HTTP layer: 404 on unknown id, 400 on bad body, history row written
 */

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert');
const http = require('http');

const helpers = require('./helpers');
const { pool, resetDb, applySchema, applyMigration, seedTodos, seedNotes, seedFolders, seedLists, close } = helpers;

// Require the app AFTER helpers (which set DATABASE_URL).
const { app } = require('..');
const { computeNewPosition } = require('../reorderHelpers');

let server;
let baseUrl;

before(async () => {
    // Reset to a known schema. applySchema is idempotent (CREATE TABLE IF NOT EXISTS).
    await applySchema();
    await applyMigration();

    server = http.createServer(app);
    await new Promise(resolve => server.listen(0, resolve));
    const { port } = server.address();
    baseUrl = `http://127.0.0.1:${port}`;
});

after(async () => {
    await new Promise(resolve => server.close(resolve));
    await close();
});

beforeEach(async () => {
    await resetDb();
});

/**
 * Tiny http client. node:fetch is fine; using it keeps tests dep-free.
 */
async function api(method, path, body) {
    const res = await fetch(`${baseUrl}${path}`, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: body == null ? undefined : JSON.stringify(body),
    });
    let data = null;
    const text = await res.text();
    if (text) { try { data = JSON.parse(text); } catch (_) { data = text; } }
    return { status: res.status, body: data };
}

// --- computeNewPosition (helper-level) ---------------------------------------

test('computeNewPosition: interpolates between two neighbours', async () => {
    const todos = await seedTodos(4, { withPosition: true });
    // Move the 4th todo (position 4000) between the 1st (1000) and 2nd (2000).
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const newPos = await computeNewPosition(
            client, 'todos', { deleted_at: null },
            todos[3].id, todos[0].id, todos[1].id
        );
        await client.query('COMMIT');
        assert.strictEqual(newPos, 1500, 'midpoint of 1000 and 2000');
    } finally {
        client.release();
    }
});

test('computeNewPosition: places at top when beforeId is null', async () => {
    const todos = await seedTodos(3, { withPosition: true });
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const newPos = await computeNewPosition(
            client, 'todos', { deleted_at: null },
            todos[2].id, null, todos[0].id
        );
        await client.query('COMMIT');
        assert.strictEqual(newPos, 500, 'half of the smallest existing position');
    } finally {
        client.release();
    }
});

test('computeNewPosition: places at bottom when afterId is null', async () => {
    const todos = await seedTodos(3, { withPosition: true });
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const newPos = await computeNewPosition(
            client, 'todos', { deleted_at: null },
            todos[0].id, todos[2].id, null
        );
        await client.query('COMMIT');
        assert.strictEqual(newPos, 4000, 'max existing (3000) + 1000');
    } finally {
        client.release();
    }
});

test('computeNewPosition: renumbers when neighbours are adjacent', async () => {
    // Seed 3 todos at positions 100, 101, 200. Moving the 3rd between 1st and 2nd
    // forces renumber because the gap between 100 and 101 is 1.
    const created1 = new Date(Date.UTC(2026, 0, 1, 0, 0, 0));
    const created2 = new Date(Date.UTC(2026, 0, 1, 0, 0, 1));
    const created3 = new Date(Date.UTC(2026, 0, 1, 0, 0, 2));
    const ins = (title, created, pos) => pool.query(
        `INSERT INTO todos (title, created_at, updated_at, position) VALUES ($1, $2, $2, $3) RETURNING *`,
        [title, created, pos]
    );
    const a = (await ins('a', created1, 100)).rows[0];
    const b = (await ins('b', created2, 101)).rows[0];
    const c = (await ins('c', created3, 200)).rows[0];

    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const newPos = await computeNewPosition(
            client, 'todos', { deleted_at: null },
            c.id, a.id, b.id
        );
        await client.query('COMMIT');

        const { rows } = await pool.query('SELECT id, position FROM todos ORDER BY position ASC');
        // Renumbering should produce 1000, 2000, 3000 with c sandwiched between a and b.
        assert.deepStrictEqual(rows.map(r => r.position), [1000, 2000, 3000]);
        // c lands at the slot between a and b => position 2000 in the renumbered scope.
        const cAfter = rows.find(r => r.id === c.id);
        assert.strictEqual(cAfter.position, newPos);
        assert.strictEqual(cAfter.position, 2000);
    } finally {
        client.release();
    }
});

// --- HTTP endpoints ----------------------------------------------------------

test('PATCH /api/todos/:id/reorder moves to bottom and writes history', async () => {
    const todos = await seedTodos(3, { withPosition: true });
    const targetId = todos[0].id; // currently first

    const { status, body } = await api('PATCH', `/api/todos/${targetId}/reorder`, {
        before_id: todos[2].id,
        after_id: null,
    });
    assert.strictEqual(status, 200);
    assert.strictEqual(body.id, targetId);
    assert.strictEqual(body.position, 4000);

    const { rows: history } = await pool.query(
        `SELECT action, field_changed, new_value FROM todo_history WHERE todo_id = $1`,
        [targetId]
    );
    assert.strictEqual(history.length, 1);
    assert.strictEqual(history[0].action, 'reorder');
    assert.strictEqual(history[0].field_changed, 'position');
    assert.strictEqual(history[0].new_value, '4000');
});

test('PATCH /api/lists/:id/reorder interpolates between two neighbours', async () => {
    const lists = await seedLists(['a', 'b', 'c']);
    // Apply backfill first to give them positions 1000, 2000, 3000.
    await applyMigration();
    const refreshed = (await pool.query('SELECT * FROM lists ORDER BY position')).rows;

    // Move list c (position 3000) between a (1000) and b (2000).
    const { status, body } = await api('PATCH', `/api/lists/${refreshed[2].id}/reorder`, {
        before_id: refreshed[0].id,
        after_id: refreshed[1].id,
    });
    assert.strictEqual(status, 200);
    assert.strictEqual(body.position, 1500);
});

test('PATCH /api/note_folders/:id/reorder', async () => {
    const folders = await seedFolders(['x', 'y', 'z']);
    await applyMigration();
    const fresh = (await pool.query('SELECT * FROM note_folders ORDER BY position')).rows;

    const { status, body } = await api('PATCH', `/api/note_folders/${fresh[2].id}/reorder`, {
        before_id: null,
        after_id: fresh[0].id,
    });
    assert.strictEqual(status, 200);
    assert.strictEqual(body.position, 500);
});

test('PATCH /api/notes/:id/reorder within same folder', async () => {
    const [f1] = await seedFolders(['F1']);
    const notes = await seedNotes([
        { title: 'n1', folderId: f1.id },
        { title: 'n2', folderId: f1.id },
        { title: 'n3', folderId: f1.id },
    ]);
    await applyMigration();
    const fresh = (await pool.query('SELECT * FROM notes ORDER BY position')).rows;

    // Move n3 to the very top.
    const { status, body } = await api('PATCH', `/api/notes/${fresh[2].id}/reorder`, {
        before_id: null,
        after_id: fresh[0].id,
    });
    assert.strictEqual(status, 200);
    assert.strictEqual(body.position, 500);
    assert.strictEqual(body.folder_id, f1.id);
});

test('PATCH /api/notes/:id/reorder across folders writes both moved + reorder history', async () => {
    const [f1, f2] = await seedFolders(['F1', 'F2']);
    const notes = await seedNotes([
        { title: 'a', folderId: f1.id },
        { title: 'b', folderId: f1.id },
        { title: 'c', folderId: f2.id },
    ]);
    await applyMigration();

    // Move note 'a' to folder f2 at the top.
    const noteA = notes[0];
    const cInF2 = (await pool.query('SELECT id FROM notes WHERE folder_id = $1 ORDER BY position', [f2.id])).rows[0];

    const { status, body } = await api('PATCH', `/api/notes/${noteA.id}/reorder`, {
        before_id: null,
        after_id: cInF2.id,
        folder_id: f2.id,
    });
    assert.strictEqual(status, 200);
    assert.strictEqual(body.folder_id, f2.id);
    assert.ok(body.position < 1000, 'should land above the existing F2 note');

    const { rows: history } = await pool.query(
        `SELECT action, field_changed, old_value, new_value FROM note_history
         WHERE note_id = $1 ORDER BY id`,
        [noteA.id]
    );
    const actions = history.map(h => h.action);
    assert.ok(actions.includes('moved'), 'cross-folder move should log a moved entry');
    assert.ok(actions.includes('reorder'), 'reorder should also be logged');
});

test('PATCH /api/notes/:id/reorder to unfiled (folder_id: null)', async () => {
    const [f1] = await seedFolders(['F1']);
    const notes = await seedNotes([
        { title: 'a', folderId: f1.id },
        { title: 'unfiled1', folderId: null },
    ]);
    await applyMigration();

    const noteA = notes[0];
    const { status, body } = await api('PATCH', `/api/notes/${noteA.id}/reorder`, {
        before_id: null,
        after_id: null,
        folder_id: null,
    });
    assert.strictEqual(status, 200);
    assert.strictEqual(body.folder_id, null);
});

test('PATCH /api/todos/:id/reorder rejects bad body', async () => {
    const todos = await seedTodos(2, { withPosition: true });
    const { status } = await api('PATCH', `/api/todos/${todos[0].id}/reorder`, {
        before_id: 'not-a-number',
    });
    assert.strictEqual(status, 400);
});

test('PATCH /api/todos/:id/reorder on missing id falls through (no row updated)', async () => {
    // computeNewPosition still produces a value, but the UPDATE matches no
    // rows so the route returns 404 via the rows[0] guard.
    const { status } = await api('PATCH', `/api/todos/999999/reorder`, {
        before_id: null, after_id: null,
    });
    assert.strictEqual(status, 404);
});
