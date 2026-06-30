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

    private static let appendToNote = AnthropicTool(
        name: "append_to_note",
        description: "Append new content to the end of an EXISTING note without rewriting or replacing existing content. Use whenever the user wants to add a line / point / bullet / paragraph to an existing note (e.g., 'add a fourth point', 'append a note that …', 'also add', 'add another bullet'). The model NEVER provides the existing body — pass only the new text. The device merges it with sensible spacing.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing note to append to (from EXISTING NOTES context)"),
                "content": string("The new text to append to the note. Provide ONLY the new content — do NOT include any of the existing body. The device handles spacing between the existing body and the appended text.")
            ],
            required: ["id", "content"]
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

    // MARK: - Itineraries (trips + day-by-day items)

    /// Single itinerary-item shape for the `add_itinerary_item` array.
    private static let itineraryItemSchema: AnthropicJSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "day_date": .object([
                "type": .string("string"),
                "description": .string("ISO 8601 date for the day this item belongs to (e.g., 2026-06-14 or 2026-06-14T00:00:00.000Z). Must fall within the trip's date range.")
            ]),
            "kind": .object([
                "type": .string("string"),
                "enum": .array([.string("stay"), .string("activity"), .string("place"), .string("restaurant")]),
                "description": .string("Category of the itinerary item.")
            ]),
            "title": .object([
                "type": .string("string"),
                "description": .string("Short title (e.g., 'Hotel Roma', 'Vatican tour'). Required.")
            ]),
            "notes": .object([
                "type": .string("string"),
                "description": .string("Free-form notes. Use empty string if none.")
            ]),
            "start_time": .object([
                "type": .string("string"),
                "description": .string("OPTIONAL start time for this item as a full ISO 8601 datetime with timezone (e.g., 2026-06-14T19:00:00-04:00 or 2026-06-14T11:00:00Z). The DATE portion MUST match day_date. Set this whenever the user mentions a time (e.g., 'dinner at 8', '11am check-in', 'tour at 14:00'); otherwise omit. Items without a start_time render as 'untimed' on the timeline.")
            ]),
            "end_date": .object([
                "type": .string("string"),
                "description": .string("STAY ONLY: ISO 8601 date for the check-out day (e.g., 2026-06-17). REQUIRED when kind is 'stay' (use day_date + 1 if user didn't specify, since most stays are at least one night). Must be > day_date. Omit for non-stay kinds.")
            ]),
            "end_time": .object([
                "type": .string("string"),
                "description": .string("STAY ONLY, OPTIONAL: check-out time as a full ISO 8601 datetime with timezone (e.g., 2026-06-17T11:00:00-04:00). The DATE portion MUST match end_date. Set this when the user mentions a check-out time; otherwise omit.")
            ]),
            "google_maps_link": .object([
                "type": .string("string"),
                "description": .string("OPTIONAL Google Maps URL for the location (e.g., https://maps.app.goo.gl/abc or https://www.google.com/maps/place/...). Extract it ONLY if the source explicitly contains one; do NOT invent or guess a link. Omit (or use empty string) when there is no link.")
            ])
        ]),
        "required": .array([.string("day_date"), .string("kind"), .string("title"), .string("notes")])
    ])

    private static let draftTrip = AnthropicTool(
        name: "draft_trip",
        description: "Create a NEW trip in the Itineraries section with a destination name and a date range. IMPORTANT: If the user does not specify start_date AND end_date, do NOT call this tool. Ask the user for the dates first.",
        input_schema: object(
            properties: [
                "name": string("Destination or trip title (e.g., 'Italy', 'Vietnam')."),
                "start_date": string("First day of the trip in ISO 8601 (e.g., 2026-06-14 or 2026-06-14T00:00:00.000Z). Required."),
                "end_date": string("Last day of the trip (inclusive) in ISO 8601. Required."),
                "notes": string("Free-form notes about the trip. Use empty string if none.")
            ],
            required: ["name", "start_date", "end_date", "notes"]
        )
    )

    private static let addItineraryItem = AnthropicTool(
        name: "add_itinerary_item",
        description: "Add one or more day-by-day items (stays, activities, places, restaurants) to an EXISTING trip. The LLM should pick trip_id from the EXISTING TRIPS context block; reject ambiguity by asking which trip the user means rather than guessing. Use this for multi-item adds in a single call.",
        input_schema: object(
            properties: [
                "trip_id": string("The UUID of the existing trip to add items to (from EXISTING TRIPS context)."),
                "items": arrayOf(itineraryItemSchema, description: "Array of itinerary items to append to the trip.")
            ],
            required: ["trip_id", "items"]
        )
    )

    private static let editTrip = AnthropicTool(
        name: "edit_trip",
        description: "Edit an EXISTING trip's name, date range, or notes. Requires the trip UUID. IMPORTANT: At least one field must actually change. Use empty string for fields you want to keep unchanged. Use the literal string \"null\" ONLY for notes to clear it. Name and dates cannot be cleared.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing trip to edit (from EXISTING TRIPS context)."),
                "name": string("New trip name. Use empty string to keep unchanged."),
                "start_date": string("New start date in ISO 8601. Use empty string to keep unchanged."),
                "end_date": string("New end date in ISO 8601. Use empty string to keep unchanged."),
                "notes": string("New notes. Use empty string to keep unchanged, or the literal \"null\" to clear.")
            ],
            required: ["id", "name", "start_date", "end_date", "notes"]
        )
    )

    private static let deleteTrip = AnthropicTool(
        name: "delete_trip",
        description: "Delete an EXISTING trip and ALL its itinerary items (cascade). Use when the user wants to remove a trip entirely. Requires the trip UUID.",
        input_schema: object(
            properties: ["id": string("The UUID of the trip to delete (from EXISTING TRIPS context).")],
            required: ["id"]
        )
    )

    private static let editItineraryItem = AnthropicTool(
        name: "edit_itinerary_item",
        description: "Edit an EXISTING itinerary item's day, kind, title, notes, start time, (for stays) check-out date / time, or Google Maps link. Requires the item UUID. IMPORTANT: At least one field must actually change. Use empty string for fields to keep unchanged. Use the literal string \"null\" for notes, start_time, end_date, end_time, or google_maps_link to CLEAR them. day_date, kind, and title cannot be cleared.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing itinerary item to edit (from EXISTING TRIPS context)."),
                "day_date": string("New day for this item in ISO 8601. Use empty string to keep unchanged."),
                "kind": string("New kind. Must be one of: stay, activity, place, restaurant. Use empty string to keep unchanged."),
                "title": string("New title. Use empty string to keep unchanged."),
                "notes": string("New notes. Use empty string to keep unchanged, or the literal \"null\" to clear."),
                "start_time": string("New start time as a full ISO 8601 datetime with timezone (e.g., 2026-06-14T19:00:00-04:00). The date portion should match day_date. Use empty string to keep unchanged, or the literal \"null\" to clear (make the item untimed)."),
                "end_date": string("STAY ONLY: new check-out date in ISO 8601 (e.g., 2026-06-17). Must be > day_date. Use empty string to keep unchanged, or the literal \"null\" to clear."),
                "end_time": string("STAY ONLY: new check-out time as a full ISO 8601 datetime with timezone (e.g., 2026-06-17T11:00:00-04:00). The date portion should match end_date. Use empty string to keep unchanged, or the literal \"null\" to clear."),
                "google_maps_link": string("New Google Maps URL for the location. Use empty string to keep unchanged, or the literal \"null\" to clear.")
            ],
            required: ["id", "day_date", "kind", "title", "notes"]
        )
    )

    private static let deleteItineraryItem = AnthropicTool(
        name: "delete_itinerary_item",
        description: "Delete an EXISTING itinerary item. Use when user wants to remove a single stay/activity/place/restaurant from a trip. Requires the item UUID.",
        input_schema: object(
            properties: ["id": string("The UUID of the itinerary item to delete (from EXISTING TRIPS context).")],
            required: ["id"]
        )
    )

    // MARK: - Expenses (Finance v1)

    /// Log a new expense. SGD is the home currency; the conversion happens
    /// on-device after the tool call lands, so the LLM never needs to know
    /// FX rates. Category is one of the 12 canonical raw values — the model
    /// picks based on merchant + description.
    private static let addExpense = AnthropicTool(
        name: "add_expense",
        description: "Log a NEW expense. Use this when the user says they spent money (e.g., \"I spent $20 on lunch at Starbucks\", \"add a 67 SGD grocery run yesterday\"). Pick the best-fitting category from the enum. If currency isn't specified, default to SGD. Date defaults to today if the user doesn't say.",
        input_schema: object(
            properties: [
                "id": string("UUID string for the new expense. Generate a fresh one for every call (any valid lowercase UUID, e.g., 9b3a8e1c-2f6f-4a3b-9d2c-7e0a1b4c5d6e)."),
                "date": string("ISO 8601 date the spend happened (e.g., 2026-05-22 or 2026-05-22T18:30:00Z). Use today's date if the user did not specify a date."),
                "category": string("One of: food_and_dining, groceries, transport, shopping, entertainment, bills_and_utilities, health_and_wellness, travel, subscriptions, personal_care, gifts_and_donations, other. Pick the best fit based on merchant and description."),
                "merchant": string("Merchant or vendor name (e.g., \"Starbucks\", \"FairPrice\"). Use empty string if unknown."),
                "description": string("Short description of the expense (e.g., \"lunch with Sarah\", \"weekly groceries\"). Use empty string if none."),
                "original_amount": .object([
                    "type": .string("number"),
                    "description": .string("Amount paid in the original currency. Must be greater than zero.")
                ]),
                "original_currency": string("ISO 4217 currency code (e.g., \"SGD\", \"USD\", \"EUR\"). Default to \"SGD\" if the user did not specify a currency."),
                "payment_method": string("Optional payment method (e.g., \"Cash\", \"Visa **1234\"). Use empty string if unknown.")
            ],
            required: ["id", "date", "category", "merchant", "description", "original_amount", "original_currency", "payment_method"]
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
        appendToNote,
        editListItem,
        removeListItem,
        editFolder,
        deleteTask,
        deleteNote,
        deleteList,
        deleteFolder,
        draftTrip,
        addItineraryItem,
        editTrip,
        deleteTrip,
        editItineraryItem,
        deleteItineraryItem,
        addExpense
    ]

    /// Subset of `allTools` excluded from the capture (Shortcut) auto-execute
    /// path. Capture auto-confirms everything the LLM emits; trip-related
    /// tools require date confirmation and contextual review that only the
    /// chat surface offers. Filter applied in `ChatToDrafts.run()`.
    static let captureExcludedToolNames: Set<String> = [
        "draft_trip",
        "add_itinerary_item",
        "edit_trip",
        "delete_trip",
        "edit_itinerary_item",
        "delete_itinerary_item"
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
        "append_to_note": .appendToNote,
        "delete_task": .deleteTodo,
        "delete_note": .deleteNote,
        "delete_list": .deleteList,
        "delete_folder": .deleteFolder,
        "draft_trip": .createTrip,
        "add_itinerary_item": .addItineraryItems,
        "edit_trip": .updateTrip,
        "delete_trip": .deleteTrip,
        "edit_itinerary_item": .updateItineraryItem,
        "delete_itinerary_item": .deleteItineraryItem,
        "add_expense": .addExpense
    ]
}
