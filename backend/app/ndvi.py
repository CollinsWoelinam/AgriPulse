"""NDVI computation, zonal stats and stress-zone extraction for one field on one scene."""

from dataclasses import dataclass

import numpy as np
import rasterio
from affine import Affine
from rasterio.crs import CRS
from rasterio.enums import Resampling
from rasterio.features import geometry_mask, shapes
from rasterio.warp import transform_geom
from rasterio.windows import from_bounds
from shapely.geometry import mapping, shape

# Sentinel-2 SCL classes to drop: nodata, saturated, cloud shadow, cloud medium/high, cirrus, snow.
SCL_INVALID = [0, 1, 3, 8, 9, 10, 11]


@dataclass(frozen=True)
class StressRule:
    """How a pixel counts as stressed.

    relative: more than `drop` below the field's own median, so early-season or
              naturally low-NDVI crops don't flag the whole field.
    absolute: below a fixed (per-crop) `threshold`.
    Either way, no stress is flagged when the median is below `min_canopy_ndvi`
    (bare soil, emergence, post-harvest): there is no canopy to scout.
    """

    mode: str = "relative"
    threshold: float = 0.3
    drop: float = 0.2
    min_canopy_ndvi: float = 0.25

    def threshold_for(self, median_ndvi: float) -> float | None:
        if median_ndvi < self.min_canopy_ndvi:
            return None
        return median_ndvi * (1 - self.drop) if self.mode == "relative" else self.threshold


@dataclass
class FieldNdvi:
    ndvi: np.ndarray  # float32, NaN outside field / under cloud
    transform: Affine
    crs: CRS
    min_ndvi: float
    mean_ndvi: float
    median_ndvi: float
    max_ndvi: float
    std_ndvi: float
    valid_fraction: float
    stress_threshold: float | None  # None: no canopy, stress not evaluated
    stressed_area_sqm: float


def compute_field_ndvi(
    red_href: str,
    nir_href: str,
    scl_href: str,
    field_geom_4326: dict,
    scale: float = 0.0001,
    offset: float = 0.0,
    stress: StressRule = StressRule(),
    min_valid_fraction: float = 0.7,
    edge_buffer_m: float = 10.0,
) -> FieldNdvi | None:
    """Return NDVI + stats for the field, or None if the pass is too cloudy to trust."""
    with rasterio.open(red_href) as red_ds, rasterio.open(nir_href) as nir_ds, rasterio.open(scl_href) as scl_ds:
        geom = shape(transform_geom("EPSG:4326", red_ds.crs, field_geom_4326))
        inner = geom.buffer(-edge_buffer_m)
        if not inner.is_empty:  # tiny fields keep their full boundary
            geom = inner

        # Windowed reads: only the field's bounding box is fetched over HTTP.
        # boundless=True zero-fills where a field crosses the tile edge (0 = nodata).
        win = from_bounds(*geom.bounds, transform=red_ds.transform).round_offsets().round_lengths()
        if win.width < 1 or win.height < 1:
            return None
        transform = red_ds.window_transform(win)
        red_dn = red_ds.read(1, window=win, boundless=True, fill_value=0)
        nir_dn = nir_ds.read(1, window=win, boundless=True, fill_value=0)
        scl = scl_ds.read(  # SCL is 20 m: resample onto the 10 m grid
            1,
            window=from_bounds(*red_ds.window_bounds(win), transform=scl_ds.transform),
            out_shape=red_dn.shape,
            resampling=Resampling.nearest,
            boundless=True,
            fill_value=0,
        )
        crs = red_ds.crs

    red = red_dn.astype("float32") * scale + offset
    nir = nir_dn.astype("float32") * scale + offset
    outside = geometry_mask([mapping(geom)], out_shape=red_dn.shape, transform=transform)
    # Non-positive reflectance is a correction artifact (or a double-applied offset), not a real signal.
    invalid = outside | np.isin(scl, SCL_INVALID) | (red_dn == 0) | (nir_dn == 0) | (red <= 0) | (nir <= 0)
    with np.errstate(divide="ignore", invalid="ignore"):
        ndvi = np.where(invalid, np.nan, (nir - red) / (nir + red)).astype("float32")
    ndvi[~np.isfinite(ndvi)] = np.nan
    np.clip(ndvi, -1.0, 1.0, out=ndvi)

    valid = ndvi[np.isfinite(ndvi)]
    in_field = int((~outside).sum())
    if in_field == 0 or valid.size / in_field < min_valid_fraction:
        return None

    pixel_area = abs(transform.a * transform.e)
    median = float(np.median(valid))
    threshold = stress.threshold_for(median)
    stressed = 0 if threshold is None else int((valid < threshold).sum())
    return FieldNdvi(
        ndvi=ndvi,
        transform=transform,
        crs=crs,
        min_ndvi=float(valid.min()),
        mean_ndvi=float(valid.mean()),
        median_ndvi=median,
        max_ndvi=float(valid.max()),
        std_ndvi=float(valid.std()),
        valid_fraction=valid.size / in_field,
        stress_threshold=threshold,
        stressed_area_sqm=float(stressed * pixel_area),
    )


def extract_stress_zones(result: FieldNdvi, min_area_sqm: float) -> list[dict]:
    """Polygonize contiguous pixels below the pass's stress threshold; returns EPSG:4326 GeoJSON."""
    if result.stress_threshold is None:
        return []
    stressed = np.isfinite(result.ndvi) & (result.ndvi < result.stress_threshold)
    if not stressed.any():
        return []
    zones = []
    for geom, _ in shapes(stressed.astype("uint8"), mask=stressed, transform=result.transform, connectivity=8):
        poly = shape(geom)
        if poly.area < min_area_sqm:
            continue
        inside = ~geometry_mask([geom], out_shape=result.ndvi.shape, transform=result.transform)
        zones.append({
            "geometry": transform_geom(result.crs, "EPSG:4326", geom),
            "area_sqm": float(poly.area),
            "mean_ndvi": float(np.nanmean(result.ndvi[inside])),
        })
    return zones


def write_cog(path: str, result: FieldNdvi) -> None:
    height, width = result.ndvi.shape
    with rasterio.open(
        path,
        "w",
        driver="COG",
        width=width,
        height=height,
        count=1,
        dtype="float32",
        crs=result.crs,
        transform=result.transform,
        nodata=np.nan,
        compress="DEFLATE",
        predictor=3,
    ) as dst:
        dst.write(result.ndvi, 1)
