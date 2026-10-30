class_name Wfg1LocalFrame
extends RefCounted

## Double-precision WGS84 geocentric calculations for the global consumer.
##
## ECEF components remain scalar/PackedFloat64Array values. A Vector3 is made
## only after subtracting a validated render origin and converting the delta to
## its local east/up/south tangent frame. This avoids down-casting Earth-radius
## values to a single-precision engine vector.
const CRS_GEOGRAPHIC_2D := "EPSG:4326"
const CRS_GEOGRAPHIC_3D := "EPSG:4979"
const CRS_GEOCENTRIC := "EPSG:4978"
const ELLIPSOIDAL_DATUM := "WGS84_ELLIPSOIDAL"
const SEMI_MAJOR_AXIS_M := 6_378_137.0
const INVERSE_FLATTENING := 298.257223563
const FLATTENING := 1.0 / INVERSE_FLATTENING
const SEMI_MINOR_AXIS_M := SEMI_MAJOR_AXIS_M * (1.0 - FLATTENING)
const ECCENTRICITY_SQUARED := FLATTENING * (2.0 - FLATTENING)
const MIN_ELLIPSOIDAL_HEIGHT_M := -12_000.0
const MAX_ELLIPSOIDAL_HEIGHT_M := 100_000_000.0
const MIN_ECEF_RADIUS_M := SEMI_MINOR_AXIS_M + MIN_ELLIPSOIDAL_HEIGHT_M
const MAX_ECEF_RADIUS_M := SEMI_MAJOR_AXIS_M + MAX_ELLIPSOIDAL_HEIGHT_M
## Local-render-domain constraint: WFG-1 level-zero cells span about 27.8 km at
## the equator, so this admits several neighboring cells while preventing a
## tile Node3D from becoming a planet-scale/global position. It is not an
## accuracy target or a performance threshold. Out-of-domain tiles are released
## and must be requested after rebasing the render origin near their address.
const MAX_LOCAL_COMPONENT_M := 250_000.0
const FRAME_COMPONENT_CONSISTENCY_M := 0.000001
const FRAME_BASIS_CONSISTENCY := 1.0e-15

## Make a reusable tangent-frame origin from WGS84 lon/lat and an ellipsoidal
## height. This method accepts no orthometric or unknown vertical height.
static func create_origin(latitude_deg: float, longitude_deg: float, ellipsoidal_height_m: float = 0.0) -> Dictionary:
	var normalized_longitude := -180.0 if longitude_deg == 180.0 else longitude_deg
	var converted := geodetic_to_ecef_components(
		latitude_deg,
		normalized_longitude,
		ellipsoidal_height_m,
		CRS_GEOGRAPHIC_2D,
		ELLIPSOIDAL_DATUM,
		"ellipsoidal"
	)
	if not converted.get("ok", false):
		return converted
	var latitude_rad := deg_to_rad(latitude_deg)
	var longitude_rad := deg_to_rad(normalized_longitude)
	return {
		"ok": true,
		"error": "",
		"crs": CRS_GEOCENTRIC,
		"horizontal_crs": CRS_GEOGRAPHIC_2D,
		"vertical_datum": ELLIPSOIDAL_DATUM,
		"latitude_deg": latitude_deg,
		"longitude_deg": normalized_longitude,
		"ellipsoidal_height_m": ellipsoidal_height_m,
		"ecef_m": converted["ecef_m"],
		"sin_latitude": sin(latitude_rad),
		"cos_latitude": cos(latitude_rad),
		"sin_longitude": sin(longitude_rad),
		"cos_longitude": cos(longitude_rad)
	}

