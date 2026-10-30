class_name Wfg1VegetationPlacementV1
extends RefCounted

## Deterministic procedural vegetation proxies for a WFG-1 streamed tile.
##
## Input `decoded.vegetation.placement_support_u8` is produced from WorldCover
## classes, not an individual-plant inventory. Codes 10/20/30 mean tree-cover,
## shrubland, and grassland support; 0 means no proxy. The runtime emits at most
## one visible proxy per configured local spacing cell, chooses a supporting
## source pixel with a stable address-derived hash, and samples the separate
## ellipsoidal terrain grid for its ground position. Meshes are style proxies;
## they make no claim about observed plant locations or species.
const RULE_ID := "worldforge-vegetation-placement-v1"
const DEFAULT_CANDIDATE_SPACING_M := 100.0
const MAX_SUPPORT_SAMPLES := 16_777_216
const MAX_PLACEMENTS_PER_TILE := 1_000_000
const UINT32_MASK := 4_294_967_295
const WORLD_COVER_VEGETATED_CLASS_NAMES := {
	10: "tree_cover",
	20: "shrubland",
	30: "grassland",
	40: "cropland",
	60: "bare_sparse_vegetation",
	90: "herbaceous_wetland",
	95: "mangroves",
	100: "moss_lichen"
}
const Address := preload("res://terrain/wfg1_tile_address.gd")
const LocalFrame := preload("res://terrain/wfg1_local_frame.gd")

