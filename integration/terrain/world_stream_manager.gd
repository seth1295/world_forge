class_name WorldStreamManager
extends Node3D

## General WFG-1 streamed world consumer.
##
## The provider validates the versioned external tile bundle on a worker and
## returns the normalized envelope documented by WorldTileProvider. The manager
## validates request identity and layer status, then calls the builder on the
## main thread. Only a fully validated/built Node3D is installed. A replacement
## never changes a tile's geographic address; source revision and LOD are
## independent request metadata.
signal tile_request_started(request_id: int, tile_id: String, source_id: String, lod: int)
signal tile_installed(request_id: int, tile_id: String, source_id: String, lod: int, tile_state: String, layer_outcomes: Dictionary)
signal tile_request_failed(request_id: int, tile_id: String, message: String)
signal tile_request_cancelled(request_id: int, tile_id: String, reason: String)
signal tile_unloaded(request_id: int, tile_id: String, reason: String)
signal stale_result_rejected(request_id: int, tile_id: String, current_request_id: int)
signal coverage_gap_reported(tile_id: String, layer_id: String, outcome: Dictionary)
signal render_origin_changed(latitude_deg: float, longitude_deg: float, ellipsoidal_height_m: float)

const Address := preload("res://terrain/wfg1_tile_address.gd")
const LocalFrame := preload("res://terrain/wfg1_local_frame.gd")
const CancellationToken := preload("res://terrain/world_tile_cancellation_token.gd")
const LoadTask := preload("res://terrain/world_tile_load_task.gd")
const MAX_IN_FLIGHT_WORKERS := 4
const MAX_QUEUED_REQUESTS := 4096
const MAX_TERMINAL_REQUEST_HISTORY := 256
const VALID_LAYER_STATUSES := ["ready", "partial", "no_source_coverage", "not_generated", "failed", "cancelled"]

var _provider: WorldTileProvider
var _tile_builder: Callable
var _default_source_id := ""
var _default_source_generation := ""
var _expected_schema_id := ""
var _expected_schema_version := ""
var _request_sequence := 0
var _render_origin: Dictionary = {}
var _current_request_by_tile: Dictionary = {}
var _state_by_request_id: Dictionary = {}
var _terminal_request_history: Array[int] = []
var _queued_requests: Array[Dictionary] = []
var _pending_tasks: Array[Dictionary] = []
var _installed_by_tile: Dictionary = {}

func _ready() -> void:
	var default_origin := LocalFrame.create_origin(0.0, 0.0, 0.0)
	if default_origin.get("ok", false):
		_render_origin = default_origin
	set_process(true)

## Configure the component adapter and a main-thread tile builder. Provider
## implementations are RefCounted, worker-safe objects and never Nodes.
func configure_provider(
		provider: WorldTileProvider,
		builder: Callable,
		default_source_id: String,
		default_source_generation: String,
		expected_schema_id: String,
		expected_schema_version: String
	) -> Dictionary:
	if provider == null or not provider.has_method("load_tile"):
		return _failure("provider must be a worker-safe WorldTileProvider")
	if not builder.is_valid():
		return _failure("a main-thread tile builder is required")
	if default_source_id.strip_edges().is_empty() or default_source_generation.strip_edges().is_empty():
		return _failure("default source ID and generation must be explicit")
	if expected_schema_id.strip_edges().is_empty() or expected_schema_version.strip_edges().is_empty():
		return _failure("expected world-tile schema ID and version must be explicit")
	_provider = provider
	_tile_builder = builder
	_default_source_id = default_source_id
	_default_source_generation = default_source_generation
	_expected_schema_id = expected_schema_id
	_expected_schema_version = expected_schema_version
	return {"ok": true, "error": ""}

## Move the renderer origin. Global ECEF stays in PackedFloat64Array form; each
## installed tile transform is recomputed after ECEF-origin subtraction.
func set_render_origin(latitude_deg: float, longitude_deg: float, ellipsoidal_height_m: float = 0.0) -> Dictionary:
	var next_origin := LocalFrame.create_origin(latitude_deg, longitude_deg, ellipsoidal_height_m)
	if not next_origin.get("ok", false):
		return next_origin
	_render_origin = next_origin
	var tile_ids: Array = _installed_by_tile.keys()
	tile_ids.sort()
	for tile_id_value in tile_ids:
		var tile_id := String(tile_id_value)
		if not _rebase_installed_tile(tile_id):
			_release_installed_tile(tile_id, "outside the current local-render origin range")
	render_origin_changed.emit(latitude_deg, -180.0 if longitude_deg == 180.0 else longitude_deg, ellipsoidal_height_m)
	return {"ok": true, "error": "", "origin": _render_origin.duplicate(true)}

