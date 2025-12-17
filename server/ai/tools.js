/**
 * OpenAI Responses API Tool Schemas
 * Defines the draft_* tools for the AI assistant
 * These tools create draft actions that require user confirmation
 *
 * Note: Responses API uses a different format than Chat Completions API
 * - name, description, parameters are at the top level (not nested under 'function')
 */

const tools = [
    // ========== CREATE TOOLS ==========
    {
        type: 'function',
        name: 'draft_task',
        description: 'Create a NEW task/todo item. Use this when the user wants to add a new task, reminder, or todo.',
        parameters: {
            type: 'object',
            properties: {
                title: {
                    type: 'string',
                    description: 'The title or main text of the task'
                },
                description: {
                    type: 'string',
                    description: 'Optional additional details or notes about the task'
                },
                due_at: {
                    type: 'string',
                    description: 'Due date in ISO 8601 format (e.g., 2024-01-15T14:00:00.000Z). Parse relative dates like "tomorrow", "next week", etc. Use empty string if no due date.'
                },
                tag: {
                    type: 'string',
                    description: 'Category tag for the task (e.g., "Work", "Personal", "Shopping", "Health"). Use empty string if no tag.'
                }
            },
            required: ['title', 'description', 'due_at', 'tag'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'draft_note',
        description: 'Create a NEW note. Use this when the user wants to save new information, write something down, or create a new memo. Can be placed in a folder.',
        parameters: {
            type: 'object',
            properties: {
                title: {
                    type: 'string',
                    description: 'The title of the note'
                },
                body: {
                    type: 'string',
                    description: 'The main content/body of the note'
                },
                folder_id: {
                    type: 'number',
                    description: 'ID of the folder to place the note in (use 0 or omit for no folder). Find folder ID from EXISTING FOLDERS list.'
                },
                tags: {
                    type: 'array',
                    items: {
                        type: 'string'
                    },
                    description: 'Optional tags for categorizing the note'
                }
            },
            required: ['title', 'body', 'folder_id', 'tags'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'draft_list',
        description: 'Create a NEW list with items. Use this when the user wants to create a new checklist, shopping list, or any new list of items.',
        parameters: {
            type: 'object',
            properties: {
                title: {
                    type: 'string',
                    description: 'The title of the list'
                },
                items: {
                    type: 'array',
                    items: {
                        type: 'object',
                        properties: {
                            text: {
                                type: 'string',
                                description: 'The text content of the list item'
                            },
                            checked: {
                                type: 'boolean',
                                description: 'Whether the item is checked/completed'
                            }
                        },
                        required: ['text', 'checked'],
                        additionalProperties: false
                    },
                    description: 'Array of list items with text and checked status'
                }
            },
            required: ['title', 'items'],
            additionalProperties: false
        },
        strict: true
    },

    // ========== EDIT TOOLS ==========
    {
        type: 'function',
        name: 'complete_task',
        description: 'Mark an EXISTING task as completed or incomplete. Use when user wants to check off, complete, finish, or uncheck a task. Requires the task ID.',
        parameters: {
            type: 'object',
            properties: {
                id: {
                    type: 'number',
                    description: 'The ID of the existing task to mark complete/incomplete'
                },
                completed: {
                    type: 'boolean',
                    description: 'True to mark as completed, false to mark as incomplete/uncompleted'
                }
            },
            required: ['id', 'completed'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'edit_task',
        description: 'Edit an EXISTING task/todo. Use when user wants to modify a task title, description, due date, or tag. Does NOT change completion status - use complete_task for that. Requires the task ID. IMPORTANT: At least one of title, description, due_at, or tag must have a non-empty value. If user does not specify what to change, ask for clarification instead of calling this tool.',
        parameters: {
            type: 'object',
            properties: {
                id: {
                    type: 'number',
                    description: 'The ID of the existing task to edit'
                },
                title: {
                    type: 'string',
                    description: 'New title for the task. Use empty string ONLY to keep current title unchanged (at least one other field must have a value).'
                },
                description: {
                    type: 'string',
                    description: 'New description for the task. Use empty string to keep unchanged, or "null" to clear/delete the description.'
                },
                due_at: {
                    type: 'string',
                    description: 'New due date in ISO 8601 format. Use empty string to keep unchanged, or "null" to remove. At least one field must actually change.'
                },
                tag: {
                    type: 'string',
                    description: 'New tag for the task. Use empty string to keep unchanged, or "null" to remove. At least one field must actually change.'
                }
            },
            required: ['id', 'title', 'description', 'due_at', 'tag'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'edit_note',
        description: 'Edit an EXISTING note. Use when user wants to modify a note title, content, or move it to a different folder. Requires the note ID. IMPORTANT: At least one of title, body, or folder_id must have a non-empty value. If user does not specify what to change, ask for clarification instead of calling this tool.',
        parameters: {
            type: 'object',
            properties: {
                id: {
                    type: 'number',
                    description: 'The ID of the existing note to edit'
                },
                title: {
                    type: 'string',
                    description: 'New title for the note. Use empty string ONLY to keep current title unchanged (at least one other field must have a value).'
                },
                body: {
                    type: 'string',
                    description: 'New content/body for the note. Use empty string to keep unchanged, or "null" to clear/delete the body content.'
                },
                folder_id: {
                    type: 'number',
                    description: 'ID of the folder to move the note to. Use 0 to keep unchanged, -1 to remove from folder. At least one field must actually change.'
                }
            },
            required: ['id', 'title', 'body', 'folder_id'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'edit_list',
        description: 'Edit an EXISTING list. Use when user wants to rename a list or replace all its items. Requires the list ID. IMPORTANT: At least one of title or items must have a non-empty value. If user does not specify what to change, ask for clarification instead of calling this tool.',
        parameters: {
            type: 'object',
            properties: {
                id: {
                    type: 'number',
                    description: 'The ID of the existing list to edit'
                },
                title: {
                    type: 'string',
                    description: 'New title for the list. Use empty string ONLY to keep current title unchanged (items must have values then).'
                },
                items: {
                    type: 'array',
                    items: {
                        type: 'object',
                        properties: {
                            text: {
                                type: 'string',
                                description: 'The text content of the list item'
                            },
                            checked: {
                                type: 'boolean',
                                description: 'Whether the item is checked/completed'
                            }
                        },
                        required: ['text', 'checked'],
                        additionalProperties: false
                    },
                    description: 'Complete new items array (replaces existing items). Use empty array ONLY to keep unchanged (title must have value then).'
                }
            },
            required: ['id', 'title', 'items'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'add_to_list',
        description: 'Add new items to an EXISTING list without replacing existing items. Use when user wants to add items to a list.',
        parameters: {
            type: 'object',
            properties: {
                id: {
                    type: 'number',
                    description: 'The ID of the existing list to add items to'
                },
                new_items: {
                    type: 'array',
                    items: {
                        type: 'object',
                        properties: {
                            text: {
                                type: 'string',
                                description: 'The text content of the new list item'
                            },
                            checked: {
                                type: 'boolean',
                                description: 'Whether the item is checked/completed (usually false for new items)'
                            }
                        },
                        required: ['text', 'checked'],
                        additionalProperties: false
                    },
                    description: 'Array of new items to add to the list'
                }
            },
            required: ['id', 'new_items'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'edit_list_item',
        description: 'Edit a specific item within an EXISTING list. Use when user wants to change the text or checked status of a specific list item. Requires list ID and item index. IMPORTANT: You must provide at least one actual change (non-empty text or a checked value). If user does not specify what to change, ask for clarification.',
        parameters: {
            type: 'object',
            properties: {
                list_id: {
                    type: 'number',
                    description: 'The ID of the list containing the item'
                },
                item_index: {
                    type: 'number',
                    description: 'The index of the item to edit (0-based, from EXISTING LISTS context)'
                },
                text: {
                    type: 'string',
                    description: 'New text for the item. Provide the actual new text value. Use empty string only if changing checked status.'
                },
                checked: {
                    type: 'boolean',
                    description: 'New checked status for the item. Set true/false to change, or match current value if only changing text.'
                }
            },
            required: ['list_id', 'item_index', 'text', 'checked'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'remove_list_item',
        description: 'Remove a specific item from an EXISTING list. Use when user wants to delete a specific item from a list. Requires list ID and item index.',
        parameters: {
            type: 'object',
            properties: {
                list_id: {
                    type: 'number',
                    description: 'The ID of the list containing the item'
                },
                item_index: {
                    type: 'number',
                    description: 'The index of the item to remove (0-based, from EXISTING LISTS context)'
                }
            },
            required: ['list_id', 'item_index'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'edit_folder',
        description: 'Edit an EXISTING folder name. Use when user wants to rename a folder.',
        parameters: {
            type: 'object',
            properties: {
                id: {
                    type: 'number',
                    description: 'The ID of the existing folder to edit'
                },
                name: {
                    type: 'string',
                    description: 'New name for the folder'
                }
            },
            required: ['id', 'name'],
            additionalProperties: false
        },
        strict: true
    },

    // ========== DELETE TOOLS ==========
    {
        type: 'function',
        name: 'delete_task',
        description: 'Delete an EXISTING task/todo. Use when user wants to remove a task. Requires the task ID.',
        parameters: {
            type: 'object',
            properties: {
                id: {
                    type: 'number',
                    description: 'The ID of the task to delete'
                }
            },
            required: ['id'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'delete_note',
        description: 'Delete an EXISTING note. Use when user wants to remove a note. Requires the note ID.',
        parameters: {
            type: 'object',
            properties: {
                id: {
                    type: 'number',
                    description: 'The ID of the note to delete'
                }
            },
            required: ['id'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'delete_list',
        description: 'Delete an EXISTING list. Use when user wants to remove a list. Requires the list ID.',
        parameters: {
            type: 'object',
            properties: {
                id: {
                    type: 'number',
                    description: 'The ID of the list to delete'
                }
            },
            required: ['id'],
            additionalProperties: false
        },
        strict: true
    },
    {
        type: 'function',
        name: 'delete_folder',
        description: 'Delete an EXISTING folder. Use when user wants to remove a folder. Notes in the folder will be moved to no folder. Requires the folder ID.',
        parameters: {
            type: 'object',
            properties: {
                id: {
                    type: 'number',
                    description: 'The ID of the folder to delete'
                }
            },
            required: ['id'],
            additionalProperties: false
        },
        strict: true
    }
];

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
