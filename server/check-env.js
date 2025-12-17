require('dotenv').config();

// Security: Only log whether the key is set, NEVER log any part of the key itself
console.log('Environment Variables Check:');
console.log('----------------------------');
console.log('OPENAI_API_KEY:', process.env.OPENAI_API_KEY ? '✓ Set (hidden for security)' : '✗ NOT SET');
console.log('DATABASE_URL:', process.env.DATABASE_URL ? '✓ Set (hidden for security)' : '✗ NOT SET');
console.log('NODE_ENV:', process.env.NODE_ENV || 'not set (defaults to development)');
console.log('PORT:', process.env.PORT || '3000 (default)');