## Convert a WGS84 geographic point into ECEF component doubles. The CRS and
## vertical-reference arguments are mandatory so an orthometric source cannot
## accidentally be passed as ellipsoidal height. Use an explicit, validated
## geoid conversion in the producer before calling this method.
static func geodetic_to_ecef_components(
		latitude_deg: float,
		longitude_deg: float,
		ellipsoidal_height_m: float,
		horizontal_crs: String,
		vertical_datum: String,
		height_type: String
	) -> Dictionary:
	if horizontal_crs not in [CRS_GEOGRAPHIC_2D, CRS_GEOGRAPHIC_3D]:
		return _failure("unsupported or unknown horizontal CRS")
	if vertical_datum != ELLIPSOIDAL_DATUM or height_type != "ellipsoidal":
		return _failure("only explicit WGS84 ellipsoidal heights can be converted to ECEF")
	if not is_finite(latitude_deg) or latitude_deg < -90.0 or latitude_deg > 90.0:
		return _failure("latitude_deg must be finite and within [-90, 90]")
	if not is_finite(longitude_deg) or longitude_deg < -180.0 or longitude_deg > 180.0:
		return _failure("longitude_deg must be finite and within [-180, 180]")
	if not is_finite(ellipsoidal_height_m) or ellipsoidal_height_m < MIN_ELLIPSOIDAL_HEIGHT_M or ellipsoidal_height_m > MAX_ELLIPSOIDAL_HEIGHT_M:
		return _failure("ellipsoidal height is outside the declared WGS84 conversion bounds")

	var normalized_longitude := -180.0 if longitude_deg == 180.0 else longitude_deg
	var latitude_rad := deg_to_rad(latitude_deg)
	var longitude_rad := deg_to_rad(normalized_longitude)
	var sin_latitude := sin(latitude_rad)
	var cos_latitude := cos(latitude_rad)
	var prime_vertical_radius := SEMI_MAJOR_AXIS_M / sqrt(1.0 - ECCENTRICITY_SQUARED * sin_latitude * sin_latitude)
	var x := (prime_vertical_radius + ellipsoidal_height_m) * cos_latitude * cos(longitude_rad)
	var y := (prime_vertical_radius + ellipsoidal_height_m) * cos_latitude * sin(longitude_rad)
	var z := (prime_vertical_radius * (1.0 - ECCENTRICITY_SQUARED) + ellipsoidal_height_m) * sin_latitude
	var radius := sqrt(x * x + y * y + z * z)
	if not is_finite(x) or not is_finite(y) or not is_finite(z) or not is_finite(radius) or radius < MIN_ECEF_RADIUS_M or radius > MAX_ECEF_RADIUS_M:
		return _failure("converted WGS84 ECEF coordinate is outside declared bounds")
	var components := PackedFloat64Array([x, y, z])
	return {"ok": true, "error": "", "crs": CRS_GEOCENTRIC, "horizontal_crs": CRS_GEOGRAPHIC_2D, "latitude_deg": latitude_deg, "longitude_deg": normalized_longitude, "ellipsoidal_height_m": ellipsoidal_height_m, "ecef_m": components}

## Public validation entry point for normalized provider/builder tangent frames.
## Recomputes ECEF from the declared geodetic origin and rejects contradictory
## component or basis fields before any transform uses them.
static func validate_frame(frame: Dictionary) -> Dictionary:
	var validation_error := _validate_frame(frame)
	if not validation_error.is_empty():
		return _failure(validation_error)
	return {"ok": true, "error": ""}

## Project an ECEF point to an engine-local Vector3. ECEF remains a packed
## double array until after origin subtraction; output axes are east, up, south.
static func ecef_to_local(ecef_m: PackedFloat64Array, origin: Dictionary) -> Dictionary:
	var input_error := _validate_frame_inputs(ecef_m, origin)
	if not input_error.is_empty():
		return _failure(input_error)
	var origin_ecef: PackedFloat64Array = origin["ecef_m"]
	var dx := ecef_m[0] - origin_ecef[0]
	var dy := ecef_m[1] - origin_ecef[1]
	var dz := ecef_m[2] - origin_ecef[2]
	var east := -float(origin["sin_longitude"]) * dx + float(origin["cos_longitude"]) * dy
	var up := float(origin["cos_latitude"]) * float(origin["cos_longitude"]) * dx + float(origin["cos_latitude"]) * float(origin["sin_longitude"]) * dy + float(origin["sin_latitude"]) * dz
	var north := -float(origin["sin_latitude"]) * float(origin["cos_longitude"]) * dx - float(origin["sin_latitude"]) * float(origin["sin_longitude"]) * dy + float(origin["cos_latitude"]) * dz
	if not _local_components_in_bounds(east, up, north):
		return _failure("point is outside the current render-origin range; rebase before vector conversion")
	return {"ok": true, "error": "", "local_enu_m": Vector3(east, up, north), "local_engine_m": Vector3(east, up, -north)}

