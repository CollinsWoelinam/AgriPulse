"""Synthetic Sentinel-2-like scene: healthy field with a stressed block and a cloud block."""

import numpy as np
import pytest
import rasterio
from rasterio.transform import from_origin
from rasterio.warp import transform_geom

from app.ndvi import StressRule, compute_field_ndvi, extract_stress_zones, write_cog

CRS = "EPSG:32631"
ORIGIN_X, ORIGIN_Y = 600000.0, 5800000.0
SIZE = 100  # 100 x 100 px at 10 m = 1 km square
SCALE, OFFSET = 0.0001, -0.1


def dn(reflectance):
    return np.round((np.asarray(reflectance) - OFFSET) / SCALE).astype("uint16")


def write(path, arr, res, dtype):
    with rasterio.open(
        path, "w", driver="GTiff", width=arr.shape[1], height=arr.shape[0], count=1, dtype=dtype,
        crs=CRS, transform=from_origin(ORIGIN_X, ORIGIN_Y, res, res), nodata=0,
    ) as dst:
        dst.write(arr, 1)


@pytest.fixture
def scene(tmp_path):
    red = np.full((SIZE, SIZE), 0.04)
    nir = np.full((SIZE, SIZE), 0.40)  # NDVI ~0.82
    red[20:40, 20:40], nir[20:40, 20:40] = 0.10, 0.15  # stressed block, NDVI 0.2
    scl = np.full((SIZE // 2, SIZE // 2), 4, dtype="uint8")  # 20 m grid, 4 = vegetation
    scl[30:40, 30:40] = 9  # cloud over 200x200 m (pixels 60-80 on the 10 m grid)

    paths = {k: str(tmp_path / f"{k}.tif") for k in ("red", "nir", "scl")}
    write(paths["red"], dn(red), 10, "uint16")
    write(paths["nir"], dn(nir), 10, "uint16")
    write(paths["scl"], scl, 20, "uint8")
    return paths


def field_4326(x0, y0, x1, y1):
    poly = {"type": "Polygon", "coordinates": [[
        [ORIGIN_X + x0, ORIGIN_Y - y0], [ORIGIN_X + x1, ORIGIN_Y - y0],
        [ORIGIN_X + x1, ORIGIN_Y - y1], [ORIGIN_X + x0, ORIGIN_Y - y1], [ORIGIN_X + x0, ORIGIN_Y - y0],
    ]]}
    return transform_geom(CRS, "EPSG:4326", poly)


def run(scene, geom, **kw):
    return compute_field_ndvi(scene["red"], scene["nir"], scene["scl"], geom, scale=SCALE, offset=OFFSET, **kw)


def test_stats_mask_clouds_and_count_stress(scene):
    result = run(scene, field_4326(0, 0, 1000, 1000), edge_buffer_m=0, min_valid_fraction=0.5)

    assert result is not None
    assert result.min_ndvi == pytest.approx(0.2, abs=0.01)
    assert result.max_ndvi == pytest.approx(0.818, abs=0.01)
    assert np.isnan(result.ndvi[70, 70])  # cloud pixel removed, not counted as stress
    assert result.valid_fraction == pytest.approx(1 - 400 / 10000, abs=0.01)
    assert result.stressed_area_sqm == pytest.approx(400 * 100, rel=0.02)


def test_offset_matters(scene):
    # Ignoring the -0.1 offset roughly halves NDVI of the stressed block (0.11 vs 0.20).
    geom = field_4326(200, 200, 400, 400)
    wrong = compute_field_ndvi(scene["red"], scene["nir"], scene["scl"], geom, scale=SCALE, offset=0.0, edge_buffer_m=0)
    right = run(scene, geom, edge_buffer_m=0)
    assert right.mean_ndvi == pytest.approx(0.2, abs=0.01)
    assert right.mean_ndvi - wrong.mean_ndvi > 0.05


def test_cloudy_pass_is_skipped(scene):
    # Field entirely under the cloud block.
    assert run(scene, field_4326(600, 600, 800, 800), edge_buffer_m=0) is None


def test_edge_buffer_shrinks_field(scene):
    full = run(scene, field_4326(0, 0, 500, 500), edge_buffer_m=0)
    inner = run(scene, field_4326(0, 0, 500, 500), edge_buffer_m=10)
    assert np.isfinite(inner.ndvi).sum() < np.isfinite(full.ndvi).sum()


def test_stress_zones_and_cog(scene, tmp_path):
    result = run(scene, field_4326(0, 0, 1000, 1000), edge_buffer_m=0, min_valid_fraction=0.5)

    zones = extract_stress_zones(result, min_area_sqm=500)
    assert len(zones) == 1
    assert zones[0]["area_sqm"] == pytest.approx(40000, rel=0.01)
    assert zones[0]["mean_ndvi"] == pytest.approx(0.2, abs=0.01)
    assert zones[0]["geometry"]["type"] == "Polygon"

    path = str(tmp_path / "ndvi.tif")
    write_cog(path, result)
    with rasterio.open(path) as ds:
        assert ds.driver == "GTiff" and ds.crs.to_string() == CRS
        assert np.isnan(ds.nodata)


def test_band_scaling_respects_earthsearch_offset_flag():
    from datetime import datetime

    from pystac import Asset, Item

    from app.stac import band_scaling

    asset = Asset("red.tif", extra_fields={"raster:bands": [{"scale": 0.0001, "offset": -0.1}]})
    item = Item("x", None, None, datetime(2026, 6, 20), {})
    assert band_scaling(item, asset) == (0.0001, -0.1)
    item.properties["earthsearch:boa_offset_applied"] = True
    assert band_scaling(item, asset) == (0.0001, 0.0)


def test_relative_stress_uses_field_median(scene):
    result = run(scene, field_4326(0, 0, 1000, 1000), edge_buffer_m=0, min_valid_fraction=0.5)
    assert result.median_ndvi == pytest.approx(0.818, abs=0.01)
    assert result.stress_threshold == pytest.approx(0.818 * 0.8, abs=0.01)


def test_absolute_rule_uses_fixed_threshold(scene):
    rule = StressRule(mode="absolute", threshold=0.15)
    result = run(scene, field_4326(0, 0, 1000, 1000), edge_buffer_m=0, min_valid_fraction=0.5, stress=rule)
    assert result.stress_threshold == 0.15
    assert result.stressed_area_sqm == 0  # stressed block sits at 0.2


def test_no_canopy_means_no_stress(scene):
    # Field fully inside the 0.2 block: bare-soil-like median, so nothing to scout in either mode.
    for rule in (StressRule(), StressRule(mode="absolute")):
        result = run(scene, field_4326(200, 200, 400, 400), edge_buffer_m=0, stress=rule)
        assert result.stress_threshold is None
        assert result.stressed_area_sqm == 0
        assert extract_stress_zones(result, min_area_sqm=0) == []


def test_crop_thresholds_from_settings():
    from app.config import settings

    assert settings.stress_rule(" Maize ").threshold == 0.4
    assert settings.stress_rule("quinoa").threshold == settings.stress_default_threshold
