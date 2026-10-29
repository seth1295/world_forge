class_name TerrainLodBuilderV1
extends RefCounted

const TRIANGLE_AREA_EPSILON_SQUARED := 0.000000000001

## Build a deterministic sample-preserving mesh level. Level 1 keeps every other
## source row/column and appends the last row/column when the dimension is odd.
## Heights and horizontal coordinates always come directly from decoded v1 samples.
static func build(decoded: Dictionary, lod_level: int) -> Dictionary:
	if lod_level < 0 or lod_level > 1:
		return _failure("only deterministic terrain LOD levels 0 and 1 are supported")
	if not decoded.get("ok", false):
		return _failure("cannot build LOD from an invalid decoded window")
	var source_rows := int(decoded["rows"])
	var source_columns := int(decoded["columns"])
	var source_vertices: PackedVector3Array = decoded["vertices"]
	if source_rows < 2 or source_columns < 2 or source_vertices.size() != source_rows * source_columns:
		return _failure("decoded source grid does not have a complete vertex array")
	var stride := 1 if lod_level == 0 else 2
	var row_indices := _sample_indices(source_rows, stride)
	var column_indices := _sample_indices(source_columns, stride)
	var rows := row_indices.size()
	var columns := column_indices.size()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	vertices.resize(rows * columns)
	normals.resize(rows * columns)
	for output_row in range(rows):
		for output_column in range(columns):
			var source_index := row_indices[output_row] * source_columns + column_indices[output_column]
			var output_index := output_row * columns + output_column
			vertices[output_index] = source_vertices[source_index]
			normals[output_index] = Vector3.ZERO
	var triangle_count := (rows - 1) * (columns - 1) * 2
	var indices := PackedInt32Array()
	var faces := PackedVector3Array()
	indices.resize(triangle_count * 3)
	faces.resize(triangle_count * 3)
	var cursor := 0
	for row in range(rows - 1):
		for column in range(columns - 1):
			var north_west := row * columns + column
			var north_east := north_west + 1
			var south_west := north_west + columns
			var south_east := south_west + 1
			indices[cursor] = north_west
			indices[cursor + 1] = south_east
			indices[cursor + 2] = south_west
			faces[cursor] = vertices[north_west]
			faces[cursor + 1] = vertices[south_east]
			faces[cursor + 2] = vertices[south_west]
			var first_normal := (vertices[south_west] - vertices[north_west]).cross(vertices[south_east] - vertices[north_west])
			if first_normal.length_squared() <= TRIANGLE_AREA_EPSILON_SQUARED:
				return _failure("LOD mesh contains a degenerate first triangle")
			normals[north_west] += first_normal
			normals[south_east] += first_normal
			normals[south_west] += first_normal
			cursor += 3
			indices[cursor] = north_west
			indices[cursor + 1] = north_east
			indices[cursor + 2] = south_east
			faces[cursor] = vertices[north_west]
			faces[cursor + 1] = vertices[north_east]
			faces[cursor + 2] = vertices[south_east]
			var second_normal := (vertices[south_east] - vertices[north_west]).cross(vertices[north_east] - vertices[north_west])
			if second_normal.length_squared() <= TRIANGLE_AREA_EPSILON_SQUARED:
				return _failure("LOD mesh contains a degenerate second triangle")
			normals[north_west] += second_normal
			normals[north_east] += second_normal
			normals[south_east] += second_normal
			cursor += 3
	for vertex_index in range(normals.size()):
		if normals[vertex_index].length_squared() <= TRIANGLE_AREA_EPSILON_SQUARED:
			return _failure("LOD mesh contains an isolated vertex")
		normals[vertex_index] = normals[vertex_index].normalized()
		if normals[vertex_index].y <= 0.0:
			return _failure("LOD mesh contains a non-upward normal")
	var geometry := {
		"ok": true,
		"error": "",
		"lod_level": lod_level,
		"sample_stride": stride,
		"source_row_offset": int(decoded["manifest"]["grid"]["source_window"]["row_offset"]),
		"source_column_offset": int(decoded["manifest"]["grid"]["source_window"]["column_offset"]),
		"source_rows": row_indices,
		"source_columns": column_indices,
		"rows": rows,
		"columns": columns,
		"vertices": vertices,
		"normals": normals,
		"indices": indices,
		"faces": faces,
		"max_omitted_sample_deviation_m": 0.0
	}
	if lod_level == 1:
		geometry["max_omitted_sample_deviation_m"] = max_omitted_sample_deviation_m(decoded, geometry)
	return geometry