## Build a MultiMesh root in the tile-origin tangent frame. The provider adapter
## maps the contract bundle to the normalized dictionaries documented here:
## - `decoded.vegetation.placement_support_u8`, `classes_u8`, `rows`, `columns`,
##   `pixel_center_affine` (`x_origin_deg`, `y_origin_deg`, `pixel_width_deg`,
##   `pixel_height_deg`), `support_class_table`, `provenance`;
## - `decoded.terrain.ellipsoidal_heights_m`, `valid_mask`, `rows`, `columns`,
##   and its separately georeferenced `pixel_center_affine`;
## - `decoded.exclusion_masks` may contain same-sized `coverage`, `land`, `water`,
##   `roads`, and `buildings` masks. Missing feature masks are disclosed.
static func build_tile_nodes(decoded: Dictionary, context: Dictionary, renderer_config: Dictionary = {}) -> Dictionary:
	var tile_id := String(context.get("tile_id", ""))
	var parsed_tile := Address.parse_id(tile_id)
	if not parsed_tile.get("ok", false):
		return _failure("vegetation builder requires a canonical WFG-1 tile ID")
	if not decoded.has("vegetation") or typeof(decoded["vegetation"]) != TYPE_DICTIONARY:
		return _failure("vegetation layer is missing from decoded tile data")
	if not decoded.has("terrain") or typeof(decoded["terrain"]) != TYPE_DICTIONARY:
		return _failure("vegetation requires the separately georeferenced terrain layer")
	var vegetation: Dictionary = decoded["vegetation"]
	var terrain: Dictionary = decoded["terrain"]
	var support: Variant = vegetation.get("placement_support_u8")
	var source_classes: Variant = vegetation.get("classes_u8")
	if typeof(support) != TYPE_PACKED_BYTE_ARRAY or typeof(source_classes) != TYPE_PACKED_BYTE_ARRAY:
		return _failure("vegetation support and WorldCover class payloads must be PackedByteArray")
	var rows := int(vegetation.get("rows", 0))
	var columns := int(vegetation.get("columns", 0))
	var sample_validation := _validate_raster_shape(rows, columns, support.size(), "vegetation support")
	if not sample_validation.is_empty():
		return _failure(sample_validation)
	if source_classes.size() != support.size():
		return _failure("WorldCover class raster and vegetation support dimensions differ")
	var class_mapping_result := _validate_class_mapping(vegetation)
	if not class_mapping_result.get("ok", false):
		return _failure(String(class_mapping_result.get("error", "support class mapping is invalid")))
	var class_mapping: Dictionary = class_mapping_result["mapping"]
	var provenance_error := _validate_provenance(decoded, vegetation)
	if not provenance_error.is_empty():
		return _failure(provenance_error)
	var support_affine := _read_affine(vegetation.get("pixel_center_affine", {}), "vegetation")
	if not support_affine.get("ok", false):
		return _failure(String(support_affine.get("error", "vegetation affine is invalid")))
	var terrain_affine := _read_affine(terrain.get("pixel_center_affine", {}), "terrain")
	if not terrain_affine.get("ok", false):
		return _failure(String(terrain_affine.get("error", "terrain affine is invalid")))
	var terrain_error := _validate_terrain_grid(terrain)
	if not terrain_error.is_empty():
		return _failure(terrain_error)
	var origin: Variant = context.get("tile_origin")
	if typeof(origin) != TYPE_DICTIONARY:
		return _failure("vegetation builder requires the validated WFG-1 tile tangent origin")
	var origin_validation := LocalFrame.validate_frame(origin)
	if not origin_validation.get("ok", false):
		return _failure(String(origin_validation.get("error", "tile origin is inconsistent")))
	var bounds_result := Address.bounds_for_address(parsed_tile["address"])
	if not bounds_result.get("ok", false):
		return _failure("vegetation tile has no WFG-1 bounds")
	var spacing_m := float(renderer_config.get("candidate_spacing_m", DEFAULT_CANDIDATE_SPACING_M))
	if not is_finite(spacing_m) or spacing_m < 10.0 or spacing_m > 10_000.0:
		return _failure("candidate_spacing_m must be finite and within [10, 10000] metres")
	var seed := stable_tile_seed(tile_id)
	if vegetation.has("stable_tile_seed") and int(vegetation["stable_tile_seed"]) != seed:
		return _failure("content producer stable tile seed differs from the runtime WFG-1 seed")
	var masks: Dictionary = decoded.get("exclusion_masks", {})
	var mask_error := _validate_masks(masks, support.size())
	if not mask_error.is_empty():
		return _failure(mask_error)

	var candidates: Dictionary = {}
	var exclusion_counts := {"no_support": 0, "outside_coverage": 0, "outside_land": 0, "water": 0, "invalid_terrain": 0, "roads": 0, "buildings": 0, "outside_tile": 0}
	var support_bytes: PackedByteArray = support
	var class_bytes: PackedByteArray = source_classes
	for sample_index in range(support_bytes.size()):
		var code := int(support_bytes[sample_index])
		if code == 0:
			exclusion_counts["no_support"] += 1
			continue
		if not class_mapping.has(code):
			return _failure("vegetation support contains an unknown nonzero code %d" % code)
		var class_definition: Dictionary = class_mapping[code]
		var expected_source_class := int(class_definition["worldcover_class_value"])
		if int(class_bytes[sample_index]) != expected_source_class:
			return _failure("vegetation support code at index %d disagrees with the retained WorldCover class raster" % sample_index)
		if not _mask_allows(masks, "coverage", sample_index):
			exclusion_counts["outside_coverage"] += 1
			continue
		if not _mask_allows(masks, "land", sample_index):
			exclusion_counts["outside_land"] += 1
			continue
		if _mask_excludes(masks, "water", sample_index):
			exclusion_counts["water"] += 1
			continue
		if _mask_excludes(masks, "roads", sample_index):
			exclusion_counts["roads"] += 1
			continue
		if _mask_excludes(masks, "buildings", sample_index):
			exclusion_counts["buildings"] += 1
			continue
		var row := sample_index / columns
		var column := sample_index % columns
		var longitude := float(support_affine["x_origin_deg"]) + float(column) * float(support_affine["pixel_width_deg"])
		var latitude := float(support_affine["y_origin_deg"]) + float(row) * float(support_affine["pixel_height_deg"])
		var point_address := Address.address_for_lon_lat(longitude, latitude, int(parsed_tile["address"]["level"]))
		if not point_address.get("ok", false) or point_address["address"] != parsed_tile["address"]:
			return _failure("a supported vegetation pixel is outside its declared WFG-1 tile address")
		var center_height := _sample_terrain_height(terrain, longitude, latitude)
		if not center_height.get("ok", false):
			exclusion_counts["invalid_terrain"] += 1
			continue
		var ecef_at_zero := LocalFrame.geodetic_to_ecef_components(latitude, longitude, 0.0, LocalFrame.CRS_GEOGRAPHIC_2D, LocalFrame.ELLIPSOIDAL_DATUM, "ellipsoidal")
		if not ecef_at_zero.get("ok", false):
			return _failure(String(ecef_at_zero.get("error", "support pixel could not be converted to WGS84 ECEF")))
		var local_at_zero := LocalFrame.ecef_to_local(ecef_at_zero["ecef_m"], origin)
		if not local_at_zero.get("ok", false):
			return _failure(String(local_at_zero.get("error", "support pixel is outside the tile tangent frame")))
		var local_position: Vector3 = local_at_zero["local_engine_m"]
		var bin_x := int(floor(local_position.x / spacing_m))
		var bin_z := int(floor(local_position.z / spacing_m))
		var bin_key := "%d:%d:%d" % [code, bin_x, bin_z]
		var score := _candidate_score(seed, row, column, code)
		if not candidates.has(bin_key) or score < int(candidates[bin_key]["score"]):
			candidates[bin_key] = {
				"score": score,
				"row": row,
				"column": column,
				"index": sample_index,
				"code": code,
				"class_name": String(class_definition["class_name"]),
				"worldcover_class_value": expected_source_class,
				"longitude_deg": longitude,
				"latitude_deg": latitude,
				"bin_x": bin_x,
				"bin_z": bin_z
			}
	if candidates.size() > MAX_PLACEMENTS_PER_TILE:
		return _failure("procedural vegetation candidate count exceeds the bounded per-tile limit")

	var bin_keys: Array = candidates.keys()
	bin_keys.sort()
	var counts: Dictionary = {}
	var selected_by_class: Dictionary = {}
	var instances_by_class: Dictionary = {}
	for support_code_value in class_mapping:
		var class_label := String(class_mapping[support_code_value]["class_name"])
		counts[class_label] = 0
		selected_by_class[class_label] = PackedInt32Array()
		instances_by_class[class_label] = []
	var fingerprint := HashingContext.new()
	if fingerprint.start(HashingContext.HASH_SHA256) != OK:
		return _failure("cannot initialize procedural vegetation layout fingerprint")
	for bin_key_value in bin_keys:
		var candidate: Dictionary = candidates[String(bin_key_value)]
		var row := int(candidate["row"])
		var column := int(candidate["column"])
		var code := int(candidate["code"])
		var class_label := String(candidate["class_name"])
		var jitter := _cell_jitter(seed, row, column, code)
		var longitude := float(candidate["longitude_deg"]) + float(jitter[0]) * float(support_affine["pixel_width_deg"])
		var latitude := float(candidate["latitude_deg"]) + float(jitter[1]) * float(support_affine["pixel_height_deg"])
		var point_address := Address.address_for_lon_lat(longitude, latitude, int(parsed_tile["address"]["level"]))
		if not point_address.get("ok", false) or point_address["address"] != parsed_tile["address"]:
			return _failure("deterministic vegetation jitter crossed a WFG-1 tile ownership edge")
		var height_result := _sample_terrain_height(terrain, longitude, latitude)
		if not height_result.get("ok", false):
			exclusion_counts["invalid_terrain"] += 1
			continue
		var ecef_result := LocalFrame.geodetic_to_ecef_components(latitude, longitude, float(height_result["height_m"]), LocalFrame.CRS_GEOGRAPHIC_2D, LocalFrame.ELLIPSOIDAL_DATUM, "ellipsoidal")
		if not ecef_result.get("ok", false):
			return _failure(String(ecef_result.get("error", "procedural plant position could not be converted to WGS84 ECEF")))
		var point_frame := LocalFrame.create_origin(latitude, longitude, float(height_result["height_m"]))
		var point_transform := LocalFrame.tile_transform(point_frame, origin)
		if not point_transform.get("ok", false):
			return _failure(String(point_transform.get("error", "procedural plant position is outside the WFG-1 tile tangent frame")))
		var local_up: Vector3 = point_transform["transform"].basis.y.normalized()
		var scale := 0.85 + float(jitter[2]) * 0.30
		var plant_dimensions := _plant_dimensions(int(candidate["worldcover_class_value"]))
		var orientation := Basis(Quaternion(Vector3.UP, local_up)).scaled(Vector3.ONE * scale)
		var translation: Vector3 = point_transform["transform"].origin + local_up * float(plant_dimensions["height_m"]) * 0.5
		instances_by_class[class_label].append(Transform3D(orientation, translation))
		selected_by_class[class_label].append(int(candidate["index"]))
		counts[class_label] = int(counts[class_label]) + 1
		var fingerprint_row := "%s|%d|%d|%d|%s\n" % [String(bin_key_value), row, column, code, class_label]
		if fingerprint.update(fingerprint_row.to_utf8_buffer()) != OK:
			return _failure("cannot update procedural vegetation fingerprint")

	var root := Node3D.new()
	root.name = "ProceduralVegetation_%s" % tile_id.replace(":", "_")
	var fixture_label := String(decoded.get("fixture_label", ""))
	var is_synthetic_fixture := fixture_label == "SYNTHETIC_TEST_FIXTURE"
	var mask_state := {
		"land_mask_applied": masks.has("land"),
		"coverage_mask_applied": masks.has("coverage"),
		"water_mask_applied": masks.has("water"),
		"road_mask_applied": masks.has("roads"),
		"building_mask_applied": masks.has("buildings")
	}
	var layout_sha256 := fingerprint.finish().hex_encode()
	root.set_meta("wfg1_tile_id", tile_id)
	root.set_meta("vegetation_rule_id", RULE_ID)
	root.set_meta("procedural_representation", "WorldCover cover-class proxy; not an observed individual plant")
	root.set_meta("observed_individual_plant_locations", false)
	root.set_meta("species_claim", "none")
	root.set_meta("candidate_spacing_m", spacing_m)
	root.set_meta("stable_tile_seed_u32", seed)
	root.set_meta("layout_sha256", layout_sha256)
	root.set_meta("source_fixture_label", fixture_label if is_synthetic_fixture else "real_source")
	root.set_meta("exclusion_masks_applied", mask_state)
	root.set_meta("exclusion_mask_disclosure", String(decoded.get("exclusion_mask_disclosure", "")))
	root.set_meta("exclusion_counts", exclusion_counts)
	root.set_meta("placement_counts", counts.duplicate(true))
	root.set_meta("selected_support_pixel_indices", selected_by_class)
	root.set_meta("support_class_table", class_mapping.duplicate(true))
	var layer_outcome_overrides: Dictionary = {}
	var total_placements := 0
	for count_value in counts.values():
		total_placements += int(count_value)
	var missing_vector_masks: Array[String] = []
	for mask_name in ["water", "roads", "buildings"]:
		if not masks.has(mask_name):
			missing_vector_masks.append(mask_name)
	if exclusion_counts["invalid_terrain"] > 0:
		layer_outcome_overrides["vegetation"] = {
			"status": "partial",
			"gap_declared": true,
			"gap_reason": "%d WorldCover support pixels lack a valid colocated terrain sample" % int(exclusion_counts["invalid_terrain"]),
			"disclosure": "Procedural vegetation positions are aligned only where the validated terrain raster supports the source pixel; unsupported locations were omitted."
		}
	elif total_placements > 0 and not missing_vector_masks.is_empty():
		layer_outcome_overrides["vegetation"] = {
			"status": "partial",
			"gap_declared": true,
			"gap_reason": "Overture water/road/building exclusion masks were not rasterized",
			"disclosure": "Procedural cover proxies use WorldCover support and terrain alignment. Overture water, road and building masks were unavailable to placement, so overlaps may occur; locations and species are not observed facts."
		}
	for support_code_value in class_mapping:
		var code := int(support_code_value)
		var class_definition: Dictionary = class_mapping[support_code_value]
		var class_label := String(class_definition["class_name"])
		var instance_transforms: Array = instances_by_class[class_label]
		if instance_transforms.is_empty():
			continue
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = _mesh_for_worldcover_class(int(class_definition["worldcover_class_value"]))
		multimesh.instance_count = instance_transforms.size()
		multimesh.visible_instance_count = instance_transforms.size()
		for instance_index in range(instance_transforms.size()):
			multimesh.set_instance_transform(instance_index, instance_transforms[instance_index])
		var instance_node := MultiMeshInstance3D.new()
		instance_node.name = class_label.capitalize() + "CoverProxies"
		instance_node.multimesh = multimesh
		instance_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		instance_node.set_meta("procedural_representation", "cover-class proxy; not observed plants")
		instance_node.set_meta("source_class_code", code)
		instance_node.set_meta("source_class_name", class_label)
		instance_node.set_meta("worldcover_class_value", int(class_definition["worldcover_class_value"]))
		instance_node.set_meta("species_claim", "none")
		instance_node.set_meta("observed_individual_plant_locations", false)
		instance_node.set_meta("wfg1_tile_id", tile_id)
		root.add_child(instance_node)
	return {
		"ok": true,
		"error": "",
		"node": root,
		"included_layers": PackedStringArray(["vegetation"]),
		"placement_counts": counts,
		"selected_support_pixel_indices": selected_by_class,
		"stable_tile_seed_u32": seed,
		"layout_sha256": layout_sha256,
		"candidate_spacing_m": spacing_m,
		"exclusion_masks_applied": mask_state,
		"exclusion_counts": exclusion_counts,
		"procedural_disclosure": "Rendered positions are deterministic procedural cover proxies selected from WorldCover support pixels. They do not represent observed individual trees, exact plant locations, species, or surveyed heights.",
		"layer_outcome_overrides": layer_outcome_overrides
	}

