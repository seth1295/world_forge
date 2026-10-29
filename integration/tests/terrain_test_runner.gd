extends Node

const StrictJson := preload("res://terrain/strict_json_v1.gd")
const SchemaV1 := preload("res://terrain/schema_v1.gd")
const ContractV1 := preload("res://terrain/terrain_contract_v1.gd")
const Decoder := preload("res://terrain/bundle_decoder_v1.gd")
const SiteCatalog := preload("res://terrain/site_catalog_v1.gd")
const TileFactory := preload("res://terrain/terrain_tile_factory_v1.gd")
const GeodeticEcef := preload("res://terrain/geodetic_ecef_wgs84_v1.gd")
const StreamManager := preload("res://terrain/terrain_stream_manager_v1.gd")

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
        "collision":
            _run_contract_tests()
            await _run_collision_tests()
        "lifecycle":
            await _run_lifecycle_tests()
        "all":
            _run_contract_tests()
            _run_geodetic_tests()
            _run_origin_rebase_tests()
            await _run_collision_tests()
            await _run_lifecycle_tests()
        _:
            _check(false, "supported suite name is contracts, geodetic, rebase, collision, lifecycle, or all")
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
    _run_tampered_payload_test()
    _run_bounded_read_tests()

func _run_catalog_window_design_tests() -> void:
    var shared_source: Dictionary = {"product_id": "USGS shared raster", "raster": {"sha256": "628fd3bd2b2de7e36d37f7a28050db9f34bc73a7b9a8f77f54a488ec8ce757d0"}}
    var site_definition: Dictionary = {
        "site_id": "window-catalog-fixture",
        "frame_id": "wf-fixture:shared-frame",
        "source": shared_source,
        "windows": {
            "west": {"bundle_directory": "fixture-west", "artifact_id": "west-window-artifact", "source_window": {"row_offset": 100, "column_offset": 200}},
            "east": {"bundle_directory": "fixture-east", "artifact_id": "east-window-artifact", "source_window": {"row_offset": 100, "column_offset": 416}}
        }
    }
    var west_window := SiteCatalog.make_window_record(site_definition, "west")
    var east_window := SiteCatalog.make_window_record(site_definition, "east")
    _check(not west_window.is_empty() and not east_window.is_empty(), "site catalog resolves more than one window record")
    _check(west_window.get("frame_id") == east_window.get("frame_id") and west_window.get("source") == east_window.get("source"), "adjacent-window records inherit one shared source-raster and frame identity")
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
