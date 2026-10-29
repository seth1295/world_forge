class_name RoadsFeatureConsumerV1
extends RefCounted

const StrictJson := preload("res://terrain/strict_json_v1.gd")
const SchemaV1 := preload("res://terrain/schema_v1.gd")
const HashV1 := preload("res://terrain/hash_v1.gd")
const TerrainSites := preload("res://terrain/site_catalog_v1.gd")

const CONTRACT_ID := "urn:worldforge:contract:road-centerlines:1.0.0"
const FEATURE_FILE := "golden_roads_v1.json"
const SCHEMA_FILE := "roads_feature_collection_v1.schema.json"
const FIXTURE_FILE := "fixtures/golden_dem_sample_vector_v1.json"
const MAX_FEATURE_BYTES := 4_000_000
const MAX_SCHEMA_BYTES := 100_000
const MAX_FEATURES := 500
const MAX_POINTS_PER_PATH := 100_000
const MAX_PROJECTED_SEGMENT_M := 10.0
const MAX_VIEWER_DISPLAY_SEGMENT_M := 2.0
const BARYCENTRIC_EDGE_GUARD := 1.0e-10
const GRID_HINT_FLOAT_ROUND_TRIP_GUARD_PIXELS := 1.0e-8
const DEFAULT_DISPLAY_OFFSET_M := 3.0

const ARCHIVE_SHA256 := "d0063402ae35789546fbfc3041320aeb139d3b82845d8ca9ab1869dd55df4001"
const ARCHIVE_BYTE_LENGTH := 2842936
const FEATURE_FILE_SHA256 := "c92a254d1e92727fa325fd1ede7fdc5186b86e1ff4ccf0550f0f8eddbe087d96"
const COMPONENT_SHA256 := {
    "tl_2026_08059_roads.cpg": "3ad3031f5503a4404af825262ee8232cc04d4ea6683d42c5dd0a2f2a27ac9824",
    "tl_2026_08059_roads.dbf": "d8a1b9e5ce8f1884dad974b05b14253662cbefafa07a0e0a52ec31ad9df36902",
    "tl_2026_08059_roads.prj": "0b9041e921d9ebb43247d314608fe9e38a0b008ee793067fc1806199ea1fb9dd",
    "tl_2026_08059_roads.shp": "f72b4eafa002de37aa365a181d9a19d723780d86e5ad8d8b65ed9720da58fe62",
    "tl_2026_08059_roads.shp.ea.iso.xml": "02c6ff600b5e42e49ea5e58c4b4c12de63effb58026b90c3c1ca6c5e5dec270c",
    "tl_2026_08059_roads.shp.iso.xml": "71d81812c5db052859d2bfb8d9f832983184f39dad02a40f84ab05394f678f5a",
    "tl_2026_08059_roads.shx": "af4f1884be658f3d56b54a62a19ffc3c5428f30d82f3a453a3b35e4e6fa15946"
}
const COMPONENT_BYTE_LENGTHS := {
    "tl_2026_08059_roads.cpg": 5,
    "tl_2026_08059_roads.dbf": 1934775,
    "tl_2026_08059_roads.prj": 165,
    "tl_2026_08059_roads.shp": 4365708,
    "tl_2026_08059_roads.shp.ea.iso.xml": 21866,
    "tl_2026_08059_roads.shp.iso.xml": 50147,
    "tl_2026_08059_roads.shx": 120076
}
const ROUTE_IDENTITIES := {
    "11012811999747": {"fullname": "S Golden Rd", "rttyp": "M", "mtfcc": "S1400"},
    "1106092818987": {"fullname": "Lookout Mountain Rd", "rttyp": "M", "mtfcc": "S1400"},
    "110713405478": {"fullname": "US Hwy 6", "rttyp": "U", "mtfcc": "S1200"}
}