## Queue an asynchronous global tile request. `lod` and source revision are
## request variants; neither changes the WFG-1 address identity. A `partial`
## outcome is installable only when `allow_partial` is explicit for this call.
func request_tile(
		address: Dictionary,
		lod: int,
		required_layers: Array[String],
		source_id: String = "",
		source_generation: String = "",
		allow_partial: bool = false
	) -> int:
	_request_sequence += 1
	var request_id := _request_sequence
	var address_result := Address.validate_address(address)
	if not address_result.get("ok", false):
		tile_request_failed.emit(request_id, "", String(address_result.get("error", "invalid WFG-1 address")))
		return request_id
	if lod < 0 or lod > Address.MAX_LEVEL:
		tile_request_failed.emit(request_id, Address.format_id(address_result["address"]), "LOD must be an integer in [0, 16]")
		return request_id
	if required_layers.is_empty():
		tile_request_failed.emit(request_id, Address.format_id(address_result["address"]), "at least one layer must be requested")
		return request_id
	if _provider == null or not _tile_builder.is_valid():
		tile_request_failed.emit(request_id, Address.format_id(address_result["address"]), "world provider and tile builder are not configured")
		return request_id
	var resolved_source := source_id.strip_edges()
	if resolved_source.is_empty():
		resolved_source = _default_source_id
	var resolved_generation := source_generation.strip_edges()
	if resolved_generation.is_empty():
		resolved_generation = _default_source_generation
	if resolved_source.is_empty() or resolved_generation.is_empty():
		tile_request_failed.emit(request_id, Address.format_id(address_result["address"]), "source ID and source generation must be explicit")
		return request_id
	var layers := PackedStringArray()
	var seen_layers: Dictionary = {}
	for layer in required_layers:
		var layer_name := layer.strip_edges()
		if layer_name.is_empty() or seen_layers.has(layer_name):
			tile_request_failed.emit(request_id, Address.format_id(address_result["address"]), "required layers must be nonempty and unique")
			return request_id
		seen_layers[layer_name] = true
		layers.append(layer_name)
	var checked_address: Dictionary = address_result["address"]
	var tile_id := Address.format_id(checked_address)
	var queued_for_tile := _count_queued_requests_for_tile(tile_id)
	if _pending_tasks.size() >= MAX_IN_FLIGHT_WORKERS and _queued_requests.size() - queued_for_tile >= MAX_QUEUED_REQUESTS:
		tile_request_failed.emit(request_id, tile_id, "world tile request queue is full")
		return request_id

	_cancel_pending_for_tile(tile_id, "superseded by a newer address/source/LOD request")
	var request := {
		"request_id": request_id,
		# Unique across the manager lifetime. This replaces a per-address
		# generation dictionary, so unloaded addresses leave no tombstones.
		"generation": request_id,
		"address": checked_address,
		"address_id": tile_id,
		"lod": lod,
		"required_layers": layers,
		"allow_partial": allow_partial,
		"source_id": resolved_source,
		"source_generation": resolved_generation
	}
	_current_request_by_tile[tile_id] = request_id
	_set_request_state(request_id, {"status": "queued", "request": request.duplicate(true)})
	if _pending_tasks.size() < MAX_IN_FLIGHT_WORKERS:
		_launch_request(request)
	else:
		_queued_requests.append(request)
	_launch_queued_requests()
	return request_id

## Invalidate in-flight/queued work but preserve any already installed tile.
func cancel_tile(address: Dictionary, reason: String = "cancelled by caller") -> int:
	var address_result := Address.validate_address(address)
	if not address_result.get("ok", false):
		return 0
	var tile_id := Address.format_id(address_result["address"])
	var request_id := int(_current_request_by_tile.get(tile_id, 0))
	_cancel_pending_for_tile(tile_id, reason)
	_restore_current_request_from_installed_tile(tile_id)
	return request_id

## Cancel pending work and release all render/collision resources for one tile.
func unload_tile(address: Dictionary, reason: String = "unloaded by caller") -> int:
	var address_result := Address.validate_address(address)
	if not address_result.get("ok", false):
		return 0
	var tile_id := Address.format_id(address_result["address"])
	var request_id := cancel_tile(address_result["address"], reason)
	_release_installed_tile(tile_id, reason, request_id)
	return request_id

func unload_all(reason: String = "all tiles unloaded") -> void:
	var tile_ids: Dictionary = {}
	for tile_id in _installed_by_tile.keys():
		tile_ids[tile_id] = true
	for tile_id in _current_request_by_tile.keys():
		tile_ids[tile_id] = true
	var ids: Array = tile_ids.keys()
	ids.sort()
	for tile_id_value in ids:
		var parsed := Address.parse_id(String(tile_id_value))
		if parsed.get("ok", false):
			unload_tile(parsed["address"], reason)

func get_pending_task_count() -> int:
	return _pending_tasks.size() + _queued_requests.size()

func get_active_worker_count() -> int:
	return _pending_tasks.size()

func get_queued_request_count() -> int:
	return _queued_requests.size()

func get_loaded_tile_count() -> int:
	return _installed_by_tile.size()

func get_request_history_count() -> int:
	return _state_by_request_id.size()

func get_tracked_tile_count() -> int:
	return _current_request_by_tile.size()

func get_request_state(request_id: int) -> Dictionary:
	return _state_by_request_id.get(request_id, {"status": "expired", "request_id": request_id}).duplicate(true)

func is_tile_loaded(address: Dictionary) -> bool:
	var checked := Address.validate_address(address)
	return checked.get("ok", false) and _installed_by_tile.has(Address.format_id(checked["address"]))

func get_loaded_tile(address: Dictionary) -> Node3D:
	var checked := Address.validate_address(address)
	if not checked.get("ok", false):
		return null
	var tile_id := Address.format_id(checked["address"])
	if not _installed_by_tile.has(tile_id):
		return null
	return _installed_by_tile[tile_id]["node"]

func get_tile_state(address: Dictionary) -> Dictionary:
	var checked := Address.validate_address(address)
	if not checked.get("ok", false):
		return {"status": "invalid", "error": String(checked.get("error", "invalid address"))}
	var tile_id := Address.format_id(checked["address"])
	var state: Dictionary = _installed_by_tile.get(tile_id, {}).duplicate(true)
	if not state.is_empty():
		state.erase("node")
		return state
	var request_id := int(_current_request_by_tile.get(tile_id, 0))
	return _state_by_request_id.get(request_id, {"status": "unloaded", "tile_id": tile_id}).duplicate(true)

func _process(_delta: float) -> void:
	for index in range(_pending_tasks.size() - 1, -1, -1):
		var pending: Dictionary = _pending_tasks[index]
		var task_id := int(pending["task_id"])
		if not WorkerThreadPool.is_task_completed(task_id):
			continue
		var wait_error := WorkerThreadPool.wait_for_task_completion(task_id)
		_pending_tasks.remove_at(index)
		_complete_task(pending, wait_error)
	_launch_queued_requests()

