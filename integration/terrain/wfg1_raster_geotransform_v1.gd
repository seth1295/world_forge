class_name Wfg1RasterGeotransformV1
extends RefCounted

## Typed WGS84 geographic raster transform. The sample-coordinate rule must
## match the declared affine origin; no half-cell shift is inferred.
const MAX_RASTER_SAMPLES := 10_000_000

static func validate_transform(value: Variant, rows: int, columns: int) -> Dictionary:
	if rows < 1 or columns < 1 or rows > MAX_RASTER_SAMPLES / columns:
		return _failure("raster dimensions exceed the finite sample limit")
	if typeof(value) != TYPE_DICTIONARY:
		return _failure("raster geotransform must be an object")
	if String(value.get("horizontal_crs", "")) != "EPSG:4326" or value.get("axis_order", []) != ["longitude", "latitude"]:
		return _failure("raster geotransform requires EPSG:4326 longitude/latitude axes")
	var affine: Variant = value.get("affine")
	if typeof(affine) != TYPE_DICTIONARY:
		return _failure("raster affine must be a named coefficient object")
	for coefficient in ["x_origin", "y_origin", "pixel_width", "rotation_x", "rotation_y", "pixel_height"]:
		if not affine.has(coefficient) or typeof(affine[coefficient]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(affine[coefficient])):
			return _failure("raster affine lacks finite %s" % coefficient)
	if float(affine["x_origin"]) < -180.0 or float(affine["x_origin"]) > 180.0 or float(affine["y_origin"]) < -90.0 or float(affine["y_origin"]) > 90.0:
		return _failure("raster affine origin is outside WGS84 geographic bounds")
	if float(affine["pixel_width"]) == 0.0 or float(affine["pixel_height"]) == 0.0:
		return _failure("raster affine pixel spacing must be nonzero")
	var origin_reference := String(value.get("origin_reference", ""))
	var registration := String(value.get("pixel_registration", ""))
	var coordinate_rule := String(value.get("sample_coordinate_rule", ""))
	if origin_reference not in ["pixel_corner", "pixel_center"] or registration not in ["area", "point"]:
		return _failure("raster transform requires explicit origin reference and pixel registration")
	var expected_rule := "row_col_plus_half" if origin_reference == "pixel_corner" else "row_col"
	var coordinate_rule_was_derived := coordinate_rule.is_empty()
	if coordinate_rule_was_derived:
		# The canonical WFG raster contract defines this exact relationship; the
		# raw generator may predate the explicit field while still declaring the
		# origin reference. Preserve the provenance distinction in the result.
		coordinate_rule = expected_rule
	if coordinate_rule != expected_rule:
		return _failure("raster sample_coordinate_rule contradicts origin_reference")
	return {
		"ok": true,
		"error": "",
		"rows": rows,
		"columns": columns,
		"horizontal_crs": "EPSG:4326",
		"axis_order": "longitude_latitude",
		"affine": affine.duplicate(true),
		"origin_reference": origin_reference,
		"pixel_registration": registration,
		"sample_coordinate_rule": coordinate_rule,
		"sample_coordinate_rule_was_derived": coordinate_rule_was_derived,
		"column_offset": 0.5 if coordinate_rule == "row_col_plus_half" else 0.0,
		"row_offset": 0.5 if coordinate_rule == "row_col_plus_half" else 0.0
	}

static func sample_lon_lat(transform: Dictionary, row: int, column: int) -> Dictionary:
	var rows := int(transform.get("rows", 0))
	var columns := int(transform.get("columns", 0))
	if row < 0 or row >= rows or column < 0 or column >= columns:
		return _failure("raster sample index is outside its declared dimensions")
	var affine: Dictionary = transform.get("affine", {})
	var column_coordinate := float(column) + float(transform.get("column_offset", NAN))
	var row_coordinate := float(row) + float(transform.get("row_offset", NAN))
	var longitude := float(affine.get("x_origin", NAN)) + column_coordinate * float(affine.get("pixel_width", NAN)) + row_coordinate * float(affine.get("rotation_x", NAN))
	var latitude := float(affine.get("y_origin", NAN)) + column_coordinate * float(affine.get("rotation_y", NAN)) + row_coordinate * float(affine.get("pixel_height", NAN))
	if not is_finite(longitude) or not is_finite(latitude) or longitude < -180.0 or longitude > 180.0 or latitude < -90.0 or latitude > 90.0:
		return _failure("raster sample coordinate is outside WGS84 bounds")
	return {"ok": true, "error": "", "longitude_deg": longitude, "latitude_deg": latitude}

static func coordinate_to_sample_index(transform: Dictionary, longitude_deg: float, latitude_deg: float) -> Dictionary:
	if not is_finite(longitude_deg) or not is_finite(latitude_deg) or longitude_deg < -180.0 or longitude_deg > 180.0 or latitude_deg < -90.0 or latitude_deg > 90.0:
		return _failure("coordinate must be finite WGS84 longitude/latitude")
	var affine: Dictionary = transform.get("affine", {})
	var dx := longitude_deg - float(affine.get("x_origin", NAN))
	var dy := latitude_deg - float(affine.get("y_origin", NAN))
	var a := float(affine.get("pixel_width", NAN))
	var b := float(affine.get("rotation_x", NAN))
	var c := float(affine.get("rotation_y", NAN))
	var d := float(affine.get("pixel_height", NAN))
	var determinant := a * d - b * c
	if not is_finite(determinant) or absf(determinant) <= 1.0e-30:
		return _failure("raster affine is singular")
	var column_coordinate := (dx * d - dy * b) / determinant - float(transform.get("column_offset", NAN))
	var row_coordinate := (dy * a - dx * c) / determinant - float(transform.get("row_offset", NAN))
	if not is_finite(column_coordinate) or not is_finite(row_coordinate):
		return _failure("raster inverse affine produced a non-finite sample index")
	return {"ok": true, "error": "", "column_index": column_coordinate, "row_index": row_coordinate}

static func axis_aligned_pixel_center_affine(transform: Dictionary) -> Dictionary:
	var affine: Dictionary = transform.get("affine", {})
	if absf(float(affine.get("rotation_x", NAN))) > 1.0e-15 or absf(float(affine.get("rotation_y", NAN))) > 1.0e-15:
		return _failure("axis-aligned pixel-center affine is required by this renderer")
	var center := sample_lon_lat(transform, 0, 0)
	if not center.get("ok", false):
		return center
	return {
		"ok": true,
		"error": "",
		"x_origin_deg": float(center["longitude_deg"]),
		"y_origin_deg": float(center["latitude_deg"]),
		"pixel_width_deg": float(affine["pixel_width"]),
		"pixel_height_deg": float(affine["pixel_height"])
	}

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
