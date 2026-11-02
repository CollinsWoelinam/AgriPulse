import json
import os
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Literal
from uuid import UUID

import psycopg
from fastapi import APIRouter, FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator

from app.auth import CurrentUser, Manager, User, authenticate, issue_token
from app.config import settings
from app.db import pool
from app.tasks import enqueue_field, queue
from app.tiles import mbtiles_for, public_tile_url

WEB_DIR = Path(__file__).resolve().parent.parent / "web"


@asynccontextmanager
async def lifespan(_: FastAPI):
    pool.open()
    queue.open()  # defer-only: jobs run in the separate worker service
    yield
    queue.close()
    pool.close()


app = FastAPI(title="AgriPulse API", lifespan=lifespan)
api = APIRouter(prefix="/api")


class LoginRequest(BaseModel):
    email: str
    password: str


class FieldCreate(BaseModel):
    field_name: str = Field(max_length=100)
    crop_type: str = Field(max_length=50)
    boundary: dict

    @field_validator("boundary")
    @classmethod
    def polygonal(cls, v: dict) -> dict:
        if v.get("type") not in ("Polygon", "MultiPolygon"):
            raise ValueError("boundary must be a GeoJSON Polygon or MultiPolygon")
        return v


class ProcessRequest(BaseModel):
    start: date | None = None
    end: date | None = None
    force: bool = False


NoteCategory = Literal[
    "pest_infestation", "disease", "nitrogen_deficiency", "irrigation_failure",
    "weeds", "weather_damage", "no_issue", "other",
]


class NoteIn(BaseModel):
    field_id: UUID
    zone_id: UUID | None = None
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    accuracy_m: float | None = Field(default=None, ge=0)
    category: NoteCategory
    note: str = Field(default="", max_length=2000)
    observed_at: datetime


PHOTO_TYPES = {"image/jpeg": "jpg", "image/png": "png", "image/heic": "heic", "image/webp": "webp"}

FIELD_COLUMNS = """
    f.id, f.field_name, f.crop_type, round(f.area_hectares::numeric, 2)::float AS area_hectares,
    ST_AsGeoJSON(f.boundary)::json AS boundary, f.created_at
"""


def _user_json(user: User) -> dict:
    return {"id": user.id, "email": user.email, "display_name": user.display_name, "role": user.role}


@api.get("/health")
def health():
    with pool.connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


@api.post("/auth/login")
def login(body: LoginRequest):
    user = authenticate(body.email, body.password)
    if user is None:
        raise HTTPException(401, "wrong email or password")
    return {"token": issue_token(user), "user": _user_json(user)}


@api.get("/me")
def me(user: CurrentUser):
    return _user_json(user)


# ---- Fields ----

def _get_field(conn, field_id: UUID, user: User) -> dict:
    row = conn.execute(
        f"SELECT {FIELD_COLUMNS} FROM farm_fields f WHERE f.id = %s AND f.org_id = %s", (field_id, user.org_id)
    ).fetchone()
    if row is None:
        raise HTTPException(404, "field not found")
    return row


@api.post("/fields", status_code=201)
def create_field(body: FieldCreate, user: Manager):
    try:
        with pool.connection() as conn:
            return conn.execute(
                f"""
                INSERT INTO farm_fields AS f (org_id, field_name, crop_type, boundary)
                VALUES (%s, %s, %s, ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(%s), 4326)))
                RETURNING {FIELD_COLUMNS}
                """,
                (user.org_id, body.field_name, body.crop_type, json.dumps(body.boundary)),
            ).fetchone()
    except (psycopg.errors.CheckViolation, psycopg.errors.InternalError) as exc:
        raise HTTPException(422, f"invalid boundary geometry: {exc.diag.message_primary}")


