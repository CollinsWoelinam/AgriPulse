from datetime import date

from pystac import Asset, Item
from pystac_client import Client

from app.config import settings


def search_scenes(geom_4326: dict, start: date, end: date) -> list[Item]:
    client = Client.open(settings.stac_api_url)
    search = client.search(
        collections=[settings.stac_collection],
        intersects=geom_4326,
        datetime=f"{start.isoformat()}/{end.isoformat()}",
        query={"eo:cloud_cover": {"lt": settings.max_scene_cloud_cover}},
        max_items=500,
    )
    return list(search.items())


def band_scaling(item: Item, asset: Asset) -> tuple[float, float]:
    """Scale/offset to turn DNs into surface reflectance.

    raster:bands carries offset -0.1 for processing baseline >= 04.00, but Earth Search has
    already subtracted it from the pixels when `earthsearch:boa_offset_applied` is true while
    still advertising the offset. Applying it twice drives red reflectance negative.
    """
    band = (asset.extra_fields.get("raster:bands") or [{}])[0]
    offset = 0.0 if item.properties.get("earthsearch:boa_offset_applied") else band.get("offset", 0.0)
    return band.get("scale", 0.0001), offset