static func stable_tile_seed(tile_id: String) -> int:
	var hash_context := HashingContext.new()
	if hash_context.start(HashingContext.HASH_SHA256) != OK:
		return -1
	var input := (tile_id + "|" + RULE_ID).to_utf8_buffer()
	if hash_context.update(input) != OK:
		return -1
	var digest := hash_context.finish()
	return (int(digest[0]) << 24) | (int(digest[1]) << 16) | (int(digest[2]) << 8) | int(digest[3])

static func _validate_class_mapping(vegetation: Dictionary) -> Dictionary:
	var table: Variant = vegetation.get("support_class_table")
	if typeof(table) != TYPE_ARRAY or table.is_empty():
		return _failure("vegetation support_class_table must preserve each source category separately")
	var mapping: Dictionary = {}
	var seen_worldcover_values: Dictionary = {}
	for entry_value in table:
		if typeof(entry_value) != TYPE_DICTIONARY:
			return _failure("vegetation support class entries must be dictionaries")
		var entry: Dictionary = entry_value
		for key in ["support_code", "worldcover_class_value", "class_name"]:
			if not entry.has(key):
				return _failure("vegetation support class entry is missing %s" % key)
		var support_code: Variant = entry["support_code"]
		var class_value: Variant = entry["worldcover_class_value"]
		if typeof(support_code) != TYPE_INT or typeof(class_value) != TYPE_INT:
			return _failure("support codes and WorldCover source values must be integers")
		var code := int(support_code)
		var worldcover_value := int(class_value)
		var class_label := String(entry["class_name"])
		if code <= 0 or code > 255 or mapping.has(code):
			return _failure("vegetation support codes must be unique nonzero uint8 values")
		if not WORLD_COVER_VEGETATED_CLASS_NAMES.has(worldcover_value) or WORLD_COVER_VEGETATED_CLASS_NAMES[worldcover_value] != class_label:
			return _failure("support class %s does not map to a selected vegetated WorldCover category" % class_label)
		if seen_worldcover_values.has(worldcover_value):
			return _failure("WorldCover source classes must remain distinct in the support table")
		seen_worldcover_values[worldcover_value] = true
		mapping[code] = {"worldcover_class_value": worldcover_value, "class_name": class_label}
	return {"ok": true, "error": "", "mapping": mapping}