@api.get("/fields")
def list_fields(user: CurrentUser):
    """Fields with a summary of their latest pass (null if never processed)."""
    with pool.connection() as conn:
        return conn.execute(
            f"""
            SELECT {FIELD_COLUMNS},
                   CASE WHEN s.id IS NULL THEN NULL ELSE json_build_object(
                       'id', s.id, 'acquisition_date', s.acquisition_date, 'mean_ndvi', s.mean_ndvi::float,
                       'stressed_pct', round((100 * s.stressed_area_sqm / (f.area_hectares * 10000))::numeric, 1)::float,
                       'stress_zone_count', (SELECT count(*) FROM stress_zones z WHERE z.stats_id = s.id))
                   END AS latest_pass
            FROM farm_fields f
            LEFT JOIN LATERAL (
                SELECT * FROM ndvi_zonal_stats WHERE field_id = f.id ORDER BY acquisition_date DESC LIMIT 1
            ) s ON true
            WHERE f.org_id = %s ORDER BY f.created_at DESC
            """,
            (user.org_id,),
        ).fetchall()


@api.get("/fields/{field_id}")
def get_field(field_id: UUID, user: CurrentUser):
    with pool.connection() as conn:
        return _get_field(conn, field_id, user)


@api.delete("/fields/{field_id}", status_code=204)
def delete_field(field_id: UUID, user: Manager):
    with pool.connection() as conn:
        conn.execute("DELETE FROM farm_fields WHERE id = %s AND org_id = %s", (field_id, user.org_id))


@api.post("/fields/{field_id}/process", status_code=202)
def process_field(field_id: UUID, body: ProcessRequest, user: Manager):
    end = body.end or date.today()
    start = body.start or end - timedelta(days=90)
    with pool.connection() as conn:
        _get_field(conn, field_id, user)
    job = enqueue_field(str(field_id), start, end, body.force)
    if job is None:
        raise HTTPException(409, "this field already has a job queued")
    return job


@api.get("/jobs/{job_id}")
def get_job(job_id: UUID, user: CurrentUser):
    with pool.connection() as conn:
        row = conn.execute(
            "SELECT j.* FROM processing_jobs j JOIN farm_fields f ON f.id = j.field_id WHERE j.id = %s AND f.org_id = %s",
            (job_id, user.org_id),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "job not found")
    return row


# ---- NDVI passes and stress zones ----

def _stats_rows(conn, field: dict) -> list[dict]:
    rows = conn.execute(
        """
        SELECT s.id, s.acquisition_date, s.scene_id, s.min_ndvi::float, s.mean_ndvi::float,
               s.median_ndvi::float, s.max_ndvi::float, s.std_ndvi::float, s.valid_fraction,
               s.stress_threshold::float, s.stressed_area_sqm,
               s.raster_path, count(z.id) AS stress_zone_count
        FROM ndvi_zonal_stats s LEFT JOIN stress_zones z ON z.stats_id = s.id
        WHERE s.field_id = %s
        GROUP BY s.id ORDER BY s.acquisition_date
        """,
        (field["id"],),
    ).fetchall()
    field_sqm = field["area_hectares"] * 10000
    prev = None
    for r in rows:
        r["tile_url"] = public_tile_url(r.pop("raster_path"))
        r["stressed_pct"] = round(100 * r["stressed_area_sqm"] / field_sqm, 1) if field_sqm else 0.0
        r["mean_change"] = None if prev is None else round(r["mean_ndvi"] - prev, 3)
        r["alert"] = r["mean_change"] is not None and r["mean_change"] <= -settings.alert_mean_drop
        prev = r["mean_ndvi"]
    return rows


def _zones(conn, stats_id) -> dict:
    rows = conn.execute(
        """
        SELECT id, mean_ndvi::float, area_sqm, ST_AsGeoJSON(zone)::json AS geometry,
               ST_AsGeoJSON(target)::json AS target
        FROM stress_zones WHERE stats_id = %s ORDER BY mean_ndvi
        """,
        (stats_id,),
    ).fetchall()
    return {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature",
                "id": str(r["id"]),
                "geometry": r["geometry"],
                "properties": {"mean_ndvi": r["mean_ndvi"], "area_sqm": r["area_sqm"], "target": r["target"]},
            }
            for r in rows
        ],
    }


