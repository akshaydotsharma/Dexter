/**
 * Chat to Drafts Module
 * Uses OpenAI Responses API with function calling to convert user messages into drafts
 */

const { getClient, CONFIG } = require('./openaiClient');
const { tools } = require('./tools');
const { handlers } = require('./toolHandlers');
const draftStore = require('./draftStore');

/**
 * System instructions for the AI assistant
 * @param {string} tz - Timezone string
 * @param {string} nowIso - Current time in ISO format
 * @param {Object} context - Context data (existing items)
 * @returns {string} Instructions string
 */
function getInstructions(tz, nowIso, context = {}) {
    let contextSection = '';

    // Add existing items context if provided
    if (context.todos?.length > 0) {
        contextSection += '\n\nEXISTING TASKS:\n';
        contextSection += context.todos.map(t =>
            `- ID:${t.id} "${t.title}"${t.due_date ? ` (due: ${new Date(t.due_date).toLocaleDateString()})` : ''}${t.tag ? ` [${t.tag}]` : ''}${t.completed ? ' ✓' : ''}`
        ).join('\n');
    }

    if (context.notes?.length > 0) {
        contextSection += '\n\nEXISTING NOTES:\n';
        contextSection += context.notes.map(n => {
            let noteStr = `- ID:${n.id} "${n.title}"${n.folder_id ? ` (folder ID:${n.folder_id})` : ''}`;
            if (n.content_preview) {
                const preview = n.content_preview.length >= 200
                    ? n.content_preview.substring(0, 197) + '...'
                    : n.content_preview;
                noteStr += `\n  Body preview: "${preview.replace(/\n/g, ' ')}"`;
            }
            return noteStr;
        }).join('\n');
    }

    if (context.lists?.length > 0) {
        contextSection += '\n\nEXISTING LISTS:\n';
        contextSection += context.lists.map(l => {
            let listStr = `- List ID:${l.id} "${l.title}" (${l.items?.length || 0} items)`;
            if (l.items?.length > 0) {
                listStr += '\n  Items:';
                l.items.forEach((item, idx) => {
                    listStr += `\n    [${idx}] "${item.text}"${item.completed ? ' ✓' : ''}`;
                });
            }
            return listStr;
        }).join('\n');
    }

    if (context.folders?.length > 0) {
        contextSection += '\n\nEXISTING FOLDERS:\n';
        contextSection += context.folders.map(f =>
            `- ID:${f.id} "${f.name}"`
        ).join('\n');
    }

    return `You are a personal assistant that helps users manage their tasks, notes, and lists.

Your role is to convert user messages into draft actions using the available tools.

AVAILABLE TOOLS:

CREATE (for new items):
- draft_task: Create a NEW task/todo with title, description, due_at (ISO 8601), and tag
- draft_note: Create a NEW note with title, body, and optional tags array
- draft_list: Create a NEW list with title and items array

EDIT (for existing items - requires ID):
- complete_task: Mark a task as completed or incomplete
- edit_task: Edit an existing task's title, description, due_at, or tag
- edit_note: Edit an existing note's title, body, or move to different folder
- edit_list: Edit an existing list's title or replace all items
- add_to_list: Add new items to an existing list (keeps existing items)
- edit_list_item: Edit a specific item in a list (requires list_id and item_index from context)
- edit_folder: Rename an existing folder

DELETE/REMOVE (for existing items - requires ID):
- delete_task: Delete an existing task
- delete_note: Delete an existing note
- delete_list: Delete an existing list
- delete_folder: Delete an existing folder (notes move to no folder)
- remove_list_item: Remove a specific item from a list (requires list_id and item_index)

IMPORTANT RULES:
1. NEVER perform actions directly - ONLY call tools to create draft proposals
2. For EDITS and DELETES: You MUST have the item ID. If user mentions an item by name, find its ID from the EXISTING items list below.
3. If you cannot find an item the user mentions, ask them to clarify which item they mean.
4. If crucial details are missing, ask ONE clarifying question.
5. Parse relative dates (tomorrow, next week, in 3 days, etc.) to ISO 8601 format.
6. Infer appropriate tags from context when reasonable (Work, Personal, Shopping, Health, etc.)
7. For multi-item requests, you can call multiple tools in a single response.
8. For edit tools: ONLY call them when you have specific changes to make. You must provide at least one non-empty field value. Use empty string only for fields you want to keep unchanged.
9. If the user's request is unclear or doesn't specify what to change, ask for clarification instead of calling an edit tool with empty values.
${contextSection}

Timezone: ${tz}
Current time: ${nowIso}

When you successfully create drafts, respond with a brief confirmation message. The user will see preview cards for the drafts and can confirm or reject them.`;
}

const db = require('../db');

