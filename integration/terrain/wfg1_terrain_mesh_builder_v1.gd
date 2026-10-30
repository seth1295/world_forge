class_name Wfg1TerrainMeshBuilderV1
extends RefCounted

## Build a source-derived terrain render mesh and collision mesh for one WFG-1
## tile. LOD changes decimate only the interior. Every native source edge sample
## remains in the mesh at all LODs, and coarse macro-cells use a deterministic
## center fan with explicit edge strips. Adjacent tiles therefore share the
## same edge positions; no skirts conceal a mismatch. Render and collision use
## one exact local vertex and triangle index set.
const Address := preload("res://terrain/wfg1_tile_address.gd")
const LocalFrame := preload("res://terrain/wfg1_local_frame.gd")
const MAX_SAMPLES := 16_777_216
const DEGENERATE_TRIANGLE_AREA_SQUARED := 1.0e-20

## `decoded.terrain` is normalized by the external-bundle provider:
## `rows`, `columns`, `ellipsoidal_heights_m: PackedFloat64Array`,
## `valid_mask: PackedByteArray`, `sample_lonlat_deg: PackedFloat64Array`
## (interleaved lon/lat for each sample), `global_row_offset`,
## `global_column_offset`, source ID/generation, datum/conversion provenance.
## The current bundle schema may provide an affine source grid; the adapter
## expands that exact pixel-center/row-order transform to the packed positions.
static func build_tile(decoded: Dictionary, context: Dictionary) -> Dictionary:
	if not decoded.has("terrain") or typeof(decoded["terrain"]) != TYPE_DICTIONARY:
		return _failure("decoded tile does not contain terrain data")
	var terrain: Dictionary = decoded["terrain"]
	var rows := int(terrain.get("rows", 0))
	var columns := int(terrain.get("columns", 0))
	if rows < 2 or columns < 2 or rows > MAX_SAMPLES / columns:
		return _failure("terrain sample dimensions are outside the bounded grid")
	var sample_count := rows * columns
	var heights: Variant = terrain.get("ellipsoidal_heights_m")
	var valid: Variant = terrain.get("valid_mask")
	var lonlat: Variant = terrain.get("sample_lonlat_deg")
	if typeof(heights) != TYPE_PACKED_FLOAT64_ARRAY or (heights as PackedFloat64Array).size() != sample_count:
		return _failure("ellipsoidal terrain heights must be a matching PackedFloat64Array")
	if typeof(valid) != TYPE_PACKED_BYTE_ARRAY or (valid as PackedByteArray).size() != sample_count:
		return _failure("terrain valid mask must be a matching PackedByteArray")
	if typeof(lonlat) != TYPE_PACKED_FLOAT64_ARRAY or (lonlat as PackedFloat64Array).size() != sample_count * 2:
		return _failure("terrain sample coordinates must be interleaved binary64 longitude/latitude pairs")
	if String(terrain.get("horizontal_crs", "")) != LocalFrame.CRS_GEOGRAPHIC_2D or String(terrain.get("horizontal_datum", "")) != "WGS84" or String(terrain.get("axis_order", "")) != "longitude_latitude":
		return _failure("terrain sample coordinates must declare normalized WGS84 longitude/latitude")
	if String(terrain.get("vertical_datum", "")) != LocalFrame.ELLIPSOIDAL_DATUM or String(terrain.get("height_type", "")) != "ellipsoidal":
		return _failure("terrain sample heights must be explicitly transformed to WGS84 ellipsoidal metres")
	var tile_id := String(context.get("tile_id", ""))
	var address_result := Address.parse_id(tile_id)
	if not address_result.get("ok", false):
		return _failure("terrain builder requires a canonical WFG-1 tile ID")
	var address: Dictionary = address_result["address"]
	var bounds := Address.bounds_for_address(address)
	if not bounds.get("ok", false):
		return _failure("terrain address has no computable WFG-1 bounds")
	var tile_origin: Variant = context.get("tile_origin")
	if typeof(tile_origin) != TYPE_DICTIONARY or not LocalFrame.validate_frame(tile_origin).get("ok", false):
		return _failure("terrain builder requires a validated scalar-double tile origin")
	var lod := int(context.get("lod", -1))
	if lod < Address.MIN_LEVEL or lod > Address.MAX_LEVEL:
		return _failure("terrain representation LOD is outside the supported range")
	var source_id := String(context.get("source_id", ""))
	var source_generation := String(context.get("source_generation", ""))
	if source_id.is_empty() or source_generation.is_empty():
		return _failure("terrain source identity and generation must be explicit")

	var heights_m: PackedFloat64Array = heights
	var valid_mask: PackedByteArray = valid
	var sample_lonlat: PackedFloat64Array = lonlat
	var global_row_offset := int(terrain.get("global_row_offset", 0))
	var global_column_offset := int(terrain.get("global_column_offset", 0))
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var grid_valid := PackedByteArray()
	vertices.resize(sample_count)
	normals.resize(sample_count)
	grid_valid.resize(sample_count)
	var min_height := INF
	var max_height := -INF
	var source_spacing: Variant = terrain.get("source_sample_spacing", {})
	if typeof(source_spacing) != TYPE_DICTIONARY:
		return _failure("terrain source sample spacing is required to validate point-grid perimeter support")
	var pixel_width_deg := absf(float(source_spacing.get("pixel_width_deg", 0.0)))
	var pixel_height_deg := absf(float(source_spacing.get("pixel_height_deg", 0.0)))
	if not is_finite(pixel_width_deg) or not is_finite(pixel_height_deg) or pixel_width_deg <= 0.0 or pixel_height_deg <= 0.0:
		return _failure("terrain point-grid sample spacing must be finite and positive")
	var bounds_tolerance_deg := 1.0e-12
	for sample_index in range(sample_count):
		if int(valid_mask[sample_index]) not in [0, 1]:
			return _failure("terrain valid-mask values must be 0 or 1")
		if int(valid_mask[sample_index]) == 0:
			grid_valid[sample_index] = 0
			vertices[sample_index] = Vector3.ZERO
			normals[sample_index] = Vector3.UP
			continue
		var longitude := sample_lonlat[sample_index * 2]
		var latitude := sample_lonlat[sample_index * 2 + 1]
		var height := heights_m[sample_index]
		if not is_finite(longitude) or not is_finite(latitude) or not is_finite(height):
			return _failure("valid terrain sample contains a non-finite position or height")
		if longitude < float(bounds["west_deg"]) - bounds_tolerance_deg or longitude > float(bounds["east_deg"]) + bounds_tolerance_deg or latitude < float(bounds["south_deg"]) - bounds_tolerance_deg or latitude > float(bounds["north_deg"]) + bounds_tolerance_deg:
			return _failure("terrain sample lies outside its declared WFG-1 extent after explicit pixel registration")
		var ecef := LocalFrame.geodetic_to_ecef_components(latitude, longitude, height, LocalFrame.CRS_GEOGRAPHIC_2D, LocalFrame.ELLIPSOIDAL_DATUM, "ellipsoidal")
		if not ecef.get("ok", false):
			return _failure(String(ecef.get("error", "terrain sample cannot be converted to WGS84 ECEF")))
		var local := LocalFrame.ecef_to_local(ecef["ecef_m"], tile_origin)
		if not local.get("ok", false):
			return _failure(String(local.get("error", "terrain sample is outside the current tangent frame")))
		vertices[sample_index] = local["local_engine_m"]
		normals[sample_index] = Vector3.ZERO
		grid_valid[sample_index] = 1
		min_height = minf(min_height, height)
		max_height = maxf(max_height, height)
	if not is_finite(min_height) or not is_finite(max_height):
		return _failure("terrain grid has no valid samples")

	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	if lod == 0:
		_append_native_grid(rows, columns, vertices, normals, grid_valid, indices, faces)
	else:
		var factor := 1 << lod
		var selected_rows := _select_axis(rows, factor, global_row_offset)
		var selected_columns := _select_axis(columns, factor, global_column_offset)
		for row_index in range(selected_rows.size() - 1):
			for column_index in range(selected_columns.size() - 1):
				_append_lod_macro(
					int(selected_rows[row_index]),
					int(selected_rows[row_index + 1]),
					int(selected_columns[column_index]),
					int(selected_columns[column_index + 1]),
					rows,
					columns,
					vertices,
					normals,
					grid_valid,
					indices,
					faces
				)
	var boundary_result := _append_boundary_support(
		terrain.get("boundary_support_features", []),
		rows,
		columns,
		sample_lonlat,
		heights_m,
		grid_valid,
		vertices,
		normals,
		indices,
		faces,
		tile_origin,
		bounds
	)
	if not boundary_result.get("ok", false):
		return _failure(String(boundary_result.get("error", "terrain boundary support failed validation")))
	if indices.is_empty() or faces.size() != indices.size():
		return _failure("terrain representation has no valid render/collision triangles")
	for sample_index in range(normals.size()):
		if grid_valid[sample_index] == 0:
			continue
		var normal := normals[sample_index]
		if not is_finite(normal.x) or not is_finite(normal.y) or not is_finite(normal.z):
			return _failure("terrain normal is non-finite")
		if normal.length_squared() <= DEGENERATE_TRIANGLE_AREA_SQUARED:
			# Valid native samples omitted by this LOD have no accumulated mesh normal.
			normals[sample_index] = Vector3.UP
		else:
			normals[sample_index] = normal.normalized()
	var landcover_result := _make_landcover_vertex_colors(decoded, sample_lonlat, terrain.get("boundary_support_features", []), vertices.size())
	if not landcover_result.get("ok", false):
		return _failure(String(landcover_result.get("error", "land-cover material sampling failed")))
	var landcover_colors: PackedColorArray = landcover_result.get("colors", PackedColorArray())
	var has_landcover := bool(landcover_result.get("has_landcover", false))
	var mesh := ArrayMesh.new()
	var mesh_arrays: Array = []
	mesh_arrays.resize(Mesh.ARRAY_MAX)
	mesh_arrays[Mesh.ARRAY_VERTEX] = vertices
	mesh_arrays[Mesh.ARRAY_NORMAL] = normals
	mesh_arrays[Mesh.ARRAY_INDEX] = indices
	if has_landcover:
		if landcover_colors.size() != vertices.size():
			return _failure("WorldCover vertex colors do not match terrain mesh vertices")
		mesh_arrays[Mesh.ARRAY_COLOR] = landcover_colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh_arrays)
	if mesh.get_surface_count() != 1:
		return _failure("Godot could not create a terrain render surface")
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE if has_landcover else Color(0.34, 0.43, 0.31, 1.0)
	material.vertex_color_use_as_albedo = has_landcover
	material.roughness = 0.96
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, material)
	var root := Node3D.new()
	root.name = "Terrain_%s_Lod%d" % [tile_id.replace(":", "_"), lod]
	root.set_meta("terrain_source_id", source_id)
	root.set_meta("source_generation", source_generation)
	root.set_meta("wfg1_tile_id", tile_id)
	root.set_meta("runtime_lod", lod)
	root.set_meta("source_sample_spacing", terrain.get("source_sample_spacing", {}))
	root.set_meta("source_vertical_reference", terrain.get("source_vertical_reference", {}))
	root.set_meta("source_grid_sample_registration", "explicit pixel-center coordinates derived from the producer affine origin reference")
	root.set_meta("sample_min_ellipsoidal_height_m", min_height)
	root.set_meta("sample_max_ellipsoidal_height_m", max_height)
	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "TerrainSurface"
	mesh_node.mesh = mesh
	root.add_child(mesh_node)
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	var collision_node := CollisionShape3D.new()
	collision_node.name = "TerrainTriangles"
	var collision := ConcavePolygonShape3D.new()
	collision.backface_collision = true
	collision.set_faces(faces)
	collision_node.shape = collision
	body.add_child(collision_node)
	root.add_child(body)
	var edge_data := _extract_edges(rows, columns, sample_lonlat, heights_m, grid_valid)
	if not boundary_result["edge_data"].is_empty():
		edge_data = boundary_result["edge_data"]
	root.set_meta("terrain_edge_hashes", edge_data["hashes"])
	root.set_meta("terrain_edge_samples", edge_data["samples"])
	root.set_meta("terrain_boundary_support_counts", boundary_result["counts"])
	root.set_meta("terrain_boundary_support_status", boundary_result["status"])
	root.set_meta("terrain_lod_algorithm", "native-edge-preserving-center-fan-v1")
	root.set_meta("terrain_triangle_count", indices.size() / 3)
	root.set_meta("landcover_material_source", "ESA WorldCover class sampled at terrain mesh vertices" if has_landcover else "no land-cover raster available")
	root.set_meta("landcover_class_colors", landcover_result.get("class_counts", {}))
	var included_layers := PackedStringArray(["terrain"])
	if has_landcover:
		included_layers.append("landcover")
	return {
		"ok": true,
		"error": "",
		"node": root,
		"collision_ready": true,
		"included_layers": included_layers,
		"runtime_lod": lod,
		"rows": rows,
		"columns": columns,
		"vertices": vertices,
		"indices": indices,
		"faces": faces,
		"edge_data": edge_data,
		"edge_samples": edge_data["samples"],
		"edge_hashes": edge_data["hashes"],
		"terrain_source_id": source_id,
		"source_generation": source_generation,
		"source_spacing": terrain.get("source_sample_spacing", {}),
		"source_vertical_reference": terrain.get("source_vertical_reference", {})
	}