static func _validate_provenance(decoded: Dictionary, vegetation: Dictionary) -> String:
	if String(decoded.get("fixture_label", "")) == "SYNTHETIC_TEST_FIXTURE":
		return ""
	var provenance: Variant = vegetation.get("provenance")
	if typeof(provenance) != TYPE_DICTIONARY:
		return "vegetation source provenance is required"
	if String(provenance.get("provider", "")) != "ESA" or String(provenance.get("product", "")) != "WorldCover" or String(provenance.get("release", "")) != "2021" or String(provenance.get("algorithm_version", "")) != "v200":
		return "vegetation support source is not the selected ESA WorldCover 2021 v200 product"
	if String(provenance.get("license", "")) != "CC-BY-4.0":
		return "WorldCover support layer must retain its CC BY 4.0 license record"
	if not _is_sha256(String(provenance.get("support_payload_sha256", ""))) or not _is_sha256(String(provenance.get("class_payload_sha256", ""))) or not _is_sha256(String(provenance.get("source_cog_sha256", ""))):
		return "vegetation support, class raster, and source COG checksums must be explicit"
	return ""

static func _validate_raster_shape(rows: int, columns: int, count: int, name: String) -> String:
	if rows < 1 or columns < 1 or rows > MAX_SUPPORT_SAMPLES or columns > MAX_SUPPORT_SAMPLES:
		return "%s dimensions are outside the declared bounds" % name
	if rows > MAX_SUPPORT_SAMPLES / columns or rows * columns != count:
		return "%s dimensions do not match its bounded sample count" % name
	return ""

