class_name GlobalTileAddressV1
extends RefCounted

## WorldForge's bounded prototype for a wrap- and pole-safe global cell address.
## The input is WGS 84 geographic 2D (latitude/longitude in degrees). It does not
## transform source datums or assign a height/reference frame.

const SCHEME_ID := "wf-cube-quad-v1"
const MIN_LEVEL := 0
const MAX_LEVEL := 30
const MIN_LATITUDE_DEG := -90.0
const MAX_LATITUDE_DEG := 90.0
const MIN_LONGITUDE_DEG := -180.0
const MAX_LONGITUDE_DEG := 180.0
const AXIS_EPSILON := 1.0e-15

## Quantize WGS 84 geographic 2D into one cubed-sphere quadtree cell.
## Longitude is normalized to [-180, 180); both poles have one canonical address.
static func address_wgs84(latitude_deg: float, longitude_deg: float, level: int) -> Dictionary:
    if not is_finite(latitude_deg) or latitude_deg < MIN_LATITUDE_DEG or latitude_deg > MAX_LATITUDE_DEG:
        return _failure("latitude_deg must be finite and within [-90, 90]")
    if not is_finite(longitude_deg) or longitude_deg < MIN_LONGITUDE_DEG or longitude_deg > MAX_LONGITUDE_DEG:
        return _failure("longitude_deg must be finite and within [-180, 180]")
    if level < MIN_LEVEL or level > MAX_LEVEL:
        return _failure("level is outside the supported [0, 30] range")

    var unit_direction: Vector3
    if latitude_deg == MAX_LATITUDE_DEG:
        unit_direction = Vector3(0.0, 0.0, 1.0)
    elif latitude_deg == MIN_LATITUDE_DEG:
        unit_direction = Vector3(0.0, 0.0, -1.0)
    else:
        var normalized_longitude := fposmod(longitude_deg + 180.0, 360.0) - 180.0
        var latitude_rad := deg_to_rad(latitude_deg)
        var longitude_rad := deg_to_rad(normalized_longitude)
        var cos_latitude := cos(latitude_rad)
        unit_direction = Vector3(
            cos_latitude * cos(longitude_rad),
            cos_latitude * sin(longitude_rad),
            sin(latitude_rad)
        )
    return address_direction(unit_direction, level)

## Address a finite nonzero direction using the same face and tie rules as the
## geographic entry point. This is useful for independent topology fixtures only.
static func address_direction(direction: Vector3, level: int) -> Dictionary:
    if level < MIN_LEVEL or level > MAX_LEVEL:
        return _failure("level is outside the supported [0, 30] range")
    if not _is_finite_vector(direction) or direction.length_squared() <= 0.0:
        return _failure("direction must be finite and nonzero")
    var normalized_direction := direction.normalized()
    var face_uv := _direction_to_face_uv(normalized_direction)
    var face := int(face_uv["face"])
    return _address_from_face_uv(face, float(face_uv["u"]), float(face_uv["v"]), level)

static func address_cell(face: int, level: int, x: int, y: int) -> Dictionary:
    if level < MIN_LEVEL or level > MAX_LEVEL or face < 0 or face > 5:
        return _failure("address face or level is outside the supported range")
    var count := 1 << level
    if x < 0 or x >= count or y < 0 or y >= count:
        return _failure("address cell coordinates are outside the selected level")
    return _make_address(face, level, x, y)

static func parent(address: Dictionary) -> Dictionary:
    var validation := _validate_address(address)
    if not validation.get("ok", false):
        return validation
    var level := int(address["level"])
    if level == 0:
        return _failure("level-0 face cells do not have a parent")
    return _make_address(int(address["face"]), level - 1, int(address["x"]) >> 1, int(address["y"]) >> 1)

static func children(address: Dictionary) -> Dictionary:
    var validation := _validate_address(address)
    if not validation.get("ok", false):
        return validation
    var level := int(address["level"])
    if level == MAX_LEVEL:
        return _failure("level-30 cells do not have prototype children")
    var face := int(address["face"])
    var child_level := level + 1
    var x := int(address["x"]) * 2
    var y := int(address["y"]) * 2
    return {
        "ok": true,
        "children": [
            _make_address(face, child_level, x, y),
            _make_address(face, child_level, x + 1, y),
            _make_address(face, child_level, x, y + 1),
            _make_address(face, child_level, x + 1, y + 1),
        ],
        "error": ""
    }

