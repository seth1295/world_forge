class_name TerrainOriginRebaseV1
extends Node3D

## Scene-level floating origin for one declared regional Cartesian frame. Durable child
## transforms remain in that frame; this root alone translates them into Godot-local space.
## It does not transform between regional, geodetic, ECEF, or height datums.

var origin_frame_position_m := Vector3.ZERO
var origin_generation := 0

func rebase_to_frame_position(new_origin_m: Vector3) -> Dictionary:
    if not _is_finite_vector(new_origin_m):
        return {"ok": false, "error": "origin frame position must be finite"}
    origin_frame_position_m = new_origin_m
    position = -new_origin_m
    origin_generation += 1
    return {"ok": true, "origin_generation": origin_generation, "error": ""}

## Convert a durable child position in the declared regional chart to the root's local
## coordinate expression. Descendants are authored in frame coordinates and left intact.
func frame_to_local(frame_position_m: Vector3) -> Vector3:
    return frame_position_m - origin_frame_position_m

func local_to_frame(local_position_m: Vector3) -> Vector3:
    return local_position_m + origin_frame_position_m

## Ray and physics query results are scene/world positions after the root translation.
func scene_world_to_frame(scene_world_position_m: Vector3) -> Vector3:
    return scene_world_position_m + origin_frame_position_m

static func _is_finite_vector(value: Vector3) -> bool:
    return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