static func _read_affine(value: Variant, name: String) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return _failure("%s pixel_center_affine must be a dictionary" % name)
	for key in ["x_origin_deg", "y_origin_deg", "pixel_width_deg", "pixel_height_deg"]:
		if not value.has(key) or typeof(value[key]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value[key])):
			return _failure("%s pixel_center_affine lacks finite %s" % [name, key])
	if float(value["pixel_width_deg"]) <= 0.0 or float(value["pixel_height_deg"]) >= 0.0:
		return _failure("%s affine must be west-to-east and north-to-south pixel-center registered" % name)
	return {"ok": true, "error": "", "x_origin_deg": float(value["x_origin_deg"]), "y_origin_deg": float(value["y_origin_deg"]), "pixel_width_deg": float(value["pixel_width_deg"]), "pixel_height_deg": float(value["pixel_height_deg"])}

static func _validate_terrain_grid(terrain: Dictionary) -> String:
	if String(terrain.get("horizontal_crs", "")) != LocalFrame.CRS_GEOGRAPHIC_2D or String(terrain.get("horizontal_datum", "")) != "WGS84" or String(terrain.get("axis_order", "")) != "longitude_latitude":
		return "vegetation terrain sampler requires normalized WGS84 longitude/latitude"
	if String(terrain.get("vertical_datum", "")) != LocalFrame.ELLIPSOIDAL_DATUM or String(terrain.get("height_type", "")) != "ellipsoidal":
		return "vegetation terrain heights must be explicitly WGS84 ellipsoidal"
	var height_values: Variant = terrain.get("ellipsoidal_heights_m")
	var valid_mask: Variant = terrain.get("valid_mask")
	if typeof(height_values) != TYPE_PACKED_FLOAT64_ARRAY or typeof(valid_mask) != TYPE_PACKED_BYTE_ARRAY:
		return "terrain ellipsoidal height samples and valid mask must be packed double/byte arrays"
	var rows := int(terrain.get("rows", 0))
	var columns := int(terrain.get("columns", 0))
	var shape_error := _validate_raster_shape(rows, columns, height_values.size(), "terrain height grid")
	if not shape_error.is_empty():
		return shape_error
	if valid_mask.size() != height_values.size():
		return "terrain valid mask size differs from terrain height grid"
	for mask_value in valid_mask:
		if mask_value not in [0, 1]:
			return "terrain valid mask values must be 0 or 1"
	return ""

