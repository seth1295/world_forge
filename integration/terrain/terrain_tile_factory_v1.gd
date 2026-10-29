class_name TerrainTileFactoryV1
extends RefCounted

## Build renderer and static collision resources only after the decoder has validated
## the manifest and every sample. Both resources share one local-space vertex set.
static func create_tile(decoded: Dictionary, lod_policy: String = "single_window_full_resolution") -> Node3D:
    if not decoded.get("ok", false):
        return null
    var vertices: PackedVector3Array = decoded["vertices"]
    var normals: PackedVector3Array = decoded["normals"]
    var indices: PackedInt32Array = decoded["indices"]
    var faces: PackedVector3Array = decoded["faces"]
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
    root.set_meta("lod_level", 0)
    root.set_meta("sample_stride", int(decoded["manifest"]["grid"]["sample_stride"]))
    root.set_meta("lod_policy", lod_policy)

    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "TerrainSurface"
    mesh_instance.mesh = mesh
    mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    root.add_child(mesh_instance)

    var body := StaticBody3D.new()
    body.name = "TerrainCollision"
    body.collision_layer = 1
    body.collision_mask = 1
    var collision_shape := CollisionShape3D.new()
    collision_shape.name = "TerrainTriangles"
    var collision := ConcavePolygonShape3D.new()
    collision.backface_collision = true
    collision.set_faces(faces)
    collision_shape.shape = collision
    body.add_child(collision_shape)
    root.add_child(body)
    return root