## Cardinal edge neighbours are topological cube-face neighbours. Edge rotation and
## reversal are explicit so a neighbour's opposite edge returns the original cell.
static func neighbor(address: Dictionary, direction: String) -> Dictionary:
    var validation := _validate_address(address)
    if not validation.get("ok", false):
        return validation
    if not ["east", "west", "north", "south"].has(direction):
        return _failure("direction must be east, west, north, or south")

    var level := int(address["level"])
    var count := 1 << level
    var face := int(address["face"])
    var x := int(address["x"])
    var y := int(address["y"])
    var next_face := face
    var next_x := x
    var next_y := y
    var reciprocal_direction := ""
    match direction:
        "east":
            if x + 1 < count:
                next_x += 1
                reciprocal_direction = "west"
            else:
                var mapped := _map_face_edge(face, direction, x, y, count)
                next_face = int(mapped["face"])
                next_x = int(mapped["x"])
                next_y = int(mapped["y"])
                reciprocal_direction = String(mapped["reciprocal_direction"])
        "west":
            if x > 0:
                next_x -= 1
                reciprocal_direction = "east"
            else:
                var mapped := _map_face_edge(face, direction, x, y, count)
                next_face = int(mapped["face"])
                next_x = int(mapped["x"])
                next_y = int(mapped["y"])
                reciprocal_direction = String(mapped["reciprocal_direction"])
        "north":
            if y > 0:
                next_y -= 1
                reciprocal_direction = "south"
            else:
                var mapped := _map_face_edge(face, direction, x, y, count)
                next_face = int(mapped["face"])
                next_x = int(mapped["x"])
                next_y = int(mapped["y"])
                reciprocal_direction = String(mapped["reciprocal_direction"])
        "south":
            if y + 1 < count:
                next_y += 1
                reciprocal_direction = "north"
            else:
                var mapped := _map_face_edge(face, direction, x, y, count)
                next_face = int(mapped["face"])
                next_x = int(mapped["x"])
                next_y = int(mapped["y"])
                reciprocal_direction = String(mapped["reciprocal_direction"])
    var result := _make_address(next_face, level, next_x, next_y)
    result["reciprocal_direction"] = reciprocal_direction
    return result

static func key(address: Dictionary) -> String:
    var validation := _validate_address(address)
    return String(address["tile_key"]) if validation.get("ok", false) else ""

static func _address_from_face_uv(face: int, u: float, v: float, level: int) -> Dictionary:
    if face < 0 or face > 5 or not is_finite(u) or not is_finite(v):
        return _failure("cube face or projected coordinates are invalid")
    var count := 1 << level
    var x := clampi(int(floor((u + 1.0) * 0.5 * float(count))), 0, count - 1)
    var y := clampi(int(floor((1.0 - v) * 0.5 * float(count))), 0, count - 1)
    return _make_address(face, level, x, y)

static func _make_address(face: int, level: int, x: int, y: int) -> Dictionary:
    var tile_key := "%s/f%d/l%d/x%d/y%d" % [SCHEME_ID, face, level, x, y]
    return {
        "ok": true,
        "scheme_id": SCHEME_ID,
        "face": face,
        "level": level,
        "x": x,
        "y": y,
        "tile_key": tile_key,
        "error": ""
    }

## Face order: +X, -X, +Y, -Y, +Z (north pole), -Z (south pole).
## Exact dominant-axis ties prefer X, then Y, then Z for deterministic ownership.
static func _direction_to_face_uv(direction: Vector3) -> Dictionary:
    var abs_x := absf(direction.x)
    var abs_y := absf(direction.y)
    var abs_z := absf(direction.z)
    if abs_x >= abs_y and abs_x >= abs_z:
        if direction.x >= 0.0:
            return {"face": 0, "u": direction.y / direction.x, "v": direction.z / direction.x}
        return {"face": 1, "u": -direction.y / abs_x, "v": direction.z / abs_x}
    if abs_y >= abs_z:
        if direction.y >= 0.0:
            return {"face": 2, "u": -direction.x / direction.y, "v": direction.z / direction.y}
        return {"face": 3, "u": direction.x / abs_y, "v": direction.z / abs_y}
    if direction.z >= 0.0:
        return {"face": 4, "u": direction.x / abs_z, "v": direction.y / abs_z}
    return {"face": 5, "u": direction.x / abs_z, "v": -direction.y / abs_z}

