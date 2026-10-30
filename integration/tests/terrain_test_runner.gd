extends Node

const StrictJson := preload("res://terrain/strict_json_v1.gd")
const SchemaV1 := preload("res://terrain/schema_v1.gd")
const ContractV1 := preload("res://terrain/terrain_contract_v1.gd")
const Decoder := preload("res://terrain/bundle_decoder_v1.gd")
const SiteCatalog := preload("res://terrain/site_catalog_v1.gd")
const TileFactory := preload("res://terrain/terrain_tile_factory_v1.gd")
const GeodeticEcef := preload("res://terrain/geodetic_ecef_wgs84_v1.gd")
const GlobalTileAddress := preload("res://terrain/global_tile_address_v1.gd")
const GlobalPositionBridge := preload("res://terrain/global_position_bridge_v1.gd")
const OriginRebase := preload("res://terrain/terrain_origin_rebase_v1.gd")
const SourceErrorLodPolicy := preload("res://terrain/source_error_lod_policy_v1.gd")
const StreamManager := preload("res://terrain/terrain_stream_manager_v1.gd")
const LodBuilder := preload("res://terrain/terrain_lod_builder_v1.gd")

var _checks := 0
var _failures := 0
var _repository_root := ""
var _schema: Dictionary = {}
var _decoded_by_site: Dictionary = {}

func run_suite(suite_name: String) -> int:
    _checks = 0
    _failures = 0
    _repository_root = SiteCatalog.repository_root()
    print("WF_TERRAIN_TEST_SUITE=%s" % suite_name)
    var schema_result := Decoder._read_schema(_repository_root.path_join("contracts/terrain_grid_v1.schema.json"))
    _check(schema_result.get("ok", false), "parent terrain schema parses with strict JSON")
    if schema_result.get("ok", false):
        _schema = schema_result["value"]
    else:
        _report_summary()
        return 1

    match suite_name:
        "contracts":
            _run_contract_tests()
        "geodetic":
            _run_geodetic_tests()
            _run_origin_rebase_tests()
        "rebase":
            _run_origin_rebase_tests()
        "tile-address":
            _run_spatial_address_tests()
        "origin-live":
            await _run_origin_rebase_scene_tests()
        "collision":
            _run_contract_tests()
            await _run_collision_tests()
        "lifecycle":
            await _run_lifecycle_tests()
        "adjacent":
            _run_contract_tests()
            await _run_adjacent_lifecycle_tests()
        "all":
            _run_contract_tests()
            _run_geodetic_tests()
            _run_origin_rebase_tests()
            _run_spatial_address_tests()
            await _run_collision_tests()
            await _run_lifecycle_tests()
            await _run_adjacent_lifecycle_tests()
            await _run_origin_rebase_scene_tests()
        _:
            _check(false, "supported suite name is contracts, geodetic, rebase, tile-address, origin-live, collision, lifecycle, adjacent, or all")
    _report_summary()
    return 1 if _failures > 0 else 0

func _run_contract_tests() -> void:
    var strict_parser := StrictJson.new()
    var duplicate := strict_parser.parse_bytes('{"v":1,"v":2}'.to_utf8_buffer())
    _check(not duplicate.get("ok", false), "strict JSON rejects duplicate object keys")
    var escaped_duplicate := strict_parser.parse_bytes('{"v":1,"\\u0076":2}'.to_utf8_buffer())
    _check(not escaped_duplicate.get("ok", false), "strict JSON rejects duplicate keys after escape decoding")
    var oversized := PackedByteArray()
    oversized.resize(ContractV1.MAX_MANIFEST_BYTES + 1)
    _check(not strict_parser.parse_bytes(oversized).get("ok", false), "strict JSON enforces the manifest byte limit")

    for site_id in SiteCatalog.site_ids():
        var decoder := Decoder.new()
        decoder.decode(site_id, _repository_root)
        var decoded: Dictionary = decoder.result
        var decoded_ok := bool(decoded.get("ok", false))
        var decoded_message := "%s real producer bundle validates" % site_id
        if not decoded_ok:
            decoded_message += ": " + String(decoded.get("error", ""))
        _check(decoded_ok, decoded_message)
        if not decoded_ok:
            continue
        _decoded_by_site[site_id] = decoded
        var site: Dictionary = decoded["site"]
        var window_ids := SiteCatalog.window_ids(site_id)
        var default_window_id := String(site["window_id"])
        _check(window_ids.has(default_window_id), "%s exposes its configured default window ID in the site window catalog" % site_id)
        var selected_window := SiteCatalog.get_window(site_id, String(site["window_id"]))
        _check(selected_window.get("window_id") == default_window_id and selected_window.get("frame_id") == site.get("frame_id") and selected_window.get("source") == site.get("source"), "%s default window resolves with the approved shared source and frame" % site_id)
        var manifest: Dictionary = decoded["manifest"]
        _check(decoded["artifact_id"] == site["artifact_id"], "%s artifact ID matches the requested site" % site_id)
        _check(manifest["frame"]["frame_id"] == site["frame_id"], "%s frame ID matches the approved regional frame" % site_id)
        _check(decoded["vertices"].size() == int(site["rows"]) * int(site["columns"]), "%s geometry vertex count matches grid sample count" % site_id)
        _check(decoded["indices"].size() == decoded["faces"].size(), "%s render indices and collision triangles have equal lengths" % site_id)
        var anchor_position: Vector3 = decoded["vertices"][int(decoded["anchor_index"])]
        _check(anchor_position.length() <= 0.000001, "%s anchor sample maps to the local origin with H-H0 = 0" % site_id)
        _check(String(manifest["frame"]["horizontal"]["source_crs"]) == "EPSG:4269" and String(manifest["frame"]["vertical"]["datum"]) == "NAVD88", "%s retains NAD83 and NAVD88 local-frame semantics" % site_id)

        var bad_unknown: Dictionary = manifest.duplicate(true)
        bad_unknown["unapproved_global_position"] = {"crs": "EPSG:4978"}
        var unknown_result := ContractV1.validate_manifest(bad_unknown, _schema, site)
        _check(not unknown_result.get("ok", false), "%s rejects unknown global-position manifest fields" % site_id)

        var bad_path: Dictionary = manifest.duplicate(true)
        bad_path["payloads"]["horizontal_xy"]["path"] = "../height_samples.f32le"
        var bad_path_result := ContractV1.validate_manifest(bad_path, _schema, site)
        _check(not bad_path_result.get("ok", false), "%s rejects a traversal payload path before file access" % site_id)

        var bad_source: Dictionary = manifest.duplicate(true)
        bad_source["source"]["raster"]["sha256"] = "0000000000000000000000000000000000000000000000000000000000000000"
        var bad_source_result := ContractV1.validate_manifest(bad_source, _schema, site)
        _check(not bad_source_result.get("ok", false), "%s rejects source raster identity not in the site allowlist" % site_id)
        var affine_delta := 0.001
        var bad_affine_footprint: Dictionary = manifest.duplicate(true)
        var tampered_raster: Dictionary = bad_affine_footprint["source"]["raster"]
        var tampered_affine: Dictionary = tampered_raster["affine"]
        tampered_affine["x_origin"] = float(tampered_affine["x_origin"]) + affine_delta
        var tampered_footprint: Dictionary = bad_affine_footprint["grid"]["source_pixel_footprint_bounds"]
        tampered_footprint["west_deg"] = float(tampered_footprint["west_deg"]) + affine_delta
        tampered_footprint["east_deg"] = float(tampered_footprint["east_deg"]) + affine_delta
        var affine_result := ContractV1.validate_manifest(bad_affine_footprint, _schema, site)
        var affine_error := String(affine_result.get("error", ""))
        _check(not affine_result.get("ok", false) and affine_error.contains("source.raster.affine.x_origin"), "%s rejects a mutated raster affine even when footprint bounds are adjusted to remain consistent" % site_id)

        var bad_nodata: Dictionary = manifest.duplicate(true)
        bad_nodata["source"]["raster"]["nodata_value"] = -999998.0
        var nodata_result := ContractV1.validate_manifest(bad_nodata, _schema, site)
        var nodata_error := String(nodata_result.get("error", ""))
        _check(not nodata_result.get("ok", false) and nodata_error.contains("source.raster.nodata_value"), "%s rejects a mutated source raster no-data value" % site_id)

        var bad_rights: Dictionary = manifest.duplicate(true)
        bad_rights["source"]["rights_statement"] = "unapproved source rights"
        var rights_result := ContractV1.validate_manifest(bad_rights, _schema, site)
        _check(not rights_result.get("ok", false), "%s rejects source-rights text not pinned in its approved record" % site_id)

        var bad_frame_hash: Dictionary = manifest.duplicate(true)
        bad_frame_hash["frame_definition_sha256"] = "0000000000000000000000000000000000000000000000000000000000000000"
        var frame_hash_result := ContractV1.validate_manifest(bad_frame_hash, _schema, site)
        _check(not frame_hash_result.get("ok", false), "%s rejects a canonical frame hash mismatch" % site_id)

        var bad_artifact: Dictionary = manifest.duplicate(true)
        bad_artifact["artifact_id"] = "0000000000000000000000000000000000000000000000000000000000000000"
        var artifact_result := ContractV1.validate_manifest(bad_artifact, _schema, site)
        _check(not artifact_result.get("ok", false), "%s rejects a canonical artifact hash mismatch" % site_id)

        var stale_site: Dictionary = site.duplicate(true)
        stale_site["artifact_id"] = "0000000000000000000000000000000000000000000000000000000000000000"
        var stale_result := ContractV1.validate_manifest(manifest, _schema, stale_site)
        _check(not stale_result.get("ok", false), "%s rejects a stale expected artifact ID" % site_id)

        var bad_dimensions: Dictionary = manifest.duplicate(true)
        bad_dimensions["grid"]["rows"] = 4096
        bad_dimensions["grid"]["columns"] = 4096
        var dimensions_result := ContractV1.validate_dimensions_and_files(bad_dimensions)
        _check(not dimensions_result.get("ok", false), "%s rejects dimensions above the v1 sample cap before allocation" % site_id)

        var bad_length: Dictionary = manifest.duplicate(true)
        bad_length["payloads"]["height_samples"]["byte_length"] += 4
        var length_result := ContractV1.validate_dimensions_and_files(bad_length)
        _check(not length_result.get("ok", false), "%s rejects payload length inconsistent with dimensions" % site_id)

    _run_catalog_window_design_tests()
    _run_adjacent_window_validation_tests()
    _run_tampered_payload_test()
    _run_bounded_read_tests()

