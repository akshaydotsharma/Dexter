/**
 * OpenAI Client Module
 * Centralized OpenAI API client configuration
 */

const OpenAI = require('openai');

let openaiInstance = null;

/**
 * Get or create the OpenAI client instance
 * @returns {OpenAI} OpenAI client instance
 */
function getClient() {
    if (!openaiInstance) {
        const apiKey = process.env.OPENAI_API_KEY;
        if (!apiKey) {
            throw new Error('OPENAI_API_KEY is not configured. Please set it in your environment variables.');
        }
        openaiInstance = new OpenAI({ apiKey });
    }
    return openaiInstance;
}

/**
 * Configuration for chat completions
 */
const CONFIG = {
    model: 'gpt-5-nano',
    temperature: 0.3,
    maxTokens: 1024
};

module.exports = {
    getClient,
    CONFIG
};
