/**
 * Sync endpoint tests for #14.
 *
 * Spins up the real Express app against the test DB and exercises:
 *   GET /api/sync/changes?since_version=N
 *     - returns rows with version > N across all four synced tables
 *     - reports a max_version watermark the client can use next
 *     - includes soft-deleted rows so deletes propagate
 *
 *   POST /api/sync/upsert
 *     - INSERTs a new row keyed by client_uuid
 *     - UPDATEs an existing row when client's updated_at is newer
 *     - REJECTs (server wins) when server's updated_at is newer; returns
 *       the server's row in the rejection so the client can adopt it
 */

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert');
const http = require('node:http');

const { pool, applySchema, applyMigration, resetDb, close } = require('./helpers');

let server;
let baseUrl;

before(async () => {
    await applySchema();
    await applyMigration();
    const { app } = require('../index');
    server = http.createServer(app);
    await new Promise((resolve) => server.listen(0, resolve));
    const { port } = server.address();
    baseUrl = `http://127.0.0.1:${port}`;
});

beforeEach(async () => {
    await resetDb();
});

after(async () => {
    await new Promise((resolve) => server.close(resolve));
    await close();
});

async function fetchJSON(method, path, body) {
    const url = baseUrl + path;
    const opts = {
        method,
        headers: { 'Content-Type': 'application/json' },
    };
    const res = await fetch(url, body !== undefined ? { ...opts, body: JSON.stringify(body) } : opts);
    const text = await res.text();
    return { status: res.status, body: text ? JSON.parse(text) : null };
}

test('GET /api/sync/changes returns rows with version > since_version', async () => {
    // Seed three rows directly so they have known initial versions.
    await pool.query(`INSERT INTO todos (title) VALUES ('alpha'), ('bravo'), ('charlie')`);

    const { status, body } = await fetchJSON('GET', '/api/sync/changes?since_version=0');
    assert.strictEqual(status, 200);
    assert.strictEqual(body.todos.length, 3);
    assert.ok(body.max_version > 0);

    // Watermark on the second row's version: should return only the third.
    const sortedVersions = body.todos.map((t) => Number(t.version)).sort((a, b) => a - b);
    const second = sortedVersions[1];
    const after = await fetchJSON('GET', `/api/sync/changes?since_version=${second}`);
    assert.strictEqual(after.body.todos.length, 1);
    assert.ok(Number(after.body.todos[0].version) > second);
});

test('GET /api/sync/changes includes soft-deleted rows as tombstones', async () => {
    const { rows } = await pool.query(`INSERT INTO notes (title) VALUES ('alpha') RETURNING *`);
    const note = rows[0];

    // Soft-delete via the actual DELETE endpoint, which now updates deleted_at.
    const del = await fetchJSON('DELETE', `/api/notes/${note.id}`);
    assert.strictEqual(del.status, 204);

    const { body } = await fetchJSON('GET', '/api/sync/changes?since_version=0');
    assert.strictEqual(body.notes.length, 1);
    assert.ok(body.notes[0].deleted_at !== null, 'deleted_at must be present on the tombstone');
});

test('POST /api/sync/upsert INSERTs a new row keyed by client_uuid', async () => {
    const clientUuid = '11111111-1111-4111-8111-111111111111';
    const { status, body } = await fetchJSON('POST', '/api/sync/upsert', {
        todos: [{
            client_uuid: clientUuid,
            title: 'from-iphone',
            completed: false,
            updated_at: new Date().toISOString(),
        }],
    });
    assert.strictEqual(status, 200);
    assert.strictEqual(body.applied.todos.length, 1);
    assert.strictEqual(body.applied.todos[0].title, 'from-iphone');
    assert.strictEqual(body.applied.todos[0].client_uuid, clientUuid);

    const { rows } = await pool.query(
        `SELECT * FROM todos WHERE client_uuid = $1`,
        [clientUuid]
    );
    assert.strictEqual(rows.length, 1);
});