func _run_adjacent_window_validation_tests() -> void:
    var ids: Array[String] = ["golden-west", "golden-east"]
    var decoder := Decoder.new()
    decoder.decode_window_set("golden", _repository_root, ids)
    var result: Dictionary = decoder.result
    var decoded_ok := bool(result.get("ok", false))
    var decode_detail := "accepted" if decoded_ok else "rejected: %s" % String(result.get("error", "unknown"))
    _check(decoded_ok, "producer-generated Golden west/east bundles validate as one adjacent window set: %s" % decode_detail)
    if not decoded_ok:
        return
    _decoded_by_site["golden-adjacent"] = result
    var windows: Array[Dictionary] = result["windows"]
    var west: Dictionary = windows[0]
    var east: Dictionary = windows[1]
    var west_window: Dictionary = west["manifest"]["grid"]["source_window"]
    var east_window: Dictionary = east["manifest"]["grid"]["source_window"]
    _check(String(west["site"]["window_id"]) == "golden-west" and String(east["site"]["window_id"]) == "golden-east", "adjacent set is ordered west to east")
    _check(int(west_window["row_offset"]) == 2544 and int(east_window["row_offset"]) == 2544 and int(west_window["rows"]) == 216 and int(east_window["rows"]) == 216, "adjacent windows share the approved 216 source rows at row offset 2544")
    _check(int(west_window["column_offset"]) == 8214 and int(west_window["columns"]) == 217 and int(east_window["column_offset"]) == 8430 and int(east_window["columns"]) == 216, "adjacent windows match their approved source columns and dimensions")
    _check(int(west_window["column_offset"]) + int(west_window["columns"]) - 1 == int(east_window["column_offset"]), "west/east windows share exactly source sample column 8430")
    _check(west["manifest"]["frame"] == east["manifest"]["frame"] and west["manifest"]["source"] == east["manifest"]["source"], "adjacent windows have the identical full frame and source raster identity")
    _check(west["boundary_samples"]["east"]["xy_f64le"] == east["boundary_samples"]["west"]["xy_f64le"], "shared column 8430 Float64 XY bytes are identical across all rows")
    _check(west["boundary_samples"]["east"]["height_f32le"] == east["boundary_samples"]["west"]["height_f32le"], "shared column 8430 Float32 height bytes are identical across all rows")
    _check(String(west["artifact_id"]) != String(east["artifact_id"]), "adjacent windows retain distinct artifact IDs")
    var west_cells_end_sample := int(west_window["column_offset"]) + int(west_window["columns"]) - 1
    var east_cells_start_sample := int(east_window["column_offset"])
    _check(west_cells_end_sample == east_cells_start_sample, "center-to-center cell strips meet at the shared sample without area overlap")

    var west_vertices: PackedVector3Array = west["vertices"]
    var east_vertices: PackedVector3Array = east["vertices"]
    var west_columns := int(west["columns"])
    var east_columns := int(east["columns"])
    var max_seam_delta_m := 0.0
    for row in range(int(west["rows"])):
        var west_edge := west_vertices[row * west_columns + west_columns - 1]
        var east_edge := east_vertices[row * east_columns]
        max_seam_delta_m = maxf(max_seam_delta_m, west_edge.distance_to(east_edge))
    print("WF_GOLDEN_ADJACENT_MAX_SHARED_VERTEX_DELTA_M=%.12f" % max_seam_delta_m)
    _check(max_seam_delta_m == 0.0, "shared sample column produces identical local seam vertices")

    var reversed_ids: Array[String] = ["golden-east", "golden-west"]
    var reversed_decoder := Decoder.new()
    reversed_decoder.decode_window_set("golden", _repository_root, reversed_ids)
    var reversed_result: Dictionary = reversed_decoder.result
    _check(reversed_result.get("ok", false) and String(reversed_result["windows"][0]["site"]["window_id"]) == "golden-west", "adjacency normalization accepts reversed request order and returns west/east order")

    var duplicate_ids: Array[String] = ["golden-west", "golden-west"]
    var duplicate_decoder := Decoder.new()
    duplicate_decoder.decode_window_set("golden", _repository_root, duplicate_ids)
    _check(not duplicate_decoder.result.get("ok", false), "adjacent window set rejects duplicate window IDs")

    var mismatch_windows: Array[Dictionary] = [west.duplicate(true), east.duplicate(true)]
    var changed_edge: PackedByteArray = mismatch_windows[0]["boundary_samples"]["east"]["height_f32le"]
    changed_edge[0] = changed_edge[0] ^ 0x01
    mismatch_windows[0]["boundary_samples"]["east"]["height_f32le"] = changed_edge
    var mismatch_result: Dictionary = Decoder._order_and_validate_adjacent_pair(mismatch_windows)
    _check(not mismatch_result.get("ok", false) and String(mismatch_result.get("error", "")).contains("shared sample column bytes"), "adjacent pair validator rejects one mutated shared-edge height byte")

func _run_catalog_window_design_tests() -> void:
    var shared_source: Dictionary = {"product_id": "USGS shared raster", "raster": {"sha256": "628fd3bd2b2de7e36d37f7a28050db9f34bc73a7b9a8f77f54a488ec8ce757d0"}}
    var site_definition: Dictionary = {
        "site_id": "window-catalog-fixture",
        "frame_id": "wf-fixture:shared-frame",
        "source": shared_source,
        "windows": {
            "west": {"bundle_directory": "fixture-west", "artifact_id": "west-window-artifact", "source_window": {"row_offset": 100, "column_offset": 200}, "source_overrides": {"acquisition_time_basis": "receipt"}},
            "east": {"bundle_directory": "fixture-east", "artifact_id": "east-window-artifact", "source_window": {"row_offset": 100, "column_offset": 416}, "source_overrides": {"acquisition_time_basis": "receipt"}}
        }
    }
    var west_window := SiteCatalog.make_window_record(site_definition, "west")
    var east_window := SiteCatalog.make_window_record(site_definition, "east")
    _check(not west_window.is_empty() and not east_window.is_empty(), "site catalog resolves more than one window record")
    _check(west_window.get("frame_id") == east_window.get("frame_id") and west_window.get("source") == east_window.get("source"), "adjacent-window records inherit one shared source-raster and frame identity")
    _check(west_window["source"]["raster"]["sha256"] == shared_source["raster"]["sha256"] and west_window["source"]["acquisition_time_basis"] == "receipt", "window source overrides retain the full shared raster descriptor while recording per-window receipt provenance")
    _check(west_window.get("artifact_id") != east_window.get("artifact_id") and west_window.get("source_window") != east_window.get("source_window"), "adjacent-window records retain distinct artifact and source-window identity")
    _check(SiteCatalog.make_window_record(site_definition, "unknown").is_empty(), "site catalog rejects an unknown window ID")
func _run_bounded_read_tests() -> void:
    var horizontal_path := _repository_root.path_join("integration/assets/terrain/baltimore/horizontal_xy.f64le")
    var too_large := Decoder._read_bounded_file(horizontal_path, ContractV1.MAX_HORIZONTAL_BYTES + 1, ContractV1.MAX_HORIZONTAL_BYTES, "0000000000000000000000000000000000000000000000000000000000000000")
    _check(not too_large.get("ok", false), "bounded payload reader rejects a declared size above cap before allocation")
    var wrong_length := Decoder._read_bounded_file(horizontal_path, 746497, ContractV1.MAX_HORIZONTAL_BYTES, "0000000000000000000000000000000000000000000000000000000000000000")
    _check(not wrong_length.get("ok", false), "bounded payload reader rejects an opened file with a changed byte length")
func _run_tampered_payload_test() -> void:
    var site_id := "baltimore"
    var fixture_root := OS.get_user_data_dir().path_join("terrain-contract-negative-fixture")
    var stale_fixture_removed := _remove_negative_fixture_tree(fixture_root)
    _check(stale_fixture_removed, "stale negative payload fixture is removed before recreation")
    if not stale_fixture_removed:
        return
    var schema_destination := fixture_root.path_join("contracts/terrain_grid_v1.schema.json")
    var bundle_destination := fixture_root.path_join("integration/assets/terrain/baltimore")
    DirAccess.make_dir_recursive_absolute(schema_destination.get_base_dir())
    DirAccess.make_dir_recursive_absolute(bundle_destination)
    var original_schema := FileAccess.get_file_as_bytes(_repository_root.path_join("contracts/terrain_grid_v1.schema.json"))
    _write_bytes(schema_destination, original_schema)
    var source_directory := _repository_root.path_join("integration/assets/terrain/baltimore")
    var source_manifest_bytes := FileAccess.get_file_as_bytes(source_directory.path_join("manifest.json"))
    var source_manifest_result := StrictJson.new().parse_bytes(source_manifest_bytes)
    if not source_manifest_result.get("ok", false):
        _check(false, "real Baltimore manifest is available for deterministic metadata tampering tests")
        _remove_negative_fixture_tree(fixture_root)
        return
    var original_manifest: Dictionary = source_manifest_result["value"]
    for filename in ["manifest.json", "horizontal_xy.f64le", "height_samples.f32le"]:
        var bytes := FileAccess.get_file_as_bytes(source_directory.path_join(filename))
        if filename == "horizontal_xy.f64le" and not bytes.is_empty():
            bytes[0] = bytes[0] ^ 0x01
        _write_bytes(bundle_destination.path_join(filename), bytes)
    var tampered_decoder := Decoder.new()
    tampered_decoder.decode(site_id, fixture_root)
    var tampered_result: Dictionary = tampered_decoder.result
    _check(not tampered_result.get("ok", false) and String(tampered_result.get("error", "")).contains("SHA-256"), "consumer rejects payload bytes that do not match the manifest SHA-256")
    _check(not tampered_result.has("vertices"), "invalid payload is rejected before terrain geometry allocation")

    var source_manifest_text := source_manifest_bytes.get_string_from_utf8()
    var affine_manifest_text := source_manifest_text
    affine_manifest_text = affine_manifest_text.replace("\"x_origin\": -77.00055555599346", "\"x_origin\": -76.99955555599346")
    affine_manifest_text = affine_manifest_text.replace("\"west_deg\": -76.6200000000285", "\"west_deg\": -76.6190000000285")
    affine_manifest_text = affine_manifest_text.replace("\"east_deg\": -76.60000000000699", "\"east_deg\": -76.59900000000699")
    _write_bytes(bundle_destination.path_join("manifest.json"), affine_manifest_text.to_utf8_buffer())
    var affine_decoder := Decoder.new()
    affine_decoder.decode(site_id, fixture_root)
    var affine_decode_result: Dictionary = affine_decoder.result
    var affine_decode_error := String(affine_decode_result.get("error", ""))
    _check(not affine_decode_result.get("ok", false) and affine_decode_error.contains("source.raster.affine.x_origin"), "decoder rejects affine-and-footprint tampering before payload loading: %s" % affine_decode_error)
    _check(not affine_decode_result.has("vertices"), "affine-and-footprint mismatch is rejected before geometry allocation")

    var nodata_manifest_text := source_manifest_text.replace("\"nodata_value\": -999999.0", "\"nodata_value\": -999998.0")
    _write_bytes(bundle_destination.path_join("manifest.json"), nodata_manifest_text.to_utf8_buffer())
    var nodata_decoder := Decoder.new()
    nodata_decoder.decode(site_id, fixture_root)
    var nodata_decode_result: Dictionary = nodata_decoder.result
    var nodata_decode_error := String(nodata_decode_result.get("error", ""))
    _check(not nodata_decode_result.get("ok", false) and nodata_decode_error.contains("source.raster.nodata_value"), "decoder rejects no-data tampering before payload loading: %s" % nodata_decode_error)
    _check(not nodata_decode_result.has("vertices"), "no-data mismatch is rejected before geometry allocation")

    _check(_remove_negative_fixture_tree(fixture_root), "negative source and payload fixture files and directories are removed after verification")