static func _make_landcover_vertex_colors(decoded: Dictionary, terrain_lonlat: PackedFloat64Array, boundary_features: Variant, expected_vertex_count: int) -> Dictionary:
	var landcover: Variant = decoded.get("landcover")
	if typeof(landcover) != TYPE_DICTIONARY:
		return {"ok": true, "error": "", "has_landcover": false, "colors": PackedColorArray(), "class_counts": {}}
	var raster: Dictionary = landcover
	var values: Variant = raster.get("classes_u8")
	var rows := int(raster.get("rows", 0))
	var columns := int(raster.get("columns", 0))
	if rows == 0 and columns == 0 and typeof(values) == TYPE_PACKED_BYTE_ARRAY and values.is_empty():
		return {"ok": true, "error": "", "has_landcover": false, "colors": PackedColorArray(), "class_counts": {}}
	if typeof(values) != TYPE_PACKED_BYTE_ARRAY or rows < 1 or columns < 1 or rows > MAX_SAMPLES / columns or values.size() != rows * columns:
		return {"ok": false, "error": "WorldCover class raster dimensions are invalid"}
	var affine: Variant = raster.get("pixel_center_affine")
	if typeof(affine) != TYPE_DICTIONARY:
		return {"ok": false, "error": "WorldCover class raster lacks a pixel-center affine"}
	for key in ["x_origin_deg", "y_origin_deg", "pixel_width_deg", "pixel_height_deg"]:
		if not affine.has(key) or typeof(affine[key]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(affine[key])):
			return {"ok": false, "error": "WorldCover affine lacks finite %s" % key}
	if float(affine["pixel_width_deg"]) == 0.0 or float(affine["pixel_height_deg"]) == 0.0:
		return {"ok": false, "error": "WorldCover pixel spacing must be nonzero"}
	var vertex_lonlat := PackedFloat64Array()
	vertex_lonlat.append_array(terrain_lonlat)
	if typeof(boundary_features) == TYPE_ARRAY:
		for edge in ["north", "east", "south", "west"]:
			var edge_features: Array[Dictionary] = []
			for feature_value in boundary_features:
				if typeof(feature_value) == TYPE_DICTIONARY and String(feature_value.get("edge", "")) == edge:
					edge_features.append(feature_value)
			edge_features.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("edge_index", -1)) < int(b.get("edge_index", -1)))
			for feature in edge_features:
				vertex_lonlat.append(float(feature.get("longitude_deg", NAN)))
				vertex_lonlat.append(float(feature.get("latitude_deg", NAN)))
	if vertex_lonlat.size() != expected_vertex_count * 2:
		return {"ok": false, "error": "land-cover material coordinates do not match terrain vertices"}
	var colors := PackedColorArray()
	colors.resize(expected_vertex_count)
	var class_counts: Dictionary = {}
	for vertex_index in range(expected_vertex_count):
		var lon := vertex_lonlat[vertex_index * 2]
		var lat := vertex_lonlat[vertex_index * 2 + 1]
		if not is_finite(lon) or not is_finite(lat):
			return {"ok": false, "error": "terrain vertex has non-finite coordinates for land-cover sampling"}
		var column_position := (lon - float(affine["x_origin_deg"])) / float(affine["pixel_width_deg"])
		var row_position := (lat - float(affine["y_origin_deg"])) / float(affine["pixel_height_deg"])
		if not is_finite(column_position) or not is_finite(row_position):
			return {"ok": false, "error": "WorldCover affine inverse produced non-finite indices"}
		var column := clampi(int(round(column_position)), 0, columns - 1)
		var row := clampi(int(round(row_position)), 0, rows - 1)
		var class_code := int(values[row * columns + column])
		colors[vertex_index] = _landcover_class_color(class_code)
		class_counts[class_code] = int(class_counts.get(class_code, 0)) + 1
	return {"ok": true, "error": "", "has_landcover": true, "colors": colors, "class_counts": class_counts}

