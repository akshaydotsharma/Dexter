/**
 * Tests for POST /api/ai/capture — the headless voice-capture endpoint
 * powering the iOS side-button shortcut. As of #14 follow-up the endpoint
 * auto-executes EVERY draft the LLM produces (single, multi, create,
 * edit, add-to-list, delete) so the shortcut is fully autonomous.
 *
 *  - status: "executed" when at least one draft was applied; `executed`
 *    array carries the per-draft summaries used to build the spoken dialog
 *  - status: "needs_clarification" when LLM asks a follow-up question
 *  - status: "error" only when zero drafts AND tool errors
 *  - 400 when input is missing or empty
 *  - 500 when ANTHROPIC_API_KEY is missing
 */

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert');
const http = require('http');

const helpers = require('./helpers');
const { pool, resetDb, applySchema, applyMigration, close } = helpers;

// IMPORTANT: stubbing must happen BEFORE the server module is required so
// that index.js's `const { chatToDrafts } = require('./ai/chatToDrafts')`
// captures the stub off the already-cached module object.
process.env.ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || 'test-key-not-used';
const chatToDraftsModule = require('../ai/chatToDrafts');
const realChatToDrafts = chatToDraftsModule.chatToDrafts;

let nextChatToDraftsResponse = null;
let lastChatToDraftsCall = null;
chatToDraftsModule.chatToDrafts = async (input, options) => {
    lastChatToDraftsCall = { input, options };
    if (typeof nextChatToDraftsResponse === 'function') {
        return nextChatToDraftsResponse(input, options);
    }
    return nextChatToDraftsResponse;
};

const draftStore = require('../ai/draftStore');
const { app } = require('..');

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
    chatToDraftsModule.chatToDrafts = realChatToDrafts;
    await new Promise(resolve => server.close(resolve));
    await close();
});

