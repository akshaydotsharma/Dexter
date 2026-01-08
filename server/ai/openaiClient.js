/**
 * AI Client Module (Vercel AI SDK)
 * Centralized AI client configuration using Vercel AI SDK with Anthropic Claude
 */

const { createAnthropic } = require('@ai-sdk/anthropic');

let anthropicInstance = null;

/**
 * Get or create the Anthropic provider instance
 * @returns {ReturnType<typeof createAnthropic>} Anthropic provider instance
 */
function getProvider() {
    if (!anthropicInstance) {
        const apiKey = process.env.ANTHROPIC_API_KEY;
        if (!apiKey) {
            throw new Error('ANTHROPIC_API_KEY is not configured. Please set it in your environment variables.');
        }
        anthropicInstance = createAnthropic({ apiKey });
    }
    return anthropicInstance;
}

/**
 * Get a chat model instance
 * @param {string} modelId - Model identifier (default from CONFIG)
 * @returns {LanguageModelV1} Chat model instance
 */
function getChatModel(modelId) {
    const provider = getProvider();
    return provider(modelId || CONFIG.model);
}

/**
 * Configuration for AI generation
 */
const CONFIG = {
    model: 'claude-sonnet-4-20250514',
    temperature: 0.3,
    maxTokens: 1024
};

module.exports = {
    getProvider,
    getChatModel,
    CONFIG
};
