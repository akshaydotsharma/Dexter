/**
 * AI Client Module (Vercel AI SDK + Anthropic)
 * Switched to Anthropic since the user's ANTHROPIC_API_KEY is configured.
 */

const { createAnthropic } = require('@ai-sdk/anthropic');

let providerInstance = null;

function getProvider() {
    if (!providerInstance) {
        const apiKey = process.env.ANTHROPIC_API_KEY;
        if (!apiKey) {
            throw new Error('ANTHROPIC_API_KEY is not configured. Please set it in your environment variables.');
        }
        providerInstance = createAnthropic({ apiKey });
    }
    return providerInstance;
}

function getChatModel(modelId) {
    const provider = getProvider();
    return provider(modelId || CONFIG.model);
}

const CONFIG = {
    model: 'claude-sonnet-4-5',
    temperature: 0.3,
    maxTokens: 1024,
};

module.exports = {
    getProvider,
    getChatModel,
    CONFIG,
};
