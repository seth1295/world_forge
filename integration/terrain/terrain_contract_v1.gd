class_name TerrainContractV1
extends RefCounted

const CONTRACT_ID := "urn:worldforge:contract:terrain-grid:1.0.0"
const MAX_MANIFEST_BYTES := 65_536
const MAX_SAMPLES := 4_194_304
const MAX_HORIZONTAL_BYTES := 67_108_864
const MAX_HEIGHT_BYTES := 16_777_216
const HORIZONTAL_FILE := "horizontal_xy.f64le"
const HEIGHT_FILE := "height_samples.f32le"
const HORIZONTAL_ENCODING := "ieee754_binary64_le_easting_northing_pairs"
const HEIGHT_ENCODING := "ieee754_binary32_le_metres"
const SOURCE_FOOTPRINT_TOLERANCE_DEG := 0.000000000001

static func validate_manifest(manifest: Dictionary, schema: Dictionary, approved_site: Dictionary = {}, allow_synthetic_test_vector: bool = false) -> Dictionary:
    var schema_error := TerrainSchemaV1.validate(manifest, schema)
    if not schema_error.is_empty():
        return _failure(schema_error)
    var semantic_error := _validate_semantics(manifest, approved_site, allow_synthetic_test_vector)
    if not semantic_error.is_empty():
        return _failure(semantic_error)
    var frame_hash := TerrainGridHashV1.compute_frame_hash(manifest["frame"])
    if frame_hash.is_empty() or frame_hash != manifest["frame_definition_sha256"]:
        return _failure("frame_definition_sha256 does not match canonical frame bytes")
    if not approved_site.is_empty() and frame_hash != approved_site.get("frame_definition_sha256", ""):
        return _failure("frame definition differs from the approved site frame")
    var artifact_id := TerrainGridHashV1.compute_artifact_id(manifest, frame_hash)
    if artifact_id.is_empty() or artifact_id != manifest["artifact_id"]:
        return _failure("artifact_id does not match canonical artifact bytes")
    if not approved_site.is_empty() and artifact_id != approved_site.get("artifact_id", ""):
        return _failure("artifact_id differs from the requested site artifact")
    return {"ok": true, "error": "", "frame_hash": frame_hash, "artifact_id": artifact_id}

static func validate_dimensions_and_files(manifest: Dictionary) -> Dictionary:
    var grid: Dictionary = manifest["grid"]
    var window: Dictionary = grid["source_window"]
    var rows := int(grid["rows"])
    var columns := int(grid["columns"])
    if rows < 2 or rows > 4096 or columns < 2 or columns > 4096:
        return _failure("grid rows/columns are outside v1 bounds")
    if rows > MAX_SAMPLES / columns:
        return _failure("grid sample count exceeds the v1 maximum")
    var sample_count := rows * columns
    var expected_xy := sample_count * 16
    var expected_heights := sample_count * 4
    var payloads: Dictionary = manifest["payloads"]
    var xy: Dictionary = payloads["horizontal_xy"]
    var heights: Dictionary = payloads["height_samples"]
    if xy["path"] != HORIZONTAL_FILE or xy["encoding"] != HORIZONTAL_ENCODING:
        return _failure("unsupported horizontal payload path or encoding")
    if heights["path"] != HEIGHT_FILE or heights["encoding"] != HEIGHT_ENCODING:
        return _failure("unsupported height payload path or encoding")
    if int(xy["byte_length"]) != expected_xy or expected_xy > MAX_HORIZONTAL_BYTES:
        return _failure("horizontal payload length does not match grid dimensions or cap")
    if int(heights["byte_length"]) != expected_heights or expected_heights > MAX_HEIGHT_BYTES:
        return _failure("height payload length does not match grid dimensions or cap")
    var source: Dictionary = manifest["source"]
    var raster: Dictionary = source["raster"]
    var source_window: Dictionary = grid["source_window"]
    if int(source_window["rows"]) != rows or int(source_window["columns"]) != columns:
        return _failure("grid and source-window dimensions differ")
    if int(source_window["row_offset"]) > 100000 - rows or int(source_window["column_offset"]) > 100000 - columns:
        return _failure("source window addition exceeds checked integer limits")
    if int(source_window["row_offset"]) + rows > int(raster["height"]) or int(source_window["column_offset"]) + columns > int(raster["width"]):
        return _failure("source window lies outside source raster")
    if int(window["row_offset"]) != int(source_window["row_offset"]) or int(window["column_offset"]) != int(source_window["column_offset"]):
        return _failure("source-window fields are inconsistent")
    return {"ok": true, "error": "", "rows": rows, "columns": columns, "sample_count": sample_count, "horizontal_bytes": expected_xy, "height_bytes": expected_heights}

