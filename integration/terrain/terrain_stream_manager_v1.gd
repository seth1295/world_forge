class_name TerrainStreamManagerV1
extends Node3D

signal load_started(request_id: int, site_id: String)
signal load_succeeded(request_id: int, site_id: String, artifact_id: String, frame_id: String)
signal window_set_loaded(request_id: int, site_id: String, window_ids: Array[String], frame_id: String)
signal load_failed(request_id: int, site_id: String, message: String)
signal unloaded(request_id: int)
signal stale_result_rejected(request_id: int, site_id: String, artifact_id: String, current_request_id: int)

const Decoder := preload("res://terrain/bundle_decoder_v1.gd")
const SiteCatalog := preload("res://terrain/site_catalog_v1.gd")
const TileFactory := preload("res://terrain/terrain_tile_factory_v1.gd")
const MAX_IN_FLIGHT_WORKERS := 1

var _request_sequence := 0
var _current_request_id := 0
var _current_site_id := ""
var _active_tiles: Array[Node3D] = []
var _loaded_window_ids: Array[String] = []
var _pending_tasks: Array[Dictionary] = []
var _queued_latest_request: Dictionary = {}

var loaded_site_id: String:
    get:
        return _current_site_id if not _active_tiles.is_empty() else ""

var loaded_window_ids: Array[String]:
    get:
        return _loaded_window_ids.duplicate()

func _ready() -> void:
    set_process(true)

## Load a site's default approved window through the same atomic request path as a window set.
func request_site(site_id: String) -> int:
    var site := SiteCatalog.get_site(site_id)
    if site.is_empty():
        return request_window_set(site_id, [])
    var window_ids: Array[String] = [String(site["window_id"])]
    return request_window_set(site_id, window_ids)

## Load one window or a seam-validated adjacent set atomically. Demand stays capped at one
## worker task plus one replaceable latest request regardless of the number of windows.
func request_window_set(site_id: String, window_ids: Array[String]) -> int:
    _request_sequence += 1
    _current_request_id = _request_sequence
    _current_site_id = site_id
    _remove_loaded_tiles()
    var site := SiteCatalog.get_site(site_id)
    if site.is_empty():
        _current_site_id = ""
        _queued_latest_request.clear()
        load_failed.emit(_current_request_id, site_id, "unknown or unapproved terrain site")
        return _current_request_id
    if window_ids.is_empty() or window_ids.size() > 2:
        _current_site_id = ""
        _queued_latest_request.clear()
        load_failed.emit(_current_request_id, site_id, "terrain request must name one or two approved windows")
        return _current_request_id

    var window_records: Dictionary = {}
    var requested_window_ids: Array[String] = []
    var expected_artifact_ids: Array[String] = []
    var requested_source: Dictionary = {}
    for window_id in window_ids:
        if window_records.has(window_id):
            _current_site_id = ""
            _queued_latest_request.clear()
            load_failed.emit(_current_request_id, site_id, "terrain request contains a duplicate window ID")
            return _current_request_id
        var window_record := SiteCatalog.get_window(site_id, window_id)
        if window_record.is_empty():
            _current_site_id = ""
            _queued_latest_request.clear()
            load_failed.emit(_current_request_id, site_id, "unknown or unapproved window %s" % window_id)
            return _current_request_id
        if String(window_record["frame_id"]) != String(site["frame_id"]):
            _current_site_id = ""
            _queued_latest_request.clear()
            load_failed.emit(_current_request_id, site_id, "requested window does not use the approved site frame")
            return _current_request_id
        if requested_window_ids.is_empty():
            requested_source = window_record["source"]
        elif window_record["source"] != requested_source:
            _current_site_id = ""
            _queued_latest_request.clear()
            load_failed.emit(_current_request_id, site_id, "requested windows do not share the same approved source identity")
            return _current_request_id
        window_records[window_id] = window_record
        requested_window_ids.append(window_id)
        expected_artifact_ids.append(String(window_record["artifact_id"]))

    requested_window_ids.sort_custom(func(left_id: String, right_id: String) -> bool:
        var left_record: Dictionary = window_records[left_id]
        var right_record: Dictionary = window_records[right_id]
        return int(left_record["source_window"]["column_offset"]) < int(right_record["source_window"]["column_offset"])
    )
    var artifacts_by_window: Dictionary = {}
    for index in range(requested_window_ids.size()):
        artifacts_by_window[requested_window_ids[index]] = expected_artifact_ids[window_ids.find(requested_window_ids[index])]
    var ordered_artifact_ids: Array[String] = []
    for window_id in requested_window_ids:
        ordered_artifact_ids.append(String(artifacts_by_window[window_id]))

    var request := {
        "request_id": _current_request_id,
        "site_id": site_id,
        "window_ids": requested_window_ids,
        "expected_artifact_ids": ordered_artifact_ids,
        "expected_frame_id": String(site["frame_id"])
    }
    if _pending_tasks.size() >= MAX_IN_FLIGHT_WORKERS:
        _queued_latest_request = request
        load_started.emit(_current_request_id, site_id)
        return _current_request_id
    _launch_request(request)
    return _current_request_id

