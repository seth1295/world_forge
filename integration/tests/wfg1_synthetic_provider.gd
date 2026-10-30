extends "res://terrain/world_tile_provider.gd"

const Address := preload("res://terrain/wfg1_tile_address.gd")
const LocalFrame := preload("res://terrain/wfg1_local_frame.gd")

## Explicitly synthetic fixture provider. It contains no real geographic data and
## is used only to exercise the actual asynchronous consumer/lifecycle API.
var delay_msec := 0
var status_by_layer: Dictionary = {}
var extra_layer_outcomes: Dictionary = {}
var bad_origin_vertical_datum := ""
var bad_layer_horizontal_crs := ""
var bad_layer_source_vertical_datum := ""
var mixed_source_vertical := false
var bad_mixed_conversion_mask := false
var tile_bounds_offset_deg := 0.0
var origin_longitude_offset_deg := 0.0
var bad_origin_ecef := false
var valid_fallback_for_layer := ""
var schema_id := "urn:worldforge:synthetic-test-fixture:1"
var schema_version := "synthetic-1"

func load_tile(request: Dictionary, cancellation: WorldTileCancellationToken) -> Dictionary:
	var remaining := delay_msec
	while remaining > 0:
		if cancellation.is_cancelled():
			return {"ok": false, "status": "cancelled", "error": "synthetic provider observed cancellation"}
		var slice := mini(remaining, 2)
		OS.delay_msec(slice)
		remaining -= slice
	if cancellation.is_cancelled():
		return {"ok": false, "status": "cancelled", "error": "synthetic provider observed cancellation"}

	var outcomes: Dictionary = {}
	var spatial: Dictionary = {}
	for layer_value in request["required_layers"]:
		var layer_id := String(layer_value)
		outcomes[layer_id] = _outcome_for_layer(layer_id)
		spatial[layer_id] = _spatial_reference_for_layer(layer_id)
	for layer_id_value in extra_layer_outcomes:
		var layer_id := String(layer_id_value)
		outcomes[layer_id] = extra_layer_outcomes[layer_id_value].duplicate(true)
		spatial[layer_id] = _spatial_reference_for_layer(layer_id)

	var bounds: Dictionary = Address.bounds_for_address(request["address"])
	var tile_origin_vertical_datum := "WGS84_ELLIPSOIDAL"
	if not bad_origin_vertical_datum.is_empty():
		tile_origin_vertical_datum = bad_origin_vertical_datum
	var tile_origin := {
		"horizontal_crs": "EPSG:4326",
		"vertical_datum": tile_origin_vertical_datum,
		"height_type": "ellipsoidal",
		"latitude_deg": (float(bounds["south_deg"]) + float(bounds["north_deg"])) * 0.5,
		"longitude_deg": (float(bounds["west_deg"]) + float(bounds["east_deg"])) * 0.5 + origin_longitude_offset_deg,
		"ellipsoidal_height_m": 0.0
	}
	if bad_origin_ecef:
		var computed_origin := LocalFrame.create_origin(float(tile_origin["latitude_deg"]), float(tile_origin["longitude_deg"]), 0.0)
		var ecef: PackedFloat64Array = computed_origin["ecef_m"]
		ecef[0] += 1.0
		tile_origin["ecef_m"] = ecef
	var declared_bounds := {
		"west_deg": float(bounds["west_deg"]),
		"south_deg": float(bounds["south_deg"]),
		"east_deg": float(bounds["east_deg"]),
		"north_deg": float(bounds["north_deg"]) + tile_bounds_offset_deg
	}
	var manifest := {
		"schema_id": schema_id,
		"schema_version": schema_version,
		"address_id": String(request["address_id"]),
		"source_id": String(request["source_id"]),
		"source_generation": String(request["source_generation"]),
		"lod": int(request["lod"]),
		"tile_bounds": declared_bounds,
		"layer_outcomes": outcomes,
		"layer_spatial_references": spatial,
		"tile_origin": tile_origin
	}
	var decoded := {"fixture_label": "SYNTHETIC_TEST_FIXTURE", "fixture_tile_id": String(request["address_id"])}
	if mixed_source_vertical and spatial.has("terrain"):
		var mixed_reference: Dictionary = spatial["terrain"]
		mixed_reference["source_vertical_datum"] = "per_sample_source_mask"
		mixed_reference["vertical_conversion"] = {"vertical_references_by_source_code": {
			"1": _mixed_vertical_reference("EGM2008", false),
			"2": _mixed_vertical_reference("MEAN_SEA_LEVEL", true)
		}}
		spatial["terrain"] = mixed_reference
		manifest["layer_spatial_references"] = spatial
		decoded["terrain"] = {
			"source_mask": PackedByteArray([1, 2]),
			"geoid_mask": PackedByteArray([1, 1] if bad_mixed_conversion_mask else [1, 2])
		}
	return {
		"ok": true,
		"manifest": manifest,
		"decoded": decoded
	}

