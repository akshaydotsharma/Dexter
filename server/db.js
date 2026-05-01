require('dotenv').config();
const { Pool } = require('pg');

const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false,
});

/**
 * Run a callback inside a transaction, automatically committing or rolling back.
 * Used by reorder endpoints which need SELECT ... FOR UPDATE + UPDATE atomicity.
 *
 * @param {(client: import('pg').PoolClient) => Promise<any>} fn
 * @returns {Promise<any>} whatever fn returns
 */
async function withTransaction(fn) {
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        const result = await fn(client);
        await client.query('COMMIT');
        return result;
    } catch (err) {
        try { await client.query('ROLLBACK'); } catch (_) { /* ignore */ }
        throw err;
    } finally {
        client.release();
    }
}

module.exports = {
    query: (text, params) => pool.query(text, params),
    getClient: () => pool.connect(),
    withTransaction,
    pool,
};
