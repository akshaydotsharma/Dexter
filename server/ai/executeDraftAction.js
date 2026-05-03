/**
 * Execute a draft action server-side.
 *
 * Used by /api/ai/execute (chat confirm flow), /api/drafts/:id/confirm, and
 * /api/ai/capture (App Intent / Shortcut path that auto-executes everything).
 *
 * Throws DraftExecutionError on validation problems (missing entity, bad
 * input). Callers translate those into HTTP responses or AppIntent dialog
 * text. Throwing keeps the helper free of res/req coupling.
 *
 * Returns: {
 *   result,            // raw row returned by the SQL RETURNING clause
 *   resultEntityId,    // server's integer id (used by draftStore.confirmDraft)
 *   summary: { type, title, id, action, dueDate? }
 * }
 *
 * `summary` is shaped for human-friendly dialog rendering — the App Intent
 * builds its spoken response from it ("Added 'milk' to Groceries", etc.).
 */

class DraftExecutionError extends Error {
    constructor(message, { status = 400 } = {}) {
        super(message);
        this.name = 'DraftExecutionError';
        this.status = status;
    }
}

async function executeDraftAction(draft, draftData, deps) {
    const { db, logTodoHistory, logNoteHistory, logListHistory } = deps;

    let result;
    let resultEntityId;
    let summary;

    switch (draft.action_type) {
        // ========== CREATE OPERATIONS ==========
        case 'CREATE_TODO': {
            const { rows } = await db.query(
                'INSERT INTO todos (title, description, due_date, tag) VALUES ($1, $2, $3, $4) RETURNING *',
                [draftData.title, draftData.description || null, draftData.due_date || null, draftData.tag || null]
            );
            result = rows[0];
            resultEntityId = result.id;
            await logTodoHistory(result.id, 'created', null, null, JSON.stringify(draftData));
            summary = { type: 'todo', action: 'created', id: result.id, title: draftData.title, dueDate: result.due_date || null };
            break;
        }

        case 'CREATE_NOTE': {
            const { rows } = await db.query(
                'INSERT INTO notes (title, content, folder_id) VALUES ($1, $2, $3) RETURNING *',
                [draftData.title, draftData.content, draftData.folder_id || null]
            );
            result = rows[0];
            resultEntityId = result.id;
            await logNoteHistory(result.id, 'created', null, null, JSON.stringify(draftData));
            summary = { type: 'note', action: 'created', id: result.id, title: draftData.title || '' };
            break;
        }

        case 'CREATE_LIST': {
            const items = Array.isArray(draftData.items)
                ? draftData.items.map(item => typeof item === 'string' ? { text: item, checked: false } : item)
                : [];
            const { rows } = await db.query(
                'INSERT INTO lists (title, items) VALUES ($1, $2) RETURNING *',
                [draftData.title, JSON.stringify(items)]
            );
            result = rows[0];
            resultEntityId = result.id;
            await logListHistory(result.id, 'created', null, null, JSON.stringify(draftData));
            summary = { type: 'list', action: 'created', id: result.id, title: draftData.title };
            break;
        }

        // ========== UPDATE OPERATIONS ==========
        case 'COMPLETE_TODO': {
            const { rows } = await db.query(
                'UPDATE todos SET completed = $1, updated_at = CURRENT_TIMESTAMP WHERE id = $2 RETURNING *',
                [draftData.completed, draftData.id]
            );
            if (rows.length === 0) throw new DraftExecutionError('Task not found', { status: 404 });
            result = rows[0];
            resultEntityId = result.id;
            await logTodoHistory(result.id, draftData.completed ? 'completed' : 'uncompleted', 'completed', !draftData.completed, draftData.completed);
            summary = { type: 'todo', action: draftData.completed ? 'completed' : 'reopened', id: result.id, title: result.title };
            break;
        }

        case 'UPDATE_TODO': {
            const updates = [];
            const values = [];
            let p = 1;
            if (draftData.title !== undefined) { updates.push(`title = $${p++}`); values.push(draftData.title); }
            if (draftData.description !== undefined) { updates.push(`description = $${p++}`); values.push(draftData.description); }
            if (draftData.due_date !== undefined) { updates.push(`due_date = $${p++}`); values.push(draftData.due_date); }
            if (draftData.tag !== undefined) { updates.push(`tag = $${p++}`); values.push(draftData.tag); }
            if (updates.length === 0) throw new DraftExecutionError('No fields to update');
            values.push(draftData.id);
            const { rows } = await db.query(
                `UPDATE todos SET ${updates.join(', ')}, updated_at = CURRENT_TIMESTAMP WHERE id = $${p} AND deleted_at IS NULL RETURNING *`,
                values
            );
            if (rows.length === 0) throw new DraftExecutionError('Task not found', { status: 404 });
            result = rows[0];
            resultEntityId = result.id;
            await logTodoHistory(result.id, 'updated', null, null, JSON.stringify(draftData));
            summary = { type: 'todo', action: 'updated', id: result.id, title: result.title };
            break;
        }

        case 'UPDATE_NOTE': {
            const updates = [];
            const values = [];
            let p = 1;
            if (draftData.title !== undefined) { updates.push(`title = $${p++}`); values.push(draftData.title); }
            if (draftData.content !== undefined) { updates.push(`content = $${p++}`); values.push(draftData.content); }
            if (draftData.folder_id !== undefined) { updates.push(`folder_id = $${p++}`); values.push(draftData.folder_id); }
            if (updates.length === 0) throw new DraftExecutionError('No fields to update');
            values.push(draftData.id);
            const { rows } = await db.query(
                `UPDATE notes SET ${updates.join(', ')}, updated_at = CURRENT_TIMESTAMP WHERE id = $${p} RETURNING *`,
                values
            );
            if (rows.length === 0) throw new DraftExecutionError('Note not found', { status: 404 });
            result = rows[0];
            resultEntityId = result.id;
            await logNoteHistory(result.id, 'updated', null, null, JSON.stringify(draftData));
            summary = { type: 'note', action: 'updated', id: result.id, title: result.title || '' };
            break;
        }

        case 'UPDATE_LIST': {
            const updates = [];
            const values = [];
            let p = 1;
            if (draftData.title !== undefined) { updates.push(`title = $${p++}`); values.push(draftData.title); }
            if (draftData.items !== undefined) { updates.push(`items = $${p++}`); values.push(JSON.stringify(draftData.items)); }
            if (updates.length === 0) throw new DraftExecutionError('No fields to update');
            values.push(draftData.id);
            const { rows } = await db.query(
                `UPDATE lists SET ${updates.join(', ')} WHERE id = $${p} RETURNING *`,
                values
            );
            if (rows.length === 0) throw new DraftExecutionError('List not found', { status: 404 });
            result = rows[0];
            resultEntityId = result.id;
            await logListHistory(result.id, 'updated', null, null, JSON.stringify(draftData));
            summary = { type: 'list', action: 'updated', id: result.id, title: result.title };
            break;
        }

        case 'ADD_TO_LIST': {
            const { rows: existing } = await db.query('SELECT * FROM lists WHERE id = $1 AND deleted_at IS NULL', [draftData.id]);
            if (existing.length === 0) throw new DraftExecutionError('List not found', { status: 404 });
            const currentItems = typeof existing[0].items === 'string' ? JSON.parse(existing[0].items) : (existing[0].items || []);
            const newItemsRaw = Array.isArray(draftData.new_items) ? draftData.new_items : [];
            const normalised = newItemsRaw.map(item => typeof item === 'string' ? { text: item, checked: false } : item);
            const merged = [...currentItems, ...normalised];
            const { rows } = await db.query('UPDATE lists SET items = $1 WHERE id = $2 RETURNING *', [JSON.stringify(merged), draftData.id]);
            result = rows[0];
            resultEntityId = result.id;
            await logListHistory(result.id, 'updated', null, null, JSON.stringify({ added_items: normalised }));
            const addedNames = normalised.map(i => i.text).filter(Boolean).join(', ');
            summary = { type: 'list', action: 'items_added', id: result.id, title: result.title, addedNames };
            break;
        }

        case 'UPDATE_LIST_ITEM': {
            const { rows: listRows } = await db.query('SELECT * FROM lists WHERE id = $1 AND deleted_at IS NULL', [draftData.list_id]);
            if (listRows.length === 0) throw new DraftExecutionError('List not found', { status: 404 });
            const items = typeof listRows[0].items === 'string' ? JSON.parse(listRows[0].items) : (listRows[0].items || []);
            if (draftData.item_index >= items.length) throw new DraftExecutionError('Item index out of range');
            const oldItem = { ...items[draftData.item_index] };
            if (draftData.text !== undefined && draftData.text.trim()) {
                items[draftData.item_index].text = draftData.text;
            }
            if (draftData.checked !== undefined) {
                items[draftData.item_index].completed = draftData.checked;
                items[draftData.item_index].completedAt = draftData.checked ? new Date().toISOString() : null;
            }
            const { rows } = await db.query('UPDATE lists SET items = $1 WHERE id = $2 RETURNING *', [JSON.stringify(items), draftData.list_id]);
            result = rows[0];
            resultEntityId = result.id;
            await logListHistory(result.id, 'updated', 'item', JSON.stringify(oldItem), JSON.stringify(items[draftData.item_index]));
            summary = { type: 'list', action: 'item_updated', id: result.id, title: result.title };
            break;
        }

        case 'REMOVE_LIST_ITEM': {
            const { rows: listRows } = await db.query('SELECT * FROM lists WHERE id = $1 AND deleted_at IS NULL', [draftData.list_id]);
            if (listRows.length === 0) throw new DraftExecutionError('List not found', { status: 404 });
            const items = typeof listRows[0].items === 'string' ? JSON.parse(listRows[0].items) : (listRows[0].items || []);
            if (draftData.item_index >= items.length) throw new DraftExecutionError('Item index out of range');
            const removed = items.splice(draftData.item_index, 1)[0];
            const { rows } = await db.query('UPDATE lists SET items = $1 WHERE id = $2 RETURNING *', [JSON.stringify(items), draftData.list_id]);
            result = rows[0];
            resultEntityId = result.id;
            await logListHistory(result.id, 'item_removed', 'item', JSON.stringify(removed), null);
            summary = { type: 'list', action: 'item_removed', id: result.id, title: result.title };
            break;
        }

        case 'UPDATE_FOLDER': {
            const { rows } = await db.query(
                'UPDATE note_folders SET name = $1 WHERE id = $2 RETURNING *',
                [draftData.name, draftData.id]
            );
            if (rows.length === 0) throw new DraftExecutionError('Folder not found', { status: 404 });
            result = rows[0];
            resultEntityId = result.id;
            summary = { type: 'folder', action: 'updated', id: result.id, title: result.name };
            break;
        }

        // ========== DELETE OPERATIONS ==========
        case 'DELETE_TODO': {
            const { rows } = await db.query(
                'UPDATE todos SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1 AND deleted_at IS NULL RETURNING *',
                [draftData.id]
            );
            if (rows.length === 0) throw new DraftExecutionError('Task not found or already deleted', { status: 404 });
            result = rows[0];
            resultEntityId = result.id;
            await logTodoHistory(result.id, 'deleted', null, null, null);
            summary = { type: 'todo', action: 'deleted', id: result.id, title: result.title };
            break;
        }

        case 'DELETE_NOTE': {
            // Soft-delete so the iOS sync engine receives a tombstone.
            const { rows } = await db.query(
                'UPDATE notes SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1 AND deleted_at IS NULL RETURNING *',
                [draftData.id]
            );
            if (rows.length === 0) throw new DraftExecutionError('Note not found', { status: 404 });
            result = rows[0];
            resultEntityId = result.id;
            await logNoteHistory(result.id, 'deleted', null, null, null);
            summary = { type: 'note', action: 'deleted', id: result.id, title: result.title || '' };
            break;
        }

        case 'DELETE_LIST': {
            const { rows } = await db.query(
                'UPDATE lists SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1 AND deleted_at IS NULL RETURNING *',
                [draftData.id]
            );
            if (rows.length === 0) throw new DraftExecutionError('List not found', { status: 404 });
            result = rows[0];
            resultEntityId = result.id;
            await logListHistory(result.id, 'deleted', null, null, null);
            summary = { type: 'list', action: 'deleted', id: result.id, title: result.title };
            break;
        }

        case 'DELETE_FOLDER': {
            // Soft-cascade so notes inside also tombstone for sync.
            await db.query(
                'UPDATE notes SET deleted_at = CURRENT_TIMESTAMP WHERE folder_id = $1 AND deleted_at IS NULL',
                [draftData.id]
            );
            const { rows } = await db.query(
                'UPDATE note_folders SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1 AND deleted_at IS NULL RETURNING *',
                [draftData.id]
            );
            if (rows.length === 0) throw new DraftExecutionError('Folder not found', { status: 404 });
            result = rows[0];
            resultEntityId = result.id;
            summary = { type: 'folder', action: 'deleted', id: result.id, title: result.name };
            break;
        }

        default:
            throw new DraftExecutionError(`Unsupported action type: ${draft.action_type}`);
    }

    return { result, resultEntityId, summary };
}

module.exports = { executeDraftAction, DraftExecutionError };