func _mixed_vertical_reference(source_datum: String, approximate: bool) -> Dictionary:
	var code_reference := {
		"source_vertical_datum": source_datum,
		"method": "nominal_MSL_plus_EGM2008_geoid" if approximate else "h = H_EGM2008 + N_EGM2008",
		"approximate": approximate,
		"conversion_mask_code": 2 if approximate else 1,
		"geoid_grid_id": "OSGeo-PROJ-data/us_nga_egm08_25.tif",
		"geoid_grid_sha256": "4191d471eefebf24091b56dbc604353cb3b8cf8cc70e448bb9ae56a272bef17a",
		"interpolation_method": "bilinear_interpolation_of_point_registered_grid",
		"numeric_validation": {"max_residual_m": 0.00000191, "independent_method": "synthetic fixture only"}
	}
	if approximate:
		code_reference["quality_warning"] = "synthetic fixture approximate mixed-datum disclosure"
	return code_reference

func _outcome_for_layer(layer_id: String) -> Dictionary:
	var status := String(status_by_layer.get(layer_id, "ready"))
	var outcome := {"status": status}
	if layer_id == "roads" and status == "ready":
		outcome["feature_count"] = 0
		outcome["coverage_metadata"] = {"query_complete": true, "fixture": "synthetic"}
	if status == "partial":
		outcome["gap_declared"] = true
		outcome["disclosure"] = "synthetic missing coverage disclosure"
		outcome["gap_reason"] = "synthetic test gap"
	elif status in ["no_source_coverage", "not_generated", "failed", "cancelled"]:
		outcome["gap_declared"] = true
		outcome["gap_reason"] = "synthetic test coverage/error state"
	if status == "no_source_coverage" and valid_fallback_for_layer == layer_id:
		outcome["fallback"] = {"status": "ready", "source_id": "synthetic-lawful-fallback", "provenance": "SYNTHETIC_TEST_FIXTURE"}
	return outcome

func _spatial_reference_for_layer(layer_id: String) -> Dictionary:
	if layer_id == "terrain":
		var terrain_reference := {
			"horizontal_crs": "EPSG:4326",
			"horizontal_datum": "WGS84",
			"axis_order": "longitude_latitude",
			"has_elevation": true,
			"source_vertical_datum": "WGS84_ELLIPSOIDAL" if bad_layer_source_vertical_datum.is_empty() else bad_layer_source_vertical_datum,
			"height_type": "ellipsoidal",
			"vertical_datum": "WGS84_ELLIPSOIDAL"
		}
		if not bad_layer_horizontal_crs.is_empty():
			terrain_reference["horizontal_crs"] = bad_layer_horizontal_crs
		return terrain_reference
	var feature_reference := {
		"horizontal_crs": "EPSG:4326",
		"horizontal_datum": "WGS84",
		"axis_order": "longitude_latitude",
		"has_elevation": false,
		"source_vertical_datum": "not_applicable",
		"height_type": "not_applicable",
		"vertical_datum": "not_applicable"
	}
	if not bad_layer_horizontal_crs.is_empty():
		feature_reference["horizontal_crs"] = bad_layer_horizontal_crs
	return feature_reference