static func _landcover_class_color(class_code: int) -> Color:
	match class_code:
		10:
			return Color(0.20, 0.42, 0.18, 1.0)
		20:
			return Color(0.34, 0.48, 0.22, 1.0)
		30:
			return Color(0.48, 0.58, 0.27, 1.0)
		40:
			return Color(0.68, 0.57, 0.28, 1.0)
		50:
			return Color(0.52, 0.51, 0.49, 1.0)
		60:
			return Color(0.56, 0.54, 0.37, 1.0)
		70:
			return Color(0.86, 0.91, 0.96, 1.0)
		80:
			return Color(0.22, 0.42, 0.61, 1.0)
		90:
			return Color(0.29, 0.50, 0.38, 1.0)
		95:
			return Color(0.20, 0.44, 0.33, 1.0)
		100:
			return Color(0.58, 0.62, 0.48, 1.0)
		_:
			return Color(0.34, 0.43, 0.31, 1.0)

static func _select_axis(length: int, factor: int, global_offset: int) -> Array[int]:
	var selected: Array[int] = [0]
	for index in range(1, length - 1):
		if posmod(global_offset + index, factor) == 0:
			selected.append(index)
	if length > 1:
		selected.append(length - 1)
	return selected

static func _append_native_grid(rows: int, columns: int, vertices: PackedVector3Array, normals: PackedVector3Array, valid: PackedByteArray, indices: PackedInt32Array, faces: PackedVector3Array) -> void:
	for row in range(rows - 1):
		for column in range(columns - 1):
			var nw := row * columns + column
			var ne := nw + 1
			var sw := nw + columns
			var se := sw + 1
			if valid[nw] == 0 or valid[ne] == 0 or valid[sw] == 0 or valid[se] == 0:
				continue
			_add_upward_triangle(nw, se, sw, vertices, normals, indices, faces)
			_add_upward_triangle(nw, ne, se, vertices, normals, indices, faces)

