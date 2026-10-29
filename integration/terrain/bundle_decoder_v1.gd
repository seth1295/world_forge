class_name TerrainBundleDecoderV1
extends RefCounted

const StrictJson := preload("res://terrain/strict_json_v1.gd")
const SchemaV1 := preload("res://terrain/schema_v1.gd")
const ContractV1 := preload("res://terrain/terrain_contract_v1.gd")
const HashV1 := preload("res://terrain/hash_v1.gd")
const SiteCatalog := preload("res://terrain/site_catalog_v1.gd")

const MAX_RENDER_SAMPLES := 131_072
const HASH_CHUNK_BYTES := 1_048_576
const PROJECTED_BOUNDS_TOLERANCE_M := 0.000001
const MAX_SOURCE_HEIGHT_M := 12_000.0
const MAX_RELATIVE_HEIGHT_M := 24_000.0
const MAX_ABS_PROJECTED_M := 100_000.0
const MAX_SCHEMA_BYTES := 65_536

var result: Dictionary = {}

## Decode a whitelisted real bundle. All file, source, frame, artifact, count, hash,
## and sample checks finish before geometry arrays are allocated.
func decode(site_id: String, repository_root: String, window_id: String = "") -> void:
    result = _decode_bundle(site_id, repository_root, window_id)

## Decode two approved adjacent windows as one atomic consumer request. The v1 full-resolution
## sample edges are checked before either tile set is returned for scene installation.
func decode_window_set(site_id: String, repository_root: String, window_ids: Array[String]) -> void:
    result = _decode_window_set(site_id, repository_root, window_ids)

static func _decode_window_set(site_id: String, repository_root: String, window_ids: Array[String]) -> Dictionary:
    if window_ids.is_empty() or window_ids.size() > 2:
        return _failure("terrain window set must contain one or two windows")
    if SiteCatalog.get_site(site_id).is_empty():
        return _failure("unknown or unapproved terrain site")
    var seen: Dictionary = {}
    var decoded_windows: Array[Dictionary] = []
    for window_id in window_ids:
        if seen.has(window_id):
            return _failure("terrain window set contains a duplicate window ID")
        seen[window_id] = true
        var window_decoder := TerrainBundleDecoderV1.new()
        window_decoder.decode(site_id, repository_root, window_id)
        var window_result: Dictionary = window_decoder.result
        if not window_result.get("ok", false):
            return _failure("window %s failed validation: %s" % [window_id, String(window_result.get("error", "unknown error"))])
        decoded_windows.append(window_result)
    if decoded_windows.size() == 2:
        var adjacency: Dictionary = _order_and_validate_adjacent_pair(decoded_windows)
        if not adjacency.get("ok", false):
            return _failure(String(adjacency.get("error", "adjacent windows are incompatible")))
        var ordered_windows: Array[Dictionary] = []
        for ordered_window in adjacency["windows"]:
            ordered_windows.append(ordered_window)
        decoded_windows = ordered_windows
    var ordered_ids: Array[String] = []
    for decoded_window in decoded_windows:
        ordered_ids.append(String(decoded_window["site"]["window_id"]))
    return {
        "ok": true,
        "error": "",
        "site_id": site_id,
        "windows": decoded_windows,
        "window_ids": ordered_ids,
        "frame_id": String(decoded_windows[0]["manifest"]["frame"]["frame_id"]),
        "lod_policy": "adjacent_atomic_exact_subsample"
    }

