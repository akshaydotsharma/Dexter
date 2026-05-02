CREATE TABLE IF NOT EXISTS todos (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    completed BOOLEAN DEFAULT FALSE,
    due_date TIMESTAMP,
    tag TEXT,
    position INTEGER, -- ordering for drag-to-reorder; NULL allowed so legacy inserts still work
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
    name TEXT NOT NULL,
    position INTEGER, -- ordering for drag-to-reorder; NULL allowed so legacy inserts still work
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS note_folders_position_idx ON note_folders (position);

CREATE TABLE IF NOT EXISTS notes (
    id SERIAL PRIMARY KEY,
    folder_id INTEGER REFERENCES note_folders(id) ON DELETE CASCADE,
    title TEXT,
    content TEXT,
    position INTEGER, -- ordering within a folder (or unfiled scope when folder_id IS NULL)
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
    title TEXT NOT NULL,
    items JSONB DEFAULT '[]',
    position INTEGER, -- ordering for drag-to-reorder; NULL allowed so legacy inserts still work
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
