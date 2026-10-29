extends Node3D

const SiteCatalog := preload("res://terrain/site_catalog_v1.gd")
const TestRunner := preload("res://tests/terrain_test_runner.gd")

@onready var _stream_manager: TerrainStreamManagerV1 = $TerrainStreamManager

var _camera: Camera3D
var _site_selector: OptionButton
var _status_label: Label
var _detail_label: Label
var _unload_button: Button
var _capture_output_path := ""

func _ready() -> void:
    var test_suite := _argument_value("--test")
    if not test_suite.is_empty():
        call_deferred("_run_test_suite", test_suite)
        return
    _create_view_environment()
    _build_technical_ui()
    _stream_manager.load_started.connect(_on_load_started)
    _stream_manager.load_succeeded.connect(_on_load_succeeded)
    _stream_manager.load_failed.connect(_on_load_failed)
    _stream_manager.unloaded.connect(_on_unloaded)
    _capture_output_path = _argument_value("--capture")
    var requested_site := _argument_value("--site")
    if not SiteCatalog.SITES.has(requested_site):
        requested_site = "baltimore"
    _select_site(requested_site, true)

func _run_test_suite(suite_name: String) -> void:
    var runner: Node = TestRunner.new()
    add_child(runner)
    var exit_code: int = await runner.run_suite(suite_name)
    get_tree().quit(exit_code)

func _create_view_environment() -> void:
    var world_environment := WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.76, 0.82, 0.86, 1.0)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.74, 0.78, 0.82, 1.0)
    environment.ambient_light_energy = 0.68
    environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    environment.adjustment_enabled = true
    environment.adjustment_brightness = 1.04
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
    _camera.name = "DiagnosticCamera"
    _camera.current = true
    _camera.fov = 58.0
    _camera.near = 0.5
    _camera.far = 8000.0
    add_child(_camera)

func _build_technical_ui() -> void:
    var canvas := CanvasLayer.new()
    canvas.name = "TechnicalOverlay"
    add_child(canvas)

    var outer_margin := MarginContainer.new()
    outer_margin.name = "TechnicalPanelMargin"
    outer_margin.mouse_filter = Control.MOUSE_FILTER_PASS
    outer_margin.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
    outer_margin.position = Vector2(22.0, 22.0)
    outer_margin.custom_minimum_size = Vector2(400.0, 240.0)
    canvas.add_child(outer_margin)

    var panel := PanelContainer.new()
    panel.custom_minimum_size = Vector2(400.0, 0.0)
    var panel_style := StyleBoxFlat.new()
    panel_style.bg_color = Color(0.055, 0.085, 0.105, 0.94)
    panel_style.border_color = Color(0.31, 0.54, 0.56, 0.92)
    panel_style.set_border_width_all(1)
    panel_style.set_corner_radius_all(8)
    panel_style.content_margin_left = 15.0
    panel_style.content_margin_right = 15.0
    panel_style.content_margin_top = 13.0
    panel_style.content_margin_bottom = 13.0
    panel.add_theme_stylebox_override("panel", panel_style)
    outer_margin.add_child(panel)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 8)
    panel.add_child(column)

    var eyebrow := Label.new()
    eyebrow.text = "WORLDFORGE  /  TERRAIN GRID V1"
    eyebrow.add_theme_color_override("font_color", Color(0.49, 0.82, 0.76, 1.0))
    eyebrow.add_theme_font_size_override("font_size", 12)
    column.add_child(eyebrow)

    var title := Label.new()
    title.text = "Geographic consumer"
    title.add_theme_color_override("font_color", Color(0.92, 0.96, 0.96, 1.0))
    title.add_theme_font_size_override("font_size", 20)
    column.add_child(title)

    var selector_row := HBoxContainer.new()
    selector_row.add_theme_constant_override("separation", 8)
    column.add_child(selector_row)
    _site_selector = OptionButton.new()
    _site_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    for index in range(SiteCatalog.site_ids().size()):
        var site_id := SiteCatalog.site_ids()[index]
        var site := SiteCatalog.get_site(site_id)
        _site_selector.add_item(String(site["display_name"]), index)
        _site_selector.set_item_metadata(index, site_id)
    _site_selector.item_selected.connect(_on_site_option_selected)
    selector_row.add_child(_site_selector)

    _unload_button = Button.new()
    _unload_button.text = "Unload"
    _unload_button.custom_minimum_size = Vector2(78.0, 34.0)
    _unload_button.pressed.connect(_on_unload_pressed)
    selector_row.add_child(_unload_button)

    _status_label = Label.new()
    _status_label.text = "IDLE  /  no terrain loaded"
    _status_label.add_theme_color_override("font_color", Color(0.83, 0.88, 0.9, 1.0))
    _status_label.add_theme_font_size_override("font_size", 13)
    _status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(_status_label)

    _detail_label = Label.new()
    _detail_label.text = "Select an approved USGS 3DEP terrain site."
    _detail_label.add_theme_color_override("font_color", Color(0.66, 0.75, 0.79, 1.0))
    _detail_label.add_theme_font_size_override("font_size", 12)
    _detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(_detail_label)

    var boundary_label := Label.new()
    boundary_label.text = "NAD83 / GRS80 regional frame  ·  NAVD88 orthometric ΔH  ·  no global datum bridge"
    boundary_label.add_theme_color_override("font_color", Color(0.49, 0.67, 0.71, 1.0))
    boundary_label.add_theme_font_size_override("font_size", 11)
    boundary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(boundary_label)

