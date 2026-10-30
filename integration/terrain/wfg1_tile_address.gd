class_name Wfg1TileAddress
extends RefCounted

## Canonical geographic address for the WorldForge WFG-1 global grid.
##
## Level-zero cells are 0.25 degrees by 0.25 degrees. Positive address levels
## bisect each level-zero cell independently; they do not describe source sample
## spacing or a terrain LOD. Longitude inputs must be in [-180, 180]; +180 is
## normalized to -180. Latitude +90 belongs to the final northmost row.
const SCHEME := "WFG-1"
const ID_PREFIX := "wfg1"
const MIN_LEVEL := 0
const MAX_LEVEL := 16
const LEVEL_ZERO_STEP_DEG := 0.25
const LEVEL_ZERO_X_COUNT := 1440
const LEVEL_ZERO_Y_COUNT := 720

static func address_for_lon_lat(longitude_deg: float, latitude_deg: float, level: int = 0) -> Dictionary:
	if level < MIN_LEVEL or level > MAX_LEVEL:
		return _failure("level must be an integer in [0, 16]")
	if not is_finite(longitude_deg) or longitude_deg < -180.0 or longitude_deg > 180.0:
		return _failure("longitude_deg must be finite and within [-180, 180]")
	if not is_finite(latitude_deg) or latitude_deg < -90.0 or latitude_deg > 90.0:
		return _failure("latitude_deg must be finite and within [-90, 90]")

	# At either exact pole all longitudes denote the same physical point. Use
	# longitude 0 for deterministic point ownership while retaining all x columns
	# for non-degenerate polar-area tiles below the pole.
	var normalized_longitude := 0.0 if absf(latitude_deg) == 90.0 else (-180.0 if longitude_deg == 180.0 else longitude_deg)
	var subdivisions := 1 << level
	var x_count := LEVEL_ZERO_X_COUNT * subdivisions
	var y_count := LEVEL_ZERO_Y_COUNT * subdivisions
	var x := int(floor((normalized_longitude + 180.0) * (4.0 * float(subdivisions))))
	var y := y_count - 1 if latitude_deg == 90.0 else int(floor((latitude_deg + 90.0) * (4.0 * float(subdivisions))))
	if x < 0 or x >= x_count or y < 0 or y >= y_count:
		return _failure("coordinate could not be assigned to a WFG-1 cell")
	return {"ok": true, "error": "", "address": {"scheme": SCHEME, "level": level, "x": x, "y": y}}

static func validate_address(address: Dictionary) -> Dictionary:
	if String(address.get("scheme", "")) != SCHEME:
		return _failure("address scheme must be WFG-1")
	var level_value: Variant = address.get("level")
	var x_value: Variant = address.get("x")
	var y_value: Variant = address.get("y")
	if not _is_exact_integer(level_value) or not _is_exact_integer(x_value) or not _is_exact_integer(y_value):
		return _failure("level, x, and y must be exact integers")
	var level := int(level_value)
	if level < MIN_LEVEL or level > MAX_LEVEL:
		return _failure("level must be an integer in [0, 16]")
	var subdivisions := 1 << level
	var x_count := LEVEL_ZERO_X_COUNT * subdivisions
	var y_count := LEVEL_ZERO_Y_COUNT * subdivisions
	var x := int(x_value)
	var y := int(y_value)
	if x < 0 or x >= x_count:
		return _failure("x is outside this level's global grid")
	if y < 0 or y >= y_count:
		return _failure("y is outside this level's global grid")
	return {"ok": true, "error": "", "address": {"scheme": SCHEME, "level": level, "x": x, "y": y}}

static func format_id(address: Dictionary) -> String:
	var checked := validate_address(address)
	if not checked.get("ok", false):
		return ""
	var value: Dictionary = checked["address"]
	return "%s:%d:%d:%d" % [ID_PREFIX, int(value["level"]), int(value["x"]), int(value["y"])]

static func parse_id(tile_id: String) -> Dictionary:
	var parts := tile_id.split(":", true)
	if parts.size() != 4 or parts[0] != ID_PREFIX:
		return _failure("tile ID must use canonical wfg1:<level>:<x>:<y> syntax")
	for index in range(1, parts.size()):
		if not _is_canonical_integer_text(parts[index]):
			return _failure("tile ID contains a noncanonical integer")
	var address := {"scheme": SCHEME, "level": int(parts[1]), "x": int(parts[2]), "y": int(parts[3])}
	var checked := validate_address(address)
	if not checked.get("ok", false):
		return checked
	if format_id(checked["address"]) != tile_id:
		return _failure("tile ID does not round-trip canonically")
	return {"ok": true, "error": "", "address": checked["address"], "tile_id": tile_id}

