class_name RoadsInteropTestRunner
extends Node

const Decoder := preload("res://terrain/bundle_decoder_v1.gd")
const SiteCatalog := preload("res://terrain/site_catalog_v1.gd")
const TileFactory := preload("res://terrain/terrain_tile_factory_v1.gd")
const StrictJson := preload("res://terrain/strict_json_v1.gd")
const Roads := preload("res://features/roads_feature_consumer_v1.gd")

const TEST_VECTOR_PATH := "integration/features/fixtures/golden_dem_sample_vector_v1.json"
const DISPLAY_OFFSET_M := Roads.DEFAULT_DISPLAY_OFFSET_M

var _failures: Array[String] = []

func run_suite(suite_name: String, repository_root: String) -> int:
    _failures.clear()
    if suite_name != "roads":
        push_error("Unknown roads interoperability test suite: %s" % suite_name)
        return 2
    _run_roads_contract_tests(repository_root)
    if _failures.is_empty():
        print("WF_ROADS_TEST_RESULT=PASS")
        return 0
    for failure in _failures:
        push_error("WF_ROADS_TEST_FAILURE=%s" % failure)
    print("WF_ROADS_TEST_RESULT=FAIL")
    return 1

func _run_roads_contract_tests(repository_root: String) -> void:
    var site := SiteCatalog.get_site("golden")
    _expect(not site.is_empty(), "Golden site is approved")
    if site.is_empty():
        return
    var decoder := Decoder.new()
    decoder.decode("golden", repository_root)
    var decoded: Dictionary = decoder.result
    _expect(bool(decoded.get("ok", false)), "real Golden terrain bundle decodes")
    if not decoded.get("ok", false):
        _failures.append("Golden terrain decoder returned: %s" % String(decoded.get("error", "")))
        return

    var road_result := Roads.load_bundle(repository_root)
    _expect(bool(road_result.get("ok", false)), "Census feature bundle validates against its schema and exact Golden frame")
    if not road_result.get("ok", false):
        _failures.append("road consumer rejected bundle: %s" % String(road_result.get("error", "")))
        return
    var collection: Dictionary = road_result["collection"]
    var schema: Dictionary = road_result["schema"]
    var terrain_manifest: Dictionary = road_result["terrain_manifest"]
    _expect(collection["frame"] == decoded["manifest"]["frame"], "road and rendered terrain use the exact same frame object")
    _expect(collection["frame"]["frame_id"] == site["frame_id"], "road and terrain scene use the Golden frame ID")
    _expect(collection["terrain_support"]["artifact_id"] == site["artifact_id"], "road bundle references the pinned Golden artifact")

    _test_collection_digest(repository_root, schema, terrain_manifest)
    _test_rejection_cases(collection, schema, terrain_manifest)
    _test_known_dem_sample(repository_root, decoded)
    _test_intermediate_triangle_sample(decoded)

    var drape := Roads.build_draped_mesh(collection, decoded, DISPLAY_OFFSET_M)
    _expect(bool(drape.get("ok", false)), "selected Census centerlines drape onto the real Golden terrain support")
    if not drape.get("ok", false):
        _failures.append("terrain drape failed: %s" % String(drape.get("error", "")))
        return
    _expect(int(drape.get("draped_point_count", 0)) > 0, "at least one selected centerline point is supported by Golden DEM")
    _expect(int(drape.get("draped_point_count", 0)) == 351, "351 of the 364 committed source-resampled points fall on Golden sample-centre support")
    _expect(int(drape.get("support_miss_count", 0)) == 13, "13 source points beyond the Golden sample-centre hull remain undraped")
    _expect(int(drape.get("rendered_vertex_count", 0)) > int(drape.get("draped_point_count", 0)), "viewer display subdivision samples the terrain mesh between source-resampled points")
    _expect(int(drape.get("line_strip_count", 0)) > 0, "draped centerline meshes contain rendered line strips")
    _expect(int(drape.get("support_miss_count", 0)) >= 0, "points outside terrain sample centres are counted without extrapolation")

    var placement_root := Node3D.new()
    placement_root.name = "RoadsTestFrameRoot"
    add_child(placement_root)
    var terrain_tile := TileFactory.create_tile(decoded)
    _expect(terrain_tile != null, "real source-derived terrain tile can be placed for interoperability test")
    if terrain_tile == null:
        placement_root.queue_free()
        return
    placement_root.add_child(terrain_tile)
    var roads_instance := MeshInstance3D.new()
    roads_instance.name = "DrapedCensusCenterlines"
    roads_instance.mesh = drape["mesh"]
    placement_root.add_child(roads_instance)
    _expect(terrain_tile.position == Vector3.ZERO, "terrain tile stays at the Golden site-local origin")
    _expect(roads_instance.position == Vector3.ZERO, "road mesh uses the same site-local origin as terrain")
    _expect(String(terrain_tile.get_meta("frame_id", "")) == String(collection["frame"]["frame_id"]), "terrain scene frame metadata matches road feature frame")
    _expect(roads_instance.mesh.get_surface_count() > 0, "draped road scene has rendered surfaces")
    var h0 := float(decoded["manifest"]["frame"]["origin"]["height_navd88_m"])
    for report_variant in drape["sample_reports"]:
        var report: Dictionary = report_variant
        if not report.get("draped", false):
            continue
        _expect(float(report["height_navd88_m"]) == h0 + float(report["terrain_local_up_m"]), "sample report preserves NAVD88 H separately from local H-H0")
        _expect(float(report["display_local_y_m"]) == float(report["terrain_local_up_m"]) + DISPLAY_OFFSET_M, "display offset is applied after and separately from support sampling")
    print("WF_ROADS_DRAPE_POINT_COUNT=%d" % int(drape["draped_point_count"]))
    print("WF_ROADS_UNSUPPORTED_TERRAIN_EDGE_POINTS=%d" % int(drape["support_miss_count"]))
    print("WF_ROADS_LINE_STRIP_COUNT=%d" % int(drape["line_strip_count"]))
    print("WF_ROADS_ALIGNMENT_SAMPLE_REPORTS=%s" % JSON.stringify(drape["sample_reports"]))
    placement_root.queue_free()

