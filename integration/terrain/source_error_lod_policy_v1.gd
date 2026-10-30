class_name SourceErrorLodPolicyV1
extends RefCounted

## Selects a visual level from per-tile source-derived geometric error and a
## scenario-provided screen-space budget. The budget is deliberately not global.
## Collision eligibility is never inferred from visual LOD.

static func select_visual_level(candidates: Array[Dictionary], metres_per_pixel: float, max_error_pixels: float) -> Dictionary:
    if not is_finite(metres_per_pixel) or metres_per_pixel <= 0.0:
        return _failure("metres_per_pixel must be finite and positive")
    if not is_finite(max_error_pixels) or max_error_pixels <= 0.0:
        return _failure("max_error_pixels must be finite and positive")
    if candidates.is_empty():
        return _failure("no source-backed visual LOD candidates are available")

    var candidates_by_level: Dictionary = {}
    for candidate in candidates:
        var level := int(candidate.get("lod_level", -1))
        if level < 0 or candidates_by_level.has(level):
            return _failure("candidate levels must be unique nonnegative integers")
        candidates_by_level[level] = candidate
    if not candidates_by_level.has(0):
        return _failure("LOD 0 is required as the fail-closed source reference")
    var source_reference: Dictionary = candidates_by_level[0]
    if not bool(source_reference.get("error_known", false)):
        return _failure("LOD 0 source reference error is unknown")
    var source_error := float(source_reference.get("max_geometric_error_m", INF))
    if not is_finite(source_error) or source_error < 0.0:
        return _failure("LOD 0 source reference error is invalid")

    var selected_level := 0
    var selected_error_pixels := source_error / metres_per_pixel
    for level_value in candidates_by_level.keys():
        var level := int(level_value)
        var candidate: Dictionary = candidates_by_level[level]
        if not bool(candidate.get("error_known", false)):
            continue
        var error_m := float(candidate.get("max_geometric_error_m", INF))
        if not is_finite(error_m) or error_m < 0.0:
            continue
        var error_pixels := error_m / metres_per_pixel
        if error_pixels <= max_error_pixels and level > selected_level:
            selected_level = level
            selected_error_pixels = error_pixels
    return {
        "ok": true,
        "selected_lod_level": selected_level,
        "estimated_screen_error_px": selected_error_pixels,
        "collision_eligibility_changed": false,
        "error": ""
    }

static func _failure(message: String) -> Dictionary:
    return {"ok": false, "selected_lod_level": -1, "estimated_screen_error_px": INF, "collision_eligibility_changed": false, "error": message}