## Return the Node3D transform for geometry authored in the tile anchor's local
## east/up/south tangent frame, relative to the current render-origin frame.
## Only the origin-relative translation and unit basis vectors become Vector3s.
static func tile_transform(tile_origin: Dictionary, render_origin: Dictionary) -> Dictionary:
	var tile_error := _validate_frame(tile_origin)
	if not tile_error.is_empty():
		return _failure("invalid tile origin: " + tile_error)
	var render_error := _validate_frame(render_origin)
	if not render_error.is_empty():
		return _failure("invalid render origin: " + render_error)
	var local_anchor := ecef_to_local(tile_origin["ecef_m"], render_origin)
	if not local_anchor.get("ok", false):
		return local_anchor

	var east_t := PackedFloat64Array([-float(tile_origin["sin_longitude"]), float(tile_origin["cos_longitude"]), 0.0])
	var up_t := PackedFloat64Array([
		float(tile_origin["cos_latitude"]) * float(tile_origin["cos_longitude"]),
		float(tile_origin["cos_latitude"]) * float(tile_origin["sin_longitude"]),
		float(tile_origin["sin_latitude"])
	])
	var south_t := PackedFloat64Array([
		float(tile_origin["sin_latitude"]) * float(tile_origin["cos_longitude"]),
		float(tile_origin["sin_latitude"]) * float(tile_origin["sin_longitude"]),
		-float(tile_origin["cos_latitude"])
	])
	var east_o := PackedFloat64Array([-float(render_origin["sin_longitude"]), float(render_origin["cos_longitude"]), 0.0])
	var up_o := PackedFloat64Array([
		float(render_origin["cos_latitude"]) * float(render_origin["cos_longitude"]),
		float(render_origin["cos_latitude"]) * float(render_origin["sin_longitude"]),
		float(render_origin["sin_latitude"])
	])
	var south_o := PackedFloat64Array([
		float(render_origin["sin_latitude"]) * float(render_origin["cos_longitude"]),
		float(render_origin["sin_latitude"]) * float(render_origin["sin_longitude"]),
		-float(render_origin["cos_latitude"])
	])
	var x_axis := Vector3(_dot(east_o, east_t), _dot(up_o, east_t), _dot(south_o, east_t))
	var y_axis := Vector3(_dot(east_o, up_t), _dot(up_o, up_t), _dot(south_o, up_t))
	var z_axis := Vector3(_dot(east_o, south_t), _dot(up_o, south_t), _dot(south_o, south_t))
	var basis := Basis(x_axis, y_axis, z_axis)
	if not _is_finite_vector(x_axis) or not _is_finite_vector(y_axis) or not _is_finite_vector(z_axis) or not _is_finite_vector(local_anchor["local_engine_m"]):
		return _failure("tile-to-origin transform contains non-finite values")
	return {"ok": true, "error": "", "transform": Transform3D(basis, local_anchor["local_engine_m"])}

static func orthometric_to_ellipsoidal_height(
		orthometric_height_m: float,
		geoid_undulation_m: float,
		source_vertical_datum: String,
		geoid_model: String
	) -> Dictionary:
	if source_vertical_datum != "EGM2008" or geoid_model != "EGM2008":
		return _failure("unsupported vertical conversion; only explicit EGM2008 H + EGM2008 N is implemented")
	if not is_finite(orthometric_height_m) or not is_finite(geoid_undulation_m):
		return _failure("orthometric height and geoid undulation must be finite")
	var ellipsoidal_height_m := orthometric_height_m + geoid_undulation_m
	if not is_finite(ellipsoidal_height_m) or ellipsoidal_height_m < MIN_ELLIPSOIDAL_HEIGHT_M or ellipsoidal_height_m > MAX_ELLIPSOIDAL_HEIGHT_M:
		return _failure("converted ellipsoidal height is outside the declared bounds")
	return {
		"ok": true,
		"error": "",
		"height_type": "ellipsoidal",
		"vertical_datum": ELLIPSOIDAL_DATUM,
		"source_height_m": orthometric_height_m,
		"geoid_undulation_m": geoid_undulation_m,
		"ellipsoidal_height_m": ellipsoidal_height_m,
		"conversion": "h = H_EGM2008 + N_EGM2008"
	}

