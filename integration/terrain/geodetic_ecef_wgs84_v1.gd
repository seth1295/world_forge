class_name Wgs84GeodeticEcefV1
extends RefCounted

const CRS_GEOGRAPHIC_3D := "EPSG:4979"
const CRS_GEOCENTRIC := "EPSG:4978"
const SEMI_MAJOR_AXIS_M := 6_378_137.0
const INVERSE_FLATTENING := 298.257223563
const FLATTENING := 1.0 / INVERSE_FLATTENING
const SEMI_MINOR_AXIS_M := SEMI_MAJOR_AXIS_M * (1.0 - FLATTENING)
const FIRST_ECCENTRICITY_SQUARED := FLATTENING * (2.0 - FLATTENING)
const SECOND_ECCENTRICITY_SQUARED := (SEMI_MAJOR_AXIS_M * SEMI_MAJOR_AXIS_M - SEMI_MINOR_AXIS_M * SEMI_MINOR_AXIS_M) / (SEMI_MINOR_AXIS_M * SEMI_MINOR_AXIS_M)
const MIN_LATITUDE_DEG := -90.0
const MAX_LATITUDE_DEG := 90.0
const MIN_LONGITUDE_DEG := -180.0
const MAX_LONGITUDE_DEG := 180.0
const MIN_ELLIPSOIDAL_HEIGHT_M := -12_000.0
const MAX_ELLIPSOIDAL_HEIGHT_M := 100_000_000.0
const MIN_ECEF_RADIUS_M := SEMI_MINOR_AXIS_M + MIN_ELLIPSOIDAL_HEIGHT_M
const MAX_ECEF_RADIUS_M := SEMI_MAJOR_AXIS_M + MAX_ELLIPSOIDAL_HEIGHT_M
const POLAR_AXIS_EPSILON_M := 1.0e-9
const ITERATION_EPSILON_RAD := 1.0e-14
const MAX_INVERSE_ITERATIONS := 12

## Convert WGS 84 geographic latitude/longitude and ellipsoidal height to geocentric XYZ.
## Inputs are degrees and metres. This performs only the WGS 84 ellipsoid conversion;
## it does not transform a different horizontal datum or vertical height datum.
static func geodetic_to_ecef(latitude_deg: float, longitude_deg: float, ellipsoidal_height_m: float) -> Dictionary:
    if not is_finite(latitude_deg) or latitude_deg < MIN_LATITUDE_DEG or latitude_deg > MAX_LATITUDE_DEG:
        return _failure("latitude_deg must be finite and within [-90, 90]")
    if not is_finite(longitude_deg) or longitude_deg < MIN_LONGITUDE_DEG or longitude_deg > MAX_LONGITUDE_DEG:
        return _failure("longitude_deg must be finite and within [-180, 180]")
    if not is_finite(ellipsoidal_height_m) or ellipsoidal_height_m < MIN_ELLIPSOIDAL_HEIGHT_M or ellipsoidal_height_m > MAX_ELLIPSOIDAL_HEIGHT_M:
        return _failure("ellipsoidal_height_m is outside the declared WGS 84 conversion bounds")

    var latitude_rad := deg_to_rad(latitude_deg)
    var longitude_rad := deg_to_rad(longitude_deg)
    var sin_latitude := sin(latitude_rad)
    var cos_latitude := cos(latitude_rad)
    var prime_vertical_radius := SEMI_MAJOR_AXIS_M / sqrt(1.0 - FIRST_ECCENTRICITY_SQUARED * sin_latitude * sin_latitude)
    var x := (prime_vertical_radius + ellipsoidal_height_m) * cos_latitude * cos(longitude_rad)
    var y := (prime_vertical_radius + ellipsoidal_height_m) * cos_latitude * sin(longitude_rad)
    var z := (prime_vertical_radius * (1.0 - FIRST_ECCENTRICITY_SQUARED) + ellipsoidal_height_m) * sin_latitude
    var ecef := Vector3(x, y, z)
    if not _is_finite_vector(ecef) or ecef.length() < MIN_ECEF_RADIUS_M or ecef.length() > MAX_ECEF_RADIUS_M:
        return _failure("converted ECEF point is outside the declared radius bounds")
    return {"ok": true, "crs": CRS_GEOCENTRIC, "ecef_m": ecef, "error": ""}

