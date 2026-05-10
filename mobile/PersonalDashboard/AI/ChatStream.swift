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
        10. Apply VOCABULARY HANDLING (above) to the user's input first, then to the content of every artefact you create. The vocabulary substitution must appear in artefact titles and bodies, not only in your interpretation.

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

        Each tool call you make is applied immediately on the user's device — there is no preview-and-confirm step. Treat every successful tool call as already done. Reply with a brief past-tense confirmation (e.g. "Done — added that task." or "Got it, updated the list.") so the user knows the action completed; do not say "I'll draft that for you to confirm" or imply approval is still pending.
        """
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