func _launch_request(request: Dictionary) -> void:
	if _pending_tasks.size() >= MAX_IN_FLIGHT_WORKERS:
		_queued_requests.append(request)
		return
	var token := CancellationToken.new()
	var worker := LoadTask.new()
	var task_id := WorkerThreadPool.add_task(
		Callable(worker, "run").bind(_provider, request.duplicate(true), token),
		false,
		"WorldForge WFG-1 tile %s request %d" % [String(request["address_id"]), int(request["request_id"])]
	)
	if task_id < 0:
		_set_request_state(int(request["request_id"]), {"status": "failed", "request": request, "error": "Godot could not schedule the world-tile validation task"})
		_restore_current_request_from_installed_tile(String(request["address_id"]))
		tile_request_failed.emit(int(request["request_id"]), String(request["address_id"]), "Godot could not schedule the world-tile validation task")
		return
	_pending_tasks.append({
		"task_id": task_id,
		"worker": worker,
		"token": token,
		"cancel_notified": false,
		"request": request.duplicate(true)
	})
	_set_request_state(int(request["request_id"]), {"status": "loading", "request": request.duplicate(true)})
	tile_request_started.emit(int(request["request_id"]), String(request["address_id"]), String(request["source_id"]), int(request["lod"]))

func _launch_queued_requests() -> void:
	while _pending_tasks.size() < MAX_IN_FLIGHT_WORKERS and not _queued_requests.is_empty():
		var request: Dictionary = _queued_requests.pop_front()
		var tile_id := String(request["address_id"])
		if int(_current_request_by_tile.get(tile_id, 0)) != int(request["request_id"]):
			_set_request_state(int(request["request_id"]), {"status": "superseded", "request": request})
			stale_result_rejected.emit(int(request["request_id"]), tile_id, int(_current_request_by_tile.get(tile_id, 0)))
			continue
		_launch_request(request)

func _complete_task(pending: Dictionary, wait_error: int) -> void:
	var request: Dictionary = pending["request"]
	var request_id := int(request["request_id"])
	var tile_id := String(request["address_id"])
	var current_request_id := int(_current_request_by_tile.get(tile_id, 0))
	if current_request_id != request_id:
		_set_request_state(request_id, {"status": "superseded", "request": request})
		stale_result_rejected.emit(request_id, tile_id, current_request_id)
		return
	if wait_error != OK:
		_fail_request(request, "world-tile worker failed while completing (error %d)" % wait_error)
		return
	var task: WorldTileLoadTask = pending["worker"]
	var worker_result: Dictionary = task.result
	if String(worker_result.get("status", "")) == "cancelled":
		_fail_request(request, String(worker_result.get("error", "world-tile request cancelled")), "cancelled")
		return
	if not worker_result.get("ok", false):
		_fail_request(request, String(worker_result.get("error", "world-tile provider failed")))
		return
	var provider_result: Variant = worker_result.get("provider_result")
	if typeof(provider_result) != TYPE_DICTIONARY or _contains_object(provider_result):
		_fail_request(request, "provider result is not a plain-data dictionary")
		return
	if not provider_result.get("ok", false):
		_fail_request(request, String(provider_result.get("error", "world-tile bundle validation failed")))
		return
	var envelope_error := _validate_provider_envelope(request, provider_result)
	if not envelope_error.is_empty():
		_fail_request(request, envelope_error)
		return
	var manifest: Dictionary = provider_result["manifest"]
	var tile_origin_result := _make_tile_origin(manifest["tile_origin"])
	if not tile_origin_result.get("ok", false):
		_fail_request(request, String(tile_origin_result.get("error", "invalid tile origin")))
		return
	var tile_context := {
		"tile_id": tile_id,
		"address": request["address"],
		"lod": int(request["lod"]),
		"source_id": String(request["source_id"]),
		"source_generation": String(request["source_generation"]),
		"request_id": request_id,
		"generation": int(request["generation"]),
		"required_layers": request["required_layers"],
		"allow_partial": bool(request["allow_partial"]),
		"layer_outcomes": manifest["layer_outcomes"].duplicate(true),
		"manifest": manifest.duplicate(true),
		"tile_origin": tile_origin_result,
		"render_origin": _render_origin.duplicate(true)
	}
	var build_result: Variant = _tile_builder.call(provider_result["decoded"], tile_context)
	if typeof(build_result) != TYPE_DICTIONARY or not build_result.get("ok", false):
		_fail_request(request, String(build_result.get("error", "tile builder failed")) if typeof(build_result) == TYPE_DICTIONARY else "tile builder returned a non-dictionary result")
		return
	var tile_node: Variant = build_result.get("node")
	if not tile_node is Node3D or tile_node.get_parent() != null:
		_fail_request(request, "tile builder must return an unattached Node3D")
		return
	var included_layers: Variant = build_result.get("included_layers")
	if typeof(included_layers) not in [TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY]:
		tile_node.free()
		_fail_request(request, "tile builder must declare the layers included in its scene root")
		return
	var outcome_error := _apply_builder_outcome_overrides(request, manifest, build_result.get("layer_outcome_overrides", {}))
	if not outcome_error.is_empty():
		tile_node.free()
		_fail_request(request, outcome_error)
		return
	var included_layer_error := _validate_included_layers(included_layers, manifest["layer_outcomes"], request)
	if not included_layer_error.is_empty():
		tile_node.free()
		_fail_request(request, included_layer_error)
		return
	var required_output_error := _validate_required_layer_outputs(request, included_layers, manifest["layer_outcomes"])
	if not required_output_error.is_empty():
		tile_node.free()
		_fail_request(request, required_output_error)
		return
	var terrain_included := _string_list_has(included_layers, "terrain")
	var terrain_requested_ready := _requires_terrain_collision(request, manifest)
	if (terrain_included or terrain_requested_ready) and (not build_result.get("collision_ready", false) or not _contains_collision_object(tile_node)):
		tile_node.free()
		_fail_request(request, "terrain is not installable before its validated collision resource is ready")
		return
	var transform_result := LocalFrame.tile_transform(tile_origin_result, _render_origin)
	if not transform_result.get("ok", false):
		tile_node.free()
		_fail_request(request, String(transform_result.get("error", "tile is outside the render-origin range")))
		return
	tile_node.transform = transform_result["transform"]
	tile_node.name = "WorldTile_%s" % tile_id.replace(":", "_")
	tile_node.set_meta("wfg1_tile_id", tile_id)
	tile_node.set_meta("source_id", String(request["source_id"]))
	tile_node.set_meta("source_generation", String(request["source_generation"]))
	tile_node.set_meta("lod", int(request["lod"]))
	var tile_state := "ready" if _all_layers_ready(manifest["layer_outcomes"]) else "partial"
	add_child(tile_node)
	_release_installed_tile(tile_id, "replaced after validated source/LOD update")
	_installed_by_tile[tile_id] = {
		"status": tile_state,
		"request_id": request_id,
		"generation": int(request["generation"]),
		"tile_id": tile_id,
		"address": request["address"].duplicate(true),
		"source_id": String(request["source_id"]),
		"source_generation": String(request["source_generation"]),
		"lod": int(request["lod"]),
		"layer_outcomes": manifest["layer_outcomes"].duplicate(true),
		"tile_origin": tile_origin_result,
		"node": tile_node
	}
	_set_request_state(request_id, {"status": tile_state, "request": request.duplicate(true), "layer_outcomes": manifest["layer_outcomes"].duplicate(true)})
	for layer_id in manifest["layer_outcomes"]:
		var outcome: Dictionary = manifest["layer_outcomes"][layer_id]
		if String(outcome["status"]) == "no_source_coverage":
			coverage_gap_reported.emit(tile_id, String(layer_id), outcome.duplicate(true))
	tile_installed.emit(request_id, tile_id, String(request["source_id"]), int(request["lod"]), tile_state, manifest["layer_outcomes"].duplicate(true))

