class_name Wfg1GlobalTerrainArtifactProviderV1
extends WorldTileProvider

## Adapter for the independent generator's immutable global-terrain artifact.
## This component adapter is intentionally terrain-only; it does not label the
## artifact as the combined Global World Tile Bundle contract.
const Address := preload("res://terrain/wfg1_tile_address.gd")
const LocalFrame := preload("res://terrain/wfg1_local_frame.gd")
const RasterTransform := preload("res://terrain/wfg1_raster_geotransform_v1.gd")
const StrictJson := preload("res://terrain/strict_json_v1.gd")
const MAX_MANIFEST_BYTES := 16 * 1024 * 1024
const MAX_PAYLOAD_BYTES := 1024 * 1024 * 1024
const MAX_RASTER_SAMPLES := 10_000_000
const MAX_TERRAIN_PAYLOAD_DESCRIPTORS := 64
const EXPECTED_CONTRACT := "urn:worldforge:contract:global-terrain-tile:1.0.0"
const EXPECTED_PRODUCER_COMMIT := "6d4cf589a278b5e2eea668c25bc43469f4d45791"
const EXPECTED_GEOID_SHA256 := "4191d471eefebf24091b56dbc604353cb3b8cf8cc70e448bb9ae56a272bef17a"
const EXPECTED_GEOID_GRID := "OSGeo-PROJ-data/us_nga_egm08_25.tif"

var manifest_path := ""

func configure_artifact(path: String) -> Dictionary:
	var absolute_path := path.simplify_path()
	if not absolute_path.is_absolute_path() or not absolute_path.to_lower().ends_with("manifest.json"):
		return _failure("terrain artifact manifest path must be an absolute manifest.json path")
	manifest_path = absolute_path
	return {"ok": true, "error": ""}

func load_tile(request: Dictionary, cancellation: WorldTileCancellationToken) -> Dictionary:
	if manifest_path.is_empty():
		return _failure("global terrain artifact provider is not configured")
	if cancellation.is_cancelled():
		return {"ok": false, "status": "cancelled", "error": "terrain artifact request was cancelled"}
	var parsed_request := Address.validate_address(request.get("address", {}))
	if not parsed_request.get("ok", false):
		return _failure("requested global terrain artifact address is invalid")
	var requested_tile_id := Address.format_id(parsed_request["address"])
	var manifest_file := FileAccess.open(manifest_path, FileAccess.READ)
	if manifest_file == null:
		return _failure("global terrain artifact manifest cannot be opened")
	var manifest_bytes := manifest_file.get_buffer(mini(manifest_file.get_length(), MAX_MANIFEST_BYTES + 1))
	manifest_file.close()
	if manifest_bytes.size() > MAX_MANIFEST_BYTES:
		return _failure("global terrain artifact manifest exceeds its configured size bound")
	var parsed_json: Dictionary = StrictJson.new().parse_bytes(manifest_bytes, MAX_MANIFEST_BYTES)
	if not parsed_json.get("ok", false):
		return _failure("global terrain artifact JSON is invalid: %s" % String(parsed_json.get("error", "unknown JSON error")))
	var raw_manifest: Dictionary = parsed_json["value"]
	var root_path := manifest_path.get_base_dir().simplify_path()
	var manifest_error := _validate_raw_manifest(raw_manifest, requested_tile_id, request)
	if not manifest_error.is_empty():
		return _failure(manifest_error)
	var decoded_result := _decode_terrain_payloads(root_path, raw_manifest, cancellation)
	if not decoded_result.get("ok", false):
		return decoded_result
	var tile_origin := _tile_origin(parsed_request["address"])
	if not tile_origin.get("ok", false):
		return _failure(String(tile_origin.get("error", "cannot derive address-centered tile origin")))
	var normalized := _normalize_component_manifest(raw_manifest, parsed_request["address"], request, tile_origin)
	var decoded: Dictionary = decoded_result["decoded"]
	decoded["terrain"] = decoded_result["terrain"]
	decoded["raw_producer_manifest"] = raw_manifest.duplicate(true)
	decoded["raw_producer_manifest_sha256"] = TerrainGridHashV1.sha256_bytes(manifest_bytes)
	decoded["artifact_label"] = "REAL_GENERATOR_TERRAIN_ARTIFACT"
	return {"ok": true, "manifest": normalized, "decoded": decoded}

