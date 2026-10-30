extends SceneTree

const Address := preload("res://terrain/wfg1_tile_address.gd")
const LocalFrame := preload("res://terrain/wfg1_local_frame.gd")
const FeatureBuilder := preload("res://terrain/wfg1_feature_geometry_builder_v1.gd")

var _checks := 0
var _failures := 0
var _fixture_paths: Array[String] = []

func _initialize() -> void:
	_run()
	print("WF_WFG1_FEATURE_GEOMETRY_RESULT=%s checks=%d failures=%d" % ["PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(1 if _failures > 0 else 0)

func _run() -> void:
	print("WF_WFG1_FEATURE_GEOMETRY_SUITE=synthetic-geographic-feature-fixtures")
	var address_result := Address.parse_id("wfg1:0:729:555")
	_check(bool(address_result.get("ok", false)), "synthetic Paris feature tile address parses")
	if not address_result.get("ok", false):
		return
	var origin_result := LocalFrame.create_origin(48.875, 2.375, 0.0)
	_check(bool(origin_result.get("ok", false)), "synthetic feature tile gets a validated tangent frame")
	if not origin_result.get("ok", false):
		return
	var road_features: Array = [
		_feature("road-source-1", "road-fragment-1", "LineString", [[2.32, 48.94], [2.39, 48.91], [2.42, 48.86]], {"road_width_m": 3.0})
	]
	var building_features: Array = [
		_feature("building-source-1", "building-fragment-1", "Polygon", [[
			[2.33, 48.91], [2.36, 48.91], [2.36, 48.88], [2.33, 48.88], [2.33, 48.91]
		]], {"building_height_m": 9.0}),
		_feature("building-source-with-courtyard", "building-fragment-hole", "Polygon", [
			[[2.40, 48.91], [2.43, 48.91], [2.43, 48.88], [2.40, 48.88], [2.40, 48.91]],
			[[2.41, 48.90], [2.42, 48.90], [2.42, 48.89], [2.41, 48.89], [2.41, 48.90]]
		], {})
	]
	var water_features: Array = [
		_feature("open-water-source", "open-water-fragment", "Polygon", [[
			[2.34, 48.85], [2.37, 48.85], [2.37, 48.83], [2.34, 48.83], [2.34, 48.85]
		]], {"water_type": "open_water"}),
		_feature("inland-water-source", "inland-water-fragment", "Polygon", [[
			[2.39, 48.85], [2.42, 48.85], [2.42, 48.83], [2.39, 48.83], [2.39, 48.85]
		]], {"water_type": "lake"})
	]
	var road_record := _write_shard("roads", road_features)
	var building_record := _write_shard("buildings", building_features)
	var water_record := _write_shard("water", water_features)
	if road_record.is_empty() or building_record.is_empty() or water_record.is_empty():
		_check(false, "synthetic GeoJSON shards are written under task temporary storage")
		_cleanup_files()
		return
	var decoded := {
		"terrain": _terrain_fixture(),
		"vector_payloads_by_layer": {
			"roads": [road_record],
			"buildings": [building_record],
			"water": [water_record]
		}
	}
	var context := {
		"tile_id": "wfg1:0:729:555",
		"source_id": "SYNTHETIC_TEST_FIXTURE",
		"source_generation": "SYNTHETIC_TEST_FIXTURE",
		"tile_origin": origin_result
	}
	var built := FeatureBuilder.build_nodes(decoded, context)
	_check(bool(built.get("ok", false)), "roads, buildings and water geometry build from explicitly synthetic GeoJSON")
	if not built.get("ok", false):
		push_error(String(built.get("error", "feature fixture build failed")))
		_cleanup_files()
		return
	var root: Node3D = built["node"]
	var roads: Node3D = root.get_node_or_null("RoadsSourceGeometry")
	var buildings: Node3D = root.get_node_or_null("BuildingsSourceGeometry")
	var water: Node3D = root.get_node_or_null("WaterSourceGeometry")
	_check(roads != null and buildings != null and water != null, "each source layer is represented by a batched layer node")
	if roads != null and roads.get_child_count() == 1:
		var road_mesh: MeshInstance3D = roads.get_child(0)
		var road_index: Array = road_mesh.get_meta("source_feature_vertex_index", [])
		_check(road_index.size() == 1 and String(road_index[0].get("source_id", "")) == "road-source-1" and String(road_index[0].get("fragment_id", "")) == "road-fragment-1", "road render chunk preserves source and fragment IDs")
		var road_style: Dictionary = road_index[0].get("render_style", {}) if not road_index.is_empty() else {}
		_check(is_equal_approx(float(road_style.get("road_width_m", 0.0)), 3.0) and road_style.get("width_provenance") == "source property", "source-provided road width remains distinct from procedural width style")
	else:
		_check(false, "road render chunk exists")
	if buildings != null and buildings.get_child_count() == 1:
		var building_mesh: MeshInstance3D = buildings.get_child(0)
		var building_index: Array = building_mesh.get_meta("source_feature_vertex_index", [])
		var style: Dictionary = building_index[0].get("render_style", {}) if not building_index.is_empty() else {}
		_check(building_index.size() == 1 and String(building_index[0].get("source_id", "")) == "building-source-1", "courtyard building source feature is retained but deliberately not filled")
		_check(is_equal_approx(float(style.get("building_height_m", 0.0)), 9.0) and style.get("height_provenance") == "source property", "source-provided building height is preserved")
		var building_outcome: Dictionary = built["layer_outcome_overrides"].get("buildings", {})
		_check(building_outcome.get("status") == "partial" and String(building_outcome.get("gap_reason", "")).contains("interior rings"), "unrendered courtyard is an explicit partial layer outcome")
	else:
		_check(false, "valid building mesh exists while the courtyard is omitted")
	if water != null and water.get_child_count() == 1:
		var water_mesh: MeshInstance3D = water.get_child(0)
		var water_index: Array = water_mesh.get_meta("source_feature_vertex_index", [])
		var water_style: Dictionary = water_index[0].get("render_style", {}) if not water_index.is_empty() else {}
		_check(water_index.size() == 1 and String(water_index[0].get("source_id", "")) == "open-water-source", "only explicitly typed open water receives a rendered surface")
		_check(water_style.get("surface_method") == "nominal mean sea level at h=N_EGM2008" and water_style.get("source_height_invented") == false, "open-water surface uses geoid height and discloses its source rule")
		var water_outcome: Dictionary = built["layer_outcome_overrides"].get("water", {})
		_check(int(root.get_meta("source_feature_counts_and_placement", {}).get("water", {}).get("water_without_surface_count", -1)) == 1 and water_outcome.get("status") == "partial", "inland water without source-level height remains unplaced and partial")
	else:
		_check(false, "open-water render chunk exists")
	_check(not bool(built.get("collision_ready", true)), "feature-only output never claims terrain collision readiness")
	if is_instance_valid(root):
		root.free()
	_cleanup_files()

func _terrain_fixture() -> Dictionary:
	var longitudes: Array[float] = [2.30, 2.45]
	var latitudes: Array[float] = [48.95, 48.80]
	var lonlat := PackedFloat64Array()
	var heights := PackedFloat64Array()
	var valid := PackedByteArray()
	var source_mask := PackedByteArray()
	var quality_mask := PackedByteArray()
	var geoid := PackedFloat32Array()
	var geoid_mask := PackedByteArray()
	for latitude in latitudes:
		for longitude in longitudes:
			lonlat.append(longitude)
			lonlat.append(latitude)
			heights.append(50.0)
			valid.append(1)
			source_mask.append(1)
			quality_mask.append(1)
			geoid.append(40.0)
			geoid_mask.append(1)
	return {
		"rows": 2,
		"columns": 2,
		"ellipsoidal_heights_m": heights,
		"valid_mask": valid,
		"sample_lonlat_deg": lonlat,
		"sample_coordinate_transform": {
			"affine": {"x_origin": 2.30, "y_origin": 48.95, "pixel_width": 0.15, "pixel_height": -0.15, "rotation_x": 0.0, "rotation_y": 0.0},
			"column_offset": 0.0,
			"row_offset": 0.0
		},
		"source_mask": source_mask,
		"quality_mask": quality_mask,
		"geoid_undulation_m": geoid,
		"geoid_mask": geoid_mask,
		"horizontal_crs": "EPSG:4326",
		"horizontal_datum": "WGS84",
		"axis_order": "longitude_latitude",
		"vertical_datum": "WGS84_ELLIPSOIDAL",
		"height_type": "ellipsoidal",
		"tile_bounds_wgs84": {"west_deg": 2.25, "south_deg": 48.75, "east_deg": 2.5, "north_deg": 49.0}
	}

func _feature(source_id: String, fragment_id: String, geometry_type: String, coordinates: Variant, source_properties: Dictionary) -> Dictionary:
	var properties := source_properties.duplicate(true)
	properties["worldforge"] = {"fragment_id": fragment_id, "tile_id": "wfg1:0:729:555", "fixture": "synthetic; not source geography"}
	return {"type": "Feature", "id": source_id, "geometry": {"type": geometry_type, "coordinates": coordinates}, "properties": properties}

func _write_shard(layer_id: String, features: Array) -> Dictionary:
	var temporary_root := OS.get_environment("WF_TASK_TEMP_ROOT")
	if temporary_root.is_empty():
		return {}
	var path := temporary_root.path_join("synthetic-%s.geojson" % layer_id)
	var bytes := JSON.stringify({"type": "FeatureCollection", "features": features}).to_utf8_buffer()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {}
	file.store_buffer(bytes)
	file.close()
	_fixture_paths.append(path)
	var hasher := HashingContext.new()
	if hasher.start(HashingContext.HASH_SHA256) != OK or hasher.update(bytes) != OK:
		return {}
	return {
		"path": path,
		"relative_path": "synthetic/%s.geojson" % layer_id,
		"descriptor": {"feature_count": features.size(), "sha256": hasher.finish().hex_encode()}
	}

func _cleanup_files() -> void:
	for path in _fixture_paths:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_fixture_paths.clear()

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS  " + label)
	else:
		_failures += 1
		push_error("FAIL  " + label)