## Convert geocentric WGS 84 XYZ metres to latitude, longitude and ellipsoidal height.
## The geocentric origin is singular and is rejected; returned longitude is zero at a pole.
static func ecef_to_geodetic(ecef_m: Vector3) -> Dictionary:
    if not _is_finite_vector(ecef_m):
        return _failure("ECEF components must be finite")
    var radius := ecef_m.length()
    if not is_finite(radius) or radius < MIN_ECEF_RADIUS_M or radius > MAX_ECEF_RADIUS_M:
        return _failure("ECEF radius is outside the declared WGS 84 conversion bounds")

    var horizontal_radius := sqrt(ecef_m.x * ecef_m.x + ecef_m.y * ecef_m.y)
    var latitude_rad: float
    var longitude_deg := 0.0
    var height_m: float
    if horizontal_radius <= POLAR_AXIS_EPSILON_M:
        latitude_rad = PI * 0.5 if ecef_m.z >= 0.0 else -PI * 0.5
        height_m = absf(ecef_m.z) - SEMI_MINOR_AXIS_M
    else:
        longitude_deg = rad_to_deg(atan2(ecef_m.y, ecef_m.x))
        latitude_rad = atan2(ecef_m.z, horizontal_radius * (1.0 - FIRST_ECCENTRICITY_SQUARED))
        height_m = 0.0
        for _iteration in range(MAX_INVERSE_ITERATIONS):
            var sin_latitude := sin(latitude_rad)
            var cos_latitude := cos(latitude_rad)
            var prime_vertical_radius := SEMI_MAJOR_AXIS_M / sqrt(1.0 - FIRST_ECCENTRICITY_SQUARED * sin_latitude * sin_latitude)
            if absf(cos_latitude) <= POLAR_AXIS_EPSILON_M:
                height_m = absf(ecef_m.z) - SEMI_MINOR_AXIS_M
                break
            height_m = horizontal_radius / cos_latitude - prime_vertical_radius
            var denominator := horizontal_radius - FIRST_ECCENTRICITY_SQUARED * prime_vertical_radius * cos_latitude
            var next_latitude_rad := atan2(ecef_m.z, denominator)
            if absf(next_latitude_rad - latitude_rad) <= ITERATION_EPSILON_RAD:
                latitude_rad = next_latitude_rad
                break
            latitude_rad = next_latitude_rad
        var final_sin_latitude := sin(latitude_rad)
        var final_cos_latitude := cos(latitude_rad)
        var final_prime_vertical_radius := SEMI_MAJOR_AXIS_M / sqrt(1.0 - FIRST_ECCENTRICITY_SQUARED * final_sin_latitude * final_sin_latitude)
        if absf(final_cos_latitude) > POLAR_AXIS_EPSILON_M:
            height_m = horizontal_radius / final_cos_latitude - final_prime_vertical_radius
        else:
            height_m = absf(ecef_m.z) - SEMI_MINOR_AXIS_M

    var latitude_deg := rad_to_deg(latitude_rad)
    if longitude_deg <= MIN_LONGITUDE_DEG:
        longitude_deg = MAX_LONGITUDE_DEG
    if not is_finite(latitude_deg) or not is_finite(longitude_deg) or not is_finite(height_m):
        return _failure("inverse conversion produced a non-finite coordinate")
    if latitude_deg < MIN_LATITUDE_DEG or latitude_deg > MAX_LATITUDE_DEG or longitude_deg < MIN_LONGITUDE_DEG or longitude_deg > MAX_LONGITUDE_DEG:
        return _failure("inverse conversion produced a coordinate outside geographic bounds")
    if height_m < MIN_ELLIPSOIDAL_HEIGHT_M or height_m > MAX_ELLIPSOIDAL_HEIGHT_M:
        return _failure("inverse ellipsoidal height is outside the declared bounds")
    return {
        "ok": true,
        "crs": CRS_GEOGRAPHIC_3D,
        "latitude_deg": latitude_deg,
        "longitude_deg": longitude_deg,
        "ellipsoidal_height_m": height_m,
        "error": ""
    }

static func _is_finite_vector(value: Vector3) -> bool:
    return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

static func _failure(message: String) -> Dictionary:
    return {"ok": false, "error": message}