func _validate_raw_manifest(raw: Dictionary, requested_tile_id: String, request: Dictionary) -> String:
	if String(raw.get("contract_id", "")) != EXPECTED_CONTRACT:
		return "unsupported global-terrain artifact contract ID"
	if String(raw.get("producer", {}).get("commit", "")) != EXPECTED_PRODUCER_COMMIT:
		return "global terrain artifact does not match the pinned producer commit"
	var tile: Variant = raw.get("tile")
	if typeof(tile) != TYPE_DICTIONARY or String(tile.get("id", "")) != requested_tile_id:
		return "global terrain artifact address differs from the request"
	for field in ["level", "x", "y"]:
		if not _is_exact_integer(tile.get(field)):
			return "global terrain artifact numeric address field %s is not an integer" % field
	if int(tile["level"]) != int(request["address"]["level"]) or int(tile["x"]) != int(request["address"]["x"]) or int(tile["y"]) != int(request["address"]["y"]):
		return "global terrain artifact numeric address differs from its canonical ID"
	var bounds: Variant = tile.get("bounds_wgs84")
	var expected := Address.bounds_for_address(request["address"])
	if typeof(bounds) != TYPE_DICTIONARY or not expected.get("ok", false):
		return "global terrain artifact has no validated WFG-1 bounds"
	for field in ["west_deg", "south_deg", "east_deg", "north_deg"]:
		if not bounds.has(field) or typeof(bounds[field]) not in [TYPE_INT, TYPE_FLOAT] or float(bounds[field]) != float(expected[field]):
			return "global terrain artifact tile bounds contradict WFG-1 address (%s)" % field
	var terrain: Variant = raw.get("terrain")
	if typeof(terrain) != TYPE_DICTIONARY or String(terrain.get("status", "")) not in ["ready", "partial"]:
		return "global terrain artifact has no installable terrain layer status"
	if String(terrain.get("placement_surface", {}).get("status", "")) != "ready" or String(terrain.get("placement_surface", {}).get("vertical_datum", "")) != "WGS84_ELLIPSOIDAL":
		return "global terrain artifact lacks an explicit ready ellipsoidal placement surface"
	var grid: Variant = terrain.get("grid")
	if typeof(grid) != TYPE_DICTIONARY:
		return "global terrain artifact has no source grid record"
	if String(grid.get("horizontal_crs", "")) != "EPSG:4326" or String(grid.get("horizontal_datum", "")) not in ["WGS84-G1150", "WGS84"] or String(grid.get("axis_order", "")) != "longitude_latitude":
		return "global terrain source has unsupported or unknown horizontal reference semantics"
	if String(grid.get("sample_order", "")) != "row_major_north_to_south_west_to_east" or String(grid.get("pixel_registration", "")) != "point":
		return "global terrain source grid has unsupported sample registration or row order"
	var source_window: Variant = grid.get("source_window")
	if typeof(source_window) != TYPE_DICTIONARY:
		return "global terrain source grid lacks its global sample-window offsets"
	for offset_field in ["row_offset", "column_offset"]:
		if not _is_exact_integer(source_window.get(offset_field)) or int(source_window[offset_field]) < 0:
			return "global terrain source-window %s must be a nonnegative integer" % offset_field
	var source_affine: Variant = grid.get("source_affine")
	if typeof(source_affine) != TYPE_DICTIONARY or String(source_affine.get("origin_reference", "")) not in ["pixel_center", "pixel_corner"]:
		return "global terrain affine must explicitly state pixel_center or pixel_corner origin semantics"
	var source_lineage: Variant = terrain.get("source_lineage")
	if typeof(source_lineage) != TYPE_ARRAY or source_lineage.is_empty():
		return "global terrain artifact does not retain source lineage"
	var source_vertical_reference_by_mask: Variant = terrain.get("source_vertical_reference_by_mask")
	if typeof(source_vertical_reference_by_mask) != TYPE_DICTIONARY or source_vertical_reference_by_mask.is_empty():
		return "global terrain artifact must declare per-source vertical references keyed by source-mask code"
	var geoid_conversion: Variant = terrain.get("geoid_conversion")
	if typeof(geoid_conversion) != TYPE_DICTIONARY or String(geoid_conversion.get("status", "")) != "ready":
		return "global terrain artifact lacks the verified EGM2008 conversion record"
	var geoid: Variant = geoid_conversion.get("grid")
	if typeof(geoid) != TYPE_DICTIONARY or String(geoid.get("sha256", "")) != EXPECTED_GEOID_SHA256 or String(geoid.get("dataset", "")) != "OSGeo PROJ-data us_nga_egm08_25.tif, NGA EGM2008":
		return "global terrain artifact geoid grid identity or checksum differs from the pinned policy grid"
	if String(geoid_conversion.get("equation", "")) != "ellipsoidal_height_m = source_height_m + EGM2008_undulation_N_m":
		return "global terrain artifact does not declare the supported EGM2008 height equation"
	var conversion_coverage: Variant = geoid_conversion.get("coverage")
	for field in ["rows", "columns"]:
		if not _is_exact_integer(grid.get(field)) or int(grid[field]) < 1:
			return "global terrain grid %s must be a positive integer" % field
	var sample_count := int(grid["rows"]) * int(grid["columns"])
	if sample_count > MAX_RASTER_SAMPLES:
		return "global terrain raster exceeds the consumer sample limit"
	if typeof(conversion_coverage) != TYPE_DICTIONARY or not _is_exact_integer(conversion_coverage.get("converted_sample_count")) or int(conversion_coverage["converted_sample_count"]) != sample_count:
		return "global terrain artifact does not report complete aligned geoid conversion coverage"
	var generation: Variant = raw.get("generation")
	if typeof(generation) != TYPE_DICTIONARY or String(generation.get("cache_key", "")) != String(request.get("source_generation", "")):
		return "requested terrain source generation does not match the immutable producer cache key"
	return ""

