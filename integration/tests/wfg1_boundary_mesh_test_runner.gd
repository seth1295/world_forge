extends SceneTree

const Address := preload("res://terrain/wfg1_tile_address.gd")
const LocalFrame := preload("res://terrain/wfg1_local_frame.gd")
const TerrainBuilder := preload("res://terrain/wfg1_terrain_mesh_builder_v1.gd")

var _checks := 0
var _failures := 0

func _initialize() -> void:
	_run()
	print("WF_WFG1_BOUNDARY_MESH_RESULT=%s checks=%d failures=%d" % ["PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(1 if _failures > 0 else 0)

func _run() -> void:
	print("WF_WFG1_BOUNDARY_MESH_SUITE=synthetic-boundary-fixtures")
	var center_address := Address.address_for_lon_lat(0.125, 89.875)
	var last_x_address := Address.address_for_lon_lat(179.875, 89.875)
	_check(center_address.get("ok", false) and last_x_address.get("ok", false), "polar fixture addresses resolve")
	if not center_address.get("ok", false) or not last_x_address.get("ok", false):
		return
	var center_result := _build_polar_fixture(center_address["address"])
	var last_x_result := _build_polar_fixture(last_x_address["address"])
	_check(center_result.get("ok", false) and last_x_result.get("ok", false), "both synthetic polar cells build a terrain render/collision mesh")
	if not center_result.get("ok", false) or not last_x_result.get("ok", false):
		if not center_result.get("ok", false):
			push_error(String(center_result.get("error", "")))
		if not last_x_result.get("ok", false):
			push_error(String(last_x_result.get("error", "")))
		_free_result(center_result)
		_free_result(last_x_result)
		return
	var center_samples: Dictionary = center_result["edge_samples"]
	var east_samples: Dictionary = last_x_result["edge_samples"]
	var center_hashes: Dictionary = center_result["edge_hashes"]
	var east_hashes: Dictionary = last_x_result["edge_hashes"]
	_check(center_samples.has("north") and center_samples["north"] == east_samples.get("north", PackedFloat64Array()), "all x columns share identical canonical pole target longitude, latitude and height")
	_check(center_hashes.get("north", "") == east_hashes.get("north", ""), "canonical pole edge hash is identical across remote longitude columns")
	_check(center_samples["north"] == PackedFloat64Array([0.0, 90.0, 20.0]), "pole edge metadata uses lon=0, lat=+90 and the same ellipsoidal height")
	var tid_values: PackedInt32Array = center_result["edge_data"]["type_identifier_masks"]["north"]
	var tid_valid: PackedByteArray = center_result["edge_data"]["type_identifier_valid"]["north"]
	_check(tid_values == PackedInt32Array([-1]) and tid_valid == PackedByteArray([0]), "nullable CopDEM TID stays null through the terrain boundary record")
	_check(int(center_result["node"].get_meta("terrain_triangle_count", -1)) == 10 and center_result["vertices"].size() == 10, "single pole vertex fans into the last valid north raster row")
	var collision_faces: PackedVector3Array = center_result["faces"]
	var indices: PackedInt32Array = center_result["indices"]
	var render_vertices: PackedVector3Array = center_result["vertices"]
	var same_topology := collision_faces.size() == indices.size()
	var maximum_residual := 0.0
	for index in range(mini(indices.size(), collision_faces.size())):
		var vertex_index := int(indices[index])
		if vertex_index < 0 or vertex_index >= render_vertices.size():
			same_topology = false
			break
		maximum_residual = maxf(maximum_residual, render_vertices[vertex_index].distance_to(collision_faces[index]))
	_check(same_topology and maximum_residual <= 0.001, "synthetic polar render/collision positions remain within the 1 mm representation bound")
	_check(String(center_result["node"].get_meta("terrain_boundary_support_status", "")) == "partial_missing_edges", "unprovided ordinary edges remain explicitly partial")
	_free_result(center_result)
	_free_result(last_x_result)

func _build_polar_fixture(address: Dictionary) -> Dictionary:
	var bounds := Address.bounds_for_address(address)
	var origin := LocalFrame.create_origin(
		(float(bounds["south_deg"]) + float(bounds["north_deg"])) * 0.5,
		(float(bounds["west_deg"]) + float(bounds["east_deg"])) * 0.5,
		0.0
	)
	if not origin.get("ok", false):
		return {"ok": false, "error": String(origin.get("error", "tile origin failed"))}
	var longitudes: Array[float] = []
	for column in range(3):
		longitudes.append(float(bounds["west_deg"]) + (float(column) + 0.5) * 0.08333333333333333)
	var latitudes: Array[float] = []
	for row in range(3):
		latitudes.append(float(bounds["north_deg"]) - (float(row) + 0.5) * 0.08333333333333333)
	var lonlat := PackedFloat64Array()
	var heights := PackedFloat64Array()
	var valid := PackedByteArray()
	for latitude in latitudes:
		for longitude in longitudes:
			lonlat.append(longitude)
			lonlat.append(latitude)
			heights.append(20.0)
			valid.append(1)
	var pole_feature := {
		"id": "boundary:north:0",
		"edge": "north",
		"edge_index": 0,
		"edge_sample_count": 1,
		"longitude_deg": 0.0,
		"latitude_deg": 90.0,
		"ellipsoidal_height_m": 20.0,
		"support": {
			"source_sample_longitude": 0.0,
			"source_sample_latitude": 89.95833333333333,
			"source_height_H": -20.0,
			"geoid_undulation_N": 40.0,
			"ellipsoidal_height_h": 20.0,
			"source_mask": 1,
			"quality_mask": 1,
			"type_identifier_mask": null,
			"geoid_mask": 1
		}
	}
	var decoded := {
		"terrain": {
			"rows": 3,
			"columns": 3,
			"ellipsoidal_heights_m": heights,
			"valid_mask": valid,
			"sample_lonlat_deg": lonlat,
			"global_row_offset": 0,
			"global_column_offset": 0,
			"horizontal_crs": "EPSG:4326",
			"horizontal_datum": "WGS84",
			"axis_order": "longitude_latitude",
			"vertical_datum": "WGS84_ELLIPSOIDAL",
			"height_type": "ellipsoidal",
			"source_sample_spacing": {"pixel_width_deg": 0.08333333333333333, "pixel_height_deg": -0.08333333333333333},
			"boundary_support_features": [pole_feature]
		}
	}
	var context := {
		"tile_id": Address.format_id(address),
		"lod": 0,
		"source_id": "SYNTHETIC_TEST_FIXTURE",
		"source_generation": "SYNTHETIC_TEST_FIXTURE",
		"tile_origin": origin
	}
	return TerrainBuilder.build_tile(decoded, context)

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS  " + label)
	else:
		_failures += 1
		push_error("FAIL  " + label)

func _free_result(result: Dictionary) -> void:
	var node: Variant = result.get("node")
	if node is Node3D and is_instance_valid(node):
		node.free()
