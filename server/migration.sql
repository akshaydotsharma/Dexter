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

-- =============================================================================
-- 2026-05-03: Sync metadata for iOS local-first data layer (#14)
-- =============================================================================
-- Adds a global monotonic sync-version sequence, plus per-row `version`,
-- `client_uuid`, `updated_at`, and `deleted_at` columns to todos, notes, lists,
-- and note_folders so the iOS SwiftData store can do delta sync. A BEFORE
-- UPDATE trigger on each table bumps version + updated_at on every UPDATE so
-- application code does not have to remember to set them. client_uuid lets the
-- phone create rows offline with a stable identity that the server adopts on
-- first sync.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, conditional UNIQUE constraint, ALTER
-- COLUMN SET NOT NULL only after backfill, DROP TRIGGER IF EXISTS before
-- recreating. Re-running the script is a no-op once applied.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SEQUENCE IF NOT EXISTS sync_version_seq;

ALTER TABLE todos        ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT nextval('sync_version_seq');
ALTER TABLE notes        ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT nextval('sync_version_seq');
ALTER TABLE lists        ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT nextval('sync_version_seq');
ALTER TABLE note_folders ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT nextval('sync_version_seq');

ALTER TABLE todos        ADD COLUMN IF NOT EXISTS client_uuid UUID;
ALTER TABLE notes        ADD COLUMN IF NOT EXISTS client_uuid UUID;
ALTER TABLE lists        ADD COLUMN IF NOT EXISTS client_uuid UUID;
ALTER TABLE note_folders ADD COLUMN IF NOT EXISTS client_uuid UUID;

UPDATE todos        SET client_uuid = gen_random_uuid() WHERE client_uuid IS NULL;
UPDATE notes        SET client_uuid = gen_random_uuid() WHERE client_uuid IS NULL;
UPDATE lists        SET client_uuid = gen_random_uuid() WHERE client_uuid IS NULL;
UPDATE note_folders SET client_uuid = gen_random_uuid() WHERE client_uuid IS NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'todos_client_uuid_key') THEN
        ALTER TABLE todos ADD CONSTRAINT todos_client_uuid_key UNIQUE (client_uuid);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'notes_client_uuid_key') THEN
        ALTER TABLE notes ADD CONSTRAINT notes_client_uuid_key UNIQUE (client_uuid);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lists_client_uuid_key') THEN
        ALTER TABLE lists ADD CONSTRAINT lists_client_uuid_key UNIQUE (client_uuid);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'note_folders_client_uuid_key') THEN
        ALTER TABLE note_folders ADD CONSTRAINT note_folders_client_uuid_key UNIQUE (client_uuid);
    END IF;
END $$;

ALTER TABLE todos        ALTER COLUMN client_uuid SET NOT NULL;
ALTER TABLE notes        ALTER COLUMN client_uuid SET NOT NULL;
ALTER TABLE lists        ALTER COLUMN client_uuid SET NOT NULL;
ALTER TABLE note_folders ALTER COLUMN client_uuid SET NOT NULL;

ALTER TABLE todos        ALTER COLUMN client_uuid SET DEFAULT gen_random_uuid();
ALTER TABLE notes        ALTER COLUMN client_uuid SET DEFAULT gen_random_uuid();
ALTER TABLE lists        ALTER COLUMN client_uuid SET DEFAULT gen_random_uuid();
ALTER TABLE note_folders ALTER COLUMN client_uuid SET DEFAULT gen_random_uuid();

ALTER TABLE notes        ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP DEFAULT NULL;
ALTER TABLE lists        ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP DEFAULT NULL;
ALTER TABLE note_folders ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP DEFAULT NULL;

ALTER TABLE lists        ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE note_folders ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP;

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

-- =============================================================================
-- 2026-05-03: folder_client_uuid for note->folder linking by UUID (#14)
-- =============================================================================
-- iOS can create a folder offline AND a note inside that folder offline.
-- Both rows arrive at the server in a single sync upsert batch. The note
-- needs to reference the folder by something stable across the network,
-- and the folder's integer id only exists after the server has persisted
-- the folder. folder_client_uuid is the canonical link going forward;
-- folder_id is kept in sync via the sync.js upsert handler so legacy
-- callers that read folder_id keep working.

ALTER TABLE notes ADD COLUMN IF NOT EXISTS folder_client_uuid UUID;

-- Backfill from existing folder_id by joining note_folders.client_uuid.
UPDATE notes n
SET folder_client_uuid = f.client_uuid
FROM note_folders f
WHERE n.folder_id = f.id AND n.folder_client_uuid IS NULL;

CREATE INDEX IF NOT EXISTS notes_folder_client_uuid_idx ON notes (folder_client_uuid);

-- FK only after backfill is safe to add. Wrap in DO so re-runs are idempotent.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'notes_folder_client_uuid_fkey'
    ) THEN
        ALTER TABLE notes
        ADD CONSTRAINT notes_folder_client_uuid_fkey
        FOREIGN KEY (folder_client_uuid)
        REFERENCES note_folders(client_uuid) ON DELETE CASCADE;
    END IF;
END $$;