static func load_bundle(repository_root: String) -> Dictionary:
    var root := repository_root.simplify_path()
    if root.is_empty() or not DirAccess.dir_exists_absolute(root):
        return _failure("repository root is missing")
    var feature_path := root.path_join("integration/features").path_join(FEATURE_FILE)
    var schema_path := root.path_join("contracts").path_join(SCHEMA_FILE)
    var golden_path := root.path_join("integration/assets/terrain/golden/manifest.json")
    var feature_directory := DirAccess.open(feature_path.get_base_dir())
    var schema_directory := DirAccess.open(schema_path.get_base_dir())
    if feature_directory == null or schema_directory == null:
        return _failure("feature or schema directory could not be opened")
    if feature_directory.is_link(feature_path) or schema_directory.is_link(schema_path):
        return _failure("feature contract or schema may not be a symbolic link or reparse point")

    var schema_result := _read_json_object(schema_path, MAX_SCHEMA_BYTES)
    if not schema_result.get("ok", false):
        return _failure("feature schema could not be read: %s" % String(schema_result.get("error", "")))
    var contract_result := _read_json_object(feature_path, MAX_FEATURE_BYTES)
    if not contract_result.get("ok", false):
        return _failure("feature collection could not be read: %s" % String(contract_result.get("error", "")))
    var feature_bytes := _read_bytes(feature_path, MAX_FEATURE_BYTES)
    if not feature_bytes.get("ok", false) or HashV1.sha256_bytes(feature_bytes.get("bytes", PackedByteArray())) != FEATURE_FILE_SHA256:
        return _failure("road feature bundle SHA-256 differs from the reviewed v1 fixture")
    var terrain_result := _read_json_object(golden_path, MAX_SCHEMA_BYTES)
    if not terrain_result.get("ok", false):
        return _failure("Golden terrain manifest could not be read: %s" % String(terrain_result.get("error", "")))

    var contract: Dictionary = contract_result["value"]
    var schema: Dictionary = schema_result["value"]
    var terrain_manifest: Dictionary = terrain_result["value"]
    var validation_error := validate_collection(contract, schema, terrain_manifest)
    if not validation_error.is_empty():
        return _failure(validation_error)
    return {
        "ok": true,
        "collection": contract,
        "schema": schema,
        "terrain_manifest": terrain_manifest,
        "error": ""
    }