## Invalidate worker and queued requests, then release every active render/collision node.
func unload() -> int:
    _request_sequence += 1
    _current_request_id = _request_sequence
    _current_site_id = ""
    _queued_latest_request.clear()
    _remove_loaded_tiles()
    unloaded.emit(_current_request_id)
    return _current_request_id

func get_pending_task_count() -> int:
    return _pending_tasks.size() + (1 if not _queued_latest_request.is_empty() else 0)

func get_active_worker_count() -> int:
    return _pending_tasks.size()

func get_queued_request_count() -> int:
    return 0 if _queued_latest_request.is_empty() else 1

func get_loaded_tile_count() -> int:
    return _active_tiles.size()

func get_loaded_tile(window_id: String) -> Node3D:
    for tile in _active_tiles:
        if is_instance_valid(tile) and String(tile.get_meta("window_id", "")) == window_id:
            return tile
    return null

func _launch_request(request: Dictionary) -> void:
    if _pending_tasks.size() >= MAX_IN_FLIGHT_WORKERS:
        _queued_latest_request = request
        return
    var decoder := Decoder.new()
    var repository_root := SiteCatalog.repository_root()
    var request_id := int(request["request_id"])
    var site_id := String(request["site_id"])
    var window_ids: Array[String] = request["window_ids"]
    var task_id := WorkerThreadPool.add_task(
        Callable(decoder, "decode_window_set").bind(site_id, repository_root, window_ids),
        false,
        "WorldForge terrain windows %s request %d" % [site_id, request_id]
    )
    if task_id < 0:
        if request_id == _current_request_id:
            _current_site_id = ""
        load_failed.emit(request_id, site_id, "Godot could not schedule terrain load")
        return
    _pending_tasks.append({
        "task_id": task_id,
        "decoder": decoder,
        "request_id": request_id,
        "site_id": site_id,
        "window_ids": window_ids,
        "expected_artifact_ids": request["expected_artifact_ids"],
        "expected_frame_id": String(request["expected_frame_id"])
    })
    load_started.emit(request_id, site_id)

func _process(_delta: float) -> void:
    for index in range(_pending_tasks.size() - 1, -1, -1):
        var task: Dictionary = _pending_tasks[index]
        var task_id := int(task["task_id"])
        if not WorkerThreadPool.is_task_completed(task_id):
            continue
        var wait_error := WorkerThreadPool.wait_for_task_completion(task_id)
        _pending_tasks.remove_at(index)
        _complete_task(task, wait_error)
    if _pending_tasks.is_empty() and not _queued_latest_request.is_empty():
        var next_request := _queued_latest_request
        _queued_latest_request = {}
        if int(next_request["request_id"]) == _current_request_id:
            _launch_request(next_request)
        else:
            var stale_ids: Array[String] = next_request.get("window_ids", [])
            var stale_id := stale_ids[0] if not stale_ids.is_empty() else ""
            var stale_artifacts: Array[String] = next_request.get("expected_artifact_ids", [])
            var stale_artifact := stale_artifacts[0] if not stale_artifacts.is_empty() else ""
            stale_result_rejected.emit(int(next_request["request_id"]), String(next_request["site_id"]), stale_artifact, _current_request_id)

