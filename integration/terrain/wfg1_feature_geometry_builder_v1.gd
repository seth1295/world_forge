class_name Wfg1FeatureGeometryBuilderV1
extends RefCounted

## Main-thread, source-ID-preserving geographic feature mesh builder.
## It reads and releases one â‰¤16 MiB GeoJSON shard at a time and creates at
## most one mesh node per shard/layer, never one scene node per source feature.
const Address := preload("res://terrain/wfg1_tile_address.gd")
const LocalFrame := preload("res://terrain/wfg1_local_frame.gd")
const RasterTransform := preload("res://terrain/wfg1_raster_geotransform_v1.gd")
const MAX_SHARD_BYTES := 16 * 1024 * 1024
const MAX_DECODED_GEOMETRY_BYTES := 4 * 1024 * 1024 * 1024
const MAX_VECTOR_COORDINATE_POSITIONS := 50_000_000
const MAX_VECTOR_FEATURES := 2_000_000
const MAX_MESH_VERTICES := 50_000_000
const DEFAULT_ROAD_WIDTH_M := 5.0
const DEFAULT_BUILDING_HEIGHT_M := 6.0
const ROAD_RENDER_LIFT_M := 0.025

static func build_nodes(decoded: Dictionary, context: Dictionary, renderer_config: Dictionary = {}) -> Dictionary:
	var tile_id := String(context.get("tile_id", ""))
	var address_result := Address.parse_id(tile_id)
	if not address_result.get("ok", false):
		return _failure("feature geometry builder requires a canonical WFG-1 address")
	if typeof(decoded.get("terrain")) != TYPE_DICTIONARY:
		return _failure("source features require the validated terrain sample grid")
	var origin: Variant = context.get("tile_origin")
	if typeof(origin) != TYPE_DICTIONARY or not LocalFrame.validate_frame(origin).get("ok", false):
		return _failure("feature geometry builder requires a consistent WGS84 tile tangent frame")
	var terrain: Dictionary = decoded["terrain"]
	var terrain_error := _validate_terrain(terrain)
	if not terrain_error.is_empty():
		return _failure(terrain_error)
	var payloads_by_layer: Variant = decoded.get("vector_payloads_by_layer", {})
	if typeof(payloads_by_layer) != TYPE_DICTIONARY:
		return _failure("provider did not return bounded vector-shard descriptors")
	var root := Node3D.new()
	root.name = "GeographicFeatures_%s" % tile_id.replace(":", "_")
	root.set_meta("wfg1_tile_id", tile_id)
	root.set_meta("source_geometry_coordinate_reference", "EPSG:4326 WGS84 longitude/latitude; source feature height absent unless explicitly declared")
	root.set_meta("feature_rendering_styles", {
		"road_default_width_m": DEFAULT_ROAD_WIDTH_M,
		"road_render_lift_m": ROAD_RENDER_LIFT_M,
		"building_default_height_m": DEFAULT_BUILDING_HEIGHT_M,
		"dimensions_are_observed": false,
		"source_provided_width_or_height_used_when_explicit": true
	})
	var included_layers := PackedStringArray()
	var render_outcomes: Dictionary = {}
	var counts: Dictionary = {}
	var total_decoded_bytes := int(decoded.get("initial_decoded_geometry_bytes", 0))
	if total_decoded_bytes < 0 or total_decoded_bytes > MAX_DECODED_GEOMETRY_BYTES:
		root.free()
		return _failure("initial boundary geometry exceeds the 4 GiB consumer budget")
	for layer_id in ["roads", "buildings", "water"]:
		var layer_payloads: Variant = payloads_by_layer.get(layer_id, [])
		if typeof(layer_payloads) != TYPE_ARRAY:
			root.free()
			return _failure("%s payload list is not an array" % layer_id)
		var layer_result := _build_layer(layer_id, layer_payloads, terrain, origin, address_result["address"], renderer_config, total_decoded_bytes)
		if not layer_result.get("ok", false):
			root.free()
			return layer_result
		total_decoded_bytes = int(layer_result["total_decoded_bytes"])
		counts[layer_id] = layer_result["counts"]
		if layer_result.get("node") is Node3D:
			root.add_child(layer_result["node"])
			included_layers.append(layer_id)
		if layer_result.has("render_outcome") and typeof(layer_result["render_outcome"]) == TYPE_DICTIONARY and not layer_result["render_outcome"].is_empty():
			render_outcomes[layer_id] = layer_result["render_outcome"].duplicate(true)
	root.set_meta("source_feature_counts_and_placement", counts)
	root.set_meta("layer_render_outcome_overrides", render_outcomes.duplicate(true))
	root.set_meta("decoded_geometry_bytes", total_decoded_bytes)
	var feature_root: Node3D = root if not root.get_children().is_empty() else null
	if feature_root == null:
		root.free()
	return {
		"ok": true,
		"error": "",
		"node": feature_root,
		"included_layers": included_layers,
		"collision_ready": false,
		"layer_outcome_overrides": render_outcomes,
		"feature_counts_and_placement": counts,
		"decoded_geometry_bytes": total_decoded_bytes
	}