static func _append_lod_macro(r0: int, r1: int, c0: int, c1: int, rows: int, columns: int, vertices: PackedVector3Array, normals: PackedVector3Array, valid: PackedByteArray, indices: PackedInt32Array, faces: PackedVector3Array) -> void:
	var all_valid := true
	for row in range(r0, r1 + 1):
		for column in range(c0, c1 + 1):
			if valid[row * columns + column] == 0:
				all_valid = false
				break
		if not all_valid:
			break
	var row_span := r1 - r0
	var column_span := c1 - c0
	if not all_valid or row_span < 2 or column_span < 2:
		for row in range(r0, r1):
			for column in range(c0, c1):
				var nw := row * columns + column
				var ne := nw + 1
				var sw := nw + columns
				var se := sw + 1
				if valid[nw] == 0 or valid[ne] == 0 or valid[sw] == 0 or valid[se] == 0:
					continue
				_add_upward_triangle(nw, se, sw, vertices, normals, indices, faces)
				_add_upward_triangle(nw, ne, se, vertices, normals, indices, faces)
		return
	var center_row := r0 + (row_span >> 1)
	var center_column := c0 + (column_span >> 1)
	var center_index := center_row * columns + center_column
	if center_row <= r0 or center_row >= r1 or center_column <= c0 or center_column >= c1 or valid[center_index] == 0:
		_append_native_region(r0, r1, c0, c1, columns, vertices, normals, valid, indices, faces)
		return
	var perimeter: Array[int] = []
	for column in range(c0, c1 + 1):
		perimeter.append(r0 * columns + column)
	for row in range(r0 + 1, r1 + 1):
		perimeter.append(row * columns + c1)
	for column in range(c1 - 1, c0 - 1, -1):
		perimeter.append(r1 * columns + column)
	for row in range(r1 - 1, r0, -1):
		perimeter.append(row * columns + c0)
	for perimeter_index in range(perimeter.size()):
		var first := perimeter[perimeter_index]
		var second := perimeter[(perimeter_index + 1) % perimeter.size()]
		_add_upward_triangle(center_index, first, second, vertices, normals, indices, faces)

