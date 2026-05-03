/**
 * Sync endpoints for the iOS local-first data layer (#14).
 *
 * Two endpoints:
 *
 *   GET  /api/sync/changes?since_version=N
 *     Returns every row across todos, notes, lists, and note_folders whose
 *     `version` is strictly greater than `since_version`. Includes
 *     soft-deleted rows so the iOS engine receives tombstones and can prune
 *     local state. Response includes `max_version`, the new watermark the
 *     client should pass on the next pull.
 *
 *   POST /api/sync/upsert
 *     Accepts a batch of changes from the client keyed by `client_uuid`.
 *     For each row:
 *       - If no row with this client_uuid exists on the server, INSERT.
 *       - If a row exists and the server's updated_at is OLDER than the
 *         client's, UPDATE (client wins).
 *       - If a row exists and the server's updated_at is NEWER, REJECT
 *         (server wins; client should adopt server's row on next pull).
 *
 * Conflict policy: last-write-wins by `updated_at`. The trigger
 * `bump_sync_metadata()` handles version + updated_at on every UPDATE so
 * application code does not need to set them.
 */

const TABLES = ['todos', 'notes', 'lists', 'note_folders'];

// Schemas describe which columns a client may upsert per table. id and
// auto-managed columns (version, created_at, updated_at) are NOT in this list.
// `deleted_at` is allowed so a client can submit a soft-delete intent.
const TABLE_SCHEMAS = {
    todos: ['title', 'description', 'completed', 'due_date', 'tag', 'position', 'deleted_at'],
    notes: ['title', 'content', 'folder_id', 'position', 'deleted_at'],
    lists: ['title', 'items', 'position', 'deleted_at'],
    note_folders: ['name', 'position', 'deleted_at'],
};

/**
 * GET /api/sync/changes?since_version=N
 * Returns the delta across all synced tables.
 */
async function handleChanges(req, res, db) {
    const since = Number.parseInt(req.query.since_version, 10);
    const sinceVersion = Number.isFinite(since) && since >= 0 ? since : 0;

    try {
        const result = {};
        let maxVersion = sinceVersion;

        for (const table of TABLES) {
            const { rows } = await db.query(
                `SELECT * FROM ${table} WHERE version > $1 ORDER BY version ASC`,
                [sinceVersion]
            );
            result[table] = rows;
            for (const row of rows) {
                const v = Number(row.version);
                if (v > maxVersion) maxVersion = v;
            }
        }

        result.max_version = maxVersion;
        res.json(result);
    } catch (err) {
        console.error('[SYNC] /changes failed:', err);
        res.status(500).json({ error: err.message });
    }
}

/**
 * POST /api/sync/upsert
 * Body: { todos?: [...], notes?: [...], lists?: [...], note_folders?: [...] }
 * Each row must include client_uuid + updated_at. Other columns may be omitted.
 */
async function handleUpsert(req, res, db) {
    const body = req.body || {};
    const result = {
        applied: { todos: [], notes: [], lists: [], note_folders: [] },
        rejected: { todos: [], notes: [], lists: [], note_folders: [] },
        max_version: 0,
    };

    try {
        await db.withTransaction(async (client) => {
            for (const table of TABLES) {
                const incoming = Array.isArray(body[table]) ? body[table] : [];
                for (const row of incoming) {
                    if (!row || !row.client_uuid) {
                        result.rejected[table].push({ client_uuid: row?.client_uuid ?? null, reason: 'missing_client_uuid' });
                        continue;
                    }
                    if (!row.updated_at) {
                        result.rejected[table].push({ client_uuid: row.client_uuid, reason: 'missing_updated_at' });
                        continue;
                    }

                    const { rows: existingRows } = await client.query(
                        `SELECT * FROM ${table} WHERE client_uuid = $1`,
                        [row.client_uuid]
                    );

                    if (existingRows.length === 0) {
                        // INSERT path. Build column list from schema, only
                        // including keys present on the incoming row.
                        const cols = ['client_uuid'];
                        const vals = [row.client_uuid];
                        for (const col of TABLE_SCHEMAS[table]) {
                            if (Object.prototype.hasOwnProperty.call(row, col)) {
                                cols.push(col);
                                vals.push(serializeValue(table, col, row[col]));
                            }
                        }
                        const placeholders = vals.map((_, i) => `$${i + 1}`).join(', ');
                        const { rows: inserted } = await client.query(
                            `INSERT INTO ${table} (${cols.join(', ')}) VALUES (${placeholders}) RETURNING *`,
                            vals
                        );
                        result.applied[table].push(inserted[0]);
                    } else {
                        // UPDATE path with last-write-wins conflict check.
                        const server = existingRows[0];
                        const serverUpdated = new Date(server.updated_at).getTime();
                        const clientUpdated = new Date(row.updated_at).getTime();

                        if (Number.isNaN(clientUpdated)) {
                            result.rejected[table].push({ client_uuid: row.client_uuid, reason: 'invalid_updated_at' });
                            continue;
                        }

                        if (serverUpdated >= clientUpdated) {
                            // Server wins. Return the current server row so
                            // the client adopts it on this round-trip without
                            // needing a follow-up GET.
                            result.rejected[table].push({
                                client_uuid: row.client_uuid,
                                reason: 'server_newer',
                                server_row: server,
                            });
                            continue;
                        }

                        // Client wins: build SET clause from schema-allowed keys.
                        const sets = [];
                        const vals = [];
                        for (const col of TABLE_SCHEMAS[table]) {
                            if (Object.prototype.hasOwnProperty.call(row, col)) {
                                sets.push(`${col} = $${vals.length + 1}`);
                                vals.push(serializeValue(table, col, row[col]));
                            }
                        }
                        if (sets.length === 0) {
                            // Nothing to update; treat as applied with no diff.
                            result.applied[table].push(server);
                            continue;
                        }
                        vals.push(row.client_uuid);
                        const { rows: updated } = await client.query(
                            `UPDATE ${table} SET ${sets.join(', ')} WHERE client_uuid = $${vals.length} RETURNING *`,
                            vals
                        );
                        result.applied[table].push(updated[0]);
                    }
                }
            }
        });

        // Compute max_version across applied rows.
        for (const table of TABLES) {
            for (const row of result.applied[table]) {
                const v = Number(row.version);
                if (v > result.max_version) result.max_version = v;
            }
            for (const reject of result.rejected[table]) {
                if (reject.server_row) {
                    const v = Number(reject.server_row.version);
                    if (v > result.max_version) result.max_version = v;
                }
            }
        }

        res.json(result);
    } catch (err) {
        console.error('[SYNC] /upsert failed:', err);
        res.status(500).json({ error: err.message });
    }
}

/**
 * Some columns need explicit serialization (JSONB, dates).
 */
function serializeValue(table, column, value) {
    if (value === null || value === undefined) return null;
    if (table === 'lists' && column === 'items') {
        return typeof value === 'string' ? value : JSON.stringify(value);
    }
    return value;
}

function mountSyncRoutes(app, db) {
    app.get('/api/sync/changes', (req, res) => handleChanges(req, res, db));
    app.post('/api/sync/upsert', (req, res) => handleUpsert(req, res, db));
}

module.exports = { mountSyncRoutes, TABLES, TABLE_SCHEMAS };