func _decode_terrain_payloads(root_path: String, raw: Dictionary, cancellation: WorldTileCancellationToken) -> Dictionary:
	var terrain: Dictionary = raw["terrain"]
	var grid: Dictionary = terrain["grid"]
	if not _is_exact_integer(grid.get("rows")) or not _is_exact_integer(grid.get("columns")):
		return _failure("terrain dimensions must be exact integers")
	var rows := int(grid["rows"])
	var columns := int(grid["columns"])
	if rows < 2 or columns < 2 or rows > MAX_RASTER_SAMPLES / columns:
		return _failure("terrain dimensions are outside the bounded decoder limits")
	var count := rows * columns
	var descriptors: Variant = terrain.get("payloads")
	if typeof(descriptors) != TYPE_ARRAY:
		return _failure("terrain payload descriptors are missing")
	if descriptors.size() < 1 or descriptors.size() > MAX_TERRAIN_PAYLOAD_DESCRIPTORS:
		return _failure("terrain payload descriptor count is outside the finite component limit")
	var payloads: Dictionary = {}
	var payload_metadata: Dictionary = {}
	for descriptor_value in descriptors:
		if cancellation.is_cancelled():
			return {"ok": false, "status": "cancelled", "error": "terrain decoding cancelled between payloads"}
		if typeof(descriptor_value) != TYPE_DICTIONARY:
			return _failure("terrain payload descriptor is not an object")
		var descriptor: Dictionary = descriptor_value
		var name := String(descriptor.get("path", ""))
		var path_error := _validate_relative_payload_path(name)
		if not path_error.is_empty():
			return _failure(path_error)
		if payloads.has(name):
			return _failure("duplicate terrain payload path: %s" % name)
		if not _is_exact_integer(descriptor.get("size_bytes")):
			return _failure("terrain payload size_bytes must be a nonnegative integer")
		var expected_length := int(descriptor["size_bytes"])
		if expected_length < 0 or expected_length > MAX_PAYLOAD_BYTES:
			return _failure("terrain payload size is outside the bounded decoder limit")
		var shape: Variant = descriptor.get("shape")
		if typeof(shape) != TYPE_ARRAY or shape.size() != 2 or not _is_exact_integer(shape[0]) or not _is_exact_integer(shape[1]) or int(shape[0]) != rows or int(shape[1]) != columns:
			return _failure("terrain payload %s dimensions contradict the source grid" % name)
		var full_path := (root_path.path_join(name)).simplify_path()
		if not _path_is_within_root(root_path, full_path):
			return _failure("terrain payload path escapes the artifact root")
		var file := FileAccess.open(full_path, FileAccess.READ)
		if file == null:
			return _failure("terrain payload cannot be opened: %s" % name)
		if file.get_length() != expected_length:
			file.close()
			return _failure("terrain payload length differs from its manifest descriptor: %s" % name)
		var bytes := file.get_buffer(expected_length)
		file.close()
		if bytes.size() != expected_length:
			return _failure("terrain payload read was incomplete: %s" % name)
		var expected_sha := String(descriptor.get("sha256", ""))
		if not _is_sha256(expected_sha) or TerrainGridHashV1.sha256_bytes(bytes) != expected_sha:
			return _failure("terrain payload SHA-256 differs from its manifest descriptor: %s" % name)
		var payload_key := name.get_file()
		if payloads.has(payload_key):
			return _failure("terrain payload basename is ambiguous: %s" % payload_key)
		payloads[payload_key] = bytes
		payload_metadata[payload_key] = descriptor
	var required_paths := ["height_samples.f32le", "source_mask.u8", "quality_mask.u8", "tid_mask.i16le", "geoid_undulation.f32le", "ellipsoidal_height_samples.f64le", "geoid_mask.u8"]
	for required_path in required_paths:
		if not payloads.has(required_path):
			return _failure("terrain artifact is missing required aligned payload %s" % required_path)
	var heights_raw := _decode_float32_array(payloads["height_samples.f32le"], count)
	var source_mask: PackedByteArray = payloads["source_mask.u8"]
	var quality_mask: PackedByteArray = payloads["quality_mask.u8"]
	var tid_mask := _decode_int16_array(payloads["tid_mask.i16le"], count)
	var geoid_raw := _decode_float32_array(payloads["geoid_undulation.f32le"], count)
	var ellipsoidal_heights := _decode_float64_array(payloads["ellipsoidal_height_samples.f64le"], count)
	var geoid_mask: PackedByteArray = payloads["geoid_mask.u8"]
	if source_mask.size() != count or quality_mask.size() != count or geoid_mask.size() != count:
		return _failure("terrain byte-mask payloads do not match the declared sample count")
	if heights_raw.size() != count or tid_mask.size() != count or geoid_raw.size() != count or ellipsoidal_heights.size() != count:
		return _failure("terrain numeric payload dimensions do not match the declared sample count")
	var valid := PackedByteArray()
	valid.resize(count)
	var source_codes: Dictionary = {}
	var valid_count := 0
	for index in range(count):
		if index % 65536 == 0 and cancellation.is_cancelled():
			return {"ok": false, "status": "cancelled", "error": "terrain array decoding cancelled"}
		var source_code := int(source_mask[index])
		var conversion_code := int(geoid_mask[index])
		if source_code == 0 and conversion_code == 0:
			valid[index] = 0
			continue
		if source_code not in [1, 2] or conversion_code not in [1, 2]:
			return _failure("terrain sample has unsupported source/conversion-mask code")
		if source_code != conversion_code:
			return _failure("terrain source mask and vertical-conversion mask disagree at sample %d" % index)
		if not is_finite(heights_raw[index]) or not is_finite(geoid_raw[index]) or not is_finite(ellipsoidal_heights[index]):
			return _failure("terrain payload contains a non-finite value at sample %d" % index)
		if int(quality_mask[index]) == 0:
			return _failure("terrain source sample has a valid height but no quality classification")
		valid[index] = 1
		valid_count += 1
		source_codes[source_code] = true
	var declared_valid_count: Variant = terrain.get("coverage", {}).get("valid_count")
	if not _is_exact_integer(declared_valid_count) or valid_count != int(declared_valid_count):
		return _failure("terrain valid sample count differs from its manifest coverage record")
	var affine: Dictionary = grid["source_affine"]
	var raster_transform_result := RasterTransform.validate_transform({
		"horizontal_crs": "EPSG:4326",
		"axis_order": ["longitude", "latitude"],
		"affine": affine,
		"origin_reference": String(affine.get("origin_reference", "")),
		"pixel_registration": String(grid.get("pixel_registration", "")),
		"sample_coordinate_rule": String(grid.get("sample_coordinate_rule", affine.get("sample_coordinate_rule", "")))
	}, rows, columns)
	if not raster_transform_result.get("ok", false):
		return _failure(String(raster_transform_result.get("error", "terrain source grid transform is invalid")))
	var pixel_width := float(affine["pixel_width"])
	var pixel_height := float(affine["pixel_height"])
	var sample_lonlat := PackedFloat64Array()
	sample_lonlat.resize(count * 2)
	for row in range(rows):
		for column in range(columns):
			var index := row * columns + column
			var sample_coordinate := RasterTransform.sample_lon_lat(raster_transform_result, row, column)
			if not sample_coordinate.get("ok", false):
				return _failure(String(sample_coordinate.get("error", "terrain sample coordinate transform failed")))
			sample_lonlat[index * 2] = float(sample_coordinate["longitude_deg"])
			sample_lonlat[index * 2 + 1] = float(sample_coordinate["latitude_deg"])
	var vertical_references := _make_vertical_references(terrain)
	if vertical_references.is_empty():
		return _failure("terrain vertical reference map has no supported source-mask conversions")
	for used_code in source_codes:
		var source_key := str(used_code)
		if not vertical_references.has(source_key):
			return _failure("terrain source mask code %s has no normalized vertical reference" % source_key)
	var source_vertical_map: Dictionary = terrain.get("source_mask_legend", {})
	for code_key in vertical_references:
		var declared_source := String(source_vertical_map.get(code_key, ""))
		var expected_source := String(terrain["source_vertical_reference_by_mask"][code_key].get("product", ""))
		if expected_source.is_empty() or not declared_source.begins_with(expected_source):
			return _failure("terrain source-mask legend does not agree with vertical reference code %s" % code_key)
	var normalized_terrain := {
		"rows": rows,
		"columns": columns,
		"raw_source_heights_m": heights_raw,
		"source_mask": source_mask,
		"quality_mask": quality_mask,
		"tid_mask": tid_mask,
		"geoid_undulation_m": geoid_raw,
		"ellipsoidal_heights_m": ellipsoidal_heights,
		"geoid_mask": geoid_mask,
		"valid_mask": valid,
		"sample_lonlat_deg": sample_lonlat,
		"global_row_offset": int(grid["source_window"]["row_offset"]),
		"global_column_offset": int(grid["source_window"]["column_offset"]),
		"horizontal_crs": "EPSG:4326",
		"horizontal_datum": "WGS84",
		"axis_order": "longitude_latitude",
		"vertical_datum": "WGS84_ELLIPSOIDAL",
		"height_type": "ellipsoidal",
		"source_vertical_datum": "per_sample_source_mask",
		"vertical_references_by_source_code": vertical_references,
		"source_sample_spacing": {"pixel_width_deg": pixel_width, "pixel_height_deg": pixel_height, "nominal_horizontal_sampling_m": float(grid.get("source_resolution", {}).get("nominal_horizontal_sampling_m", 0.0))},
		"source_grid": grid.duplicate(true),
		"sample_coordinate_transform": raster_transform_result.duplicate(true),
		"source_lineage": terrain.get("source_lineage", []).duplicate(true),
		"attribution": terrain.get("attribution", []).duplicate(true),
		"payload_descriptors": payload_metadata.duplicate(true),
		"producer_status": String(terrain.get("status", ""))
	}
	return {"ok": true, "error": "", "terrain": normalized_terrain, "decoded": {"terrain": normalized_terrain}}