static func _validate_masks(masks: Dictionary, expected_size: int) -> String:
	for mask_name in ["coverage", "land", "water", "roads", "buildings"]:
		if not masks.has(mask_name):
			continue
		var mask: Variant = masks[mask_name]
		if typeof(mask) != TYPE_PACKED_BYTE_ARRAY or mask.size() != expected_size:
			return "%s exclusion mask must be a PackedByteArray matching vegetation support dimensions" % mask_name
		for value in mask:
			if value not in [0, 1]:
				return "%s mask values must be 0 or 1" % mask_name
	return ""

static func _mask_allows(masks: Dictionary, name: String, index: int) -> bool:
	return not masks.has(name) or int(masks[name][index]) == 1

static func _mask_excludes(masks: Dictionary, name: String, index: int) -> bool:
	return masks.has(name) and int(masks[name][index]) == 1

static func _sample_terrain_height(terrain: Dictionary, longitude: float, latitude: float) -> Dictionary:
	var terrain_affine := _read_affine(terrain.get("pixel_center_affine", {}), "terrain")
	if not terrain_affine.get("ok", false):
		return terrain_affine
	var rows := int(terrain["rows"])
	var columns := int(terrain["columns"])
	var column_position := (longitude - float(terrain_affine["x_origin_deg"])) / float(terrain_affine["pixel_width_deg"])
	var row_position := (latitude - float(terrain_affine["y_origin_deg"])) / float(terrain_affine["pixel_height_deg"])
	if not is_finite(column_position) or not is_finite(row_position) or column_position < 0.0 or row_position < 0.0 or column_position > float(columns - 1) or row_position > float(rows - 1):
		return _failure("vegetation candidate lies outside the terrain sample grid")
	var column0 := int(floor(column_position))
	var row0 := int(floor(row_position))
	var column1 := mini(column0 + 1, columns - 1)
	var row1 := mini(row0 + 1, rows - 1)
	var dx := column_position - float(column0)
	var dy := row_position - float(row0)
	var indices := [row0 * columns + column0, row0 * columns + column1, row1 * columns + column0, row1 * columns + column1]
	var weights := [(1.0 - dx) * (1.0 - dy), dx * (1.0 - dy), (1.0 - dx) * dy, dx * dy]
	var heights: PackedFloat64Array = terrain["ellipsoidal_heights_m"]
	var valid: PackedByteArray = terrain["valid_mask"]
	var interpolated_height := 0.0
	for corner in range(4):
		var weight := float(weights[corner])
		if weight <= 1.0e-15:
			continue
		var index := int(indices[corner])
		if int(valid[index]) != 1 or not is_finite(heights[index]):
			return _failure("vegetation candidate terrain sample is no-data or invalid")
		interpolated_height += weight * heights[index]
	if not is_finite(interpolated_height):
		return _failure("vegetation terrain interpolation produced a non-finite height")
	return {"ok": true, "error": "", "height_m": interpolated_height}