static func _build_layer(layer_id: String, payloads: Array, terrain: Dictionary, origin: Dictionary, address: Dictionary, renderer_config: Dictionary, decoded_before: int) -> Dictionary:
	if payloads.size() > 65_536:
		return _failure("%s exceeds the configured GeoJSON shard-count limit" % layer_id)
	var root := Node3D.new()
	root.name = layer_id.capitalize() + "SourceGeometry"
	var expected_features := 0
	var built_features := 0
	var excluded_for_vertical := 0
	var unsupported_geometry_count := 0
	var unplaced_water := 0
	var decoded_bytes := decoded_before
	var layer_coordinate_positions := 0
	var shard_index := 0
	for payload_value in payloads:
		if typeof(payload_value) != TYPE_DICTIONARY:
			root.free()
			return _failure("%s payload path record is malformed" % layer_id)
		var payload: Dictionary = payload_value
		var descriptor: Dictionary = payload.get("descriptor", {})
		var path := String(payload.get("path", ""))
		if path.is_empty() or not FileAccess.file_exists(path):
			root.free()
			return _failure("%s source GeoJSON shard is missing" % layer_id)
		var input := FileAccess.open(path, FileAccess.READ)
		if input == null:
			root.free()
			return _failure("%s source GeoJSON shard cannot be opened" % layer_id)
		var byte_length := input.get_length()
		if byte_length < 1 or byte_length > MAX_SHARD_BYTES:
			input.close()
			root.free()
			return _failure("%s source GeoJSON shard exceeds the 16 MiB per-shard limit" % layer_id)
		decoded_bytes += byte_length
		if decoded_bytes > MAX_DECODED_GEOMETRY_BYTES:
			input.close()
			root.free()
			return _failure("decoded geographic geometry exceeds the 4 GiB finite consumer limit")
		var bytes := input.get_buffer(byte_length)
		input.close()
		if bytes.size() != byte_length or TerrainGridHashV1.sha256_bytes(bytes) != String(descriptor.get("sha256", "")):
			root.free()
			return _failure("%s GeoJSON shard changed after provider validation" % layer_id)
		var parsed := JSON.new()
		if parsed.parse(bytes.get_string_from_utf8()) != OK or typeof(parsed.data) != TYPE_DICTIONARY:
			root.free()
			return _failure("%s shard is not valid GeoJSON" % layer_id)
		bytes.clear()
		var collection: Dictionary = parsed.data
		if String(collection.get("type", "")) != "FeatureCollection" or typeof(collection.get("features")) != TYPE_ARRAY:
			root.free()
			return _failure("%s shard must contain an RFC 7946 FeatureCollection" % layer_id)
		var features: Array = collection["features"]
		if features.size() != int(descriptor.get("feature_count", -1)):
			root.free()
			return _failure("%s GeoJSON shard feature count changed after provider validation" % layer_id)
		expected_features += features.size()
		if expected_features > MAX_VECTOR_FEATURES:
			root.free()
			return _failure("%s exceeds the configured 2M source feature limit" % layer_id)
		var vertices := PackedVector3Array()
		var indices := PackedInt32Array()
		var feature_index: Array[Dictionary] = []
		for feature_value in features:
			if typeof(feature_value) != TYPE_DICTIONARY:
				root.free()
				return _failure("%s shard contains a non-object feature" % layer_id)
			var feature: Dictionary = feature_value
			var source_id := String(feature.get("id", ""))
			if source_id.strip_edges().is_empty():
				root.free()
				return _failure("%s feature is missing its stable source ID" % layer_id)
			var geometry: Variant = feature.get("geometry")
			var properties: Dictionary = feature.get("properties", {}) if typeof(feature.get("properties")) == TYPE_DICTIONARY else {}
			var worldforge: Dictionary = properties.get("worldforge", {}) if typeof(properties.get("worldforge")) == TYPE_DICTIONARY else {}
			var fragment_id := String(worldforge.get("fragment_id", ""))
			if fragment_id.is_empty():
				root.free()
				return _failure("%s source feature %s lacks its stable WorldForge fragment ID" % [layer_id, source_id])
			if typeof(geometry) != TYPE_DICTIONARY:
				root.free()
				return _failure("%s source feature %s has no geometry" % [layer_id, source_id])
			var geometry_type := String(geometry.get("type", ""))
			var coordinates: Variant = geometry.get("coordinates")
			var position_count := _count_coordinate_positions(coordinates)
			if position_count < 0:
				root.free()
				return _failure("%s feature %s has malformed or non-2D coordinates" % [layer_id, source_id])
			layer_coordinate_positions += position_count
			if layer_coordinate_positions > MAX_VECTOR_COORDINATE_POSITIONS:
				root.free()
				return _failure("%s exceeds the configured 50M coordinate-position limit" % layer_id)
			# Consumer budget is serialized shard bytes + 64 bytes per decoded
			# coordinate position + 128 bytes per feature record.
			decoded_bytes += position_count * 64 + 128
			if decoded_bytes > MAX_DECODED_GEOMETRY_BYTES:
				root.free()
				return _failure("decoded geometry exceeds the 4 GiB consumer budget")
			var previous_vertex_count := vertices.size()
			var previous_index_count := indices.size()
			var render_result: Dictionary
			match layer_id:
				"roads":
					render_result = _append_road_geometry(geometry_type, coordinates, properties, terrain, origin, address, vertices, indices)
				"buildings":
					render_result = _append_polygon_geometry(layer_id, geometry_type, coordinates, properties, terrain, origin, address, vertices, indices, DEFAULT_BUILDING_HEIGHT_M)
				"water":
					render_result = _append_water_geometry(geometry_type, coordinates, properties, terrain, origin, address, vertices, indices)
				_:
					render_result = _failure("unsupported feature layer ID")
			if not render_result.get("ok", false):
				if layer_id == "water" and bool(render_result.get("unavailable_surface", false)):
					vertices.resize(previous_vertex_count)
					indices.resize(previous_index_count)
					unplaced_water += 1
					continue
				if bool(render_result.get("terrain_unavailable", false)):
					vertices.resize(previous_vertex_count)
					indices.resize(previous_index_count)
					excluded_for_vertical += 1
					continue
				if bool(render_result.get("unsupported_geometry", false)):
					vertices.resize(previous_vertex_count)
					indices.resize(previous_index_count)
					unsupported_geometry_count += 1
					continue
				root.free()
				return _failure("%s feature %s geometry rejected: %s" % [layer_id, source_id, String(render_result.get("error", "unknown geometry error"))])
			var added_vertices := vertices.size() - previous_vertex_count
			if added_vertices > 0:
				built_features += 1
				feature_index.append({"source_id": source_id, "fragment_id": fragment_id, "vertex_begin": previous_vertex_count, "vertex_count": added_vertices, "render_style": render_result.get("render_style", {})})
			if vertices.size() > MAX_MESH_VERTICES:
				root.free()
				return _failure("%s decoded mesh exceeds the configured 50M vertex safety limit" % layer_id)
		if not vertices.is_empty() and not indices.is_empty():
			var mesh_instance := _make_shard_mesh(layer_id, shard_index, vertices, indices)
			if mesh_instance == null:
				root.free()
				return _failure("%s source geometry did not produce a valid mesh" % layer_id)
			mesh_instance.set_meta("source_payload_path", String(payload.get("relative_path", "")))
			mesh_instance.set_meta("source_payload_sha256", String(descriptor.get("sha256", "")))
			mesh_instance.set_meta("source_feature_count", features.size())
			mesh_instance.set_meta("source_feature_vertex_index", feature_index)
			mesh_instance.set_meta("source_layer", layer_id)
			mesh_instance.set_meta("rendering_style", "procedural style dimensions are separate from Overture source facts")
			root.add_child(mesh_instance)
		shard_index += 1
	var outcome_override: Dictionary = {}
	if unsupported_geometry_count > 0:
		outcome_override = {"status": "partial", "gap_declared": true, "gap_reason": "%d source polygons include interior rings without a validated hole-aware renderer" % unsupported_geometry_count, "disclosure": "Features with interior rings were retained in source GeoJSON and deliberately not rendered; polygon holes are not filled or simplified into false building/water areas."}
	if excluded_for_vertical > 0:
		outcome_override["status"] = "partial"
		outcome_override["gap_declared"] = true
		outcome_override["gap_reason"] = "%d source features could not be draped to valid ellipsoidal terrain samples" % excluded_for_vertical
		outcome_override["disclosure"] = String(outcome_override.get("disclosure", "")) + " Some source features remain unrendered because validated terrain sampling coverage does not include every feature coordinate."
	if unplaced_water > 0:
		outcome_override["status"] = "partial"
		outcome_override["gap_declared"] = true
		outcome_override["gap_reason"] = "%d water features lack an authorized surface-height source" % unplaced_water
		outcome_override["disclosure"] = String(outcome_override.get("disclosure", "")) + " Water geometry without source-provided inland level or a typed open-water rule was left unplaced; no ellipsoid-zero plane was invented."
	var layer_root: Node3D = root if not root.get_children().is_empty() else null
	if layer_root == null:
		root.free()
	return {"ok": true, "error": "", "node": layer_root, "counts": {"query_feature_count": expected_features, "rendered_feature_count": built_features, "terrain_unavailable_feature_count": excluded_for_vertical, "water_without_surface_count": unplaced_water, "decoded_geometry_bytes": decoded_bytes, "coordinate_positions": layer_coordinate_positions}, "total_decoded_bytes": decoded_bytes, "render_outcome": outcome_override}

