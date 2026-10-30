class_name GlobalPositionBridgeV1
extends RefCounted

const SiteCatalog := preload("res://terrain/site_catalog_v1.gd")
const TARGET_CRS := "EPSG:4978"

## Current Terrain Grid frames are NAD83/GRS80 with unspecified realization/epoch and
## NAVD88 orthometric heights. No compatible operation is registered, so fail closed.
## `local_position_m` is the site frame's (E, H-H0, -N) expression; it is never treated
## as WGS 84 ECEF by this function.
static func terrain_local_to_wgs84_ecef(site_id: String, _local_position_m: Vector3) -> Dictionary:
    var site := SiteCatalog.get_site(site_id)
    if site.is_empty():
        return {
            "ok": false,
            "status": "unsupported_source",
            "source_frame_id": "",
            "target_crs": TARGET_CRS,
            "operation_id": "",
            "ecef_m": Vector3.ZERO,
            "error": "terrain source site is not approved"
        }
    return {
        "ok": false,
        "status": "unavailable",
        "source_frame_id": String(site["frame_id"]),
        "target_crs": TARGET_CRS,
        "operation_id": "",
        "ecef_m": Vector3.ZERO,
        "error": "no compatible NAD83 realization/epoch and NAVD88-to-ellipsoidal operation is registered"
    }
