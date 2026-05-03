-- gen_random_uuid() ships with core Postgres 13+, but pgcrypto is a safe shim
-- for older builds. Idempotent; CREATE EXTENSION IF NOT EXISTS is a no-op when
-- the function is already in core.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Global monotonic sync version sequence. Every UPDATE on a synced table bumps
-- the row's `version` to nextval(). The iOS sync engine watermarks on the max
-- version it has seen and asks the server for everything newer in one call.
CREATE SEQUENCE IF NOT EXISTS sync_version_seq;

CREATE TABLE IF NOT EXISTS todos (
    id SERIAL PRIMARY KEY,
    client_uuid UUID UNIQUE DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    description TEXT,
    completed BOOLEAN DEFAULT FALSE,
    due_date TIMESTAMP,
    tag TEXT,
    position INTEGER, -- ordering for drag-to-reorder; NULL allowed so legacy inserts still work
    version BIGINT NOT NULL DEFAULT nextval('sync_version_seq'),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS todos_position_idx ON todos (position);

-- Add updated_at and deleted_at columns if they don't exist (for existing databases)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'todos' AND column_name = 'updated_at') THEN
        ALTER TABLE todos ADD COLUMN updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'todos' AND column_name = 'deleted_at') THEN
        ALTER TABLE todos ADD COLUMN deleted_at TIMESTAMP DEFAULT NULL;
    END IF;
END $$;