/**
 * Fetch existing items context for the AI
 * @returns {Promise<Object>} { todos, notes, lists, folders }
 */
async function fetchContext() {
    const context = { todos: [], notes: [], lists: [], folders: [] };

    try {
        // Fetch todos (only active, not soft-deleted)
        const todosRes = await db.query('SELECT id, title, description, due_date, tag, completed FROM todos WHERE deleted_at IS NULL ORDER BY created_at DESC LIMIT 50');
        context.todos = todosRes.rows;
    } catch (err) {
        console.error('Error fetching todos:', err.message);
    }

    try {
        // Fetch notes (include content preview for context)
        const notesRes = await db.query('SELECT id, title, folder_id, LEFT(content, 200) as content_preview FROM notes ORDER BY updated_at DESC LIMIT 50');
        context.notes = notesRes.rows;
    } catch (err) {
        console.error('Error fetching notes:', err.message);
    }

    try {
        // Fetch lists
        const listsRes = await db.query('SELECT id, title, items FROM lists ORDER BY created_at DESC LIMIT 50');
        context.lists = listsRes.rows.map(l => ({
            ...l,
            items: typeof l.items === 'string' ? JSON.parse(l.items) : l.items
        }));
    } catch (err) {
        console.error('Error fetching lists:', err.message);
    }

    try {
        // Fetch folders
        const foldersRes = await db.query('SELECT id, name FROM note_folders ORDER BY name ASC LIMIT 20');
        context.folders = foldersRes.rows;
    } catch (err) {
        console.error('Error fetching folders:', err.message);
    }

    return context;
}

/**
 * Process a chat message and return drafts
 * Uses OpenAI Responses API with function calling
 *
 * @param {string} userText - The user's message
 * @param {Object} options - Options
 * @param {string} options.userId - User ID (optional)
 * @param {string} options.nowIso - Current time in ISO format
 * @param {string} options.tz - Timezone string
 * @param {string} options.sessionId - Session ID for conversation tracking
 * @returns {Promise<Object>} { drafts, assistantText, followUpQuestion }
 */
async function chatToDrafts(userText, options = {}) {
    const {
        userId = null,
        nowIso = new Date().toISOString(),
        tz = 'UTC',
        sessionId = null
    } = options;

    const openai = getClient();

    // Fetch existing items for context
    const context = await fetchContext();
    const instructions = getInstructions(tz, nowIso, context);

    // Log user message
    await draftStore.logMessage({
        sessionId,
        role: 'user',
        content: userText,
        model: null,
        tokensUsed: null,
        responseId: null
    });

    // Call OpenAI Responses API with tools
    // Note: gpt-5-nano doesn't support temperature parameter
    const response = await openai.responses.create({
        model: CONFIG.model,
        instructions,
        input: [{ role: 'user', content: userText }],
        tools
    });

    // Debug: Log response summary (not full response to avoid logging sensitive data)
    if (process.env.NODE_ENV !== 'production') {
        console.log('[chatToDrafts] Response received, output items:', response.output?.length || 0);
    }

    // Result object
    const result = {
        drafts: [],
        assistantText: '',
        followUpQuestion: null,
        toolCalls: [],
        errors: []
    };

    // Context for tool handlers
    const ctx = {
        userId,
        sourceMessage: userText,
        model: CONFIG.model
    };

    // Process response output items
    if (response.output && Array.isArray(response.output)) {
        for (const item of response.output) {
            if (item.type === 'function_call') {
                // Parse and execute the tool call
                const functionName = item.name;
                const args = JSON.parse(item.arguments);

                // Check if we have a handler for this tool
                if (handlers[functionName]) {
                    try {
                        const handlerResult = await handlers[functionName](args, ctx);

                        // Get the created draft from DB to return full details
                        const draft = await draftStore.getDraftById(handlerResult.draft_id);
                        if (draft) {
                            result.drafts.push(draftStore.formatDraft(draft));
                        }

                        result.toolCalls.push({
                            id: item.call_id,
                            function: functionName,
                            arguments: args
                        });
                    } catch (err) {
                        console.error(`Error executing ${functionName}:`, err);
                        result.errors.push({
                            tool: functionName,
                            message: err.message || 'Unknown error occurred'
                        });
                    }
                }
            }
        }
    }

    // Get assistant text from response
    if (response.output_text) {
        result.assistantText = response.output_text;
    }

    // Generate summary if we have drafts but no assistant text
    if (result.drafts.length > 0 && !result.assistantText) {
        result.assistantText = generateDraftSummary(result.drafts);
    }

    // If no tool calls and we got text, it's likely a clarification question
    if (result.drafts.length === 0 && result.assistantText) {
        if (result.assistantText.includes('?')) {
            result.followUpQuestion = result.assistantText;
        }
    }

    // If we have errors, generate a user-friendly error message
    if (result.errors.length > 0 && result.drafts.length === 0) {
        const errorMessages = result.errors.map(e => e.message).join('; ');
        result.assistantText = `I couldn't process that request: ${errorMessages}\n\nPlease try again with more specific details about what you'd like to change.`;
    }

    // Calculate tokens used
    const tokensUsed = response.usage
        ? (response.usage.input_tokens || 0) + (response.usage.output_tokens || 0)
        : null;

    // Log assistant response
    await draftStore.logMessage({
        sessionId,
        role: 'assistant',
        content: result.assistantText || '',
        toolCalls: result.toolCalls.length > 0 ? result.toolCalls : null,
        model: CONFIG.model,
        tokensUsed,
        responseId: response.id || null
    });

    return result;
}

