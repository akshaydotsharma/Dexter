-- Migration script to update todos table with new fields
-- Run this on existing databases to preserve data

-- Rename text column to title
ALTER TABLE todos RENAME COLUMN text TO title;

-- Add new columns
ALTER TABLE todos ADD COLUMN IF NOT EXISTS description TEXT;
ALTER TABLE todos ADD COLUMN IF NOT EXISTS due_date TIMESTAMP;
ALTER TABLE todos ADD COLUMN IF NOT EXISTS tag TEXT;