func _validate_provider_envelope(request: Dictionary, result: Dictionary) -> String:
	if not result.has("manifest") or typeof(result["manifest"]) != TYPE_DICTIONARY:
		return "provider did not return a manifest"
	if not result.has("decoded") or typeof(result["decoded"]) != TYPE_DICTIONARY:
		return "provider did not return validated decoded tile data"
	var manifest: Dictionary = result["manifest"]
	if String(manifest.get("schema_id", "")) != _expected_schema_id or String(manifest.get("schema_version", "")) != _expected_schema_version:
		return "bundle schema ID/version is unknown or incompatible with the configured provider"
	if String(manifest.get("address_id", "")) != String(request["address_id"]):
		return "bundle address identity differs from the request"
	if String(manifest.get("source_id", "")) != String(request["source_id"]):
		return "bundle source identity differs from the request"
	if String(manifest.get("source_generation", "")) != String(request["source_generation"]):
		return "bundle source generation differs from the requested generation"
	if typeof(manifest.get("lod")) not in [TYPE_INT, TYPE_FLOAT] or int(manifest["lod"]) != int(request["lod"]) or float(manifest["lod"]) != float(request["lod"]):
		return "bundle LOD identity differs from the request"
	var parsed_address := Address.parse_id(String(manifest["address_id"]))
	if not parsed_address.get("ok", false) or parsed_address["address"] != request["address"]:
		return "bundle address ID is not a canonical WFG-1 address"
	var bounds_error := _validate_manifest_tile_bounds(manifest, request["address"])
	if not bounds_error.is_empty():
		return bounds_error
	var layer_outcomes: Variant = manifest.get("layer_outcomes")
	if typeof(layer_outcomes) != TYPE_DICTIONARY:
		return "bundle layer_outcomes must be a dictionary"
	for layer_id_value in layer_outcomes:
		var layer_id := String(layer_id_value)
		var outcome: Variant = layer_outcomes[layer_id_value]
		if typeof(outcome) != TYPE_DICTIONARY:
			return "layer outcome %s is not a dictionary" % layer_id
		var status := String(outcome.get("status", ""))
		if status not in VALID_LAYER_STATUSES:
			return "layer outcome %s has an unknown status" % layer_id
		if status == "partial" and not _has_partial_disclosure(outcome):
			return "partial layer %s lacks a source/fallback/gap disclosure" % layer_id
		if status == "no_source_coverage" and not _has_explicit_gap(outcome):
			return "no_source_coverage for %s lacks an explicit gap record" % layer_id
		if status in ["not_generated", "failed", "cancelled"] and not _has_explicit_gap(outcome):
			return "unavailable layer %s lacks an explicit state record" % layer_id
	for layer_id_value in request["required_layers"]:
		var layer_id := String(layer_id_value)
		if not layer_outcomes.has(layer_id):
			return "required layer %s is missing from the bundle" % layer_id
		var outcome: Dictionary = layer_outcomes[layer_id]
		var status := String(outcome["status"])
		if status == "ready":
			continue
		if status == "partial" and bool(request["allow_partial"]) and _has_partial_disclosure(outcome):
			continue
		if status == "no_source_coverage" and bool(request["allow_partial"]) and _has_valid_fallback(outcome):
			continue
		return "required layer %s is %s without an explicitly permitted ready fallback" % [layer_id, status]
	var spatial_error := _validate_layer_spatial_references(manifest, layer_outcomes, result["decoded"])
	if not spatial_error.is_empty():
		return spatial_error
	var origin: Variant = manifest.get("tile_origin")
	if typeof(origin) != TYPE_DICTIONARY:
		return "bundle tile_origin must declare its geographic tangent-frame anchor"
	if String(origin.get("horizontal_crs", "")) not in [LocalFrame.CRS_GEOGRAPHIC_2D, LocalFrame.CRS_GEOGRAPHIC_3D]:
		return "tile_origin has an unsupported or unknown horizontal CRS"
	if String(origin.get("vertical_datum", "")) != LocalFrame.ELLIPSOIDAL_DATUM or String(origin.get("height_type", "")) != "ellipsoidal":
		return "tile_origin must declare WGS84 ellipsoidal height"
	var origin_error := _validate_tile_origin_address(origin, request["address"])
	if not origin_error.is_empty():
		return origin_error
	return ""

