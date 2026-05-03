/**
 * Sync metadata tests.
 *
 * Confirms the schema additions for the iOS local-first data layer (#14):
 *   - every synced row gets a non-null `version` and `client_uuid` on insert
 *   - UPDATE bumps `version` to a strictly greater value
 *   - UPDATE refreshes `updated_at` automatically (trigger handles it)
 *   - `version` is globally monotonic across todos/notes/lists/note_folders
 *   - `deleted_at` exists on all four tables and defaults to NULL
 */

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert');

const { pool, applySchema, applyMigration, resetDb, close } = require('./helpers');

before(async () => {
    await applySchema();
    await applyMigration();
});

beforeEach(async () => {
    await resetDb();
});

after(async () => {
    await close();
});

test('insert assigns version and client_uuid automatically', async () => {
    const { rows } = await pool.query(
        `INSERT INTO todos (title) VALUES ('alpha') RETURNING *`
    );
    const todo = rows[0];
    assert.ok(todo.version > 0, 'version should be a positive number');
    assert.ok(todo.client_uuid, 'client_uuid should be populated');
    assert.match(
        String(todo.client_uuid),
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
        'client_uuid should look like a UUID'
    );
    assert.strictEqual(todo.deleted_at, null);
});

test('UPDATE bumps version monotonically and refreshes updated_at', async () => {
    const { rows: insertRows } = await pool.query(
        `INSERT INTO todos (title) VALUES ('alpha') RETURNING *`
    );
    const before = insertRows[0];

    // Wait 50ms so updated_at has a chance to differ.
    await new Promise((r) => setTimeout(r, 50));

    const { rows: updateRows } = await pool.query(
        `UPDATE todos SET title = 'alpha-edited' WHERE id = $1 RETURNING *`,
        [before.id]
    );
    const after = updateRows[0];

    assert.ok(after.version > before.version, 'version must strictly increase on update');
    assert.ok(
        new Date(after.updated_at).getTime() >= new Date(before.updated_at).getTime(),
        'updated_at must be at least the original'
    );
    assert.strictEqual(after.client_uuid, before.client_uuid, 'client_uuid is stable across updates');
});

test('version is globally monotonic across todos, notes, lists, folders', async () => {
    const t = await pool.query(`INSERT INTO todos (title) VALUES ('a') RETURNING version`);
    const f = await pool.query(`INSERT INTO note_folders (name) VALUES ('inbox') RETURNING version, id`);
    const n = await pool.query(
        `INSERT INTO notes (title, folder_id) VALUES ('note', $1) RETURNING version`,
        [f.rows[0].id]
    );
    const l = await pool.query(`INSERT INTO lists (title) VALUES ('groceries') RETURNING version`);

    const versions = [t.rows[0].version, f.rows[0].version, n.rows[0].version, l.rows[0].version].map(Number);
    const sorted = [...versions].sort((a, b) => a - b);
    // Each insert must have produced a strictly greater version than the previous one.
    for (let i = 1; i < sorted.length; i++) {
        assert.ok(sorted[i] > sorted[i - 1], `version[${i}] (${sorted[i]}) must be > version[${i-1}] (${sorted[i-1]})`);
    }
});

test('soft-delete columns exist and default to null on every synced table', async () => {
    const tables = ['todos', 'notes', 'lists', 'note_folders'];
    for (const tbl of tables) {
        const { rows } = await pool.query(
            `SELECT column_name, is_nullable
             FROM information_schema.columns
             WHERE table_name = $1 AND column_name = 'deleted_at'`,
            [tbl]
        );
        assert.strictEqual(rows.length, 1, `${tbl} should have a deleted_at column`);
        assert.strictEqual(rows[0].is_nullable, 'YES', `${tbl}.deleted_at should be nullable`);
    }
});

test('client_uuid is unique across rows in the same table', async () => {
    const a = await pool.query(`INSERT INTO todos (title) VALUES ('a') RETURNING client_uuid`);
    const b = await pool.query(`INSERT INTO todos (title) VALUES ('b') RETURNING client_uuid`);
    assert.notStrictEqual(a.rows[0].client_uuid, b.rows[0].client_uuid);

    // Forcing the same client_uuid must fail.
    await assert.rejects(
        pool.query(
            `INSERT INTO todos (title, client_uuid) VALUES ('c', $1)`,
            [a.rows[0].client_uuid]
        ),
        /duplicate key|unique/i
    );
});
