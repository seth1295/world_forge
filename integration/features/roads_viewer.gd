class_name RoadsInteropViewer
extends Node3D

const SiteCatalog := preload("res://terrain/site_catalog_v1.gd")
const Decoder := preload("res://terrain/bundle_decoder_v1.gd")
const Roads := preload("res://features/roads_feature_consumer_v1.gd")
const TestRunner := preload("res://features/roads_test_runner.gd")

const DISPLAY_OFFSET_M := Roads.DEFAULT_DISPLAY_OFFSET_M

@onready var _terrain_manager: TerrainStreamManagerV1 = $TerrainStreamManager

var _camera: Camera3D
var _status_label: Label
var _detail_label: Label
var _capture_output_path := ""

func _ready() -> void:
    var test_suite := _argument_value("--test")
    if not test_suite.is_empty():
        call_deferred("_run_test_suite", test_suite)
        return
    _create_view_environment()
    _build_technical_overlay()
    _terrain_manager.load_started.connect(_on_load_started)
    _terrain_manager.load_succeeded.connect(_on_load_succeeded)
    _terrain_manager.load_failed.connect(_on_load_failed)
    _capture_output_path = _argument_value("--capture")
    _select_golden_site()

func _run_test_suite(test_suite: String) -> void:
    var runner: Node = TestRunner.new()
    add_child(runner)
    var exit_code: int = runner.run_suite(test_suite, SiteCatalog.repository_root())
    get_tree().quit(exit_code)

func _create_view_environment() -> void:
    var world_environment := WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.76, 0.82, 0.86, 1.0)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.74, 0.78, 0.82, 1.0)
    environment.ambient_light_energy = 0.7
    environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    world_environment.environment = environment
    add_child(world_environment)

    var sun := DirectionalLight3D.new()
    sun.name = "DiagnosticSun"
    sun.rotation_degrees = Vector3(-53.0, -24.0, 0.0)
    sun.light_color = Color(1.0, 0.94, 0.82, 1.0)
    sun.light_energy = 1.35
    sun.shadow_enabled = true
    add_child(sun)

    _camera = Camera3D.new()
    _camera.name = "RoadsDiagnosticCamera"
    _camera.current = true
    _camera.fov = 58.0
    _camera.near = 0.5
    _camera.far = 8000.0
    add_child(_camera)

func _build_technical_overlay() -> void:
    var canvas := CanvasLayer.new()
    canvas.name = "RoadsTechnicalOverlay"
    add_child(canvas)

    var panel := PanelContainer.new()
    panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
    panel.position = Vector2(22.0, 22.0)
    panel.custom_minimum_size = Vector2(520.0, 0.0)
    var panel_style := StyleBoxFlat.new()
    panel_style.bg_color = Color(0.055, 0.085, 0.105, 0.95)
    panel_style.border_color = Color(0.31, 0.54, 0.56, 0.92)
    panel_style.set_border_width_all(1)
    panel_style.set_corner_radius_all(8)
    panel_style.content_margin_left = 15.0
    panel_style.content_margin_right = 15.0
    panel_style.content_margin_top = 13.0
    panel_style.content_margin_bottom = 13.0
    panel.add_theme_stylebox_override("panel", panel_style)
    canvas.add_child(panel)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 7)
    panel.add_child(column)

    var eyebrow := Label.new()
    eyebrow.text = "WORLDFORGE  /  ROAD INTEROPERABILITY V1"
    eyebrow.add_theme_color_override("font_color", Color(0.49, 0.82, 0.76, 1.0))
    eyebrow.add_theme_font_size_override("font_size", 12)
    column.add_child(eyebrow)

    var title := Label.new()
    title.text = "Census road centerlines on real Golden terrain"
    title.add_theme_color_override("font_color", Color(0.92, 0.96, 0.96, 1.0))
    title.add_theme_font_size_override("font_size", 19)
    column.add_child(title)

    _status_label = Label.new()
    _status_label.text = "LOADING  /  validated Golden terrain support"
    _status_label.add_theme_color_override("font_color", Color(0.83, 0.88, 0.9, 1.0))
    _status_label.add_theme_font_size_override("font_size", 13)
    _status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(_status_label)

    _detail_label = Label.new()
    _detail_label.text = "2026 U.S. Census Bureau All Roads, Jefferson County, Colorado\n"
    _detail_label.text += "Three source LINEARIDs / 2D NAD83 longitude-latitude / no Z or width\n"
    _detail_label.text += "Golden NAD83 / GRS80 AEQD frame / NAVD88 H-H0 inferred terrain drape\n"
    _detail_label.text += "Census positional accuracy is unspecified; display offset +%.2f m" % DISPLAY_OFFSET_M
    _detail_label.add_theme_color_override("font_color", Color(0.66, 0.75, 0.79, 1.0))
    _detail_label.add_theme_font_size_override("font_size", 12)
    _detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(_detail_label)