func _validate_manifest_tile_bounds(manifest: Dictionary, address: Dictionary) -> String:
	var declared: Variant = manifest.get("tile_bounds")
	if typeof(declared) != TYPE_DICTIONARY:
		return "bundle must declare WFG-1-derived tile bounds"
	var expected := Address.bounds_for_address(address)
	if not expected.get("ok", false):
		return "requested WFG-1 address has no computable bounds"
	for key in ["west_deg", "south_deg", "east_deg", "north_deg"]:
		if not declared.has(key) or typeof(declared[key]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(declared[key])):
			return "declared tile bounds are missing finite %s" % key
		if float(declared[key]) != float(expected[key]):
			return "declared tile bound %s does not match the WFG-1 address" % key
	return ""

func _validate_tile_origin_address(origin: Dictionary, address: Dictionary) -> String:
	for key in ["latitude_deg", "longitude_deg", "ellipsoidal_height_m"]:
		if not origin.has(key) or typeof(origin[key]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(origin[key])):
			return "tile_origin is missing finite %s" % key
	var origin_address := Address.address_for_lon_lat(float(origin["longitude_deg"]), float(origin["latitude_deg"]), int(address["level"]))
	if not origin_address.get("ok", false) or origin_address["address"] != address:
		return "tile_origin geodetic location does not belong to the requested WFG-1 address"
	var bounds := Address.bounds_for_address(address)
	var expected_latitude := (float(bounds["south_deg"]) + float(bounds["north_deg"])) * 0.5
	var expected_longitude := (float(bounds["west_deg"]) + float(bounds["east_deg"])) * 0.5
	if float(origin["latitude_deg"]) != expected_latitude or float(origin["longitude_deg"]) != expected_longitude or float(origin["ellipsoidal_height_m"]) != 0.0:
		return "tile_origin must be the WFG-1 tile-bounds center at zero ellipsoidal height"
	if origin.has("ecef_m"):
		if typeof(origin["ecef_m"]) != TYPE_PACKED_FLOAT64_ARRAY:
			return "tile_origin ECEF, when supplied, must remain a PackedFloat64Array"
		var recomputed := LocalFrame.create_origin(float(origin["latitude_deg"]), float(origin["longitude_deg"]), float(origin["ellipsoidal_height_m"]))
		if not recomputed.get("ok", false):
			return "tile_origin geodetic coordinates cannot be converted to WGS84 ECEF"
		var provided: PackedFloat64Array = origin["ecef_m"]
		var computed: PackedFloat64Array = recomputed["ecef_m"]
		if provided.size() != 3:
			return "tile_origin ECEF must contain three binary64 components"
		for component_index in range(3):
			if not is_finite(provided[component_index]) or absf(provided[component_index] - computed[component_index]) > LocalFrame.FRAME_COMPONENT_CONSISTENCY_M:
				return "tile_origin ECEF components contradict its geodetic coordinates/height"
	return ""

