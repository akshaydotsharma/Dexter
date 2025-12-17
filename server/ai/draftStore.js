/**
 * Draft Store Module
 * Handles database operations for draft actions
 */

const db = require('../db');

/**
 * Create a new draft action in the database
 * @param {Object} params Draft parameters
 * @param {string} params.actionType - The action type (e.g., 'CREATE_TODO')
 * @param {string} params.entityType - The entity type (e.g., 'todo')
 * @param {number|null} params.entityId - Entity ID for updates/deletes, null for creates
 * @param {Object} params.draftData - The draft data payload
 * @param {string} params.originalInput - The user's original input text
 * @param {string} params.model - The model used for generation
 * @returns {Promise<Object>} The created draft record
 */
async function createDraft({ actionType, entityType, entityId, draftData, originalInput, model }) {
    const { rows } = await db.query(
        `INSERT INTO draft_actions (action_type, entity_type, entity_id, draft_data, original_input, model, status)
         VALUES ($1, $2, $3, $4, $5, $6, 'pending') RETURNING *`,
        [actionType, entityType, entityId || null, JSON.stringify(draftData), originalInput, model || null]
    );
    return rows[0];
}

/**
 * Get a draft by ID
 * @param {number} id Draft ID
 * @returns {Promise<Object|null>} The draft record or null
 */
async function getDraftById(id) {
    const { rows } = await db.query(
        `SELECT id, action_type, entity_type, entity_id, draft_data, original_input, status, created_at, resolved_at, result_entity_id
         FROM draft_actions WHERE id = $1`,
        [id]
    );
    return rows[0] || null;
}

/**
 * Get pending draft by ID
 * @param {number} id Draft ID
 * @returns {Promise<Object|null>} The draft record or null if not found or not pending
 */
async function getPendingDraft(id) {
    const { rows } = await db.query(
        'SELECT * FROM draft_actions WHERE id = $1 AND status = $2',
        [id, 'pending']
    );
    return rows[0] || null;
}

/**
 * Get all drafts by status
 * @param {string} status Draft status ('pending', 'confirmed', 'rejected', 'expired')
 * @returns {Promise<Array>} Array of draft records
 */
async function getDraftsByStatus(status = 'pending') {
    const { rows } = await db.query(
        `SELECT id, action_type, entity_type, entity_id, draft_data, original_input, status, created_at, resolved_at, result_entity_id
         FROM draft_actions
         WHERE status = $1
         ORDER BY created_at DESC`,
        [status]
    );
    return rows;
}

/**
 * Update draft status to confirmed
 * @param {number} id Draft ID
 * @param {number} resultEntityId The ID of the created/updated entity
 * @returns {Promise<Object>} Updated draft record
 */
async function confirmDraft(id, resultEntityId) {
    const { rows } = await db.query(
        'UPDATE draft_actions SET status = $1, resolved_at = CURRENT_TIMESTAMP, result_entity_id = $2 WHERE id = $3 RETURNING *',
        ['confirmed', resultEntityId, id]
    );
    return rows[0];
}

/**
 * Update draft status to rejected
 * @param {number} id Draft ID
 * @returns {Promise<Object|null>} Updated draft record or null if not found
 */
async function rejectDraft(id) {
    const { rows } = await db.query(
        `UPDATE draft_actions SET status = 'rejected', resolved_at = CURRENT_TIMESTAMP
         WHERE id = $1 AND status = 'pending' RETURNING *`,
        [id]
    );
    return rows[0] || null;
}

/**
 * Update draft data before confirmation
 * @param {number} id Draft ID
 * @param {Object} draftData New draft data
 * @returns {Promise<Object|null>} Updated draft record or null if not found
 */
async function updateDraftData(id, draftData) {
    const { rows } = await db.query(
        `UPDATE draft_actions SET draft_data = $1
         WHERE id = $2 AND status = 'pending' RETURNING *`,
        [JSON.stringify(draftData), id]
    );
    return rows[0] || null;
}

/**
 * Format draft for API response
 * @param {Object} draft Raw draft record from DB
 * @returns {Object} Formatted draft object
 */
function formatDraft(draft) {
    return {
        id: draft.id,
        action_type: draft.action_type,
        entity_type: draft.entity_type,
        entity_id: draft.entity_id,
        data: draft.draft_data,
        original_input: draft.original_input,
        status: draft.status,
        created_at: draft.created_at,
        resolved_at: draft.resolved_at,
        result_entity_id: draft.result_entity_id
    };
}

/**
 * Log an AI message to the ai_messages table
 * @param {Object} params Message parameters
 * @param {string} params.sessionId - Optional session ID for grouping conversations
 * @param {string} params.role - Message role ('user', 'assistant', 'system')
 * @param {string} params.content - Message content
 * @param {Array} params.toolCalls - Optional tool calls made by assistant
 * @param {string} params.model - Model used
 * @param {number} params.tokensUsed - Total tokens used
 * @param {string} params.responseId - OpenAI response ID
 * @returns {Promise<Object>} The created message record
 */
async function logMessage({ sessionId, role, content, toolCalls, model, tokensUsed, responseId }) {
    const { rows } = await db.query(
        `INSERT INTO ai_messages (session_id, role, content, tool_calls, model, tokens_used, response_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *`,
        [
            sessionId || null,
            role,
            content || '',
            toolCalls ? JSON.stringify(toolCalls) : null,
            model || null,
            tokensUsed || null,
            responseId || null
        ]
    );
    return rows[0];
}

/**
 * Get messages by session ID
 * @param {string} sessionId Session ID
 * @param {number} limit Max messages to return
 * @returns {Promise<Array>} Array of message records
 */
async function getMessagesBySession(sessionId, limit = 50) {
    const { rows } = await db.query(
        `SELECT * FROM ai_messages WHERE session_id = $1 ORDER BY created_at ASC LIMIT $2`,
        [sessionId, limit]
    );
    return rows;
}

module.exports = {
    createDraft,
    getDraftById,
    getPendingDraft,
    getDraftsByStatus,
    confirmDraft,
    rejectDraft,
    updateDraftData,
    formatDraft,
    logMessage,
    getMessagesBySession
};
