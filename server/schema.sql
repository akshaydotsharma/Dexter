CREATE TABLE IF NOT EXISTS todos (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT,
    completed BOOLEAN DEFAULT FALSE,
    due_date TIMESTAMP,
    tag TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT NULL
);

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

-- Note history/audit log table
CREATE TABLE IF NOT EXISTS note_history (
    id SERIAL PRIMARY KEY,
    note_id INTEGER NOT NULL,
    action TEXT NOT NULL, -- 'created', 'updated', 'deleted', 'moved'
    field_changed TEXT, -- which field was changed (null for create/delete)
    old_value TEXT, -- previous value (null for create)
    new_value TEXT, -- new value (null for delete)
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS note_folders (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS notes (
    id SERIAL PRIMARY KEY,
    folder_id INTEGER REFERENCES note_folders(id) ON DELETE CASCADE,
    title TEXT,
    content TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

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
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

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