static func _append_road_geometry(geometry_type: String, coordinates: Variant, properties: Dictionary, terrain: Dictionary, origin: Dictionary, address: Dictionary, vertices: PackedVector3Array, indices: PackedInt32Array) -> Dictionary:
	if geometry_type not in ["LineString", "MultiLineString"] or typeof(coordinates) != TYPE_ARRAY:
		return _failure("roads must be 2D LineString/MultiLineString geometry")
	var lines: Array = [coordinates] if geometry_type == "LineString" else coordinates
	var source_width := _source_dimension_m(properties, ["width_m", "road_width_m"])
	var width_m: float = float(source_width["value_m"]) if source_width.get("ok", false) else DEFAULT_ROAD_WIDTH_M
	if not is_finite(width_m) or width_m <= 0.0 or width_m > 200.0:
		return _failure("road source/style width is outside the supported range")
	for line_value in lines:
		if typeof(line_value) != TYPE_ARRAY or line_value.size() < 2:
			return _failure("road line component requires at least two coordinates")
		var points_result := _terrain_local_points(line_value, terrain, origin, address, "terrain")
		if not points_result.get("ok", false):
			return points_result
		var points: Array[Vector3] = points_result["points"]
		var ups: Array[Vector3] = points_result["surface_normals"]
		for point_index in range(points.size() - 1):
			var first: Vector3 = points[point_index]
			var second: Vector3 = points[point_index + 1]
			var direction := Vector2(second.x - first.x, second.z - first.z)
			if direction.length_squared() <= 1.0e-12:
				continue
			var first_up: Vector3 = ups[point_index].normalized()
			var second_up: Vector3 = ups[point_index + 1].normalized()
			var surface_up := (first_up + second_up).normalized()
			var tangent := Vector3(direction.x, second.y - first.y, direction.y).normalized()
			var side: Vector3 = surface_up.cross(tangent).normalized() * width_m * 0.5
			var first_lift := first_up * ROAD_RENDER_LIFT_M
			var second_lift := second_up * ROAD_RENDER_LIFT_M
			_append_quad(vertices, indices, first + side + first_lift, first - side + first_lift, second + side + second_lift, second - side + second_lift)
	return {"ok": true, "error": "", "render_style": {"road_width_m": width_m, "width_provenance": "source property" if source_width.get("ok", false) else "procedural render style", "lift_m": ROAD_RENDER_LIFT_M}}