## WGS84 inverse geodesic distance using Vincenty's ellipsoidal solution. This
## is used only for validating a declared boundary-sample offset; it does not
## change the source or target coordinates.
static func geodesic_distance_wgs84_m(latitude1_deg: float, longitude1_deg: float, latitude2_deg: float, longitude2_deg: float) -> Dictionary:
	for coordinate in [latitude1_deg, longitude1_deg, latitude2_deg, longitude2_deg]:
		if not is_finite(coordinate):
			return _failure("geodesic coordinates must be finite")
	if latitude1_deg < -90.0 or latitude1_deg > 90.0 or latitude2_deg < -90.0 or latitude2_deg > 90.0 or longitude1_deg < -180.0 or longitude1_deg > 180.0 or longitude2_deg < -180.0 or longitude2_deg > 180.0:
		return _failure("geodesic coordinates are outside WGS84 longitude/latitude bounds")
	var flattening := FLATTENING
	var semi_major := SEMI_MAJOR_AXIS_M
	var semi_minor := SEMI_MINOR_AXIS_M
	var phi1 := deg_to_rad(latitude1_deg)
	var phi2 := deg_to_rad(latitude2_deg)
	var longitude_delta_deg := longitude2_deg - longitude1_deg
	while longitude_delta_deg > 180.0:
		longitude_delta_deg -= 360.0
	while longitude_delta_deg < -180.0:
		longitude_delta_deg += 360.0
	var longitude_delta := deg_to_rad(longitude_delta_deg)
	var u1 := atan((1.0 - flattening) * tan(phi1))
	var u2 := atan((1.0 - flattening) * tan(phi2))
	var sin_u1 := sin(u1)
	var cos_u1 := cos(u1)
	var sin_u2 := sin(u2)
	var cos_u2 := cos(u2)
	var lambda := longitude_delta
	var sin_sigma := 0.0
	var cos_sigma := 0.0
	var sigma := 0.0
	var sin_alpha := 0.0
	var cos_sq_alpha := 0.0
	var cos_two_sigma_m := 0.0
	var converged := false
	for _iteration in range(100):
		var sin_lambda := sin(lambda)
		var cos_lambda := cos(lambda)
		var term1 := cos_u2 * sin_lambda
		var term2 := cos_u1 * sin_u2 - sin_u1 * cos_u2 * cos_lambda
		sin_sigma = sqrt(term1 * term1 + term2 * term2)
		if sin_sigma == 0.0:
			return {"ok": true, "error": "", "distance_m": 0.0}
		cos_sigma = sin_u1 * sin_u2 + cos_u1 * cos_u2 * cos_lambda
		sigma = atan2(sin_sigma, cos_sigma)
		sin_alpha = cos_u1 * cos_u2 * sin_lambda / sin_sigma
		cos_sq_alpha = 1.0 - sin_alpha * sin_alpha
		cos_two_sigma_m = 0.0 if cos_sq_alpha <= 1.0e-30 else cos_sigma - 2.0 * sin_u1 * sin_u2 / cos_sq_alpha
		var coefficient := flattening / 16.0 * cos_sq_alpha * (4.0 + flattening * (4.0 - 3.0 * cos_sq_alpha))
		var previous_lambda := lambda
		lambda = longitude_delta + (1.0 - coefficient) * flattening * sin_alpha * (sigma + coefficient * sin_sigma * (cos_two_sigma_m + coefficient * cos_sigma * (-1.0 + 2.0 * cos_two_sigma_m * cos_two_sigma_m)))
		if absf(lambda - previous_lambda) <= 1.0e-13:
			converged = true
			break
	if not converged:
		return _failure("WGS84 inverse geodesic did not converge for these coordinates")
	var u_sq := cos_sq_alpha * (semi_major * semi_major - semi_minor * semi_minor) / (semi_minor * semi_minor)
	var a_coefficient := 1.0 + u_sq / 16384.0 * (4096.0 + u_sq * (-768.0 + u_sq * (320.0 - 175.0 * u_sq)))
	var b_coefficient := u_sq / 1024.0 * (256.0 + u_sq * (-128.0 + u_sq * (74.0 - 47.0 * u_sq)))
	var delta_sigma := b_coefficient * sin_sigma * (cos_two_sigma_m + b_coefficient / 4.0 * (cos_sigma * (-1.0 + 2.0 * cos_two_sigma_m * cos_two_sigma_m) - b_coefficient / 6.0 * cos_two_sigma_m * (-3.0 + 4.0 * sin_sigma * sin_sigma) * (-3.0 + 4.0 * cos_two_sigma_m * cos_two_sigma_m)))
	var distance := semi_minor * a_coefficient * (sigma - delta_sigma)
	if not is_finite(distance) or distance < 0.0:
		return _failure("WGS84 inverse geodesic produced an invalid distance")
	return {"ok": true, "error": "", "distance_m": distance}

static func _validate_frame_inputs(ecef_m: PackedFloat64Array, origin: Dictionary) -> String:
	var origin_error := _validate_frame(origin)
	if not origin_error.is_empty():
		return "invalid render origin: " + origin_error
	if ecef_m.size() != 3:
		return "ECEF point must contain exactly three binary64 components"
	for component in ecef_m:
		if not is_finite(component):
			return "ECEF components must be finite"
	var radius := sqrt(ecef_m[0] * ecef_m[0] + ecef_m[1] * ecef_m[1] + ecef_m[2] * ecef_m[2])
	if not is_finite(radius) or radius < MIN_ECEF_RADIUS_M or radius > MAX_ECEF_RADIUS_M:
		return "ECEF point radius is outside the declared WGS84 bounds"
	return ""

