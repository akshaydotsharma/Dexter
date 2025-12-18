/**
 * Quick test script to verify OpenAI API connection with gpt-4.1
 * Run with: node test-bytez.js
 */

require('dotenv').config();
const OpenAI = require('openai');

async function test() {
    console.log('Testing OpenAI API connection...');
    console.log('Using model: gpt-5-nano');

    const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

    try {
        // Test with the Responses API
        const response = await openai.responses.create({
            model: 'gpt-5-nano',
            input: 'Say "Hello! OpenAI is working!" and nothing else.'
        });

        console.log('Success!');
        console.log('Response ID:', response.id);
        console.log('Output:', response.output_text || response.output);
    } catch (err) {
        console.error('Error:', err.message);
        if (err.status) {
            console.error('Status:', err.status);
        }
        process.exit(1);
    }
}

test();
