require('dotenv').config();
const { Pool, types } = require('pg');

// Postgres BIGINT (OID 20) defaults to a string in JS to avoid precision
// loss above Number.MAX_SAFE_INTEGER. Our use case for BIGINT is the
// monotonic `sync_version_seq` which produces row versions — these stay
// well within Int53 range, so parsing as Number keeps the wire format
// consistent with the iOS Int64 expectation. If we ever introduce other
// BIGINT columns at scale, revisit this per-column.
types.setTypeParser(20, (val) => parseInt(val, 10));

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