static func _candidate_score(seed: int, row: int, column: int, code: int) -> int:
	var state := (seed ^ ((row * 2_654_435_761) & UINT32_MASK) ^ ((column * 2_246_822_519) & UINT32_MASK) ^ code) & UINT32_MASK
	return _next_u32(state)

static func _cell_jitter(seed: int, row: int, column: int, code: int) -> Array[float]:
	var state := _candidate_score(seed, row, column, code)
	state = _next_u32(state)
	var east_fraction := float(state) / 4_294_967_296.0 - 0.5
	state = _next_u32(state)
	var north_fraction := float(state) / 4_294_967_296.0 - 0.5
	state = _next_u32(state)
	var scale_fraction := float(state) / 4_294_967_296.0
	return [east_fraction * 0.5, north_fraction * 0.5, scale_fraction]

static func _next_u32(state: int) -> int:
	var value := state & UINT32_MASK
	value = (value ^ ((value << 13) & UINT32_MASK)) & UINT32_MASK
	value = (value ^ (value >> 17)) & UINT32_MASK
	value = (value ^ ((value << 5) & UINT32_MASK)) & UINT32_MASK
	return value

static func _plant_dimensions(worldcover_class_value: int) -> Dictionary:
	match worldcover_class_value:
		10, 95:
			return {"height_m": 8.0, "base_width_m": 5.0}
		20:
			return {"height_m": 3.5, "base_width_m": 3.8}
		30, 90:
			return {"height_m": 1.5, "base_width_m": 2.4}
		40:
			return {"height_m": 1.2, "base_width_m": 3.0}
		60, 100:
			return {"height_m": 0.7, "base_width_m": 1.8}
	return {"height_m": 0.0, "base_width_m": 0.0}