func _validate_layer_spatial_references(manifest: Dictionary, layer_outcomes: Dictionary, decoded: Dictionary) -> String:
	var spatial_references: Variant = manifest.get("layer_spatial_references")
	if typeof(spatial_references) != TYPE_DICTIONARY:
		return "bundle layer_spatial_references must declare CRS/datum semantics per layer"
	for layer_id_value in layer_outcomes:
		var layer_id := String(layer_id_value)
		if not spatial_references.has(layer_id):
			return "layer %s has no spatial reference declaration" % layer_id
		var reference: Variant = spatial_references[layer_id]
		if typeof(reference) != TYPE_DICTIONARY:
			return "layer %s spatial reference is not a dictionary" % layer_id
		var horizontal_crs := String(reference.get("horizontal_crs", ""))
		if horizontal_crs not in [LocalFrame.CRS_GEOGRAPHIC_2D, LocalFrame.CRS_GEOGRAPHIC_3D]:
			return "layer %s has an unsupported or unknown horizontal CRS" % layer_id
		if String(reference.get("horizontal_datum", "")) != "WGS84" or String(reference.get("axis_order", "")) != "longitude_latitude":
			return "layer %s must declare WGS84 longitude/latitude axis order" % layer_id
		if not reference.has("has_elevation") or typeof(reference["has_elevation"]) != TYPE_BOOL:
			return "layer %s must declare whether its payload contains elevation" % layer_id
		if not bool(reference["has_elevation"]):
			if String(reference.get("source_vertical_datum", "")) != "not_applicable" or String(reference.get("height_type", "")) != "not_applicable" or String(reference.get("vertical_datum", "")) != "not_applicable":
				return "non-elevation layer %s must explicitly declare vertical semantics as not_applicable" % layer_id
			continue
		if String(reference.get("height_type", "")) != "ellipsoidal" or String(reference.get("vertical_datum", "")) != LocalFrame.ELLIPSOIDAL_DATUM:
			return "layer %s must be transformed to explicit WGS84 ellipsoidal heights before ECEF placement" % layer_id
		var source_datum := String(reference.get("source_vertical_datum", ""))
		if source_datum == LocalFrame.ELLIPSOIDAL_DATUM:
			continue
		var conversion: Variant = reference.get("vertical_conversion")
		if typeof(conversion) != TYPE_DICTIONARY:
			return "layer %s source vertical datum %s lacks a verified conversion record" % [layer_id, source_datum]
		if source_datum == "per_sample_source_mask":
			var mapping: Variant = conversion.get("vertical_references_by_source_code")
			if typeof(mapping) != TYPE_DICTIONARY or mapping.is_empty():
				return "layer %s mixed source datums require vertical_references_by_source_code" % layer_id
			var layer_data: Variant = decoded.get(layer_id)
			if typeof(layer_data) != TYPE_DICTIONARY:
				return "layer %s mixed source datums require decoded per-sample masks" % layer_id
			var source_mask: Variant = layer_data.get("source_mask")
			var conversion_mask: Variant = layer_data.get("geoid_mask")
			if typeof(source_mask) != TYPE_PACKED_BYTE_ARRAY or typeof(conversion_mask) != TYPE_PACKED_BYTE_ARRAY or source_mask.size() == 0 or source_mask.size() != conversion_mask.size():
				return "layer %s source and conversion masks must be aligned PackedByteArray values" % layer_id
			var used_codes: Dictionary = {}
			for sample_index in range(source_mask.size()):
				var source_code := int(source_mask[sample_index])
				var conversion_code := int(conversion_mask[sample_index])
				var source_key := str(source_code)
				if source_code == 0 and conversion_code == 0:
					continue
				if not mapping.has(source_key):
					return "layer %s source mask code %d has no declared vertical reference" % [layer_id, source_code]
				var code_reference: Variant = mapping[source_key]
				if typeof(code_reference) != TYPE_DICTIONARY or int(code_reference.get("conversion_mask_code", -1)) != conversion_code:
					return "layer %s geoid conversion mask code contradicts source code %d" % [layer_id, source_code]
				used_codes[source_key] = true
			for source_key_value in mapping:
				var declared_source_key := String(source_key_value)
				var declared_reference: Variant = mapping[source_key_value]
				if not declared_source_key.is_valid_int() or typeof(declared_reference) != TYPE_DICTIONARY:
					return "layer %s vertical source-code map has an invalid key or record" % layer_id
				var code_source_datum := String(declared_reference.get("source_vertical_datum", ""))
				if code_source_datum not in ["EGM2008", "MEAN_SEA_LEVEL"]:
					return "layer %s source mask code %s has an unsupported source vertical datum" % [layer_id, declared_source_key]
				if String(declared_reference.get("geoid_grid_id", "")) != "OSGeo-PROJ-data/us_nga_egm08_25.tif" or not _is_sha256(String(declared_reference.get("geoid_grid_sha256", ""))) or String(declared_reference.get("interpolation_method", "")).is_empty() or not _has_numeric_validation(declared_reference):
					return "layer %s source mask code %s lacks a pinned geoid conversion and numeric validation" % [layer_id, declared_source_key]
				if code_source_datum == "EGM2008" and (String(declared_reference.get("method", "")) != "h = H_EGM2008 + N_EGM2008" or bool(declared_reference.get("approximate", true))):
					return "layer %s source mask code %s must use exact EGM2008 H+N semantics" % [layer_id, declared_source_key]
				if code_source_datum == "MEAN_SEA_LEVEL" and (String(declared_reference.get("method", "")) != "nominal_MSL_plus_EGM2008_geoid" or not bool(declared_reference.get("approximate", false)) or String(declared_reference.get("quality_warning", "")).strip_edges().is_empty()):
					return "layer %s nominal MSL source code %s must disclose approximate mixed-datum semantics" % [layer_id, declared_source_key]
				if used_codes.has(declared_source_key) and int(declared_reference.get("conversion_mask_code", -1)) < 1:
					return "layer %s source mask code %s has an invalid conversion-mask code" % [layer_id, declared_source_key]
			if used_codes.is_empty():
				return "layer %s mixed vertical reference map is not used by any valid samples" % layer_id
			continue
		var geoid_grid_id := String(conversion.get("geoid_grid_id", ""))
		var geoid_sha256 := String(conversion.get("geoid_grid_sha256", ""))
		var interpolation := String(conversion.get("interpolation_method", ""))
		if geoid_grid_id != "OSGeo-PROJ-data/us_nga_egm08_25.tif" or not _is_sha256(geoid_sha256) or interpolation.is_empty():
			return "layer %s lacks pinned EGM2008 geoid grid identity/checksum/interpolation metadata" % layer_id
		if not _has_numeric_validation(conversion):
			return "layer %s geoid conversion lacks independent numeric validation metadata" % layer_id
		if source_datum == "EGM2008":
			if String(conversion.get("method", "")) != "h = H_EGM2008 + N_EGM2008":
				return "layer %s EGM2008 conversion lacks h=H+N and independent numeric validation metadata" % layer_id
		elif source_datum == "MEAN_SEA_LEVEL":
			if not bool(conversion.get("approximate", false)) or String(conversion.get("method", "")) != "nominal_MSL_plus_EGM2008_geoid" or String(conversion.get("quality_warning", "")).strip_edges().is_empty():
				return "layer %s nominal MSL conversion must disclose its approximate mixed-datum limitation" % layer_id
		else:
			return "layer %s has an unsupported or unknown source vertical datum" % layer_id
	return ""

