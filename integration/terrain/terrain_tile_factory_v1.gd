class_name TerrainTileFactoryV1
extends RefCounted

const LodBuilder := preload("res://terrain/terrain_lod_builder_v1.gd")

## Build renderer and static collision resources only after the decoder has validated
## the manifest and every sample. Rendering and collision use the same LOD vertices.
static func create_tile(decoded: Dictionary, lod_policy: String = "single_window_full_resolution", lod_level: int = 0, prebuilt_geometry: Dictionary = {}) -> Node3D:
    if not decoded.get("ok", false):
        return null
    var lod_geometry := prebuilt_geometry if not prebuilt_geometry.is_empty() else LodBuilder.build(decoded, lod_level)
    if not lod_geometry.get("ok", false) or int(lod_geometry.get("lod_level", -1)) != lod_level:
        return null
    var vertices: PackedVector3Array = lod_geometry["vertices"]
    var normals: PackedVector3Array = lod_geometry["normals"]
    var indices: PackedInt32Array = lod_geometry["indices"]
    var faces: PackedVector3Array = lod_geometry["faces"]
    if vertices.is_empty() or indices.is_empty() or faces.is_empty() or indices.size() != faces.size():
        return null

    var mesh := ArrayMesh.new()
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_INDEX] = indices
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    if mesh.get_surface_count() != 1:
        return null

    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.33, 0.45, 0.34, 1.0)
    material.roughness = 0.94
    material.metallic = 0.0
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    mesh.surface_set_material(0, material)

    var root := Node3D.new()
    var window_id := String(decoded["site"].get("window_id", "window-0"))
    root.name = "TerrainTile_%s_%s" % [String(decoded["site"]["site_id"]), window_id]
    root.set_meta("site_id", decoded["site"]["site_id"])
    root.set_meta("window_id", window_id)
    root.set_meta("region_id", decoded["manifest"]["grid"]["region_id"])
    root.set_meta("frame_id", decoded["manifest"]["frame"]["frame_id"])
    root.set_meta("artifact_id", decoded["artifact_id"])
    # The approved NAD83/NAVD88 source frame has no compatible global operation yet.
    # Keep a stable region-window identity, source identity, frame, and content revision
    # separate; do not synthesize a WGS 84 address from the source chart coordinates.
    root.set_meta("regional_tile_id", "wf-regional-window-v1/%s/%s" % [String(decoded["manifest"]["grid"]["region_id"]), window_id])
    root.set_meta("tile_identity_scheme", "wf-regional-window-v1")
    var source: Dictionary = decoded["manifest"]["source"]
    var raster: Dictionary = source["raster"]
    root.set_meta("source_identity", "%s/%s" % [String(source["product_id"]), String(raster["sha256"])])
    root.set_meta("spatial_reference_id", String(decoded["manifest"]["frame"]["frame_id"]))
    root.set_meta("content_revision", String(decoded["artifact_id"]))
    root.set_meta("lod_level", lod_level)
    root.set_meta("sample_stride", int(lod_geometry["sample_stride"]))
    root.set_meta("edge_sample_policy", "preserve_final_row_and_column")
    root.set_meta("source_row_indices", lod_geometry["source_rows"])
    root.set_meta("source_column_indices", lod_geometry["source_columns"])
    root.set_meta("lod_policy", lod_policy)
    root.set_meta("collision_contact_eligible", lod_level == 0)
    root.set_meta("collision_fidelity_policy", "source_sampled_level_0" if lod_level == 0 else "coarse_structural_lod_not_for_ground_contact")

    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "TerrainSurface"
    mesh_instance.mesh = mesh
    mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    root.add_child(mesh_instance)

    var body := StaticBody3D.new()
    body.name = "TerrainCollision"
    body.collision_layer = 1 if lod_level == 0 else 0
    body.collision_mask = 1 if lod_level == 0 else 0
    var collision_shape := CollisionShape3D.new()
    collision_shape.name = "TerrainTriangles"
    var collision := ConcavePolygonShape3D.new()
    collision.backface_collision = true
    collision.set_faces(faces)
    collision_shape.shape = collision
    collision_shape.disabled = lod_level != 0
    body.add_child(collision_shape)
    root.add_child(body)
    return root