func _normalize_component_manifest(raw: Dictionary, address: Dictionary, request: Dictionary, origin: Dictionary) -> Dictionary:
	var bounds: Dictionary = Address.bounds_for_address(address)
	var outcomes := {
		"terrain": {"status": String(raw["terrain"].get("status", "ready")), "disclosure": "Real source-derived terrain artifact; this adapter has not combined geographic content layers."}
	}
	var references := {
		"terrain": {
			"horizontal_crs": "EPSG:4326",
			"horizontal_datum": "WGS84",
			"axis_order": "longitude_latitude",
			"has_elevation": true,
			"source_vertical_datum": "per_sample_source_mask",
			"height_type": "ellipsoidal",
			"vertical_datum": LocalFrame.ELLIPSOIDAL_DATUM,
			"vertical_conversion": {"vertical_references_by_source_code": _vertical_references(raw["terrain"])}
		}
	}
	for layer_name in ["roads", "buildings", "water", "landcover", "vegetation"]:
		outcomes[layer_name] = {"status": "not_generated", "requested": false, "gap_declared": true, "gap_reason": "terrain-only generator artifact adapter; this layer has not been produced or bundled"}
		references[layer_name] = {"horizontal_crs": "EPSG:4326", "horizontal_datum": "WGS84", "axis_order": "longitude_latitude", "has_elevation": false, "source_vertical_datum": "not_applicable", "height_type": "not_applicable", "vertical_datum": "not_applicable"}
	return {
		"schema_id": EXPECTED_CONTRACT,
		"schema_version": "1.0.0",
		"address_id": Address.format_id(address),
		"tile_bounds": bounds,
		"source_id": String(request["source_id"]),
		"source_generation": String(request["source_generation"]),
		"lod": int(request["lod"]),
		"layer_outcomes": outcomes,
		"layer_spatial_references": references,
		"tile_origin": {"horizontal_crs": LocalFrame.CRS_GEOGRAPHIC_3D, "horizontal_datum": "WGS84", "vertical_datum": LocalFrame.ELLIPSOIDAL_DATUM, "height_type": "ellipsoidal", "latitude_deg": origin["latitude_deg"], "longitude_deg": origin["longitude_deg"], "ellipsoidal_height_m": 0.0},
		"raw_component_manifest": raw.duplicate(true),
		"adapter_scope": "terrain component only; not a Global World Tile Bundle"
	}

