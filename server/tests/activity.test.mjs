/**
 * Activity timeline endpoint tests for issue #16.
 *
 * Exercises GET /api/dashboard/activity against the personal_dashboard_test DB.
 * Covers: empty state, mixed-type ordering, pagination round-trip, type filter,
 * soft-delete exclusion/inclusion, note parent, list snippet, and limit clamping.
 */

import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createRequire } from 'node:module';

// helpers.js is CommonJS; import works because Node ESM can import CJS modules.
const require = createRequire(import.meta.url);
const { pool, applySchema, applyMigration, resetDb, close } = require('./helpers.js');

let server;
let baseUrl;

before(async () => {
    await applySchema();
    await applyMigration();
    // helpers.js sets DATABASE_URL to the test DB before this import fires,
    // so the server's db pool connects to the right database.
    const { app } = require('../index');
    server = http.createServer(app);
    await new Promise((resolve) => server.listen(0, resolve));
    const addr = server.address();
    baseUrl = `http://127.0.0.1:${addr.port}`;
});

beforeEach(async () => {
    await resetDb();
});

after(async () => {
    await new Promise((resolve) => server.close(resolve));
    await close();
});

/** Convenience: GET a path and return { status, body }. */
async function get(path) {
    const res = await fetch(baseUrl + path);
    const text = await res.text();
    return { status: res.status, body: text ? JSON.parse(text) : null };
}

// ─── Helper seeders with explicit created_at values ──────────────────────────

async function insertTodo(title, { description = null, createdAt = new Date(), deletedAt = null } = {}) {
    const { rows } = await pool.query(
        `INSERT INTO todos (title, description, created_at, updated_at, deleted_at)
         VALUES ($1, $2, $3, $3, $4) RETURNING *`,
        [title, description, createdAt, deletedAt]
    );
    return rows[0];
}

async function insertNote(title, { content = null, folderId = null, createdAt = new Date(), deletedAt = null } = {}) {
    const { rows } = await pool.query(
        `INSERT INTO notes (title, content, folder_id, created_at, updated_at, deleted_at)
         VALUES ($1, $2, $3, $4, $4, $5) RETURNING *`,
        [title, content, folderId, createdAt, deletedAt]
    );
    return rows[0];
}

async function insertFolder(name, { createdAt = new Date(), deletedAt = null } = {}) {
    const { rows } = await pool.query(
        `INSERT INTO note_folders (name, created_at, updated_at, deleted_at)
         VALUES ($1, $2, $2, $3) RETURNING *`,
        [name, createdAt, deletedAt]
    );
    return rows[0];
}

