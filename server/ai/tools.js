/**
 * Vercel AI SDK Tool Schemas
 * Defines the draft_* tools for the AI assistant using Zod schemas
 * These tools create draft actions that require user confirmation
 *
 * NOTE: AI SDK v5 uses 'inputSchema' instead of 'parameters'
 */

const { z } = require('zod');
const { tool } = require('ai');

// ========== LIST ITEM SCHEMA (reusable) ==========
const listItemSchema = z.object({
    text: z.string().describe('The text content of the list item'),
    checked: z.boolean().describe('Whether the item is checked/completed')
});

// ========== CREATE TOOLS ==========
const draft_task = tool({
    description: 'Create a NEW task/todo item. Use this when the user wants to add a new task, reminder, or todo.',
    inputSchema: z.object({
        title: z.string().describe('The title or main text of the task'),
        description: z.string().describe('Optional additional details or notes about the task'),
        due_at: z.string().describe('Due date in ISO 8601 format (e.g., 2024-01-15T14:00:00.000Z). Parse relative dates like "tomorrow", "next week", etc. Use empty string if no due date.'),
        tag: z.string().describe('Category tag for the task (e.g., "Work", "Personal", "Shopping", "Health"). Use empty string if no tag.')
    })
});

const draft_note = tool({
    description: 'Create a NEW note. Use this when the user wants to save new information, write something down, or create a new memo. Can be placed in a folder.',
    inputSchema: z.object({
        title: z.string().describe('The title of the note'),
        body: z.string().describe('The main content/body of the note'),
        folder_id: z.number().describe('ID of the folder to place the note in (use 0 or omit for no folder). Find folder ID from EXISTING FOLDERS list.'),
        tags: z.array(z.string()).describe('Optional tags for categorizing the note')
    })
});

const draft_list = tool({
    description: 'Create a NEW list with items. Use this when the user wants to create a new checklist, shopping list, or any new list of items.',
    inputSchema: z.object({
        title: z.string().describe('The title of the list'),
        items: z.array(listItemSchema).describe('Array of list items with text and checked status')
    })
});

// ========== EDIT TOOLS ==========
const complete_task = tool({
    description: 'Mark an EXISTING task as completed or incomplete. Use when user wants to check off, complete, finish, or uncheck a task. Requires the task ID.',
    inputSchema: z.object({
        id: z.number().describe('The ID of the existing task to mark complete/incomplete'),
        completed: z.boolean().describe('True to mark as completed, false to mark as incomplete/uncompleted')
    })
});

const edit_task = tool({
    description: 'Edit an EXISTING task/todo. Use when user wants to modify a task title, description, due date, or tag. Does NOT change completion status - use complete_task for that. Requires the task ID. IMPORTANT: At least one of title, description, due_at, or tag must have a non-empty value. If user does not specify what to change, ask for clarification instead of calling this tool.',
    inputSchema: z.object({
        id: z.number().describe('The ID of the existing task to edit'),
        title: z.string().describe('New title for the task. Use empty string ONLY to keep current title unchanged (at least one other field must have a value).'),
        description: z.string().describe('New description for the task. Use empty string to keep unchanged, or "null" to clear/delete the description.'),
        due_at: z.string().describe('New due date in ISO 8601 format. Use empty string to keep unchanged, or "null" to remove. At least one field must actually change.'),
        tag: z.string().describe('New tag for the task. Use empty string to keep unchanged, or "null" to remove. At least one field must actually change.')
    })
});

const edit_note = tool({
    description: 'Edit an EXISTING note. Use when user wants to modify a note title, content, or move it to a different folder. Requires the note ID. IMPORTANT: At least one of title, body, or folder_id must have a non-empty value. If user does not specify what to change, ask for clarification instead of calling this tool.',
    inputSchema: z.object({
        id: z.number().describe('The ID of the existing note to edit'),
        title: z.string().describe('New title for the note. Use empty string ONLY to keep current title unchanged (at least one other field must have a value).'),
        body: z.string().describe('New content/body for the note. Use empty string to keep unchanged, or "null" to clear/delete the body content.'),
        folder_id: z.number().describe('ID of the folder to move the note to. Use 0 to keep unchanged, -1 to remove from folder. At least one field must actually change.')
    })
});

const edit_list = tool({
    description: 'Edit an EXISTING list. Use when user wants to rename a list or replace all its items. Requires the list ID. IMPORTANT: At least one of title or items must have a non-empty value. If user does not specify what to change, ask for clarification instead of calling this tool.',
    inputSchema: z.object({
        id: z.number().describe('The ID of the existing list to edit'),
        title: z.string().describe('New title for the list. Use empty string ONLY to keep current title unchanged (items must have values then).'),
        items: z.array(listItemSchema).describe('Complete new items array (replaces existing items). Use empty array ONLY to keep unchanged (title must have value then).')
    })
});

