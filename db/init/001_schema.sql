CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Single default org until auth lands; the API uses this id (DEFAULT_ORG_ID).
INSERT INTO organizations (id, name) VALUES ('00000000-0000-0000-0000-000000000001', 'Default');

CREATE TABLE farm_fields (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    field_name VARCHAR(100) NOT NULL,
    crop_type VARCHAR(50) NOT NULL,
    boundary GEOMETRY(MultiPolygon, 4326) NOT NULL CHECK (ST_IsValid(boundary)),
    area_hectares DOUBLE PRECISION GENERATED ALWAYS AS (
        ST_Area(boundary::geography) / 10000.0
    ) STORED,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_farm_fields_boundary ON farm_fields USING GIST (boundary);
CREATE INDEX idx_farm_fields_org ON farm_fields (org_id);

-- One row per field per cloud-free satellite pass.
CREATE TABLE ndvi_zonal_stats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    field_id UUID NOT NULL REFERENCES farm_fields(id) ON DELETE CASCADE,
    acquisition_date DATE NOT NULL,
    scene_id TEXT NOT NULL,
    min_ndvi NUMERIC(4, 3) NOT NULL,
    mean_ndvi NUMERIC(4, 3) NOT NULL,
    max_ndvi NUMERIC(4, 3) NOT NULL,
    std_ndvi NUMERIC(4, 3) NOT NULL,
    valid_fraction REAL NOT NULL,           -- cloud-free share of the field
    stressed_area_sqm DOUBLE PRECISION NOT NULL DEFAULT 0,
    raster_path TEXT NOT NULL,              -- per-field NDVI COG, served via TiTiler
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE (field_id, acquisition_date)
);

-- Contiguous low-NDVI areas; `target` is where scouts navigate to.
CREATE TABLE stress_zones (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    stats_id UUID NOT NULL REFERENCES ndvi_zonal_stats(id) ON DELETE CASCADE,
    zone GEOMETRY(MultiPolygon, 4326) NOT NULL,
    target GEOMETRY(Point, 4326) NOT NULL,  -- ST_PointOnSurface: always inside the zone
    mean_ndvi NUMERIC(4, 3) NOT NULL,
    area_sqm DOUBLE PRECISION NOT NULL
);

CREATE INDEX idx_stress_zones_stats ON stress_zones (stats_id);
CREATE INDEX idx_stress_zones_zone ON stress_zones USING GIST (zone);

-- Ids are generated on the device so offline sync can retry safely.
CREATE TABLE scouting_notes (
    id UUID PRIMARY KEY,
    field_id UUID NOT NULL REFERENCES farm_fields(id) ON DELETE CASCADE,
    zone_id UUID REFERENCES stress_zones(id) ON DELETE SET NULL,
    location GEOMETRY(Point, 4326) NOT NULL,
    category TEXT NOT NULL,
    note TEXT,
    observed_at TIMESTAMPTZ NOT NULL,
    synced_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE processing_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    field_id UUID NOT NULL REFERENCES farm_fields(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'done', 'failed')),
    message TEXT,
    passes_stored INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT now(),
    finished_at TIMESTAMPTZ
);