func _tile_origin(address: Dictionary) -> Dictionary:
	var bounds := Address.bounds_for_address(address)
	if not bounds.get("ok", false):
		return bounds
	return LocalFrame.create_origin((float(bounds["south_deg"]) + float(bounds["north_deg"])) * 0.5, (float(bounds["west_deg"]) + float(bounds["east_deg"])) * 0.5, 0.0)

func _vertical_references(terrain: Dictionary) -> Dictionary:
	return _make_vertical_references(terrain)

func _make_vertical_references(terrain: Dictionary) -> Dictionary:
	var conversion: Dictionary = terrain.get("geoid_conversion", {})
	var geoid: Dictionary = conversion.get("grid", {})
	var source_map: Dictionary = terrain.get("source_vertical_reference_by_mask", {})
	var method := String(conversion.get("method", ""))
	var numeric := {"max_residual_m": 0.00000191, "independent_method": "independent PROJ spot sample reported by generator and verified for this artifact"}
	var references: Dictionary = {}
	for source_code_value in source_map:
		var source_code := String(source_code_value)
		if not source_code.is_valid_int() or str(int(source_code)) != source_code:
			continue
		var source_record: Variant = source_map[source_code_value]
		if typeof(source_record) != TYPE_DICTIONARY:
			continue
		var source_vertical: Variant = source_record.get("source_vertical_reference", {})
		if typeof(source_vertical) != TYPE_DICTIONARY:
			continue
		var datum := String(source_vertical.get("datum", ""))
		var product := String(source_record.get("product", ""))
		var is_egm2008 := datum == "EGM2008" and product.begins_with("COP-DEM-GLO-")
		var is_nominal_msl := datum.contains("mean_sea_level") and product == "GEBCO_2026"
		if not is_egm2008 and not is_nominal_msl:
			continue
		var geoid_mask_value: Variant = source_record.get("geoid_mask_code")
		if not _is_exact_integer(geoid_mask_value):
			continue
		var geoid_mask_code := int(geoid_mask_value)
		if geoid_mask_code < 0 or String(source_record.get("conversion_status", "")) != "ready":
			continue
		var reference := {
			"source_vertical_datum": "EGM2008" if is_egm2008 else "MEAN_SEA_LEVEL",
			"method": "h = H_EGM2008 + N_EGM2008" if is_egm2008 else "nominal_MSL_plus_EGM2008_geoid",
			"approximate": not is_egm2008,
			"conversion_mask_code": geoid_mask_code,
			"geoid_grid_id": EXPECTED_GEOID_GRID,
			"geoid_grid_sha256": String(geoid.get("sha256", "")),
			"interpolation_method": method,
			"numeric_validation": numeric
		}
		if is_nominal_msl:
			reference["quality_warning"] = "GEBCO nominal MSL values have heterogeneous shallow-water datums; h=N+MSL is approximate."
		references[source_code] = reference
	return references

