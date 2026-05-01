/**
 * Preferences tests.
 *
 *  - deepMerge unit tests
 *  - hydrateLayoutPreference unit tests
 *  - GET /api/dashboard/config returns full defaults when stored is empty
 *  - PATCH /api/dashboard/config/preferences deep-merges partial updates
 *  - PATCH preserves widgets array
 *  - PATCH validates types via Zod (rejects bad enum)
 */

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert');
const http = require('http');

const helpers = require('./helpers');
const { pool, resetDb, applySchema, applyMigration, close } = helpers;

const { app } = require('..');
const { deepMerge, hydrateLayoutPreference, DEFAULT_PREFERENCES } = require('../preferences');

let server;
let baseUrl;

before(async () => {
    await applySchema();
    await applyMigration();
    server = http.createServer(app);
    await new Promise(resolve => server.listen(0, resolve));
    baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
    await new Promise(resolve => server.close(resolve));
    await close();
});

beforeEach(async () => {
    await resetDb();
    // Re-seed the dashboard_config row that schema.sql normally inserts; the
    // truncate above wipes it.
    await pool.query(`INSERT INTO dashboard_config (id, layout_preference) VALUES (1, '{"widgets": ["todos","notes","lists"]}')`);
});

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

// --- deepMerge ---------------------------------------------------------------

test('deepMerge merges plain objects key-wise', () => {
    const out = deepMerge({ a: 1, b: { x: 1, y: 2 } }, { b: { y: 99, z: 3 }, c: 4 });
    assert.deepStrictEqual(out, { a: 1, b: { x: 1, y: 99, z: 3 }, c: 4 });
});

test('deepMerge replaces arrays wholesale (does NOT concat)', () => {
    const out = deepMerge({ tags: ['a', 'b'] }, { tags: ['c'] });
    assert.deepStrictEqual(out.tags, ['c']);
});

test('deepMerge does not mutate the inputs', () => {
    const base = { a: { b: 1 } };
    const patch = { a: { c: 2 } };
    deepMerge(base, patch);
    assert.deepStrictEqual(base, { a: { b: 1 } });
    assert.deepStrictEqual(patch, { a: { c: 2 } });
});

// --- hydrateLayoutPreference -------------------------------------------------

test('hydrateLayoutPreference fills full preferences when stored is empty', () => {
    const out = hydrateLayoutPreference(null);
    assert.deepStrictEqual(out.preferences, DEFAULT_PREFERENCES);
    assert.deepStrictEqual(out.widgets, ['todos', 'notes', 'lists']);
});

test('hydrateLayoutPreference preserves stored widgets', () => {
    const out = hydrateLayoutPreference({ widgets: ['notes'], preferences: { theme: 'dark' } });
    assert.deepStrictEqual(out.widgets, ['notes']);
    assert.strictEqual(out.preferences.theme, 'dark');
    // Defaults still fill in for unset keys.
    assert.strictEqual(out.preferences.density, 'comfortable');
});

// --- HTTP ---------------------------------------------------------------------

test('GET /api/dashboard/config returns full defaults', async () => {
    const { status, body } = await api('GET', '/api/dashboard/config');
    assert.strictEqual(status, 200);
    assert.deepStrictEqual(body.layout_preference.widgets, ['todos', 'notes', 'lists']);
    assert.strictEqual(body.layout_preference.preferences.theme, 'system');
    assert.strictEqual(body.layout_preference.preferences.default_view, 'today');
    assert.strictEqual(body.layout_preference.preferences.ai.stream, true);
});

test('PATCH /api/dashboard/config/preferences deep-merges partial update', async () => {
    const { status, body } = await api('PATCH', '/api/dashboard/config/preferences', {
        theme: 'dark',
        ai: { model: 'gpt-4o-mini' },
    });
    assert.strictEqual(status, 200);
    assert.strictEqual(body.layout_preference.preferences.theme, 'dark');
    // ai.stream default preserved by deep-merge:
    assert.strictEqual(body.layout_preference.preferences.ai.stream, true);
    assert.strictEqual(body.layout_preference.preferences.ai.model, 'gpt-4o-mini');
});

test('PATCH /api/dashboard/config/preferences does NOT clobber widgets', async () => {
    // Set a custom widgets array first.
    await pool.query(
        `UPDATE dashboard_config SET layout_preference = $1 WHERE id = 1`,
        [JSON.stringify({ widgets: ['notes', 'todos'], preferences: { theme: 'light' } })]
    );

    const { body } = await api('PATCH', '/api/dashboard/config/preferences', { density: 'compact' });
    assert.deepStrictEqual(body.layout_preference.widgets, ['notes', 'todos']);
    assert.strictEqual(body.layout_preference.preferences.theme, 'light');
    assert.strictEqual(body.layout_preference.preferences.density, 'compact');
});

test('PATCH /api/dashboard/config/preferences rejects invalid enum', async () => {
    const { status, body } = await api('PATCH', '/api/dashboard/config/preferences', {
        theme: 'neon-pink',
    });
    assert.strictEqual(status, 400);
    assert.ok(body.error);
});

test('PATCH /api/dashboard/config/preferences rejects unknown keys (strict schema)', async () => {
    const { status } = await api('PATCH', '/api/dashboard/config/preferences', {
        not_a_key: true,
    });
    assert.strictEqual(status, 400);
});

test('PATCH then GET round-trips merged preferences', async () => {
    await api('PATCH', '/api/dashboard/config/preferences', {
        theme: 'dark',
        density: 'compact',
        dashboard_widget_order: ['notes', 'todos', 'lists'],
    });
    const { body } = await api('GET', '/api/dashboard/config');
    assert.strictEqual(body.layout_preference.preferences.theme, 'dark');
    assert.strictEqual(body.layout_preference.preferences.density, 'compact');
    assert.deepStrictEqual(body.layout_preference.preferences.dashboard_widget_order, ['notes', 'todos', 'lists']);
});

test('GET /api/config (legacy alias) returns the same hydrated shape', async () => {
    const { status, body } = await api('GET', '/api/config');
    assert.strictEqual(status, 200);
    assert.ok(body.layout_preference.preferences);
    assert.strictEqual(body.layout_preference.preferences.theme, 'system');
});
