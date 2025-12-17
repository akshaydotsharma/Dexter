/**
 * Tool Handlers Module
 * Handles execution of tool calls from the AI
 * Each handler validates args and inserts a draft into draft_actions
 */

const db = require('../db');

// Validation constants
const MAX_TITLE_LENGTH = 500;
const MAX_DESCRIPTION_LENGTH = 5000;
const MAX_BODY_LENGTH = 50000;
const MAX_ITEMS_COUNT = 100;
const MAX_ITEM_TEXT_LENGTH = 1000;
const MAX_TAG_LENGTH = 100;
const MAX_TAGS_COUNT = 20;
const MAX_NAME_LENGTH = 200;

/**
 * Validate and sanitize a string field
 * @param {string} value - The value to validate
 * @param {number} maxLength - Maximum allowed length
 * @param {string} fieldName - Field name for error messages
 * @returns {string} Sanitized string
 */
function validateString(value, maxLength, fieldName) {
    if (typeof value !== 'string') {
        return '';
    }
    const trimmed = value.trim();
    if (trimmed.length > maxLength) {
        return trimmed.substring(0, maxLength);
    }
    return trimmed;
}

/**
 * Validate ISO 8601 date string
 * @param {string|null} value - The date string to validate
 * @returns {string|null} Valid ISO date or null
 */
function validateIsoDate(value) {
    if (!value || value === 'null') return null;
    try {
        const date = new Date(value);
        if (isNaN(date.getTime())) return null;
        return date.toISOString();
    } catch {
        return null;
    }
}

/**
 * Insert a draft into the draft_actions table
 * @param {Object} params Draft parameters
 * @returns {Promise<number>} The created draft ID
 */
async function insertDraft({ actionType, entityType, entityId, payload, sourceMessage, model }) {
    const { rows } = await db.query(
        `INSERT INTO draft_actions (action_type, entity_type, entity_id, draft_data, original_input, model, status)
         VALUES ($1, $2, $3, $4, $5, $6, 'pending') RETURNING id`,
        [
            actionType,
            entityType,
            entityId || null,
            JSON.stringify(payload),
            sourceMessage,
            model
        ]
    );
    return rows[0].id;
}

// ========== CREATE HANDLERS ==========

/**
 * Handler for draft_task tool - Creates a NEW task/todo item
 */
