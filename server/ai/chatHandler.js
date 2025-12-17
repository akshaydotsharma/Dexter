/**
 * Chat Handler Module
 * Orchestrates LLM calls and processes responses with function calling
 */

const { getClient, CONFIG } = require('./openaiClient');
const { tools, toolToActionType, toolToEntityType } = require('./tools');
const draftStore = require('./draftStore');

/**
 * System prompt for the AI assistant
 */
const SYSTEM_PROMPT = `You are a helpful personal assistant that helps users manage their tasks, notes, and lists.

Your capabilities:
1. Create todos/tasks - with title, optional description, due date, and tags
2. Create notes - with title and content
3. Create lists - with title and list items

When users make requests:
- Use the appropriate function/tool to create draft actions
- Parse relative dates (tomorrow, next week, etc.) to ISO 8601 format
- Infer appropriate tags from context (Work, Personal, Shopping, Health, etc.)
- Be conversational and helpful in your responses
- If the user's intent is unclear, ask a clarifying question instead of guessing

For multi-item requests, you can call multiple functions in a single response.

Today's date context will be provided with each message.`;

/**
 * Process a chat message and return drafts + assistant text
 * @param {string} userInput The user's message
 * @param {Object} options Optional settings
 * @param {Array} options.conversationHistory - Previous messages for multi-turn
 * @param {string} options.sessionId - Session ID for message logging
 * @returns {Promise<Object>} { assistantText, drafts, followUpQuestion }
 */
async function processChat(userInput, options = {}) {
    const { conversationHistory = [], sessionId = null } = options;
    const openai = getClient();

    // Add current date context
    const today = new Date().toISOString().split('T')[0];
    const userMessage = `Today's date is ${today}. User input: "${userInput}"`;

    // Build messages array
    const messages = [
        { role: 'system', content: SYSTEM_PROMPT },
        ...conversationHistory,
        { role: 'user', content: userMessage }
    ];

    // Log user message to ai_messages table
    await draftStore.logMessage({
        sessionId,
        role: 'user',
        content: userInput,
        model: null,
        tokensUsed: null,
        responseId: null
    });

    // Call OpenAI with function calling
    const response = await openai.chat.completions.create({
        model: CONFIG.model,
        messages,
        tools,
        tool_choice: 'auto',
        temperature: CONFIG.temperature,
        max_tokens: CONFIG.maxTokens
    });

    const choice = response.choices[0];
    const message = choice.message;

    // Calculate tokens used
    const tokensUsed = response.usage
        ? response.usage.prompt_tokens + response.usage.completion_tokens
        : null;

    // Process the response
    const result = {
        assistantText: '',
        drafts: [],
        followUpQuestion: null,
        toolCalls: [],
        model: CONFIG.model
    };

    // Handle tool calls (function calling)
    if (message.tool_calls && message.tool_calls.length > 0) {
        for (const toolCall of message.tool_calls) {
            const functionName = toolCall.function.name;
            const functionArgs = JSON.parse(toolCall.function.arguments);

            const actionType = toolToActionType[functionName];
            const entityType = toolToEntityType[functionName];

            if (actionType && entityType) {
                // Create draft in database with model info
                const draft = await draftStore.createDraft({
                    actionType,
                    entityType,
                    entityId: null,
                    draftData: functionArgs,
                    originalInput: userInput,
                    model: CONFIG.model
                });

                result.drafts.push(draftStore.formatDraft(draft));
                result.toolCalls.push({
                    id: toolCall.id,
                    function: functionName,
                    arguments: functionArgs
                });
            }
        }

        // Generate a response acknowledging the drafts
        if (result.drafts.length > 0) {
            result.assistantText = generateDraftSummary(result.drafts);
        }
    }

    // Handle text response (could be a follow-up question or clarification)
    if (message.content) {
        if (result.drafts.length === 0) {
            // No tools called - this is likely a clarifying question or conversation
            result.assistantText = message.content;

            // Check if it's a question
            if (message.content.includes('?')) {
                result.followUpQuestion = message.content;
            }
        } else {
            // There are drafts and also text - append to summary
            result.assistantText = message.content;
        }
    }

    // Log assistant response to ai_messages table
    await draftStore.logMessage({
        sessionId,
        role: 'assistant',
        content: result.assistantText || '',
        toolCalls: result.toolCalls.length > 0 ? result.toolCalls : null,
        model: CONFIG.model,
        tokensUsed,
        responseId: response.id || null
    });

    return result;
}

/**
 * Generate a summary message for created drafts
 * @param {Array} drafts Array of draft objects
 * @returns {string} Summary text
 */
function generateDraftSummary(drafts) {
    if (drafts.length === 0) return '';

    const summaries = drafts.map(draft => {
        const data = draft.data;
        switch (draft.entity_type) {
            case 'todo':
                let todoSummary = `Task: "${data.title}"`;
                if (data.due_date) {
                    todoSummary += ` (due: ${new Date(data.due_date).toLocaleDateString()})`;
                }
                if (data.tag) {
                    todoSummary += ` [${data.tag}]`;
                }
                return todoSummary;
            case 'note':
                return `Note: "${data.title}"`;
            case 'list':
                return `List: "${data.title}" with ${data.items?.length || 0} items`;
            default:
                return `${draft.action_type}: ${data.title || 'Untitled'}`;
        }
    });

    if (summaries.length === 1) {
        return `I've prepared a draft for you:\n\n${summaries[0]}\n\nPlease review and confirm to create it.`;
    }

    return `I've prepared ${summaries.length} drafts for you:\n\n${summaries.map((s, i) => `${i + 1}. ${s}`).join('\n')}\n\nPlease review and confirm each one.`;
}

module.exports = {
    processChat,
    SYSTEM_PROMPT
};
