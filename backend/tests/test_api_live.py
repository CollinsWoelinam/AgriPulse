"""Live API tests against a running stack (needs a processed field and the users below).

    docker compose exec -e AGRIPULSE_LIVE_URL=http://localhost:8000 api pytest -q tests/test_api_live.py

Users (create with `python -m app.auth add`): manager@example.com / scout@example.com in the default org,
outsider@example.com in another org; all with password "correct-horse".
"""

import json
import os
import sqlite3
import tempfile
import urllib.error
import urllib.request
import uuid
from datetime import UTC, datetime

import pytest

BASE = os.environ.get("AGRIPULSE_LIVE_URL")
pytestmark = pytest.mark.skipif(not BASE, reason="set AGRIPULSE_LIVE_URL to run live API tests")
PASSWORD = "correct-horse"


def call(method, path, token=None, body=None, raw=None, content_type=None):
    headers = {}
    data = None
    if body is not None:
        data, headers["Content-Type"] = json.dumps(body).encode(), "application/json"
    if raw is not None:
        data, headers["Content-Type"] = raw, content_type
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            payload = resp.read()
            ctype = resp.headers.get("content-type", "")
            return resp.status, json.loads(payload) if "json" in ctype else payload
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def login(email):
    status, body = call("POST", "/api/auth/login", body={"email": email, "password": PASSWORD})
    assert status == 200, body
    return body["token"]


@pytest.fixture(scope="module")
def manager():
    return login("manager@example.com")


@pytest.fixture(scope="module")
def scout():
    return login("scout@example.com")


@pytest.fixture(scope="module")
def field(scout):
    status, fields = call("GET", "/api/fields", scout)
    assert status == 200
    processed = [f for f in fields if f["latest_pass"]]
    assert processed, "needs at least one processed field"
    return processed[0]


def note_body(field, **kw):
    return {"field_id": field["id"], "lat": 52.5418, "lon": 5.603, "accuracy_m": 4.5,
            "category": "nitrogen_deficiency", "note": "yellowing lower leaves",
            "observed_at": datetime.now(UTC).isoformat(), **kw}


def test_login_rejects_bad_password():
    status, _ = call("POST", "/api/auth/login", body={"email": "scout@example.com", "password": "nope"})
    assert status == 401


def test_requires_token():
    assert call("GET", "/api/fields")[0] == 401
    assert call("GET", "/api/fields", "garbage")[0] == 401


def test_me(scout):
    status, me = call("GET", "/api/me", scout)
    assert status == 200 and me["role"] == "scout"


def test_scout_cannot_manage_fields(scout, field):
    boundary = {"type": "Polygon", "coordinates": [[[5.6, 52.54], [5.601, 52.54], [5.601, 52.541], [5.6, 52.54]]]}
    assert call("POST", "/api/fields", scout, {"field_name": "x", "crop_type": "x", "boundary": boundary})[0] == 403
    assert call("POST", f"/api/fields/{field['id']}/process", scout, {})[0] == 403
    assert call("DELETE", f"/api/fields/{field['id']}", scout)[0] == 403


def test_other_org_is_invisible(field):
    outsider = login("outsider@example.com")
    status, fields = call("GET", "/api/fields", outsider)
    assert status == 200 and all(f["id"] != field["id"] for f in fields)
    assert call("GET", f"/api/fields/{field['id']}", outsider)[0] == 404
    assert call("GET", f"/api/fields/{field['id']}/scouting", outsider)[0] == 404
    assert call("GET", f"/api/stats/{field['latest_pass']['id']}/zones", outsider)[0] == 404
    assert call("PUT", f"/api/notes/{uuid.uuid4()}", outsider, note_body(field))[0] == 404


def test_scouting_package(scout, field):
    status, pkg = call("GET", f"/api/fields/{field['id']}/scouting", scout)
    assert status == 200
    assert pkg["pass"]["id"] == field["latest_pass"]["id"]
    ndvi = [z["properties"]["mean_ndvi"] for z in pkg["zones"]["features"]]
    assert ndvi == sorted(ndvi)  # worst first
    assert all(z["properties"]["target"]["type"] == "Point" for z in pkg["zones"]["features"])


