/**
 * Reorder helpers for drag-to-reorder endpoints.
 *
 * The position model is gap-1000 sparse integers per scope. To move a row
 * between two neighbours we set its position to the midpoint of theirs. If
 * the gap collapses to <= 1 we renumber the entire scope to step 1000 and
 * place the moved row in the right slot.
 *
 * `scopeFilter` lets callers add an extra WHERE clause without exposing
 * column lists from the route handler. It must be parameterized via the
 * `params` slot to avoid SQL injection — a bare object of field=value pairs
 * is the only shape accepted.
 */

const STEP = 1000;

/**
 * Build a parameterised WHERE fragment from a scopeFilter object.
 * Returns { sql, params } where sql is `<col> = $N AND <col2> IS NULL ...`
 * and params is the ordered values to splice into the calling query's
 * params array. NULL values are emitted as `IS NULL` rather than `= NULL`.
 *
 * Caller passes its own paramOffset so the placeholders line up with the
 * surrounding query's existing params.
 *
 * @param {Object} scopeFilter
 * @param {number} paramOffset existing params already in the query
 * @returns {{ sql: string, params: any[] }}
 */
function buildScopeWhere(scopeFilter, paramOffset = 0) {
    const parts = [];
    const params = [];
    let i = paramOffset;
    for (const [col, val] of Object.entries(scopeFilter)) {
        // Hard guard: only allow simple identifiers as column names. This is
        // a defence-in-depth check — callers always pass literal strings — but
        // it ensures a typo never becomes an injection vector.
        if (!/^[a-z_][a-z0-9_]*$/i.test(col)) {
            throw new Error(`Invalid scope column: ${col}`);
        }
        if (val === null) {
            parts.push(`${col} IS NULL`);
        } else {
            i += 1;
            parts.push(`${col} = $${i}`);
            params.push(val);
        }
    }
    return { sql: parts.length ? parts.join(' AND ') : 'TRUE', params };
}

/**
 * Allowlist of tables we accept. Identifier interpolation in SQL is otherwise
 * a footgun; this is the cheapest way to make it safe.
 */
const ALLOWED_TABLES = new Set(['todos', 'notes', 'lists', 'note_folders']);

function assertTable(table) {
    if (!ALLOWED_TABLES.has(table)) {
        throw new Error(`Reorder not supported for table: ${table}`);
    }
}

/**
 * Renumber every row in scope to step-1000 positions in current ascending
 * position order. Inserts the moving row (`movingId`) at the right slot
 * relative to before/after neighbours. Caller is responsible for the
 * surrounding transaction.
 *
 * Returns the new position of the moving row.
 *
 * @param {import('pg').PoolClient} client
 * @param {string} table
 * @param {Object} scopeFilter
 * @param {number} movingId
 * @param {number|null} beforeId row that should end up immediately above
 * @param {number|null} afterId row that should end up immediately below
 */
async function renumberScope(client, table, scopeFilter, movingId, beforeId, afterId) {
    assertTable(table);
    const { sql: scopeSql, params: scopeParams } = buildScopeWhere(scopeFilter);
    // Lock and read the current order. Excluding the moving row from the
    // sorted snapshot and re-inserting it at the desired slot is simpler
    // than computing offsets afterwards.
    const { rows } = await client.query(
        `SELECT id, position FROM ${table}
         WHERE ${scopeSql} AND id <> $${scopeParams.length + 1}
         ORDER BY position ASC NULLS LAST, id ASC
         FOR UPDATE`,
        [...scopeParams, movingId]
    );
    const ordered = rows.map(r => r.id);

    // Resolve the slot index where `movingId` should land.
    let insertIdx;
    if (beforeId == null && afterId == null) {
        // No neighbours specified — append to the end.
        insertIdx = ordered.length;
    } else if (beforeId == null) {
        // afterId only — place at the very top.
        insertIdx = 0;
    } else if (afterId == null) {
        // beforeId only — place at the very end.
        insertIdx = ordered.length;
    } else {
        // Place between beforeId and afterId. Find beforeId and put us right after.
        const idx = ordered.indexOf(beforeId);
        insertIdx = idx === -1 ? ordered.length : idx + 1;
    }

    ordered.splice(insertIdx, 0, movingId);

    // Single round-trip update via UPDATE ... FROM (VALUES ...).
    if (ordered.length === 0) {
        return STEP; // nothing to update; should not happen because movingId exists
    }
    const valuesClauses = [];
    const updateParams = [];
    let p = 0;
    ordered.forEach((id, i) => {
        const pos = (i + 1) * STEP;
        valuesClauses.push(`($${++p}::int, $${++p}::int)`);
        updateParams.push(id, pos);
    });
    await client.query(
        `UPDATE ${table} AS t
         SET position = v.pos
         FROM (VALUES ${valuesClauses.join(', ')}) AS v(id, pos)
         WHERE t.id = v.id`,
        updateParams
    );

    return (insertIdx + 1) * STEP;
}