static func _append_native_region(r0: int, r1: int, c0: int, c1: int, columns: int, vertices: PackedVector3Array, normals: PackedVector3Array, valid: PackedByteArray, indices: PackedInt32Array, faces: PackedVector3Array) -> void:
	for row in range(r0, r1):
		for column in range(c0, c1):
			var nw := row * columns + column
			var ne := nw + 1
			var sw := nw + columns
			var se := sw + 1
			if valid[nw] == 0 or valid[ne] == 0 or valid[sw] == 0 or valid[se] == 0:
				continue
			_add_upward_triangle(nw, se, sw, vertices, normals, indices, faces)
			_add_upward_triangle(nw, ne, se, vertices, normals, indices, faces)

static func _add_upward_triangle(a: int, b: int, c: int, vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, faces: PackedVector3Array) -> void:
	var first := a
	var second := b
	var third := c
	var normal := (vertices[second] - vertices[first]).cross(vertices[third] - vertices[first])
	if not is_finite(normal.x) or not is_finite(normal.y) or not is_finite(normal.z) or normal.length_squared() <= DEGENERATE_TRIANGLE_AREA_SQUARED:
		return
	if normal.y < 0.0:
		var swap := second
		second = third
		third = swap
		normal = -normal
	indices.append(first)
	indices.append(second)
	indices.append(third)
	faces.append(vertices[first])
	faces.append(vertices[second])
	faces.append(vertices[third])
	normals[first] += normal
	normals[second] += normal
	normals[third] += normal

