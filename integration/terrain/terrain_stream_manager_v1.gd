class_name TerrainStreamManagerV1
extends Node3D

signal load_started(request_id: int, site_id: String)
signal load_succeeded(request_id: int, site_id: String, artifact_id: String, frame_id: String)
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
var _loaded_tile: Node3D
var _pending_tasks: Array[Dictionary] = []
var _queued_latest_request: Dictionary = {}

var loaded_site_id: String:
    get:
        return _current_site_id if is_instance_valid(_loaded_tile) else ""

func _ready() -> void:
    set_process(true)

## Start an asynchronous load. At most one worker runs; one replaceable latest request is queued.
func request_site(site_id: String) -> int:
    _request_sequence += 1
    _current_request_id = _request_sequence
    _current_site_id = site_id
    _remove_loaded_tile()
    var site := SiteCatalog.get_site(site_id)
    if site.is_empty():
        _current_site_id = ""
        _queued_latest_request.clear()
        load_failed.emit(_current_request_id, site_id, "unknown or unapproved terrain site")
        return _current_request_id

    var request := {
        "request_id": _current_request_id,
        "site_id": site_id,
        "expected_artifact_id": String(site["artifact_id"]),
        "expected_frame_id": String(site["frame_id"])
    }
    if _pending_tasks.size() >= MAX_IN_FLIGHT_WORKERS:
        _queued_latest_request = request
        load_started.emit(_current_request_id, site_id)
        return _current_request_id
    _launch_request(request)
    return _current_request_id

## Invalidate worker and queued requests, then release the current render/collision nodes.
func unload() -> int:
    _request_sequence += 1
    _current_request_id = _request_sequence
    _current_site_id = ""
    _queued_latest_request.clear()
    _remove_loaded_tile()
    unloaded.emit(_current_request_id)
    return _current_request_id

func get_pending_task_count() -> int:
    return _pending_tasks.size() + (1 if not _queued_latest_request.is_empty() else 0)

func get_active_worker_count() -> int:
    return _pending_tasks.size()

func get_queued_request_count() -> int:
    return 0 if _queued_latest_request.is_empty() else 1

func get_loaded_tile_count() -> int:
    return get_child_count()

func _launch_request(request: Dictionary) -> void:
    if _pending_tasks.size() >= MAX_IN_FLIGHT_WORKERS:
        _queued_latest_request = request
        return
    var decoder := Decoder.new()
    var repository_root := SiteCatalog.repository_root()
    var request_id := int(request["request_id"])
    var site_id := String(request["site_id"])
    var task_id := WorkerThreadPool.add_task(
        Callable(decoder, "decode").bind(site_id, repository_root),
        false,
        "WorldForge terrain load %s request %d" % [site_id, request_id]
    )
    if task_id < 0:
        if request_id == _current_request_id:
            _current_site_id = ""
        load_failed.emit(request_id, site_id, "Godot could not schedule terrain validation")
        return
    _pending_tasks.append({
        "task_id": task_id,
        "decoder": decoder,
        "request_id": request_id,
        "site_id": site_id,
        "expected_artifact_id": String(request["expected_artifact_id"]),
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
            stale_result_rejected.emit(int(next_request["request_id"]), String(next_request["site_id"]), String(next_request["expected_artifact_id"]), _current_request_id)

func _complete_task(task: Dictionary, wait_error: int) -> void:
    var decoder = task["decoder"]
    var decoded: Dictionary = decoder.result
    var request_id := int(task["request_id"])
    var site_id := String(task["site_id"])
    var artifact_id := String(decoded.get("artifact_id", ""))
    if request_id != _current_request_id:
        stale_result_rejected.emit(request_id, site_id, artifact_id, _current_request_id)
        return
    if wait_error != OK:
        _current_site_id = ""
        load_failed.emit(request_id, site_id, "terrain worker failed while completing (error %d)" % wait_error)
        return
    if not decoded.get("ok", false):
        _current_site_id = ""
        load_failed.emit(request_id, site_id, String(decoded.get("error", "terrain validation failed")))
        return
    if artifact_id != String(task["expected_artifact_id"]) or String(decoded["manifest"]["frame"]["frame_id"]) != String(task["expected_frame_id"]):
        _current_site_id = ""
        load_failed.emit(request_id, site_id, "terrain completion identity differs from the requested site")
        return

    var tile := TileFactory.create_tile(decoded)
    if tile == null:
        _current_site_id = ""
        load_failed.emit(request_id, site_id, "terrain mesh or collision resource could not be created")
        return
    add_child(tile)
    _loaded_tile = tile
    load_succeeded.emit(request_id, site_id, artifact_id, String(task["expected_frame_id"]))

func _remove_loaded_tile() -> void:
    if not is_instance_valid(_loaded_tile):
        _loaded_tile = null
        return
    if _loaded_tile.get_parent() == self:
        remove_child(_loaded_tile)
    _loaded_tile.queue_free()
    _loaded_tile = null

func _exit_tree() -> void:
    # Invalidation prevents a late completion from being installed during scene teardown.
    _request_sequence += 1
    _current_request_id = _request_sequence
    _queued_latest_request.clear()
    # WorkerThreadPool requires each accepted task ID to be awaited exactly once.
    for task in _pending_tasks:
        WorkerThreadPool.wait_for_task_completion(int(task["task_id"]))
    _pending_tasks.clear()