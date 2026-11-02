# AgriPulse

Sentinel-2 NDVI field health analytics:
field boundary → STAC search → cloud-masked NDVI + zonal stats + stress zones → PostGIS → map and trend chart,
refreshed nightly by a durable job queue.

## Run

```bash
docker compose up --build
```

- Dashboard: http://localhost:8000 (link a field directly with `#field=<id>`)
- API docs: http://localhost:8000/docs
- Tile server (TiTiler): http://localhost:8001
- PostGIS: localhost:5433 (set `DB_PORT` to change), user/password/db `agripulse`

Draw a field on the map, save it, then click **Fetch last 90 days**. The job runs in the `worker` service.

Process a field from the CLI instead (runs inline, bypassing the queue):

```bash
docker compose exec api python -m app.pipeline <field_id> [days_back]
```

Trigger the nightly refresh now:

```bash
docker compose exec worker python -c "from app.tasks import queue, nightly_refresh
with queue.open(): nightly_refresh.defer(timestamp=0)"
```

Tests (synthetic rasters, no network):

```bash
docker compose run --rm --no-deps api pytest -q
```

### Upgrading an existing database

`db/init/*.sql` only runs on a fresh volume. To apply a newer schema file to a running DB (all are idempotent):

```bash
docker compose exec -T db psql -U agripulse -d agripulse < db/init/002_phase2.sql
```

Then reprocess fields with `{"force": true}` to fill the new columns. The worker creates the Procrastinate queue tables itself on first start.

## Layout

| Path | What |
|---|---|
| `db/init/` | PostGIS schema (`001`) and Phase 2 columns (`002`) |
| `backend/app/ndvi.py` | NDVI, SCL cloud mask, zonal stats, `StressRule`, stress-zone polygons, COG writer |
| `backend/app/stac.py` | Earth Search STAC (Sentinel-2 L2A COGs on AWS) |
| `backend/app/pipeline.py` | Per-field job: search → parallel scene reads → best pass per date → DB |
| `backend/app/tasks.py` | Procrastinate queue: `process_field` task, nightly `nightly_refresh` periodic task |
| `backend/app/worker.py` | Worker entrypoint (`python -m app.worker`) |
| `backend/app/main.py` | FastAPI (`/api/...`) and static dashboard |
| `web/index.html` | MapLibre dashboard: draw fields, trend chart, time slider, NDVI overlay, stress targets |

## How the pipeline works

1. Search Earth Search for L2A scenes intersecting the field (scene cloud cover < 60%).
   Dates already stored are skipped, so reruns only process new passes.
2. Per scene, read **only the field's bounding box** from the remote COGs (B04, B08, SCL) with HTTP range requests.
3. Reproject the boundary to the scene's UTM CRS, shrink it 10 m to drop edge pixels.
4. Convert DNs to reflectance. `raster:bands` lists offset −0.1 (baseline ≥ 04.00), but Earth Search has already
   removed it from the pixels when `earthsearch:boa_offset_applied` is true, so it's applied only when that flag is absent.
   Pixels with reflectance ≤ 0 are dropped.
5. Mask SCL classes 0, 1, 3, 8, 9, 10, 11 (nodata, saturated, shadow, clouds, cirrus, snow).
6. Skip the pass if under 70% of the field is valid. Otherwise compute min/mean/median/max/std.
7. Pick the pass's stress threshold (below), polygonize stressed pixels into zones ≥ 500 m²;
   `ST_PointOnSurface` of each zone becomes the scouting target.
8. Write a per-field NDVI COG, served as colored XYZ tiles by TiTiler.

### Stress detection

Set with `STRESS_MODE`:

- **`relative`** (default): a pixel is stressed when it is more than 20% below the field's median
  (`STRESS_RELATIVE_DROP`). This adapts to crop and growth stage, so it highlights within-field variability, which is what scouts act on.
- **`absolute`**: below a fixed per-crop threshold (`STRESS_CROP_THRESHOLDS`, fallback `STRESS_DEFAULT_THRESHOLD`).
  The defaults are starting points; tune them per region.

In both modes, nothing is flagged when the field median is below 0.25 (`STRESS_MIN_CANOPY_NDVI`): bare soil,
emergence or post-harvest has no canopy to scout. The threshold used is stored per pass (`NULL` = not evaluated).

Relative mode assumes one crop per boundary. A polygon spanning several parcels flags the weaker parcels as a whole.

### Alerts

`GET /api/fields/{id}/stats` adds `mean_change` (vs the previous pass) and `alert` when mean NDVI drops by at least
0.1 (`ALERT_MEAN_DROP`). The chart marks alerts with a red point and a `▼` label.

### Jobs

- `POST /api/fields/{id}/process` queues a job in Postgres (Procrastinate). The `processing_jobs` table mirrors its status for the UI.
- Per field: at most one job **waiting** at a time (a second request while one is waiting gets `409`),
  and never two **running** at once (a request made while one runs is queued behind it).
- Failed jobs retry 3 times, 2 minutes apart, which covers STAC/S3 outages.
- `nightly_refresh` runs at 04:00 UTC (`NIGHTLY_CRON`), queueing every field for the last 10 days (`NIGHTLY_LOOKBACK_DAYS`)
  to catch scenes published late. Already-stored dates are skipped, so a run with nothing new takes a couple of seconds.

## Known limitations / next steps

- No auth yet: everything belongs to the seeded default organization.
- A field split across two MGRS tiles on the same date isn't mosaicked. The more complete tile wins, and if neither covers 70% the pass is skipped.
- Alerts only show in the dashboard. Next: push/email notifications.
- Next indices: NDRE (B05, nitrogen) and NDMI (B8A/B11, water stress).
- PDF field report.
