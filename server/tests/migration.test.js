/**
 * Migration backfill tests.
 *
 * Drops the test DB to a clean state, applies schema (without position
 * columns) by raw DDL, seeds rows with NULL positions, runs migration.sql,
 * and asserts:
 *   - every row has a position
 *   - positions are gap-1000 sequential per scope (global for todos/lists/folders,
 *     per-folder for notes)
 *   - re-running the migration is idempotent (no double-positioning)
 */

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const { pool, close } = require('./helpers');

const MIGRATION_PATH = path.join(__dirname, '..', 'migration.sql');

async function dropEverything() {
    await pool.query(`
        DROP TABLE IF EXISTS todo_history, note_history, list_history,
            todos, notes, lists, note_folders,
            draft_actions, ai_messages, dashboard_config CASCADE
    `);
}

async function legacySchema() {
    // Recreate the pre-migration shape WITHOUT position columns. We only
    // need the columns the migration's backfill reads from.
    await pool.query(`
        CREATE TABLE todos (
            id SERIAL PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT,
            completed BOOLEAN DEFAULT FALSE,
            due_date TIMESTAMPTZ,
            tag TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            deleted_at TIMESTAMP
        );
        CREATE TABLE note_folders (
            id SERIAL PRIMARY KEY,
            name TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE notes (
            id SERIAL PRIMARY KEY,
            folder_id INTEGER REFERENCES note_folders(id) ON DELETE CASCADE,
            title TEXT,
            content TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE lists (
            id SERIAL PRIMARY KEY,
            title TEXT NOT NULL,
            items JSONB DEFAULT '[]',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
    `);
}

async function applyMigration() {
    const sql = fs.readFileSync(MIGRATION_PATH, 'utf8');
    await pool.query(sql);
}

before(async () => {
    await dropEverything();
    await legacySchema();
});

after(async () => {
    await close();
});

test('backfills positions for todos with gap-1000 sequential values', async () => {
    // Seed 4 todos with strictly increasing created_at; expect positions
    // 1000, 2000, 3000, 4000 in created_at order.
    for (let i = 0; i < 4; i++) {
        const created = new Date(Date.UTC(2026, 0, 1, 0, 0, i));
        await pool.query(
            `INSERT INTO todos (title, created_at, updated_at) VALUES ($1, $2, $2)`,
            [`todo ${i}`, created]
        );
    }
    await applyMigration();
    const { rows } = await pool.query('SELECT id, title, position FROM todos ORDER BY created_at ASC');
    assert.strictEqual(rows.length, 4);
    rows.forEach((r, i) => {
        assert.strictEqual(r.position, (i + 1) * 1000, `row ${r.id} should be position ${(i + 1) * 1000}`);
    });
});

test('backfills lists with gap-1000 globally', async () => {
    for (let i = 0; i < 3; i++) {
        const created = new Date(Date.UTC(2026, 1, 1, 0, 0, i));
        await pool.query(
            `INSERT INTO lists (title, created_at) VALUES ($1, $2)`,
            [`list ${i}`, created]
        );
    }
    await applyMigration();
    const { rows } = await pool.query('SELECT position FROM lists ORDER BY created_at ASC');
    assert.deepStrictEqual(rows.map(r => r.position), [1000, 2000, 3000]);
});

test('backfills note_folders globally with gap-1000', async () => {
    for (let i = 0; i < 3; i++) {
        const created = new Date(Date.UTC(2026, 2, 1, 0, 0, i));
        await pool.query(
            `INSERT INTO note_folders (name, created_at) VALUES ($1, $2)`,
            [`folder ${i}`, created]
        );
    }
    await applyMigration();
    const { rows } = await pool.query('SELECT position FROM note_folders ORDER BY created_at ASC');
    assert.deepStrictEqual(rows.map(r => r.position), [1000, 2000, 3000]);
});

test('backfills notes per-folder (NULL folder is its own scope)', async () => {
    // First flush prior data so partitioning is clean. Notes already have
    // positions from earlier tests' migration runs; null them out so the
    // backfill has work to do.
    await pool.query('TRUNCATE notes RESTART IDENTITY');

    const { rows: folders } = await pool.query('SELECT id FROM note_folders ORDER BY id LIMIT 2');
    const [f1, f2] = folders;

    // 2 notes in folder1, 3 notes in folder2, 2 unfiled. Each scope should
    // start at 1000 and step 1000.
    let t = 0;
    const insert = async (folderId) => {
        const created = new Date(Date.UTC(2026, 3, 1, 0, 0, t++));
        await pool.query(
            `INSERT INTO notes (title, folder_id, created_at, updated_at) VALUES ($1, $2, $3, $3)`,
            [`n${t}`, folderId, created]
        );
    };
    await insert(f1.id); await insert(f1.id);
    await insert(f2.id); await insert(f2.id); await insert(f2.id);
    await insert(null);  await insert(null);

    await applyMigration();

    const { rows: r1 } = await pool.query('SELECT position FROM notes WHERE folder_id = $1 ORDER BY created_at', [f1.id]);
    const { rows: r2 } = await pool.query('SELECT position FROM notes WHERE folder_id = $1 ORDER BY created_at', [f2.id]);
    const { rows: r0 } = await pool.query('SELECT position FROM notes WHERE folder_id IS NULL ORDER BY created_at');

    assert.deepStrictEqual(r1.map(r => r.position), [1000, 2000]);
    assert.deepStrictEqual(r2.map(r => r.position), [1000, 2000, 3000]);
    assert.deepStrictEqual(r0.map(r => r.position), [1000, 2000]);
});

test('migration is idempotent - re-running does NOT double-position rows', async () => {
    // Snapshot positions, re-apply the migration, assert nothing changed.
    const { rows: before } = await pool.query('SELECT id, position FROM todos ORDER BY id');

    await applyMigration();
    await applyMigration();

    const { rows: after } = await pool.query('SELECT id, position FROM todos ORDER BY id');
    assert.deepStrictEqual(after, before, 'positions must be stable across reruns');
});

test('inserting a new row with NULL position then re-migrating fills only that row', async () => {
    await pool.query(
        `INSERT INTO todos (title, created_at, updated_at) VALUES ('fresh', NOW(), NOW())`
    );
    const { rows: before } = await pool.query('SELECT position FROM todos WHERE title = $1', ['fresh']);
    assert.strictEqual(before[0].position, null);

    await applyMigration();

    const { rows: after } = await pool.query('SELECT position FROM todos WHERE title = $1', ['fresh']);
    assert.notStrictEqual(after[0].position, null, 'new NULL row should get a position on re-run');
});