static func validate_collection(contract: Dictionary, schema: Dictionary, terrain_manifest: Dictionary) -> String:
    var schema_error := SchemaV1.validate(contract, schema)
    if not schema_error.is_empty():
        return "feature schema validation failed: %s" % schema_error
    if String(contract.get("contract_id", "")) != CONTRACT_ID or int(contract.get("schema_version", -1)) != 1:
        return "road feature contract identity is unsupported"
    if String(contract.get("feature_type", "")) != "road_path_centerline":
        return "road feature collection type is unsupported"
    if not terrain_manifest.has("frame") or not terrain_manifest.has("frame_definition_sha256"):
        return "Golden terrain manifest is missing its frame identity"
    var terrain_frame: Dictionary = terrain_manifest["frame"]
    if contract.get("frame", {}) != terrain_frame:
        return "road feature frame object differs from the exact Golden Terrain Grid frame"
    if String(contract.get("frame_definition_sha256", "")) != String(terrain_manifest["frame_definition_sha256"]):
        return "road feature frame hash differs from Golden Terrain Grid v1"
    var coordinate_space: Dictionary = contract.get("coordinate_space", {})
    if String(coordinate_space.get("frame_id", "")) != String(terrain_frame.get("frame_id", "")):
        return "road feature coordinate space uses a different frame ID"
    if String(coordinate_space.get("source_crs", "")) != "EPSG:4269" or String(coordinate_space.get("source_axis_order", "")) != "longitude_latitude":
        return "road feature source CRS or axis order is unsupported"
    if String(coordinate_space.get("horizontal_datum", "")) != "NAD83" or String(coordinate_space.get("ellipsoid", "")) != "GRS80":
        return "road feature datum/ellipsoid identity is unsupported"
    if String(coordinate_space.get("realization_epoch", "")) != "unspecified_by_source_metadata":
        return "road feature realization/epoch claims are unsupported"
    if String(coordinate_space.get("projected_axis_order", "")) != "easting_northing" or String(coordinate_space.get("units", "")) != "metre" or int(coordinate_space.get("dimensions", -1)) != 2:
        return "road feature local coordinate order, units or dimension is unsupported"
    var pipeline := String(coordinate_space.get("operation_proj_pipeline", "")).to_lower()
    for forbidden in ["wgs84", "wgs 84", "towgs84", "hgridshift", "vgridshift", "helmert", "ballpark"]:
        if pipeline.contains(forbidden):
            return "road projection operation contains an unapproved datum transformation"
    if not pipeline.contains("+proj=aeqd") or not pipeline.contains("+ellps=grs80"):
        return "road projection is not the Golden GRS80 AEQD operation"
    if String(coordinate_space.get("operation_proj_pipeline", "")) != String(terrain_frame["horizontal"]["operation_proj_pipeline"]):
        return "road projection pipeline differs from the exact Golden local frame operation"
    if String(coordinate_space.get("projection_method", "")) != String(terrain_frame["horizontal"]["projection_method"]):
        return "road projection method differs from the Golden local frame"
    if String(coordinate_space.get("projection_wkt2", "")) != String(terrain_frame["horizontal"]["projection_wkt2"]):
        return "road projection WKT differs from the Golden local frame"

    var source: Dictionary = contract.get("source", {})
    if String(source.get("provider", "")) != "U.S. Census Bureau" or String(source.get("source_uri", "")) != "https://www2.census.gov/geo/tiger/TIGER2026/ROADS/tl_2026_08059_roads.zip":
        return "Census source identity or official archive URL differs from the selected dataset"
    if int(source.get("archive_byte_length", -1)) != ARCHIVE_BYTE_LENGTH or String(source.get("archive_sha256", "")) != ARCHIVE_SHA256:
        return "Census source ZIP length or SHA-256 differs from the inspected archive"
    var component_hashes: Dictionary = source.get("component_hashes", {})
    if component_hashes.size() != COMPONENT_SHA256.size():
        return "Census source component list is incomplete"
    for component_name in COMPONENT_SHA256:
        if not component_hashes.has(component_name):
            return "Census source component is missing: %s" % component_name
        var descriptor: Dictionary = component_hashes[component_name]
        if String(descriptor.get("sha256", "")) != String(COMPONENT_SHA256[component_name]):
            return "Census component hash differs for %s" % component_name
        if int(descriptor.get("byte_length", 0)) != int(COMPONENT_BYTE_LENGTHS[component_name]):
            return "Census component byte length differs for %s" % component_name
    if int(source.get("vintage", -1)) != 2026 or String(source.get("release_date", "")) != "2026-10-14":
        return "Census source vintage/release date differs from the selected dataset"
    var source_coordinates: Dictionary = source.get("source_coordinates", {})
    if String(source_coordinates.get("crs", "")) != "EPSG:4269" or String(source_coordinates.get("horizontal_datum", "")) != "NAD83" or String(source_coordinates.get("ellipsoid", "")) != "GRS80":
        return "Census source CRS/datum/ellipsoid does not match the source .prj"
    if int(source_coordinates.get("dimensions", -1)) != 2 or bool(source_coordinates.get("has_z", true)):
        return "Census source geometry must remain two-dimensional"
    if String(source_coordinates.get("vertical_datum", "")) != "none" or String(source_coordinates.get("road_width_attribute", "")) != "absent":
        return "Census source has no supported vertical datum or road width"
    if not String(source.get("accuracy_statement", "")).contains("no per-feature positional accuracy guarantee"):
        return "Census source accuracy limitation is missing"
    if not String(source.get("conspicuous_trademark_disclaimer", "")).contains("TIGER/Line® is a registered trademark"):
        return "Census trademark/disclaimer notice is missing"

    var support: Dictionary = contract.get("terrain_support", {})
    if String(support.get("contract_id", "")) != String(terrain_manifest.get("contract_id", "")):
        return "road drape references an unsupported terrain contract"
    if String(support.get("artifact_id", "")) != String(terrain_manifest.get("artifact_id", "")):
        return "road drape references a different Golden terrain artifact"
    if String(support.get("source_raster_sha256", "")) != String(terrain_manifest["source"]["raster"]["sha256"]):
        return "road drape references a different Golden terrain source raster"
    if String(support.get("source_product_id", "")) != String(terrain_manifest["source"]["product_id"]):
        return "road drape references a different Golden terrain source product"
    if String(support.get("frame_definition_sha256", "")) != String(terrain_manifest["frame_definition_sha256"]):
        return "road drape references a different Golden frame definition"
    if String(support.get("height_datum", "")) != "NAVD88" or String(support.get("height_type", "")) != "orthometric" or String(support.get("local_up_expression", "")) != "H-H0":
        return "road drape height semantics differ from the Golden terrain contract"
    if String(contract.get("geometry_semantics", {}).get("source_height", "")) != "absent" or String(contract.get("geometry_semantics", {}).get("source_width", "")) != "absent":
        return "road feature source height or width must remain absent"

    var expected_bounds := [-105.24, 39.745, -105.20, 39.765]
    var clip_extent: Dictionary = contract.get("clip_extent", {})
    if float(clip_extent.get("west", INF)) != expected_bounds[0] or float(clip_extent.get("south", INF)) != expected_bounds[1] or float(clip_extent.get("east", INF)) != expected_bounds[2] or float(clip_extent.get("north", INF)) != expected_bounds[3]:
        return "road feature crop differs from the selected Golden source bounds"
    var features: Array = contract.get("features", [])
    if features.is_empty() or features.size() > MAX_FEATURES:
        return "road feature count is empty or exceeds the v1 limit"
    var selected_routes: Array = contract.get("selection", [])
    var expected_ids: Dictionary = ROUTE_IDENTITIES
    if features.size() != expected_ids.size() or selected_routes.size() != expected_ids.size():
        return "road feature set does not contain the three selected route segments"
    var selected_ids: Dictionary = {}
    for selected_variant in selected_routes:
        if typeof(selected_variant) != TYPE_DICTIONARY:
            return "selected route identity must be an object"
        var selected: Dictionary = selected_variant
        if not _has_only_keys(selected, ["LINEARID", "FULLNAME", "RTTYP", "MTFCC"]):
            return "selected route identity has an unknown property"
        if typeof(selected.get("LINEARID")) != TYPE_STRING or typeof(selected.get("FULLNAME")) != TYPE_STRING or typeof(selected.get("RTTYP")) != TYPE_STRING or typeof(selected.get("MTFCC")) != TYPE_STRING:
            return "selected route identity has an invalid field type"
        var selected_id := String(selected.get("LINEARID", ""))
        if not expected_ids.has(selected_id) or selected_ids.has(selected_id):
            return "selected route list contains an unknown or duplicated source ID"
        var selected_identity: Dictionary = expected_ids[selected_id]
        if String(selected.get("FULLNAME", "")) != String(selected_identity["fullname"]) or String(selected.get("RTTYP", "")) != String(selected_identity["rttyp"]) or String(selected.get("MTFCC", "")) != String(selected_identity["mtfcc"]):
            return "selected route list name, route type or MTFCC differs from the inspected Census record"
        selected_ids[selected_id] = true

    var rows := int(support.get("sample_grid_rows", 0))
    var columns := int(support.get("sample_grid_columns", 0))
    if rows != int(terrain_manifest["grid"]["rows"]) or columns != int(terrain_manifest["grid"]["columns"]):
        return "road terrain sample-grid dimensions differ from Golden Terrain Grid v1"
    var raster: Dictionary = terrain_manifest["source"]["raster"]
    var affine: Dictionary = raster.get("affine", {})
    var source_window: Dictionary = terrain_manifest["grid"]["source_window"]
    var row_offset := int(source_window["row_offset"])
    var column_offset := int(source_window["column_offset"])
    var identifiers: Dictionary = {}
    var counted_points := 0
    for feature_variant in features:
        if typeof(feature_variant) != TYPE_DICTIONARY:
            return "road feature entry must be an object"
        var feature: Dictionary = feature_variant
        if not _has_only_keys(feature, ["id", "source_record_index", "feature_type", "properties", "geometry"]):
            return "road feature has an unknown property"
        if typeof(feature.get("id")) != TYPE_STRING or not _is_integer(feature.get("source_record_index")):
            return "road feature ID or source record index has an invalid type"
        if int(feature["source_record_index"]) < 0:
            return "road feature source record index is negative"
        if typeof(feature.get("feature_type")) != TYPE_STRING or String(feature["feature_type"]) != "road_path_centerline":
            return "road feature type is unsupported"
        if typeof(feature.get("properties")) != TYPE_DICTIONARY or typeof(feature.get("geometry")) != TYPE_DICTIONARY:
            return "road feature properties or geometry has an invalid type"
        var feature_id := String(feature.get("id", ""))
        if feature_id.is_empty() or identifiers.has(feature_id):
            return "road feature ID is empty or duplicated"
        if not expected_ids.has(feature_id):
            return "road feature ID is not in the selected source route set"
        identifiers[feature_id] = true
        var properties: Dictionary = feature.get("properties", {})
        if not _has_only_keys(properties, ["LINEARID", "FULLNAME", "RTTYP", "MTFCC"]):
            return "road feature properties contain an unknown field"
        for property_name in ["LINEARID", "FULLNAME", "RTTYP", "MTFCC"]:
            if typeof(properties.get(property_name)) != TYPE_STRING:
                return "road feature source property %s has an invalid type" % property_name
        var expected_identity: Dictionary = expected_ids[feature_id]
        if String(properties.get("LINEARID", "")) != feature_id:
            return "road feature ID differs from its source LINEARID"
        if String(properties.get("FULLNAME", "")) != String(expected_identity["fullname"]) or String(properties.get("RTTYP", "")) != String(expected_identity["rttyp"]) or String(properties.get("MTFCC", "")) != String(expected_identity["mtfcc"]):
            return "road feature name, route type or MTFCC differs from the selected Census record"
        var geometry: Dictionary = feature.get("geometry", {})
        if not _has_only_keys(geometry, ["type", "paths"]):
            return "road feature geometry has an unknown property"
        if String(geometry.get("type", "")) != "MultiLineString2D":
            return "road feature geometry must be a 2D MultiLineString"
        if typeof(geometry.get("paths")) != TYPE_ARRAY:
            return "road feature paths must be an array"
        var paths: Array = geometry["paths"]
        if paths.is_empty():
            return "road feature has no clipped path"
        for path_variant in paths:
            if typeof(path_variant) != TYPE_DICTIONARY:
                return "road feature path must be an object"
            var path: Dictionary = path_variant
            if not _has_only_keys(path, ["points"]) or typeof(path.get("points")) != TYPE_ARRAY:
                return "road feature path has an unknown property or invalid point array"
            var points: Array = path["points"]
            if points.size() < 2 or points.size() > MAX_POINTS_PER_PATH:
                return "road feature path point count is outside v1 bounds"
            counted_points += points.size()
            var previous_xy := Vector2(INF, INF)
            for point_variant in points:
                if typeof(point_variant) != TYPE_DICTIONARY:
                    return "road feature coordinate must be an object"
                var point: Dictionary = point_variant
                if not _has_only_keys(point, ["source_lon_lat_deg", "local_xy_m", "terrain_grid_rc_hint"]):
                    return "road feature point may not carry Z, width or unknown values"
                if typeof(point.get("source_lon_lat_deg")) != TYPE_ARRAY or typeof(point.get("local_xy_m")) != TYPE_ARRAY or typeof(point.get("terrain_grid_rc_hint")) != TYPE_ARRAY:
                    return "road feature point coordinates and support hints must be arrays"
                var source_xy: Array = point.get("source_lon_lat_deg", [])
                var local_xy: Array = point.get("local_xy_m", [])
                var grid_rc: Array = point.get("terrain_grid_rc_hint", [])
                if source_xy.size() != 2 or local_xy.size() != 2 or grid_rc.size() != 2:
                    return "road feature point coordinates must remain 2D"
                for coordinate in source_xy:
                    if not _is_number(coordinate):
                        return "road source coordinate must be numeric"
                for coordinate in local_xy:
                    if not _is_number(coordinate):
                        return "road projected coordinate must be numeric"
                for coordinate in grid_rc:
                    if not _is_number(coordinate):
                        return "road sample-grid hint must be numeric"
                var longitude := float(source_xy[0])
                var latitude := float(source_xy[1])
                var easting := float(local_xy[0])
                var northing := float(local_xy[1])
                var grid_row := float(grid_rc[0])
                var grid_column := float(grid_rc[1])
                if not _finite(longitude) or not _finite(latitude) or not _finite(easting) or not _finite(northing) or not _finite(grid_row) or not _finite(grid_column):
                    return "road feature coordinate or support hint is non-finite"
                if longitude < expected_bounds[0] or longitude > expected_bounds[2] or latitude < expected_bounds[1] or latitude > expected_bounds[3]:
                    return "road feature source coordinate lies outside the exact crop"
                var expected_row := (latitude - float(affine["y_origin"])) / float(affine["pixel_height"]) - 0.5 - row_offset
                var expected_column := (longitude - float(affine["x_origin"])) / float(affine["pixel_width"]) - 0.5 - column_offset
                if absf(grid_row - expected_row) > GRID_HINT_FLOAT_ROUND_TRIP_GUARD_PIXELS or absf(grid_column - expected_column) > GRID_HINT_FLOAT_ROUND_TRIP_GUARD_PIXELS:
                    return "road support grid hint mismatch at %s: stored %s/%s expected %s/%s" % [feature_id, str(grid_row), str(grid_column), str(expected_row), str(expected_column)]
                if absf(easting) > 100000.0 or absf(northing) > 100000.0:
                    return "road projected coordinate exceeds the regional frame limit"
                var current_xy := Vector2(easting, -northing)
                if previous_xy.x != INF:
                    var segment_length := previous_xy.distance_to(current_xy)
                    if segment_length > MAX_PROJECTED_SEGMENT_M + 0.0000001:
                        return "road path exceeds its deterministic resampling interval"
                previous_xy = current_xy
    if identifiers.size() != expected_ids.size():
        return "selected route ID set is incomplete"
    if counted_points != int(contract["generation"]["resampled_point_count"]):
        return "road feature point count differs from generation metadata"
    return ""