static func _append_polygon_geometry(layer_id: String, geometry_type: String, coordinates: Variant, properties: Dictionary, terrain: Dictionary, origin: Dictionary, address: Dictionary, vertices: PackedVector3Array, indices: PackedInt32Array, default_height_m: float) -> Dictionary:
	if geometry_type not in ["Polygon", "MultiPolygon"] or typeof(coordinates) != TYPE_ARRAY:
		return _failure("%s requires 2D Polygon/MultiPolygon geometry" % layer_id)
	var polygons: Array = [coordinates] if geometry_type == "Polygon" else coordinates
	var source_height := _source_dimension_m(properties, ["height_m", "building_height_m"])
	var height_m := float(source_height["value_m"]) if source_height.get("ok", false) else default_height_m
	if height_m < 0.0 or height_m > 1000.0:
		return _failure("building source/style height is outside the supported range")
	for polygon_value in polygons:
		if typeof(polygon_value) != TYPE_ARRAY or polygon_value.is_empty():
			return _failure("polygon has no exterior ring")
		if polygon_value.size() > 1:
			return {"ok": false, "unsupported_geometry": true, "error": "polygon has interior rings; hole-aware surface triangulation is not implemented"}
		var exterior: Variant = polygon_value[0]
		if typeof(exterior) != TYPE_ARRAY or exterior.size() < 4:
			return _failure("polygon exterior ring requires at least four coordinates")
		var points_result := _terrain_local_points(exterior, terrain, origin, address, "terrain")
		if not points_result.get("ok", false):
			return points_result
		var points: Array[Vector3] = points_result["points"]
		var surface_normals: Array[Vector3] = points_result["surface_normals"]
		if points.size() < 4:
			return _failure("polygon exterior ring is too short after closure validation")
		var ring_count := points.size() - 1 if points.front().distance_to(points.back()) <= 0.01 else points.size()
		if ring_count < 3:
			return _failure("polygon exterior ring has fewer than three unique vertices")
		var polygon_2d := PackedVector2Array()
		for point_index in range(ring_count):
			polygon_2d.append(Vector2(points[point_index].x, points[point_index].z))
		var top_start := vertices.size()
		for point_index in range(ring_count):
			vertices.append(points[point_index] + surface_normals[point_index] * height_m)
		var triangles := Geometry2D.triangulate_polygon(polygon_2d)
		if triangles.is_empty():
			return _failure("building polygon could not be triangulated")
		for triangle_index in range(0, triangles.size(), 3):
			indices.append(top_start + triangles[triangle_index])
			indices.append(top_start + triangles[triangle_index + 1])
			indices.append(top_start + triangles[triangle_index + 2])
		for point_index in range(ring_count):
			var next_index := (point_index + 1) % ring_count
			_append_quad(vertices, indices, points[point_index], points[next_index], points[point_index] + surface_normals[point_index] * height_m, points[next_index] + surface_normals[next_index] * height_m)
	return {"ok": true, "error": "", "render_style": {"building_height_m": height_m, "height_provenance": "source property" if source_height.get("ok", false) else "procedural render style", "interior_holes_used": false}}