async function draft_task(args, ctx) {
    const title = validateString(args.title, MAX_TITLE_LENGTH, 'title');
    if (!title) {
        throw new Error('Task title is required');
    }

    const payload = {
        title,
        description: validateString(args.description || '', MAX_DESCRIPTION_LENGTH, 'description'),
        due_date: validateIsoDate(args.due_at),
        tag: args.tag ? validateString(args.tag, MAX_TAG_LENGTH, 'tag') : null
    };

    const draft_id = await insertDraft({
        actionType: 'CREATE_TODO',
        entityType: 'todo',
        entityId: null,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for draft_note tool - Creates a NEW note
 */
async function draft_note(args, ctx) {
    const title = validateString(args.title, MAX_TITLE_LENGTH, 'title');
    if (!title) {
        throw new Error('Note title is required');
    }

    const body = validateString(args.body || '', MAX_BODY_LENGTH, 'body');

    let tags = [];
    if (Array.isArray(args.tags)) {
        tags = args.tags
            .slice(0, MAX_TAGS_COUNT)
            .map(t => validateString(t, MAX_TAG_LENGTH, 'tag'))
            .filter(Boolean);
    }

    const payload = {
        title,
        content: body,
        folder_id: args.folder_id && args.folder_id > 0 ? args.folder_id : null,
        tags
    };

    const draft_id = await insertDraft({
        actionType: 'CREATE_NOTE',
        entityType: 'note',
        entityId: null,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for draft_list tool - Creates a NEW list with items
 */
async function draft_list(args, ctx) {
    const title = validateString(args.title, MAX_TITLE_LENGTH, 'title');
    if (!title) {
        throw new Error('List title is required');
    }

    let items = [];
    if (Array.isArray(args.items)) {
        items = args.items
            .slice(0, MAX_ITEMS_COUNT)
            .map(item => ({
                text: validateString(item.text || '', MAX_ITEM_TEXT_LENGTH, 'item text'),
                checked: Boolean(item.checked)
            }))
            .filter(item => item.text);
    }

    const payload = {
        title,
        items
    };

    const draft_id = await insertDraft({
        actionType: 'CREATE_LIST',
        entityType: 'list',
        entityId: null,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

// ========== EDIT HANDLERS ==========

/**
 * Handler for complete_task tool - Marks a task as completed or incomplete
 */
async function complete_task(args, ctx) {
    if (!args.id || typeof args.id !== 'number') {
        throw new Error('Task ID is required');
    }

    const payload = {
        id: args.id,
        completed: Boolean(args.completed)
    };

    const draft_id = await insertDraft({
        actionType: 'COMPLETE_TODO',
        entityType: 'todo',
        entityId: args.id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for edit_task tool - Edits an EXISTING task
 */
async function edit_task(args, ctx) {
    if (!args.id || typeof args.id !== 'number') {
        throw new Error('Task ID is required');
    }

    // Build payload with only changed fields
    const payload = { id: args.id };

    if (args.title && args.title.trim()) {
        payload.title = validateString(args.title, MAX_TITLE_LENGTH, 'title');
    }
    // Handle description: "null" means clear/delete the description, empty string means keep unchanged
    if (args.description === 'null') {
        payload.description = '';  // Clear the description
    } else if (args.description && args.description.trim()) {
        payload.description = validateString(args.description, MAX_DESCRIPTION_LENGTH, 'description');
    }
    if (args.due_at === 'null') {
        payload.due_date = null;
    } else if (args.due_at && args.due_at.trim()) {
        payload.due_date = validateIsoDate(args.due_at);
    }
    if (args.tag === 'null') {
        payload.tag = null;
    } else if (args.tag && args.tag.trim()) {
        payload.tag = validateString(args.tag, MAX_TAG_LENGTH, 'tag');
    }

    // Validate that at least one field is being changed
    if (Object.keys(payload).length === 1) {
        throw new Error('At least one field (title, description, due_at, or tag) must be provided to update');
    }

    const draft_id = await insertDraft({
        actionType: 'UPDATE_TODO',
        entityType: 'todo',
        entityId: args.id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for edit_note tool - Edits an EXISTING note
 */
async function edit_note(args, ctx) {
    if (!args.id || typeof args.id !== 'number') {
        throw new Error('Note ID is required');
    }

    const payload = { id: args.id };

    if (args.title && args.title.trim()) {
        payload.title = validateString(args.title, MAX_TITLE_LENGTH, 'title');
    }
    // Handle body: "null" means clear/delete the body, empty string means keep unchanged
    if (args.body === 'null') {
        payload.content = '';  // Clear the body
    } else if (args.body && args.body.trim()) {
        payload.content = validateString(args.body, MAX_BODY_LENGTH, 'body');
    }
    if (args.folder_id === -1) {
        payload.folder_id = null;
    } else if (args.folder_id && args.folder_id > 0) {
        payload.folder_id = args.folder_id;
    }

    // Validate that at least one field is being changed
    if (Object.keys(payload).length === 1) {
        throw new Error('At least one field (title, body, or folder_id) must be provided to update');
    }

    const draft_id = await insertDraft({
        actionType: 'UPDATE_NOTE',
        entityType: 'note',
        entityId: args.id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for edit_list tool - Edits an EXISTING list
 */
async function edit_list(args, ctx) {
    if (!args.id || typeof args.id !== 'number') {
        throw new Error('List ID is required');
    }

    const payload = { id: args.id };

    if (args.title && args.title.trim()) {
        payload.title = validateString(args.title, MAX_TITLE_LENGTH, 'title');
    }
    if (Array.isArray(args.items) && args.items.length > 0) {
        payload.items = args.items
            .slice(0, MAX_ITEMS_COUNT)
            .map(item => ({
                text: validateString(item.text || '', MAX_ITEM_TEXT_LENGTH, 'item text'),
                checked: Boolean(item.checked)
            }))
            .filter(item => item.text);
    }

    // Validate that at least one field is being changed
    if (Object.keys(payload).length === 1) {
        throw new Error('At least one field (title or items) must be provided to update');
    }

    const draft_id = await insertDraft({
        actionType: 'UPDATE_LIST',
        entityType: 'list',
        entityId: args.id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for add_to_list tool - Adds items to an EXISTING list
 */
async function add_to_list(args, ctx) {
    if (!args.id || typeof args.id !== 'number') {
        throw new Error('List ID is required');
    }

    if (!Array.isArray(args.new_items) || args.new_items.length === 0) {
        throw new Error('New items are required');
    }

    const new_items = args.new_items
        .slice(0, MAX_ITEMS_COUNT)
        .map(item => ({
            text: validateString(item.text || '', MAX_ITEM_TEXT_LENGTH, 'item text'),
            checked: Boolean(item.checked)
        }))
        .filter(item => item.text);

    const payload = {
        id: args.id,
        new_items
    };

    const draft_id = await insertDraft({
        actionType: 'ADD_TO_LIST',
        entityType: 'list',
        entityId: args.id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for edit_list_item tool - Edits a specific item within a list
 */
async function edit_list_item(args, ctx) {
    if (!args.list_id || typeof args.list_id !== 'number') {
        throw new Error('List ID is required');
    }
    if (typeof args.item_index !== 'number' || args.item_index < 0) {
        throw new Error('Valid item index is required');
    }

    const payload = {
        list_id: args.list_id,
        item_index: args.item_index
    };

    // Track if we have actual changes
    let hasTextChange = false;
    let hasCheckedChange = false;

    // Only include fields that are being changed
    if (args.text && args.text.trim()) {
        payload.text = validateString(args.text, MAX_ITEM_TEXT_LENGTH, 'item text');
        hasTextChange = true;
    }
    if (typeof args.checked === 'boolean') {
        payload.checked = args.checked;
        hasCheckedChange = true;
    }

    // Since checked is always required by the schema, we consider it valid if:
    // 1. Text has a non-empty value, OR
    // 2. Checked is explicitly provided (which it always is due to schema)
    // The real validation happens at execute time when we compare with existing values
    // For now, accept if at least checked is provided (always true) but log if text is empty
    if (!hasTextChange && !hasCheckedChange) {
        throw new Error('At least one field (text or checked) must be provided to update');
    }

    const draft_id = await insertDraft({
        actionType: 'UPDATE_LIST_ITEM',
        entityType: 'list',
        entityId: args.list_id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for remove_list_item tool - Removes a specific item from a list
 */
async function remove_list_item(args, ctx) {
    if (!args.list_id || typeof args.list_id !== 'number') {
        throw new Error('List ID is required');
    }
    if (typeof args.item_index !== 'number' || args.item_index < 0) {
        throw new Error('Valid item index is required');
    }

    const payload = {
        list_id: args.list_id,
        item_index: args.item_index
    };

    const draft_id = await insertDraft({
        actionType: 'REMOVE_LIST_ITEM',
        entityType: 'list',
        entityId: args.list_id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for edit_folder tool - Edits an EXISTING folder name
 */
async function edit_folder(args, ctx) {
    if (!args.id || typeof args.id !== 'number') {
        throw new Error('Folder ID is required');
    }

    const name = validateString(args.name, MAX_NAME_LENGTH, 'name');
    if (!name) {
        throw new Error('Folder name is required');
    }

    const payload = {
        id: args.id,
        name
    };

    const draft_id = await insertDraft({
        actionType: 'UPDATE_FOLDER',
        entityType: 'folder',
        entityId: args.id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

// ========== DELETE HANDLERS ==========

/**
 * Handler for delete_task tool - Deletes an EXISTING task
 */
async function delete_task(args, ctx) {
    if (!args.id || typeof args.id !== 'number') {
        throw new Error('Task ID is required');
    }

    const payload = { id: args.id };

    const draft_id = await insertDraft({
        actionType: 'DELETE_TODO',
        entityType: 'todo',
        entityId: args.id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for delete_note tool - Deletes an EXISTING note
 */
async function delete_note(args, ctx) {
    if (!args.id || typeof args.id !== 'number') {
        throw new Error('Note ID is required');
    }

    const payload = { id: args.id };

    const draft_id = await insertDraft({
        actionType: 'DELETE_NOTE',
        entityType: 'note',
        entityId: args.id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for delete_list tool - Deletes an EXISTING list
 */
async function delete_list(args, ctx) {
    if (!args.id || typeof args.id !== 'number') {
        throw new Error('List ID is required');
    }

    const payload = { id: args.id };

    const draft_id = await insertDraft({
        actionType: 'DELETE_LIST',
        entityType: 'list',
        entityId: args.id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler for delete_folder tool - Deletes an EXISTING folder
 */
async function delete_folder(args, ctx) {
    if (!args.id || typeof args.id !== 'number') {
        throw new Error('Folder ID is required');
    }

    const payload = { id: args.id };

    const draft_id = await insertDraft({
        actionType: 'DELETE_FOLDER',
        entityType: 'folder',
        entityId: args.id,
        payload,
        sourceMessage: ctx.sourceMessage,
        model: ctx.model
    });

    return { draft_id };
}

/**
 * Handler map for dispatching tool calls
 */
const handlers = {
    // Create
    draft_task,
    draft_note,
    draft_list,
    // Edit
    complete_task,
    edit_task,
    edit_note,
    edit_list,
    edit_list_item,
    add_to_list,
    edit_folder,
    // Delete / Remove
    delete_task,
    delete_note,
    delete_list,
    delete_folder,
    remove_list_item
};

module.exports = {
    handlers,
    // Create
    draft_task,
    draft_note,
    draft_list,
    // Edit
    complete_task,
    edit_task,
    edit_note,
    edit_list,
    edit_list_item,
    add_to_list,
    edit_folder,
    // Delete / Remove
    delete_task,
    delete_note,
    delete_list,
    delete_folder,
    remove_list_item
};