def _get_stats(conn, stats_id: UUID, user: User) -> dict:
    row = conn.execute(
        """
        SELECT s.id, s.field_id, s.acquisition_date, s.raster_path, f.field_name,
               ST_XMin(f.boundary) AS west, ST_YMin(f.boundary) AS south,
               ST_XMax(f.boundary) AS east, ST_YMax(f.boundary) AS north
        FROM ndvi_zonal_stats s JOIN farm_fields f ON f.id = s.field_id
        WHERE s.id = %s AND f.org_id = %s
        """,
        (stats_id, user.org_id),
    ).fetchone()
    if row is None:
        raise HTTPException(404, "pass not found")
    return row


@api.get("/fields/{field_id}/stats")
def field_stats(field_id: UUID, user: CurrentUser):
    """NDVI time series for the field, oldest first, with a tile URL per pass.

    `mean_change` is the difference from the previous pass; `alert` flags drops of at least
    ALERT_MEAN_DROP. `stressed_pct` is relative to the whole field area.
    """
    with pool.connection() as conn:
        return _stats_rows(conn, _get_field(conn, field_id, user))


@api.get("/stats/{stats_id}/zones")
def stress_zones(stats_id: UUID, user: CurrentUser):
    """Stress zones as a GeoJSON FeatureCollection; `target` is the scouting navigation point."""
    with pool.connection() as conn:
        _get_stats(conn, stats_id, user)
        return _zones(conn, stats_id)


@api.get("/fields/{field_id}/scouting")
def scouting_package(field_id: UUID, user: CurrentUser):
    """Everything the scouting app caches for offline use: field, latest pass, its zones (worst first)."""
    with pool.connection() as conn:
        field = _get_field(conn, field_id, user)
        passes = _stats_rows(conn, field)
        latest = passes[-1] if passes else None
        zones = _zones(conn, latest["id"]) if latest else {"type": "FeatureCollection", "features": []}
    return {
        "field": field,
        "pass": latest,
        "zones": zones,
        "mbtiles_url": f"/api/stats/{latest['id']}/mbtiles" if latest else None,
    }


@api.get("/stats/{stats_id}/mbtiles")
def ndvi_mbtiles(stats_id: UUID, user: CurrentUser):
    """Pre-rendered NDVI tiles for one pass, for offline maps."""
    with pool.connection() as conn:
        s = _get_stats(conn, stats_id, user)
    path = mbtiles_for(
        s["raster_path"], (s["west"], s["south"], s["east"], s["north"]),
        f"{s['field_name']} NDVI {s['acquisition_date']}",
    )
    return FileResponse(path, media_type="application/vnd.mapbox-vector-tile+sqlite",
                        filename=f"ndvi_{s['acquisition_date']}.mbtiles")


# ---- Scouting notes and photos ----

def _notes(conn, where: str, params: tuple) -> list[dict]:
    return conn.execute(
        f"""
        SELECT n.id, n.field_id, n.zone_id, ST_Y(n.location) AS lat, ST_X(n.location) AS lon, n.accuracy_m,
               n.category, n.note, n.observed_at, n.synced_at, u.display_name AS author,
               COALESCE((SELECT json_agg(p.id ORDER BY p.created_at) FROM note_photos p WHERE p.note_id = n.id),
                        '[]'::json) AS photo_ids
        FROM scouting_notes n LEFT JOIN users u ON u.id = n.author_id
        WHERE {where}
        ORDER BY n.observed_at DESC
        """,
        params,
    ).fetchall()