static func _append_boundary_support(
		boundary_features: Variant,
		rows: int,
		columns: int,
		lonlat: PackedFloat64Array,
		heights: PackedFloat64Array,
		valid: PackedByteArray,
		vertices: PackedVector3Array,
		normals: PackedVector3Array,
		indices: PackedInt32Array,
		faces: PackedVector3Array,
		tile_origin: Dictionary,
		bounds: Dictionary
	) -> Dictionary:
	if typeof(boundary_features) != TYPE_ARRAY:
		return _failure("terrain boundary_support_features must be an array")
	if boundary_features.is_empty():
		return {"ok": true, "error": "", "counts": {}, "status": "partial_missing_edges", "missing_edges": ["north", "east", "south", "west"], "edge_data": {}, "boundary_vertex_count": 0}
	var groups: Dictionary = {"north": [], "east": [], "south": [], "west": []}
	var seen_ids: Dictionary = {}
	for feature_value in boundary_features:
		if typeof(feature_value) != TYPE_DICTIONARY:
			return _failure("terrain boundary-support record is malformed")
		var feature: Dictionary = feature_value
		var feature_id := String(feature.get("id", ""))
		var edge := String(feature.get("edge", ""))
		if not groups.has(edge) or feature_id.is_empty() or seen_ids.has(feature_id):
			return _failure("terrain boundary feature has an invalid edge or duplicate ID")
		seen_ids[feature_id] = true
		groups[edge].append(feature)
	var sample_data := {"north": PackedFloat64Array(), "east": PackedFloat64Array(), "south": PackedFloat64Array(), "west": PackedFloat64Array()}
	var edge_masks := {"north": PackedByteArray(), "east": PackedByteArray(), "south": PackedByteArray(), "west": PackedByteArray()}
	var edge_tids := {"north": PackedInt32Array(), "east": PackedInt32Array(), "south": PackedInt32Array(), "west": PackedInt32Array()}
	var edge_tid_valid := {"north": PackedByteArray(), "east": PackedByteArray(), "south": PackedByteArray(), "west": PackedByteArray()}
	var edge_geoid_masks := {"north": PackedByteArray(), "east": PackedByteArray(), "south": PackedByteArray(), "west": PackedByteArray()}
	var counts: Dictionary = {}
	var vertex_start := vertices.size()
	for edge in ["north", "east", "south", "west"]:
		var features: Array = groups[edge]
		if features.is_empty():
			continue
		features.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return int(left.get("edge_index", -1)) < int(right.get("edge_index", -1)))
		var declared_count := int(features[0].get("edge_sample_count", 0))
		var polar_edge: bool = (edge == "north" and float(bounds["north_deg"]) == 90.0) or (edge == "south" and float(bounds["south_deg"]) == -90.0)
		var required_count := 1 if polar_edge else 2
		if declared_count != features.size() or declared_count < required_count or (polar_edge and declared_count != 1):
			return _failure("terrain boundary edge %s has incomplete or invalid declared sample coverage" % edge)
		for sample_index in range(features.size()):
			var support_feature: Dictionary = features[sample_index]
			if int(support_feature.get("edge_index", -1)) != sample_index or int(support_feature.get("edge_sample_count", -1)) != declared_count:
				return _failure("terrain boundary edge %s has noncanonical edge_index coverage" % edge)
			var feature_id := String(support_feature.get("id", ""))
			if feature_id != "boundary:%s:%d" % [edge, sample_index]:
				return _failure("terrain boundary edge %s has an unstable feature ID" % edge)
		var core_order := _core_edge_indices(edge, rows, columns)
		if core_order.size() < 2:
			return _failure("terrain source grid has no samples along boundary edge %s" % edge)
		if polar_edge:
			var support_feature: Dictionary = features[0]
			var target_longitude := float(support_feature.get("longitude_deg", NAN))
			var target_latitude := float(support_feature.get("latitude_deg", NAN))
			var target_height := float(support_feature.get("ellipsoidal_height_m", NAN))
			var expected_latitude := 90.0 if edge == "north" else -90.0
			if target_longitude != 0.0 or target_latitude != expected_latitude or not is_finite(target_height):
				return _failure("polar edge requires the single canonical longitude-zero pole support vertex")
			var target_ecef := LocalFrame.geodetic_to_ecef_components(target_latitude, target_longitude, target_height, LocalFrame.CRS_GEOGRAPHIC_2D, LocalFrame.ELLIPSOIDAL_DATUM, "ellipsoidal")
			if not target_ecef.get("ok", false):
				return _failure(String(target_ecef.get("error", "pole support cannot be represented as WGS84 ECEF")))
			var target_local := LocalFrame.ecef_to_local(target_ecef["ecef_m"], tile_origin)
			if not target_local.get("ok", false):
				return _failure(String(target_local.get("error", "pole support is outside the current tangent frame")))
			var pole_vertex_index := vertices.size()
			vertices.append(target_local["local_engine_m"])
			normals.append(Vector3.ZERO)
			valid.append(1)
			var output_samples: PackedFloat64Array = sample_data[edge]
			output_samples.append(target_longitude)
			output_samples.append(target_latitude)
			output_samples.append(target_height)
			var support: Dictionary = support_feature.get("support", {})
			var tid_value: Variant = support.get("type_identifier_mask")
			var output_masks: PackedByteArray = edge_masks[edge]
			output_masks.append(int(support.get("source_mask", 0)))
			output_masks.append(int(support.get("quality_mask", 0)))
			edge_tids[edge].append(-1 if tid_value == null else int(tid_value))
			edge_tid_valid[edge].append(0 if tid_value == null else 1)
			edge_geoid_masks[edge].append(int(support.get("geoid_mask", 0)))
			var fan_row := 0 if edge == "north" else rows - 1
			var found_valid_row := false
			for row_offset in range(rows):
				var candidate_row := row_offset if edge == "north" else rows - 1 - row_offset
				var row_has_valid := false
				for column in range(columns):
					if valid[candidate_row * columns + column] == 1:
						row_has_valid = true
						break
				if row_has_valid:
					fan_row = candidate_row
					found_valid_row = true
					break
			if not found_valid_row:
				return _failure("polar support cannot connect to a valid raster row")
			for column in range(columns - 1):
				var first_index := fan_row * columns + column
				var second_index := first_index + 1
				if valid[first_index] == 0 or valid[second_index] == 0:
					continue
				_add_upward_triangle(first_index, second_index, pole_vertex_index, vertices, normals, indices, faces)
			counts[edge] = 1
			continue
		var boundary_vertex_indices: Array[int] = []
		var core_vertex_indices: Array[int] = []
		var previous_core_index := -1
		for sample_index in range(features.size()):
			var support_feature: Dictionary = features[sample_index]
			var support: Dictionary = support_feature.get("support", {})
			var source_longitude := float(support.get("source_sample_longitude", NAN))
			var source_latitude := float(support.get("source_sample_latitude", NAN))
			var target_longitude := float(support_feature.get("longitude_deg", NAN))
			var target_latitude := float(support_feature.get("latitude_deg", NAN))
			var target_height := float(support_feature.get("ellipsoidal_height_m", NAN))
			if not is_finite(source_longitude) or not is_finite(source_latitude) or not is_finite(target_longitude) or not is_finite(target_latitude) or not is_finite(target_height):
				return _failure("terrain boundary support has non-finite source or target coordinates")
			var along_coordinate := source_longitude if edge in ["north", "south"] else source_latitude
			var nearest_core_order := 0
			var nearest_delta := INF
			for core_order_index in range(core_order.size()):
				var candidate_index := int(core_order[core_order_index])
				var candidate_coordinate := lonlat[candidate_index * 2] if edge in ["north", "south"] else lonlat[candidate_index * 2 + 1]
				var delta := absf(candidate_coordinate - along_coordinate)
				if delta < nearest_delta:
					nearest_delta = delta
					nearest_core_order = core_order_index
			var core_index := int(core_order[nearest_core_order])
			if core_index == previous_core_index:
				return _failure("boundary support samples map to duplicate native edge vertices on %s" % edge)
			previous_core_index = core_index
			var target_ecef := LocalFrame.geodetic_to_ecef_components(target_latitude, target_longitude, target_height, LocalFrame.CRS_GEOGRAPHIC_2D, LocalFrame.ELLIPSOIDAL_DATUM, "ellipsoidal")
			if not target_ecef.get("ok", false):
				return _failure(String(target_ecef.get("error", "boundary support target cannot be represented as WGS84 ECEF")))
			var target_local := LocalFrame.ecef_to_local(target_ecef["ecef_m"], tile_origin)
			if not target_local.get("ok", false):
				return _failure(String(target_local.get("error", "boundary support target is outside the local tangent domain")))
			var target_vertex_index := vertices.size()
			vertices.append(target_local["local_engine_m"])
			normals.append(Vector3.ZERO)
			valid.append(1)
			boundary_vertex_indices.append(target_vertex_index)
			core_vertex_indices.append(core_index)
			sample_data[edge].append(target_longitude)
			sample_data[edge].append(target_latitude)
			sample_data[edge].append(target_height)
			edge_masks[edge].append(int(support.get("source_mask", 0)))
			edge_masks[edge].append(int(support.get("quality_mask", 0)))
			var tid_value: Variant = support.get("type_identifier_mask")
			edge_tids[edge].append(-1 if tid_value == null else int(tid_value))
			edge_tid_valid[edge].append(0 if tid_value == null else 1)
			edge_geoid_masks[edge].append(int(support.get("geoid_mask", 0)))
		counts[edge] = declared_count
		for sample_index in range(boundary_vertex_indices.size() - 1):
			_add_upward_triangle(core_vertex_indices[sample_index], core_vertex_indices[sample_index + 1], boundary_vertex_indices[sample_index], vertices, normals, indices, faces)
			_add_upward_triangle(core_vertex_indices[sample_index + 1], boundary_vertex_indices[sample_index + 1], boundary_vertex_indices[sample_index], vertices, normals, indices, faces)
	var edge_data := _make_boundary_edge_data(sample_data, edge_masks, edge_tids, edge_tid_valid, edge_geoid_masks)
	var missing_edges: Array[String] = []
	for edge in ["north", "east", "south", "west"]:
		var required_count := 1 if ((edge == "north" and float(bounds["north_deg"]) == 90.0) or (edge == "south" and float(bounds["south_deg"]) == -90.0)) else 2
		if groups[edge].size() < required_count:
			missing_edges.append(edge)
	var status := "complete" if missing_edges.is_empty() else "partial_missing_edges"
	return {"ok": true, "error": "", "counts": counts, "status": status, "missing_edges": missing_edges, "edge_data": edge_data, "boundary_vertex_count": vertices.size() - vertex_start}