static func _validate_semantics(manifest: Dictionary, approved_site: Dictionary, allow_synthetic: bool) -> String:
    if manifest.get("contract_id", "") != CONTRACT_ID:
        return "unsupported v1 contract id"
    var source: Dictionary = manifest["source"]
    var raster: Dictionary = source["raster"]
    var frame: Dictionary = manifest["frame"]
    var horizontal: Dictionary = frame["horizontal"]
    var vertical: Dictionary = frame["vertical"]
    var origin: Dictionary = frame["origin"]
    var grid: Dictionary = manifest["grid"]
    var bounds: Dictionary = grid["projected_sample_bounds_m"]
    if frame["frame_id"] != bounds["frame_id"]:
        return "projected-bounds and frame IDs must match"
    if horizontal["source_crs"] != "EPSG:4269" or horizontal["source_axis_order"] != "longitude_latitude":
        return "v1 horizontal source CRS or axis order is unsupported"
    if horizontal["datum"] != "NAD83" or horizontal["ellipsoid"] != "GRS80" or horizontal["realization_epoch"] != "unspecified_by_source_metadata":
        return "v1 horizontal source datum/ellipsoid identity is unsupported"
    if horizontal["projection_method"] != "ellipsoidal_azimuthal_equidistant" or horizontal["projected_axis_order"] != "easting_northing" or horizontal["unit"] != "metre":
        return "v1 regional projection semantics are unsupported"
    if vertical["datum"] != "NAVD88" or vertical["height_type"] != "orthometric" or vertical["unit"] != "metre" or vertical["local_up_expression"] != "H-H0":
        return "v1 vertical semantics are unsupported"
    if raster["horizontal_crs"] != "EPSG:4269" or raster["horizontal_datum"] != "NAD83" or raster["ellipsoid"] != "GRS80":
        return "source raster horizontal identity is unsupported"
    if raster["realization_epoch"] != "unspecified_by_source_metadata" or raster["vertical_datum"] != "NAVD88" or raster["vertical_height_type"] != "orthometric" or raster["vertical_unit"] != "metre":
        return "source raster vertical identity is unsupported"
    if raster["dtype"] != "float32" or int(raster["band"]) != 1 or float(raster["scale"]) != 1.0 or float(raster["offset"]) != 0.0 or raster["pixel_interpretation"] != "area":
        return "unsupported source raster layout"
    var affine: Dictionary = raster["affine"]
    if float(affine["rotation_x"]) != 0.0 or float(affine["rotation_y"]) != 0.0 or float(affine["pixel_width"]) <= 0.0 or float(affine["pixel_height"]) >= 0.0:
        return "v1 requires a north-up raster affine transform"
    var window: Dictionary = grid["source_window"]
    var generation: Dictionary = manifest["generation"]
    if generation["source_window"] != window or generation["resampling"] != "none" or grid["resampling"] != "none" or int(grid["sample_stride"]) != 1:
        return "generation and grid source-window semantics differ"
    var source_origin: Dictionary = grid["source_pixel_footprint_bounds"]
    var x0 := float(affine["x_origin"])
    var y0 := float(affine["y_origin"])
    var dx := float(affine["pixel_width"])
    var dy := float(affine["pixel_height"])
    var row_offset := int(window["row_offset"])
    var column_offset := int(window["column_offset"])
    var rows := int(grid["rows"])
    var columns := int(grid["columns"])
    if not _near_number(source_origin["west_deg"], x0 + column_offset * dx, SOURCE_FOOTPRINT_TOLERANCE_DEG) or not _near_number(source_origin["east_deg"], x0 + (column_offset + columns) * dx, SOURCE_FOOTPRINT_TOLERANCE_DEG):
        return "source footprint longitude bounds do not match source affine/window"
    if not _near_number(source_origin["north_deg"], y0 + row_offset * dy, SOURCE_FOOTPRINT_TOLERANCE_DEG) or not _near_number(source_origin["south_deg"], y0 + (row_offset + rows) * dy, SOURCE_FOOTPRINT_TOLERANCE_DEG):
        return "source footprint latitude bounds do not match source affine/window"
    if origin["source_product_id"] != source["product_id"] or origin["source_raster_sha256"] != raster["sha256"]:
        return "frame origin does not identify the manifest source raster"
    if int(origin["source_row"]) >= int(raster["height"]) or int(origin["source_column"]) >= int(raster["width"]):
        return "frame anchor lies outside source raster"
    if not is_finite(float(origin["height_navd88_m"])) or absf(float(origin["height_navd88_m"])) > 12000.0:
        return "frame anchor height is non-finite or outside v1 bounds"
    var projected_bounds: Dictionary = grid["projected_sample_bounds_m"]
    var e_min := float(projected_bounds["easting_min"])
    var e_max := float(projected_bounds["easting_max"])
    var n_min := float(projected_bounds["northing_min"])
    var n_max := float(projected_bounds["northing_max"])
    if e_min > e_max or n_min > n_max or maxf(maxf(absf(e_min), absf(e_max)), maxf(absf(n_min), absf(n_max))) > 100000.0:
        return "projected sample bounds are invalid or exceed regional limits"

    var synthetic: bool = source["provider"] == "SYNTHETIC TEST ONLY" and source["product_id"] == "SYNTHETIC-ONLY"
    if synthetic:
        if not allow_synthetic:
            return "synthetic contract vector is test-only and cannot be loaded as terrain"
        return ""
    if approved_site.is_empty():
        return "source is not tied to an approved site record"
    if frame["frame_id"] != approved_site.get("frame_id", "") or grid["region_id"] != approved_site.get("region_id", ""):
        return "region or frame does not match the approved site record"
    if int(grid["rows"]) != int(approved_site.get("rows", -1)) or int(grid["columns"]) != int(approved_site.get("columns", -1)):
        return "grid dimensions differ from the approved site record"
    if int(origin["source_row"]) != int(approved_site.get("anchor_row", -1)) or int(origin["source_column"]) != int(approved_site.get("anchor_column", -1)):
        return "frame anchor indices differ from the approved site record"
    if not _same_number(origin["longitude_deg"], approved_site.get("anchor_longitude_deg", INF)) or not _same_number(origin["latitude_deg"], approved_site.get("anchor_latitude_deg", INF)):
        return "frame anchor coordinates differ from the approved site record"
    if not _same_number(origin["height_navd88_m"], approved_site.get("anchor_height_navd88_m", INF)):
        return "frame anchor height differs from the approved site record"

    var expected_source: Dictionary = approved_site.get("source", {})
    if expected_source.is_empty():
        return "approved site record is missing source identity"
    for key in expected_source:
        var expected_value: Variant = expected_source[key]
        if typeof(expected_value) == TYPE_DICTIONARY:
            var actual_section: Variant = source.get(key, {})
            if typeof(actual_section) != TYPE_DICTIONARY:
                return "source.%s is not an object" % key
            for subkey in expected_value:
                if not actual_section.has(subkey) or actual_section[subkey] != expected_value[subkey]:
                    return "source.%s.%s differs from approved site record" % [key, subkey]
        elif not source.has(key) or source[key] != expected_value:
            return "source.%s differs from approved site record" % key

    var expected_producer: Dictionary = approved_site.get("producer", {})
    if expected_producer.is_empty():
        return "approved site record is missing producer identity"
    var producer: Dictionary = manifest["producer"]
    for producer_key in expected_producer:
        if not producer.has(producer_key) or producer[producer_key] != expected_producer[producer_key]:
            return "producer.%s differs from approved producer record" % producer_key

    var pipeline := String(horizontal["operation_proj_pipeline"]).to_lower()
    if pipeline.contains("wgs84") or pipeline.contains("wgs 84") or pipeline.contains("towgs84") or pipeline.contains("hgridshift") or pipeline.contains("vgridshift") or pipeline.contains("ballpark") or pipeline.contains("helmert"):
        return "regional v1 pipeline may not bridge to WGS84 or apply an unapproved datum/grid operation"
    if not _has_token(pipeline, "+proj=aeqd") or not (_has_token(pipeline, "+ellps=grs80") or _has_token(pipeline, "+datum=nad83")):
        return "regional v1 pipeline is not the approved same-datum GRS80 AEQD projection"
    var tokens := pipeline.split(" ", false)
    var project_steps := 0
    for token in tokens:
        if token.begins_with("+proj="):
            if token != "+proj=pipeline" and token != "+proj=unitconvert" and token != "+proj=aeqd":
                return "regional v1 pipeline contains an unsupported projection step"
            if token == "+proj=aeqd":
                project_steps += 1
    if project_steps != 1:
        return "regional v1 pipeline must contain exactly one AEQD projection step"
    if not _has_parameter(pipeline, "+lat_0=", float(origin["latitude_deg"])) or not _has_parameter(pipeline, "+lon_0=", float(origin["longitude_deg"])):
        return "regional pipeline anchor does not match manifest origin"
    var wkt := String(horizontal["projection_wkt2"]).to_lower()
    if wkt.contains("wgs 84") or wkt.contains("wgs84"):
        return "regional v1 projection WKT may not substitute WGS84"
    return ""

static func _has_token(text: String, token: String) -> bool:
    return text.split(" ", false).has(token)

static func _has_parameter(text: String, prefix: String, expected: float) -> bool:
    for token in text.split(" ", false):
        if token.begins_with(prefix):
            return String(token.substr(prefix.length())).to_float() == expected
    return false

static func _near_number(left: Variant, right: float, tolerance: float) -> bool:
    return typeof(left) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(left)) and absf(float(left) - right) <= tolerance
static func _same_number(left: Variant, right: Variant) -> bool:
    return typeof(left) in [TYPE_INT, TYPE_FLOAT] and typeof(right) in [TYPE_INT, TYPE_FLOAT] and float(left) == float(right)

static func _failure(message: String) -> Dictionary:
    return {"ok": false, "error": message}