static func _order_and_validate_adjacent_pair(decoded_windows: Array[Dictionary]) -> Dictionary:
    if decoded_windows.size() != 2:
        return _failure("adjacent pair must contain exactly two windows")
    var west: Dictionary = decoded_windows[0]
    var east: Dictionary = decoded_windows[1]
    var west_window: Dictionary = west["manifest"]["grid"]["source_window"]
    var east_window: Dictionary = east["manifest"]["grid"]["source_window"]
    if int(west_window["column_offset"]) > int(east_window["column_offset"]):
        var swap := west
        west = east
        east = swap
        west_window = west["manifest"]["grid"]["source_window"]
        east_window = east["manifest"]["grid"]["source_window"]
    var west_manifest: Dictionary = west["manifest"]
    var east_manifest: Dictionary = east["manifest"]
    var west_grid: Dictionary = west_manifest["grid"]
    var east_grid: Dictionary = east_manifest["grid"]
    if int(west_window["row_offset"]) != int(east_window["row_offset"]) or int(west_window["rows"]) != int(east_window["rows"]):
        return _failure("adjacent windows must share the same source rows")
    if int(west_window["column_offset"]) + int(west_window["columns"]) - 1 != int(east_window["column_offset"]):
        return _failure("adjacent windows must share exactly one sample column")
    if int(west_grid["sample_stride"]) != 1 or int(east_grid["sample_stride"]) != 1 or west_grid["resampling"] != "none" or east_grid["resampling"] != "none":
        return _failure("adjacent seam policy requires full-resolution, non-resampled windows")
    if int(west_window["column_offset"]) + int(west_window["columns"]) - 2 + 1 != int(east_window["column_offset"]):
        return _failure("adjacent cell strips are not contiguous and disjoint")
    if west_grid["region_id"] != east_grid["region_id"] or west_manifest["frame"] != east_manifest["frame"] or west["frame_hash"] != east["frame_hash"]:
        return _failure("adjacent windows must share the exact regional frame identity")
    if west_manifest["source"] != east_manifest["source"]:
        return _failure("adjacent windows must share the exact approved source raster descriptor")
    if west["artifact_id"] == east["artifact_id"]:
        return _failure("adjacent windows must have distinct artifact identities")
    # Footprint metadata is outer-pixel-edge based for AREA samples, so the metadata
    # footprints may overlap by one pixel width. The center-to-center mesh strips do not.
    var west_boundary: Dictionary = west["boundary_samples"]["east"]
    var east_boundary: Dictionary = east["boundary_samples"]["west"]
    if west_boundary["xy_f64le"] != east_boundary["xy_f64le"] or west_boundary["height_f32le"] != east_boundary["height_f32le"]:
        return _failure("shared sample column bytes differ between adjacent windows")
    var west_vertices: PackedVector3Array = west["vertices"]
    var east_vertices: PackedVector3Array = east["vertices"]
    var west_columns := int(west["columns"])
    var east_columns := int(east["columns"])
    var rows := int(west["rows"])
    for row in range(rows):
        var west_edge := west_vertices[row * west_columns + west_columns - 1]
        var east_edge := east_vertices[row * east_columns]
        if west_edge.distance_to(east_edge) > 0.000001:
            return _failure("shared sample column geometry differs between adjacent windows")
    var ordered_windows: Array[Dictionary] = []
    ordered_windows.append(west)
    ordered_windows.append(east)
    return {"ok": true, "error": "", "windows": ordered_windows}

