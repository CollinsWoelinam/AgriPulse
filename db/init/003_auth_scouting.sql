-- Phase 3: users/roles and scouting photos. Idempotent, so it can be applied to an existing DB.

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT NOT NULL UNIQUE CHECK (email = lower(email)),
    display_name TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- manager: manage fields and processing; scout: read fields, log observations.
CREATE TABLE IF NOT EXISTS memberships (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('manager', 'scout')),
    PRIMARY KEY (user_id, org_id)
);

ALTER TABLE scouting_notes ADD COLUMN IF NOT EXISTS author_id UUID REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE scouting_notes ADD COLUMN IF NOT EXISTS accuracy_m REAL;
CREATE INDEX IF NOT EXISTS idx_scouting_notes_field ON scouting_notes (field_id, observed_at DESC);

-- Ids come from the device, so a retried upload is a no-op.
CREATE TABLE IF NOT EXISTS note_photos (
    id UUID PRIMARY KEY,
    note_id UUID NOT NULL REFERENCES scouting_notes(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    content_type TEXT NOT NULL,
    size_bytes INT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_note_photos_note ON note_photos (note_id);