func _select_golden_site() -> void:
    var site := SiteCatalog.get_site("golden")
    if site.is_empty():
        _fail("Golden site is not approved by Terrain Grid v1")
        return
    _camera.position = Vector3(0.0, 2200.0, 1600.0)
    _camera.look_at(Vector3(0.0, 80.0, 0.0), Vector3.UP)
    _status_label.text = "LOADING  /  real USGS Golden DEM and static collision"
    _detail_label.text += "\nFrame %s" % String(site["frame_id"])
    _terrain_manager.request_site("golden")

func _on_load_started(_request_id: int, site_id: String) -> void:
    _status_label.text = "LOADING  /  validated source terrain for %s" % site_id

func _on_load_succeeded(_request_id: int, site_id: String, artifact_id: String, frame_id: String) -> void:
    if site_id != "golden":
        _fail("viewer received a terrain site other than Golden")
        return
    var repository_root := SiteCatalog.repository_root()
    var road_result := Roads.load_bundle(repository_root)
    if not road_result.get("ok", false):
        _fail("road feature contract rejected: %s" % String(road_result.get("error", "")))
        return

    var decoder := Decoder.new()
    decoder.decode("golden", repository_root)
    var terrain_decoded: Dictionary = decoder.result
    if not terrain_decoded.get("ok", false):
        _fail("Golden terrain support could not be decoded: %s" % String(terrain_decoded.get("error", "")))
        return
    if String(terrain_decoded["artifact_id"]) != artifact_id or String(terrain_decoded["manifest"]["frame"]["frame_id"]) != frame_id:
        _fail("loaded terrain identity changed before road draping")
        return
    if _terrain_manager.get_child_count() != 1:
        _fail("expected one real Golden terrain tile in the scene")
        return
    var terrain_tile: Node3D = _terrain_manager.get_child(0)
    if terrain_tile.position != Vector3.ZERO or String(terrain_tile.get_meta("frame_id", "")) != frame_id:
        _fail("terrain tile is not placed at the Golden local origin/frame")
        return

    var drape := Roads.build_draped_mesh(road_result["collection"], terrain_decoded, DISPLAY_OFFSET_M)
    if not drape.get("ok", false):
        _fail("road centerline drape failed: %s" % String(drape.get("error", "")))
        return
    var roads_instance := MeshInstance3D.new()
    roads_instance.name = "CensusRoadCenterlines"
    roads_instance.mesh = drape["mesh"]
    roads_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    add_child(roads_instance)

    var collection: Dictionary = road_result["collection"]
    var route_labels: PackedStringArray = []
    for feature in collection["features"]:
        route_labels.append("%s (%s)" % [String(feature["properties"]["FULLNAME"]), String(feature["properties"]["MTFCC"])])
    route_labels.sort()
    _status_label.text = "DRAPED  /  %d source centerlines  /  %d points on the Golden support surface" % [
        collection["features"].size(),
        int(drape["draped_point_count"])
    ]
    _detail_label.text = "2026 Census All Roads / " + ", ".join(route_labels)
    _detail_label.text += "\nFrame %s / terrain artifact %s" % [frame_id, artifact_id.substr(0, 12)]
    _detail_label.text += "\n2D source has no Z or width / NAVD88 H-H0 is sampled from DEM support"
    _detail_label.text += "\n+%.2f m display offset is separate from sample height / %d crop-edge points outside sample centres" % [
        DISPLAY_OFFSET_M,
        int(drape["support_miss_count"])
    ]

    print("WF_ROADS_RUNTIME_SCENE=Golden")
    print("WF_ROADS_RUNTIME_FRAME_ID=%s" % frame_id)
    print("WF_ROADS_RUNTIME_TERRAIN_ARTIFACT_ID=%s" % artifact_id)
    print("WF_ROADS_RUNTIME_CENSUS_SOURCE_URL=%s" % String(collection["source"]["source_uri"]))
    print("WF_ROADS_RUNTIME_CENSUS_ARCHIVE_SHA256=%s" % String(collection["source"]["archive_sha256"]))
    print("WF_ROADS_RUNTIME_FEATURE_COUNT=%d" % collection["features"].size())
    print("WF_ROADS_RUNTIME_FEATURE_IDS=%s" % JSON.stringify(_feature_ids(collection["features"])))
    print("WF_ROADS_RUNTIME_DRAPED_POINT_COUNT=%d" % int(drape["draped_point_count"]))
    print("WF_ROADS_RUNTIME_DISPLAY_VERTEX_COUNT=%d" % int(drape["rendered_vertex_count"]))
    print("WF_ROADS_RUNTIME_TERRAIN_EDGE_MISS_COUNT=%d" % int(drape["support_miss_count"]))
    print("WF_ROADS_RUNTIME_INTERMEDIATE_SUPPORT_MISS_COUNT=%d" % int(drape["display_support_miss_count"]))
    print("WF_ROADS_RUNTIME_LINE_STRIP_COUNT=%d" % int(drape["line_strip_count"]))
    print("WF_ROADS_DISPLAY_OFFSET_M=%.2f" % DISPLAY_OFFSET_M)
    print("WF_ROADS_LOCAL_CAMERA_POSITION_M=%s" % JSON.stringify([_camera.position.x, _camera.position.y, _camera.position.z]))
    print("WF_ROADS_LOCAL_CAMERA_TARGET_M=%s" % JSON.stringify([0.0, 80.0, 0.0]))
    print("WF_ROADS_ALIGNMENT_SAMPLE_REPORTS=%s" % JSON.stringify(drape["sample_reports"]))
    if not _capture_output_path.is_empty():
        call_deferred("_capture_runtime_view", _capture_output_path)