static func _append_water_geometry(geometry_type: String, coordinates: Variant, properties: Dictionary, terrain: Dictionary, origin: Dictionary, address: Dictionary, vertices: PackedVector3Array, indices: PackedInt32Array) -> Dictionary:
	if geometry_type not in ["Polygon", "MultiPolygon"] or typeof(coordinates) != TYPE_ARRAY:
		return _failure("water surface requires 2D Polygon/MultiPolygon geometry")
	var water_kind := _water_kind(properties)
	var polygons: Array = [coordinates] if geometry_type == "Polygon" else coordinates
	var surface_method := ""
	for polygon_value in polygons:
		if typeof(polygon_value) != TYPE_ARRAY or polygon_value.is_empty() or typeof(polygon_value[0]) != TYPE_ARRAY:
			return _failure("water polygon has no exterior ring")
		if polygon_value.size() > 1:
			return {"ok": false, "unsupported_geometry": true, "error": "water polygon has interior rings; hole-aware surface triangulation is not implemented"}
		var ring: Array = polygon_value[0]
		var height_points := _water_surface_points(ring, terrain, origin, address, water_kind)
		if not height_points.get("ok", false):
			return height_points
		surface_method = String(height_points["surface_method"])
		var points: Array[Vector3] = height_points["points"]
		var ring_count := points.size() - 1 if points.front().distance_to(points.back()) <= 0.01 else points.size()
		var polygon_2d := PackedVector2Array()
		for point_index in range(ring_count):
			polygon_2d.append(Vector2(points[point_index].x, points[point_index].z))
		var vertex_start := vertices.size()
		for point_index in range(ring_count):
			vertices.append(points[point_index])
		var triangles := Geometry2D.triangulate_polygon(polygon_2d)
		if triangles.is_empty():
			return _failure("water polygon could not be triangulated")
		for triangle_index in range(0, triangles.size(), 3):
			indices.append(vertex_start + triangles[triangle_index])
			indices.append(vertex_start + triangles[triangle_index + 1])
			indices.append(vertex_start + triangles[triangle_index + 2])
	return {"ok": true, "error": "", "render_style": {"surface_method": surface_method, "source_height_invented": false}}

static func _water_surface_points(ring: Array, terrain: Dictionary, origin: Dictionary, address: Dictionary, water_kind: String) -> Dictionary:
	if water_kind == "unknown":
		return {"ok": false, "unavailable_surface": true, "error": "water class does not distinguish open water from inland water"}
	if water_kind == "inland_water":
		return {"ok": false, "unavailable_surface": true, "error": "inland water has no source-provided surface level or supported flattened CopDEM rule"}
	var points: Array[Vector3] = []
	var surface_method := "nominal mean sea level at h=N_EGM2008"
	for coordinate in ring:
		var parsed := _parse_lon_lat(coordinate, address)
		if not parsed.get("ok", false):
			return parsed
		var sample := _sample_terrain(terrain, float(parsed["longitude_deg"]), float(parsed["latitude_deg"]))
		if not sample.get("ok", false):
			return {"ok": false, "unavailable_surface": true, "error": "water position lacks a colocated geoid sample"}
		var geoid_mask := int(sample["geoid_mask"])
		if geoid_mask not in [1, 2]:
			return {"ok": false, "unavailable_surface": true, "error": "water position lacks a valid EGM2008 geoid sample"}
		if geoid_mask == 2:
			surface_method = "approximate nominal MSL at h=N_EGM2008 (GEBCO source mask)"
		var ellipsoidal_height := float(sample["geoid_undulation_m"])
		var point := _local_point(float(parsed["longitude_deg"]), float(parsed["latitude_deg"]), ellipsoidal_height, origin)
		if not point.get("ok", false):
			return point
		points.append(point["local_position"])
	return {"ok": true, "error": "", "points": points, "surface_method": surface_method}

