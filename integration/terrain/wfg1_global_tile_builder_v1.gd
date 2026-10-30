class_name Wfg1GlobalTileBuilderV1
extends RefCounted

## Main-thread combiner for terrain/collision, source feature geometry,
## categorical land cover and procedural vegetation proxies.
const TerrainBuilder := preload("res://terrain/wfg1_terrain_mesh_builder_v1.gd")
const FeatureBuilder := preload("res://terrain/wfg1_feature_geometry_builder_v1.gd")
const VegetationBuilder := preload("res://terrain/wfg1_vegetation_placement_v1.gd")

static func build_tile(decoded: Dictionary, context: Dictionary) -> Dictionary:
	var terrain_result := TerrainBuilder.build_tile(decoded, context)
	if not terrain_result.get("ok", false):
		return terrain_result
	var root: Node3D = terrain_result["node"]
	var included := PackedStringArray()
	for layer_id in terrain_result.get("included_layers", PackedStringArray()):
		included.append(String(layer_id))
	var overrides: Dictionary = {}
	var required_layers: Variant = context.get("required_layers", PackedStringArray())
	var filtered_decoded: Dictionary = decoded.duplicate()
	var source_vectors: Variant = decoded.get("vector_payloads_by_layer", {})
	if typeof(source_vectors) == TYPE_DICTIONARY:
		var requested_vectors: Dictionary = source_vectors.duplicate(true)
		for layer_id in ["roads", "buildings", "water"]:
			if not required_layers.has(layer_id):
				requested_vectors[layer_id] = []
		filtered_decoded["vector_payloads_by_layer"] = requested_vectors
	if not required_layers.has("landcover"):
		filtered_decoded.erase("landcover")
	if not required_layers.has("vegetation"):
		filtered_decoded.erase("vegetation")
	var feature_result := FeatureBuilder.build_nodes(filtered_decoded, context)
	if not feature_result.get("ok", false):
		root.free()
		return feature_result
	var feature_node: Variant = feature_result.get("node")
	if feature_node is Node3D:
		root.add_child(feature_node)
		for layer_id in feature_result.get("included_layers", PackedStringArray()):
			if not included.has(String(layer_id)):
				included.append(String(layer_id))
	var feature_overrides: Variant = feature_result.get("layer_outcome_overrides", {})
	if typeof(feature_overrides) == TYPE_DICTIONARY:
		overrides.merge(feature_overrides, true)
	var exclusion_disclosure := String(decoded.get("exclusion_mask_disclosure", ""))
	if required_layers.has("vegetation") and decoded.has("vegetation") and typeof(decoded["vegetation"]) == TYPE_DICTIONARY:
		var vegetation: Dictionary = decoded["vegetation"]
		if int(vegetation.get("rows", 0)) > 0 and int(vegetation.get("columns", 0)) > 0:
			var vegetation_result := VegetationBuilder.build_tile_nodes(decoded, context)
			if not vegetation_result.get("ok", false):
				root.free()
				return vegetation_result
			var vegetation_overrides: Variant = vegetation_result.get("layer_outcome_overrides", {})
			if typeof(vegetation_overrides) == TYPE_DICTIONARY and not vegetation_overrides.is_empty():
				overrides.merge(vegetation_overrides, true)
			var vegetation_node: Variant = vegetation_result.get("node")
			if vegetation_node is Node3D:
				vegetation_node.set_meta("exclusion_mask_disclosure", exclusion_disclosure)
				root.add_child(vegetation_node)
				if not included.has("vegetation"):
					included.append("vegetation")
		else:
			root.set_meta("vegetation_ready_empty", true)
	root.set_meta("global_tile_builder", "wfg1-global-tile-builder-v1")
	root.set_meta("included_layers", included)
	root.set_meta("layer_render_outcome_overrides", overrides.duplicate(true))
	if not exclusion_disclosure.is_empty():
		root.set_meta("vegetation_exclusion_mask_disclosure", exclusion_disclosure)
	return {
		"ok": true,
		"error": "",
		"node": root,
		"collision_ready": bool(terrain_result.get("collision_ready", false)),
		"included_layers": included,
		"layer_outcome_overrides": overrides,
		"terrain_triangle_count": terrain_result.get("indices", PackedInt32Array()).size() / 3
	}