static func _validate_frame(frame: Dictionary) -> String:
	if String(frame.get("crs", "")) != CRS_GEOCENTRIC:
		return "CRS must be EPSG:4978"
	if String(frame.get("horizontal_crs", "")) != CRS_GEOGRAPHIC_2D:
		return "frame horizontal CRS must be EPSG:4326"
	if String(frame.get("vertical_datum", "")) != ELLIPSOIDAL_DATUM:
		return "origin height must be explicitly WGS84 ellipsoidal"
	var ecef: Variant = frame.get("ecef_m")
	if typeof(ecef) != TYPE_PACKED_FLOAT64_ARRAY or (ecef as PackedFloat64Array).size() != 3:
		return "ECEF origin must be a three-element PackedFloat64Array"
	for component in ecef:
		if not is_finite(component):
			return "ECEF origin components must be finite"
	for key in ["latitude_deg", "longitude_deg", "ellipsoidal_height_m", "sin_latitude", "cos_latitude", "sin_longitude", "cos_longitude"]:
		if not frame.has(key) or typeof(frame[key]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(frame[key])):
			return "origin frame is missing finite %s" % key
	if float(frame["latitude_deg"]) < -90.0 or float(frame["latitude_deg"]) > 90.0:
		return "origin latitude is outside [-90, 90]"
	if float(frame["longitude_deg"]) < -180.0 or float(frame["longitude_deg"]) >= 180.0:
		return "origin longitude must be normalized to [-180, 180)"
	if float(frame["ellipsoidal_height_m"]) < MIN_ELLIPSOIDAL_HEIGHT_M or float(frame["ellipsoidal_height_m"]) > MAX_ELLIPSOIDAL_HEIGHT_M:
		return "origin ellipsoidal height is outside the declared WGS84 bounds"
	var radius := sqrt(ecef[0] * ecef[0] + ecef[1] * ecef[1] + ecef[2] * ecef[2])
	if not is_finite(radius) or radius < MIN_ECEF_RADIUS_M or radius > MAX_ECEF_RADIUS_M:
		return "ECEF origin radius is outside the declared WGS84 bounds"
	var latitude_rad := deg_to_rad(float(frame["latitude_deg"]))
	var longitude_rad := deg_to_rad(float(frame["longitude_deg"]))
	if absf(float(frame["sin_latitude"]) - sin(latitude_rad)) > FRAME_BASIS_CONSISTENCY or absf(float(frame["cos_latitude"]) - cos(latitude_rad)) > FRAME_BASIS_CONSISTENCY:
		return "stored latitude tangent basis differs from its geodetic origin"
	if absf(float(frame["sin_longitude"]) - sin(longitude_rad)) > FRAME_BASIS_CONSISTENCY or absf(float(frame["cos_longitude"]) - cos(longitude_rad)) > FRAME_BASIS_CONSISTENCY:
		return "stored longitude tangent basis differs from its geodetic origin"
	var expected_ecef := geodetic_to_ecef_components(
		float(frame["latitude_deg"]),
		float(frame["longitude_deg"]),
		float(frame["ellipsoidal_height_m"]),
		CRS_GEOGRAPHIC_2D,
		ELLIPSOIDAL_DATUM,
		"ellipsoidal"
	)
	if not expected_ecef.get("ok", false):
		return "origin coordinates cannot be represented as WGS84 ECEF"
	var expected_components: PackedFloat64Array = expected_ecef["ecef_m"]
	for component_index in range(3):
		if absf(ecef[component_index] - expected_components[component_index]) > FRAME_COMPONENT_CONSISTENCY_M:
			return "stored ECEF origin differs from its geodetic coordinates and ellipsoidal height"
	return ""

static func _local_components_in_bounds(east: float, up: float, north: float) -> bool:
	return is_finite(east) and is_finite(up) and is_finite(north) and absf(east) <= MAX_LOCAL_COMPONENT_M and absf(up) <= MAX_LOCAL_COMPONENT_M and absf(north) <= MAX_LOCAL_COMPONENT_M

static func _dot(left: PackedFloat64Array, right: PackedFloat64Array) -> float:
	return left[0] * right[0] + left[1] * right[1] + left[2] * right[2]

static func _is_finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