static func _decode_bundle(site_id: String, repository_root: String, window_id: String = "") -> Dictionary:
    var site := SiteCatalog.get_site(site_id) if window_id.is_empty() else SiteCatalog.get_window(site_id, window_id)
    if site.is_empty():
        return _failure("unknown or unapproved terrain site")
    if repository_root.is_empty() or not DirAccess.dir_exists_absolute(repository_root):
        return _failure("repository root is missing")

    var schema_path := repository_root.path_join("contracts/terrain_grid_v1.schema.json")
    var schema_result := _read_schema(schema_path)
    if not schema_result.get("ok", false):
        return _failure(String(schema_result.get("error", "schema could not be loaded")))
    var schema: Dictionary = schema_result["value"]

    var terrain_root := repository_root.path_join("integration/assets/terrain")
    var bundle_directory := terrain_root.path_join(String(site["bundle_directory"]))
    var path_error := _validate_bundle_paths(repository_root, terrain_root, bundle_directory)
    if not path_error.is_empty():
        return _failure(path_error)

    var manifest_path := bundle_directory.path_join("manifest.json")
    var horizontal_path := bundle_directory.path_join(ContractV1.HORIZONTAL_FILE)
    var height_path := bundle_directory.path_join(ContractV1.HEIGHT_FILE)
    var manifest_result := _read_manifest(manifest_path)
    if not manifest_result.get("ok", false):
        return _failure(String(manifest_result.get("error", "manifest could not be read")))
    var manifest: Dictionary = manifest_result["value"]

    var contract_result := ContractV1.validate_manifest(manifest, schema, site)
    if not contract_result.get("ok", false):
        return _failure(String(contract_result.get("error", "manifest validation failed")))
    var size_result := ContractV1.validate_dimensions_and_files(manifest)
    if not size_result.get("ok", false):
        return _failure(String(size_result.get("error", "manifest dimensions are invalid")))
    if int(size_result["sample_count"]) > MAX_RENDER_SAMPLES:
        return _failure("grid exceeds the v1 technical viewer sample cap")

    var payloads: Dictionary = manifest["payloads"]
    var expected_horizontal_bytes := int(size_result["horizontal_bytes"])
    var expected_height_bytes := int(size_result["height_bytes"])
    var horizontal_hash := String(payloads["horizontal_xy"]["sha256"])
    var height_hash := String(payloads["height_samples"]["sha256"])
    var horizontal_file_result := _hash_file(horizontal_path, expected_horizontal_bytes, ContractV1.MAX_HORIZONTAL_BYTES)
    if not horizontal_file_result.get("ok", false):
        return _failure(String(horizontal_file_result.get("error", "horizontal payload hash failed")))
    if String(horizontal_file_result["sha256"]) != horizontal_hash:
        return _failure("horizontal payload SHA-256 does not match the manifest")
    var height_file_result := _hash_file(height_path, expected_height_bytes, ContractV1.MAX_HEIGHT_BYTES)
    if not height_file_result.get("ok", false):
        return _failure(String(height_file_result.get("error", "height payload hash failed")))
    if String(height_file_result["sha256"]) != height_hash:
        return _failure("height payload SHA-256 does not match the manifest")

    # Read only after the declared and actual byte bounds and streaming hashes passed.
    # Exact-length reads from the opened handles keep a replacement/growth race bounded.
    var horizontal_read := _read_bounded_file(horizontal_path, expected_horizontal_bytes, ContractV1.MAX_HORIZONTAL_BYTES, horizontal_hash)
    if not horizontal_read.get("ok", false):
        return _failure(String(horizontal_read.get("error", "horizontal payload changed after hashing")))
    var height_read := _read_bounded_file(height_path, expected_height_bytes, ContractV1.MAX_HEIGHT_BYTES, height_hash)
    if not height_read.get("ok", false):
        return _failure(String(height_read.get("error", "height payload changed after hashing")))
    var horizontal_bytes: PackedByteArray = horizontal_read["bytes"]
    var height_bytes: PackedByteArray = height_read["bytes"]

    var payload_validation := _validate_samples(manifest, horizontal_bytes, height_bytes, int(size_result["sample_count"]))
    if not payload_validation.get("ok", false):
        return _failure(String(payload_validation.get("error", "terrain sample validation failed")))
    var geometry := _build_geometry(manifest, horizontal_bytes, height_bytes, int(size_result["rows"]), int(size_result["columns"]), int(size_result["sample_count"]))
    if not geometry.get("ok", false):
        return _failure(String(geometry.get("error", "terrain geometry preparation failed")))

    return {
        "ok": true,
        "error": "",
        "site": site,
        "manifest": manifest,
        "rows": int(size_result["rows"]),
        "columns": int(size_result["columns"]),
        "sample_count": int(size_result["sample_count"]),
        "vertices": geometry["vertices"],
        "normals": geometry["normals"],
        "indices": geometry["indices"],
        "faces": geometry["faces"],
        "anchor_index": int(payload_validation["anchor_index"]),
        "sample_min_height_m": float(payload_validation["sample_min_height_m"]),
        "sample_max_height_m": float(payload_validation["sample_max_height_m"]),
        "frame_hash": contract_result["frame_hash"],
        "artifact_id": contract_result["artifact_id"],
        "boundary_samples": _extract_boundary_samples(horizontal_bytes, height_bytes, int(size_result["rows"]), int(size_result["columns"]))
    }

static func _read_schema(path: String) -> Dictionary:
    var repository_directory := DirAccess.open(path.get_base_dir().get_base_dir())
    if repository_directory == null or repository_directory.is_link(path.get_base_dir()):
        return _failure("schema directory is a symbolic link or reparse point")
    var schema_directory := DirAccess.open(path.get_base_dir())
    if schema_directory == null or schema_directory.is_link(path):
        return _failure("schema path is a symbolic link or reparse point")
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return _failure("cannot open parent terrain schema (error %d)" % FileAccess.get_open_error())
    var byte_count := file.get_length()
    if byte_count <= 0 or byte_count > MAX_SCHEMA_BYTES:
        file.close()
        return _failure("parent terrain schema has an invalid byte length")
    var bytes := file.get_buffer(byte_count)
    file.close()
    if bytes.size() != byte_count:
        return _failure("parent terrain schema read was truncated")
    var parsed: Dictionary = StrictJson.new().parse_bytes(bytes, MAX_SCHEMA_BYTES)
    if not parsed.get("ok", false) or typeof(parsed.get("value")) != TYPE_DICTIONARY:
        return _failure("parent terrain schema is invalid JSON: %s" % String(parsed.get("error", "unknown error")))
    return {"ok": true, "value": parsed["value"], "error": ""}