static func _map_face_edge(face: int, direction: String, x: int, y: int, count: int) -> Dictionary:
    match face:
        0:
            match direction:
                "east": return {"face": 2, "x": 0, "y": y, "reciprocal_direction": "west"}
                "west": return {"face": 3, "x": count - 1, "y": y, "reciprocal_direction": "east"}
                "north": return {"face": 4, "x": count - 1, "y": count - 1 - x, "reciprocal_direction": "east"}
                "south": return {"face": 5, "x": count - 1, "y": x, "reciprocal_direction": "east"}
        1:
            match direction:
                "east": return {"face": 3, "x": 0, "y": y, "reciprocal_direction": "west"}
                "west": return {"face": 2, "x": count - 1, "y": y, "reciprocal_direction": "east"}
                "north": return {"face": 4, "x": 0, "y": x, "reciprocal_direction": "west"}
                "south": return {"face": 5, "x": 0, "y": count - 1 - x, "reciprocal_direction": "west"}
        2:
            match direction:
                "east": return {"face": 1, "x": 0, "y": y, "reciprocal_direction": "west"}
                "west": return {"face": 0, "x": count - 1, "y": y, "reciprocal_direction": "east"}
                "north": return {"face": 4, "x": count - 1 - x, "y": 0, "reciprocal_direction": "north"}
                "south": return {"face": 5, "x": count - 1 - x, "y": count - 1, "reciprocal_direction": "south"}
        3:
            match direction:
                "east": return {"face": 0, "x": 0, "y": y, "reciprocal_direction": "west"}
                "west": return {"face": 1, "x": count - 1, "y": y, "reciprocal_direction": "east"}
                "north": return {"face": 4, "x": x, "y": count - 1, "reciprocal_direction": "south"}
                "south": return {"face": 5, "x": x, "y": 0, "reciprocal_direction": "north"}
        4:
            match direction:
                "east": return {"face": 0, "x": count - 1 - y, "y": 0, "reciprocal_direction": "north"}
                "west": return {"face": 1, "x": y, "y": 0, "reciprocal_direction": "north"}
                "north": return {"face": 2, "x": count - 1 - x, "y": 0, "reciprocal_direction": "north"}
                "south": return {"face": 3, "x": x, "y": 0, "reciprocal_direction": "north"}
        5:
            match direction:
                "east": return {"face": 0, "x": y, "y": count - 1, "reciprocal_direction": "south"}
                "west": return {"face": 1, "x": count - 1 - y, "y": count - 1, "reciprocal_direction": "south"}
                "north": return {"face": 3, "x": x, "y": count - 1, "reciprocal_direction": "south"}
                "south": return {"face": 2, "x": count - 1 - x, "y": count - 1, "reciprocal_direction": "south"}
    return {}

static func _validate_address(address: Dictionary) -> Dictionary:
    if String(address.get("scheme_id", "")) != SCHEME_ID:
        return _failure("address uses an unsupported cube-quadtree scheme")
    var level := int(address.get("level", -1))
    var face := int(address.get("face", -1))
    var x := int(address.get("x", -1))
    var y := int(address.get("y", -1))
    if level < MIN_LEVEL or level > MAX_LEVEL or face < 0 or face > 5:
        return _failure("address face or level is outside the supported range")
    var count := 1 << level
    if x < 0 or x >= count or y < 0 or y >= count:
        return _failure("address cell coordinates are outside the selected level")
    var expected_key := "%s/f%d/l%d/x%d/y%d" % [SCHEME_ID, face, level, x, y]
    if String(address.get("tile_key", "")) != expected_key:
        return _failure("tile_key does not match its address components")
    return {"ok": true, "error": ""}

static func _is_finite_vector(value: Vector3) -> bool:
    return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

static func _failure(message: String) -> Dictionary:
    return {"ok": false, "error": message}