func _run_geodetic_tests() -> void:
    # Fixed vectors were generated independently by Rasterio/GDAL/PROJ; see the reference note.
    var references: Array[Dictionary] = [
        {"latitude": 0.0, "longitude": 0.0, "height": 0.0, "ecef": Vector3(6378137.0, 0.0, 0.0)},
        {"latitude": 0.0, "longitude": 180.0, "height": 0.0, "ecef": Vector3(-6378137.0, 0.000000000781, 0.0)},
        {"latitude": 90.0, "longitude": 0.0, "height": 0.0, "ecef": Vector3(0.000000000392, 0.0, 6356752.3142451793)},
        {"latitude": -90.0, "longitude": 0.0, "height": 0.0, "ecef": Vector3(0.000000000392, 0.0, -6356752.3142451793)},
        {"latitude": 45.0, "longitude": 45.0, "height": 0.0, "ecef": Vector3(3194419.1450605746, 3194419.1450605746, 4487348.4088659203)},
        {"latitude": 80.0, "longitude": -179.5, "height": 1200.0, "ecef": Vector3(-1111330.9309353435, -9698.438106053656, 6260724.7303323057)},
        {"latitude": -60.0, "longitude": 170.0, "height": -4000.0, "ecef": Vector3(-3146563.7688875725, 554824.0889745936, -5497013.0323235011)},
        {"latitude": 0.0, "longitude": 0.0, "height": 100000000.0, "ecef": Vector3(106378137.0, 0.0, 0.0)}
    ]
    for reference in references:
        var forward: Dictionary = GeodeticEcef.geodetic_to_ecef(float(reference["latitude"]), float(reference["longitude"]), float(reference["height"]))
        _check(forward.get("ok", false), "WGS 84 forward conversion accepts reference (%s, %s)" % [reference["latitude"], reference["longitude"]])
        if forward.get("ok", false):
            var ecef: Vector3 = forward["ecef_m"]
            var expected: Vector3 = reference["ecef"]
            _check(ecef.distance_to(expected) <= 0.0001, "WGS 84 forward XYZ matches independent fixed reference within 0.1 mm")
        var inverse: Dictionary = GeodeticEcef.ecef_to_geodetic(reference["ecef"])
        _check(inverse.get("ok", false), "WGS 84 inverse conversion accepts fixed global reference")
        if inverse.get("ok", false):
            var latitude_error := absf(float(inverse["latitude_deg"]) - float(reference["latitude"]))
            var longitude_error := absf(float(inverse["longitude_deg"]) - float(reference["longitude"]))
            var height_error := absf(float(inverse["ellipsoidal_height_m"]) - float(reference["height"]))
            _check(latitude_error <= 0.000000001 and longitude_error <= 0.000000001 and height_error <= 0.0001, "WGS 84 inverse coordinates round-trip reference point within declared test tolerance")

    _check(not GeodeticEcef.geodetic_to_ecef(90.0001, 0.0, 0.0).get("ok", false), "WGS 84 forward conversion rejects latitude outside bounds")
    _check(not GeodeticEcef.geodetic_to_ecef(0.0, 180.0001, 0.0).get("ok", false), "WGS 84 forward conversion rejects longitude outside bounds")
    _check(not GeodeticEcef.geodetic_to_ecef(0.0, 0.0, GeodeticEcef.MIN_ELLIPSOIDAL_HEIGHT_M - 0.01).get("ok", false), "WGS 84 forward conversion rejects height below its bound")
    _check(not GeodeticEcef.geodetic_to_ecef(0.0, 0.0, GeodeticEcef.MAX_ELLIPSOIDAL_HEIGHT_M + 0.01).get("ok", false), "WGS 84 forward conversion rejects height above its bound")
    _check(not GeodeticEcef.ecef_to_geodetic(Vector3.ZERO).get("ok", false), "WGS 84 inverse conversion rejects the geocentric singularity")
    _check(not GeodeticEcef.ecef_to_geodetic(Vector3(GeodeticEcef.MAX_ECEF_RADIUS_M + 1.0, 0.0, 0.0)).get("ok", false), "WGS 84 inverse conversion rejects ECEF radius above its bound")

func _run_origin_rebase_tests() -> void:
    # These are independent WGS 84 test coordinates near the two demonstrator regions.
    # They are not sourced from, or transformed from, the regional NAD83 manifests.
    var targets: Array[Dictionary] = [
        {"name": "Baltimore-area WGS 84 test point", "latitude": 39.29, "longitude": -76.61, "height": 50.0},
        {"name": "Golden-area WGS 84 test point", "latitude": 39.755, "longitude": -105.22, "height": 1700.0},
        {"name": "high-latitude antimeridian test point", "latitude": 80.0, "longitude": 179.5, "height": 1200.0}
    ]
    var first_origin_result: Dictionary = GeodeticEcef.geodetic_to_ecef(float(targets[0]["latitude"]), float(targets[0]["longitude"]), float(targets[0]["height"]))
    var second_origin_result: Dictionary = GeodeticEcef.geodetic_to_ecef(float(targets[1]["latitude"]), float(targets[1]["longitude"]), float(targets[1]["height"]))
    _check(first_origin_result.get("ok", false) and second_origin_result.get("ok", false), "two distinct WGS 84 ECEF origins are established")
    if not first_origin_result.get("ok", false) or not second_origin_result.get("ok", false):
        return
    var ecef_origins: Array[Vector3] = [first_origin_result["ecef_m"], second_origin_result["ecef_m"]]
    var max_reconstruction_error_m := 0.0
    for target in targets:
        var expected_result: Dictionary = GeodeticEcef.geodetic_to_ecef(float(target["latitude"]), float(target["longitude"]), float(target["height"]))
        if not expected_result.get("ok", false):
            _check(false, "%s can be represented as a WGS 84 geodetic point" % target["name"])
            continue
        var expected_ecef: Vector3 = expected_result["ecef_m"]
        for origin_index in range(ecef_origins.size()):
            var origin_ecef: Vector3 = ecef_origins[origin_index]
            var local_position := expected_ecef - origin_ecef
            var reconstructed_ecef := local_position + origin_ecef
            var reconstruction_error_m := reconstructed_ecef.distance_to(expected_ecef)
            max_reconstruction_error_m = maxf(max_reconstruction_error_m, reconstruction_error_m)
            _check(reconstruction_error_m <= 0.001, "%s reconstruction after ECEF origin %d subtraction stays within 1 mm" % [target["name"], origin_index + 1])
            var reconstructed_geodetic: Dictionary = GeodeticEcef.ecef_to_geodetic(reconstructed_ecef)
            _check(reconstructed_geodetic.get("ok", false), "%s reconstructs to valid WGS 84 geodetic coordinates" % target["name"])
            if reconstructed_geodetic.get("ok", false):
                var latitude_error := absf(float(reconstructed_geodetic["latitude_deg"]) - float(target["latitude"]))
                var longitude_error := absf(float(reconstructed_geodetic["longitude_deg"]) - float(target["longitude"]))
                var height_error := absf(float(reconstructed_geodetic["ellipsoidal_height_m"]) - float(target["height"]))
                _check(latitude_error <= 0.000000001 and longitude_error <= 0.000000001 and height_error <= 0.001, "%s geodetic location is invariant across local origins within 1 mm numeric error" % target["name"])
    print("WF_REBASE_MAX_ECEF_ERROR_M=%.12f" % max_reconstruction_error_m)