## Return the WGS84 longitude/latitude cell bounds. Each cell is half-open at
## east/north, except the global +90 degree edge; +180 is normalized to -180
## before lookup, so no address crosses the antimeridian.
static func bounds_for_address(address: Dictionary) -> Dictionary:
	var checked := validate_address(address)
	if not checked.get("ok", false):
		return checked
	var value: Dictionary = checked["address"]
	var step := LEVEL_ZERO_STEP_DEG / float(1 << int(value["level"]))
	var west := -180.0 + float(int(value["x"])) * step
	var south := -90.0 + float(int(value["y"])) * step
	var east := west + step
	var north := south + step
	return {
		"ok": true,
		"error": "",
		"address": value,
		"west_deg": west,
		"south_deg": south,
		"east_deg": east,
		"north_deg": north,
		"longitude_width_deg": step,
		"latitude_height_deg": step,
		"west_inclusive": true,
		"south_inclusive": true,
		"east_inclusive": false,
		"north_inclusive": int(value["y"]) == LEVEL_ZERO_Y_COUNT * (1 << int(value["level"])) - 1
	}

## Return same-level cardinal neighbors. Longitude wraps at the antimeridian;
## latitude stops at the poles. A tile never carries a wrapped east/west bbox.
static func cardinal_neighbors(address: Dictionary) -> Dictionary:
	var checked := validate_address(address)
	if not checked.get("ok", false):
		return checked
	var value: Dictionary = checked["address"]
	var level := int(value["level"])
	var x := int(value["x"])
	var y := int(value["y"])
	var subdivisions := 1 << level
	var x_count := LEVEL_ZERO_X_COUNT * subdivisions
	var y_count := LEVEL_ZERO_Y_COUNT * subdivisions
	var neighbors: Dictionary = {
		"west": {"scheme": SCHEME, "level": level, "x": (x - 1 + x_count) % x_count, "y": y},
		"east": {"scheme": SCHEME, "level": level, "x": (x + 1) % x_count, "y": y},
		"south": {},
		"north": {}
	}
	if y > 0:
		neighbors["south"] = {"scheme": SCHEME, "level": level, "x": x, "y": y - 1}
	if y + 1 < y_count:
		neighbors["north"] = {"scheme": SCHEME, "level": level, "x": x, "y": y + 1}
	return {"ok": true, "error": "", "neighbors": neighbors}

static func parent_address(address: Dictionary) -> Dictionary:
	var checked := validate_address(address)
	if not checked.get("ok", false):
		return checked
	var value: Dictionary = checked["address"]
	var level := int(value["level"])
	if level == MIN_LEVEL:
		return _failure("level-zero tile has no WFG-1 parent")
	return {"ok": true, "error": "", "address": {"scheme": SCHEME, "level": level - 1, "x": int(value["x"]) >> 1, "y": int(value["y"]) >> 1}}

static func child_addresses(address: Dictionary) -> Dictionary:
	var checked := validate_address(address)
	if not checked.get("ok", false):
		return checked
	var value: Dictionary = checked["address"]
	var level := int(value["level"])
	if level >= MAX_LEVEL:
		return _failure("maximum WFG-1 tile level has no addressable children")
	var x := int(value["x"]) * 2
	var y := int(value["y"]) * 2
	return {
		"ok": true,
		"error": "",
		"addresses": [
			{"scheme": SCHEME, "level": level + 1, "x": x, "y": y},
			{"scheme": SCHEME, "level": level + 1, "x": x + 1, "y": y},
			{"scheme": SCHEME, "level": level + 1, "x": x, "y": y + 1},
			{"scheme": SCHEME, "level": level + 1, "x": x + 1, "y": y + 1}
		]
	}

static func _is_exact_integer(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	var number := float(value)
	return is_finite(number) and floor(number) == number

static func _is_canonical_integer_text(value: String) -> bool:
	if value.is_empty():
		return false
	if value == "0":
		return true
	var start_index := 0
	if value.begins_with("-"):
		if value.length() == 1:
			return false
		start_index = 1
		if value[1] == "0":
			return false
	elif value[0] == "0":
		return false
	for index in range(start_index, value.length()):
		if not value[index].is_valid_int() or value[index].length() != 1:
			return false
	return true

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