func _select_site(site_id: String, start_load: bool) -> void:
    var site := SiteCatalog.get_site(site_id)
    if site.is_empty():
        _status_label.text = "ERROR  /  site is not approved"
        return
    for index in range(_site_selector.item_count):
        if String(_site_selector.get_item_metadata(index)) == site_id:
            _site_selector.select(index)
            break
    var camera_position: Vector3 = site["camera_position_local_m"]
    var camera_target: Vector3 = site["camera_target_local_m"]
    _camera.position = camera_position
    _camera.look_at(camera_target, Vector3.UP)
    _detail_label.text = "%s\n%.8f° N  %.8f° W\nFrame %s" % [
        String(site["display_name"]),
        float(site["anchor_latitude_deg"]),
        absf(float(site["anchor_longitude_deg"])),
        String(site["frame_id"])
    ]
    if start_load:
        _stream_manager.request_site(site_id)

func _on_site_option_selected(index: int) -> void:
    var site_id := String(_site_selector.get_item_metadata(index))
    _select_site(site_id, true)

func _on_unload_pressed() -> void:
    _stream_manager.unload()

func _on_load_started(_request_id: int, site_id: String) -> void:
    var site := SiteCatalog.get_site(site_id)
    _status_label.text = "LOADING  /  validating %s, then preparing terrain and collision" % String(site["display_name"])
    _unload_button.disabled = false

func _on_load_succeeded(_request_id: int, site_id: String, artifact_id: String, frame_id: String) -> void:
    var site := SiteCatalog.get_site(site_id)
    _status_label.text = "LOADED  /  %d × %d samples  /  source-derived elevations" % [int(site["rows"]), int(site["columns"])]
    _detail_label.text = "%s\n%.8f° N  %.8f° W\n%s · artifact %s" % [
        String(site["display_name"]),
        float(site["anchor_latitude_deg"]),
        absf(float(site["anchor_longitude_deg"])),
        frame_id,
        artifact_id.substr(0, 12)
    ]
    if not _capture_output_path.is_empty():
        call_deferred("_capture_runtime_view", _capture_output_path)


func _on_load_failed(_request_id: int, site_id: String, message: String) -> void:
    _status_label.text = "REJECTED  /  %s" % site_id
    _detail_label.text = message

func _on_unloaded(_request_id: int) -> void:
    _status_label.text = "UNLOADED  /  terrain and collision released"

func _capture_runtime_view(output_path: String) -> void:
    # Diagnostic capture mode only. Wait for the terrain/UI to render before reading the viewport.
    await get_tree().process_frame
    await get_tree().process_frame
    await RenderingServer.frame_post_draw
    var viewport_image := get_viewport().get_texture().get_image()
    if viewport_image == null or viewport_image.is_empty():
        push_error("WorldForge runtime capture failed: main viewport image is empty")
        get_tree().quit(2)
        return
    var output_directory := output_path.get_base_dir()
    if not DirAccess.dir_exists_absolute(output_directory):
        var directory_error := DirAccess.make_dir_recursive_absolute(output_directory)
        if directory_error != OK:
            push_error("WorldForge runtime capture failed to create its temp directory: %d" % directory_error)
            get_tree().quit(3)
            return
    var save_error := viewport_image.save_png(output_path)
    if save_error != OK:
        push_error("WorldForge runtime capture failed to save PNG (error %d)" % save_error)
        get_tree().quit(4)
        return
    print("WF_RUNTIME_CAPTURE_PNG=%s" % output_path)
    get_tree().quit(0)
func _argument_value(flag: String) -> String:
    var arguments := OS.get_cmdline_user_args()
    for index in range(arguments.size() - 1):
        if arguments[index] == flag:
            return arguments[index + 1]
    return ""