@api.put("/notes/{note_id}")
def put_note(note_id: UUID, body: NoteIn, user: CurrentUser):
    """Create a scouting note with a device-generated id. Re-sending the same id is a no-op."""
    with pool.connection() as conn:
        _get_field(conn, body.field_id, user)
        zone_id = body.zone_id
        if zone_id and not conn.execute(
            "SELECT 1 FROM stress_zones z JOIN ndvi_zonal_stats s ON s.id = z.stats_id WHERE z.id = %s AND s.field_id = %s",
            (zone_id, body.field_id),
        ).fetchone():
            zone_id = None  # zone replaced by a reprocess while the scout was offline: keep the note
        inserted = conn.execute(
            """
            INSERT INTO scouting_notes (id, field_id, zone_id, location, accuracy_m, category, note, observed_at, author_id)
            VALUES (%s, %s, %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326), %s, %s, %s, %s, %s)
            ON CONFLICT (id) DO NOTHING RETURNING id
            """,
            (note_id, body.field_id, zone_id, body.lon, body.lat, body.accuracy_m, body.category,
             body.note, body.observed_at, user.id),
        ).fetchone()
        if not inserted:
            owner = conn.execute("SELECT author_id::text FROM scouting_notes WHERE id = %s", (note_id,)).fetchone()
            if owner["author_id"] != user.id:
                raise HTTPException(409, "note id already used")
        return _notes(conn, "n.id = %s", (note_id,))[0]


def _check_note_access(conn, note_id: UUID, user: User) -> None:
    row = conn.execute(
        """
        SELECT n.author_id::text FROM scouting_notes n JOIN farm_fields f ON f.id = n.field_id
        WHERE n.id = %s AND f.org_id = %s
        """,
        (note_id, user.org_id),
    ).fetchone()
    if row is None:
        raise HTTPException(404, "note not found")
    if row["author_id"] != user.id and not user.is_manager:
        raise HTTPException(403, "only the author can add photos")


def _store_photo(note_id: UUID, photo_id: UUID, user: User, content_type: str, data: bytes) -> dict:
    with pool.connection() as conn:
        _check_note_access(conn, note_id, user)
        existing = conn.execute("SELECT note_id FROM note_photos WHERE id = %s", (photo_id,)).fetchone()
        if existing:
            if existing["note_id"] != note_id:
                raise HTTPException(409, "photo id already used")
            return {"id": photo_id, "note_id": note_id}
        folder = os.path.join(settings.photo_dir, user.org_id, str(note_id))
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, f"{photo_id}.{PHOTO_TYPES[content_type]}")
        with open(path, "wb") as f:
            f.write(data)
        conn.execute(  # ON CONFLICT: a concurrent retry of the same upload already wrote it
            "INSERT INTO note_photos (id, note_id, path, content_type, size_bytes) VALUES (%s, %s, %s, %s, %s)"
            " ON CONFLICT (id) DO NOTHING",
            (photo_id, note_id, path, content_type, len(data)),
        )
    return {"id": photo_id, "note_id": note_id}


@api.put("/notes/{note_id}/photos/{photo_id}", status_code=201)
async def put_photo(note_id: UUID, photo_id: UUID, request: Request, user: CurrentUser):
    """Upload one photo as the raw request body (Content-Type: image/*). Idempotent per photo id."""
    content_type = request.headers.get("content-type", "").split(";")[0].strip().lower()
    if content_type not in PHOTO_TYPES:
        raise HTTPException(415, f"photo must be one of {', '.join(PHOTO_TYPES)}")
    if int(request.headers.get("content-length") or 0) > settings.max_photo_bytes:
        raise HTTPException(413, "photo too large")
    data = await request.body()
    if not data or len(data) > settings.max_photo_bytes:
        raise HTTPException(413 if data else 400, "photo too large" if data else "empty photo")
    return await run_in_threadpool(_store_photo, note_id, photo_id, user, content_type, data)


@api.get("/photos/{photo_id}")
def get_photo(photo_id: UUID, user: CurrentUser):
    with pool.connection() as conn:
        row = conn.execute(
            """
            SELECT p.path, p.content_type FROM note_photos p
            JOIN scouting_notes n ON n.id = p.note_id JOIN farm_fields f ON f.id = n.field_id
            WHERE p.id = %s AND f.org_id = %s
            """,
            (photo_id, user.org_id),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "photo not found")
    return FileResponse(row["path"], media_type=row["content_type"])


@api.get("/fields/{field_id}/notes")
def field_notes(field_id: UUID, user: CurrentUser):
    with pool.connection() as conn:
        _get_field(conn, field_id, user)
        return _notes(conn, "n.field_id = %s", (field_id,))


app.include_router(api)
if WEB_DIR.is_dir():
    app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")