func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if character not in "0123456789abcdef":
			return false
	return true

func _has_numeric_validation(conversion: Dictionary) -> bool:
	var numeric_validation: Variant = conversion.get("numeric_validation")
	if typeof(numeric_validation) != TYPE_DICTIONARY:
		return false
	var residual: Variant = numeric_validation.get("max_residual_m")
	return typeof(residual) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(residual)) and float(residual) >= 0.0 and not String(numeric_validation.get("independent_method", "")).strip_edges().is_empty()

func _make_tile_origin(origin_metadata: Dictionary) -> Dictionary:
	var latitude := float(origin_metadata.get("latitude_deg", NAN))
	var longitude := float(origin_metadata.get("longitude_deg", NAN))
	var height := float(origin_metadata.get("ellipsoidal_height_m", NAN))
	return LocalFrame.create_origin(latitude, longitude, height)

func _has_partial_disclosure(outcome: Dictionary) -> bool:
	if _has_valid_fallback(outcome):
		return true
	return bool(outcome.get("gap_declared", false)) and not String(outcome.get("disclosure", "")).strip_edges().is_empty()

func _has_explicit_gap(outcome: Dictionary) -> bool:
	return bool(outcome.get("gap_declared", false)) and not String(outcome.get("gap_reason", outcome.get("disclosure", ""))).strip_edges().is_empty()

func _has_valid_fallback(outcome: Dictionary) -> bool:
	var fallback: Variant = outcome.get("fallback")
	if typeof(fallback) != TYPE_DICTIONARY:
		return false
	return String(fallback.get("status", "")) == "ready" and not String(fallback.get("source_id", "")).strip_edges().is_empty() and not String(fallback.get("provenance", "")).strip_edges().is_empty()

func _all_layers_ready(outcomes: Dictionary) -> bool:
	for layer_id in outcomes:
		if String(outcomes[layer_id].get("status", "")) != "ready":
			return false
	return true

func _requires_terrain_collision(request: Dictionary, manifest: Dictionary) -> bool:
	if not manifest["layer_outcomes"].has("terrain"):
		return false
	var terrain_outcome: Dictionary = manifest["layer_outcomes"]["terrain"]
	var status := String(terrain_outcome.get("status", ""))
	if not request["required_layers"].has("terrain"):
		return false
	return status == "ready" or status == "partial" and _has_valid_fallback(terrain_outcome) or status == "no_source_coverage" and _has_valid_fallback(terrain_outcome)

func _string_list_has(value: Variant, expected: String) -> bool:
	for item in value:
		if String(item) == expected:
			return true
	return false

func _apply_builder_outcome_overrides(request: Dictionary, manifest: Dictionary, overrides_value: Variant) -> String:
	if typeof(overrides_value) != TYPE_DICTIONARY:
		return "tile builder layer outcome overrides must be a dictionary"
	if overrides_value.is_empty():
		return ""
	var outcomes_value: Variant = manifest.get("layer_outcomes")
	if typeof(outcomes_value) != TYPE_DICTIONARY:
		return "provider layer outcomes disappeared before builder reconciliation"
	var outcomes: Dictionary = outcomes_value
	for layer_id_value in overrides_value:
		var layer_id := String(layer_id_value)
		var override: Variant = overrides_value[layer_id_value]
		if not outcomes.has(layer_id) or typeof(override) != TYPE_DICTIONARY:
			return "tile builder outcome override references an unknown layer or malformed record"
		if String(override.get("status", "")) != "partial":
			return "tile builder may only disclose a rendered layer as partial"
		var outcome: Dictionary = outcomes[layer_id].duplicate(true)
		var prior_status := String(outcome.get("status", ""))
		if prior_status not in ["ready", "partial"]:
			return "tile builder cannot upgrade or replace producer status %s for %s" % [prior_status, layer_id]
		var disclosure := String(override.get("disclosure", "")).strip_edges()
		var gap_reason := String(override.get("gap_reason", "")).strip_edges()
		if disclosure.is_empty() or gap_reason.is_empty() or not bool(override.get("gap_declared", false)):
			return "builder-rendered partial layer %s requires gap and disclosure metadata" % layer_id
		if prior_status == "ready":
			outcome["status"] = "partial"
		outcome["gap_declared"] = true
		outcome["gap_reason"] = gap_reason
		outcome["disclosure"] = disclosure
		outcomes[layer_id] = outcome
		if request["required_layers"].has(layer_id) and not bool(request["allow_partial"]):
			return "required layer %s rendered only partially and this request did not permit partial content" % layer_id
	manifest["layer_outcomes"] = outcomes
	return ""

func _validate_required_layer_outputs(request: Dictionary, included_layers: Variant, outcomes: Dictionary) -> String:
	for layer_id_value in request["required_layers"]:
		var layer_id := String(layer_id_value)
		if not outcomes.has(layer_id):
			return "required layer %s has no validated outcome" % layer_id
		var outcome: Dictionary = outcomes[layer_id]
		var status := String(outcome.get("status", ""))
		if status == "partial" and bool(request["allow_partial"]) and _has_partial_disclosure(outcome):
			continue
		if status == "no_source_coverage" and bool(request["allow_partial"]) and _has_valid_fallback(outcome):
			continue
		if status != "ready":
			return "required layer %s is %s without an explicitly permitted fallback" % [layer_id, status]
		var count := -1
		if layer_id == "terrain":
			count = int(outcome.get("sample_count", -1))
		elif layer_id in ["roads", "buildings", "water"]:
			count = int(outcome.get("feature_count", -1))
		else:
			count = int(outcome.get("pixel_count", -1))
		if count > 0 and not _string_list_has(included_layers, layer_id):
			return "ready nonempty required layer %s produced no renderable tile output" % layer_id
	return ""