beforeEach(async () => {
    await resetDb();
    nextChatToDraftsResponse = null;
    lastChatToDraftsCall = null;
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

// Insert a pending draft so the capture handler has a row to confirm.
// chatToDrafts itself writes to draft_actions in production; the stub
// returns a draft object only, so tests must seed the row themselves.
async function seedPendingDraft({ actionType, entityType, draftData }) {
    return draftStore.createDraft({
        actionType,
        entityType,
        entityId: null,
        draftData,
        originalInput: 'test input',
        model: 'test-model',
    });
}

// --- input validation --------------------------------------------------------

test('rejects missing input with 400', async () => {
    const { status, body } = await api('POST', '/api/ai/capture', {});
    assert.strictEqual(status, 400);
    assert.match(body.error, /input/i);
});

test('rejects whitespace-only input with 400', async () => {
    const { status, body } = await api('POST', '/api/ai/capture', { input: '   \n  ' });
    assert.strictEqual(status, 400);
    assert.match(body.error, /input/i);
});

test('rejects non-string input with 400', async () => {
    const { status } = await api('POST', '/api/ai/capture', { input: 123 });
    assert.strictEqual(status, 400);
});

// --- executed (auto-execution covers every draft type) ----------------------

test('auto-executes a single CREATE_TODO draft and creates the row', async () => {
    const draft = await seedPendingDraft({
        actionType: 'CREATE_TODO',
        entityType: 'todo',
        draftData: { title: 'Call John', description: null, due_date: '2026-05-04T15:00:00Z', tag: 'work' },
    });
    nextChatToDraftsResponse = {
        drafts: [draftStore.formatDraft(await draftStore.getDraftById(draft.id))],
        assistantText: 'I drafted a task.',
        followUpQuestion: null,
        errors: [],
    };

    const { status, body } = await api('POST', '/api/ai/capture', { input: 'remind me to call John tomorrow at 3' });
    assert.strictEqual(status, 200);
    assert.strictEqual(body.status, 'executed');
    assert.strictEqual(body.executed.length, 1);
    assert.strictEqual(body.executed[0].type, 'todo');
    assert.strictEqual(body.executed[0].action, 'created');
    assert.strictEqual(body.executed[0].title, 'Call John');
    assert.ok(body.executed[0].id, 'should return the new todo id');

    const { rows } = await pool.query('SELECT title, tag FROM todos WHERE id = $1', [body.executed[0].id]);
    assert.strictEqual(rows[0].title, 'Call John');
    assert.strictEqual(rows[0].tag, 'work');

    const updated = await draftStore.getDraftById(draft.id);
    assert.strictEqual(updated.status, 'confirmed');
    assert.strictEqual(updated.result_entity_id, body.executed[0].id);
});

test('auto-executes a CREATE_NOTE draft', async () => {
    const draft = await seedPendingDraft({
        actionType: 'CREATE_NOTE', entityType: 'note',
        draftData: { title: 'Trip ideas', content: 'Lisbon, Tokyo, Reykjavik' },
    });
    nextChatToDraftsResponse = {
        drafts: [draftStore.formatDraft(await draftStore.getDraftById(draft.id))],
        assistantText: 'Drafted the note.', followUpQuestion: null, errors: [],
    };

    const { body } = await api('POST', '/api/ai/capture', { input: 'note: Lisbon, Tokyo, Reykjavik' });
    assert.strictEqual(body.status, 'executed');
    assert.strictEqual(body.executed[0].type, 'note');
    assert.strictEqual(body.executed[0].action, 'created');

    const { rows } = await pool.query('SELECT content FROM notes WHERE id = $1', [body.executed[0].id]);
    assert.strictEqual(rows[0].content, 'Lisbon, Tokyo, Reykjavik');
});

test('auto-executes a CREATE_LIST draft with items', async () => {
    const draft = await seedPendingDraft({
        actionType: 'CREATE_LIST', entityType: 'list',
        draftData: { title: 'Groceries', items: ['eggs', 'milk', 'bread'] },
    });
    nextChatToDraftsResponse = {
        drafts: [draftStore.formatDraft(await draftStore.getDraftById(draft.id))],
        assistantText: '', followUpQuestion: null, errors: [],
    };

    const { body } = await api('POST', '/api/ai/capture', { input: 'shopping list eggs milk bread' });
    assert.strictEqual(body.status, 'executed');
    const { rows } = await pool.query('SELECT items FROM lists WHERE id = $1', [body.executed[0].id]);
    const items = typeof rows[0].items === 'string' ? JSON.parse(rows[0].items) : rows[0].items;
    assert.strictEqual(items.length, 3);
    assert.strictEqual(items[0].text, 'eggs');
});

test('auto-executes ADD_TO_LIST so shortcut adds items without UI confirmation', async () => {
    const { rows: listRows } = await pool.query(
        `INSERT INTO lists (title, items) VALUES ('Groceries', '[{"text":"eggs","checked":false}]') RETURNING id`
    );
    const listId = listRows[0].id;
    const draft = await seedPendingDraft({
        actionType: 'ADD_TO_LIST', entityType: 'list',
        draftData: { id: listId, new_items: [{ text: 'milk', checked: false }, { text: 'bread', checked: false }] },
    });
    nextChatToDraftsResponse = {
        drafts: [draftStore.formatDraft(await draftStore.getDraftById(draft.id))],
        assistantText: '', followUpQuestion: null, errors: [],
    };

    const { body } = await api('POST', '/api/ai/capture', { input: 'add milk and bread to my groceries list' });
    assert.strictEqual(body.status, 'executed');
    assert.strictEqual(body.executed[0].action, 'items_added');
    assert.match(body.executed[0].addedNames || '', /milk.*bread/);

    const { rows } = await pool.query('SELECT items FROM lists WHERE id = $1', [listId]);
    const items = typeof rows[0].items === 'string' ? JSON.parse(rows[0].items) : rows[0].items;
    assert.strictEqual(items.length, 3);
    assert.deepStrictEqual(items.map(i => i.text), ['eggs', 'milk', 'bread']);
});

test('auto-executes a multi-draft batch (every draft applies)', async () => {
    const todoDraft = await seedPendingDraft({
        actionType: 'CREATE_TODO', entityType: 'todo', draftData: { title: 'Task A' }
    });
    const noteDraft = await seedPendingDraft({
        actionType: 'CREATE_NOTE', entityType: 'note', draftData: { title: 'Note B', content: '...' }
    });
    nextChatToDraftsResponse = {
        drafts: [
            draftStore.formatDraft(await draftStore.getDraftById(todoDraft.id)),
            draftStore.formatDraft(await draftStore.getDraftById(noteDraft.id)),
        ],
        assistantText: 'I drafted 2 items.', followUpQuestion: null, errors: [],
    };

    const { body } = await api('POST', '/api/ai/capture', { input: 'task A and note B' });
    assert.strictEqual(body.status, 'executed');
    assert.strictEqual(body.executed.length, 2);

    const todoState = await draftStore.getDraftById(todoDraft.id);
    const noteState = await draftStore.getDraftById(noteDraft.id);
    assert.strictEqual(todoState.status, 'confirmed');
    assert.strictEqual(noteState.status, 'confirmed');

    const { rows } = await pool.query('SELECT count(*)::int AS n FROM todos');
    assert.strictEqual(rows[0].n, 1);
});

test('auto-executes UPDATE_TODO drafts (no UI gate)', async () => {
    const { rows: existing } = await pool.query(
        `INSERT INTO todos (title) VALUES ('old title') RETURNING id`
    );
    const todoId = existing[0].id;
    const draft = await seedPendingDraft({
        actionType: 'UPDATE_TODO', entityType: 'todo', draftData: { id: todoId, title: 'New title' }
    });
    nextChatToDraftsResponse = {
        drafts: [draftStore.formatDraft(await draftStore.getDraftById(draft.id))],
        assistantText: '', followUpQuestion: null, errors: [],
    };

    const { body } = await api('POST', '/api/ai/capture', { input: 'rename task to New title' });
    assert.strictEqual(body.status, 'executed');
    assert.strictEqual(body.executed[0].action, 'updated');

    const after = await draftStore.getDraftById(draft.id);
    assert.strictEqual(after.status, 'confirmed');
    const { rows } = await pool.query('SELECT title FROM todos WHERE id = $1', [todoId]);
    assert.strictEqual(rows[0].title, 'New title');
});

test('partial failure: applied drafts succeed, broken ones land in `failed`', async () => {
    const okDraft = await seedPendingDraft({
        actionType: 'CREATE_TODO', entityType: 'todo', draftData: { title: 'Works' }
    });
    const badDraft = await seedPendingDraft({
        actionType: 'UPDATE_TODO', entityType: 'todo', draftData: { id: 9999999, title: 'Misses' }
    });
    nextChatToDraftsResponse = {
        drafts: [
            draftStore.formatDraft(await draftStore.getDraftById(okDraft.id)),
            draftStore.formatDraft(await draftStore.getDraftById(badDraft.id)),
        ],
        assistantText: '', followUpQuestion: null, errors: [],
    };

    const { body } = await api('POST', '/api/ai/capture', { input: 'mixed' });
    assert.strictEqual(body.status, 'executed');
    assert.strictEqual(body.executed.length, 1);
    assert.strictEqual(body.failed.length, 1);
    assert.match(body.failed[0].reason, /not found/i);
});

// --- needs_clarification -----------------------------------------------------

test('returns needs_clarification when LLM has zero drafts and a follow-up', async () => {
    nextChatToDraftsResponse = {
        drafts: [],
        assistantText: 'When did you want to call John?',
        followUpQuestion: 'When did you want to call John?',
        errors: [],
    };

    const { body } = await api('POST', '/api/ai/capture', { input: 'remind me to call John' });
    assert.strictEqual(body.status, 'needs_clarification');
    assert.strictEqual(body.followUpQuestion, 'When did you want to call John?');

    const { rows } = await pool.query('SELECT count(*)::int AS n FROM todos');
    assert.strictEqual(rows[0].n, 0);
});

// --- error path --------------------------------------------------------------

test('returns status: error when chatToDrafts reports tool errors and no drafts', async () => {
    nextChatToDraftsResponse = {
        drafts: [],
        assistantText: '',
        followUpQuestion: null,
        errors: [{ tool: 'draft_task', message: 'something went wrong' }],
    };

    const { body } = await api('POST', '/api/ai/capture', { input: 'do the thing' });
    assert.strictEqual(body.status, 'error');
    assert.strictEqual(body.errors.length, 1);
});

// --- timezone is forwarded ---------------------------------------------------

test('forwards sessionId and timezone to chatToDrafts', async () => {
    nextChatToDraftsResponse = {
        drafts: [],
        assistantText: 'ok',
        followUpQuestion: 'ok?',
        errors: [],
    };

    await api('POST', '/api/ai/capture', {
        input: 'hi',
        sessionId: 'session-123',
        timezone: 'Asia/Singapore',
    });

    assert.strictEqual(lastChatToDraftsCall.input, 'hi');
    assert.strictEqual(lastChatToDraftsCall.options.sessionId, 'session-123');
    assert.strictEqual(lastChatToDraftsCall.options.tz, 'Asia/Singapore');
});