static func _core_edge_indices(edge: String, rows: int, columns: int) -> Array[int]:
	var result: Array[int] = []
	match edge:
		"north":
			for column in range(columns):
				result.append(column)
		"east":
			for row in range(rows):
				result.append(row * columns + columns - 1)
		"south":
			for column in range(columns - 1, -1, -1):
				result.append((rows - 1) * columns + column)
		"west":
			for row in range(rows - 1, -1, -1):
				result.append(row * columns)
	return result

static func _make_boundary_edge_data(samples: Dictionary, masks: Dictionary, tids: Dictionary, tid_valid: Dictionary, geoid_masks: Dictionary) -> Dictionary:
	var hashes: Dictionary = {}
	for edge in samples:
		var edge_values: PackedFloat64Array = samples[edge]
		if edge_values.is_empty():
			continue
		var hash_context := HashingContext.new()
		hash_context.start(HashingContext.HASH_SHA256)
		var stream := StreamPeerBuffer.new()
		stream.big_endian = false
		for value in edge_values:
			stream.put_double(value)
		hash_context.update(stream.data_array)
		hash_context.update(masks[edge])
		var tid_stream := StreamPeerBuffer.new()
		tid_stream.big_endian = false
		for tid_value in tids[edge]:
			tid_stream.put_32(int(tid_value))
		hash_context.update(tid_stream.data_array)
		hash_context.update(tid_valid[edge])
		hash_context.update(geoid_masks[edge])
		hashes[edge] = hash_context.finish().hex_encode()
	return {"hashes": hashes, "samples": samples, "valid_masks": masks, "type_identifier_masks": tids, "type_identifier_valid": tid_valid, "geoid_masks": geoid_masks, "support_source": "terrain_boundary_support GeoJSON; null TID stored as -1 plus type_identifier_valid=0"}