static func _terrain_local_points(coordinates: Array, terrain: Dictionary, origin: Dictionary, address: Dictionary, _kind: String) -> Dictionary:
	var points: Array[Vector3] = []
	var surface_normals: Array[Vector3] = []
	for coordinate in coordinates:
		var parsed := _parse_lon_lat(coordinate, address)
		if not parsed.get("ok", false):
			return parsed
		var sample := _sample_terrain(terrain, float(parsed["longitude_deg"]), float(parsed["latitude_deg"]))
		if not sample.get("ok", false):
			return {"ok": false, "terrain_unavailable": true, "error": "feature coordinate lacks a valid terrain height sample"}
		var local := _local_point(float(parsed["longitude_deg"]), float(parsed["latitude_deg"]), float(sample["height_m"]), origin)
		if not local.get("ok", false):
			return local
		points.append(local["local_position"])
		surface_normals.append(local["surface_normal_local"])
	return {"ok": true, "error": "", "points": points, "surface_normals": surface_normals}

static func _parse_lon_lat(value: Variant, address: Dictionary) -> Dictionary:
	if typeof(value) != TYPE_ARRAY or value.size() != 2 or typeof(value[0]) not in [TYPE_INT, TYPE_FLOAT] or typeof(value[1]) not in [TYPE_INT, TYPE_FLOAT]:
		return _failure("GeoJSON position must contain exactly two numeric WGS84 coordinates")
	var longitude := float(value[0])
	var latitude := float(value[1])
	var bounds := Address.bounds_for_address(address)
	if not is_finite(longitude) or not is_finite(latitude) or longitude < float(bounds["west_deg"]) or longitude > float(bounds["east_deg"]) or latitude < float(bounds["south_deg"]) or latitude > float(bounds["north_deg"]):
		return _failure("source feature coordinate lies outside the closed geometric edge of its WFG-1 extent")
	return {"ok": true, "error": "", "longitude_deg": longitude, "latitude_deg": latitude}

static func _local_point(longitude: float, latitude: float, height_m: float, origin: Dictionary) -> Dictionary:
	var point_origin := LocalFrame.create_origin(latitude, longitude, height_m)
	if not point_origin.get("ok", false):
		return _failure(String(point_origin.get("error", "feature coordinate cannot be converted to WGS84 ECEF")))
	var transform := LocalFrame.tile_transform(point_origin, origin)
	if not transform.get("ok", false):
		return _failure(String(transform.get("error", "feature coordinate is outside the current local tangent frame")))
	return {"ok": true, "error": "", "local_position": transform["transform"].origin, "surface_normal_local": transform["transform"].basis.y.normalized()}

static func _sample_terrain(terrain: Dictionary, longitude: float, latitude: float) -> Dictionary:
	var rows := int(terrain.get("rows", 0))
	var columns := int(terrain.get("columns", 0))
	var boundary_sample := _sample_boundary_support(terrain, longitude, latitude)
	if boundary_sample.get("on_boundary", false):
		if boundary_sample.get("ok", false):
			return boundary_sample
		return _failure(String(boundary_sample.get("error", "exact WFG-1 edge sample lacks boundary support")))
	var transform: Dictionary = terrain.get("sample_coordinate_transform", {})
	var pixel := RasterTransform.coordinate_to_sample_index(transform, longitude, latitude)
	if not pixel.get("ok", false):
		return pixel
	var column_position := float(pixel["column_index"])
	var row_position := float(pixel["row_index"])
	if column_position < 0.0 or row_position < 0.0 or column_position > float(columns - 1) or row_position > float(rows - 1):
		return _failure("feature coordinate lies outside the terrain raster sample coverage")
	var c0 := int(floor(column_position))
	var r0 := int(floor(row_position))
	var c1 := mini(c0 + 1, columns - 1)
	var r1 := mini(r0 + 1, rows - 1)
	var dx := column_position - float(c0)
	var dy := row_position - float(r0)
	var indices := [r0 * columns + c0, r0 * columns + c1, r1 * columns + c0, r1 * columns + c1]
	var weights := [(1.0 - dx) * (1.0 - dy), dx * (1.0 - dy), (1.0 - dx) * dy, dx * dy]
	var heights: PackedFloat64Array = terrain["ellipsoidal_heights_m"]
	var valid: PackedByteArray = terrain["valid_mask"]
	var geoid: PackedFloat32Array = terrain["geoid_undulation_m"]
	var source_mask: PackedByteArray = terrain["source_mask"]
	var quality_mask: PackedByteArray = terrain["quality_mask"]
	var geoid_mask: PackedByteArray = terrain["geoid_mask"]
	var height := 0.0
	var geoid_height := 0.0
	var weight_sum := 0.0
	var nearest_index := int(indices[0])
	var nearest_weight := -INF
	for corner in range(4):
		var weight := float(weights[corner])
		if weight <= 1.0e-15:
			continue
		var index := int(indices[corner])
		if int(valid[index]) != 1 or not is_finite(heights[index]):
			return _failure("feature drape intersects terrain no-data")
		height += weight * heights[index]
		if is_finite(geoid[index]) and int(geoid_mask[index]) > 0:
			geoid_height += weight * geoid[index]
		weight_sum += weight
		if weight > nearest_weight:
			nearest_index = index
			nearest_weight = weight
	if weight_sum <= 0.0:
		return _failure("terrain interpolation has no valid support weights")
	return {"ok": true, "error": "", "height_m": height / weight_sum, "geoid_undulation_m": geoid_height / weight_sum, "source_mask": int(source_mask[nearest_index]), "quality_mask": int(quality_mask[nearest_index]), "geoid_mask": int(geoid_mask[nearest_index])}