async function insertList(title, { items = [], createdAt = new Date(), deletedAt = null } = {}) {
    const { rows } = await pool.query(
        `INSERT INTO lists (title, items, created_at, updated_at, deleted_at)
         VALUES ($1, $2::jsonb, $3, $3, $4) RETURNING *`,
        [title, JSON.stringify(items), createdAt, deletedAt]
    );
    return rows[0];
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test('1. empty state returns {items:[], nextCursor:null}', async () => {
    const { status, body } = await get('/api/dashboard/activity');
    assert.equal(status, 200);
    assert.deepEqual(body, { items: [], nextCursor: null });
});

test('2. mixed-type fixtures return items in reverse-chronological order', async () => {
    // Insert four items with distinct timestamps: folder first, then todo, note, list
    const t0 = new Date('2026-01-01T10:00:00.000Z');
    const t1 = new Date('2026-01-01T11:00:00.000Z');
    const t2 = new Date('2026-01-01T12:00:00.000Z');
    const t3 = new Date('2026-01-01T13:00:00.000Z');

    await insertFolder('Work',   { createdAt: t0 });
    await insertTodo('Buy milk', { createdAt: t1 });
    await insertNote('Meeting notes', { createdAt: t2 });
    await insertList('Groceries', { createdAt: t3 });

    const { status, body } = await get('/api/dashboard/activity?limit=10');
    assert.equal(status, 200);

    // Most recent first
    const types = body.items.map((i) => i.type);
    assert.deepEqual(types, ['list', 'note', 'todo', 'folder']);

    // Verify ISO timestamps are descending
    const timestamps = body.items.map((i) => i.createdAt);
    for (let i = 1; i < timestamps.length; i++) {
        assert.ok(timestamps[i - 1] >= timestamps[i],
            `Expected descending order at position ${i}`);
    }

    // nextCursor is null because we got all 4 items with limit=10
    assert.equal(body.nextCursor, null);
});

test('3. pagination round-trip: page 1 + cursor -> page 2; no duplicates, no gaps', async () => {
    // Seed 5 items at distinct timestamps so we can paginate with limit=3
    const base = new Date('2026-02-01T00:00:00.000Z');
    for (let i = 0; i < 5; i++) {
        const t = new Date(base.getTime() + i * 60_000);
        await insertTodo(`todo-${i}`, { createdAt: t });
    }

    // Full set (no pagination) to compare against
    const { body: full } = await get('/api/dashboard/activity?limit=100');
    assert.equal(full.items.length, 5);

    // Page 1
    const { body: page1 } = await get('/api/dashboard/activity?limit=3');
    assert.equal(page1.items.length, 3, 'page 1 should have 3 items');
    assert.notEqual(page1.nextCursor, null, 'page 1 should have a nextCursor');

    // Page 2
    const { body: page2 } = await get(`/api/dashboard/activity?limit=3&cursor=${encodeURIComponent(page1.nextCursor)}`);
    assert.equal(page2.items.length, 2, 'page 2 should have the remaining 2 items');
    assert.equal(page2.nextCursor, null, 'page 2 should have no nextCursor');

    // Concatenated pages must equal full set
    const combined = [...page1.items, ...page2.items];
    assert.equal(combined.length, 5);

    const fullIds = full.items.map((i) => `${i.type}:${i.id}`);
    const combinedIds = combined.map((i) => `${i.type}:${i.id}`);
    assert.deepEqual(combinedIds, fullIds, 'Combined pages should match full result exactly');

    // No duplicates
    const uniqueIds = new Set(combinedIds);
    assert.equal(uniqueIds.size, 5, 'No duplicate items across pages');
});

test('4. ?type=note filter returns only notes', async () => {
    await insertTodo('A todo');
    await insertNote('A note');
    await insertList('A list');
    await insertFolder('A folder');

    const { status, body } = await get('/api/dashboard/activity?type=note');
    assert.equal(status, 200);
    assert.equal(body.items.length, 1);
    assert.equal(body.items[0].type, 'note');
    assert.equal(body.items[0].title, 'A note');
});

test('5. soft-deleted rows excluded by default; included when includeDeleted=1', async () => {
    const now = new Date();
    await insertTodo('Active todo',   { createdAt: now });
    await insertTodo('Deleted todo',  { createdAt: now, deletedAt: now });
    await insertNote('Active note',   { createdAt: now });
    await insertNote('Deleted note',  { createdAt: now, deletedAt: now });

    // Default: only active items
    const { body: defaultBody } = await get('/api/dashboard/activity');
    const defaultTitles = defaultBody.items.map((i) => i.title);
    assert.ok(defaultTitles.includes('Active todo'),    'Active todo should be present');
    assert.ok(defaultTitles.includes('Active note'),    'Active note should be present');
    assert.ok(!defaultTitles.includes('Deleted todo'),  'Deleted todo should be excluded');
    assert.ok(!defaultTitles.includes('Deleted note'),  'Deleted note should be excluded');

    // With includeDeleted=1: all four items present
    const { body: allBody } = await get('/api/dashboard/activity?includeDeleted=1');
    const allTitles = allBody.items.map((i) => i.title);
    assert.ok(allTitles.includes('Deleted todo'), 'Deleted todo should appear with includeDeleted=1');
    assert.ok(allTitles.includes('Deleted note'), 'Deleted note should appear with includeDeleted=1');
    assert.equal(allBody.items.length, 4);
});

test('6. notes show parent populated when folder_id is set, null when not', async () => {
    const folder = await insertFolder('Work');
    await insertNote('In folder',   { folderId: folder.id });
    await insertNote('Unfiled',     { folderId: null });

    const { body } = await get('/api/dashboard/activity?type=note');
    assert.equal(body.items.length, 2);

    const inFolder = body.items.find((i) => i.title === 'In folder');
    const unfiled  = body.items.find((i) => i.title === 'Unfiled');

    assert.ok(inFolder, 'In-folder note must be present');
    assert.ok(unfiled,  'Unfiled note must be present');
    assert.equal(inFolder.parent, 'Work', 'parent should be the folder name');
    assert.equal(unfiled.parent,  null,   'parent should be null for unfiled note');
});

test('7a. list with empty items array returns snippet: null', async () => {
    await insertList('Empty list', { items: [] });

    const { body } = await get('/api/dashboard/activity?type=list');
    assert.equal(body.items.length, 1);
    assert.equal(body.items[0].snippet, null, 'Empty list should have null snippet');
});

test('7b. list with items returns first item text as snippet', async () => {
    await insertList('Shopping', { items: [{ text: 'Milk', checked: false }, { text: 'Eggs', checked: false }] });

    const { body } = await get('/api/dashboard/activity?type=list');
    assert.equal(body.items.length, 1);
    assert.equal(body.items[0].snippet, 'Milk', 'Snippet should be first item text');
});

test('8. limit clamping: limit=0 -> 1, limit=999 -> 100', async () => {
    // Seed 10 todos so there is data to paginate.
    for (let i = 0; i < 10; i++) {
        await insertTodo(`todo-${i}`);
    }

    // limit=0 should be clamped to 1 (one item returned)
    const { body: withZero } = await get('/api/dashboard/activity?limit=0');
    assert.equal(withZero.items.length, 1, 'limit=0 should clamp to 1');

    // limit=999 should be clamped to 100 (only 10 items exist so we get 10)
    const { body: withHuge } = await get('/api/dashboard/activity?limit=999');
    assert.equal(withHuge.items.length, 10, 'limit=999 should clamp to 100 (only 10 items exist)');
    // nextCursor is null because 10 < 100
    assert.equal(withHuge.nextCursor, null, 'nextCursor should be null when returned count < clamped limit');
});