static func _validate_bundle_paths(repository_root: String, terrain_root: String, bundle_directory: String) -> String:
    var repository_directory := DirAccess.open(repository_root)
    if repository_directory == null:
        return "cannot open repository root"
    var checked_paths := [
        repository_root.path_join("integration"),
        repository_root.path_join("integration/assets"),
        terrain_root,
        bundle_directory
    ]
    for path in checked_paths:
        if repository_directory.is_link(path):
            return "terrain bundle path contains a symbolic link or reparse point"
    if not DirAccess.dir_exists_absolute(bundle_directory):
        return "approved terrain bundle directory is missing"
    var bundle_access := DirAccess.open(bundle_directory)
    if bundle_access == null:
        return "cannot open approved terrain bundle directory"
    if bundle_access.is_link(bundle_directory):
        return "terrain bundle directory is a symbolic link or reparse point"
    var expected_files := PackedStringArray(["height_samples.f32le", "horizontal_xy.f64le", "manifest.json"])
    var actual_files := bundle_access.get_files()
    actual_files.sort()
    expected_files.sort()
    if actual_files != expected_files or not bundle_access.get_directories().is_empty():
        return "terrain bundle must contain exactly manifest.json and the two v1 payloads"
    for filename in expected_files:
        var file_path := bundle_directory.path_join(filename)
        if bundle_access.is_link(file_path):
            return "terrain bundle contains a symbolic link or reparse point"
    return ""

static func _read_manifest(path: String) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return _failure("cannot open manifest (error %d)" % FileAccess.get_open_error())
    var byte_count := file.get_length()
    if byte_count <= 0 or byte_count > ContractV1.MAX_MANIFEST_BYTES:
        file.close()
        return _failure("manifest is empty or exceeds the v1 byte limit")
    var bytes := file.get_buffer(byte_count)
    file.close()
    if bytes.size() != byte_count:
        return _failure("manifest read was truncated")
    var parsed: Dictionary = StrictJson.new().parse_bytes(bytes, ContractV1.MAX_MANIFEST_BYTES)
    if not parsed.get("ok", false):
        return _failure("strict JSON validation failed: %s" % String(parsed.get("error", "unknown error")))
    return parsed

static func _hash_file(path: String, expected_bytes: int, cap_bytes: int) -> Dictionary:
    if expected_bytes < 0 or expected_bytes > cap_bytes:
        return _failure("payload declared size exceeds the v1 file cap")
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return _failure("cannot open terrain payload (error %d)" % FileAccess.get_open_error())
    if file.get_length() != expected_bytes:
        file.close()
        return _failure("terrain payload byte length differs from the manifest")
    var context := HashingContext.new()
    if context.start(HashingContext.HASH_SHA256) != OK:
        file.close()
        return _failure("cannot initialize SHA-256 for terrain payload")
    var remaining := expected_bytes
    while remaining > 0:
        var chunk_size := mini(remaining, HASH_CHUNK_BYTES)
        var chunk := file.get_buffer(chunk_size)
        if chunk.size() != chunk_size:
            file.close()
            return _failure("terrain payload read was truncated")
        if context.update(chunk) != OK:
            file.close()
            return _failure("cannot update SHA-256 for terrain payload")
        remaining -= chunk_size
    file.close()
    return {"ok": true, "sha256": context.finish().hex_encode(), "error": ""}

static func _read_bounded_file(path: String, expected_bytes: int, cap_bytes: int, expected_sha256: String) -> Dictionary:
    if expected_bytes <= 0 or expected_bytes > cap_bytes:
        return _failure("payload exact-read size is outside its v1 cap")
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return _failure("cannot reopen terrain payload (error %d)" % FileAccess.get_open_error())
    if file.get_length() != expected_bytes:
        file.close()
        return _failure("terrain payload size changed between hash and read")
    var parent_directory := DirAccess.open(path.get_base_dir())
    if parent_directory == null or parent_directory.is_link(path):
        file.close()
        return _failure("terrain payload became a symbolic link or reparse point")
    var bytes := file.get_buffer(expected_bytes)
    var size_after_read := file.get_length()
    file.close()
    if bytes.size() != expected_bytes or size_after_read != expected_bytes:
        return _failure("terrain payload exact read was truncated or changed size")
    if HashV1.sha256_bytes(bytes) != expected_sha256:
        return _failure("terrain payload changed between streaming hash and bounded read")
    return {"ok": true, "bytes": bytes, "error": ""}