static func build_draped_mesh(collection: Dictionary, terrain_decoded: Dictionary, display_offset_m: float) -> Dictionary:
    if not terrain_decoded.get("ok", false):
        return _failure("Golden terrain bundle is not validated")
    if not _finite(display_offset_m) or absf(display_offset_m) > 10.0:
        return _failure("viewer display offset is non-finite or outside its local display range")
    var terrain_manifest: Dictionary = terrain_decoded["manifest"]
    if collection.get("frame", {}) != terrain_manifest.get("frame", {}):
        return _failure("road and terrain frame objects differ before draping")
    var vertices: PackedVector3Array = terrain_decoded["vertices"]
    var rows := int(terrain_decoded["rows"])
    var columns := int(terrain_decoded["columns"])
    if vertices.size() != rows * columns:
        return _failure("validated terrain vertex count differs from its sample grid")
    var h0 := float(terrain_manifest["frame"]["origin"]["height_navd88_m"])
    var mesh := ImmediateMesh.new()
    var draped_point_count := 0
    var support_miss_count := 0
    var rendered_vertex_count := 0
    var display_support_miss_count := 0
    var line_strip_count := 0
    var route_point_reports: Array[Dictionary] = []

    for feature_variant in collection["features"]:
        var feature: Dictionary = feature_variant
        var route_id := String(feature["id"])
        var route_name := String(feature["properties"]["FULLNAME"])
        var mtfcc := String(feature["properties"]["MTFCC"])
        var material := _material_for_mtfcc(mtfcc)
        for path_variant in feature["geometry"]["paths"]:
            var path: Dictionary = path_variant
            var points: Array = path["points"]
            var report_indexes := [0, int((points.size() - 1) / 2), points.size() - 1]
            var line_points := PackedVector3Array()
            var previous_xy := Vector2.ZERO
            var previous_grid_rc := Vector2.ZERO
            var has_previous := false
            for point_index in range(points.size()):
                var point: Dictionary = points[point_index]
                var local_xy: Array = point["local_xy_m"]
                var grid_rc: Array = point["terrain_grid_rc_hint"]
                var current_xy := Vector2(float(local_xy[0]), -float(local_xy[1]))
                var current_grid_rc := Vector2(float(grid_rc[0]), float(grid_rc[1]))
                if not has_previous:
                    var first_sample := sample_surface_height(vertices, rows, columns, current_xy, current_grid_rc)
                    if not _append_sampled_vertex(line_points, current_xy, first_sample, display_offset_m):
                        support_miss_count += 1
                        line_strip_count += _emit_line_strip(mesh, line_points, material)
                        line_points.clear()
                        if report_indexes.has(point_index):
                            route_point_reports.append(_sample_report(route_id, route_name, mtfcc, point_index, point, local_xy, first_sample, h0, display_offset_m))
                    else:
                        draped_point_count += 1
                        rendered_vertex_count += 1
                        if report_indexes.has(point_index):
                            route_point_reports.append(_sample_report(route_id, route_name, mtfcc, point_index, point, local_xy, first_sample, h0, display_offset_m))
                    previous_xy = current_xy
                    previous_grid_rc = current_grid_rc
                    has_previous = true
                    continue

                var segment_length := previous_xy.distance_to(current_xy)
                var segment_steps := maxi(1, int(ceil(segment_length / MAX_VIEWER_DISPLAY_SEGMENT_M)))
                for segment_step in range(1, segment_steps + 1):
                    var amount := float(segment_step) / float(segment_steps)
                    var sample_xy := previous_xy.lerp(current_xy, amount)
                    var sample_grid_rc := previous_grid_rc.lerp(current_grid_rc, amount)
                    var sample := sample_surface_height(vertices, rows, columns, sample_xy, sample_grid_rc)
                    if not _append_sampled_vertex(line_points, sample_xy, sample, display_offset_m):
                        line_strip_count += _emit_line_strip(mesh, line_points, material)
                        line_points.clear()
                        if segment_step == segment_steps:
                            support_miss_count += 1
                            if report_indexes.has(point_index):
                                route_point_reports.append(_sample_report(route_id, route_name, mtfcc, point_index, point, local_xy, sample, h0, display_offset_m))
                        else:
                            display_support_miss_count += 1
                    else:
                        rendered_vertex_count += 1
                        if segment_step == segment_steps:
                            draped_point_count += 1
                            if report_indexes.has(point_index):
                                route_point_reports.append(_sample_report(route_id, route_name, mtfcc, point_index, point, local_xy, sample, h0, display_offset_m))
                previous_xy = current_xy
                previous_grid_rc = current_grid_rc
            line_strip_count += _emit_line_strip(mesh, line_points, material)

    if mesh.get_surface_count() <= 0 or line_strip_count <= 0:
        return _failure("no Census centerline segment could be draped on the Golden terrain support")
    return {
        "ok": true,
        "mesh": mesh,
        "draped_point_count": draped_point_count,
        "support_miss_count": support_miss_count,
        "rendered_vertex_count": rendered_vertex_count,
        "display_support_miss_count": display_support_miss_count,
        "line_strip_count": line_strip_count,
        "sample_reports": route_point_reports,
        "error": ""
    }