## Measure each source sample omitted from LOD 1 against the point on the
## corresponding coarse triangle with the same source-grid barycentric position.
## This is a crop observation, not a source accuracy or quality claim.
static func max_omitted_sample_deviation_m(decoded: Dictionary, geometry: Dictionary) -> float:
	var source_vertices: PackedVector3Array = decoded["vertices"]
	var source_rows := int(decoded["rows"])
	var source_columns := int(decoded["columns"])
	var row_indices: Array[int] = geometry["source_rows"]
	var column_indices: Array[int] = geometry["source_columns"]
	var coarse_vertices: PackedVector3Array = geometry["vertices"]
	var coarse_columns := int(geometry["columns"])
	var retained_rows: Dictionary = {}
	var retained_columns: Dictionary = {}
	for index in row_indices:
		retained_rows[index] = true
	for index in column_indices:
		retained_columns[index] = true
	var maximum := 0.0
	for source_row in range(source_rows):
		for source_column in range(source_columns):
			if retained_rows.has(source_row) and retained_columns.has(source_column):
				continue
			var row_segment := mini(source_row / 2, row_indices.size() - 2)
			var column_segment := mini(source_column / 2, column_indices.size() - 2)
			var row_start := row_indices[row_segment]
			var row_end := row_indices[row_segment + 1]
			var column_start := column_indices[column_segment]
			var column_end := column_indices[column_segment + 1]
			var v := float(source_row - row_start) / float(row_end - row_start)
			var u := float(source_column - column_start) / float(column_end - column_start)
			var north_west := coarse_vertices[row_segment * coarse_columns + column_segment]
			var north_east := coarse_vertices[row_segment * coarse_columns + column_segment + 1]
			var south_west := coarse_vertices[(row_segment + 1) * coarse_columns + column_segment]
			var south_east := coarse_vertices[(row_segment + 1) * coarse_columns + column_segment + 1]
			var corresponding_coarse_point: Vector3
			if u >= v:
				corresponding_coarse_point = north_west * (1.0 - u) + north_east * (u - v) + south_east * v
			else:
				corresponding_coarse_point = north_west * (1.0 - v) + south_east * u + south_west * (v - u)
			var source_point := source_vertices[source_row * source_columns + source_column]
			maximum = maxf(maximum, source_point.distance_to(corresponding_coarse_point))
	return maximum

static func validate_adjacent_pair(west_geometry: Dictionary, east_geometry: Dictionary) -> Dictionary:
	if not west_geometry.get("ok", false) or not east_geometry.get("ok", false):
		return _failure("adjacent LOD geometry is invalid")
	if int(west_geometry["lod_level"]) != int(east_geometry["lod_level"]):
		return _failure("neighbor LOD levels must transition together")
	var west_rows: Array[int] = west_geometry["source_rows"]
	var east_rows: Array[int] = east_geometry["source_rows"]
	if int(west_geometry["source_row_offset"]) != int(east_geometry["source_row_offset"]) or west_rows != east_rows:
		return _failure("adjacent LOD windows must use identical source rows")
	var west_columns: Array[int] = west_geometry["source_columns"]
	var east_columns: Array[int] = east_geometry["source_columns"]
	var west_global_last_column: int = int(west_geometry["source_column_offset"]) + west_columns.back()
	var east_global_first_column: int = int(east_geometry["source_column_offset"]) + east_columns.front()
	if west_global_last_column != east_global_first_column:
		return _failure("adjacent LOD windows must preserve the same shared source column")
	var west_vertices: PackedVector3Array = west_geometry["vertices"]
	var east_vertices: PackedVector3Array = east_geometry["vertices"]
	var west_width := int(west_geometry["columns"])
	var east_width := int(east_geometry["columns"])
	if west_width <= 0 or east_width <= 0 or west_rows.size() * west_width != west_vertices.size() or east_rows.size() * east_width != east_vertices.size():
		return _failure("adjacent LOD geometry dimensions are inconsistent")
	for row in range(west_rows.size()):
		var west_edge := west_vertices[row * west_width + west_width - 1]
		var east_edge := east_vertices[row * east_width]
		if west_edge != east_edge:
			return _failure("adjacent LOD shared seam vertices are not identical")
	return {"ok": true, "error": ""}

static func _sample_indices(count: int, stride: int) -> Array[int]:
	var indices: Array[int] = []
	for index in range(0, count, stride):
		indices.append(index)
	if indices.is_empty() or indices.back() != count - 1:
		indices.append(count - 1)
	return indices

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