-- Task history/audit log table
CREATE TABLE IF NOT EXISTS todo_history (
    id SERIAL PRIMARY KEY,
    todo_id INTEGER NOT NULL,
    action TEXT NOT NULL, -- 'created', 'updated', 'completed', 'uncompleted', 'deleted', 'restored'
    field_changed TEXT, -- which field was changed (null for create/delete)
    old_value TEXT, -- previous value (null for create)
    new_value TEXT, -- new value (null for delete)
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Note history/audit log table (tracks both notes and folders)
CREATE TABLE IF NOT EXISTS note_history (
    id SERIAL PRIMARY KEY,
    note_id INTEGER NOT NULL, -- note_id or folder_id depending on entity_type
    entity_type TEXT DEFAULT 'note', -- 'note' or 'folder'
    action TEXT NOT NULL, -- 'created', 'updated', 'deleted', 'moved'
    field_changed TEXT, -- which field was changed (null for create/delete)
    old_value TEXT, -- previous value (null for create)
    new_value TEXT, -- new value (null for delete)
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Add entity_type column if it doesn't exist (for existing databases)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'note_history' AND column_name = 'entity_type') THEN
        ALTER TABLE note_history ADD COLUMN entity_type TEXT DEFAULT 'note';
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS note_folders (
    id SERIAL PRIMARY KEY,
    client_uuid UUID UNIQUE DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    position INTEGER, -- ordering for drag-to-reorder; NULL allowed so legacy inserts still work
    version BIGINT NOT NULL DEFAULT nextval('sync_version_seq'),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS note_folders_position_idx ON note_folders (position);

CREATE TABLE IF NOT EXISTS notes (
    id SERIAL PRIMARY KEY,
    client_uuid UUID UNIQUE DEFAULT gen_random_uuid(),
    folder_id INTEGER REFERENCES note_folders(id) ON DELETE CASCADE,
    title TEXT,
    content TEXT,
    position INTEGER, -- ordering within a folder (or unfiled scope when folder_id IS NULL)
    version BIGINT NOT NULL DEFAULT nextval('sync_version_seq'),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS notes_folder_position_idx ON notes (folder_id, position);

-- Add folder_id and updated_at columns if they don't exist (for existing databases)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'notes' AND column_name = 'folder_id') THEN
        ALTER TABLE notes ADD COLUMN folder_id INTEGER REFERENCES note_folders(id) ON DELETE CASCADE;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'notes' AND column_name = 'updated_at') THEN
        ALTER TABLE notes ADD COLUMN updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS lists (
    id SERIAL PRIMARY KEY,
    client_uuid UUID UNIQUE DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    items JSONB DEFAULT '[]',
    position INTEGER, -- ordering for drag-to-reorder; NULL allowed so legacy inserts still work
    version BIGINT NOT NULL DEFAULT nextval('sync_version_seq'),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT NULL
);

CREATE INDEX IF NOT EXISTS lists_position_idx ON lists (position);

-- List history/audit log table
CREATE TABLE IF NOT EXISTS list_history (
    id SERIAL PRIMARY KEY,
    list_id INTEGER NOT NULL,
    action TEXT NOT NULL, -- 'created', 'updated', 'deleted', 'item_added', 'item_removed', 'item_checked', 'item_unchecked'
    field_changed TEXT, -- which field was changed (null for create/delete)
    old_value TEXT, -- previous value (null for create)
    new_value TEXT, -- new value (null for delete)
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS dashboard_config (
    id SERIAL PRIMARY KEY,
    layout_preference JSONB
);

-- Insert default dashboard config if empty
INSERT INTO dashboard_config (id, layout_preference)
SELECT 1, '{"widgets": ["todos", "notes", "lists"]}'
WHERE NOT EXISTS (SELECT 1 FROM dashboard_config WHERE id = 1);

-- Draft actions table for v2.0 LLM draft generator pattern
-- Stores pending actions from AI before user confirmation
CREATE TABLE IF NOT EXISTS draft_actions (
    id SERIAL PRIMARY KEY,
    action_type TEXT NOT NULL, -- 'CREATE_TODO', 'CREATE_NOTE', 'CREATE_LIST', 'UPDATE_TODO', etc.
    entity_type TEXT NOT NULL, -- 'todo', 'note', 'list'
    entity_id INTEGER, -- null for creates, populated for updates/deletes
    draft_data JSONB NOT NULL, -- the proposed changes/new entity data
    original_input TEXT, -- the user's natural language input
    status TEXT DEFAULT 'pending', -- 'pending', 'confirmed', 'rejected', 'expired'
    model TEXT, -- model used for generation (e.g., 'gpt-4o-mini')
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMP, -- when user confirmed/rejected
    result_entity_id INTEGER -- the id of the created/updated entity after confirmation
);

-- Add model column if it doesn't exist (for existing databases)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'draft_actions' AND column_name = 'model') THEN
        ALTER TABLE draft_actions ADD COLUMN model TEXT;
    END IF;
END $$;

-- AI messages table for conversation tracking (LLM layer audit)
-- Tracks all messages in AI conversations for debugging and multi-turn support
CREATE TABLE IF NOT EXISTS ai_messages (
    id SERIAL PRIMARY KEY,
    session_id TEXT, -- optional: group messages into conversations
    role TEXT NOT NULL, -- 'user', 'assistant', 'system'
    content TEXT NOT NULL, -- the message content
    tool_calls JSONB, -- function/tool calls made by assistant (if any)
    model TEXT, -- model used (e.g., 'gpt-4o-mini')
    tokens_used INTEGER, -- total tokens for this message (input + output)
    response_id TEXT, -- OpenAI response ID for debugging
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =============================================================================
-- Sync metadata triggers
-- =============================================================================
-- Each synced table has a BEFORE UPDATE trigger that bumps `version` to the
-- next value of `sync_version_seq` and refreshes `updated_at`. The iOS sync
-- engine uses `version` as the sole watermark for delta pulls.

CREATE OR REPLACE FUNCTION bump_sync_metadata() RETURNS trigger AS $$
BEGIN
    NEW.version := nextval('sync_version_seq');
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS todos_bump_sync ON todos;
CREATE TRIGGER todos_bump_sync BEFORE UPDATE ON todos
    FOR EACH ROW EXECUTE FUNCTION bump_sync_metadata();

DROP TRIGGER IF EXISTS notes_bump_sync ON notes;
CREATE TRIGGER notes_bump_sync BEFORE UPDATE ON notes
    FOR EACH ROW EXECUTE FUNCTION bump_sync_metadata();

DROP TRIGGER IF EXISTS lists_bump_sync ON lists;
CREATE TRIGGER lists_bump_sync BEFORE UPDATE ON lists
    FOR EACH ROW EXECUTE FUNCTION bump_sync_metadata();

DROP TRIGGER IF EXISTS note_folders_bump_sync ON note_folders;
CREATE TRIGGER note_folders_bump_sync BEFORE UPDATE ON note_folders
    FOR EACH ROW EXECUTE FUNCTION bump_sync_metadata();

CREATE INDEX IF NOT EXISTS todos_version_idx        ON todos (version);
CREATE INDEX IF NOT EXISTS notes_version_idx        ON notes (version);
CREATE INDEX IF NOT EXISTS lists_version_idx        ON lists (version);
CREATE INDEX IF NOT EXISTS note_folders_version_idx ON note_folders (version);