static func _append_sampled_vertex(
    line_points: PackedVector3Array,
    sample_xy: Vector2,
    sample: Dictionary,
    display_offset_m: float
) -> bool:
    if not sample.get("ok", false):
        return false
    var position := Vector3(sample_xy.x, float(sample["local_up_m"]) + display_offset_m, sample_xy.y)
    if not position.is_finite():
        return false
    line_points.append(position)
    return true

static func _sample_report(
    route_id: String,
    route_name: String,
    mtfcc: String,
    point_index: int,
    point: Dictionary,
    local_xy: Array,
    sample: Dictionary,
    h0: float,
    display_offset_m: float
) -> Dictionary:
    if not sample.get("ok", false):
        return {
            "route_id": route_id,
            "route_name": route_name,
            "mtfcc": mtfcc,
            "point_index": point_index,
            "source_lon_lat_deg": point["source_lon_lat_deg"],
            "local_xy_m": local_xy,
            "draped": false,
            "reason": String(sample.get("reason", "terrain support unavailable"))
        }
    var local_up := float(sample["local_up_m"])
    var display_local_y := local_up + display_offset_m
    return {
        "route_id": route_id,
        "route_name": route_name,
        "mtfcc": mtfcc,
        "point_index": point_index,
        "source_lon_lat_deg": point["source_lon_lat_deg"],
        "local_xy_m": local_xy,
        "height_navd88_m": h0 + local_up,
        "terrain_local_up_m": local_up,
        "display_offset_m": display_offset_m,
        "display_local_y_m": display_local_y,
        "support_grid_cell_rc": sample["cell_rc"],
        "draped": true
    }

