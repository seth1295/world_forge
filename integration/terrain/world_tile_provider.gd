class_name WorldTileProvider
extends RefCounted

## Worker-thread provider interface for the global stream manager.
##
## `load_tile(request, cancellation)` must perform only bounded file/network and
## contract-validation work. It must not touch Nodes, RenderingServer, PhysicsServer,
## scene resources, or single-precision global coordinates. Return a normalized
## validated envelope:
## {
##   "ok": true,
##   "manifest": {
##     "schema_id": String, "schema_version": String,
##     "address_id": "wfg1:<level>:<x>:<y>", "source_id": String,
##     "source_generation": String, "lod": int,
##     "tile_bounds": {"west_deg": float, "south_deg": float,
##       "east_deg": float, "north_deg": float},
##     "layer_outcomes": { layer_name: {"status": String, ...} },
##     "layer_spatial_references": { layer_name: {
##       "horizontal_crs": "EPSG:4326", "horizontal_datum": "WGS84",
##       "axis_order": "longitude_latitude", "has_elevation": bool,
##       "source_vertical_datum": String, "height_type": String,
##       "vertical_datum": String, "vertical_conversion": Dictionary? } },
##     "tile_origin": {"horizontal_crs": "EPSG:4326",
##       "vertical_datum": "WGS84_ELLIPSOIDAL", "height_type": "ellipsoidal",
##       "latitude_deg": float, "longitude_deg": float,
##       "ellipsoidal_height_m": float}
##   },
##   "decoded": Dictionary
## }
## A schema-specific provider adapter is responsible for checking the external
## world-tile contract, hashes, paths, per-layer CRS/datum, address bounds and payload sizes
## before it returns this envelope.
func load_tile(_request: Dictionary, _cancellation: WorldTileCancellationToken) -> Dictionary:
	return {"ok": false, "error": "WorldTileProvider.load_tile is abstract"}
