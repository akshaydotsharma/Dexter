/**
 * Shared test helpers.
 *
 * Tests run against a dedicated DB (default: dexter_test).
 * Set TEST_DATABASE_URL to override. Tables are truncated before each
 * suite — never against the dev DB.
 */

const path = require('path');
const fs = require('fs');
const { Pool } = require('pg');

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL
    || 'postgres://localhost:5432/dexter_test';

// Set DATABASE_URL to the test URL BEFORE the server's db module is required
// so the same connection pool serves the app and the test harness. Tests must
// require this helpers module before any server code.
process.env.DATABASE_URL = TEST_DATABASE_URL;
process.env.NODE_ENV = 'test';
// AI streaming tests stub streamText, but the real openaiClient still
// constructs a model handle eagerly — supply any non-empty value.
if (!process.env.OPENAI_API_KEY) process.env.OPENAI_API_KEY = 'test-key-not-used';

const pool = new Pool({ connectionString: TEST_DATABASE_URL });

const SCHEMA_PATH = path.join(__dirname, '..', 'schema.sql');
const MIGRATION_PATH = path.join(__dirname, '..', 'migration.sql');

async function applySchema() {
    const sql = fs.readFileSync(SCHEMA_PATH, 'utf8');
    await pool.query(sql);
}

async function applyMigration() {
    const sql = fs.readFileSync(MIGRATION_PATH, 'utf8');
    await pool.query(sql);
}

/**
 * Reset every table the test suite touches. Order matters: notes -> folders
 * because notes.folder_id references folders. ai_messages and draft_actions
 * are also wiped since the streaming tests insert into them.
 */
async function resetDb() {
    await pool.query(`
        TRUNCATE TABLE
            todo_history, note_history, list_history,
            todos, notes, lists, note_folders,
            draft_actions, ai_messages, dashboard_config
        RESTART IDENTITY CASCADE
    `);
}

async function close() {
    await pool.end();
}

/**
 * Insert N todos with sequential created_at values (1 second apart). Returns
 * the inserted rows. Tests use this to seed predictable orderings.
 */
async function seedTodos(n, opts = {}) {
    const rows = [];
    for (let i = 0; i < n; i++) {
        const created = new Date(Date.UTC(2026, 0, 1, 0, 0, i));
        const { rows: r } = await pool.query(
            `INSERT INTO todos (title, completed, created_at, updated_at, position)
             VALUES ($1, false, $2, $2, $3) RETURNING *`,
            [`todo ${i}`, created, opts.withPosition ? (i + 1) * 1000 : null]
        );
        rows.push(r[0]);
    }
    return rows;
}

async function seedNotes(specs) {
    // specs: [{ title, folderId|null, createdAt? }]
    const rows = [];
    for (let i = 0; i < specs.length; i++) {
        const s = specs[i];
        const created = s.createdAt || new Date(Date.UTC(2026, 0, 1, 0, 0, i));
        const { rows: r } = await pool.query(
            `INSERT INTO notes (title, content, folder_id, created_at, updated_at)
             VALUES ($1, '', $2, $3, $3) RETURNING *`,
            [s.title, s.folderId ?? null, created]
        );
        rows.push(r[0]);
    }
    return rows;
}

async function seedFolders(names) {
    const rows = [];
    for (let i = 0; i < names.length; i++) {
        const created = new Date(Date.UTC(2026, 0, 1, 0, 0, i));
        const { rows: r } = await pool.query(
            'INSERT INTO note_folders (name, created_at) VALUES ($1, $2) RETURNING *',
            [names[i], created]
        );
        rows.push(r[0]);
    }
    return rows;
}

async function seedLists(titles) {
    const rows = [];
    for (let i = 0; i < titles.length; i++) {
        const created = new Date(Date.UTC(2026, 0, 1, 0, 0, i));
        const { rows: r } = await pool.query(
            `INSERT INTO lists (title, items, created_at) VALUES ($1, '[]', $2) RETURNING *`,
            [titles[i], created]
        );
        rows.push(r[0]);
    }
    return rows;
}

async function getOrderedPositions(table, scopeWhere = '', scopeParams = []) {
    const sql = `SELECT id, position FROM ${table} ${scopeWhere ? 'WHERE ' + scopeWhere : ''} ORDER BY position ASC NULLS LAST, id ASC`;
    const { rows } = await pool.query(sql, scopeParams);
    return rows;
}

module.exports = {
    pool,
    applySchema,
    applyMigration,
    resetDb,
    seedTodos,
    seedNotes,
    seedFolders,
    seedLists,
    getOrderedPositions,
    close,
    TEST_DATABASE_URL,
};
