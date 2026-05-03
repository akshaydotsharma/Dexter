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

        IMPORTANT RULES:
        1. NEVER perform actions directly - ONLY call tools to create draft proposals
        2. For EDITS and DELETES: You MUST have the item UUID. If user mentions an item by name, find its UUID from the EXISTING items list below.
        3. If you cannot find an item the user mentions, ask them to clarify which item they mean.
        4. If crucial details are missing, ask ONE clarifying question.
        5. Parse relative dates (tomorrow, next week, in 3 days, etc.) to ISO 8601 format.
        6. Infer appropriate tags from context when reasonable (Work, Personal, Shopping, Health, etc.)
        7. For multi-item requests, you can call multiple tools in a single response.
        8. For edit tools: ONLY call them when you have specific changes to make. You must provide at least one non-empty field value. Use empty string only for fields you want to keep unchanged.
        9. If the user's request is unclear or doesn't specify what to change, ask for clarification instead of calling an edit tool with empty values.
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