/**
 * Generate a summary message for created drafts
 * @param {Array} drafts Array of draft objects
 * @returns {string} Summary text
 */
function generateDraftSummary(drafts) {
    if (drafts.length === 0) return '';

    const summaries = drafts.map(draft => {
        const data = draft.data;
        const actionType = draft.action_type;

        // Handle DELETE actions
        if (actionType.startsWith('DELETE_')) {
            const entityName = actionType.replace('DELETE_', '').toLowerCase();
            return `Delete ${entityName} (ID: ${data.id})`;
        }

        // Handle REMOVE_LIST_ITEM action
        if (actionType === 'REMOVE_LIST_ITEM') {
            return `Remove item [${data.item_index}] from list (ID: ${data.list_id})`;
        }

        // Handle COMPLETE action
        if (actionType === 'COMPLETE_TODO') {
            return `${data.completed ? 'Complete' : 'Uncomplete'} task (ID: ${data.id})`;
        }

        // Handle UPDATE_LIST_ITEM action
        if (actionType === 'UPDATE_LIST_ITEM') {
            let summary = `Edit item [${data.item_index}] in list (ID: ${data.list_id})`;
            if (data.text) summary += `: "${data.text}"`;
            if (data.checked !== undefined) summary += data.checked ? ' (mark done)' : ' (mark undone)';
            return summary;
        }

        // Handle UPDATE actions
        if (actionType.startsWith('UPDATE_') || actionType === 'ADD_TO_LIST') {
            switch (draft.entity_type) {
                case 'todo':
                    let editTodo = `Edit task (ID: ${data.id})`;
                    if (data.title) editTodo += `: "${data.title}"`;
                    return editTodo;
                case 'note':
                    let editNote = `Edit note (ID: ${data.id})`;
                    if (data.title) editNote += `: "${data.title}"`;
                    return editNote;
                case 'list':
                    if (actionType === 'ADD_TO_LIST') {
                        return `Add ${data.new_items?.length || 0} items to list (ID: ${data.id})`;
                    }
                    let editList = `Edit list (ID: ${data.id})`;
                    if (data.title) editList += `: "${data.title}"`;
                    return editList;
                case 'folder':
                    return `Rename folder (ID: ${data.id}) to "${data.name}"`;
                default:
                    return `Edit ${draft.entity_type} (ID: ${data.id})`;
            }
        }

        // Handle CREATE actions
        switch (draft.entity_type) {
            case 'todo':
                let todoSummary = `Task: "${data.title}"`;
                if (data.due_date) {
                    todoSummary += ` (due: ${new Date(data.due_date).toLocaleDateString()})`;
                }
                if (data.tag) {
                    todoSummary += ` [${data.tag}]`;
                }
                return todoSummary;
            case 'note':
                return `Note: "${data.title}"`;
            case 'list':
                return `List: "${data.title}" with ${data.items?.length || 0} items`;
            default:
                return `${draft.action_type}: ${data.title || 'Untitled'}`;
        }
    });

    if (summaries.length === 1) {
        const actionType = drafts[0].action_type;
        const isComplete = actionType === 'COMPLETE_TODO';
        const isEdit = actionType.startsWith('UPDATE_') || actionType === 'ADD_TO_LIST';
        const isDelete = actionType.startsWith('DELETE_');
        const isRemove = actionType === 'REMOVE_LIST_ITEM';
        let action;
        if (isDelete) action = 'delete';
        else if (isRemove) action = 'remove';
        else if (isComplete) action = drafts[0].data.completed ? 'complete' : 'uncomplete';
        else if (isEdit) action = 'update';
        else action = 'create';
        return `I've prepared a draft for you:\n\n${summaries[0]}\n\nPlease review and confirm to ${action} it.`;
    }

    return `I've prepared ${summaries.length} drafts for you:\n\n${summaries.map((s, i) => `${i + 1}. ${s}`).join('\n')}\n\nPlease review and confirm each one.`;
}

module.exports = {
    chatToDrafts,
    generateDraftSummary
};