static func _extract_edges(rows: int, columns: int, lonlat: PackedFloat64Array, heights: PackedFloat64Array, valid: PackedByteArray) -> Dictionary:
	var samples := {"north": PackedFloat64Array(), "south": PackedFloat64Array(), "west": PackedFloat64Array(), "east": PackedFloat64Array()}
	var masks := {"north": PackedByteArray(), "south": PackedByteArray(), "west": PackedByteArray(), "east": PackedByteArray()}
	for column in range(columns):
		_append_edge_sample("north", column, lonlat, heights, valid, samples, masks)
		_append_edge_sample("south", (rows - 1) * columns + column, lonlat, heights, valid, samples, masks)
	for row in range(rows):
		_append_edge_sample("west", row * columns, lonlat, heights, valid, samples, masks)
		_append_edge_sample("east", row * columns + columns - 1, lonlat, heights, valid, samples, masks)
	var hashes: Dictionary = {}
	for side in ["north", "south", "west", "east"]:
		var context := HashingContext.new()
		context.start(HashingContext.HASH_SHA256)
		var buffer := StreamPeerBuffer.new()
		buffer.big_endian = false
		for component in samples[side]:
			buffer.put_double(component)
		context.update(buffer.data_array)
		context.update(masks[side])
		hashes[side] = context.finish().hex_encode()
	return {"samples": samples, "valid_masks": masks, "hashes": hashes}

static func _append_edge_sample(side: String, sample_index: int, lonlat: PackedFloat64Array, heights: PackedFloat64Array, valid: PackedByteArray, samples: Dictionary, masks: Dictionary) -> void:
	var edge: PackedFloat64Array = samples[side]
	var edge_mask: PackedByteArray = masks[side]
	edge.append(lonlat[sample_index * 2])
	edge.append(lonlat[sample_index * 2 + 1])
	edge.append(heights[sample_index] if valid[sample_index] == 1 else 0.0)
	edge_mask.append(valid[sample_index])
	samples[side] = edge
	masks[side] = edge_mask

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