static func sample_surface_height(
    vertices: PackedVector3Array,
    rows: int,
    columns: int,
    position_xz: Vector2,
    grid_row_column: Vector2
) -> Dictionary:
    if rows < 2 or columns < 2 or vertices.size() != rows * columns:
        return {"ok": false, "reason": "terrain support grid shape is invalid"}
    if not position_xz.is_finite() or not grid_row_column.is_finite():
        return {"ok": false, "reason": "road sample point is non-finite"}
    if grid_row_column.x < 0.0 or grid_row_column.x > rows - 1 or grid_row_column.y < 0.0 or grid_row_column.y > columns - 1:
        return {"ok": false, "reason": "road point is outside the terrain pixel-centre support hull"}
    var base_row := mini(int(floor(grid_row_column.x)), rows - 2)
    var base_column := mini(int(floor(grid_row_column.y)), columns - 2)
    var first_row := maxi(0, base_row - 1)
    var last_row := mini(rows - 2, base_row + 1)
    var first_column := maxi(0, base_column - 1)
    var last_column := mini(columns - 2, base_column + 1)

    for row in range(first_row, last_row + 1):
        for column in range(first_column, last_column + 1):
            var nw_index := row * columns + column
            var ne_index := nw_index + 1
            var sw_index := (row + 1) * columns + column
            var se_index := sw_index + 1
            var nw := vertices[nw_index]
            var ne := vertices[ne_index]
            var sw := vertices[sw_index]
            var se := vertices[se_index]
            var point_nw := Vector2(nw.x, nw.z)
            var point_ne := Vector2(ne.x, ne.z)
            var point_sw := Vector2(sw.x, sw.z)
            var point_se := Vector2(se.x, se.z)
            var weights := _barycentric(position_xz, point_nw, point_ne, point_se)
            if _inside_triangle(weights):
                return {
                    "ok": true,
                    "local_up_m": _interpolate_height(weights, nw.y, ne.y, se.y),
                    "cell_rc": [row, column]
                }
            weights = _barycentric(position_xz, point_nw, point_se, point_sw)
            if _inside_triangle(weights):
                return {
                    "ok": true,
                    "local_up_m": _interpolate_height(weights, nw.y, se.y, sw.y),
                    "cell_rc": [row, column]
                }
    return {"ok": false, "reason": "road coordinate is not inside a nearby Golden terrain mesh triangle"}

