"""Field processing job: STAC search -> per-scene NDVI -> best pass per date -> PostGIS."""

import json
import logging
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta

from pystac import Item

from app.config import settings
from app.db import pool
from app.ndvi import FieldNdvi, StressRule, compute_field_ndvi, extract_stress_zones, write_cog
from app.stac import band_scaling, search_scenes

log = logging.getLogger(__name__)


def _process_scene(item: Item, boundary: dict, stress: StressRule) -> tuple[Item, FieldNdvi | None]:
    scale, offset = band_scaling(item, item.assets["red"])
    try:
        result = compute_field_ndvi(
            item.assets["red"].href,
            item.assets["nir"].href,
            item.assets["scl"].href,
            boundary,
            scale=scale,
            offset=offset,
            stress=stress,
            min_valid_fraction=settings.min_valid_fraction,
            edge_buffer_m=settings.edge_buffer_m,
        )
    except Exception:
        log.exception("scene %s failed", item.id)
        result = None
    return item, result


def _store_pass(field_id: str, day: date, item: Item, result: FieldNdvi) -> None:
    field_dir = os.path.join(settings.raster_dir, field_id)
    os.makedirs(field_dir, exist_ok=True)
    raster_path = os.path.join(field_dir, f"{day.isoformat()}_ndvi.tif")
    write_cog(raster_path, result)
    zones = extract_stress_zones(result, settings.min_zone_sqm)

    with pool.connection() as conn:
        stats_id = conn.execute(
            """
            INSERT INTO ndvi_zonal_stats (field_id, acquisition_date, scene_id, min_ndvi, mean_ndvi,
                median_ndvi, max_ndvi, std_ndvi, valid_fraction, stress_threshold, stressed_area_sqm, raster_path)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (field_id, acquisition_date) DO UPDATE SET
                scene_id = EXCLUDED.scene_id, min_ndvi = EXCLUDED.min_ndvi, mean_ndvi = EXCLUDED.mean_ndvi,
                median_ndvi = EXCLUDED.median_ndvi, max_ndvi = EXCLUDED.max_ndvi, std_ndvi = EXCLUDED.std_ndvi,
                valid_fraction = EXCLUDED.valid_fraction, stress_threshold = EXCLUDED.stress_threshold,
                stressed_area_sqm = EXCLUDED.stressed_area_sqm, raster_path = EXCLUDED.raster_path,
                created_at = now()
            RETURNING id
            """,
            (field_id, day, item.id, result.min_ndvi, result.mean_ndvi, result.median_ndvi, result.max_ndvi,
             result.std_ndvi, result.valid_fraction, result.stress_threshold, result.stressed_area_sqm,
             raster_path),
        ).fetchone()["id"]
        conn.execute("DELETE FROM stress_zones WHERE stats_id = %s", (stats_id,))
        for z in zones:
            conn.execute(
                """
                INSERT INTO stress_zones (stats_id, zone, target, mean_ndvi, area_sqm)
                SELECT %s, g, ST_PointOnSurface(g), %s, %s
                FROM (SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid(
                    ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)), 3)) AS g) s
                """,
                (stats_id, z["mean_ndvi"], z["area_sqm"], json.dumps(z["geometry"])),
            )


def process_field(field_id: str, start: date, end: date, force: bool = False) -> int:
    """Process all new passes for a field in [start, end]. Returns the number of passes stored."""
    with pool.connection() as conn:
        row = conn.execute(
            "SELECT crop_type, ST_AsGeoJSON(boundary)::json AS boundary FROM farm_fields WHERE id = %s",
            (field_id,),
        ).fetchone()
        if row is None:
            raise ValueError(f"field {field_id} not found")
        done_dates = {
            r["acquisition_date"]
            for r in conn.execute(
                "SELECT acquisition_date FROM ndvi_zonal_stats WHERE field_id = %s", (field_id,)
            ).fetchall()
        }
    boundary = row["boundary"]
    stress = settings.stress_rule(row["crop_type"])

    items = [i for i in search_scenes(boundary, start, end) if force or i.datetime.date() not in done_dates]
    log.info("field %s: %d candidate scenes", field_id, len(items))

    # Scenes are I/O-bound HTTP range reads; rasterio releases the GIL.
    best: dict[date, tuple[Item, FieldNdvi]] = {}
    with ThreadPoolExecutor(max_workers=settings.scene_workers) as ex:
        for item, result in ex.map(lambda i: _process_scene(i, boundary, stress), items):
            if result is None:
                continue
            day = item.datetime.date()
            # Overlapping MGRS tiles give several items per date: keep the most complete one.
            if day not in best or result.valid_fraction > best[day][1].valid_fraction:
                best[day] = (item, result)

    for day, (item, result) in sorted(best.items()):
        _store_pass(field_id, day, item, result)
    return len(best)


def _finish_job(job_id: str, status: str, message: str | None, stored: int) -> None:
    with pool.connection() as conn:
        conn.execute(
            "UPDATE processing_jobs SET status = %s, message = %s, passes_stored = %s, finished_at = now() WHERE id = %s",
            (status, message, stored, job_id),
        )


def run_job(job_id: str, field_id: str, start: date, end: date, force: bool = False) -> None:
    """Run a processing job, mirroring its state into processing_jobs. Re-raises so the queue can retry."""
    with pool.connection() as conn:
        conn.execute("UPDATE processing_jobs SET status = 'running', message = NULL WHERE id = %s", (job_id,))
    try:
        stored = process_field(field_id, start, end, force)
    except Exception as exc:
        _finish_job(job_id, "failed", str(exc), 0)
        raise
    _finish_job(job_id, "done", None, stored)


if __name__ == "__main__":
    # python -m app.pipeline <field_id> [days_back]
    logging.basicConfig(level=logging.INFO)
    days = int(sys.argv[2]) if len(sys.argv) > 2 else 90
    pool.open()
    n = process_field(sys.argv[1], date.today() - timedelta(days=days), date.today())
    print(f"stored {n} passes")
