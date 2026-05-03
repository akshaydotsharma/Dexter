import Foundation

/// One event the chat surface consumes from `ChatStream.run`. Mirrors the
/// shape the old SSE consumer surfaced, but with single-draft yields (drafts
/// arrive one tool block at a time from Anthropic, not in batched payloads).
enum ChatStreamEvent: Sendable {
    case draft(ChatDraft)
    case textChunk(String)
    case done(followUpQuestion: String?)
    case error(String)
}

/// Chat-mode orchestrator. Unlike `ChatToDrafts` (which auto-executes tool
/// calls for the capture path), this version only proposes drafts — the
/// human in the chat loop confirms or rejects each card. No tool-result
/// turn-back, no multi-step loop: the model proposes once per user turn.
@MainActor
struct ChatStream {
    let anthropic: AnthropicClient
    let context: AssistantContextBuilder

    init(anthropic: AnthropicClient, context: AssistantContextBuilder) {
        self.anthropic = anthropic
        self.context = context
    }

    static func `default`() -> ChatStream {
        ChatStream(
            anthropic: AnthropicClient(),
            context: AssistantContextBuilder.default()
        )
    }

    func run(input: String, timezone: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let contextBlock = await context.build()
                    let systemPrompt = Self.systemPrompt(
                        timezone: timezone,
                        nowIso: Self.iso8601Fractional.string(from: Date()),
                        contextBlock: contextBlock
                    )
                    let messages: [AnthropicMessage] = [
                        AnthropicMessage(role: "user", content: [.text(input)])
                    ]

                    var accumulatedText = ""
                    var draftCount = 0

                    for try await event in anthropic.stream(
                        systemPrompt: systemPrompt,
                        messages: messages,
                        tools: ToolDefinitions.allTools
                    ) {
                        switch event {
                        case .textDelta(let chunk):
                            accumulatedText += chunk
                            continuation.yield(.textChunk(chunk))

                        case .toolUse(let name, let input):
                            guard let actionType = ToolDefinitions.toolToActionType[name] else {
                                // Unknown tool name from the model — surface
                                // as an error event but keep the stream open
                                // so any in-flight text still reaches the UI.
                                continuation.yield(.error("Unknown tool: \(name)"))
                                continue
                            }
                            let preview = ChatDraft.makePreview(actionType: actionType, input: input)
                            let draft = ChatDraft(
                                actionType: actionType,
                                input: input,
                                preview: preview
                            )
                            draftCount += 1
                            continuation.yield(.draft(draft))

                        case .done:
                            // Trailing assistant text ending in "?" is a
                            // clarifying question only when the model didn't
                            // propose any drafts this turn.
                            let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                            let followUp: String? = (draftCount == 0 && trimmed.hasSuffix("?")) ? trimmed : nil
                            continuation.yield(.done(followUpQuestion: followUp))

                        case .error(let msg):
                            continuation.yield(.error(msg))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompt

    /// Verbatim port of the system prompt used in `ChatToDrafts`. Kept as a
    /// duplicate (rather than a shared helper) because the two orchestrators
    /// diverge on tool-result handling and may grow apart in tone.
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