static func _barycentric(point: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Dictionary:
    var ab := b - a
    var ac := c - a
    var ap := point - a
    var denominator := ab.x * ac.y - ac.x * ab.y
    if denominator == 0.0 or not _finite(denominator):
        return {}
    var weight_b := (ap.x * ac.y - ac.x * ap.y) / denominator
    var weight_c := (ab.x * ap.y - ab.y * ap.x) / denominator
    var weight_a := 1.0 - weight_b - weight_c
    return {"a": weight_a, "b": weight_b, "c": weight_c}

static func _inside_triangle(weights: Dictionary) -> bool:
    if weights.is_empty():
        return false
    for key in ["a", "b", "c"]:
        var weight := float(weights[key])
        if not _finite(weight) or weight < -BARYCENTRIC_EDGE_GUARD or weight > 1.0 + BARYCENTRIC_EDGE_GUARD:
            return false
    return true

static func _interpolate_height(weights: Dictionary, height_a: float, height_b: float, height_c: float) -> float:
    return float(weights["a"]) * height_a + float(weights["b"]) * height_b + float(weights["c"]) * height_c

static func _emit_line_strip(mesh: ImmediateMesh, vertices: PackedVector3Array, material: StandardMaterial3D) -> int:
    if vertices.size() < 2:
        return 0
    mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, material)
    for vertex in vertices:
        mesh.surface_add_vertex(vertex)
    mesh.surface_end()
    return 1