func _test_collection_digest(repository_root: String, schema: Dictionary, terrain_manifest: Dictionary) -> void:
    var feature_path := repository_root.path_join("integration/features").path_join(Roads.FEATURE_FILE)
    var file := FileAccess.open(feature_path, FileAccess.READ)
    _expect(file != null, "road feature bytes open for the pinned digest regression test")
    if file == null:
        return
    var byte_count := file.get_length()
    _expect(byte_count > 0 and byte_count <= Roads.MAX_FEATURE_BYTES, "road feature bytes fit the consumer read cap")
    if byte_count <= 0 or byte_count > Roads.MAX_FEATURE_BYTES:
        file.close()
        return
    var source_bytes := file.get_buffer(byte_count)
    file.close()
    _expect(source_bytes.size() == byte_count, "road feature bytes are fully read once for the digest regression test")
    if source_bytes.size() != byte_count:
        return

    var marker := "urn:worldforge:contract:road-centerlines:1.0.0"
    var marker_character_index := source_bytes.get_string_from_utf8().find(marker)
    _expect(marker_character_index >= 0, "road feature bytes contain the contract identity marker")
    if marker_character_index < 0:
        return
    var byte_index := source_bytes.get_string_from_utf8().substr(0, marker_character_index).to_utf8_buffer().size()
    var changed_bytes := source_bytes.duplicate()
    changed_bytes[byte_index + marker.to_utf8_buffer().size() - 1] = 0x31
    var changed_result := Roads.validate_collection_bytes(changed_bytes, schema, terrain_manifest)
    _expect(
        not changed_result.get("ok", false) and String(changed_result.get("error", "")).contains("SHA-256"),
        "feature consumer rejects same-length collection bytes whose digest differs from the pinned bundle"
    )

func _test_rejection_cases(collection: Dictionary, schema: Dictionary, terrain_manifest: Dictionary) -> void:
    var wrong_frame := collection.duplicate(true)
    wrong_frame["frame"]["frame_id"] = "wf-invalid-frame"
    _expect(not Roads.validate_collection(wrong_frame, schema, terrain_manifest).is_empty(), "feature consumer rejects a changed frame identity")

    var three_dimensional := collection.duplicate(true)
    three_dimensional["features"][0]["geometry"]["paths"][0]["points"][0]["z"] = 15.0
    _expect(not Roads.validate_collection(three_dimensional, schema, terrain_manifest).is_empty(), "feature consumer rejects an unsupported Z value")

    var non_finite := collection.duplicate(true)
    non_finite["features"][0]["geometry"]["paths"][0]["points"][0]["local_xy_m"][0] = NAN
    _expect(not Roads.validate_collection(non_finite, schema, terrain_manifest).is_empty(), "feature consumer rejects a non-finite projected coordinate")

    var non_numeric := collection.duplicate(true)
    non_numeric["features"][0]["geometry"]["paths"][0]["points"][0]["local_xy_m"][0] = "0"
    _expect(not Roads.validate_collection(non_numeric, schema, terrain_manifest).is_empty(), "feature consumer rejects a string masquerading as a coordinate")

    var unknown_field := collection.duplicate(true)
    unknown_field["features"][0]["geometry"]["paths"][0]["points"][0]["width_m"] = 2.0
    _expect(not Roads.validate_collection(unknown_field, schema, terrain_manifest).is_empty(), "feature consumer rejects uncontracted road width fields")

    var duplicate_id := collection.duplicate(true)
    duplicate_id["features"].append(duplicate_id["features"][0].duplicate(true))
    _expect(not Roads.validate_collection(duplicate_id, schema, terrain_manifest).is_empty(), "feature consumer rejects duplicate stable source IDs")