static func _sample_boundary_support(terrain: Dictionary, longitude: float, latitude: float) -> Dictionary:
	var bounds: Variant = terrain.get("tile_bounds_wgs84")
	if typeof(bounds) != TYPE_DICTIONARY:
		return {"ok": false, "on_boundary": false, "error": "terrain decoded record lacks WFG-1 bounds for boundary sampling"}
	var tolerance := 1.0e-12
	var on_north := absf(latitude - float(bounds["north_deg"])) <= tolerance
	var on_south := absf(latitude - float(bounds["south_deg"])) <= tolerance
	var on_east := absf(longitude - float(bounds["east_deg"])) <= tolerance or (float(bounds["east_deg"]) == 180.0 and longitude == -180.0)
	var on_west := absf(longitude - float(bounds["west_deg"])) <= tolerance
	var edge := ""
	if on_north:
		edge = "north"
	elif on_east and on_south:
		edge = "east"
	elif on_south:
		edge = "south"
	elif on_west and not on_north and not on_south:
		edge = "west"
	elif on_east:
		edge = "east"
	if edge.is_empty():
		return {"ok": false, "on_boundary": false, "error": "coordinate is not on a WFG-1 outer edge"}
	var candidates: Array[Dictionary] = []
	var support_features: Variant = terrain.get("boundary_support_features", [])
	if typeof(support_features) != TYPE_ARRAY:
		return {"ok": false, "on_boundary": true, "error": "terrain boundary support collection is malformed"}
	for feature_value in support_features:
		if typeof(feature_value) != TYPE_DICTIONARY or String(feature_value.get("edge", "")) != edge:
			continue
		var support: Dictionary = feature_value.get("support", {})
		var along_value := float(feature_value["longitude_deg"]) if edge in ["north", "south"] else float(feature_value["latitude_deg"])
		var query_value := longitude if edge in ["north", "south"] else latitude
		if absf(along_value - query_value) <= tolerance:
			return _boundary_sample_result(feature_value, true)
		candidates.append(feature_value)
	if candidates.size() < 2:
		return {"ok": false, "on_boundary": true, "error": "no exact or bracketing boundary support samples are available for this edge position"}
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_value := float(left["longitude_deg"]) if edge in ["north", "south"] else float(left["latitude_deg"])
		var right_value := float(right["longitude_deg"]) if edge in ["north", "south"] else float(right["latitude_deg"])
		return left_value < right_value
	)
	var lower: Dictionary = {}
	var upper: Dictionary = {}
	var query := longitude if edge in ["north", "south"] else latitude
	for candidate in candidates:
		var value := float(candidate["longitude_deg"]) if edge in ["north", "south"] else float(candidate["latitude_deg"])
		if value < query:
			lower = candidate
		elif value > query:
			upper = candidate
			break
	if lower.is_empty() or upper.is_empty():
		return {"ok": false, "on_boundary": true, "error": "boundary coordinate lies beyond the supported perimeter sample range"}
	var lower_support: Dictionary = lower["support"]
	var upper_support: Dictionary = upper["support"]
	if int(lower_support.get("source_mask", -1)) != int(upper_support.get("source_mask", -2)) or int(lower_support.get("geoid_mask", -1)) != int(upper_support.get("geoid_mask", -2)):
		return {"ok": false, "on_boundary": true, "error": "boundary interpolation would cross a source/datum mask change"}
	var lower_value := float(lower["longitude_deg"]) if edge in ["north", "south"] else float(lower["latitude_deg"])
	var upper_value := float(upper["longitude_deg"]) if edge in ["north", "south"] else float(upper["latitude_deg"])
	var amount := (query - lower_value) / (upper_value - lower_value)
	var height := lerpf(float(lower["ellipsoidal_height_m"]), float(upper["ellipsoidal_height_m"]), amount)
	var geoid := lerpf(float(lower_support["geoid_undulation_N"]), float(upper_support["geoid_undulation_N"]), amount)
	var chosen_support := lower_support if amount < 0.5 else upper_support
	return {
		"ok": true,
		"on_boundary": true,
		"height_m": height,
		"geoid_undulation_m": geoid,
		"source_mask": int(chosen_support["source_mask"]),
		"quality_mask": int(chosen_support["quality_mask"]),
		"geoid_mask": int(chosen_support["geoid_mask"]),
		"boundary_interpolation": "linear between explicit canonical boundary support samples",
		"source_to_boundary_offset_m": maxf(float(lower_support["source_to_boundary_offset_m"]), float(upper_support["source_to_boundary_offset_m"]))
	}

