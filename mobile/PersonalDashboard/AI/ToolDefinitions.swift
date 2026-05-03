import Foundation

/// The 15 draft / edit / delete tools advertised to the LLM. Ported one-for-one
/// from `server/ai/tools.js` with one shape change: every entity ID is a
/// UUID string instead of a server-assigned integer, so the on-device
/// SwiftData primary key (`clientUUID`) can be referenced directly.
enum ToolDefinitions {

    // MARK: - Reusable schema fragments

    /// Single list-item shape: `{ text: string, checked: bool }`.
    private static let listItemSchema: AnthropicJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "text": .object([
                "type": .string("string"),
                "description": .string("The text content of the list item")
            ]),
            "checked": .object([
                "type": .string("boolean"),
                "description": .string("Whether the item is checked/completed")
            ])
        ]),
        "required": .array([.string("text"), .string("checked")])
    ])

    private static func object(
        properties: [String: AnthropicJSONValue],
        required: [String]
    ) -> AnthropicJSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) })
        ])
    }

    private static func string(_ description: String) -> AnthropicJSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description)
        ])
    }

    private static func bool(_ description: String) -> AnthropicJSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }

    private static func int(_ description: String) -> AnthropicJSONValue {
        .object([
            "type": .string("integer"),
            "description": .string(description)
        ])
    }

    private static func arrayOf(_ items: AnthropicJSONValue, description: String) -> AnthropicJSONValue {
        .object([
            "type": .string("array"),
            "items": items,
            "description": .string(description)
        ])
    }

    // MARK: - CREATE tools

    private static let draftTask = AnthropicTool(
        name: "draft_task",
        description: "Create a NEW task/todo item. Use this when the user wants to add a new task, reminder, or todo.",
        input_schema: object(
            properties: [
                "title": string("The title or main text of the task"),
                "description": string("Optional additional details or notes about the task"),
                "due_at": string("Due date in ISO 8601 format (e.g., 2024-01-15T14:00:00.000Z). Parse relative dates like \"tomorrow\", \"next week\", etc. Use empty string if no due date."),
                "tag": string("Category tag for the task (e.g., \"Work\", \"Personal\", \"Shopping\", \"Health\"). Use empty string if no tag.")
            ],
            required: ["title", "description", "due_at", "tag"]
        )
    )

    private static let draftNote = AnthropicTool(
        name: "draft_note",
        description: "Create a NEW note. Use this when the user wants to save new information, write something down, or create a new memo. Can be placed in a folder.",
        input_schema: object(
            properties: [
                "title": string("The title of the note"),
                "body": string("The main content/body of the note"),
                "folder_id": string("UUID of the folder to place the note in (use empty string for no folder). Find folder UUID from EXISTING FOLDERS list."),
                "tags": arrayOf(.object(["type": .string("string")]), description: "Optional tags for categorizing the note")
            ],
            required: ["title", "body", "folder_id", "tags"]
        )
    )

    private static let draftList = AnthropicTool(
        name: "draft_list",
        description: "Create a NEW list with items. Use this when the user wants to create a new checklist, shopping list, or any new list of items.",
        input_schema: object(
            properties: [
                "title": string("The title of the list"),
                "items": arrayOf(listItemSchema, description: "Array of list items with text and checked status")
            ],
            required: ["title", "items"]
        )
    )

    // MARK: - EDIT tools

    private static let completeTask = AnthropicTool(
        name: "complete_task",
        description: "Mark an EXISTING task as completed or incomplete. Use when user wants to check off, complete, finish, or uncheck a task. Requires the task UUID.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing task to mark complete/incomplete (from EXISTING TASKS context)"),
                "completed": bool("True to mark as completed, false to mark as incomplete/uncompleted")
            ],
            required: ["id", "completed"]
        )
    )

    private static let editTask = AnthropicTool(
        name: "edit_task",
        description: "Edit an EXISTING task/todo. Use when user wants to modify a task title, description, due date, or tag. Does NOT change completion status - use complete_task for that. Requires the task UUID. IMPORTANT: At least one of title, description, due_at, or tag must have a non-empty value. If user does not specify what to change, ask for clarification instead of calling this tool.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing task to edit (from EXISTING TASKS context)"),
                "title": string("New title for the task. Use empty string ONLY to keep current title unchanged (at least one other field must have a value)."),
                "description": string("New description for the task. Use empty string to keep unchanged, or \"null\" to clear/delete the description."),
                "due_at": string("New due date in ISO 8601 format. Use empty string to keep unchanged, or \"null\" to remove. At least one field must actually change."),
                "tag": string("New tag for the task. Use empty string to keep unchanged, or \"null\" to remove. At least one field must actually change.")
            ],
            required: ["id", "title", "description", "due_at", "tag"]
        )
    )

    private static let editNote = AnthropicTool(
        name: "edit_note",
        description: "Edit an EXISTING note. Use when user wants to modify a note title, content, or move it to a different folder. Requires the note UUID. IMPORTANT: At least one of title, body, or folder_id must have a non-empty value. If user does not specify what to change, ask for clarification instead of calling this tool.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing note to edit (from EXISTING NOTES context)"),
                "title": string("New title for the note. Use empty string ONLY to keep current title unchanged (at least one other field must have a value)."),
                "body": string("New content/body for the note. Use empty string to keep unchanged, or \"null\" to clear/delete the body content."),
                "folder_id": string("UUID of the folder to move the note to. Use empty string to keep unchanged, \"null\" to remove from folder. At least one field must actually change.")
            ],
            required: ["id", "title", "body", "folder_id"]
        )
    )

    private static let editList = AnthropicTool(
        name: "edit_list",
        description: "Edit an EXISTING list. Use when user wants to rename a list or replace all its items. Requires the list UUID. IMPORTANT: At least one of title or items must have a non-empty value. If user does not specify what to change, ask for clarification instead of calling this tool.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing list to edit (from EXISTING LISTS context)"),
                "title": string("New title for the list. Use empty string ONLY to keep current title unchanged (items must have values then)."),
                "items": arrayOf(listItemSchema, description: "Complete new items array (replaces existing items). Use empty array ONLY to keep unchanged (title must have value then).")
            ],
            required: ["id", "title", "items"]
        )
    )

    private static let addToList = AnthropicTool(
        name: "add_to_list",
        description: "Add new items to an EXISTING list without replacing existing items. Use when user wants to add items to a list.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing list to add items to (from EXISTING LISTS context)"),
                "new_items": arrayOf(listItemSchema, description: "Array of new items to add to the list")
            ],
            required: ["id", "new_items"]
        )
    )

    private static let editListItem = AnthropicTool(
        name: "edit_list_item",
        description: "Edit a specific item within an EXISTING list. Use when user wants to change the text or checked status of a specific list item. Requires list UUID and item index. IMPORTANT: You must provide at least one actual change (non-empty text or a checked value). If user does not specify what to change, ask for clarification.",
        input_schema: object(
            properties: [
                "list_id": string("The UUID of the list containing the item (from EXISTING LISTS context)"),
                "item_index": int("The index of the item to edit (0-based, from EXISTING LISTS context)"),
                "text": string("New text for the item. Provide the actual new text value. Use empty string only if changing checked status."),
                "checked": bool("New checked status for the item. Set true/false to change, or match current value if only changing text.")
            ],
            required: ["list_id", "item_index", "text", "checked"]
        )
    )

    private static let removeListItem = AnthropicTool(
        name: "remove_list_item",
        description: "Remove a specific item from an EXISTING list. Use when user wants to delete a specific item from a list. Requires list UUID and item index.",
        input_schema: object(
            properties: [
                "list_id": string("The UUID of the list containing the item (from EXISTING LISTS context)"),
                "item_index": int("The index of the item to remove (0-based, from EXISTING LISTS context)")
            ],
            required: ["list_id", "item_index"]
        )
    )

    private static let editFolder = AnthropicTool(
        name: "edit_folder",
        description: "Edit an EXISTING folder name. Use when user wants to rename a folder.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing folder to edit (from EXISTING FOLDERS context)"),
                "name": string("New name for the folder")
            ],
            required: ["id", "name"]
        )
    )

    // MARK: - DELETE tools

    private static let deleteTask = AnthropicTool(
        name: "delete_task",
        description: "Delete an EXISTING task/todo. Use when user wants to remove a task. Requires the task UUID.",
        input_schema: object(
            properties: ["id": string("The UUID of the task to delete (from EXISTING TASKS context)")],
            required: ["id"]
        )
    )

    private static let deleteNote = AnthropicTool(
        name: "delete_note",
        description: "Delete an EXISTING note. Use when user wants to remove a note. Requires the note UUID.",
        input_schema: object(
            properties: ["id": string("The UUID of the note to delete (from EXISTING NOTES context)")],
            required: ["id"]
        )
    )

    private static let deleteList = AnthropicTool(
        name: "delete_list",
        description: "Delete an EXISTING list. Use when user wants to remove a list. Requires the list UUID.",
        input_schema: object(
            properties: ["id": string("The UUID of the list to delete (from EXISTING LISTS context)")],
            required: ["id"]
        )
    )

    private static let deleteFolder = AnthropicTool(
        name: "delete_folder",
        description: "Delete an EXISTING folder. Use when user wants to remove a folder. Notes in the folder will be moved to no folder. Requires the folder UUID.",
        input_schema: object(
            properties: ["id": string("The UUID of the folder to delete (from EXISTING FOLDERS context)")],
            required: ["id"]
        )
    )

    // MARK: - Public surface

    static let allTools: [AnthropicTool] = [
        draftTask,
        draftNote,
        draftList,
        completeTask,
        editTask,
        editNote,
        editList,
        addToList,
        editListItem,
        removeListItem,
        editFolder,
        deleteTask,
        deleteNote,
        deleteList,
        deleteFolder
    ]

    /// Map tool name → action type. Mirrors `toolToActionType` in
    /// server/ai/tools.js. Reuses `DraftActionType` from Models/Draft.swift
    /// so any future cross-references (chat preview cards, telemetry)
    /// stay aligned.
    static let toolToActionType: [String: DraftActionType] = [
        "draft_task": .createTodo,
        "draft_note": .createNote,
        "draft_list": .createList,
        "complete_task": .completeTodo,
        "edit_task": .updateTodo,
        "edit_note": .updateNote,
        "edit_list": .updateList,
        "edit_list_item": .updateListItem,
        "remove_list_item": .removeListItem,
        "edit_folder": .updateFolder,
        "add_to_list": .addToList,
        "delete_task": .deleteTodo,
        "delete_note": .deleteNote,
        "delete_list": .deleteList,
        "delete_folder": .deleteFolder
    ]
}