/**
 * Compute the new position for a row given before/after neighbour ids.
 * Locks the involved rows for update. Renumbers the scope when the gap is
 * too tight (<= 1).
 *
 * @param {import('pg').PoolClient} client
 * @param {string} table
 * @param {Object} scopeFilter columns + values that define the ordering scope
 * @param {number} movingId the id of the row being reordered
 * @param {number|null} beforeId row that should end up immediately above the
 *        moving row in the final order. null means "moving to the very top".
 * @param {number|null} afterId row that should end up immediately below the
 *        moving row. null means "moving to the very end".
 * @returns {Promise<number>} new position value to write
 */
async function computeNewPosition(client, table, scopeFilter, movingId, beforeId, afterId) {
    assertTable(table);

    // Lock the moving row first to serialize concurrent reorder calls on the same id.
    await client.query(`SELECT id FROM ${table} WHERE id = $1 FOR UPDATE`, [movingId]);

    // Both null => place at the bottom of the scope.
    if (beforeId == null && afterId == null) {
        const { sql: scopeSql, params: scopeParams } = buildScopeWhere(scopeFilter);
        const { rows } = await client.query(
            `SELECT COALESCE(MAX(position), 0) AS max_pos FROM ${table} WHERE ${scopeSql} AND id <> $${scopeParams.length + 1}`,
            [...scopeParams, movingId]
        );
        return Number(rows[0].max_pos) + STEP;
    }

    // afterId only => place at the very top of the scope.
    if (beforeId == null) {
        const { sql: scopeSql, params: scopeParams } = buildScopeWhere(scopeFilter);
        // Find the smallest position in scope (excluding the moving row).
        const { rows } = await client.query(
            `SELECT MIN(position) AS min_pos FROM ${table} WHERE ${scopeSql} AND id <> $${scopeParams.length + 1}`,
            [...scopeParams, movingId]
        );
        const minPos = rows[0].min_pos == null ? STEP * 2 : Number(rows[0].min_pos);
        if (minPos > 1) {
            return Math.floor(minPos / 2);
        }
        // Min position is already at floor — renumber.
        return await renumberScope(client, table, scopeFilter, movingId, null, afterId);
    }

    // beforeId only => place at the very end. Same as both-null but anchored
    // by an explicit before so we still validate that beforeId is in scope.
    if (afterId == null) {
        const { sql: scopeSql, params: scopeParams } = buildScopeWhere(scopeFilter);
        const { rows } = await client.query(
            `SELECT COALESCE(MAX(position), 0) AS max_pos FROM ${table} WHERE ${scopeSql} AND id <> $${scopeParams.length + 1}`,
            [...scopeParams, movingId]
        );
        return Number(rows[0].max_pos) + STEP;
    }

    // Both neighbours present — interpolate.
    const { rows: neighbourRows } = await client.query(
        `SELECT id, position FROM ${table} WHERE id = ANY($1::int[]) FOR UPDATE`,
        [[beforeId, afterId]]
    );
    const before = neighbourRows.find(r => r.id === beforeId);
    const after = neighbourRows.find(r => r.id === afterId);
    if (!before || !after || before.position == null || after.position == null) {
        // Stale neighbour ids — fall back to renumbering, which is robust to
        // missing rows (it just orders whatever is in scope).
        return await renumberScope(client, table, scopeFilter, movingId, beforeId, afterId);
    }
    const lo = Math.min(before.position, after.position);
    const hi = Math.max(before.position, after.position);
    if (hi - lo <= 1) {
        return await renumberScope(client, table, scopeFilter, movingId, beforeId, afterId);
    }
    return Math.floor((lo + hi) / 2);
}

module.exports = {
    computeNewPosition,
    renumberScope,
    buildScopeWhere,
    STEP,
};