func _complete_task(task: Dictionary, wait_error: int) -> void:
    var decoder = task["decoder"]
    var decoded_set: Dictionary = decoder.result
    var request_id := int(task["request_id"])
    var site_id := String(task["site_id"])
    var expected_ids: Array[String] = task["window_ids"]
    var expected_artifacts: Array[String] = task["expected_artifact_ids"]
    var decoded_windows: Array[Dictionary] = []
    var decoded_windows_value: Variant = decoded_set.get("windows", [])
    if typeof(decoded_windows_value) == TYPE_ARRAY:
        for decoded_window_value in decoded_windows_value:
            if typeof(decoded_window_value) == TYPE_DICTIONARY:
                decoded_windows.append(decoded_window_value)
    var stale_artifact := String(expected_artifacts[0]) if not expected_artifacts.is_empty() else ""
    if not decoded_windows.is_empty():
        stale_artifact = String(decoded_windows[0].get("artifact_id", stale_artifact))
    if request_id != _current_request_id:
        stale_result_rejected.emit(request_id, site_id, stale_artifact, _current_request_id)
        return
    if wait_error != OK:
        _current_site_id = ""
        load_failed.emit(request_id, site_id, "terrain worker failed while completing (error %d)" % wait_error)
        return
    if not decoded_set.get("ok", false):
        _current_site_id = ""
        load_failed.emit(request_id, site_id, String(decoded_set.get("error", "terrain validation failed")))
        return
    if decoded_windows.size() != expected_ids.size() or String(decoded_set.get("frame_id", "")) != String(task["expected_frame_id"]):
        _current_site_id = ""
        load_failed.emit(request_id, site_id, "terrain window-set completion identity differs from the request")
        return
    for index in range(decoded_windows.size()):
        var decoded_window: Dictionary = decoded_windows[index]
        var expected_id := String(expected_ids[index])
        if String(decoded_window["site"]["window_id"]) != expected_id or String(decoded_window["artifact_id"]) != String(expected_artifacts[index]) or String(decoded_window["manifest"]["frame"]["frame_id"]) != String(task["expected_frame_id"]):
            _current_site_id = ""
            load_failed.emit(request_id, site_id, "terrain window or artifact differs from the requested set")
            return

    var created_tiles: Array[Node3D] = []
    var lod_policy := "single_window_full_resolution" if decoded_windows.size() == 1 else String(decoded_set.get("lod_policy", "neighbor_locked_full_resolution"))
    for decoded_window in decoded_windows:
        var tile := TileFactory.create_tile(decoded_window, lod_policy)
        if tile == null:
            for created in created_tiles:
                created.queue_free()
            _current_site_id = ""
            load_failed.emit(request_id, site_id, "terrain mesh or collision resource could not be created")
            return
        created_tiles.append(tile)
    for tile in created_tiles:
        add_child(tile)
    _active_tiles = created_tiles
    _loaded_window_ids = expected_ids.duplicate()
    if decoded_windows.size() == 1:
        load_succeeded.emit(request_id, site_id, String(decoded_windows[0]["artifact_id"]), String(task["expected_frame_id"]))
    else:
        window_set_loaded.emit(request_id, site_id, _loaded_window_ids.duplicate(), String(task["expected_frame_id"]))

func _remove_loaded_tiles() -> void:
    for tile in _active_tiles:
        if not is_instance_valid(tile):
            continue
        if tile.get_parent() == self:
            remove_child(tile)
        tile.queue_free()
    _active_tiles.clear()
    _loaded_window_ids.clear()

func _exit_tree() -> void:
    # Invalidation prevents late completion from installing a partial window set during teardown.
    _request_sequence += 1
    _current_request_id = _request_sequence
    _queued_latest_request.clear()
    # WorkerThreadPool requires each accepted task ID to be awaited exactly once.
    for task in _pending_tasks:
        WorkerThreadPool.wait_for_task_completion(int(task["task_id"]))
    _pending_tasks.clear()
    _active_tiles.clear()
    _loaded_window_ids.clear()