const add_to_list = tool({
    description: 'Add new items to an EXISTING list without replacing existing items. Use when user wants to add items to a list.',
    inputSchema: z.object({
        id: z.number().describe('The ID of the existing list to add items to'),
        new_items: z.array(listItemSchema).describe('Array of new items to add to the list')
    })
});

const edit_list_item = tool({
    description: 'Edit a specific item within an EXISTING list. Use when user wants to change the text or checked status of a specific list item. Requires list ID and item index. IMPORTANT: You must provide at least one actual change (non-empty text or a checked value). If user does not specify what to change, ask for clarification.',
    inputSchema: z.object({
        list_id: z.number().describe('The ID of the list containing the item'),
        item_index: z.number().describe('The index of the item to edit (0-based, from EXISTING LISTS context)'),
        text: z.string().describe('New text for the item. Provide the actual new text value. Use empty string only if changing checked status.'),
        checked: z.boolean().describe('New checked status for the item. Set true/false to change, or match current value if only changing text.')
    })
});

const remove_list_item = tool({
    description: 'Remove a specific item from an EXISTING list. Use when user wants to delete a specific item from a list. Requires list ID and item index.',
    inputSchema: z.object({
        list_id: z.number().describe('The ID of the list containing the item'),
        item_index: z.number().describe('The index of the item to remove (0-based, from EXISTING LISTS context)')
    })
});

const edit_folder = tool({
    description: 'Edit an EXISTING folder name. Use when user wants to rename a folder.',
    inputSchema: z.object({
        id: z.number().describe('The ID of the existing folder to edit'),
        name: z.string().describe('New name for the folder')
    })
});

// ========== DELETE TOOLS ==========
const delete_task = tool({
    description: 'Delete an EXISTING task/todo. Use when user wants to remove a task. Requires the task ID.',
    inputSchema: z.object({
        id: z.number().describe('The ID of the task to delete')
    })
});

const delete_note = tool({
    description: 'Delete an EXISTING note. Use when user wants to remove a note. Requires the note ID.',
    inputSchema: z.object({
        id: z.number().describe('The ID of the note to delete')
    })
});

const delete_list = tool({
    description: 'Delete an EXISTING list. Use when user wants to remove a list. Requires the list ID.',
    inputSchema: z.object({
        id: z.number().describe('The ID of the list to delete')
    })
});

const delete_folder = tool({
    description: 'Delete an EXISTING folder. Use when user wants to remove a folder. Notes in the folder will be moved to no folder. Requires the folder ID.',
    inputSchema: z.object({
        id: z.number().describe('The ID of the folder to delete')
    })
});

// ========== TOOLS OBJECT ==========
const tools = {
    draft_task,
    draft_note,
    draft_list,
    complete_task,
    edit_task,
    edit_note,
    edit_list,
    add_to_list,
    edit_list_item,
    remove_list_item,
    edit_folder,
    delete_task,
    delete_note,
    delete_list,
    delete_folder
};

/**
 * Map tool names to draft types for storage
 */
const toolToDraftType = {
    'draft_task': 'task',
    'draft_note': 'note',
    'draft_list': 'list',
    'complete_task': 'task',
    'edit_task': 'task',
    'edit_note': 'note',
    'edit_list': 'list',
    'edit_list_item': 'list_item',
    'remove_list_item': 'list_item',
    'edit_folder': 'folder',
    'add_to_list': 'list',
    'delete_task': 'task',
    'delete_note': 'note',
    'delete_list': 'list',
    'delete_folder': 'folder'
};

/**
 * Map tool names to action types (for backwards compatibility)
 */
const toolToActionType = {
    'draft_task': 'CREATE_TODO',
    'draft_note': 'CREATE_NOTE',
    'draft_list': 'CREATE_LIST',
    'complete_task': 'COMPLETE_TODO',
    'edit_task': 'UPDATE_TODO',
    'edit_note': 'UPDATE_NOTE',
    'edit_list': 'UPDATE_LIST',
    'edit_list_item': 'UPDATE_LIST_ITEM',
    'remove_list_item': 'REMOVE_LIST_ITEM',
    'edit_folder': 'UPDATE_FOLDER',
    'add_to_list': 'ADD_TO_LIST',
    'delete_task': 'DELETE_TODO',
    'delete_note': 'DELETE_NOTE',
    'delete_list': 'DELETE_LIST',
    'delete_folder': 'DELETE_FOLDER'
};

/**
 * Map tool names to entity types
 */
const toolToEntityType = {
    'draft_task': 'todo',
    'draft_note': 'note',
    'draft_list': 'list',
    'complete_task': 'todo',
    'edit_task': 'todo',
    'edit_note': 'note',
    'edit_list': 'list',
    'edit_list_item': 'list',
    'remove_list_item': 'list',
    'edit_folder': 'folder',
    'add_to_list': 'list',
    'delete_task': 'todo',
    'delete_note': 'note',
    'delete_list': 'list',
    'delete_folder': 'folder'
};

module.exports = {
    tools,
    toolToDraftType,
    toolToActionType,
    toolToEntityType
};
