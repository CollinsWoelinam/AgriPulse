from pydantic_settings import BaseSettings

from app.ndvi import StressRule


class Settings(BaseSettings):
    database_url: str = "postgresql://agripulse:agripulse@localhost:5432/agripulse"
    default_org_id: str = "00000000-0000-0000-0000-000000000001"  # org for users created via the CLI

    jwt_secret: str = "dev-only-change-me"  # set JWT_SECRET in any shared deployment
    token_ttl_days: int = 30

    photo_dir: str = "/data/photos"
    max_photo_bytes: int = 15 * 1024 * 1024

    stac_api_url: str = "https://earth-search.aws.element84.com/v1"
    stac_collection: str = "sentinel-2-l2a"
    max_scene_cloud_cover: float = 60.0  # scene-level prefilter; field-level SCL mask does the real work

    # Shared volume: the API writes here, TiTiler reads the same path.
    raster_dir: str = "/data/rasters"
    tiler_public_url: str = "http://localhost:8001"
    tiler_internal_url: str = "http://tiler:8000"  # used server-side to build offline MBTiles
    offline_zooms: tuple[int, int] = (12, 17)      # NDVI is 10 m; z17 (~0.8 m/px) is already oversampled
    offline_max_tiles: int = 2000

    min_valid_fraction: float = 0.7  # skip passes where <70% of the field is cloud-free
    min_zone_sqm: float = 500.0      # ignore stress specks smaller than 5 pixels
    edge_buffer_m: float = 10.0      # drop one 10 m pixel along the boundary
    scene_workers: int = 4       # parallel scene reads within one field job
    worker_concurrency: int = 2  # field jobs run in parallel per queue worker

    # Stress detection (see StressRule). Relative is the default: it adapts to crop and season.
    stress_mode: str = "relative"
    stress_relative_drop: float = 0.2
    stress_min_canopy_ndvi: float = 0.25
    # Absolute-mode thresholds per crop_type (lower-cased); starting points, tune per region.
    stress_default_threshold: float = 0.3
    stress_crop_thresholds: dict[str, float] = {
        "wheat": 0.35, "barley": 0.35, "maize": 0.4, "corn": 0.4,
        "soybean": 0.35, "potato": 0.35, "rice": 0.3, "sugarbeet": 0.4,
    }

    # Mean-NDVI drop between consecutive passes that raises an alert.
    alert_mean_drop: float = 0.1

    # Nightly refresh (UTC cron) and how far back it looks for late-published scenes.
    nightly_cron: str = "0 4 * * *"
    nightly_lookback_days: int = 10

    def stress_rule(self, crop_type: str) -> StressRule:
        return StressRule(
            mode=self.stress_mode,
            threshold=self.stress_crop_thresholds.get(crop_type.strip().lower(), self.stress_default_threshold),
            drop=self.stress_relative_drop,
            min_canopy_ndvi=self.stress_min_canopy_ndvi,
        )


settings = Settings()
