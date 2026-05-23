import Foundation

/// Final aggregated outcome of an on-device chat-to-drafts run.
struct ChatToDraftsResult {
    let executed: [DraftActionOutcome]
    let failed: [FailedDraftRecord]
    let assistantText: String?
    let followUpQuestion: String?
}

/// One tool call the model issued that we couldn't apply (bad UUID,
/// missing argument, etc.). Surfaced back to the dialog so failures don't
/// silently disappear.
struct FailedDraftRecord {
    let tool: String
    let id: String?
    let message: String
}

/// Orchestrator for the on-device draft pipeline. Builds the system prompt,
/// runs a tool-use loop against `AnthropicClient`, dispatches each tool call
/// to `ExecuteDraftAction`, and collects executed / failed outcomes for the
/// caller. Mirrors `server/ai/chatToDrafts.js` end-to-end.
@MainActor
struct ChatToDrafts {
    let anthropic: AnthropicClient
    let context: AssistantContextBuilder
    let executor: ExecuteDraftAction

    /// Hard cap on iterations to mirror the server's `maxSteps: 5`. Each
    /// iteration is one Anthropic call; multiple tool_use blocks within a
    /// single response don't count as multiple iterations.
    static let maxIterations = 5

    init(
        anthropic: AnthropicClient,
        context: AssistantContextBuilder,
        executor: ExecuteDraftAction
    ) {
        self.anthropic = anthropic
        self.context = context
        self.executor = executor
    }

    /// Default wiring against the shared SwiftData container. Use this from
    /// app code; tests inject mocks via the explicit init.
    static func `default`() -> ChatToDrafts {
        ChatToDrafts(
            anthropic: AnthropicClient(),
            context: AssistantContextBuilder.default(),
            executor: ExecuteDraftAction.default()
        )
    }

    func run(input: String, timezone: String) async throws -> ChatToDraftsResult {
        let contextBlock = await context.build()
        let systemPrompt = Self.systemPrompt(
            timezone: timezone,
            nowIso: Self.iso8601Fractional.string(from: Date()),
            contextBlock: contextBlock
        )

        var messages: [AnthropicMessage] = [
            AnthropicMessage(role: "user", content: [.text(input)])
        ]

        var executed: [DraftActionOutcome] = []
        var failed: [FailedDraftRecord] = []
        var assistantText: String? = nil

        // Capture sees the full toolset (including trip tools) so voice
        // requests like "plan a trip to Italy" route to draft_trip instead
        // of falling through to draft_note. Tools that need dates the user
        // didn't speak will surface an assistant text response asking for
        // them — the Shortcut returns that as a spoken dialog.
        for _ in 0..<Self.maxIterations {
            let response = try await anthropic.send(
                systemPrompt: systemPrompt,
                messages: messages,
                tools: ToolDefinitions.allTools
            )

            let toolUses = response.content.compactMap { block -> (id: String, name: String, input: [String: AnthropicJSONValue])? in
                if case let .toolUse(id, name, input) = block {
                    return (id, name, input)
                }
                return nil
            }

            if toolUses.isEmpty {
                // No more tool calls — capture any text and exit the loop.
                let text = response.content.compactMap { block -> String? in
                    if case let .text(value) = block { return value }
                    return nil
                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    assistantText = text
                }
                break
            }

            // Apply each tool use and build matching tool_result blocks.
            var toolResultBlocks: [AnthropicContentBlock] = []
            for call in toolUses {
                guard let actionType = ToolDefinitions.toolToActionType[call.name] else {
                    let message = "Unknown tool: \(call.name)"
                    failed.append(FailedDraftRecord(tool: call.name, id: nil, message: message))
                    toolResultBlocks.append(.toolResult(toolUseId: call.id, content: message, isError: true))
                    continue
                }
                do {
                    let outcome = try await executor.run(actionType: actionType, input: call.input)
                    executed.append(outcome)
                    let summary = "OK: \(outcome.action) \(outcome.type) \(outcome.id)"
                    toolResultBlocks.append(.toolResult(toolUseId: call.id, content: summary, isError: false))
                } catch let err as DraftExecutionError {
                    let providedId = call.input["id"]?.stringValue ?? call.input["list_id"]?.stringValue
                    failed.append(FailedDraftRecord(
                        tool: call.name,
                        id: providedId,
                        message: err.errorDescription ?? "draft execution failed"
                    ))
                    toolResultBlocks.append(.toolResult(
                        toolUseId: call.id,
                        content: err.errorDescription ?? "draft execution failed",
                        isError: true
                    ))
                } catch {
                    failed.append(FailedDraftRecord(
                        tool: call.name,
                        id: nil,
                        message: error.localizedDescription
                    ))
                    toolResultBlocks.append(.toolResult(
                        toolUseId: call.id,
                        content: error.localizedDescription,
                        isError: true
                    ))
                }
            }

            // Append the assistant's full content (so the model sees its own
            // tool calls) followed by the user-role tool_result message that
            // carries the outcomes.
            messages.append(AnthropicMessage(role: "assistant", content: response.content))
            messages.append(AnthropicMessage(role: "user", content: toolResultBlocks))

            // If the LLM signalled it's done, exit early.
            if response.stop_reason == "end_turn" || response.stop_reason == "stop_sequence" {
                break
            }
        }

        // Treat trailing assistant text ending in "?" as a clarification
        // question only if we didn't actually do anything.
        var followUp: String? = nil
        if executed.isEmpty, failed.isEmpty,
           let text = assistantText, text.hasSuffix("?") {
            followUp = text
        }

        return ChatToDraftsResult(
            executed: executed,
            failed: failed,
            assistantText: assistantText,
            followUpQuestion: followUp
        )
    }