static func _extract_boundary_samples(horizontal_bytes: PackedByteArray, height_bytes: PackedByteArray, rows: int, columns: int) -> Dictionary:
    return {
        "west": {
            "xy_f64le": _extract_boundary_column(horizontal_bytes, rows, columns, 0, 16),
            "height_f32le": _extract_boundary_column(height_bytes, rows, columns, 0, 4)
        },
        "east": {
            "xy_f64le": _extract_boundary_column(horizontal_bytes, rows, columns, columns - 1, 16),
            "height_f32le": _extract_boundary_column(height_bytes, rows, columns, columns - 1, 4)
        }
    }

static func _extract_boundary_column(payload: PackedByteArray, rows: int, columns: int, column: int, bytes_per_sample: int) -> PackedByteArray:
    var boundary := PackedByteArray()
    boundary.resize(rows * bytes_per_sample)
    for row in range(rows):
        var source_offset := (row * columns + column) * bytes_per_sample
        var destination_offset := row * bytes_per_sample
        for byte_index in range(bytes_per_sample):
            boundary[destination_offset + byte_index] = payload[source_offset + byte_index]
    return boundary
static func _validate_samples(manifest: Dictionary, horizontal_bytes: PackedByteArray, height_bytes: PackedByteArray, sample_count: int) -> Dictionary:
    var grid: Dictionary = manifest["grid"]
    var frame: Dictionary = manifest["frame"]
    var origin: Dictionary = frame["origin"]
    var window: Dictionary = grid["source_window"]
    var bounds: Dictionary = grid["projected_sample_bounds_m"]
    var nodata := float(manifest["source"]["raster"]["nodata_value"])
    var anchor_height := float(origin["height_navd88_m"])
    var anchor_row := int(origin["source_row"]) - int(window["row_offset"])
    var anchor_column := int(origin["source_column"]) - int(window["column_offset"])
    var rows := int(grid["rows"])
    var columns := int(grid["columns"])
    if anchor_row < 0 or anchor_row >= rows or anchor_column < 0 or anchor_column >= columns:
        return _failure("approved v1 terrain bundle does not include its source anchor sample")
    var anchor_index := anchor_row * columns + anchor_column
    var xy_stream := _stream(horizontal_bytes)
    var height_stream := _stream(height_bytes)
    var min_easting := INF
    var max_easting := -INF
    var min_northing := INF
    var max_northing := -INF
    var min_height := INF
    var max_height := -INF
    var anchor_easting := 0.0
    var anchor_northing := 0.0
    var anchor_sample_height := 0.0
    for sample_index in range(sample_count):
        var easting := xy_stream.get_double()
        var northing := xy_stream.get_double()
        var height := height_stream.get_float()
        if not is_finite(easting) or not is_finite(northing) or maxf(absf(easting), absf(northing)) > MAX_ABS_PROJECTED_M:
            return _failure("horizontal sample is non-finite or outside v1 regional bounds")
        if not is_finite(height) or height == nodata or absf(height) > MAX_SOURCE_HEIGHT_M:
            return _failure("height sample is non-finite, no-data, or outside v1 source bounds")
        var relative_height := height - anchor_height
        if not is_finite(relative_height) or absf(relative_height) > MAX_RELATIVE_HEIGHT_M:
            return _failure("relative NAVD88 height is non-finite or outside v1 bounds")
        min_easting = minf(min_easting, easting)
        max_easting = maxf(max_easting, easting)
        min_northing = minf(min_northing, northing)
        max_northing = maxf(max_northing, northing)
        min_height = minf(min_height, height)
        max_height = maxf(max_height, height)
        if sample_index == anchor_index:
            anchor_easting = easting
            anchor_northing = northing
            anchor_sample_height = height
    if xy_stream.get_position() != horizontal_bytes.size() or height_stream.get_position() != height_bytes.size():
        return _failure("terrain payload contains trailing or unconsumed bytes")
    if not _close_enough(min_easting, float(bounds["easting_min"])) or not _close_enough(max_easting, float(bounds["easting_max"])) or not _close_enough(min_northing, float(bounds["northing_min"])) or not _close_enough(max_northing, float(bounds["northing_max"])):
        return _failure("projected sample bounds do not match the payload samples")
    if absf(anchor_easting) > PROJECTED_BOUNDS_TOLERANCE_M or absf(anchor_northing) > PROJECTED_BOUNDS_TOLERANCE_M:
        return _failure("source anchor sample does not project to the regional frame origin")
    if anchor_sample_height != anchor_height:
        return _failure("source anchor height differs from the approved NAVD88 anchor sample")
    return {
        "ok": true,
        "error": "",
        "anchor_index": anchor_index,
        "sample_min_height_m": min_height,
        "sample_max_height_m": max_height
    }

