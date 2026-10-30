extends SceneTree

const Address := preload("res://terrain/wfg1_tile_address.gd")
const LocalFrame := preload("res://terrain/wfg1_local_frame.gd")
const RasterTransform := preload("res://terrain/wfg1_raster_geotransform_v1.gd")

var _checks := 0
var _failures := 0

func _initialize() -> void:
	_run_suite()
	print("WF_WFG1_ADDRESS_TEST_RESULT=%s checks=%d failures=%d" % ["PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(1 if _failures > 0 else 0)

func _run_suite() -> void:
	print("WF_WFG1_ADDRESS_TEST_SUITE=address-geodesy-origin")
	_test_addresses()
	_test_ecef_and_local_frames()
	_test_height_datum_fail_closed()
	_test_raster_geotransform_registration()

func _test_addresses() -> void:
	var anti_meridian_west := Address.address_for_lon_lat(-180.0, 0.0)
	var anti_meridian_east := Address.address_for_lon_lat(180.0, 0.0)
	_check(anti_meridian_west.get("ok", false) and anti_meridian_east.get("ok", false), "antimeridian limit coordinates are accepted")
	_check(anti_meridian_west["address"] == anti_meridian_east["address"], "exact +180 longitude normalizes to the -180 cell")
	_check(Address.format_id(anti_meridian_east["address"]) == "wfg1:0:0:360", "canonical ID uses normalized longitude and level-zero row")

	var exact_equator_boundary := Address.address_for_lon_lat(0.0, 0.0)
	_check(exact_equator_boundary["address"]["x"] == 720 and exact_equator_boundary["address"]["y"] == 360, "exact cell boundaries belong to the east and north half-open cell")
	var negative_boundary := Address.address_for_lon_lat(-0.25, -0.25)
	_check(negative_boundary["address"]["x"] == 719 and negative_boundary["address"]["y"] == 359, "negative boundary-adjacent coordinates belong to the western and southern cell")

	var north_pole := Address.address_for_lon_lat(73.0, 90.0)
	var south_pole := Address.address_for_lon_lat(-122.0, -90.0)
	_check(north_pole.get("ok", false) and north_pole["address"]["y"] == 719, "exact +90 latitude maps to the final level-zero row")
	_check(south_pole.get("ok", false) and south_pole["address"]["y"] == 0, "exact -90 latitude maps to the first level-zero row")
	var pole_addresses_match := true
	for pole_longitude in [-180.0, -122.0, 0.0, 73.0, 179.999, 180.0]:
		var north_address := Address.address_for_lon_lat(float(pole_longitude), 90.0)
		var south_address := Address.address_for_lon_lat(float(pole_longitude), -90.0)
		pole_addresses_match = pole_addresses_match and north_address.get("ok", false) and south_address.get("ok", false) and north_address["address"] == north_pole["address"] and south_address["address"] == south_pole["address"]
	_check(pole_addresses_match and int(north_pole["address"]["x"]) == 720 and int(south_pole["address"]["x"]) == 720, "all exact-pole longitudes use canonical center meridian ownership")

	var australia := Address.address_for_lon_lat(153.025, -27.475)
	var nigeria := Address.address_for_lon_lat(7.5, 9.0)
	var greenland := Address.address_for_lon_lat(-42.0, 73.0)
	_check(australia.get("ok", false) and nigeria.get("ok", false) and greenland.get("ok", false), "remote Australia, Nigeria, and Greenland coordinates are globally addressable")
	_check(australia["address"] != nigeria["address"] and nigeria["address"] != greenland["address"], "remote coordinates resolve to distinct global cells")

	var fine := Address.address_for_lon_lat(-76.75, 39.25, 4)
	_check(fine.get("ok", false) and fine["address"]["level"] == 4, "finer tile level is independent of source sample spacing")
	var fine_bounds: Dictionary = Address.bounds_for_address(fine["address"])
	_check(fine_bounds.get("ok", false) and is_equal_approx(float(fine_bounds["longitude_width_deg"]), 0.015625), "tile bounds subdivide level-zero cells by powers of two")
	_check(float(fine_bounds["west_deg"]) <= -76.75 and -76.75 < float(fine_bounds["east_deg"]), "finer tile bounds contain their addressed longitude")
	var fine_parent := Address.parent_address(fine["address"])
	var fine_children := Address.child_addresses(fine_parent["address"])
	_check(fine_parent.get("ok", false) and fine_parent["address"]["level"] == 3, "hierarchical parent reduces address level without changing the world")
	_check(fine_children.get("ok", false) and fine_children["addresses"].has(fine["address"]), "four child addresses cover their parent tile")

	var eastern_edge := Address.address_for_lon_lat(179.875, 12.0)
	var edge_bounds: Dictionary = Address.bounds_for_address(eastern_edge["address"])
	_check(float(edge_bounds["east_deg"]) == 180.0 and float(edge_bounds["west_deg"]) < 180.0, "eastern edge tile terminates at +180 without crossing the antimeridian")
	var north_bounds: Dictionary = Address.bounds_for_address(north_pole["address"])
	_check(float(north_bounds["north_deg"]) == 90.0 and bool(north_bounds["north_inclusive"]), "only the polar global north edge is north-inclusive")
	var wrapped_neighbors := Address.cardinal_neighbors(anti_meridian_west["address"])
	_check(wrapped_neighbors.get("ok", false) and wrapped_neighbors["neighbors"]["west"]["x"] == 1439, "same-level west neighbor wraps across the antimeridian")
	var south_neighbors := Address.cardinal_neighbors(south_pole["address"])
	_check(south_neighbors["neighbors"]["south"].is_empty(), "south polar edge has no neighbor outside the globe")
	var north_neighbors := Address.cardinal_neighbors(north_pole["address"])
	_check(north_neighbors["neighbors"]["north"].is_empty(), "north polar edge has no neighbor outside the globe")

	var tile_id := Address.format_id(fine["address"])
	var round_trip := Address.parse_id(tile_id)
	_check(round_trip.get("ok", false) and round_trip["address"] == fine["address"], "canonical tile ID parse/format round-trips")
	_check(not Address.parse_id("wfg1:04:0001:0002").get("ok", false), "parser rejects IDs with leading zeroes")
	_check(not Address.parse_id("wfg1:-0:0:0").get("ok", false), "parser rejects negative zero")
	_check(not Address.parse_id("wfg1:1:+1:0").get("ok", false), "parser rejects a plus sign in canonical integer fields")
	_check(not Address.parse_id("WFG1:0:0:0").get("ok", false), "parser rejects noncanonical tile scheme spelling")

	_check(not Address.address_for_lon_lat(180.00001, 0.0).get("ok", false), "address lookup rejects out-of-range longitude instead of wrapping unknown input")
	_check(not Address.address_for_lon_lat(0.0, 90.00001).get("ok", false), "address lookup rejects out-of-range latitude")
	_check(not Address.address_for_lon_lat(INF, 0.0).get("ok", false), "address lookup rejects non-finite longitude")
	_check(not Address.address_for_lon_lat(0.0, NAN).get("ok", false), "address lookup rejects non-finite latitude")
	_check(not Address.address_for_lon_lat(0.0, 0.0, 17).get("ok", false), "address lookup rejects unsupported address levels")
	_check(not Address.validate_address({"scheme": "WFG-1", "level": 0, "x": 1440, "y": 0}).get("ok", false), "address validation rejects x outside the global grid")
	_check(not Address.validate_address({"scheme": "WFG-1", "level": 0, "x": 0, "y": 720}).get("ok", false), "address validation rejects y outside the global grid")
	_check(not Address.validate_address({"scheme": "WFG-1", "level": 0.5, "x": 0, "y": 0}).get("ok", false), "address validation rejects a fractional level")

func _test_ecef_and_local_frames() -> void:
	var reference := LocalFrame.geodetic_to_ecef_components(45.0, 45.0, 0.0, "EPSG:4326", LocalFrame.ELLIPSOIDAL_DATUM, "ellipsoidal")
	_check(reference.get("ok", false), "WGS84 scalar ECEF accepts a reference coordinate")
	if reference.get("ok", false):
		var ecef: PackedFloat64Array = reference["ecef_m"]
		var expected := PackedFloat64Array([3194419.1450605746, 3194419.1450605746, 4487348.4088659203])
		_check(_packed_distance(ecef, expected) <= 0.0001, "scalar WGS84 ECEF matches independent PROJ vector within 0.1 mm")
		_check(typeof(reference["ecef_m"]) == TYPE_PACKED_FLOAT64_ARRAY, "global ECEF remains in PackedFloat64Array rather than Vector3")

	var negative_height := LocalFrame.geodetic_to_ecef_components(-60.0, 170.0, -4000.0, "EPSG:4326", LocalFrame.ELLIPSOIDAL_DATUM, "ellipsoidal")
	_check(negative_height.get("ok", false), "WGS84 scalar ECEF accepts negative ellipsoidal height")
	if negative_height.get("ok", false):
		var expected_negative := PackedFloat64Array([-3146563.7688875725, 554824.0889745936, -5497013.0323235011])
		_check(_packed_distance(negative_height["ecef_m"], expected_negative) <= 0.0001, "negative-height ECEF matches independent PROJ vector within 0.1 mm")

	var origin := LocalFrame.create_origin(39.29, -76.61, 50.0)
	var nearby := LocalFrame.geodetic_to_ecef_components(39.29, -76.61, 60.0, "EPSG:4326", LocalFrame.ELLIPSOIDAL_DATUM, "ellipsoidal")
	_check(origin.get("ok", false) and nearby.get("ok", false), "local render origin and a nearby point are established")
	if origin.get("ok", false) and nearby.get("ok", false):
		var local_result := LocalFrame.ecef_to_local(nearby["ecef_m"], origin)
		_check(local_result.get("ok", false), "global ECEF point is converted only after local-origin subtraction")
		if local_result.get("ok", false):
			var local_position: Vector3 = local_result["local_engine_m"]
			_check(absf(local_position.x) < 0.0001 and absf(local_position.z) < 0.0001 and absf(local_position.y - 10.0) < 0.0001, "same-location height delta maps to local up without global Vector3 coordinates")
		var transform_result := LocalFrame.tile_transform(origin, origin)
		_check(transform_result.get("ok", false) and transform_result["transform"].origin.length() == 0.0, "rebasing a tile to its own origin yields zero translation")

	var anti_origin := LocalFrame.create_origin(80.0, 180.0, 0.0)
	_check(anti_origin.get("ok", false) and float(anti_origin["longitude_deg"]) == -180.0, "ECEF origin longitude is normalized at the antimeridian")
	var anti_origin_from_west := LocalFrame.create_origin(80.0, -180.0, 0.0)
	_check(anti_origin.get("ok", false) and anti_origin_from_west.get("ok", false) and anti_origin["ecef_m"] == anti_origin_from_west["ecef_m"], "+180 and -180 create identical normalized ECEF origin components")
	var polar_origin := LocalFrame.create_origin(90.0, 17.0, 0.0)
	_check(polar_origin.get("ok", false) and float(polar_origin["latitude_deg"]) == 90.0, "WGS84 tangent origin supports the north pole")

	var inconsistent_ecef: Dictionary = origin.duplicate(true)
	var inconsistent_components: PackedFloat64Array = inconsistent_ecef["ecef_m"]
	inconsistent_components[0] += 0.01
	inconsistent_ecef["ecef_m"] = inconsistent_components
	_check(not LocalFrame.ecef_to_local(nearby["ecef_m"], inconsistent_ecef).get("ok", false), "local conversion rejects a frame whose ECEF origin contradicts its geodetic coordinates")
	var inconsistent_basis: Dictionary = origin.duplicate(true)
	inconsistent_basis["sin_latitude"] = float(inconsistent_basis["sin_latitude"]) + 0.01
	_check(not LocalFrame.ecef_to_local(nearby["ecef_m"], inconsistent_basis).get("ok", false), "local conversion rejects a tangent basis inconsistent with its stored latitude")

	var remote_tile := LocalFrame.create_origin(-27.0, 153.0, 0.0)
	var remote_render_origin := LocalFrame.create_origin(-27.0, 152.5, 0.0)
	var remote_transform := LocalFrame.tile_transform(remote_tile, remote_render_origin)
	_check(remote_transform.get("ok", false), "remote neighboring regions receive a WGS84 tile-to-render transform")
	if remote_transform.get("ok", false):
		var remote_x_axis: Vector3 = remote_transform["transform"].basis.x
		var remote_y_axis: Vector3 = remote_transform["transform"].basis.y
		var remote_z_axis: Vector3 = remote_transform["transform"].basis.z
		_check(remote_transform["transform"].origin.x > 40_000.0 and remote_transform["transform"].origin.x < 60_000.0, "remote tile translation is the expected local eastward scale")
		_check(absf(remote_x_axis.length() - 1.0) < 0.000000001 and absf(remote_y_axis.length() - 1.0) < 0.000000001 and absf(remote_z_axis.length() - 1.0) < 0.000000001 and absf(remote_transform["transform"].basis.determinant() - 1.0) < 0.000000001, "remote tangent-frame basis remains orthonormal and right-handed")

	var date_line_tile := LocalFrame.create_origin(80.0, -179.5, 0.0)
	var date_line_origin := LocalFrame.create_origin(80.0, 179.5, 0.0)
	var date_line_transform := LocalFrame.tile_transform(date_line_tile, date_line_origin)
	_check(date_line_transform.get("ok", false) and date_line_transform["transform"].origin.x > 15_000.0 and date_line_transform["transform"].origin.length() < 30_000.0, "antimeridian transform uses the short normalized eastward route")

	var north_pole_tile := LocalFrame.create_origin(90.0, 0.0, 0.0)
	var north_pole_render := LocalFrame.create_origin(90.0, 90.0, 0.0)
	var pole_transform := LocalFrame.tile_transform(north_pole_tile, north_pole_render)
	_check(pole_transform.get("ok", false) and pole_transform["transform"].origin.length() <= 0.000001, "north-pole tile origins remain coincident when longitude basis changes")
	if pole_transform.get("ok", false):
		_check(pole_transform["transform"].basis.x.z > 0.999999 and absf(pole_transform["transform"].basis.determinant() - 1.0) < 0.000000001, "north-pole tangent basis follows longitude orientation without reflection")

	var equator_origin := LocalFrame.create_origin(0.0, 0.0, 0.0)
	var boundary_point := PackedFloat64Array([LocalFrame.SEMI_MAJOR_AXIS_M, LocalFrame.MAX_LOCAL_COMPONENT_M, 0.0])
	var boundary_local := LocalFrame.ecef_to_local(boundary_point, equator_origin)
	var outside_point := PackedFloat64Array([LocalFrame.SEMI_MAJOR_AXIS_M, LocalFrame.MAX_LOCAL_COMPONENT_M + 0.01, 0.0])
	_check(boundary_local.get("ok", false) and absf(float(boundary_local["local_engine_m"].x) - LocalFrame.MAX_LOCAL_COMPONENT_M) <= 0.000001, "the documented 250 km local-render boundary is inclusive")
	_check(not LocalFrame.ecef_to_local(outside_point, equator_origin).get("ok", false), "a point beyond the local-render boundary requires rebasing")
	var far_frame := LocalFrame.create_origin(-27.0, 153.0, 0.0)
	_check(not LocalFrame.tile_transform(far_frame, equator_origin).get("ok", false), "remote tile transform fails closed until render origin is rebased near it")

	_check(not LocalFrame.geodetic_to_ecef_components(0.0, 0.0, 0.0, "EPSG:3857", LocalFrame.ELLIPSOIDAL_DATUM, "ellipsoidal").get("ok", false), "scalar ECEF rejects an unsupported CRS")
	_check(not LocalFrame.geodetic_to_ecef_components(0.0, 0.0, 0.0, "EPSG:4326", "", "unknown").get("ok", false), "scalar ECEF rejects an unknown vertical datum")
	_check(not LocalFrame.ecef_to_local(PackedFloat64Array([0.0, 0.0, 0.0]), origin).get("ok", false), "local conversion rejects the geocentric singularity")
	_check(not LocalFrame.ecef_to_local(PackedFloat64Array([1.0, 2.0]), origin).get("ok", false), "local conversion rejects malformed ECEF component count")

func _test_height_datum_fail_closed() -> void:
	var egm_conversion := LocalFrame.orthometric_to_ellipsoidal_height(-20.0, 35.0, "EGM2008", "EGM2008")
	_check(egm_conversion.get("ok", false) and is_equal_approx(float(egm_conversion["ellipsoidal_height_m"]), 15.0), "explicit EGM2008 conversion uses h = H + N, including negative orthometric height")
	_check(not LocalFrame.orthometric_to_ellipsoidal_height(-20.0, 35.0, "NAVD88", "EGM2008").get("ok", false), "orthometric conversion rejects unsupported NAVD88 rather than treating it as EGM2008")
	_check(not LocalFrame.orthometric_to_ellipsoidal_height(-20.0, 35.0, "MEAN_SEA_LEVEL", "EGM2008").get("ok", false), "orthometric conversion rejects nominal MSL without an explicit supported operation")
	_check(not LocalFrame.orthometric_to_ellipsoidal_height(-20.0, INF, "EGM2008", "EGM2008").get("ok", false), "orthometric conversion rejects non-finite geoid values")

func _test_raster_geotransform_registration() -> void:
	var corner_transform := {
		"horizontal_crs": "EPSG:4326",
		"axis_order": ["longitude", "latitude"],
		"affine": {"x_origin": 2.2495833333333333, "y_origin": 48.999583333333334, "pixel_width": 0.0008333333333333334, "rotation_x": 0.0, "rotation_y": 0.0, "pixel_height": -0.0008333333333333334},
		"origin_reference": "pixel_corner",
		"pixel_registration": "point",
		"sample_coordinate_rule": "row_col_plus_half"
	}
	var parsed_corner := RasterTransform.validate_transform(corner_transform, 300, 300)
	_check(parsed_corner.get("ok", false), "point raster with explicit pixel-corner origin validates before sampling")
	if parsed_corner.get("ok", false):
		var first_point := RasterTransform.sample_lon_lat(parsed_corner, 0, 0)
		var last_point := RasterTransform.sample_lon_lat(parsed_corner, 299, 299)
		_check(first_point.get("ok", false) and absf(float(first_point["longitude_deg"]) - 2.25) < 1.0e-12 and absf(float(first_point["latitude_deg"]) - 48.99916666666667) < 1.0e-12, "corner-origin point raster applies exactly one declared half-pixel offset")
		var point_address := Address.address_for_lon_lat(float(first_point["longitude_deg"]), float(first_point["latitude_deg"]))
		_check(point_address.get("ok", false) and point_address["address"] == {"scheme": "WFG-1", "level": 0, "x": 729, "y": 555}, "corner-origin source sample maps inside its WFG-1 address after declared registration")
		_check(last_point.get("ok", false) and absf(float(last_point["longitude_deg"]) - 2.4991666666666665) < 1.0e-12 and absf(float(last_point["latitude_deg"]) - 48.75) < 1.0e-12, "last corner-origin sample retains its affine-derived coordinates without edge clamping")
	var mismatched_rule := corner_transform.duplicate(true)
	mismatched_rule["sample_coordinate_rule"] = "row_col"
	_check(not RasterTransform.validate_transform(mismatched_rule, 300, 300).get("ok", false), "corner-origin raster rejects a center-sample rule mismatch")
	var implicit_rule := corner_transform.duplicate(true)
	implicit_rule.erase("sample_coordinate_rule")
	var normalized_rule := RasterTransform.validate_transform(implicit_rule, 300, 300)
	var implicit_first := RasterTransform.sample_lon_lat(normalized_rule, 0, 0) if normalized_rule.get("ok", false) else {"ok": false}
	_check(normalized_rule.get("ok", false) and bool(normalized_rule.get("sample_coordinate_rule_was_derived", false)) and implicit_first.get("ok", false) and absf(float(implicit_first["longitude_deg"]) - 2.25) < 1.0e-12, "adapter derives only the contract-defined corner rule from explicit pixel_corner origin and records that normalization")
	var center_transform := corner_transform.duplicate(true)
	center_transform["origin_reference"] = "pixel_center"
	center_transform["sample_coordinate_rule"] = "row_col"
	var parsed_center := RasterTransform.validate_transform(center_transform, 300, 300)
	var center_point := RasterTransform.sample_lon_lat(parsed_center, 0, 0) if parsed_center.get("ok", false) else {"ok": false}
	_check(parsed_center.get("ok", false) and center_point.get("ok", false) and float(center_point["longitude_deg"]) == 2.2495833333333333, "center-origin raster preserves the declared first sample coordinate with no inferred offset")
	var missing_origin := corner_transform.duplicate(true)
	missing_origin.erase("origin_reference")
	_check(not RasterTransform.validate_transform(missing_origin, 300, 300).get("ok", false), "raster with unspecified origin reference fails closed")

func _packed_distance(left: PackedFloat64Array, right: PackedFloat64Array) -> float:
	if left.size() != 3 or right.size() != 3:
		return INF
	var dx := left[0] - right[0]
	var dy := left[1] - right[1]
	var dz := left[2] - right[2]
	return sqrt(dx * dx + dy * dy + dz * dz)

func _check(condition: bool, description: String) -> void:
	_checks += 1
	if condition:
		print("PASS  %s" % description)
	else:
		_failures += 1
		push_error("FAIL  %s" % description)