static func _material_for_mtfcc(mtfcc: String) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.roughness = 1.0
    material.render_priority = 1
    match mtfcc:
        "S1100":
            material.albedo_color = Color(0.92, 0.25, 0.18, 1.0)
        "S1200":
            material.albedo_color = Color(1.0, 0.61, 0.2, 1.0)
        "S1400":
            material.albedo_color = Color(0.12, 0.86, 0.78, 1.0)
        "S1630":
            material.albedo_color = Color(0.66, 0.42, 0.95, 1.0)
        _:
            material.albedo_color = Color(0.91, 0.92, 0.86, 1.0)
    return material

static func _read_json_object(path: String, byte_limit: int) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {"ok": false, "value": {}, "error": "cannot open %s (error %d)" % [path.get_file(), FileAccess.get_open_error()]}
    var byte_count := file.get_length()
    if byte_count <= 0 or byte_count > byte_limit:
        file.close()
        return {"ok": false, "value": {}, "error": "%s is empty or exceeds its byte limit" % path.get_file()}
    var bytes := file.get_buffer(byte_count)
    file.close()
    if bytes.size() != byte_count:
        return {"ok": false, "value": {}, "error": "%s was truncated" % path.get_file()}
    var parsed: Dictionary = StrictJson.new().parse_bytes(bytes, byte_limit)
    if not parsed.get("ok", false) or typeof(parsed.get("value")) != TYPE_DICTIONARY:
        return {"ok": false, "value": {}, "error": String(parsed.get("error", "invalid JSON object"))}
    return parsed

static func _read_bytes(path: String, byte_limit: int) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {"ok": false, "bytes": PackedByteArray(), "error": "cannot open feature bundle bytes"}
    var byte_count := file.get_length()
    if byte_count <= 0 or byte_count > byte_limit:
        file.close()
        return {"ok": false, "bytes": PackedByteArray(), "error": "feature bundle byte length is invalid"}
    var bytes := file.get_buffer(byte_count)
    file.close()
    if bytes.size() != byte_count:
        return {"ok": false, "bytes": PackedByteArray(), "error": "feature bundle byte read was truncated"}
    return {"ok": true, "bytes": bytes, "error": ""}

static func _finite(value: float) -> bool:
    return is_finite(value)

static func _is_number(value: Variant) -> bool:
    return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT

static func _is_integer(value: Variant) -> bool:
    if typeof(value) == TYPE_INT:
        return true
    if typeof(value) != TYPE_FLOAT or not is_finite(float(value)):
        return false
    return floor(float(value)) == float(value)

static func _has_only_keys(value: Dictionary, allowed_keys: Array) -> bool:
    for key in value.keys():
        if not allowed_keys.has(String(key)):
            return false
    return true

static func _failure(message: String) -> Dictionary:
    return {"ok": false, "error": message}