static func _mesh_for_worldcover_class(worldcover_class_value: int) -> PrimitiveMesh:
	var mesh: PrimitiveMesh
	match worldcover_class_value:
		10, 95:
			var tree := CylinderMesh.new()
			tree.height = 8.0
			tree.top_radius = 0.0
			tree.bottom_radius = 2.5 if worldcover_class_value == 10 else 2.0
			mesh = tree
		20:
			var shrub := SphereMesh.new()
			shrub.height = 3.5
			shrub.radius = 1.9
			mesh = shrub
		30, 90:
			var grass := BoxMesh.new()
			grass.size = Vector3(2.4, 1.5, 2.4) if worldcover_class_value == 30 else Vector3(1.6, 1.5, 1.6)
			mesh = grass
		40:
			var crops := BoxMesh.new()
			crops.size = Vector3(3.0, 1.2, 0.7)
			mesh = crops
		60, 100:
			var sparse_cover := SphereMesh.new()
			sparse_cover.height = 0.7
			sparse_cover.radius = 0.9 if worldcover_class_value == 60 else 0.7
			mesh = sparse_cover
	var material := StandardMaterial3D.new()
	material.roughness = 0.96
	material.metallic = 0.0
	match worldcover_class_value:
		10:
			material.albedo_color = Color(0.20, 0.42, 0.18, 1.0)
		20:
			material.albedo_color = Color(0.34, 0.48, 0.22, 1.0)
		30:
			material.albedo_color = Color(0.48, 0.58, 0.27, 1.0)
		40:
			material.albedo_color = Color(0.68, 0.57, 0.28, 1.0)
		60:
			material.albedo_color = Color(0.56, 0.54, 0.37, 1.0)
		90:
			material.albedo_color = Color(0.29, 0.50, 0.38, 1.0)
		95:
			material.albedo_color = Color(0.20, 0.44, 0.33, 1.0)
		100:
			material.albedo_color = Color(0.58, 0.62, 0.48, 1.0)
	mesh.material = material
	return mesh

static func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if "0123456789abcdef".find(character) < 0:
			return false
	return true

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
