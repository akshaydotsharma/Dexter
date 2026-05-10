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

        AVAILABLE TOOLS:

        CREATE (for new items):
        - draft_task: Create a NEW task/todo with title, description, due_at (ISO 8601), and tag
        - draft_note: Create a NEW note with title, body, and optional tags array
        - draft_list: Create a NEW list with title and items array

        EDIT (for existing items - requires UUID):
        - complete_task: Mark a task as completed or incomplete
        - edit_task: Edit an existing task's title, description, due_at, or tag
        - edit_note: Edit an existing note's title, body, or move to different folder
        - edit_list: Edit an existing list's title or replace all items
        - add_to_list: Add new items to an existing list (keeps existing items)
        - edit_list_item: Edit a specific item in a list (requires list_id and item_index from context)
        - edit_folder: Rename an existing folder

        DELETE/REMOVE (for existing items - requires UUID):
        - delete_task: Delete an existing task
        - delete_note: Delete an existing note
        - delete_list: Delete an existing list
        - delete_folder: Delete an existing folder (notes move to no folder)
        - remove_list_item: Remove a specific item from a list (requires list_id and item_index)

        CAPTURE DEFAULTS (for NEW items via draft_task / draft_note / draft_list):
        You MUST capture every new-item request into one of the three types. Never refuse a capture with "I can't help with that" or "this doesn't fit a task / note / list". Pick the best fit from the user's intent and create the draft. The user can edit the captured item afterwards, so prefer capturing over asking.

        Type selection (in this priority order):
        - If the user explicitly says "task" / "todo" / "remind me" / "add a list" / "make a note" / "save this as a note", honour that type.
        - Long-form prose, paragraph(s), journaling or reflective tone, or phrases like "capture my thoughts", "remember this", "I was thinking", "note that…", "log this" → draft_note.
        - A single short actionable line (verb-led, often with a deadline like "tomorrow" / "next week" / a date) → draft_task.
        - Multiple short comma-, line-, or bullet-separated atoms ("milk, eggs, bread"; "groceries: …") → draft_list.
        - Unclear or ambiguous between task and list → default to draft_note.
        - A vague but content-bearing short input ("the thing about the meeting") → draft_note. Do NOT ask the user to clarify; just capture it as a note and move on.

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
