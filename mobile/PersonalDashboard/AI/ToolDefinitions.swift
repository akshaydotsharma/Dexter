import Foundation

/// The 15 draft / edit / delete tools advertised to the LLM. Ported one-for-one
/// from `server/ai/tools.js` with one shape change: every entity ID is a
/// UUID string instead of a server-assigned integer, so the on-device
/// SwiftData primary key (`clientUUID`) can be referenced directly.
enum ToolDefinitions {

    // MARK: - Reusable schema fragments

    /// Single list-item shape: `{ text: string, checked: bool, url?: string }`.
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
            ]),
            "url": .object([
                "type": .string("string"),
                "description": .string("Optional link (URL) associated with the item. Omit if there is no link.")
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
                "tag": string("Category tag for the task (e.g., \"Work\", \"Personal\", \"Shopping\", \"Health\"). Use empty string if no tag."),
                "priority": string("Task priority. Use \"p0\" (highest/urgent), \"p1\" (medium), or \"p2\" (low). Use empty string when the user does not indicate a priority.")
            ],
            required: ["title", "description", "due_at", "tag", "priority"]
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

    /// Description of the curated icon + color choices, shared by draft_list and
    /// edit_list so the model always picks from the same on-brand set.
    private static let listIconGuidance = "An SF Symbol name giving the list a visual identity. ALWAYS set this — pick the symbol that best fits the list's topic. Good choices: checklist, list.bullet, cart, bag, gift, creditcard, airplane, suitcase, map, car, briefcase, calendar, chart.bar, folder, figure.run, dumbbell, heart, leaf, house, fork.knife, cup.and.saucer, book, graduationcap, lightbulb, gamecontroller, music.note, film, camera, star, flag. Use a valid SF Symbol name; if unsure, use \"checklist\"."
    private static let listColorGuidance = "A color for the list. ALWAYS set this. Use one of these names (or its hex): Teal (0F766E), Indigo (4338CA), Purple (6D28D9), Red (B91C1C), Amber (B45309), Green (047857), Pink (7C3F58), Slate (475569). Pick a color that fits the topic (e.g. travel -> Indigo, groceries/money -> Green, fitness/health -> Red, work -> Slate)."

    private static let draftList = AnthropicTool(
        name: "draft_list",
        description: "Create a NEW list with items. Use this when the user wants to create a new checklist, shopping list, or any new list of items. ALWAYS set an appropriate icon and color so the list has a clear visual identity (e.g. a \"Japan trip\" list gets airplane + Indigo, a grocery list gets cart + Green).",
        input_schema: object(
            properties: [
                "title": string("The title of the list"),
                "items": arrayOf(listItemSchema, description: "Array of list items with text and checked status"),
                "icon": string(listIconGuidance),
                "color": string(listColorGuidance)
            ],
            required: ["title", "items", "icon", "color"]
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
                "tag": string("New tag for the task. Use empty string to keep unchanged, or \"null\" to remove. At least one field must actually change."),
                "priority": string("New priority: \"p0\" (highest), \"p1\" (medium), or \"p2\" (low). Use empty string to keep unchanged, or \"null\" to clear it back to no priority.")
            ],
            required: ["id", "title", "description", "due_at", "tag", "priority"]
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
        description: "Edit an EXISTING list. Use when user wants to rename a list, replace all its items, or change its icon / color. Requires the list UUID. IMPORTANT: At least one of title, items, icon, or color must have a non-empty value. If user does not specify what to change, ask for clarification instead of calling this tool.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing list to edit (from EXISTING LISTS context)"),
                "title": string("New title for the list. Use empty string ONLY to keep current title unchanged (another field must have a value then)."),
                "items": arrayOf(listItemSchema, description: "Complete new items array (replaces existing items). Use empty array to keep unchanged (another field must have a value then)."),
                "icon": string("New SF Symbol icon for the list. Set when the user wants a different icon. Use empty string to keep unchanged. " + listIconGuidance),
                "color": string("New color for the list. Set when the user wants to recolor it. Use empty string to keep unchanged. " + listColorGuidance)
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
                "checked": bool("New checked status for the item. Set true/false to change, or match current value if only changing text."),
                "url": string("New link (URL) for the item. Provide to set or change the item's link; omit to leave it unchanged.")
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
                "enum": .array([.string("stay"), .string("transport"), .string("activity"), .string("place"), .string("restaurant")]),
                "description": .string("Category of the itinerary item. Use 'transport' for any way of getting between places (a flight, train, bus, ferry, or car transfer) and set the 'mode' field. Use 'activity' for tours, attractions, and events.")
            ]),
            "mode": .object([
                "type": .string("string"),
                "enum": .array([.string("flight"), .string("train"), .string("car"), .string("bus"), .string("ferry"), .string("other")]),
                "description": .string("TRANSPORT ONLY: the mode of transport. Set this whenever kind is 'transport' (a flight -> 'flight', a train -> 'train', a car/taxi/private transfer -> 'car', a coach/bus -> 'bus', a ferry/boat -> 'ferry', anything else -> 'other'). Omit for non-transport kinds.")
            ]),
            "title": .object([
                "type": .string("string"),
                "description": .string("Short title (e.g., 'Hotel Roma', 'Flight BA123 LHR->FCO', 'Vatican tour'). Required.")
            ]),
            "notes": .object([
                "type": .string("string"),
                "description": .string("Free-form notes. Use empty string if none.")
            ]),
            "start_time": .object([
                "type": .string("string"),
                "description": .string("OPTIONAL start time for this item as a full ISO 8601 datetime with timezone (e.g., 2026-06-14T19:00:00-04:00 or 2026-06-14T11:00:00Z). The DATE portion MUST match day_date. Set this whenever the user mentions a time (e.g., 'dinner at 8', '11am check-in', 'tour at 14:00'); otherwise omit. Items without a start_time render as 'untimed' on the timeline.")
            ]),
            "arrival_time": .object([
                "type": .string("string"),
                "description": .string("TRANSPORT / ACTIVITY ONLY, OPTIONAL: the arrival / landing / end time (a flight's landing, a train's arrival) as a full ISO 8601 datetime with timezone (e.g., 2026-06-14T22:35:00+01:00). The DATE portion should match day_date. Set this together with start_time (departure) whenever the booking states an arrival time for a flight/train/bus/ferry/transfer; otherwise omit. Not for stays (use end_time), places, or restaurants.")
            ]),
            "end_date": .object([
                "type": .string("string"),
                "description": .string("STAY ONLY: ISO 8601 date for the check-out day (e.g., 2026-06-17). REQUIRED when kind is 'stay' (use day_date + 1 if user didn't specify, since most stays are at least one night). Must be > day_date. Omit for non-stay kinds.")
            ]),
            "end_time": .object([
                "type": .string("string"),
                "description": .string("STAY ONLY, OPTIONAL: check-out time as a full ISO 8601 datetime with timezone (e.g., 2026-06-17T11:00:00-04:00). The DATE portion MUST match end_date. Set this when the user mentions a check-out time; otherwise omit.")
            ]),
            "address": .object([
                "type": .string("string"),
                "description": .string("OPTIONAL postal address / location text for this item as it appears in the booking (e.g. the hotel, Airbnb, restaurant, or activity venue address). Used to locate the place on a map. The device builds the map link from this automatically, so extract the address text accurately. Omit or use empty string if none.")
            ]),
            "google_maps_link": .object([
                "type": .string("string"),
                "description": .string("OPTIONAL Google Maps URL for the location (e.g., https://maps.app.goo.gl/abc or https://www.google.com/maps/place/...). Extract it ONLY if the source explicitly contains one; do NOT invent or guess a link (the device derives one from address instead). Omit (or use empty string) when there is no link.")
            ]),
            "seat": .object([
                "type": .string("string"),
                "description": .string("OPTIONAL seat assignment as printed (e.g. \"12A\", \"Coach 4 / 21\", \"Block A Row 14 Seat 7\"). Set ONLY when a real seat is explicitly present on the booking/ticket; never infer it. Omit or use empty string otherwise.")
            ]),
            "gate": .object([
                "type": .string("string"),
                "description": .string("OPTIONAL boarding gate as printed on a boarding pass (e.g. \"B22\", \"14\"). Set ONLY when a real gate is explicitly printed; never infer, never emit a dash, \"TBD\", or a lone letter. Omit or use empty string otherwise.")
            ]),
            "venue": .object([
                "type": .string("string"),
                "description": .string("OPTIONAL venue / location name for an event or show (e.g. \"The O2, London\", \"Wembley Stadium\"). Set ONLY when the booking names a venue explicitly. Omit or use empty string for flights and anything without a named venue.")
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
        description: "Add one or more day-by-day items (stays, transport, activities, places, restaurants) to an EXISTING trip. The LLM should pick trip_id from the EXISTING TRIPS context block; reject ambiguity by asking which trip the user means rather than guessing. Use this for multi-item adds in a single call.",
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
        description: "Edit an EXISTING itinerary item's day, kind, title, notes, start time, (for stays) check-out date / time, address, or Google Maps link. Requires the item UUID. IMPORTANT: At least one field must actually change. Use empty string for fields to keep unchanged. Use the literal string \"null\" for notes, start_time, end_date, end_time, address, or google_maps_link to CLEAR them. day_date, kind, and title cannot be cleared.",
        input_schema: object(
            properties: [
                "id": string("The UUID of the existing itinerary item to edit (from EXISTING TRIPS context)."),
                "day_date": string("New day for this item in ISO 8601. Use empty string to keep unchanged."),
                "kind": string("New kind. Must be one of: stay, transport, activity, place, restaurant. Use empty string to keep unchanged."),
                "mode": string("TRANSPORT ONLY: new transport mode, one of flight, train, car, bus, ferry, other. Use empty string to keep unchanged. Ignored for non-transport kinds."),
                "title": string("New title. Use empty string to keep unchanged."),
                "notes": string("New notes. Use empty string to keep unchanged, or the literal \"null\" to clear."),
                "start_time": string("New start time as a full ISO 8601 datetime with timezone (e.g., 2026-06-14T19:00:00-04:00). The date portion should match day_date. Use empty string to keep unchanged, or the literal \"null\" to clear (make the item untimed)."),
                "arrival_time": string("TRANSPORT / ACTIVITY ONLY: new arrival / landing / end time (for a flight or train) as a full ISO 8601 datetime with timezone (e.g., 2026-06-14T22:35:00+01:00). The date portion should match day_date. Set together with start_time. Use empty string to keep unchanged, or the literal \"null\" to clear. Ignored for other kinds."),
                "end_date": string("STAY ONLY: new check-out date in ISO 8601 (e.g., 2026-06-17). Must be > day_date. Use empty string to keep unchanged, or the literal \"null\" to clear."),
                "end_time": string("STAY ONLY: new check-out time as a full ISO 8601 datetime with timezone (e.g., 2026-06-17T11:00:00-04:00). The date portion should match end_date. Use empty string to keep unchanged, or the literal \"null\" to clear."),
                "address": string("New postal address / location text for the location (e.g. hotel or restaurant address). The device builds the map link from this automatically. Use empty string to keep unchanged, or the literal \"null\" to clear."),
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
    /// FX rates. Category is one of the 13 canonical raw values — the model
    /// picks based on merchant + description.
    ///
    /// `includeSplitParams` gates the trip-settle-up params (`paid_by`,
    /// `split_with`, #258). They ship on the chat / capture surface but are
    /// deliberately withheld from the email path (`addExpenseEmailSafe`), whose
    /// content is untrusted — the email path defaults trip splits in Swift
    /// instead of letting the model emit split data.
    private static func makeAddExpense(includeSplitParams: Bool) -> AnthropicTool {
        var properties: [String: AnthropicJSONValue] = [
            "id": string("UUID string for the new expense. Generate a fresh one for every call (any valid lowercase UUID, e.g., 9b3a8e1c-2f6f-4a3b-9d2c-7e0a1b4c5d6e)."),
            "date": string("ISO 8601 date the spend happened (e.g., 2026-05-22 or 2026-05-22T18:30:00Z). Use today's date if the user did not specify a date."),
            "category": string("One of: food_and_dining, groceries, transport, shopping, entertainment, bills_and_utilities, rent, health_and_wellness, travel, subscriptions, personal_care, gifts_and_donations, other. Pick the best fit based on merchant and description (rent/lease payments -> rent)."),
            "merchant": string("Merchant or vendor name (e.g., \"Starbucks\", \"FairPrice\"). Use empty string if unknown."),
            "description": string("Short description of the expense (e.g., \"lunch with Sarah\", \"weekly groceries\"). Use empty string if none."),
            "original_amount": .object([
                "type": .string("number"),
                "description": .string("Amount paid in the original currency. Must be greater than zero.")
            ]),
            "original_currency": string("ISO 4217 currency code (e.g., \"SGD\", \"USD\", \"EUR\"). Default to \"SGD\" if the user did not specify a currency."),
            "payment_method": string("Optional payment method (e.g., \"Cash\", \"Visa **1234\"). Use empty string if unknown."),
            "source": string("How this expense was captured. Use \"receipt\" ONLY when logging from a forwarded purchase/receipt email; leave empty otherwise. Allowed values: manual, text, voice, photo, receipt, pdf, recurring."),
            "trip_id": string("UUID of the EXISTING trip this expense belongs to, when (and only when) it is a travel fare for a trip in the EXISTING TRIPS context (e.g., a flight or hotel charge). Use empty string for any non-travel purchase."),
            "person_name": string("Name of the person this expense is for or with (e.g., \"Sarah\"), when the user names one. Reuse the exact name from the PEOPLE context if it already exists. Use empty string if none."),
            "event_name": string("Name of the occasion, group, or trip this expense belongs to (e.g., \"Bali trip\", \"Diwali gifts\"), when the user names one. Reuse the exact name from the EVENTS context if it already exists. Use empty string if none."),
            "number_of_shares": .object([
                "type": .string("integer"),
                "description": .string("How many people the bill was split among, when the user says it was shared (e.g. \"split 3 ways\" => 3). When set, original_amount MUST be the FULL receipt total — the app stores only the user's equal share (total / number_of_shares). Omit or use 1 for a normal unshared expense. Prefer split_with (named people) over this when you know who was involved.")
            ])
        ]

        // Trip settle-up params (#258). Optional; only meaningful for a trip
        // expense (trip_id set) or when the user explicitly names who paid or
        // who a bill is split between. When set, pass the FULL bill in
        // original_amount and leave number_of_shares at 1 — the app records the
        // per-person breakdown from split_with and nets it in settle-up.
        if includeSplitParams {
            properties["paid_by"] = string("OPTIONAL. Who fronted the money: a person's name, or \"me\" for the user. Only set when this is a trip expense (trip_id set) or the user says who paid (e.g. \"Sam paid\"). Reuse the exact name from the trip's participants / the PEOPLE context. Omit or use empty string when the user paid a normal solo expense.")
            properties["split_with"] = arrayOf(
                .object(["type": .string("string")]),
                description: "OPTIONAL. The people the bill is split among, by name; include \"me\" for the user when their share is part of it. Equal split (one share each in v1). Only set when the user is splitting a bill — usually a trip expense (e.g. \"split between all of us\", \"me and Sam\"). Reuse the exact names from the trip's participants / the PEOPLE context. When set, pass the FULL bill in original_amount and leave number_of_shares at 1. Omit for a normal solo expense."
            )
        }

        let description = "Log a NEW expense. Use this when the user says they spent money (e.g., \"I spent $20 on lunch at Starbucks\", \"add a 67 SGD grocery run yesterday\"). Pick the best-fitting category from the enum. If currency isn't specified, default to SGD. Date defaults to today if the user doesn't say. If the user names a person the expense is for/with (\"dinner with Sarah\") set person_name, and if they name an occasion or trip it belongs to (\"for the Bali trip\") set event_name — reuse the EXACT existing names from the PEOPLE / EVENTS context when they refer to one already there, so you don't create near-duplicates. If the user says the bill was split among several people (e.g., \"split 3 ways\", \"between the 4 of us\"), set number_of_shares to that count and pass the FULL receipt total in original_amount — the app records only the user's share."
            + (includeSplitParams
               ? " For a TRIP expense, or whenever the user names who paid or who a bill is shared with, set paid_by and/or split_with with the exact person names (use \"me\" for the user) instead of number_of_shares — these drive the trip settle-up. Only set them when a split/payer is actually implied."
               : "")

        return AnthropicTool(
            name: "add_expense",
            description: description,
            input_schema: object(
                properties: properties,
                required: ["id", "date", "category", "merchant", "description", "original_amount", "original_currency", "payment_method"]
            )
        )
    }

    /// Chat / capture add_expense — carries the trip settle-up params (#258).
    private static let addExpense = makeAddExpense(includeSplitParams: true)

    /// Email-path add_expense — WITHOUT the settle-up params (#258). The email
    /// content is untrusted, so the model is never offered `paid_by` /
    /// `split_with` there; the email path defaults trip splits in Swift.
    static let addExpenseEmailSafe = makeAddExpense(includeSplitParams: false)

    /// Create a recurring monthly expense TEMPLATE (#236). Does NOT log an
    /// expense immediately — it defines a fixed monthly charge that the app
    /// materialises into a real expense on its posting day each month (with
    /// backfill for missed months). If the posting day has already passed this
    /// month when the template is created, the app posts that month right away.
    private static let addRecurringExpense = AnthropicTool(
        name: "add_recurring_expense",
        description: "Create a RECURRING monthly expense template. Use this when the user describes a fixed charge that repeats every month (e.g. \"add my $2,000 rent on the 1st every month\", \"Netflix is 19.98 SGD monthly on the 15th\", \"log my insurance premium of 120 each month\"). This sets up a template — the app automatically posts the expense on the chosen day each month, so do NOT also call add_expense for the same charge. Pick the best-fitting category from the enum. If currency isn't specified, default to SGD. day_of_month is 1-31; a value past the end of a short month posts on that month's last day.",
        input_schema: object(
            properties: [
                "id": string("UUID string for the new recurring template. Generate a fresh one for every call (any valid lowercase UUID, e.g., 9b3a8e1c-2f6f-4a3b-9d2c-7e0a1b4c5d6e)."),
                "amount": .object([
                    "type": .string("number"),
                    "description": .string("The monthly charge amount in the original currency. Must be greater than zero.")
                ]),
                "currency": string("ISO 4217 currency code (e.g. \"SGD\", \"USD\", \"EUR\"). Default to \"SGD\" if the user did not specify a currency."),
                "category": string("One of: food_and_dining, groceries, transport, shopping, entertainment, bills_and_utilities, rent, health_and_wellness, travel, subscriptions, personal_care, gifts_and_donations, other. Pick the best fit (rent/lease -> rent; insurance/utilities -> bills_and_utilities; streaming/software -> subscriptions)."),
                "merchant": string("Merchant or payee name (e.g. \"Landlord\", \"Netflix\"). Use empty string if unknown."),
                "description": string("Short description of the recurring charge (e.g. \"monthly rent\", \"car insurance\"). Use empty string if none."),
                "payment_method": string("Optional payment method (e.g. \"GIRO\", \"Visa **1234\"). Use empty string if unknown."),
                "day_of_month": int("Day of the month the charge posts, 1-31. A value past a short month's end (e.g. 31) posts on that month's last day. If the user says \"the 1st\" use 1, \"the 15th\" use 15, etc. If they say \"start of the month\" use 1; \"end of the month\" use 31."),
                "start_date": string("OPTIONAL ISO 8601 date for the first month this should apply (e.g. 2026-07-01). Use empty string to start from the current month."),
                "end_date": string("OPTIONAL ISO 8601 date after which the charge should stop (e.g. 2027-06-30). Use empty string for an open-ended recurring charge.")
            ],
            required: ["id", "amount", "currency", "category", "merchant", "description", "payment_method", "day_of_month"]
        )
    )

    /// Bulk-delete finance entries matching an optional filter (#204). All
    /// filters are optional and ANDed. An unfiltered call is a full wipe of
    /// EVERY expense — the model must not issue that until the user has
    /// explicitly confirmed, and then it passes `confirm_all: true`. The
    /// executor enforces the same guard so the auto-executing capture / voice
    /// path can't wipe everything on a single unconfirmed request.
    private static let clearExpenses = AnthropicTool(
        name: "clear_expenses",
        description: "Bulk-delete expenses (finance entries) matching an optional filter. Use for requests like \"clear my expenses\", \"delete all my food expenses\", \"remove expenses before May\", \"delete everything I imported from DBS\". Apply whichever of after_date / before_date / category / source the user gives as an AND filter. SAFETY: if you provide NO filter (no after_date, no before_date, no category, no source) this deletes EVERY expense. Do NOT call this unfiltered on a first request — instead reply in plain text telling the user this will erase ALL their expenses and ask them to confirm (e.g. \"yes, clear all\"). Only after they explicitly confirm, call clear_expenses again with confirm_all: true. Filtered clears (any of after_date / before_date / category / source present) apply immediately and do NOT need confirm_all.",
        input_schema: object(
            properties: [
                "after_date": string("OPTIONAL ISO 8601 date (e.g. 2026-06-01). Delete only expenses dated STRICTLY AFTER this day. Omit or use empty string for no lower bound."),
                "before_date": string("OPTIONAL ISO 8601 date. Delete only expenses dated STRICTLY BEFORE this day. Omit or use empty string for no upper bound."),
                "category": string("OPTIONAL category to restrict the clear to. One of: food_and_dining, groceries, transport, shopping, entertainment, bills_and_utilities, rent, health_and_wellness, travel, subscriptions, personal_care, gifts_and_donations, other. Omit or use empty string to clear across all categories."),
                "source": string("OPTIONAL import source to restrict the clear to — the bank or statement name the user mentions (e.g. \"DBS\", \"Citi\", \"Amex\"). Use this for requests like \"delete all expenses imported from DBS\" or \"clear my Citi statement expenses\". Matches case-insensitively as a substring of the statement label / file name, so pass just the bank name the user said, not a full label. Only affects imported statement expenses. Omit or use empty string for no source constraint."),
                "confirm_all": bool("Set true ONLY to confirm an unfiltered clear of ALL expenses, and ONLY after the user has explicitly confirmed they want to erase everything. Ignored when any filter is present. Defaults to false.")
            ],
            required: []
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
        addExpense,
        addRecurringExpense,
        clearExpenses
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
        "add_expense": .addExpense,
        "add_recurring_expense": .addRecurringExpense,
        "clear_expenses": .clearExpenses
    ]
}