func _run_spatial_address_tests() -> void:
    var level := 4
    var references: Array[Dictionary] = [
        {"name": "equator and prime meridian", "latitude": 0.0, "longitude": 0.0, "key": "wf-cube-quad-v1/f0/l4/x8/y8"},
        {"name": "antimeridian -180", "latitude": 0.0, "longitude": -180.0, "key": "wf-cube-quad-v1/f1/l4/x8/y8"},
        {"name": "antimeridian +180 wraps to -180", "latitude": 0.0, "longitude": 180.0, "key": "wf-cube-quad-v1/f1/l4/x8/y8"},
        {"name": "north pole canonical cell", "latitude": 90.0, "longitude": 0.0, "key": "wf-cube-quad-v1/f4/l4/x8/y8"},
        {"name": "north pole ignores longitude", "latitude": 90.0, "longitude": 179.0, "key": "wf-cube-quad-v1/f4/l4/x8/y8"},
        {"name": "south pole canonical cell", "latitude": -90.0, "longitude": 0.0, "key": "wf-cube-quad-v1/f5/l4/x8/y8"},
        {"name": "south pole ignores longitude", "latitude": -90.0, "longitude": -179.0, "key": "wf-cube-quad-v1/f5/l4/x8/y8"},
        {"name": "high-latitude antimeridian", "latitude": 80.0, "longitude": -179.5, "key": "wf-cube-quad-v1/f4/l4/x6/y8"},
        {"name": "southern mid-latitude", "latitude": -60.0, "longitude": 170.0, "key": "wf-cube-quad-v1/f5/l4/x3/y8"},
        {"name": "Baltimore-area synthetic WGS 84 reference", "latitude": 39.29, "longitude": -76.61, "key": "wf-cube-quad-v1/f3/l4/x9/y1"},
        {"name": "Golden-area synthetic WGS 84 reference", "latitude": 39.755, "longitude": -105.22, "key": "wf-cube-quad-v1/f3/l4/x5/y1"}
    ]
    for reference in references:
        var address := GlobalTileAddress.address_wgs84(float(reference["latitude"]), float(reference["longitude"]), level)
        var message := "%s maps to its independently fixed cubed-sphere cell key" % String(reference["name"])
        if not address.get("ok", false):
            message += ": " + String(address.get("error", "unknown address error"))
        _check(address.get("ok", false) and String(address.get("tile_key", "")) == String(reference["key"]), message)
        if address.get("ok", false):
            _check(not address.has("source_identity") and not address.has("frame_id") and not address.has("content_revision") and not address.has("runtime_handle"), "%s cell key carries no source, frame, content revision, or runtime resource handle" % String(reference["name"]))

    var same_cell: Dictionary = GlobalTileAddress.address_wgs84(39.29, -76.61, level)
    var binding_revision_a := same_cell.duplicate(true)
    binding_revision_a["source_identity"] = "synthetic-source-a"
    binding_revision_a["frame_id"] = "synthetic-frame-a"
    binding_revision_a["content_revision"] = "artifact-a"
    binding_revision_a["runtime_handle"] = 1001
    var binding_revision_b := same_cell.duplicate(true)
    binding_revision_b["source_identity"] = "synthetic-source-b"
    binding_revision_b["frame_id"] = "synthetic-frame-b"
    binding_revision_b["content_revision"] = "artifact-b"
    binding_revision_b["runtime_handle"] = 2002
    _check(GlobalTileAddress.key(binding_revision_a) == GlobalTileAddress.key(binding_revision_b) and GlobalTileAddress.key(binding_revision_a) == String(same_cell["tile_key"]), "cell identity stays fixed when source, frame, content revision, and runtime handle change")

    var parent_result := GlobalTileAddress.parent(same_cell)
    var children_result := GlobalTileAddress.children(parent_result)
    var found_child := false
    if children_result.get("ok", false):
        for child in children_result["children"]:
            found_child = found_child or GlobalTileAddress.key(child) == GlobalTileAddress.key(same_cell)
    _check(parent_result.get("ok", false) and children_result.get("ok", false) and found_child, "quadtree parent/child addresses preserve a cell identity through the selected hierarchy")
    _check(not GlobalTileAddress.address_wgs84(90.0001, 0.0, level).get("ok", false), "global cell addressing rejects latitude outside WGS 84 geographic bounds")
    _check(not GlobalTileAddress.address_wgs84(0.0, 180.0001, level).get("ok", false), "global cell addressing rejects longitude outside WGS 84 geographic bounds")
    _check(not GlobalTileAddress.address_wgs84(0.0, 0.0, GlobalTileAddress.MAX_LEVEL + 1).get("ok", false), "global cell addressing rejects levels outside the stable key domain")
    _check(not GlobalTileAddress.address_direction(Vector3.ZERO, level).get("ok", false), "global cell addressing rejects a zero direction")

    var synthetic_lod_candidates: Array[Dictionary] = [
        {"lod_level": 0, "error_known": true, "max_geometric_error_m": 0.0, "collision_eligible": true},
        {"lod_level": 1, "error_known": true, "max_geometric_error_m": 2.0, "collision_eligible": false},
        {"lod_level": 2, "error_known": false, "max_geometric_error_m": INF, "collision_eligible": false}
    ]
    var detail_lod_result := SourceErrorLodPolicy.select_visual_level(synthetic_lod_candidates, 1.0, 1.0)
    var coarse_lod_result := SourceErrorLodPolicy.select_visual_level(synthetic_lod_candidates, 10.0, 1.0)
    _check(detail_lod_result.get("ok", false) and int(detail_lod_result.get("selected_lod_level", -1)) == 0, "source-error LOD policy keeps the source reference when the candidate exceeds the scenario screen-error budget")
    _check(coarse_lod_result.get("ok", false) and int(coarse_lod_result.get("selected_lod_level", -1)) == 1, "source-error LOD policy may select a measured coarser level when the scenario budget admits it")
    var unknown_lod_one_result := SourceErrorLodPolicy.select_visual_level([
        {"lod_level": 0, "error_known": true, "max_geometric_error_m": 0.0},
        {"lod_level": 1, "error_known": false, "max_geometric_error_m": INF}
    ], 1.0, 1.0)
    _check(unknown_lod_one_result.get("ok", false) and int(unknown_lod_one_result.get("selected_lod_level", -1)) == 0, "source-error LOD policy falls back to LOD 0 when the next coarser tile error is unknown")
    _check(not SourceErrorLodPolicy.select_visual_level([{"lod_level": 0, "error_known": false}], 1.0, 1.0).get("ok", false), "source-error LOD policy fails closed when even the source reference error is unknown")
    _check(not SourceErrorLodPolicy.select_visual_level([{"lod_level": 1, "error_known": true, "max_geometric_error_m": 0.0}], 1.0, 1.0).get("ok", false), "source-error LOD policy fails closed when no source-reference level is present")
    var collision_flag_variant := synthetic_lod_candidates.duplicate(true)
    collision_flag_variant[1]["collision_eligible"] = true
    var collision_independent_result := SourceErrorLodPolicy.select_visual_level(collision_flag_variant, 10.0, 1.0)
    _check(collision_independent_result.get("ok", false) and int(collision_independent_result.get("selected_lod_level", -1)) == int(coarse_lod_result.get("selected_lod_level", -2)) and not bool(collision_independent_result.get("collision_eligibility_changed", true)), "visual LOD selection does not infer or alter collision eligibility")

    var cardinal_directions := ["east", "west", "north", "south"]
    var opposite_direction := {"east": "west", "west": "east", "north": "south", "south": "north"}
    var count := 1 << 3
    var edge_checks := 0
    var edge_failures: Array[String] = []
    for face in range(6):
        for index in range(count):
            var edge_cells: Array[Dictionary] = [
                {"address": GlobalTileAddress.address_cell(face, 3, 0, index), "direction": "west"},
                {"address": GlobalTileAddress.address_cell(face, 3, count - 1, index), "direction": "east"},
                {"address": GlobalTileAddress.address_cell(face, 3, index, 0), "direction": "north"},
                {"address": GlobalTileAddress.address_cell(face, 3, index, count - 1), "direction": "south"}
            ]
            for edge_cell in edge_cells:
                var neighbor: Dictionary = GlobalTileAddress.neighbor(edge_cell["address"], String(edge_cell["direction"]))
                var return_direction := String(neighbor.get("reciprocal_direction", opposite_direction[edge_cell["direction"]]))
                var return_neighbor: Dictionary = GlobalTileAddress.neighbor(neighbor, return_direction) if neighbor.get("ok", false) else {}
                if not neighbor.get("ok", false) or GlobalTileAddress.key(return_neighbor) != GlobalTileAddress.key(edge_cell["address"]):
                    edge_failures.append("%s %s -> %s -> %s" % [GlobalTileAddress.key(edge_cell["address"]), String(edge_cell["direction"]), GlobalTileAddress.key(neighbor), GlobalTileAddress.key(return_neighbor)])
                edge_checks += 1
    print("WF_CUBE_QUAD_FACE_EDGE_RECIPROCITY_CHECKS=%d" % edge_checks)
    _check(edge_failures.is_empty(), "all cube-face cardinal edge neighbors are stable and reciprocal")
    for edge_failure in edge_failures:
        print("WF_CUBE_QUAD_EDGE_RECIPROCITY_FAILURE=%s" % edge_failure)
    var central := GlobalTileAddress.address_cell(0, 4, 8, 8)
    var east := GlobalTileAddress.neighbor(central, "east")
    var west := GlobalTileAddress.neighbor(central, "west")
    var north := GlobalTileAddress.neighbor(central, "north")
    var south := GlobalTileAddress.neighbor(central, "south")
    _check(GlobalTileAddress.key(east) == "wf-cube-quad-v1/f0/l4/x9/y8" and GlobalTileAddress.key(west) == "wf-cube-quad-v1/f0/l4/x7/y8" and GlobalTileAddress.key(north) == "wf-cube-quad-v1/f0/l4/x8/y7" and GlobalTileAddress.key(south) == "wf-cube-quad-v1/f0/l4/x8/y9", "within-face cardinal neighbors are the expected adjacent cells")
    var cross_face_references: Array[Dictionary] = [
        {"face": 0, "direction": "east", "x": 15, "y": 8, "expected": "wf-cube-quad-v1/f2/l4/x0/y8"},
        {"face": 0, "direction": "west", "x": 0, "y": 8, "expected": "wf-cube-quad-v1/f3/l4/x15/y8"},
        {"face": 0, "direction": "north", "x": 8, "y": 0, "expected": "wf-cube-quad-v1/f4/l4/x15/y7"},
        {"face": 0, "direction": "south", "x": 8, "y": 15, "expected": "wf-cube-quad-v1/f5/l4/x15/y8"},
        {"face": 1, "direction": "east", "x": 15, "y": 8, "expected": "wf-cube-quad-v1/f3/l4/x0/y8"},
        {"face": 1, "direction": "west", "x": 0, "y": 8, "expected": "wf-cube-quad-v1/f2/l4/x15/y8"},
        {"face": 1, "direction": "north", "x": 8, "y": 0, "expected": "wf-cube-quad-v1/f4/l4/x0/y8"},
        {"face": 1, "direction": "south", "x": 8, "y": 15, "expected": "wf-cube-quad-v1/f5/l4/x0/y7"},
        {"face": 2, "direction": "east", "x": 15, "y": 8, "expected": "wf-cube-quad-v1/f1/l4/x0/y8"},
        {"face": 2, "direction": "west", "x": 0, "y": 8, "expected": "wf-cube-quad-v1/f0/l4/x15/y8"},
        {"face": 2, "direction": "north", "x": 8, "y": 0, "expected": "wf-cube-quad-v1/f4/l4/x7/y0"},
        {"face": 2, "direction": "south", "x": 8, "y": 15, "expected": "wf-cube-quad-v1/f5/l4/x7/y15"},
        {"face": 3, "direction": "east", "x": 15, "y": 8, "expected": "wf-cube-quad-v1/f0/l4/x0/y8"},
        {"face": 3, "direction": "west", "x": 0, "y": 8, "expected": "wf-cube-quad-v1/f1/l4/x15/y8"},
        {"face": 3, "direction": "north", "x": 8, "y": 0, "expected": "wf-cube-quad-v1/f4/l4/x8/y15"},
        {"face": 3, "direction": "south", "x": 8, "y": 15, "expected": "wf-cube-quad-v1/f5/l4/x8/y0"},
        {"face": 4, "direction": "east", "x": 15, "y": 8, "expected": "wf-cube-quad-v1/f0/l4/x7/y0"},
        {"face": 4, "direction": "west", "x": 0, "y": 8, "expected": "wf-cube-quad-v1/f1/l4/x8/y0"},
        {"face": 4, "direction": "north", "x": 8, "y": 0, "expected": "wf-cube-quad-v1/f2/l4/x7/y0"},
        {"face": 4, "direction": "south", "x": 8, "y": 15, "expected": "wf-cube-quad-v1/f3/l4/x8/y0"},
        {"face": 5, "direction": "east", "x": 15, "y": 8, "expected": "wf-cube-quad-v1/f0/l4/x8/y15"},
        {"face": 5, "direction": "west", "x": 0, "y": 8, "expected": "wf-cube-quad-v1/f1/l4/x7/y15"},
        {"face": 5, "direction": "north", "x": 8, "y": 0, "expected": "wf-cube-quad-v1/f3/l4/x8/y15"},
        {"face": 5, "direction": "south", "x": 8, "y": 15, "expected": "wf-cube-quad-v1/f2/l4/x7/y15"}
    ]
    for reference in cross_face_references:
        var source_address := GlobalTileAddress.address_cell(int(reference["face"]), 4, int(reference["x"]), int(reference["y"]))
        var mapped_neighbor := GlobalTileAddress.neighbor(source_address, String(reference["direction"]))
        _check(GlobalTileAddress.key(mapped_neighbor) == String(reference["expected"]), "face %d %s edge maps to its independently fixed neighboring face cell" % [int(reference["face"]), String(reference["direction"])])

    var baltimore_conversion := GlobalPositionBridge.terrain_local_to_wgs84_ecef("baltimore", Vector3.ZERO)
    var golden_conversion := GlobalPositionBridge.terrain_local_to_wgs84_ecef("golden", Vector3.ZERO)
    _check(not baltimore_conversion.get("ok", true) and String(baltimore_conversion.get("status", "")) == "unavailable" and String(baltimore_conversion.get("source_frame_id", "")) == String(SiteCatalog.get_site("baltimore")["frame_id"]), "Baltimore NAD83/GRS80 + NAVD88 source-to-global conversion is explicitly unavailable")
    _check(not golden_conversion.get("ok", true) and String(golden_conversion.get("status", "")) == "unavailable" and String(golden_conversion.get("source_frame_id", "")) == String(SiteCatalog.get_site("golden")["frame_id"]), "Golden NAD83/GRS80 + NAVD88 source-to-global conversion is explicitly unavailable")
    _check(String(baltimore_conversion.get("operation_id", "not-empty")) == "" and String(golden_conversion.get("operation_id", "not-empty")) == "", "no unverified datum or geoid operation is invented for either real terrain region")