def test_mbtiles_package(scout, field):
    status, data = call("GET", f"/api/stats/{field['latest_pass']['id']}/mbtiles", scout)
    assert status == 200
    with tempfile.NamedTemporaryFile(suffix=".mbtiles") as f:
        f.write(data)
        f.flush()
        db = sqlite3.connect(f.name)
        meta = dict(db.execute("SELECT name, value FROM metadata"))
        count, zmin, zmax = db.execute("SELECT count(*), min(zoom_level), max(zoom_level) FROM tiles").fetchone()
        png = db.execute("SELECT tile_data FROM tiles LIMIT 1").fetchone()[0]
    assert meta["format"] == "png" and count > 0 and zmin == 12 and zmax == 17
    assert png[:8] == b"\x89PNG\r\n\x1a\n"


def test_note_put_is_idempotent(scout, field):
    note_id = str(uuid.uuid4())
    s1, n1 = call("PUT", f"/api/notes/{note_id}", scout, note_body(field))
    s2, n2 = call("PUT", f"/api/notes/{note_id}", scout, note_body(field, note="retried"))
    assert (s1, s2) == (200, 200)
    assert n1["id"] == n2["id"] == note_id
    assert n2["note"] == "yellowing lower leaves"  # first write wins; retries don't overwrite
    assert n1["author"] and n1["photo_ids"] == []


def test_note_with_stale_zone_is_kept(scout, field):
    status, note = call("PUT", f"/api/notes/{uuid.uuid4()}", scout, note_body(field, zone_id=str(uuid.uuid4())))
    assert status == 200 and note["zone_id"] is None


def test_note_validation(scout, field):
    assert call("PUT", f"/api/notes/{uuid.uuid4()}", scout, note_body(field, category="aliens"))[0] == 422
    assert call("PUT", f"/api/notes/{uuid.uuid4()}", scout, note_body(field, lat=123))[0] == 422


def test_other_user_cannot_reuse_note_id(scout, manager, field):
    note_id = str(uuid.uuid4())
    assert call("PUT", f"/api/notes/{note_id}", scout, note_body(field))[0] == 200
    assert call("PUT", f"/api/notes/{note_id}", manager, note_body(field))[0] == 409


def test_photo_upload(scout, manager, field):
    note_id, photo_id = str(uuid.uuid4()), str(uuid.uuid4())
    call("PUT", f"/api/notes/{note_id}", scout, note_body(field))
    jpeg = b"\xff\xd8\xff\xe0" + b"0" * 2048 + b"\xff\xd9"
    path = f"/api/notes/{note_id}/photos/{photo_id}"
    assert call("PUT", path, scout, raw=b"GIF89a", content_type="image/gif")[0] == 415
    assert call("PUT", path, scout, raw=jpeg, content_type="image/jpeg")[0] == 201
    assert call("PUT", path, scout, raw=jpeg, content_type="image/jpeg")[0] == 201  # retry is a no-op

    status, notes = call("GET", f"/api/fields/{field['id']}/notes", manager)
    assert status == 200
    note = next(n for n in notes if n["id"] == note_id)
    assert note["photo_ids"] == [photo_id]
    status, data = call("GET", f"/api/photos/{photo_id}", manager)
    assert status == 200 and data == jpeg
    assert call("GET", f"/api/photos/{photo_id}", login("outsider@example.com"))[0] == 404


def test_field_list_summary(scout, field):
    p = field["latest_pass"]
    assert len(p["series"]) >= 2 and p["series"][-1] == pytest.approx(p["mean_ndvi"], abs=1e-3)
    assert p["mean_change"] == pytest.approx(p["series"][-1] - p["series"][-2], abs=1e-3)
    assert isinstance(p["alert"], bool)
    assert 0 <= p["scouted_zone_count"] <= p["stress_zone_count"]


def test_zone_note_count_and_org_feed(scout, field):
    _, pkg = call("GET", f"/api/fields/{field['id']}/scouting", scout)
    zone = pkg["zones"]["features"][0]
    before = zone["properties"]["note_count"]
    note_id = str(uuid.uuid4())
    call("PUT", f"/api/notes/{note_id}", scout, note_body(field, zone_id=zone["id"]))
    _, pkg = call("GET", f"/api/fields/{field['id']}/scouting", scout)
    assert pkg["zones"]["features"][0]["properties"]["note_count"] == before + 1

    status, feed = call("GET", "/api/notes?limit=5", scout)
    assert status == 200 and len(feed) <= 5
    assert feed[0]["id"] == note_id and feed[0]["field_name"] == field["field_name"]
    _, outsider_feed = call("GET", "/api/notes", login("outsider@example.com"))
    assert all(n["field_id"] != field["id"] for n in outsider_feed)