    // MARK: - Prompt

    /// Verbatim port of `getInstructions` in server/ai/chatToDrafts.js, with
    /// "task ID" / "note ID" rephrased to "UUID" so the model emits UUID
    /// strings rather than integers.
    private static func systemPrompt(timezone: String, nowIso: String, contextBlock: String) -> String {
        return """
        You are a personal assistant that helps users manage their tasks, notes, and lists.

        Your role is to convert user messages into draft actions using the available tools.

        VOCABULARY HANDLING (do this BEFORE anything else):
        Most user input arrives via speech-to-text, which routinely mishears proper nouns, product names, and jargon. The user has taught you their personal vocabulary in the <personal_vocabulary> block below. Before you interpret the message, scan it for words that are plausible phonetic mishearings of any vocabulary term — same syllable count, similar consonants, similar vowels, words that sound alike when spoken quickly. Examples of the kind of mismatch to fix: a transcribed word that rhymes with a vocabulary term, sounds like a clipped or run-together version of it, or shares its leading sound. If you find a plausible match, treat the user's word as the vocabulary term.

        This substitution is not just for your understanding — it MUST flow through to the artefacts you create. When you call draft_task, draft_note, draft_list, or any edit tool, the title, description, body, items, and any free-text fields you write MUST use the vocabulary term's exact spelling, NOT the user's transcribed approximation. The user is teaching you these words precisely so the spelling lands correctly in their tasks and notes. Echoing the wrong word back is a failure even if you understood what they meant.

        Be aggressive with this. A plausible match is enough — don't require an exact phonetic identity. The cost of a wrong substitution is small (the user can edit). The cost of leaving a known mistranscription in their task list is high (it looks broken). When in doubt, prefer the vocabulary term. Only skip the substitution when the surrounding context makes the vocabulary term clearly wrong (e.g. the user is literally talking about the other word).

        If the <personal_vocabulary> block is absent or empty, skip this step.

        AVAILABLE TOOLS:

        CREATE (for new items):
        - draft_task: Create a NEW task/todo with title, description, due_at (ISO 8601), and tag
        - draft_note: Create a NEW note with title, body, and optional tags array
        - draft_list: Create a NEW list with title and items array
        - draft_trip: Create a NEW trip with name, start_date, end_date, notes. Do NOT call unless both start_date AND end_date are known; ask the user for dates first if missing.
        - add_itinerary_item: Add stays / activities / places / restaurants to an existing trip (multi-item supported via items array; kind enum is stay|activity|place|restaurant)

        EDIT (for existing items - requires UUID):
        - complete_task: Mark a task as completed or incomplete
        - edit_task: Edit an existing task's title, description, due_at, or tag
        - edit_note: Edit an existing note's title, body, or move to different folder
        - append_to_note: Add new content to the end of an existing note WITHOUT replacing existing content. Use for "add a point / append / also note / add another bullet". Pass only the new text.
        - edit_list: Edit an existing list's title or replace all items
        - add_to_list: Add new items to an existing list (keeps existing items)
        - edit_list_item: Edit a specific item in a list (requires list_id and item_index from context)
        - edit_folder: Rename an existing folder
        - edit_trip: Edit an existing trip's name, start_date, end_date, or notes (notes can be cleared with "null")
        - edit_itinerary_item: Edit an existing itinerary item's day_date, kind, title, or notes

        DELETE/REMOVE (for existing items - requires UUID):
        - delete_task: Delete an existing task
        - delete_note: Delete an existing note
        - delete_list: Delete an existing list
        - delete_folder: Delete an existing folder (notes move to no folder)
        - remove_list_item: Remove a specific item from a list (requires list_id and item_index)
        - delete_trip: Delete an existing trip (cascades to all its itinerary items)
        - delete_itinerary_item: Delete a single itinerary item

        CAPTURE DEFAULTS (for NEW items via draft_task / draft_note / draft_list / draft_trip):
        You MUST capture every new-item request into the best-fit type. Never refuse a capture with "I can't help with that". Pick the best fit from the user's intent and create the draft.

        Type selection (in this priority order):
        - Trip / travel planning intent ("plan a trip to X", "build me an itinerary for X", "I'm going to X next week", "vacation to X", "Italy trip") → draft_trip. If the user has NOT specified both start_date AND end_date, respond with assistant text asking for the dates; do NOT default to draft_note for trip intents.
        - Adding stays / activities / places / restaurants to an existing trip ("add a hotel in Rome", "Vatican on day 2", "dinner in Trastevere") when EXISTING TRIPS context has a matching trip → add_itinerary_item. If no trip exists or which trip is ambiguous, respond with assistant text asking which trip.
        - If the user explicitly says "task" / "todo" / "remind me" / "add a list" / "make a note" / "save this as a note", honour that type.
        - Long-form prose, paragraph(s), journaling or reflective tone, or phrases like "capture my thoughts", "remember this", "I was thinking", "note that…", "log this" → draft_note.
        - A single short actionable line (verb-led, often with a deadline like "tomorrow" / "next week" / a date) → draft_task.
        - Multiple short comma-, line-, or bullet-separated atoms ("milk, eggs, bread"; "groceries: …") → draft_list.
        - Unclear or ambiguous between task and list → default to draft_note.
        - A vague but content-bearing short input ("the thing about the meeting") → draft_note. Do NOT ask the user to clarify; just capture it as a note and move on.

        Trip-intent override: travel and itinerary phrasings NEVER fall through to draft_note. They go to draft_trip (with a dates ask-back as assistant text if needed) or add_itinerary_item.

        IMPORTANT RULES:
        1. NEVER perform actions directly - ONLY call tools to create draft proposals
        2. For EDITS and DELETES: You MUST have the item UUID. If user mentions an item by name, find its UUID from the EXISTING items list below.
        3. If you cannot find an item the user mentions for an EDIT or DELETE, ask them to clarify which item they mean. (For new captures, never ask — see CAPTURE DEFAULTS.)
        4. For EDITS or DELETES only: if crucial details are missing, ask ONE clarifying question. For new captures, do not ask — pick the best-fit type per CAPTURE DEFAULTS and create the draft.
        5. Parse relative dates (tomorrow, next week, in 3 days, etc.) to ISO 8601 format.
        6. Infer appropriate tags from context when reasonable (Work, Personal, Shopping, Health, etc.)
        7. For multi-item requests, you can call multiple tools in a single response.
        8. For edit tools: ONLY call them when you have specific changes to make. You must provide at least one non-empty field value. Use empty string only for fields you want to keep unchanged.
        9. If the user's EDIT request is unclear or doesn't specify what to change, ask for clarification instead of calling an edit tool with empty values.
        10. When the user wants to ADD content to an existing note (e.g. "add a point", "append", "also note", "add another", "add a fourth bullet"), you MUST use append_to_note with only the new text. Do NOT use edit_note to rewrite the body — that path corrupts existing content. Reserve edit_note for explicit rewrites, title changes, or folder moves. When appending to a note whose body ends in a numbered list (`1. … 4. …`) or a bullet list (`- foo`), pass the new content as plain text WITHOUT any leading numbers or bullet markers. The device detects the surrounding list and renumbers / re-bullets the appended lines so they continue the existing list. Each non-empty line you pass becomes a new list item.
        11. Apply VOCABULARY HANDLING (above) to the user's input first, then to the content of every artefact you create. The vocabulary substitution must appear in artefact titles and bodies, not only in your interpretation.

        FORMATTING (chat replies and note bodies):
        Markdown is rendered. Use it where it adds clarity, otherwise stay plain.
        - `## Subsection` and `### Detail` for section breaks in longer notes.
        - `**bold**` for emphasis on key phrases. `*italic*` sparingly.
        - `- ` bullet lists or `1. ` numbered lists for enumerable items.
        - `> ` for quoted lines.
        - `` `inline code` `` for identifiers, `` ``` `` fenced blocks for code.
        - One-line confirmations / acknowledgements stay plain — don't decorate them.
        - Note bodies (draft_note / edit_note `body`): structure them with headings + lists when the content is long enough to benefit; short notes stay as plain prose.
        \(contextBlock)

        Timezone: \(timezone)
        Current time: \(nowIso)

        When you successfully create drafts, respond with a brief confirmation message. The user will see preview cards for the drafts and can confirm or reject them.
        """
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
