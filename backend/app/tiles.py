"""NDVI tile URLs and offline MBTiles packages for the scouting app."""

import math
import os
import sqlite3
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote

from app.config import settings

NDVI_STYLE = "rescale=-0.2,0.9&colormap_name=rdylgn"


def tile_path(raster_path: str) -> str:
    return f"/cog/tiles/WebMercatorQuad/{{z}}/{{x}}/{{y}}.png?url={quote(raster_path)}&{NDVI_STYLE}"


def public_tile_url(raster_path: str) -> str:
    return settings.tiler_public_url + tile_path(raster_path)


def public_preview_url(raster_path: str) -> str:
    """The whole field raster as one small PNG (native 10 m pixels), for thumbnails."""
    return f"{settings.tiler_public_url}/cog/preview.png?url={quote(raster_path)}&{NDVI_STYLE}&max_size=256"


def _tile_xy(lon: float, lat: float, z: int) -> tuple[int, int]:
    n = 2**z
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return min(max(x, 0), n - 1), min(max(y, 0), n - 1)


def tiles_for_bounds(bounds: tuple[float, float, float, float], zmin: int, zmax: int) -> list[tuple[int, int, int]]:
    west, south, east, north = bounds
    out = []
    for z in range(zmin, zmax + 1):
        x0, y0 = _tile_xy(west, north, z)
        x1, y1 = _tile_xy(east, south, z)
        out += [(z, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
    return out


def _fetch(url: str) -> bytes | None:
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            return resp.read() if resp.status == 200 else None
    except urllib.error.HTTPError:
        return None  # TiTiler answers 404 for tiles with no data


def mbtiles_for(raster_path: str, bounds: tuple[float, float, float, float], name: str) -> str:
    """Build (or reuse) an MBTiles package next to the raster. Rebuilt when the raster is newer."""
    out = raster_path.removesuffix(".tif") + ".mbtiles"
    if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(raster_path):
        return out

    zmin, zmax = settings.offline_zooms
    tiles = tiles_for_bounds(bounds, zmin, zmax)
    while zmax > zmin and len(tiles) > settings.offline_max_tiles:  # big fields: drop the deepest zoom
        zmax -= 1
        tiles = tiles_for_bounds(bounds, zmin, zmax)

    template = settings.tiler_internal_url + tile_path(raster_path)
    with ThreadPoolExecutor(max_workers=8) as ex:
        images = ex.map(lambda t: _fetch(template.format(z=t[0], x=t[1], y=t[2])), tiles)
        results = list(zip(tiles, images))

    tmp = out + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.executescript("""
        CREATE TABLE metadata (name TEXT, value TEXT);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
        CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
    """)
    db.executemany("INSERT INTO metadata VALUES (?, ?)", [
        ("name", name), ("format", "png"), ("type", "overlay"), ("version", "1"),
        ("bounds", ",".join(f"{v:.6f}" for v in bounds)), ("minzoom", str(zmin)), ("maxzoom", str(zmax)),
    ])
    # MBTiles rows are TMS (y flipped).
    db.executemany("INSERT INTO tiles VALUES (?, ?, ?, ?)", [
        (z, x, 2**z - 1 - y, data) for (z, x, y), data in results if data
    ])
    db.commit()
    db.close()
    os.replace(tmp, out)
    return out