test('POST /api/sync/upsert UPDATEs when client updated_at is newer', async () => {
    const { rows } = await pool.query(`INSERT INTO todos (title) VALUES ('original') RETURNING *`);
    const todo = rows[0];

    // Wait so the new updated_at is strictly greater.
    await new Promise((r) => setTimeout(r, 30));
    const newer = new Date(Date.now() + 60_000).toISOString();
    const { body } = await fetchJSON('POST', '/api/sync/upsert', {
        todos: [{
            client_uuid: todo.client_uuid,
            title: 'edited-on-phone',
            updated_at: newer,
        }],
    });
    assert.strictEqual(body.applied.todos.length, 1);
    assert.strictEqual(body.applied.todos[0].title, 'edited-on-phone');
    assert.strictEqual(body.rejected.todos.length, 0);
});

test('POST /api/sync/upsert REJECTs when server updated_at is newer (server wins)', async () => {
    const { rows } = await pool.query(`INSERT INTO todos (title) VALUES ('original') RETURNING *`);
    const todo = rows[0];

    // Bump server side via a real UPDATE (trigger refreshes updated_at).
    await new Promise((r) => setTimeout(r, 30));
    await pool.query(`UPDATE todos SET title = 'edited-on-mac' WHERE id = $1`, [todo.id]);

    // Client's updated_at is the OLD value, so server should win.
    const { body } = await fetchJSON('POST', '/api/sync/upsert', {
        todos: [{
            client_uuid: todo.client_uuid,
            title: 'stale-from-phone',
            updated_at: todo.updated_at,
        }],
    });

    assert.strictEqual(body.applied.todos.length, 0);
    assert.strictEqual(body.rejected.todos.length, 1);
    assert.strictEqual(body.rejected.todos[0].reason, 'server_newer');
    assert.strictEqual(body.rejected.todos[0].server_row.title, 'edited-on-mac');

    // Verify DB still has the server's value.
    const { rows: after } = await pool.query(`SELECT title FROM todos WHERE id = $1`, [todo.id]);
    assert.strictEqual(after[0].title, 'edited-on-mac');
});

test('POST /api/sync/upsert can submit a soft-delete intent via deleted_at', async () => {
    const { rows } = await pool.query(`INSERT INTO lists (title) VALUES ('groceries') RETURNING *`);
    const list = rows[0];

    await new Promise((r) => setTimeout(r, 30));
    const newer = new Date(Date.now() + 60_000).toISOString();
    const { body } = await fetchJSON('POST', '/api/sync/upsert', {
        lists: [{
            client_uuid: list.client_uuid,
            deleted_at: newer,
            updated_at: newer,
        }],
    });

    assert.strictEqual(body.applied.lists.length, 1);
    assert.ok(body.applied.lists[0].deleted_at !== null);

    // GET /api/lists must NOT return it any longer.
    const { body: listsBody } = await fetchJSON('GET', '/api/lists');
    assert.strictEqual(listsBody.length, 0);
});

test('POST /api/sync/upsert handles multiple tables in one batch', async () => {
    const { body } = await fetchJSON('POST', '/api/sync/upsert', {
        todos: [{
            client_uuid: '22222222-2222-4222-8222-222222222222',
            title: 't1',
            updated_at: new Date().toISOString(),
        }],
        notes: [{
            client_uuid: '33333333-3333-4333-8333-333333333333',
            title: 'n1',
            content: 'hello',
            updated_at: new Date().toISOString(),
        }],
        lists: [{
            client_uuid: '44444444-4444-4444-8444-444444444444',
            title: 'l1',
            items: [{ text: 'milk', checked: false }],
            updated_at: new Date().toISOString(),
        }],
    });

    assert.strictEqual(body.applied.todos.length, 1);
    assert.strictEqual(body.applied.notes.length, 1);
    assert.strictEqual(body.applied.lists.length, 1);
    assert.ok(body.max_version > 0);
});