func _validate_included_layers(included_layers: Variant, outcomes: Dictionary, request: Dictionary) -> String:
	for layer_id_value in included_layers:
		var layer_id := String(layer_id_value)
		if not outcomes.has(layer_id):
			return "tile builder included layer %s without a validated layer outcome" % layer_id
		var outcome: Dictionary = outcomes[layer_id]
		var status := String(outcome.get("status", ""))
		if status == "ready":
			continue
		if status == "partial" and bool(request["allow_partial"]) and _has_partial_disclosure(outcome):
			continue
		if status == "no_source_coverage" and bool(request["allow_partial"]) and _has_valid_fallback(outcome):
			continue
		return "tile builder included layer %s with non-installable status %s" % [layer_id, status]
	return ""

func _contains_collision_object(root: Node) -> bool:
	if root is CollisionObject3D:
		return true
	for child in root.get_children():
		if _contains_collision_object(child):
			return true
	return false

func _contains_object(value: Variant) -> bool:
	if typeof(value) == TYPE_OBJECT:
		return true
	if typeof(value) == TYPE_DICTIONARY:
		for key in value:
			if _contains_object(value[key]):
				return true
	elif typeof(value) == TYPE_ARRAY:
		for item in value:
			if _contains_object(item):
				return true
	return false

func _cancel_pending_for_tile(tile_id: String, reason: String) -> void:
	var queued_index := _queued_requests.size() - 1
	while queued_index >= 0:
		var queued: Dictionary = _queued_requests[queued_index]
		if String(queued["address_id"]) == tile_id:
			_queued_requests.remove_at(queued_index)
			_set_request_state(int(queued["request_id"]), {"status": "superseded", "request": queued.duplicate(true), "error": reason})
			tile_request_cancelled.emit(int(queued["request_id"]), tile_id, reason)
		queued_index -= 1
	for pending in _pending_tasks:
		var pending_request: Dictionary = pending["request"]
		if String(pending_request["address_id"]) == tile_id and not bool(pending["cancel_notified"]):
			pending["token"].cancel()
			pending["cancel_notified"] = true
			_set_request_state(int(pending_request["request_id"]), {"status": "superseded", "request": pending_request.duplicate(true), "error": reason})
			tile_request_cancelled.emit(int(pending_request["request_id"]), tile_id, reason)

func _fail_request(request: Dictionary, message: String, state: String = "failed") -> void:
	var request_id := int(request["request_id"])
	var tile_id := String(request["address_id"])
	_set_request_state(request_id, {"status": state, "request": request.duplicate(true), "error": message})
	if int(_current_request_by_tile.get(tile_id, 0)) == request_id:
		_restore_current_request_from_installed_tile(tile_id)
	if state == "cancelled":
		tile_request_cancelled.emit(request_id, tile_id, message)
	else:
		tile_request_failed.emit(request_id, tile_id, message)

func _rebase_installed_tile(tile_id: String) -> bool:
	if not _installed_by_tile.has(tile_id):
		return true
	var entry: Dictionary = _installed_by_tile[tile_id]
	var transform_result := LocalFrame.tile_transform(entry["tile_origin"], _render_origin)
	if not transform_result.get("ok", false):
		return false
	var node: Node3D = entry["node"]
	if not is_instance_valid(node):
		_installed_by_tile.erase(tile_id)
		return true
	node.transform = transform_result["transform"]
	return true

func _release_installed_tile(tile_id: String, reason: String, request_id: int = 0) -> void:
	if not _installed_by_tile.has(tile_id):
		return
	var entry: Dictionary = _installed_by_tile[tile_id]
	_installed_by_tile.erase(tile_id)
	if int(_current_request_by_tile.get(tile_id, 0)) == int(entry.get("request_id", -1)):
		_current_request_by_tile.erase(tile_id)
		_set_request_state(int(entry["request_id"]), {"status": "unloaded", "request_id": int(entry["request_id"]), "tile_id": tile_id, "reason": reason})
	var node: Node3D = entry["node"]
	if is_instance_valid(node):
		if node.get_parent() == self:
			remove_child(node)
		node.queue_free()
	if not reason.is_empty():
		tile_unloaded.emit(request_id, tile_id, reason)

func _exit_tree() -> void:
	for pending in _pending_tasks:
		pending["token"].cancel()
	for index in range(_pending_tasks.size() - 1, -1, -1):
		var pending: Dictionary = _pending_tasks[index]
		WorkerThreadPool.wait_for_task_completion(int(pending["task_id"]))
	_pending_tasks.clear()
	_queued_requests.clear()
	for tile_id_value in _installed_by_tile.keys():
		_release_installed_tile(String(tile_id_value), "manager shutdown")

func _count_queued_requests_for_tile(tile_id: String) -> int:
	var count := 0
	for request in _queued_requests:
		if String(request["address_id"]) == tile_id:
			count += 1
	return count

func _restore_current_request_from_installed_tile(tile_id: String) -> void:
	if _installed_by_tile.has(tile_id):
		_current_request_by_tile[tile_id] = int(_installed_by_tile[tile_id]["request_id"])
	else:
		_current_request_by_tile.erase(tile_id)

func _set_request_state(request_id: int, state: Dictionary) -> void:
	_state_by_request_id[request_id] = state
	var status := String(state.get("status", ""))
	if status not in ["ready", "partial", "failed", "cancelled", "superseded", "unloaded"]:
		return
	if not _terminal_request_history.has(request_id):
		_terminal_request_history.append(request_id)
	while _terminal_request_history.size() > MAX_TERMINAL_REQUEST_HISTORY:
		var expired_request_id: int = _terminal_request_history.pop_front()
		_state_by_request_id.erase(expired_request_id)

func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
