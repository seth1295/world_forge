extends SceneTree

const Address := preload("res://terrain/wfg1_tile_address.gd")
const StreamManager := preload("res://terrain/world_stream_manager.gd")
const SyntheticProvider := preload("res://tests/wfg1_synthetic_provider.gd")
const SyntheticBuilder := preload("res://tests/wfg1_synthetic_tile_builder.gd")
const LOCAL_RENDER_LIMIT_M := 250_000.0

var _checks := 0
var _failures := 0
var _started_counts: Dictionary = {}
var _cancelled_counts: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run_all")

func _run_all() -> void:
	print("WF_WFG1_WORLD_STREAM_TEST_SUITE=synthetic-provider-real-consumer")
	await _run_stream_manager_tests()
	print("WF_WFG1_WORLD_STREAM_TEST_RESULT=%s checks=%d failures=%d" % ["PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(1 if _failures > 0 else 0)

func _run_stream_manager_tests() -> void:
	var manager := StreamManager.new()
	manager.name = "SyntheticGlobalWorldStreamManager"
	root.add_child(manager)
	var provider := SyntheticProvider.new()
	var builder := SyntheticBuilder.new()
	var configure := manager.configure_provider(provider, Callable(builder, "build_tile"), "synthetic-source-v1", "synthetic-generation-v1", provider.schema_id, provider.schema_version)
	_check(configure.get("ok", false), "manager accepts the explicit synthetic provider/builder test fixture")
	var first_address := Address.address_for_lon_lat(0.125, 0.125)
	var manager_origin := manager.set_render_origin(0.125, 0.125, 0.0)
	_check(manager_origin.get("ok", false), "manager establishes a WGS84 local render origin")
	var failed_ids: Array[int] = []
	var stale_ids: Array[int] = []
	var gaps: Array[String] = []
	var installed_ids: Array[String] = []
	manager.tile_request_started.connect(func(request_id: int, _tile_id: String, _source: String, _lod: int) -> void: _started_counts[request_id] = int(_started_counts.get(request_id, 0)) + 1)
	manager.tile_request_failed.connect(func(request_id: int, _tile_id: String, _message: String) -> void: failed_ids.append(request_id))
	manager.tile_request_cancelled.connect(func(request_id: int, _tile_id: String, _reason: String) -> void: _cancelled_counts[request_id] = int(_cancelled_counts.get(request_id, 0)) + 1)
	manager.stale_result_rejected.connect(func(request_id: int, _tile_id: String, _current_id: int) -> void: stale_ids.append(request_id))
	manager.coverage_gap_reported.connect(func(_tile_id: String, layer_id: String, _outcome: Dictionary) -> void: gaps.append(layer_id))
	manager.tile_installed.connect(func(_request_id: int, tile_id: String, _source: String, _lod: int, _state: String, _outcomes: Dictionary) -> void: installed_ids.append(tile_id))

	provider.delay_msec = 15
	var addresses: Array[Dictionary] = []
	for x_offset in range(6):
		var longitude := 0.125 + float(x_offset) * 0.25
		addresses.append(Address.address_for_lon_lat(longitude, 0.125)["address"])
	var initial_request_ids: Array[int] = []
	for address in addresses:
		initial_request_ids.append(manager.request_tile(address, 0, ["terrain", "roads"]))
	_check(manager.get_active_worker_count() == StreamManager.MAX_IN_FLIGHT_WORKERS, "separate tile requests run asynchronously up to the manager concurrency cap")
	_check(manager.get_queued_request_count() == 2, "additional neighboring tiles queue behind active workers")
	await _wait_for_idle(manager)
	_check(manager.get_pending_task_count() == 0 and manager.get_loaded_tile_count() == 6, "six adjacent global tiles install and leave no queued/active work")
	_check(initial_request_ids.all(func(request_id: int) -> bool: return not failed_ids.has(request_id)), "valid ready tile requests do not fail")
	_check(initial_request_ids.all(func(request_id: int) -> bool: return int(_started_counts.get(request_id, 0)) == 1), "each request emits exactly one start event, including formerly queued tiles")

	var first_tile := manager.get_loaded_tile(first_address["address"])
	_check(first_tile != null and bool(first_tile.get_meta("synthetic_test_fixture", false)), "manager installs the builder output as an explicitly synthetic fixture")
	var first_state := manager.get_tile_state(first_address["address"])
	_check(String(first_state.get("status", "")) == "ready", "ready terrain and feature layers report ready installation state")
	_check(int(first_state["layer_outcomes"]["roads"]["feature_count"]) == 0 and bool(first_state["layer_outcomes"]["roads"]["coverage_metadata"]["query_complete"]), "zero-feature completed layer retains ready/query-complete semantics")
	_check(first_tile != null and first_tile.get_node_or_null("SyntheticTerrainCollision") != null, "collision object is created only after a ready terrain outcome reaches the main-thread builder")
	if first_tile != null:
		_check(first_tile.transform.origin.length() <= 0.001, "tile at the current origin receives an origin-relative local transform")
	var east_tile := manager.get_loaded_tile(addresses[1])
	_check(east_tile != null and east_tile.transform.origin.distance_to(Vector3.ZERO) > 20_000.0 and east_tile.transform.origin.length() < LOCAL_RENDER_LIMIT_M, "neighboring tile transform is local tangent metres rather than ECEF coordinates")

	var source_lod_request := manager.request_tile(first_address["address"], 1, ["terrain", "roads"], "synthetic-source-v2", "synthetic-generation-v2")
	await _wait_for_loaded_request(manager, first_address["address"], source_lod_request)
	var changed_tile := manager.get_loaded_tile(first_address["address"])
	_check(changed_tile != null and String(changed_tile.get_meta("source_id", "")) == "synthetic-source-v2" and int(changed_tile.get_meta("lod", -1)) == 1, "source and LOD changes replace the same WFG-1 tile identity")
	_check(manager.get_loaded_tile_count() == 6, "source/LOD replacement leaves one installed representation per address")

	var neighbor_bounds: Dictionary = Address.bounds_for_address(addresses[0])
	var rebased := manager.set_render_origin(
		(float(neighbor_bounds["south_deg"]) + float(neighbor_bounds["north_deg"])) * 0.5,
		(float(neighbor_bounds["west_deg"]) + float(neighbor_bounds["east_deg"])) * 0.5,
		0.0
	)
	_check(rebased.get("ok", false), "render-origin rebase updates installed neighboring tile transforms")
	first_tile = manager.get_loaded_tile(first_address["address"])
	_check(first_tile != null and first_tile.transform.origin.length() <= 0.001, "rebasing preserves the tile anchor at the local origin")

	var australia := Address.address_for_lon_lat(153.0, -27.0)
	var australia_bounds: Dictionary = Address.bounds_for_address(australia["address"])
	manager.set_render_origin(
		(float(australia_bounds["south_deg"]) + float(australia_bounds["north_deg"])) * 0.5,
		(float(australia_bounds["west_deg"]) + float(australia_bounds["east_deg"])) * 0.5,
		0.0
	)
	_check(manager.get_loaded_tile_count() == 0, "remote rebase unloads tiles outside the supported local-vector range instead of retaining wrong transforms")
	var remote_request := manager.request_tile(australia["address"], 0, ["terrain"])
	await _wait_for_loaded_request(manager, australia["address"], remote_request)
	_check(manager.is_tile_loaded(australia["address"]), "remote Australia tile can be requested after the origin is rebased there")

	provider.delay_msec = 60
	var old_source_request := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-old-source", "old-generation")
	var latest_source_request := manager.request_tile(australia["address"], 2, ["terrain"], "synthetic-latest-source", "latest-generation")
	await _wait_for_loaded_request(manager, australia["address"], latest_source_request)
	await _wait_for_idle(manager)
	var latest_tile := manager.get_loaded_tile(australia["address"])
	_check(stale_ids.has(old_source_request), "superseded source/LOD result is rejected by request and generation identity")
	_check(int(_cancelled_counts.get(old_source_request, 0)) == 1 and int(_started_counts.get(latest_source_request, 0)) == 1, "source supersession emits one cancellation and the replacement starts once")
	_check(latest_tile != null and String(latest_tile.get_meta("source_id", "")) == "synthetic-latest-source" and int(latest_tile.get_meta("lod", -1)) == 2, "latest async variant is the only installed result")

	provider.delay_msec = 0
	provider.status_by_layer = {"terrain": "no_source_coverage"}
	var no_source_request := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-no-source", "gap-generation", true)
	await _wait_for_idle(manager)
	_check(failed_ids.has(no_source_request), "required no-source-coverage layer is rejected without an installed fallback")
	_check(String(manager.get_loaded_tile(australia["address"]).get_meta("source_id", "")) == "synthetic-latest-source", "failed source replacement preserves the previous explicitly identified tile")
	provider.valid_fallback_for_layer = "terrain"
	var fallback_request := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-with-fallback", "fallback-generation", true)
	await _wait_for_loaded_request(manager, australia["address"], fallback_request)
	_check(String(manager.get_tile_state(australia["address"])["layer_outcomes"]["terrain"]["fallback"]["source_id"]) == "synthetic-lawful-fallback", "explicitly permitted partial install exposes fallback provenance")
	provider.valid_fallback_for_layer = ""

	provider.status_by_layer = {"terrain": "partial"}
	var partial_denied := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-partial-denied", "partial-denied-generation", false)
	await _wait_for_idle(manager)
	_check(failed_ids.has(partial_denied), "partial layer is rejected unless request explicitly allows it")
	var partial_allowed := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-partial-allowed", "partial-allowed-generation", true)
	await _wait_for_loaded_request(manager, australia["address"], partial_allowed)
	_check(String(manager.get_tile_state(australia["address"]).get("status", "")) == "partial", "explicitly allowed partial install exposes a partial state")
	_check(String(manager.get_tile_state(australia["address"])["layer_outcomes"]["terrain"]["disclosure"]).contains("synthetic"), "partial install preserves source/gap disclosure")

	provider.status_by_layer.clear()
	provider.extra_layer_outcomes = {"water": {"status": "no_source_coverage", "gap_declared": true, "gap_reason": "synthetic water fixture gap"}}
	var optional_gap := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-optional-gap", "optional-gap-generation")
	await _wait_for_loaded_request(manager, australia["address"], optional_gap)
	_check(gaps.has("water"), "optional no-source layer installs only as a visible explicit gap")
	_check(String(manager.get_tile_state(australia["address"]).get("status", "")) == "partial", "tile with a declared optional coverage gap reports partial")

	provider.extra_layer_outcomes.clear()
	provider.bad_origin_vertical_datum = "NAVD88"
	var bad_origin := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-bad-origin", "bad-origin-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(bad_origin), "unsupported tile-origin vertical datum fails closed")
	provider.bad_origin_vertical_datum = ""
	provider.bad_layer_source_vertical_datum = "NAVD88"
	var bad_source_datum := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-bad-source-datum", "bad-source-datum-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(bad_source_datum), "unsupported terrain source vertical datum fails closed")
	provider.bad_layer_source_vertical_datum = "EGM2008"
	var unverified_geoid := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-unverified-geoid", "unverified-geoid-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(unverified_geoid), "EGM2008 terrain is rejected without pinned grid/interpolation/validation metadata")
	provider.bad_layer_source_vertical_datum = ""
	provider.mixed_source_vertical = true
	var mixed_vertical_ready := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-mixed-vertical", "mixed-vertical-generation")
	await _wait_for_loaded_request(manager, australia["address"], mixed_vertical_ready)
	_check(String(manager.get_tile_state(australia["address"]).get("status", "")) == "ready", "mixed EGM2008/nominal-MSL tile validates per-source conversion and aligned masks")
	provider.bad_mixed_conversion_mask = true
	var mixed_mask_mismatch := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-mixed-mask-mismatch", "mixed-mask-mismatch-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(mixed_mask_mismatch), "mixed-datum tile rejects a source mask and geoid-conversion mask mismatch")
	provider.bad_mixed_conversion_mask = false
	provider.mixed_source_vertical = false
	provider.tile_bounds_offset_deg = 0.001
	var bad_bounds := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-bad-bounds", "bad-bounds-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(bad_bounds), "manifest bounds that disagree with the WFG-1 address fail closed")
	provider.tile_bounds_offset_deg = 0.0
	provider.origin_longitude_offset_deg = 0.2
	var bad_origin_location := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-wrong-origin", "wrong-origin-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(bad_origin_location), "tile origin outside its declared WFG-1 address fails closed")
	provider.origin_longitude_offset_deg = 0.0
	provider.bad_origin_ecef = true
	var bad_origin_ecef := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-bad-ecef", "bad-ecef-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(bad_origin_ecef), "declared ECEF origin inconsistent with geodetic location/height fails closed")
	provider.bad_origin_ecef = false
	provider.status_by_layer = {"terrain": "ready"}
	provider.extra_layer_outcomes["water"] = {"status": "ready"}
	provider.bad_layer_horizontal_crs = "EPSG:3857"
	var bad_crs := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-bad-crs", "bad-crs-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(bad_crs), "unsupported per-layer projected CRS fails closed")
	provider.bad_layer_horizontal_crs = ""
	provider.extra_layer_outcomes.clear()
	provider.schema_id = "urn:worldforge:unknown-world-tile-contract"
	var unknown_schema := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-unknown-schema", "unknown-schema-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(unknown_schema), "unknown world-tile schema ID/version fails closed")
	provider.schema_id = "urn:worldforge:synthetic-test-fixture:1"

	builder.create_collision = false
	var no_collision := manager.request_tile(australia["address"], 0, ["terrain"], "synthetic-no-collision", "no-collision-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(no_collision), "terrain request fails before install if collision resource is not ready")
	builder.create_collision = true
	provider.extra_layer_outcomes.clear()
	builder.layer_outcome_overrides = {
		"roads": {
			"status": "partial",
			"gap_declared": true,
			"gap_reason": "synthetic builder exclusion fixture",
			"disclosure": "The synthetic geometry fixture was deliberately omitted."
		}
	}
	var builder_partial_address := Address.address_for_lon_lat(153.1, -27.3)
	var builder_partial_rejected := manager.request_tile(builder_partial_address["address"], 0, ["roads"], "synthetic-builder-partial", "builder-partial-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(builder_partial_rejected) and not manager.is_tile_loaded(builder_partial_address["address"]), "builder-discovered partial geometry is rejected unless the caller permits it")
	var builder_partial_allowed := manager.request_tile(builder_partial_address["address"], 0, ["roads"], "synthetic-builder-partial", "builder-partial-generation", true)
	await _wait_for_loaded_request(manager, builder_partial_address["address"], builder_partial_allowed)
	var builder_partial_state := manager.get_tile_state(builder_partial_address["address"])
	_check(String(builder_partial_state.get("status", "")) == "partial" and String(builder_partial_state.get("layer_outcomes", {}).get("roads", {}).get("disclosure", "")) == "The synthetic geometry fixture was deliberately omitted.", "builder outcome overrides are retained in the installed layer state")
	manager.unload_tile(builder_partial_address["address"], "release builder outcome fixture")
	builder.layer_outcome_overrides.clear()

	provider.extra_layer_outcomes = {"terrain": {"status": "ready"}}
	builder.include_optional_terrain = true
	builder.create_collision = false
	var optional_terrain_no_collision := manager.request_tile(australia["address"], 0, ["roads"], "synthetic-optional-terrain", "optional-terrain-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(optional_terrain_no_collision), "optional terrain included by the builder also requires its ready collision object")
	provider.extra_layer_outcomes.clear()
	builder.include_optional_terrain = false
	builder.create_collision = true

	provider.status_by_layer = {"terrain": "failed"}
	var greenland := Address.address_for_lon_lat(-42.0, 73.0)
	var greenland_bounds: Dictionary = Address.bounds_for_address(greenland["address"])
	manager.set_render_origin(
		(float(greenland_bounds["south_deg"]) + float(greenland_bounds["north_deg"])) * 0.5,
		(float(greenland_bounds["west_deg"]) + float(greenland_bounds["east_deg"])) * 0.5,
		0.0
	)
	var unavailable_request := manager.request_tile(greenland["address"], 0, ["terrain"], "synthetic-provider-failure", "failure-generation")
	await _wait_for_idle(manager)
	_check(failed_ids.has(unavailable_request) and not manager.is_tile_loaded(greenland["address"]), "provider failure never marks an unavailable remote tile ready")

	provider.status_by_layer.clear()
	provider.delay_msec = 40
	var neighbors: Dictionary = Address.cardinal_neighbors(greenland["address"])["neighbors"]
	var active_cancel_addresses: Array[Dictionary] = [neighbors["west"], neighbors["east"], neighbors["south"], neighbors["north"]]
	var active_cancel_requests: Array[int] = []
	for active_address in active_cancel_addresses:
		active_cancel_requests.append(manager.request_tile(active_address, 0, ["terrain"]))
	var queued_address: Dictionary = greenland["address"]
	var queued_cancel_request := manager.request_tile(queued_address, 0, ["terrain"], "synthetic-queued-to-cancel", "queued-cancel-generation")
	_check(manager.get_active_worker_count() == StreamManager.MAX_IN_FLIGHT_WORKERS and manager.get_queued_request_count() == 1, "queued cancellation fixture reaches one bounded waiting slot")
	manager.cancel_tile(queued_address, "cancel queued fixture request")
	await _wait_for_idle(manager)
	_check(int(_cancelled_counts.get(queued_cancel_request, 0)) == 1 and not _started_counts.has(queued_cancel_request), "queued cancellation emits once and never emits started")
	_check(active_cancel_requests.all(func(request_id: int) -> bool: return int(_started_counts.get(request_id, 0)) == 1), "all active tasks emit exactly one started event")

	var active_address: Dictionary = Address.cardinal_neighbors(greenland["address"])["neighbors"]["west"]
	var active_cancel_request := manager.request_tile(active_address, 1, ["terrain"], "synthetic-active-to-cancel", "active-cancel-generation")
	manager.cancel_tile(active_address, "cancel active fixture request")
	await _wait_for_idle(manager)
	_check(int(_cancelled_counts.get(active_cancel_request, 0)) == 1 and not failed_ids.has(active_cancel_request), "active cancellation emits once without a duplicate failure signal")
	_check(stale_ids.has(active_cancel_request), "active cancelled completion is still observed and rejected as stale")

	provider.delay_msec = 0
	var stress_origin := Address.address_for_lon_lat(0.125, 0.125, Address.MAX_LEVEL)
	var stress_bounds: Dictionary = Address.bounds_for_address(stress_origin["address"])
	manager.set_render_origin(
		(float(stress_bounds["south_deg"]) + float(stress_bounds["north_deg"])) * 0.5,
		(float(stress_bounds["west_deg"]) + float(stress_bounds["east_deg"])) * 0.5,
		0.0
	)
	var stress_failures := 0
	for index in range(StreamManager.MAX_TERMINAL_REQUEST_HISTORY + 12):
		var stress_address := {"scheme": "WFG-1", "level": Address.MAX_LEVEL, "x": int(stress_origin["address"]["x"]) + index, "y": int(stress_origin["address"]["y"])}
		var stress_request := manager.request_tile(stress_address, 0, ["terrain"], "synthetic-stress-%d" % index, "generation-%d" % index)
		var frames_left := 3600
		while manager.get_pending_task_count() > 0 and frames_left > 0:
			await process_frame
			frames_left -= 1
		if frames_left == 0 or failed_ids.has(stress_request) or not manager.is_tile_loaded(stress_address):
			stress_failures += 1
		manager.unload_tile(stress_address, "release repeated unique-address fixture")
		await process_frame
		if manager.is_tile_loaded(stress_address) or manager.get_tracked_tile_count() != 0:
			stress_failures += 1
	_check(stress_failures == 0, "repeated unique-tile load/unload cycles leave no address tombstones or active tile identity")
	_check(manager.get_request_history_count() <= StreamManager.MAX_TERMINAL_REQUEST_HISTORY, "terminal request history remains within its documented bound")

	provider.delay_msec = 50
	var cancel_address := {"scheme": "WFG-1", "level": Address.MAX_LEVEL, "x": int(stress_origin["address"]["x"]) + 500, "y": int(stress_origin["address"]["y"])}
	var pending_unload := manager.request_tile(cancel_address, 0, ["terrain"], "synthetic-cancelled", "cancel-generation")
	manager.unload_tile(cancel_address, "synthetic unload during provider work")
	await _wait_for_idle(manager)
	_check(not manager.is_tile_loaded(cancel_address), "unload during async work releases current tile and prevents a late install")
	_check(stale_ids.has(pending_unload), "unload-invalidated provider completion is observed as stale")
	_check(int(_cancelled_counts.get(pending_unload, 0)) == 1, "unload emits exactly one cancellation event for its active request")
	_check(manager.get_pending_task_count() == 0, "cancelled worker and queued requests drain before manager shutdown")
	manager.queue_free()
	await process_frame
	_check(not is_instance_valid(manager), "manager shutdown releases installed resources and joins accepted workers")

func _wait_for_loaded_request(manager: WorldStreamManager, address: Dictionary, request_id: int) -> void:
	var frames_left := 3600
	while manager.get_pending_task_count() > 0 and frames_left > 0:
		await process_frame
		frames_left -= 1
	var loaded := manager.get_loaded_tile(address)
	_check(frames_left > 0, "request %d drains its asynchronous work" % request_id)
	_check(loaded != null and int(loaded.get_meta("lod", -1)) == int(manager.get_tile_state(address).get("lod", loaded.get_meta("lod", -1))), "request %d installs a scene root when its source is ready" % request_id)

func _wait_for_idle(manager: WorldStreamManager) -> void:
	var frames_left := 3600
	while manager.get_pending_task_count() > 0 and frames_left > 0:
		await process_frame
		frames_left -= 1
	_check(frames_left > 0, "asynchronous multi-tile task queue drains")

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  %s" % description)
	else:
		_failures += 1
		push_error("FAIL  %s" % description)