func _on_load_failed(_request_id: int, site_id: String, message: String) -> void:
    _fail("terrain %s failed to load: %s" % [site_id, message])

func _fail(message: String) -> void:
    push_error("WorldForge road interoperability viewer: %s" % message)
    if is_instance_valid(_status_label):
        _status_label.text = "REJECTED  /  " + message
    if not _capture_output_path.is_empty():
        get_tree().quit(5)

func _capture_runtime_view(output_path: String) -> void:
    await get_tree().process_frame
    await get_tree().process_frame
    await RenderingServer.frame_post_draw
    var viewport_image := get_viewport().get_texture().get_image()
    if viewport_image == null or viewport_image.is_empty():
        _fail("runtime capture returned an empty viewport image")
        return
    var output_directory := output_path.get_base_dir()
    if not DirAccess.dir_exists_absolute(output_directory):
        var directory_error := DirAccess.make_dir_recursive_absolute(output_directory)
        if directory_error != OK:
            _fail("runtime capture could not create output directory (error %d)" % directory_error)
            return
    var save_error := viewport_image.save_png(output_path)
    if save_error != OK:
        _fail("runtime capture could not save PNG (error %d)" % save_error)
        return
    print("WF_RUNTIME_CAPTURE_PNG=%s" % output_path)
    get_tree().quit(0)

func _feature_ids(features: Array) -> Array[String]:
    var ids: Array[String] = []
    for feature in features:
        ids.append(String(feature["id"]))
    return ids

func _argument_value(flag: String) -> String:
    var arguments := OS.get_cmdline_user_args()
    for index in range(arguments.size() - 1):
        if arguments[index] == flag:
            return arguments[index + 1]
    return ""
