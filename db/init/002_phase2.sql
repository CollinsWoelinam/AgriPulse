-- Phase 2: adaptive stress thresholds. Idempotent, so it can be applied to an existing DB.
ALTER TABLE ndvi_zonal_stats ADD COLUMN IF NOT EXISTS median_ndvi NUMERIC(4, 3);
-- Threshold used for this pass; NULL when the field had no canopy and stress wasn't evaluated.
ALTER TABLE ndvi_zonal_stats ADD COLUMN IF NOT EXISTS stress_threshold NUMERIC(4, 3);
