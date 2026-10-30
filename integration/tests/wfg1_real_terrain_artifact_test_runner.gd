extends SceneTree

const Address := preload("res://terrain/wfg1_tile_address.gd")
const StreamManager := preload("res://terrain/world_stream_manager.gd")
const TerrainProvider := preload("res://terrain/wfg1_global_terrain_artifact_provider_v1.gd")
const TerrainBuilder := preload("res://terrain/wfg1_global_tile_builder_v1.gd")
const EXPECTED_CONTRACT := "urn:worldforge:contract:global-terrain-tile:1.0.0"
const EXPECTED_PRODUCER := "6d4cf589a278b5e2eea668c25bc43469f4d45791"
const TILE_ID := "wfg1:0:729:555"
const SOURCE_ID := "worldforge-global-world"
const RUNTIME_LOD := 2

var _failures := 0
var _checks := 0
var _failure_message := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("WF_WFG1_REAL_TERRAIN_ARTIFACT_SUITE=real-generator-component-not-full-world-bundle")
	var manifest_path := OS.get_environment("WFG1_REAL_TERRAIN_MANIFEST")
	_check(not manifest_path.is_empty(), "real producer manifest path is supplied through the runner environment")
	if manifest_path.is_empty():
		_finish()
		return
	var manifest_file := FileAccess.open(manifest_path, FileAccess.READ)
	_check(manifest_file != null, "real producer manifest opens from the local immutable cache")
	if manifest_file == null:
		_finish()
		return
	var manifest_json := JSON.new()
	var parse_status := manifest_json.parse(manifest_file.get_as_text())
	manifest_file.close()
	_check(parse_status == OK and typeof(manifest_json.data) == TYPE_DICTIONARY, "real producer manifest parses as a JSON object")
	if parse_status != OK or typeof(manifest_json.data) != TYPE_DICTIONARY:
		_finish()
		return
	var raw: Dictionary = manifest_json.data
	_check(String(raw.get("contract_id", "")) == EXPECTED_CONTRACT and String(raw.get("producer", {}).get("commit", "")) == EXPECTED_PRODUCER, "artifact identifies the pinned global terrain producer contract/revision")
	_check(String(raw.get("tile", {}).get("id", "")) == TILE_ID and int(raw.get("terrain", {}).get("coverage", {}).get("valid_count", 0)) == 90_000, "real Paris artifact matches selected WFG-1 address and contains 90,000 valid samples")
	if String(raw.get("tile", {}).get("id", "")) != TILE_ID:
		_finish()
		return
	var generation := String(raw.get("generation", {}).get("cache_key", ""))
	_check(not generation.is_empty(), "real terrain producer cache key is used as the terrain source generation")
	var address_result := Address.parse_id(TILE_ID)
	_check(address_result.get("ok", false), "real WFG-1 tile address parses")
	if not address_result.get("ok", false):
		_finish()
		return
	var bounds := Address.bounds_for_address(address_result["address"])
	var center_lon := (float(bounds["west_deg"]) + float(bounds["east_deg"])) * 0.5
	var center_lat := (float(bounds["south_deg"]) + float(bounds["north_deg"])) * 0.5
	var manager := StreamManager.new()
	manager.name = "RealParisTerrainArtifactManager"
	root.add_child(manager)
	var provider := TerrainProvider.new()
	var provider_config := provider.configure_artifact(manifest_path)
	_check(provider_config.get("ok", false), "real global-terrain artifact provider accepts the immutable local manifest path")
	var configure_result := manager.configure_provider(provider, Callable(TerrainBuilder, "build_tile"), SOURCE_ID, generation, EXPECTED_CONTRACT, "1.0.0")
	_check(configure_result.get("ok", false), "actual WorldStreamManager accepts the real terrain component adapter and mesh/collision builder")
	var origin_result := manager.set_render_origin(center_lat, center_lon, 0.0)
	_check(origin_result.get("ok", false), "Paris tile requests use a center-local WGS84 render origin")
	var requested_id := manager.request_tile(address_result["address"], RUNTIME_LOD, ["terrain"], SOURCE_ID, generation, true)
	var waited_frames := 0
	while manager.get_pending_task_count() > 0 and waited_frames < 12000:
		await process_frame
		waited_frames += 1
	var state := manager.get_request_state(requested_id)
	_check(String(state.get("status", "")) == "partial", "real terrain installs while unbundled content layers remain explicit gaps")
	_check(manager.is_tile_loaded(address_result["address"]), "real WFG-1 Paris tile is present in the manager address map")
	if manager.is_tile_loaded(address_result["address"]):
		var tile := manager.get_loaded_tile(address_result["address"])
		var terrain_root: Node3D = tile
		_check(terrain_root.get_node_or_null("TerrainSurface") != null, "real source samples produce the requested terrain representation")
		var body := terrain_root.get_node_or_null("TerrainCollision") as StaticBody3D
		var collision_node := terrain_root.get_node_or_null("TerrainCollision/TerrainTriangles") as CollisionShape3D
		_check(body != null and collision_node != null and collision_node.shape is ConcavePolygonShape3D, "collision shape is built from the real source-derived terrain topology")
		var surface_node := terrain_root.get_node_or_null("TerrainSurface") as MeshInstance3D
		var render_arrays: Array = surface_node.mesh.surface_get_arrays(0) if surface_node != null and surface_node.mesh != null else []
		var render_vertices: PackedVector3Array = render_arrays[Mesh.ARRAY_VERTEX] if render_arrays.size() > Mesh.ARRAY_VERTEX else PackedVector3Array()
		var render_indices: PackedInt32Array = render_arrays[Mesh.ARRAY_INDEX] if render_arrays.size() > Mesh.ARRAY_INDEX else PackedInt32Array()
		var collision_faces: PackedVector3Array = (collision_node.shape as ConcavePolygonShape3D).get_faces() if collision_node != null and collision_node.shape is ConcavePolygonShape3D else PackedVector3Array()
		var topology_matches := render_indices.size() == collision_faces.size()
		var maximum_render_collision_residual_m := 0.0
		for face_index in range(mini(render_indices.size(), collision_faces.size())):
			var render_vertex_index := render_indices[face_index]
			if render_vertex_index < 0 or render_vertex_index >= render_vertices.size():
				topology_matches = false
				break
			var residual_m := render_vertices[render_vertex_index].distance_to(collision_faces[face_index])
			maximum_render_collision_residual_m = maxf(maximum_render_collision_residual_m, residual_m)
			if not is_finite(residual_m) or residual_m > 0.001:
				topology_matches = false
				break
		print("WF_WFG1_RENDER_COLLISION_MAX_VERTEX_RESIDUAL_M=%.12f" % maximum_render_collision_residual_m)
		_check(topology_matches and render_indices.size() % 3 == 0, "real terrain render/collision triangle order matches within the 1 mm vertex representation bound")
		_check(int(terrain_root.get_meta("runtime_lod", -1)) == RUNTIME_LOD and String(terrain_root.get_meta("terrain_lod_algorithm", "")) == "native-edge-preserving-center-fan-v1", "terrain representation records its exact LOD algorithm")
		_check(terrain_root.get_meta("terrain_edge_hashes", {}).size() == 4, "real terrain representation records all four source-derived tile edge hashes")
		var height_min := float(terrain_root.get_meta("sample_min_ellipsoidal_height_m", NAN))
		var height_max := float(terrain_root.get_meta("sample_max_ellipsoidal_height_m", NAN))
		_check(is_finite(height_min) and is_finite(height_max) and height_max >= height_min, "real ellipsoidal terrain heights remain finite through geometry construction")
		var lod2_triangles := int(terrain_root.get_meta("terrain_triangle_count", 0))
		var lod2_edges: Dictionary = terrain_root.get_meta("terrain_edge_hashes", {}).duplicate(true)
		# The manager's installed root is already positioned relative to the render origin.
		_check(tile != null and tile.transform.origin.length() <= 0.001, "tile root remains in the configured local tangent frame")
		var native_request := manager.request_tile(address_result["address"], 0, ["terrain"], SOURCE_ID, generation, true)
		var native_wait_frames := 0
		while manager.get_pending_task_count() > 0 and native_wait_frames < 12000:
			await process_frame
			native_wait_frames += 1
		_check(String(manager.get_request_state(native_request).get("status", "")) == "partial", "same real producer tile can transition back to native terrain representation")
		var native_tile := manager.get_loaded_tile(address_result["address"])
		var native_triangles := int(native_tile.get_meta("terrain_triangle_count", 0)) if native_tile != null else 0
		_check(native_tile != null and int(native_tile.get_meta("runtime_lod", -1)) == 0 and native_triangles > lod2_triangles, "real source LOD transition installs a distinct native render/collision topology")
		_check(native_tile != null and native_tile.get_meta("terrain_edge_hashes", {}) == lod2_edges, "real terrain LOD change preserves source-coordinate/height edge samples")
		manager.unload_tile(address_result["address"], "real artifact test cleanup")
		_check(not manager.is_tile_loaded(address_result["address"]), "unload releases the installed real terrain and collision nodes")
	else:
		_failure("real terrain request failed: %s" % String(state.get("error", "state=%s" % String(state.get("status", "unknown")))))
	manager.queue_free()
	await process_frame
	_finish()

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("PASS  " + label)
	else:
		_failure(label)

func _failure(label: String) -> void:
	_failures += 1
	if _failure_message.is_empty():
		_failure_message = label
	printerr("FAIL  " + label)

func _finish() -> void:
	print("WF_WFG1_REAL_TERRAIN_ARTIFACT_RESULT=%s checks=%d failures=%d" % ["PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(1 if _failures > 0 else 0)