func _run_origin_rebase_scene_tests() -> void:
    var origin := OriginRebase.new()
    origin.name = "TerrainOriginRebaseFixture"
    add_child(origin)
    var manager: TerrainStreamManagerV1 = StreamManager.new()
    manager.name = "GoldenTerrainStreamManager"
    origin.add_child(manager)
    var load_errors: Array[String] = []
    manager.load_failed.connect(func(_request_id: int, _site_id: String, message: String) -> void: load_errors.append(message))
    var initial_request := manager.request_window_set("golden", ["golden-west", "golden-east"])
    await _wait_for_window_set(manager, ["golden-west", "golden-east"])
    var load_detail := "no load errors" if load_errors.is_empty() else "; ".join(load_errors)
    _check(manager.loaded_site_id == "golden" and manager.get_loaded_tile_count() == 2, "live origin fixture loads two real Golden terrain windows asynchronously: %s" % load_detail)
    _check(initial_request > 0, "live origin fixture preserves the actual terrain request identity")
    if manager.get_loaded_tile_count() != 2:
        manager.unload()
        manager.queue_free()
        origin.queue_free()
        await get_tree().process_frame
        return

    var west_tile := manager.get_loaded_tile("golden-west")
    var east_tile := manager.get_loaded_tile("golden-east")
    var west_vertices: PackedVector3Array = (west_tile.get_node("TerrainSurface") as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
    var east_vertices: PackedVector3Array = (east_tile.get_node("TerrainSurface") as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
    var west_rows: Array = west_tile.get_meta("source_row_indices")
    var west_columns: Array = west_tile.get_meta("source_column_indices")
    var east_columns: Array = east_tile.get_meta("source_column_indices")
    var sample_row := int(west_rows.size() / 2)
    var west_width := west_columns.size()
    var east_width := east_columns.size()
    var west_probe: Vector3 = west_vertices[sample_row * west_width + west_width - 2]
    var east_probe: Vector3 = east_vertices[sample_row * east_width + 1]
    var west_seam: Vector3 = west_vertices[sample_row * west_width + west_width - 1]
    var east_seam: Vector3 = east_vertices[sample_row * east_width]
    _check(west_seam == east_seam, "live origin fixture begins from the actual installed Golden shared source sample")

    var camera := Camera3D.new()
    camera.name = "OriginFixtureCamera"
    camera.position = west_probe + Vector3(0.0, 25.0, 40.0)
    origin.add_child(camera)
    camera.look_at(west_probe, Vector3.UP)
    var test_object := StaticBody3D.new()
    test_object.name = "OriginFixtureSpatialObject"
    test_object.set_meta("object_id", "wf-test:golden-origin-fixture")
    test_object.position = west_probe + Vector3(0.0, 1.0, 0.0)
    test_object.collision_layer = 2
    test_object.collision_mask = 0
    var object_shape := CollisionShape3D.new()
    var sphere := SphereShape3D.new()
    sphere.radius = 0.25
    object_shape.shape = sphere
    test_object.add_child(object_shape)
    origin.add_child(test_object)
    var durable_camera_position := camera.position
    var durable_object_position := test_object.position
    var durable_window_ids := manager.loaded_window_ids
    var durable_tile_ids: Array[String] = []
    var durable_content_revisions: Array[String] = []
    var durable_frame_ids: Array[String] = []
    var durable_source_ids: Array[String] = []
    var pre_rebase_handles: Dictionary = {}
    for window_id in durable_window_ids:
        var tile := manager.get_loaded_tile(window_id)
        durable_tile_ids.append(String(tile.get_meta("regional_tile_id", "")))
        durable_content_revisions.append(String(tile.get_meta("content_revision", "")))
        durable_frame_ids.append(String(tile.get_meta("spatial_reference_id", "")))
        durable_source_ids.append(String(tile.get_meta("source_identity", "")))
        pre_rebase_handles[window_id] = tile.get_instance_id()

    var stale_manager: TerrainStreamManagerV1 = StreamManager.new()
    stale_manager.name = "StaleCompletionFixtureManager"
    origin.add_child(stale_manager)
    var stale_rejections: Array[Dictionary] = []
    stale_manager.stale_result_rejected.connect(func(request_id: int, site_id: String, artifact_id: String, current_request_id: int) -> void:
        stale_rejections.append({"request_id": request_id, "site_id": site_id, "artifact_id": artifact_id, "current_request_id": current_request_id})
    )
    stale_manager.request_site("baltimore")
    stale_manager.request_window_set("golden", ["golden-west", "golden-east"])
    await _wait_for_window_set(stale_manager, ["golden-west", "golden-east"])
    _check(stale_rejections.size() == 1 and int(stale_rejections[0]["request_id"]) < int(stale_rejections[0]["current_request_id"]), "stale Baltimore worker completion is rejected while primary Golden terrain remains active")
    _check(manager.loaded_window_ids == durable_window_ids and manager.get_loaded_tile_count() == 2, "stale request on a second scene manager does not replace active Golden terrain identity")
    stale_manager.unload()
    stale_manager.queue_free()
    await get_tree().process_frame

    var collision_ray := RayCast3D.new()
    collision_ray.name = "RebasedTerrainCollisionRay"
    collision_ray.collision_mask = 1
    collision_ray.collide_with_areas = false
    collision_ray.collide_with_bodies = true
    collision_ray.hit_back_faces = true
    origin.add_child(collision_ray)
    var tile_bodies: Array[StaticBody3D] = [west_tile.get_node("TerrainCollision"), east_tile.get_node("TerrainCollision")]
    var origins: Array[Vector3] = [
        Vector3.ZERO,
        Vector3(1250.0, 0.0, -750.0),
        Vector3(-2400.0, 0.0, 1800.0),
        Vector3(25000.0, 0.0, -40000.0),
        Vector3(-100000.0, 0.0, 100000.0),
        Vector3.ZERO
    ]
    var previous_generation := origin.origin_generation
    var max_camera_reconstruction_error_m := 0.0
    var max_object_reconstruction_error_m := 0.0
    for next_origin in origins:
        var rebase_result: Dictionary = origin.rebase_to_frame_position(next_origin)
        await get_tree().physics_frame
        await get_tree().physics_frame
        var camera_frame_position := origin.scene_world_to_frame(camera.global_position)
        var object_frame_position := origin.scene_world_to_frame(test_object.global_position)
        var camera_error := camera_frame_position.distance_to(durable_camera_position)
        var object_error := object_frame_position.distance_to(durable_object_position)
        max_camera_reconstruction_error_m = maxf(max_camera_reconstruction_error_m, camera_error)
        max_object_reconstruction_error_m = maxf(max_object_reconstruction_error_m, object_error)
        _check(rebase_result.get("ok", false) and int(rebase_result["origin_generation"]) == previous_generation + 1, "scene origin rebase increments its generation for the active terrain set")
        _check(camera_error <= 0.001 and object_error <= 0.001, "camera and diagnostic object durable frame positions remain within 1 mm after live scene-root translation")
        _check(manager.loaded_window_ids == durable_window_ids, "active terrain window IDs remain unchanged through repeated scene rebases")
        for index in range(durable_window_ids.size()):
            var tile := manager.get_loaded_tile(durable_window_ids[index])
            _check(String(tile.get_meta("regional_tile_id", "")) == durable_tile_ids[index] and String(tile.get_meta("content_revision", "")) == durable_content_revisions[index] and String(tile.get_meta("spatial_reference_id", "")) == durable_frame_ids[index] and String(tile.get_meta("source_identity", "")) == durable_source_ids[index], "regional tile ID, source, frame, and content identity stay fixed during rebase")
            _check(tile.get_instance_id() == int(pre_rebase_handles[durable_window_ids[index]]), "render/collision resource handle stays attached to the same tile between LOD transitions")
        await _check_rebased_terrain_ray(collision_ray, origin, west_probe, tile_bodies, "Golden west tile sample after rebase")
        await _check_rebased_terrain_ray(collision_ray, origin, east_probe, tile_bodies, "Golden east tile sample after rebase")
        await _check_rebased_terrain_ray(collision_ray, origin, west_seam, tile_bodies, "Golden shared seam sample after rebase")
        previous_generation = origin.origin_generation
    print("WF_SCENE_REBASE_MAX_CAMERA_FRAME_ERROR_M=%.12f" % max_camera_reconstruction_error_m)
    print("WF_SCENE_REBASE_MAX_OBJECT_FRAME_ERROR_M=%.12f" % max_object_reconstruction_error_m)

    var lod_one_result: Dictionary = manager.transition_adjacent_lod(1)
    _check(lod_one_result.get("ok", false) and manager.current_lod_level == 1, "live Golden neighbor set switches to the paired LOD 1 representation under the rebased scene root")
    _check(manager.loaded_window_ids == durable_window_ids, "paired LOD representation change preserves regional tile IDs")
    var lod_one_west := manager.get_loaded_tile("golden-west")
    var lod_one_east := manager.get_loaded_tile("golden-east")
    _check(lod_one_west != null and lod_one_east != null and lod_one_west.get_instance_id() != int(pre_rebase_handles["golden-west"]) and lod_one_east.get_instance_id() != int(pre_rebase_handles["golden-east"]), "LOD replacement changes volatile Godot resource handles without changing tile identity")
    _check(String(lod_one_west.get_meta("content_revision", "")) == durable_content_revisions[0] and String(lod_one_east.get_meta("content_revision", "")) == durable_content_revisions[1], "LOD representation change retains the same source content revisions")
    var lod_one_west_shape: CollisionShape3D = lod_one_west.get_node("TerrainCollision/TerrainTriangles")
    var lod_one_east_shape: CollisionShape3D = lod_one_east.get_node("TerrainCollision/TerrainTriangles")
    var lod_one_bodies: Array[StaticBody3D] = [lod_one_west.get_node("TerrainCollision"), lod_one_east.get_node("TerrainCollision")]
    _check(lod_one_west_shape.disabled and lod_one_east_shape.disabled and lod_one_bodies[0].collision_layer == 0 and lod_one_bodies[1].collision_layer == 0, "LOD 1 collision stays disabled while origin rebasing is active")
    collision_ray.position = west_probe + Vector3(0.0, -50.0, 0.0)
    collision_ray.target_position = Vector3(0.0, 100.0, 0.0)
    await get_tree().physics_frame
    collision_ray.force_raycast_update()
    _check(not collision_ray.is_colliding(), "coarse LOD collision cannot cause a contact jump after rebase")
    var lod_zero_result: Dictionary = manager.transition_adjacent_lod(0)
    _check(lod_zero_result.get("ok", false) and manager.current_lod_level == 0 and manager.ground_contact_collision_eligible, "live Golden neighbors return to source-sampled collision-eligible LOD 0")
    var lod_zero_west := manager.get_loaded_tile("golden-west")
    var lod_zero_east := manager.get_loaded_tile("golden-east")
    var lod_zero_bodies: Array[StaticBody3D] = [lod_zero_west.get_node("TerrainCollision"), lod_zero_east.get_node("TerrainCollision")]
    await _check_rebased_terrain_ray(collision_ray, origin, west_probe, lod_zero_bodies, "Golden west LOD 0 after rebase")
    await _check_rebased_terrain_ray(collision_ray, origin, east_probe, lod_zero_bodies, "Golden east LOD 0 after rebase")
    await _check_rebased_terrain_ray(collision_ray, origin, west_seam, lod_zero_bodies, "Golden shared LOD 0 seam after rebase")

    var unload_id := manager.unload()
    _check(unload_id > initial_request and manager.get_loaded_tile_count() == 0 and manager.loaded_window_ids.is_empty() and manager.get_children().is_empty(), "unload under the rebased root detaches both terrain and collision nodes and invalidates the prior request")
    await get_tree().physics_frame
    _check(manager.get_active_worker_count() == 0 and manager.get_queued_request_count() == 0, "live rebase unload leaves no pending decoder task or queued request")
    manager.queue_free()
    await get_tree().process_frame
    _check(not is_instance_valid(manager), "scene manager shuts down cleanly after live rebases and unload")
    origin.queue_free()
    await get_tree().process_frame
    _check(not is_instance_valid(origin), "origin root shuts down cleanly after its terrain, camera, object, and ray are released")

func _check_rebased_terrain_ray(ray: RayCast3D, origin: TerrainOriginRebaseV1, expected_frame_position: Vector3, allowed_bodies: Array[StaticBody3D], description: String) -> void:
    ray.position = expected_frame_position + Vector3(0.0, -50.0, 0.0)
    ray.target_position = Vector3(0.0, 100.0, 0.0)
    ray.enabled = true
    await get_tree().physics_frame
    ray.force_raycast_update()
    await get_tree().physics_frame
    _check(ray.is_colliding(), "%s collision is ready after scene rebase" % description)
    if ray.is_colliding():
        var collider: Object = ray.get_collider()
        _check(allowed_bodies.has(collider), "%s ray hits one of the intended real terrain collision bodies" % description)
        var durable_hit := origin.scene_world_to_frame(ray.get_collision_point())
        _check(durable_hit.distance_to(expected_frame_position) <= 0.001, "%s collision hit reconstructs to its unchanged terrain sample within 1 mm" % description)
func _run_collision_tests() -> void:
    for site_id in SiteCatalog.site_ids():
        if not _decoded_by_site.has(site_id):
            continue
        var decoded: Dictionary = _decoded_by_site[site_id]
        var tile := TileFactory.create_tile(decoded)
        _check(tile != null, "%s actual terrain mesh and collision resources are created" % site_id)
        if tile == null:
            continue
        add_child(tile)
        var mesh_instance: MeshInstance3D = tile.get_node("TerrainSurface")
        var collision_body: StaticBody3D = tile.get_node("TerrainCollision")
        var collision_shape: CollisionShape3D = collision_body.get_node("TerrainTriangles")
        var mesh_arrays := mesh_instance.mesh.surface_get_arrays(0)
        var mesh_vertices: PackedVector3Array = mesh_arrays[Mesh.ARRAY_VERTEX]
        var decoded_vertices: PackedVector3Array = decoded["vertices"]
        var max_vertex_delta_m := INF
        if mesh_vertices.size() == decoded_vertices.size():
            max_vertex_delta_m = 0.0
            for vertex_index in range(mesh_vertices.size()):
                max_vertex_delta_m = maxf(max_vertex_delta_m, mesh_vertices[vertex_index].distance_to(decoded_vertices[vertex_index]))
        print("WF_MESH_VERTEX_MAX_DELTA_M[%s]=%.12f" % [site_id, max_vertex_delta_m])
        _check(mesh_vertices.size() == decoded_vertices.size() and max_vertex_delta_m <= 0.001, "%s renderer uses the validated sample vertices within 1 mm" % site_id)
        _check(mesh_arrays[Mesh.ARRAY_INDEX] == decoded["indices"], "%s renderer uses the fixed contract triangle indices" % site_id)
        _check(collision_shape.shape.get_faces() == decoded["faces"], "%s collision triangles exactly match renderer index order" % site_id)
        var normals: PackedVector3Array = decoded["normals"]
        _check(normals[int(decoded["anchor_index"])].y > 0.0, "%s terrain sample normals face upward" % site_id)

        await get_tree().physics_frame
        var vertices: PackedVector3Array = decoded["vertices"]
        var sample_index := int(decoded["anchor_index"])
        var expected_position: Vector3 = vertices[sample_index]
        var ray := RayCast3D.new()
        ray.name = "SameIndexUpwardCollisionCheck"
        ray.collision_mask = 1
        ray.collide_with_areas = false
        ray.collide_with_bodies = true
        ray.hit_back_faces = true
        ray.position = expected_position + Vector3(0.0, -50.0, 0.0)
        ray.target_position = Vector3(0.0, 100.0, 0.0)
        add_child(ray)
        await get_tree().physics_frame
        await get_tree().physics_frame
        _check(ray.is_colliding(), "%s upward ray from below hits the actual static terrain collision" % site_id)
        if ray.is_colliding():
            _check(ray.get_collider() == collision_body, "%s upward ray hits the terrain collision body" % site_id)
            _check(ray.get_collision_point().distance_to(expected_position) <= 0.001, "%s upward ray intersects the same-index terrain vertex" % site_id)
        ray.queue_free()
        tile.queue_free()
        await get_tree().process_frame

func _run_lifecycle_tests() -> void:
    var manager: TerrainStreamManagerV1 = StreamManager.new()
    add_child(manager)
    var stale_request_ids: Array[int] = []
    var successful_request_ids: Array[int] = []
    manager.stale_result_rejected.connect(func(request_id: int, _site_id: String, _artifact_id: String, _current_request: int) -> void: stale_request_ids.append(request_id))
    manager.load_succeeded.connect(func(request_id: int, _site_id: String, _artifact_id: String, _frame_id: String) -> void: successful_request_ids.append(request_id))

    var first_request_id := manager.request_site("baltimore")
    var replaced_request_id := manager.request_site("golden")
    var latest_request_id := manager.request_site("baltimore")
    _check(manager.get_active_worker_count() == 1 and manager.get_queued_request_count() == 1, "rapid site toggles keep at most one worker and one replaceable latest request")
    _check(manager.get_pending_task_count() == 2, "the queued request count is bounded independently of worker count")
    await _wait_for_site(manager, "baltimore")
    _check(stale_request_ids.has(first_request_id), "the first rapid request is rejected after the latest-site replacement")
    _check(successful_request_ids.has(latest_request_id), "the latest queued request completes after the previous worker drains")
    _check(not successful_request_ids.has(first_request_id) and not successful_request_ids.has(replaced_request_id), "superseded rapid requests never install stale terrain")
    _check(manager.get_active_worker_count() == 0 and manager.get_queued_request_count() == 0, "the latest-only request queue drains after installation")
    manager.unload()
    await get_tree().process_frame

    var cancelled_request_id := manager.request_site("golden")
    var cancelled_queued_id := manager.request_site("baltimore")
    _check(manager.get_queued_request_count() == 1, "a site request made during a worker is held in the single latest slot")
    manager.unload()
    _check(manager.get_queued_request_count() == 0, "unload clears the queued request immediately")
    await _wait_until_tasks_complete(manager)
    _check(stale_request_ids.has(cancelled_request_id), "unload invalidates and rejects a late asynchronous completion")
    _check(not successful_request_ids.has(cancelled_request_id) and not successful_request_ids.has(cancelled_queued_id), "unload prevents both active and queued stale results from loading")

    var baltimore_request := manager.request_site("baltimore")
    await _wait_for_site(manager, "baltimore")
    _check(manager.loaded_site_id == "baltimore", "Baltimore bundle loads asynchronously in the parent scene")
    _check(manager.get_loaded_tile_count() == 1, "one terrain tile owns its render and collision resources")
    _check(successful_request_ids.has(baltimore_request), "Baltimore completion carries its original request ID")

    var golden_request := manager.request_site("golden")
    await _wait_for_site(manager, "golden")
    _check(manager.loaded_site_id == "golden", "switching sites unloads Baltimore and loads Golden")
    _check(manager.get_loaded_tile_count() == 1, "site replacement leaves exactly one terrain tile")
    _check(successful_request_ids.has(golden_request), "Golden completion carries its original request ID")

    manager.unload()
    await get_tree().process_frame
    _check(manager.loaded_site_id.is_empty() and manager.get_loaded_tile_count() == 0, "unload removes the active render and collision node")
    manager.queue_free()
    await get_tree().process_frame

    var shutdown_manager: TerrainStreamManagerV1 = StreamManager.new()
    add_child(shutdown_manager)
    shutdown_manager.request_site("golden")
    shutdown_manager.queue_free()
    await get_tree().process_frame
    await get_tree().process_frame
    _check(not is_instance_valid(shutdown_manager), "scene shutdown drains its worker before releasing the manager")

func _run_adjacent_lifecycle_tests() -> void:
    var manager: TerrainStreamManagerV1 = StreamManager.new()
    add_child(manager)
    var installed_sets: Array[Array] = []
    var load_errors: Array[String] = []
    manager.window_set_loaded.connect(func(_request_id: int, _site_id: String, window_ids: Array[String], _frame_id: String) -> void: installed_sets.append(window_ids.duplicate()))
    manager.load_failed.connect(func(_request_id: int, _site_id: String, message: String) -> void: load_errors.append(message))
    var requested_ids: Array[String] = ["golden-east", "golden-west"]
    var request_id := manager.request_window_set("golden", requested_ids)
    _check(manager.get_active_worker_count() <= 1 and manager.get_queued_request_count() <= 1, "adjacent window-set decode obeys the bounded worker/latest-request policy")
    await _wait_for_window_set(manager, ["golden-west", "golden-east"])
    var loaded_ids: Array[String] = manager.loaded_window_ids
    var load_detail := "no load errors" if load_errors.is_empty() else "; ".join(load_errors)
    _check(manager.loaded_site_id == "golden" and loaded_ids == ["golden-west", "golden-east"], "one request atomically installs both adjacent Golden windows in canonical order: %s" % load_detail)
    _check(manager.get_loaded_tile_count() == 2 and installed_sets.size() == 1, "the complete pair emits one install event and owns exactly two terrain tiles: %s" % load_detail)
    if manager.get_loaded_tile_count() != 2 or not _decoded_by_site.has("golden-adjacent"):
        manager.unload()
        manager.queue_free()
        await get_tree().process_frame
        return

    var strict_visual_lod := manager.select_adjacent_visual_lod(0.1, 1.0)
    var permissive_visual_lod := manager.select_adjacent_visual_lod(1000.0, 1.0)
    _check(strict_visual_lod.get("ok", false) and int(strict_visual_lod.get("selected_lod_level", -1)) == 0 and float(strict_visual_lod.get("maximum_source_error_m", -1.0)) > 0.0, "real Golden source-error policy keeps LOD 0 for the stricter synthetic camera scenario")
    _check(permissive_visual_lod.get("ok", false) and int(permissive_visual_lod.get("selected_lod_level", -1)) == 1 and float(permissive_visual_lod.get("maximum_source_error_m", -1.0)) > 0.0, "real Golden source-error policy selects LOD 1 only for the permissive synthetic camera scenario")
    _check(manager.current_lod_level == 0 and manager.ground_contact_collision_eligible and bool(strict_visual_lod.get("collision_eligibility_current", false)), "visual LOD recommendations do not transition the active terrain or change its collision eligibility")

    var pair: Dictionary = _decoded_by_site["golden-adjacent"]
    var decoded_windows: Array[Dictionary] = pair["windows"]
    var west_decoded: Dictionary = decoded_windows[0]
    var east_decoded: Dictionary = decoded_windows[1]
    var west_tile := manager.get_loaded_tile("golden-west")
    var east_tile := manager.get_loaded_tile("golden-east")
    _check(west_tile != null and east_tile != null and west_tile.get_parent() == manager and east_tile.get_parent() == manager, "both neighbor render/collision roots are installed under the same manager")
    if west_tile != null and east_tile != null:
        for tile in [west_tile, east_tile]:
            _check(int(tile.get_meta("lod_level", -1)) == 0 and int(tile.get_meta("sample_stride", -1)) == 1, "adjacent tile stays at full-resolution LOD level 0")
            _check(String(tile.get_meta("lod_policy", "")) == "adjacent_atomic_exact_subsample", "adjacent tile advertises the shared atomic exact-sample LOD policy")
            _check(bool(tile.get_meta("collision_contact_eligible", false)) and String(tile.get_meta("collision_fidelity_policy", "")) == "source_sampled_level_0", "LOD 0 collision is explicitly marked source-sampled and ground-contact eligible")
            _check(tile.get_node_or_null("TerrainSurface") != null and tile.get_node_or_null("TerrainCollision") != null, "each adjacent window installs both a visible mesh and static collision body")
        var west_body: StaticBody3D = west_tile.get_node("TerrainCollision")
        var east_body: StaticBody3D = east_tile.get_node("TerrainCollision")
        var west_vertices: PackedVector3Array = west_decoded["vertices"]
        var east_vertices: PackedVector3Array = east_decoded["vertices"]
        var row := 107
        var west_columns := int(west_decoded["columns"])
        var east_columns := int(east_decoded["columns"])
        var west_probe: Vector3 = west_vertices[row * west_columns + west_columns - 2]
        var east_probe: Vector3 = east_vertices[row * east_columns + 1]
        var seam_west: Vector3 = west_vertices[row * west_columns + west_columns - 1]
        var seam_east: Vector3 = east_vertices[row * east_columns]
        await _check_upward_terrain_ray(west_probe, [west_body], west_body, "west adjacent tile interior")
        await _check_upward_terrain_ray(east_probe, [east_body], east_body, "east adjacent tile interior")
        _check(seam_west == seam_east, "installed neighbor meshes use the same local vertex at their shared sample")
        await _check_upward_terrain_ray(seam_west, [west_body, east_body], null, "shared adjacent tile boundary")

        var lod_one_result: Dictionary = manager.transition_adjacent_lod(1)
        var lod_detail := "accepted" if lod_one_result.get("ok", false) else "rejected: %s" % String(lod_one_result.get("error", "unknown"))
        _check(lod_one_result.get("ok", false) and manager.current_lod_level == 1, "one command switches both adjacent tiles together from LOD 0 to LOD 1: %s" % lod_detail)
        _check(not bool(lod_one_result.get("ground_contact_collision_eligible", true)) and not manager.ground_contact_collision_eligible, "LOD 1 collision is explicitly ineligible for ground-level contact")
        var lod_one_west: Dictionary = LodBuilder.build(west_decoded, 1)
        var lod_one_east: Dictionary = LodBuilder.build(east_decoded, 1)
        var lod_pair_result: Dictionary = LodBuilder.validate_adjacent_pair(lod_one_west, lod_one_east)
        _check(lod_pair_result.get("ok", false), "coarse neighbor pair preserves exact shared sample rows and seam vertices")
        var west_level_one := manager.get_loaded_tile("golden-west")
        var east_level_one := manager.get_loaded_tile("golden-east")
        _check(west_level_one != null and east_level_one != null and west_level_one != west_tile and east_level_one != east_tile, "LOD 1 replaces both old render/collision roots with new paired roots")
        var west_level_one_body: StaticBody3D = west_level_one.get_node("TerrainCollision")
        var east_level_one_body: StaticBody3D = east_level_one.get_node("TerrainCollision")
        for tile in [west_level_one, east_level_one]:
            _check(int(tile.get_meta("lod_level", -1)) == 1 and int(tile.get_meta("sample_stride", -1)) == 2, "both neighbors advertise level 1 with exact stride-2 source sampling")
            _check(String(tile.get_meta("edge_sample_policy", "")) == "preserve_final_row_and_column", "coarse LOD preserves the final source row and column")
            _check(not bool(tile.get_meta("collision_contact_eligible", true)) and String(tile.get_meta("collision_fidelity_policy", "")) == "coarse_structural_lod_not_for_ground_contact", "LOD 1 collision explicitly refuses a ground-contact fidelity claim")
        var west_lod_rows: Array[int] = lod_one_west["source_rows"]
        var west_lod_columns: Array[int] = lod_one_west["source_columns"]
        var east_lod_columns: Array[int] = lod_one_east["source_columns"]
        _check(west_lod_rows.front() == 0 and west_lod_rows.back() == 215 and west_lod_columns.front() == 0 and west_lod_columns.back() == 216 and east_lod_columns.front() == 0 and east_lod_columns.back() == 215, "LOD 1 retains each outer edge and the shared global source column 8430")
        var west_lod_vertices: PackedVector3Array = lod_one_west["vertices"]
        var east_lod_vertices: PackedVector3Array = lod_one_east["vertices"]
        var max_sample_copy_delta_m := 0.0
        var west_source_columns := int(west_decoded["columns"])
        for output_row in range(west_lod_rows.size()):
            for output_column in range(west_lod_columns.size()):
                var source_index := west_lod_rows[output_row] * west_source_columns + west_lod_columns[output_column]
                max_sample_copy_delta_m = maxf(max_sample_copy_delta_m, west_lod_vertices[output_row * west_lod_columns.size() + output_column].distance_to(west_vertices[source_index]))
        var east_source_columns := int(east_decoded["columns"])
        var east_lod_rows: Array[int] = lod_one_east["source_rows"]
        for output_row in range(east_lod_rows.size()):
            for output_column in range(east_lod_columns.size()):
                var source_index: int = east_lod_rows[output_row] * east_source_columns + east_lod_columns[output_column]
                max_sample_copy_delta_m = maxf(max_sample_copy_delta_m, east_lod_vertices[output_row * east_lod_columns.size() + output_column].distance_to(east_vertices[source_index]))
        _check(max_sample_copy_delta_m == 0.0, "LOD 1 uses exact existing source sample coordinates and heights without averaging or resampling")
        var max_omitted_deviation_m := float(lod_one_result.get("max_omitted_sample_deviation_m", INF))
        print("WF_GOLDEN_ADJACENT_MAX_OMITTED_SAMPLE_DEVIATION_M=%.9f" % max_omitted_deviation_m)
        _check(is_finite(max_omitted_deviation_m) and max_omitted_deviation_m > 0.0, "LOD 1 records a finite observed omitted-sample deviation for the real crop")
        var west_level_one_mesh: MeshInstance3D = west_level_one.get_node("TerrainSurface")
        var east_level_one_mesh: MeshInstance3D = east_level_one.get_node("TerrainSurface")
        _check((west_level_one_mesh.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() == west_lod_vertices.size() and (east_level_one_mesh.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() == east_lod_vertices.size(), "LOD 1 renderer uses the reduced exact-sample geometry for both tiles")
        var west_level_one_shape: CollisionShape3D = west_level_one_body.get_node("TerrainTriangles")
        var east_level_one_shape: CollisionShape3D = east_level_one_body.get_node("TerrainTriangles")
        _check(west_level_one_shape.shape.get_faces() == lod_one_west["faces"] and east_level_one_shape.shape.get_faces() == lod_one_east["faces"], "LOD 1 coarse collision resources match their rendered triangle geometry")
        _check(west_level_one_shape.disabled and east_level_one_shape.disabled and west_level_one_body.collision_layer == 0 and east_level_one_body.collision_layer == 0 and west_level_one_body.collision_mask == 0 and east_level_one_body.collision_mask == 0, "LOD 1 collision is disabled on shapes and physics layers so it cannot affect contacts or queries")
        await get_tree().physics_frame
        var coarse_row := 53
        var west_coarse_width := int(lod_one_west["columns"])
        var east_coarse_width := int(lod_one_east["columns"])
        await _check_upward_terrain_no_hit(west_lod_vertices[coarse_row * west_coarse_width + west_coarse_width - 2], "west LOD 1 disabled collision")
        await _check_upward_terrain_no_hit(east_lod_vertices[coarse_row * east_coarse_width + 1], "east LOD 1 disabled collision")
        var coarse_seam_west := west_lod_vertices[coarse_row * west_coarse_width + west_coarse_width - 1]
        var coarse_seam_east := east_lod_vertices[coarse_row * east_coarse_width]
        _check(coarse_seam_west == coarse_seam_east, "both level-1 neighbors keep a bit-identical local shared seam vertex")
        await _check_upward_terrain_no_hit(coarse_seam_west, "shared LOD 1 disabled boundary collision")

        var lod_zero_result: Dictionary = manager.transition_adjacent_lod(0)
        _check(lod_zero_result.get("ok", false) and manager.current_lod_level == 0, "one command switches both adjacent tiles together from LOD 1 back to LOD 0")
        _check(bool(lod_zero_result.get("ground_contact_collision_eligible", false)) and manager.ground_contact_collision_eligible, "returning to LOD 0 restores the source-sampled ground-contact collision designation")
        var west_level_zero_again := manager.get_loaded_tile("golden-west")
        var east_level_zero_again := manager.get_loaded_tile("golden-east")
        _check(west_level_zero_again != null and east_level_zero_again != null and int(west_level_zero_again.get_meta("lod_level", -1)) == 0 and int(east_level_zero_again.get_meta("lod_level", -1)) == 0, "return transition rebuilds both neighbors at full resolution")
        if west_level_zero_again != null and east_level_zero_again != null:
            var west_level_zero_body: StaticBody3D = west_level_zero_again.get_node("TerrainCollision")
            var east_level_zero_body: StaticBody3D = east_level_zero_again.get_node("TerrainCollision")
            await _check_upward_terrain_ray(west_probe, [west_level_zero_body], west_level_zero_body, "west returned LOD 0 tile")
            await _check_upward_terrain_ray(east_probe, [east_level_zero_body], east_level_zero_body, "east returned LOD 0 tile")
            await _check_upward_terrain_ray(seam_west, [west_level_zero_body, east_level_zero_body], null, "returned LOD 0 shared boundary")
    else:
        _check(false, "both adjacent tile roots exist before collision probes")

    _check(installed_sets[0] == ["golden-west", "golden-east"], "install signal reports one ordered complete window set")
    _check(request_id > 0, "adjacent load preserves the originating request ID")
    var unloaded_id := manager.unload()
    _check(unloaded_id > request_id and manager.get_loaded_tile_count() == 0 and manager.loaded_window_ids.is_empty(), "unload releases the adjacent pair as one manager operation")
    _check(manager.get_children().is_empty(), "atomic adjacent unload detaches every render and collision root immediately")
    await get_tree().process_frame
    _check(manager.get_active_worker_count() == 0 and manager.get_queued_request_count() == 0, "adjacent install/unload leaves no decoder task or queued set")
    manager.queue_free()
    await get_tree().process_frame

func _wait_for_window_set(manager: TerrainStreamManagerV1, expected_ids: Array[String]) -> void:
    var frames_left := 1800
    while manager.loaded_window_ids != expected_ids and manager.get_pending_task_count() > 0 and frames_left > 0:
        await get_tree().process_frame
        frames_left -= 1
    _check(frames_left > 0, "adjacent Golden pair completes before the functional test timeout")

func _check_upward_terrain_ray(expected_position: Vector3, allowed_bodies: Array[StaticBody3D], required_body: StaticBody3D, description: String) -> void:
    var ray := RayCast3D.new()
    ray.name = "AdjacentTileCollisionReadinessCheck"
    ray.collision_mask = 1
    ray.collide_with_areas = false
    ray.collide_with_bodies = true
    ray.hit_back_faces = true
    ray.position = expected_position + Vector3(0.0, -50.0, 0.0)
    ray.target_position = Vector3(0.0, 100.0, 0.0)
    add_child(ray)
    await get_tree().physics_frame
    await get_tree().physics_frame
    _check(ray.is_colliding(), "%s upward ray is ready after install" % description)
    if ray.is_colliding():
        var collider: Object = ray.get_collider()
        _check(allowed_bodies.has(collider), "%s upward ray hits one of the intended neighboring collision bodies" % description)
        if required_body != null:
            _check(collider == required_body, "%s upward ray resolves to the owning tile collision body" % description)
        _check(ray.get_collision_point().distance_to(expected_position) <= 0.001, "%s upward ray intersects the decoded sample position within 1 mm" % description)
    ray.queue_free()
    await get_tree().process_frame

func _check_upward_terrain_no_hit(expected_position: Vector3, description: String) -> void:
    var ray := RayCast3D.new()
    ray.name = "DisabledLodCollisionRejectionCheck"
    ray.collision_mask = 1
    ray.collide_with_areas = false
    ray.collide_with_bodies = true
    ray.hit_back_faces = true
    ray.position = expected_position + Vector3(0.0, -50.0, 0.0)
    ray.target_position = Vector3(0.0, 100.0, 0.0)
    add_child(ray)
    await get_tree().physics_frame
    await get_tree().physics_frame
    _check(not ray.is_colliding(), "%s cannot be hit by a same-index upward physics ray" % description)
    ray.queue_free()
    await get_tree().process_frame
func _wait_for_site(manager: TerrainStreamManagerV1, site_id: String) -> void:
    var frames_left := 1800
    while manager.loaded_site_id != site_id and manager.get_pending_task_count() > 0 and frames_left > 0:
        await get_tree().process_frame
        frames_left -= 1
    _check(frames_left > 0, "%s asynchronous load completes before the functional test timeout" % site_id)

func _wait_until_tasks_complete(manager: TerrainStreamManagerV1) -> void:
    var frames_left := 1800
    while manager.get_pending_task_count() > 0 and frames_left > 0:
        await get_tree().process_frame
        frames_left -= 1
    _check(frames_left > 0, "cancelled worker completion is observed and awaited")

func _remove_negative_fixture_tree(path: String) -> bool:
    var expected_path := OS.get_user_data_dir().path_join("terrain-contract-negative-fixture").simplify_path()
    if path.simplify_path() != expected_path:
        return false
    return _remove_directory_tree(expected_path)

func _remove_directory_tree(path: String) -> bool:
    if not DirAccess.dir_exists_absolute(path):
        return true
    var parent := DirAccess.open(path.get_base_dir())
    if parent == null or parent.is_link(path):
        return false
    var directory := DirAccess.open(path)
    if directory == null:
        return false
    for filename in directory.get_files():
        var file_path := path.path_join(filename)
        if directory.is_link(file_path) or DirAccess.remove_absolute(file_path) != OK:
            return false
    for directory_name in directory.get_directories():
        var child_path := path.path_join(directory_name)
        if directory.is_link(child_path) or not _remove_directory_tree(child_path):
            return false
    return DirAccess.remove_absolute(path) == OK
func _write_bytes(path: String, bytes: PackedByteArray) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        _check(false, "negative test fixture file can be written")
        return
    file.store_buffer(bytes)
    file.close()

func _check(condition: bool, description: String) -> void:
    _checks += 1
    if condition:
        print("PASS  %s" % description)
    else:
        _failures += 1
        push_error("FAIL  %s" % description)

func _report_summary() -> void:
    print("WF_TERRAIN_TEST_RESULT=%s checks=%d failures=%d" % ["PASS" if _failures == 0 else "FAIL", _checks, _failures])
