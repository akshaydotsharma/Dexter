/**
 * OpenAI Client Module (Vercel AI SDK)
 * Centralized AI client configuration using Vercel AI SDK
 */

const { createOpenAI } = require('@ai-sdk/openai');

let openaiInstance = null;

/**
 * Get or create the OpenAI provider instance
 * @returns {ReturnType<typeof createOpenAI>} OpenAI provider instance
 */
function getProvider() {
    if (!openaiInstance) {
        const apiKey = process.env.OPENAI_API_KEY;
        if (!apiKey) {
            throw new Error('OPENAI_API_KEY is not configured. Please set it in your environment variables.');
        }
        openaiInstance = createOpenAI({ apiKey });
    }
    return openaiInstance;
}

/**
 * Get a chat model instance (uses Chat Completions API, required for tool calling)
 * @param {string} modelId - Model identifier (default from CONFIG)
 * @returns {LanguageModelV1} Chat model instance
 */
function getChatModel(modelId) {
    const provider = getProvider();
    // Use .chat() to get Chat Completions API which properly supports tool calling
    return provider.chat(modelId || CONFIG.model);
}

/**
 * Configuration for AI generation
 */
const CONFIG = {
    model: 'gpt-4o-mini',
    temperature: 0.3,
    maxTokens: 1024
};

module.exports = {
    getProvider,
    getChatModel,
    CONFIG
};
