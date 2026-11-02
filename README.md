# AgriPulse

Sentinel-2 NDVI field health analytics:
field boundary → STAC search → cloud-masked NDVI + zonal stats + stress zones → PostGIS → map and trend chart,
refreshed nightly by a durable job queue. The **AgriPulse Scout** mobile app (`mobile/`) guides scouts to stress
targets and records geotagged observations offline.

## Run

```bash
docker compose up --build
```

- Dashboard: http://localhost:8000 (link a field directly with `#field=<id>`)
- API docs: http://localhost:8000/docs
- Tile server (TiTiler): http://localhost:8001
- PostGIS: localhost:5433 (set `DB_PORT` to change), user/password/db `agripulse`

Create users (there is no sign-up page). Managers draw and process fields; scouts view them and log observations:

```bash
docker compose exec api python -m app.auth add you@farm.com manager --name "Your Name"   # prompts for a password
docker compose exec api python -m app.auth add scout@farm.com scout --name "Field Scout"
```

Set `JWT_SECRET` (environment or `.env`) to a long random value anywhere other than your own machine.

Sign in as a manager, draw on the map, save it, then click **Fetch last 90 days**. The job runs in the `worker` service.

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

Live API tests (auth, org isolation, notes, photos, MBTiles) against the running stack. They need a processed field
and the users listed at the top of `backend/tests/test_api_live.py`:

```bash
docker compose exec -e AGRIPULSE_LIVE_URL=http://localhost:8000 api pytest -q tests/test_api_live.py
```

### Upgrading an existing database

`db/init/*.sql` only runs on a fresh volume. To apply a newer schema file to a running DB (all are idempotent):

```bash
for f in db/init/002_phase2.sql db/init/003_auth_scouting.sql; do
  docker compose exec -T db psql -U agripulse -d agripulse < $f
done
```

Then reprocess fields with `{"force": true}` to fill the new columns. The worker creates the Procrastinate queue tables itself on first start.

## Layout

| Path | What |
|---|---|
| `db/init/` | PostGIS schema (`001`), Phase 2 columns (`002`), users and scouting photos (`003`) |
| `backend/app/auth.py` | Argon2 passwords, JWT bearer tokens, `manager`/`scout` roles, user CLI |
| `backend/app/tiles.py` | NDVI tile URLs and offline MBTiles packages |
| `backend/app/ndvi.py` | NDVI, SCL cloud mask, zonal stats, `StressRule`, stress-zone polygons, COG writer |
| `backend/app/stac.py` | Earth Search STAC (Sentinel-2 L2A COGs on AWS) |
| `backend/app/pipeline.py` | Per-field job: search → parallel scene reads → best pass per date → DB |
| `backend/app/tasks.py` | Procrastinate queue: `process_field` task, nightly `nightly_refresh` periodic task |
| `backend/app/worker.py` | Worker entrypoint (`python -m app.worker`) |
| `backend/app/main.py` | FastAPI (`/api/...`) and static dashboard |
| `web/index.html` | MapLibre dashboard: sign-in, draw fields, trend chart, time slider, NDVI overlay, stress targets, scout notes |
| `mobile/` | Flutter scouting app (iOS and Android) |

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

## Scouting app (`mobile/`)

```bash
cd mobile
flutter run                       # simulator/emulator: server defaults to localhost:8000 (iOS) / 10.0.2.2:8000 (Android)
flutter test                      # unit tests: navigation math, declination, offline sync, MBTiles
./test_driver/run_ios.sh         # end-to-end on the booted iOS simulator, with screenshots in build/screenshots/
```

On a real phone, enter the server's LAN address under **Server** on the sign-in screen. Also set the API's
`TILER_PUBLIC_URL` to an address the phone can reach, because online NDVI tiles come straight from TiTiler.

- **Fields**: a *Scout next* card (the most stressed unscouted target, with distance), then each field's NDVI
  thumbnail, alert, mean NDVI, stressed share and scouted targets. The download button saves the field for offline
  use: boundary, stress zones, thumbnail and pre-rendered NDVI tiles (MBTiles, z12–17).
  Bottom tabs: **Fields**, **My notes** (everything logged on this phone) and **Outbox** (not uploaded yet).
- **Map**: satellite imagery (online only), NDVI overlay (offline when saved), stress zones, numbered targets
  (1 = most stressed; lime = next up, outlined = scouted by anyone), a dotted route to the next target, your
  position and your observations (amber = not uploaded yet).
- **Navigate**: distance, compass direction and an arrow that turns with the phone. iOS gives true heading.
  Android gives magnetic heading, which the app corrects with the World Magnetic Model 2025. Without a compass
  (e.g. simulators) the arrow is north-up. "Arrived" shows within 10 m or the GPS accuracy, whichever is larger.
  After logging an observation it moves on to the next open target.
- **Observations**: category, notes, photos, GPS position and accuracy. Saved to an on-device outbox first, then
  uploaded on save, every minute, and when the app returns to the foreground. Note and photo ids are generated on
  the phone and the server ignores repeats, so interrupted uploads simply retry. A note the server rejects stays
  on the phone with its error and doesn't block the rest.

Fonts (Manrope, JetBrains Mono, OFL) are bundled in `mobile/assets/fonts` so the app renders the same offline.

API used by the app: `POST /api/auth/login`, `GET /api/fields`, `GET /api/fields/{id}/scouting`,
`GET /api/stats/{id}/mbtiles`, `PUT /api/notes/{id}`, `PUT /api/notes/{id}/photos/{photo_id}` (raw image body).

## Known limitations / next steps

- No sign-up, password reset or refresh tokens. Tokens last 30 days (`TOKEN_TTL_DAYS`) so scouts can work offline.
  Add login rate limiting before exposing the API publicly.
- TiTiler tiles aren't behind auth. Raster paths contain unguessable field ids, but put the tiler behind the API
  (or signed URLs) for production.
- Photos are stored on a Docker volume. Use object storage (S3 with presigned uploads) in production.
- Satellite basemap imagery isn't available offline (licensing). Offline maps show NDVI, zones and targets on a plain background.
- The scouting app shows your own observations. Other scouts' notes are visible in the web dashboard.
- A field split across two MGRS tiles on the same date isn't mosaicked. The more complete tile wins, and if neither covers 70% the pass is skipped.
- Alerts only show in the dashboard. Next: push/email notifications.
- Next indices: NDRE (B05, nitrogen) and NDMI (B8A/B11, water stress).
- PDF field report.
