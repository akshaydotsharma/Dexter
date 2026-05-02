-- Migration script to update todos table with new fields
-- Run this on existing databases to preserve data

-- Rename text column to title (idempotent: only runs if `text` still exists)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'todos' AND column_name = 'text'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'todos' AND column_name = 'title'
    ) THEN
        ALTER TABLE todos RENAME COLUMN text TO title;
    END IF;
END $$;

-- Add new columns
ALTER TABLE todos ADD COLUMN IF NOT EXISTS description TEXT;
ALTER TABLE todos ADD COLUMN IF NOT EXISTS due_date TIMESTAMP;
ALTER TABLE todos ADD COLUMN IF NOT EXISTS tag TEXT;

-- =============================================================================
-- 2026-05-02: Add position columns for drag-to-reorder (refactor v2)
-- =============================================================================
-- Adds a nullable `position` integer to todos, notes, lists, and note_folders.
-- Backfills existing rows with gap-1000 sequential values derived from
-- created_at, so reorders between two rows can interpolate without renumbering
-- the whole scope. For notes the position scope is per-folder (folder_id +
-- position is the natural key); for everything else it is global.
--
-- Idempotent: re-running this script will NOT double-position rows. The backfill
-- only writes a value into rows where position IS NULL, and indexes use IF NOT
-- EXISTS. Columns remain nullable so future inserts that omit position succeed.

ALTER TABLE todos        ADD COLUMN IF NOT EXISTS position INTEGER;
ALTER TABLE notes        ADD COLUMN IF NOT EXISTS position INTEGER;
ALTER TABLE lists        ADD COLUMN IF NOT EXISTS position INTEGER;
ALTER TABLE note_folders ADD COLUMN IF NOT EXISTS position INTEGER;

-- Backfill todos: global ordering by created_at, step 1000, base 1000
WITH ranked AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS rn
    FROM todos
    WHERE position IS NULL
)
UPDATE todos t
SET position = ranked.rn * 1000
FROM ranked
WHERE t.id = ranked.id;

-- Backfill lists: global ordering by created_at, step 1000, base 1000
WITH ranked AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS rn
    FROM lists
    WHERE position IS NULL
)
UPDATE lists l
SET position = ranked.rn * 1000
FROM ranked
WHERE l.id = ranked.id;

-- Backfill note_folders: global ordering by created_at, step 1000, base 1000
WITH ranked AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS rn
    FROM note_folders
    WHERE position IS NULL
)
UPDATE note_folders f
SET position = ranked.rn * 1000
FROM ranked
WHERE f.id = ranked.id;

-- Backfill notes: ordering is PARTITIONED by folder_id (NULLs partition together
-- as the unfiled scope), step 1000, base 1000.
WITH ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (
               PARTITION BY folder_id
               ORDER BY created_at ASC, id ASC
           ) AS rn
    FROM notes
    WHERE position IS NULL
)
UPDATE notes n
SET position = ranked.rn * 1000
FROM ranked
WHERE n.id = ranked.id;

-- Indexes for the lookup paths used by reorder + list-render
CREATE INDEX IF NOT EXISTS todos_position_idx        ON todos (position);
CREATE INDEX IF NOT EXISTS lists_position_idx        ON lists (position);
CREATE INDEX IF NOT EXISTS note_folders_position_idx ON note_folders (position);
CREATE INDEX IF NOT EXISTS notes_folder_position_idx ON notes (folder_id, position);
