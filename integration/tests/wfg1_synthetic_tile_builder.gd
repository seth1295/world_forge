extends RefCounted

## Builds a deliberately synthetic scene tree to test the genuine stream-manager
## install/rebase/unload path. It is not a source-derived world tile.
var create_collision := true
var include_optional_terrain := false
var layer_outcome_overrides: Dictionary = {}

func build_tile(decoded: Dictionary, context: Dictionary) -> Dictionary:
	if String(decoded.get("fixture_label", "")) != "SYNTHETIC_TEST_FIXTURE" or String(decoded.get("fixture_tile_id", "")) != String(context["tile_id"]):
		return {"ok": false, "error": "synthetic fixture identity is invalid"}
	var root := Node3D.new()
	root.set_meta("synthetic_test_fixture", true)
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(10.0, 10.0, 10.0)
	mesh_instance.mesh = mesh
	root.add_child(mesh_instance)
	var collision_ready := false
	var included_layers := PackedStringArray(context["required_layers"])
	if include_optional_terrain and not included_layers.has("terrain"):
		included_layers.append("terrain")
	if included_layers.has("terrain") and create_collision:
		var body := StaticBody3D.new()
		body.name = "SyntheticTerrainCollision"
		var shape_node := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(10.0, 10.0, 10.0)
		shape_node.shape = shape
		body.add_child(shape_node)
		root.add_child(body)
		collision_ready = true
	var result := {"ok": true, "node": root, "collision_ready": collision_ready, "included_layers": included_layers}
	if not layer_outcome_overrides.is_empty():
		result["layer_outcome_overrides"] = layer_outcome_overrides.duplicate(true)
	return result