static func _boundary_sample_result(feature: Dictionary, exact: bool) -> Dictionary:
	var support: Dictionary = feature["support"]
	return {
		"ok": true,
		"on_boundary": true,
		"height_m": float(feature["ellipsoidal_height_m"]),
		"geoid_undulation_m": float(support["geoid_undulation_N"]),
		"source_mask": int(support["source_mask"]),
		"quality_mask": int(support["quality_mask"]),
		"geoid_mask": int(support["geoid_mask"]),
		"boundary_interpolation": "native boundary support sample" if exact else "interpolated boundary support sample",
		"source_to_boundary_offset_m": float(support["source_to_boundary_offset_m"])
	}

static func _water_kind(properties: Dictionary) -> String:
	for field in ["water_type", "subtype", "class", "type"]:
		var value := String(properties.get(field, "")).to_lower()
		if value in ["ocean", "sea", "open_water", "marine"]:
			return "open_water"
		if value in ["lake", "pond", "reservoir", "river", "canal", "inland_water"]:
			return "inland_water"
	return "unknown"

static func _source_dimension_m(properties: Dictionary, candidates: Array[String]) -> Dictionary:
	for field in candidates:
		var value: Variant = properties.get(field)
		if typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value)) and float(value) > 0.0:
			return {"ok": true, "value_m": float(value)}
	return {"ok": false, "value_m": 0.0}

static func _append_quad(vertices: PackedVector3Array, indices: PackedInt32Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var start := vertices.size()
	vertices.append(a)
	vertices.append(b)
	vertices.append(c)
	vertices.append(d)
	indices.append(start)
	indices.append(start + 2)
	indices.append(start + 1)
	indices.append(start + 1)
	indices.append(start + 2)
	indices.append(start + 3)

static func _make_shard_mesh(layer_id: String, shard_index: int, vertices: PackedVector3Array, indices: PackedInt32Array) -> MeshInstance3D:
	if vertices.is_empty() or indices.is_empty() or indices.size() % 3 != 0:
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mesh.get_surface_count() != 1:
		return null
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.roughness = 0.94
	match layer_id:
		"roads":
			material.albedo_color = Color(0.22, 0.23, 0.22, 1.0)
		"buildings":
			material.albedo_color = Color(0.66, 0.61, 0.53, 1.0)
		"water":
			material.albedo_color = Color(0.13, 0.40, 0.67, 0.82)
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_set_material(0, material)
	var node := MeshInstance3D.new()
	node.name = "%sShard%d" % [layer_id.capitalize(), shard_index]
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if layer_id == "water" else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return node

static func _count_coordinate_positions(value: Variant) -> int:
	if typeof(value) != TYPE_ARRAY:
		return -1
	if value.size() == 2 and typeof(value[0]) in [TYPE_INT, TYPE_FLOAT] and typeof(value[1]) in [TYPE_INT, TYPE_FLOAT]:
		if not is_finite(float(value[0])) or not is_finite(float(value[1])):
			return -1
		return 1
	var total := 0
	for child in value:
		var count := _count_coordinate_positions(child)
		if count < 0:
			return -1
		total += count
		if total > MAX_VECTOR_COORDINATE_POSITIONS:
			return -1
	return total

static func _validate_terrain(terrain: Dictionary) -> String:
	if String(terrain.get("horizontal_crs", "")) != LocalFrame.CRS_GEOGRAPHIC_2D or String(terrain.get("horizontal_datum", "")) != "WGS84" or String(terrain.get("axis_order", "")) != "longitude_latitude":
		return "terrain sample grid must use normalized WGS84 longitude/latitude"
	if String(terrain.get("vertical_datum", "")) != LocalFrame.ELLIPSOIDAL_DATUM or String(terrain.get("height_type", "")) != "ellipsoidal":
		return "terrain feature drape requires explicit WGS84 ellipsoidal heights"
	var rows := int(terrain.get("rows", 0))
	var columns := int(terrain.get("columns", 0))
	if rows < 2 or columns < 2 or rows > 10_000_000 / columns:
		return "terrain grid dimensions exceed the finite sample limit"
	var heights: Variant = terrain.get("ellipsoidal_heights_m")
	var valid: Variant = terrain.get("valid_mask")
	var lonlat: Variant = terrain.get("sample_lonlat_deg")
	if typeof(heights) != TYPE_PACKED_FLOAT64_ARRAY or heights.size() != rows * columns or typeof(valid) != TYPE_PACKED_BYTE_ARRAY or valid.size() != heights.size() or typeof(lonlat) != TYPE_PACKED_FLOAT64_ARRAY or lonlat.size() != heights.size() * 2:
		return "terrain arrays do not agree with their declared dimensions"
	if typeof(terrain.get("sample_coordinate_transform")) != TYPE_DICTIONARY:
		return "terrain grid must retain its explicit affine origin/registration rule"
	return ""

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
