/**
 * Chat Handler Module
 * Orchestrates LLM calls and processes responses with function calling
 * Uses Vercel AI SDK
 */

const { generateText } = require('ai');
const { getChatModel, CONFIG } = require('./openaiClient');
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

    // Add current date context
    const today = new Date().toISOString().split('T')[0];
    const userMessage = `Today's date is ${today}. User input: "${userInput}"`;

    // Build messages array for Vercel AI SDK
    const messages = [
        ...conversationHistory.map(msg => ({
            role: msg.role,
            content: msg.content
        })),
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

    // Call Vercel AI SDK with function calling (using Chat API for proper tool support)
    const { text, toolCalls, usage, response } = await generateText({
        model: getChatModel(),
        system: SYSTEM_PROMPT,
        messages,
        tools,
        maxSteps: 5,
        temperature: CONFIG.temperature,
        maxTokens: CONFIG.maxTokens
    });

    // Calculate tokens used
    const tokensUsed = usage
        ? (usage.promptTokens || 0) + (usage.completionTokens || 0)
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
    // Note: In AI SDK v5, tool call arguments are in 'input' property, not 'args'
    if (toolCalls && toolCalls.length > 0) {
        for (const toolCall of toolCalls) {
            const functionName = toolCall.toolName;
            const functionArgs = toolCall.input || toolCall.args; // v5 uses 'input'

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
                    id: toolCall.toolCallId,
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
    if (text) {
        if (result.drafts.length === 0) {
            // No tools called - this is likely a clarifying question or conversation
            result.assistantText = text;

            // Check if it's a question
            if (text.includes('?')) {
                result.followUpQuestion = text;
            }
        } else {
            // There are drafts and also text - append to summary
            result.assistantText = text;
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
        responseId: response?.id || null
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