func _test_known_dem_sample(repository_root: String, decoded: Dictionary) -> void:
    var fixture_path := repository_root.path_join(TEST_VECTOR_PATH)
    var fixture_result := _read_json(fixture_path, 16_384)
    _expect(bool(fixture_result.get("ok", false)), "Golden known-sample vector reads as strict JSON")
    if not fixture_result.get("ok", false):
        return
    var fixture: Dictionary = fixture_result["value"]
    var grid_row := int(fixture["terrain_grid_row"])
    var grid_column := int(fixture["terrain_grid_column"])
    var columns := int(decoded["columns"])
    var sample_index := grid_row * columns + grid_column
    var vertex: Vector3 = decoded["vertices"][sample_index]
    var expected_xy: Array = fixture["local_xy_m"]
    var expected_local_up := float(fixture["local_up_m"])
    _expect(String(fixture["notice"]).contains("not a Census road feature"), "known-sample vector is explicitly test-only")

    _expect(vertex.x == float(expected_xy[0]), "test road coordinate maps to the exact DEM sample easting")
    _expect(-vertex.z == float(expected_xy[1]), "test road coordinate maps to the exact DEM sample northing")
    _expect(vertex.y == expected_local_up, "test road coordinate maps to the exact NAVD88 H-H0 sample")
    _expect(float(fixture["height_navd88_m"]) - float(fixture["h0_navd88_m"]) == expected_local_up, "sample vector keeps NAVD88 height and display local-up separate")

    var sample := Roads.sample_surface_height(
        decoded["vertices"],
        int(decoded["rows"]),
        columns,
        Vector2(float(expected_xy[0]), -float(expected_xy[1])),
        Vector2(float(grid_row), float(grid_column))
    )
    _expect(bool(sample.get("ok", false)), "known sample coordinate hits the validated terrain support surface")
    if sample.get("ok", false):
        _expect(float(sample["local_up_m"]) == expected_local_up, "sampled support height equals the known DEM H-H0 value")
    print("WF_ROADS_KNOWN_DEM_SAMPLE=%s" % JSON.stringify(fixture))

func _test_intermediate_triangle_sample(decoded: Dictionary) -> void:
    var rows := int(decoded["rows"])
    var columns := int(decoded["columns"])
    var row := 75
    var column := 150
    _expect(row < rows - 1 and column < columns - 1, "intermediate DEM test cell exists")
    if row >= rows - 1 or column >= columns - 1:
        return
    var nw: Vector3 = decoded["vertices"][row * columns + column]
    var ne: Vector3 = decoded["vertices"][row * columns + column + 1]
    var point := Vector2((nw.x + ne.x) * 0.5, (nw.z + ne.z) * 0.5)
    var expected_local_up := (nw.y + ne.y) * 0.5
    var sample := Roads.sample_surface_height(
        decoded["vertices"],
        rows,
        columns,
        point,
        Vector2(float(row), float(column) + 0.5)
    )
    _expect(bool(sample.get("ok", false)), "intermediate centerline point samples an exact terrain triangle")
    if sample.get("ok", false):
        _expect(float(sample["local_up_m"]) == expected_local_up, "intermediate centerline height follows the exact NW-NE edge interpolation formula")
        print("WF_ROADS_INTERMEDIATE_SAMPLE_EXPECTED_LOCAL_UP_M=%.12f" % expected_local_up)
        print("WF_ROADS_INTERMEDIATE_SAMPLE_ACTUAL_LOCAL_UP_M=%.12f" % float(sample["local_up_m"]))

func _read_json(path: String, byte_limit: int) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {"ok": false, "error": "cannot open test vector"}
    var byte_count := file.get_length()
    if byte_count <= 0 or byte_count > byte_limit:
        file.close()
        return {"ok": false, "error": "test vector byte length is invalid"}
    var bytes := file.get_buffer(byte_count)
    file.close()
    return StrictJson.new().parse_bytes(bytes, byte_limit)

func _expect(condition: bool, message: String) -> void:
    if condition:
        print("WF_ROADS_TEST_PASS=%s" % message)
    else:
        _failures.append(message)