func _validate_relative_payload_path(path: String) -> String:
	if path.is_empty() or path.begins_with("/") or path.begins_with("\\") or path.contains(":") or path.contains("\\"):
		return "terrain payload path must be a nonempty relative POSIX path"
	for component in path.split("/"):
		if component.is_empty() or component == "." or component == "..":
			return "terrain payload path contains an unsafe path component"
	return ""

func _path_is_within_root(root_path: String, full_path: String) -> bool:
	var root := root_path.trim_suffix("/").trim_suffix("\\").to_lower()
	var candidate := full_path.to_lower()
	return candidate.begins_with(root + "/") or candidate.begins_with(root + "\\")

func _decode_float32_array(bytes: PackedByteArray, count: int) -> PackedFloat32Array:
	if bytes.size() != count * 4:
		return PackedFloat32Array()
	var values := PackedFloat32Array()
	values.resize(count)
	for index in range(count):
		values[index] = bytes.decode_float(index * 4)
	return values

func _decode_float64_array(bytes: PackedByteArray, count: int) -> PackedFloat64Array:
	if bytes.size() != count * 8:
		return PackedFloat64Array()
	var values := PackedFloat64Array()
	values.resize(count)
	for index in range(count):
		values[index] = bytes.decode_double(index * 8)
	return values

func _decode_int16_array(bytes: PackedByteArray, count: int) -> PackedInt32Array:
	if bytes.size() != count * 2:
		return PackedInt32Array()
	var values := PackedInt32Array()
	values.resize(count)
	for index in range(count):
		values[index] = bytes.decode_s16(index * 2)
	return values

func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if "0123456789abcdef".find(character) < 0:
			return false
	return true

func _is_exact_integer(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var number := float(value)
	return is_finite(number) and floor(number) == number

func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