static func _build_geometry(manifest: Dictionary, horizontal_bytes: PackedByteArray, height_bytes: PackedByteArray, rows: int, columns: int, sample_count: int) -> Dictionary:
    # No renderer or physics resources are created here; the caller builds those on the main thread.
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    vertices.resize(sample_count)
    normals.resize(sample_count)
    var xy_stream := _stream(horizontal_bytes)
    var height_stream := _stream(height_bytes)
    var anchor_height := float(manifest["frame"]["origin"]["height_navd88_m"])
    for index in range(sample_count):
        var easting := xy_stream.get_double()
        var northing := xy_stream.get_double()
        var height := height_stream.get_float()
        vertices[index] = Vector3(easting, height - anchor_height, -northing)
        normals[index] = Vector3.ZERO

    var triangle_count := (rows - 1) * (columns - 1) * 2
    var indices := PackedInt32Array()
    var faces := PackedVector3Array()
    indices.resize(triangle_count * 3)
    faces.resize(triangle_count * 3)
    var index_cursor := 0
    var face_cursor := 0
    for row in range(rows - 1):
        for column in range(columns - 1):
            var north_west := row * columns + column
            var north_east := north_west + 1
            var south_west := north_west + columns
            var south_east := south_west + 1
            # V1's fixed NW-SE diagonal and clockwise Godot front-face index order.
            indices[index_cursor] = north_west
            indices[index_cursor + 1] = south_east
            indices[index_cursor + 2] = south_west
            faces[face_cursor] = vertices[north_west]
            faces[face_cursor + 1] = vertices[south_east]
            faces[face_cursor + 2] = vertices[south_west]
            var first_upward_normal := (vertices[south_west] - vertices[north_west]).cross(vertices[south_east] - vertices[north_west])
            normals[north_west] += first_upward_normal
            normals[south_east] += first_upward_normal
            normals[south_west] += first_upward_normal
            index_cursor += 3
            face_cursor += 3

            indices[index_cursor] = north_west
            indices[index_cursor + 1] = north_east
            indices[index_cursor + 2] = south_east
            faces[face_cursor] = vertices[north_west]
            faces[face_cursor + 1] = vertices[north_east]
            faces[face_cursor + 2] = vertices[south_east]
            var second_upward_normal := (vertices[south_east] - vertices[north_west]).cross(vertices[north_east] - vertices[north_west])
            normals[north_west] += second_upward_normal
            normals[north_east] += second_upward_normal
            normals[south_east] += second_upward_normal
            index_cursor += 3
            face_cursor += 3
    for index in range(normals.size()):
        var normal := normals[index]
        if not is_finite(normal.x) or not is_finite(normal.y) or not is_finite(normal.z) or normal.length_squared() <= 0.0:
            return _failure("terrain normal is non-finite or degenerate")
        normals[index] = normal.normalized()
        if normals[index].y <= 0.0:
            return _failure("terrain triangle order produced a non-upward normal")
    return {"ok": true, "vertices": vertices, "normals": normals, "indices": indices, "faces": faces, "error": ""}

static func _stream(bytes: PackedByteArray) -> StreamPeerBuffer:
    var stream := StreamPeerBuffer.new()
    stream.big_endian = false
    stream.data_array = bytes

    return stream

static func _close_enough(left: float, right: float) -> bool:
    return absf(left - right) <= PROJECTED_BOUNDS_TOLERANCE_M

static func _failure(message: String) -> Dictionary:
    return {"ok": false, "error": message}
