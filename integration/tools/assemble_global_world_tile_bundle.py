'''Assemble immutable terrain/feature producer artifacts as Global World Tile Bundle v1.'''

from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any
CONTRACT_ID = 'urn:worldforge:global-world-tile-bundle:1.0.0'
CONTRACT_VERSION = '1.0.0'
SOURCE_ID = 'worldforge-global-world-v1'
ASSEMBLER_ID = 'WorldForge Global World Bundle Assembler'
ASSEMBLER_VERSION = '0.1.0'
TERRAIN_COMMIT = '6d4cf589a278b5e2eea668c25bc43469f4d45791'
FEATURE_COMMIT = '6d4cf589a278b5e2eea668c25bc43469f4d45791'
GEOID_SHA256 = '4191d471eefebf24091b56dbc604353cb3b8cf8cc70e448bb9ae56a272bef17a'
GEOID_ID = 'OSGeo-PROJ-data/us_nga_egm08_25.tif'
LAYER_IDS = ('terrain', 'roads', 'buildings', 'water', 'landcover', 'vegetation')
VALID_STATUSES = {'ready', 'failed', 'partial', 'cancelled', 'not_generated', 'no_source_coverage'}
POLICY_PROFILE_ID = 'worldforge.global-world.v1.default'
MAX_MANIFEST_BYTES = 16777216
MAX_BUNDLE_BYTES = 4294967296
MAX_PAYLOAD_BYTES = 1073741824
MAX_VECTOR_LAYER_BYTES = 2147483648
MAX_VECTOR_SHARD_BYTES = 16777216
MAX_RASTER_SAMPLES = 10000000
MAX_VECTOR_FEATURES = 2000000
MAX_LAYER_SHARDS = 65536
MAX_BUNDLE_DESCRIPTORS = 65536
MAX_PAYLOAD_PATH_CHARS = 1024
MAX_DECODED_GEOMETRY_BYTES = 4294967296
MAX_VECTOR_COORDINATE_POSITIONS = 50000000

class BundleError(RuntimeError):
    pass

def _pairs_no_duplicates(pairs: 'list[tuple[str, Any]]') -> 'dict[str, Any]':
    result = {}
    for key, value in pairs:
        if key in result:
            raise BundleError(f'duplicate JSON object key: {key}')
        result[key] = value
    return result

def read_json(path: 'Path') -> 'dict[str, Any]':
    if path.stat().st_size > MAX_MANIFEST_BYTES:
        raise BundleError(f'manifest exceeds {MAX_MANIFEST_BYTES} byte consumer limit: {path}')
    try:
        value = json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=_pairs_no_duplicates)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BundleError(f'cannot read UTF-8 manifest {path}: {exc}') from exc
    if not isinstance(value, dict):
        raise BundleError(f'manifest root must be an object: {path}')
    return value

def reject_reparse_path(path: 'Path') -> 'None':
    absolute = path.absolute()
    for component in reversed((absolute, *absolute.parents)):
        if not is_reparse_or_link(component):
            continue
        raise BundleError(f'producer manifest path contains a symlink or reparse point: {component}')

def sha256_file(path: 'Path') -> 'str':
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter((lambda: stream.read(4194304)), b''):
            digest.update(block)
    return digest.hexdigest()

def is_reparse_or_link(path: 'Path') -> 'bool':
    if path.is_symlink():
        return True
    junction_probe = getattr(path, 'is_junction', None)
    if callable(junction_probe):
        return bool(junction_probe())
    return False

def safe_payload(source_root: Path, relative: str) -> Path:
    if not isinstance(relative, str) or not relative or len(relative) > MAX_PAYLOAD_PATH_CHARS:
        raise BundleError("payload path must be a bounded nonempty relative POSIX path")
    if "\\" in relative or ":" in relative or relative.startswith("/"):
        raise BundleError(f"unsafe payload path: {relative!r}")
    components = relative.split("/")
    if any(not part or part in (".", "..") or len(part) > 255 for part in components):
        raise BundleError(f"unsafe payload path: {relative!r}")
    root = source_root.resolve(strict=True)
    current = root
    for component in components:
        current = current / component
        if is_reparse_or_link(current):
            raise BundleError(f"payload path contains a symlink or reparse point: {relative}")
    resolved = current.resolve(strict=True)
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise BundleError(f"payload path escapes its producer artifact: {relative}") from exc
    if not resolved.is_file():
        raise BundleError(f"payload is not a regular file: {relative}")
    return resolved
def status_of(layer: 'dict[str, Any]') -> 'tuple[str, dict[str, Any]]':
    outcome = layer.get('outcome', layer.get('status', ''))
    if isinstance(outcome, dict):
        status = str(outcome.get('status', outcome.get('outcome', '')))
        details = dict(outcome)
    else:
        status = str(outcome)
        details = {}
    if status not in VALID_STATUSES:
        raise BundleError(f'layer {layer.get('layer_id')} has unsupported outcome {status!r}')
    return status, details

def canonical_address(terrain: dict[str, Any], features: dict[str, Any]) -> tuple[str, int, int, int, dict[str, float]]:
    tile = terrain.get("tile")
    feature_address = features.get("address")
    if not isinstance(tile, dict) or not isinstance(feature_address, dict):
        raise BundleError("terrain tile and feature address records are required")
    tile_id = tile.get("id")
    feature_id = feature_address.get("tile_id", feature_address.get("address_id"))
    if not isinstance(tile_id, str) or not isinstance(feature_id, str) or tile_id != feature_id:
        raise BundleError("terrain and feature producer artifacts do not declare the same canonical WFG-1 address")
    parts = tile_id.split(":")
    if len(parts) != 4 or parts[0] != "wfg1" or any(not part.isascii() or not part.isdecimal() for part in parts[1:]):
        raise BundleError("producer artifacts contain a malformed WFG-1 address")
    if any(len(part) > 1 and part.startswith("0") for part in parts[1:]):
        raise BundleError("producer WFG-1 address is not canonical (leading zero)")
    level, x, y = map(int, parts[1:])
    if not 0 <= level <= 16:
        raise BundleError("producer WFG-1 level is outside [0, 16]")
    if not 0 <= x < 1440 * (1 << level) or not 0 <= y < 720 * (1 << level):
        raise BundleError("producer WFG-1 address indices are outside the global grid")
    for record, label in ((tile, "terrain"), (feature_address, "features")):
        for field, expected_value in (("level", level), ("x", x), ("y", y)):
            value = record.get(field)
            if not isinstance(value, int) or isinstance(value, bool) or value != expected_value:
                raise BundleError(f"{label} manifest numeric address disagrees with its canonical tile ID")
    terrain_bounds = tile.get("bounds_wgs84")
    feature_bounds = feature_address.get("bounds_wgs84", feature_address.get("tile_bounds"))
    if isinstance(feature_bounds, list) and len(feature_bounds) == 4:
        feature_bounds = dict(zip(("west_deg", "south_deg", "east_deg", "north_deg"), feature_bounds))
    if not isinstance(terrain_bounds, dict) or not isinstance(feature_bounds, dict):
        raise BundleError("both producer manifests must declare WFG-1-derived tile bounds")
    keys = ("west_deg", "south_deg", "east_deg", "north_deg")
    bounds: dict[str, float] = {}
    for key in keys:
        value = terrain_bounds.get(key)
        other = feature_bounds.get(key)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(float(value)):
            raise BundleError(f"terrain bound {key} must be finite")
        if not isinstance(other, (int, float)) or isinstance(other, bool) or not math.isfinite(float(other)) or float(other) != float(value):
            raise BundleError(f"terrain and feature {key} bounds disagree")
        bounds[key] = float(value)
    step = 0.25 / float(1 << level)
    expected = {"west_deg": -180.0 + x * step, "south_deg": -90.0 + y * step, "east_deg": -180.0 + (x + 1) * step, "north_deg": -90.0 + (y + 1) * step}
    if bounds != expected:
        raise BundleError("producer bounds do not exactly match the WFG-1 address")
    if feature_address.get("scheme", "WFG-1") != "WFG-1":
        raise BundleError("feature producer uses an unsupported address scheme")
    return tile_id, level, x, y, bounds
def validate_terrain(terrain: dict[str, Any]) -> dict[str, Any]:
    if terrain.get("contract_id") != "urn:worldforge:contract:global-terrain-tile:1.0.0":
        raise BundleError("unsupported global terrain producer contract")
    producer = terrain.get("producer")
    if not isinstance(producer, dict) or producer.get("commit") != TERRAIN_COMMIT:
        raise BundleError("terrain producer revision differs from the pinned generator commit")
    layer = terrain.get("terrain")
    if not isinstance(layer, dict) or layer.get("status") not in ("ready", "partial"):
        raise BundleError("terrain artifact is not ready or partial")
    grid = layer.get("grid")
    if not isinstance(grid, dict) or grid.get("horizontal_crs") != "EPSG:4326" or grid.get("sample_order") != "row_major_north_to_south_west_to_east":
        raise BundleError("terrain source grid CRS or sample ordering is unsupported")
    if grid.get("pixel_registration") != "point" or not isinstance(grid.get("source_affine"), dict):
        raise BundleError("terrain source affine/pixel registration is missing")
    rows, columns = grid.get("rows"), grid.get("columns")
    if not isinstance(rows, int) or isinstance(rows, bool) or not isinstance(columns, int) or isinstance(columns, bool) or rows < 1 or columns < 1 or rows > MAX_RASTER_SAMPLES // columns:
        raise BundleError("terrain raster exceeds the named consumer sample-count policy")
    affine = grid["source_affine"]
    if affine.get("origin_reference") not in ("pixel_corner", "pixel_center"):
        raise BundleError("terrain affine must explicitly declare its origin reference")
    for key in ("x_origin", "y_origin", "pixel_width", "pixel_height", "rotation_x", "rotation_y"):
        value = affine.get(key)
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(float(value)):
            raise BundleError(f"terrain source affine coefficient {key} must be finite")
    conversion = layer.get("geoid_conversion")
    if not isinstance(conversion, dict) or conversion.get("status") != "ready" or conversion.get("equation") != "ellipsoidal_height_m = source_height_m + EGM2008_undulation_N_m":
        raise BundleError("terrain EGM2008 conversion is not explicitly ready")
    geoid = conversion.get("grid")
    if not isinstance(geoid, dict) or geoid.get("sha256") != GEOID_SHA256 or geoid.get("release") != "OSGeo PROJ-data grid; source grid modified 2019-12-27":
        raise BundleError("terrain geoid grid identity/revision/checksum differs from the selected EGM2008 grid")
    payloads = layer.get("payloads")
    if not isinstance(payloads, list) or not payloads or len(payloads) > MAX_BUNDLE_DESCRIPTORS:
        raise BundleError("terrain artifact has no bounded payload descriptors")
    vertical_map = layer.get("source_vertical_reference_by_mask")
    if not isinstance(vertical_map, dict) or not vertical_map:
        raise BundleError("terrain artifact requires explicit per-source vertical semantics")
    artifact_id = terrain.get("artifact_id")
    if not isinstance(artifact_id, str) or not artifact_id:
        raise BundleError("terrain producer artifact_id is required")
    for descriptor in payloads:
        if not isinstance(descriptor, dict):
            raise BundleError("terrain payload descriptor must be an object")
        shape = descriptor.get("shape")
        if shape is not None and (not isinstance(shape, list) or len(shape) != 2 or shape[0] != rows or shape[1] != columns):
            raise BundleError("terrain payload dimensions contradict its declared source grid")
    return layer
def validate_feature_manifest(features: dict[str, Any], expected_revision: str) -> dict[str, dict[str, Any]]:
    if features.get("schema_id") != "urn:worldforge:global-feature-bundle:1.0.0" or features.get("schema_version") != "1.0.0":
        raise BundleError("unsupported global feature producer contract")
    producer = features.get("producer")
    if not isinstance(producer, dict):
        raise BundleError("feature producer identity is required")
    for field in ("id", "version", "source_revision"):
        if not isinstance(producer.get(field), str) or not producer[field].strip():
            raise BundleError(f"feature producer {field} is required")
    if producer["source_revision"] != expected_revision or expected_revision != FEATURE_COMMIT:
        raise BundleError("feature producer source_revision must equal the exact requested and pinned generator commit")
    values = features.get("layers")
    if not isinstance(values, list):
        raise BundleError("feature producer layers must be an array")
    expected_ids = set(LAYER_IDS) - {"terrain"}
    layers = {}
    for layer in values:
        if not isinstance(layer, dict):
            raise BundleError("feature layer record must be an object")
        layer_id = layer.get("layer_id")
        if not isinstance(layer_id, str) or layer_id not in expected_ids or layer_id in layers:
            raise BundleError(f"unknown or duplicate feature layer ID: {layer_id!r}")
        status, _details = status_of(layer)
        payloads = layer.get("payloads")
        if not isinstance(payloads, list) or len(payloads) > MAX_LAYER_SHARDS:
            raise BundleError(f"feature layer {layer_id} payload list exceeds the shard limit")
        count_key = "feature_count" if layer_id in ("roads", "buildings", "water") else "pixel_count"
        count = layer.get(count_key)
        if count is not None and (not isinstance(count, int) or isinstance(count, bool) or count < 0):
            raise BundleError(f"{layer_id} {count_key} must be null/absent or a nonnegative integer")
        if status == "ready" and count is None:
            raise BundleError(f"ready layer {layer_id} requires {count_key}")
        limit = MAX_VECTOR_FEATURES if count_key == "feature_count" else MAX_RASTER_SAMPLES
        if count is not None and count > limit:
            raise BundleError(f"feature layer {layer_id} exceeds the finite consumer count limit")
        metadata = layer.get("metadata", {})
        if metadata is None:
            metadata = {}
        if not isinstance(metadata, dict):
            raise BundleError(f"feature layer {layer_id} metadata must be an object")
        if count_key == "feature_count" and count is not None and count > 0 and not payloads:
            raise BundleError(f"feature layer {layer_id} has features but no payloads")
        if count_key == "pixel_count" and count is not None:
            width, height = metadata.get("width"), metadata.get("height")
            if width is not None or height is not None:
                if not isinstance(width, int) or isinstance(width, bool) or not isinstance(height, int) or isinstance(height, bool) or width < 0 or height < 0:
                    raise BundleError(f"raster layer {layer_id} width/height must be nonnegative exact integers")
                if count == 0:
                    if width * height != 0:
                        raise BundleError(f"zero-pixel raster layer {layer_id} must declare an empty source window")
                elif width == 0 or height == 0 or height > MAX_RASTER_SAMPLES // width or width * height != count:
                    raise BundleError(f"raster layer {layer_id} dimensions disagree with pixel_count or exceed the sample limit")
            if status == "ready" and count == 0:
                query = layer.get("query_bounds_wgs84")
                if query is None or not str(layer.get("coverage_claim", "")).strip() or not str(layer.get("coverage_confidence", "")).strip():
                    raise BundleError(f"ready zero-pixel {layer_id} query requires bounds and explicit coverage disclosure")
        for field in ("source_lineage", "attribution"):
            if field in layer and not isinstance(layer[field], list):
                raise BundleError(f"feature layer {layer_id} {field} must be an array")
        layers[layer_id] = layer
    missing = expected_ids - layers.keys()
    if missing:
        raise BundleError(f"feature manifest is missing layers: {', '.join(sorted(missing))}")
    if features.get("bundle_outcome") not in VALID_STATUSES:
        raise BundleError("feature bundle outcome is unsupported")
    if not isinstance(features.get("bundle_id"), str) or not features["bundle_id"]:
        raise BundleError("feature producer bundle_id is required")
    return layers
def _coordinate_position_count(value: Any) -> int:
    if not isinstance(value, list):
        raise BundleError("GeoJSON geometry coordinates must be nested arrays")
    if not value:
        return 0
    if len(value) >= 2 and all(isinstance(part, (int, float)) and not isinstance(part, bool) for part in value):
        if len(value) != 2:
            raise BundleError("GeoJSON coordinate positions must be two-dimensional longitude/latitude")
        lon, lat = map(float, value)
        if not math.isfinite(lon) or not math.isfinite(lat) or not -180.0 <= lon <= 180.0 or not -90.0 <= lat <= 90.0:
            raise BundleError("GeoJSON coordinate lies outside finite WGS84 longitude/latitude bounds")
        return 1
    if any(not isinstance(child, list) for child in value):
        raise BundleError("GeoJSON coordinate arrays mix positions and nested arrays")
    return sum(_coordinate_position_count(child) for child in value)
def _inspect_geojson(path: Path, descriptor: dict[str, Any]) -> tuple[int, list[str], int]:
    raw = path.read_bytes()
    if len(raw) > MAX_VECTOR_SHARD_BYTES:
        raise BundleError(f"GeoJSON shard exceeds the 16 MiB shard limit: {path}")
    try:
        data = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs_no_duplicates)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise BundleError(f"invalid RFC 7946 GeoJSON shard {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("type") != "FeatureCollection" or not isinstance(data.get("features"), list):
        raise BundleError(f"GeoJSON shard is not a FeatureCollection: {path}")
    features = data["features"]
    if len(features) > MAX_VECTOR_FEATURES:
        raise BundleError(f"GeoJSON shard feature count exceeds the consumer limit: {path}")
    geometry_types: set[str] = set()
    positions = 0
    allowed = {"Point", "MultiPoint", "LineString", "MultiLineString", "Polygon", "MultiPolygon"}
    for feature in features:
        if not isinstance(feature, dict) or feature.get("type") != "Feature":
            raise BundleError(f"GeoJSON Feature is malformed: {path}")
        feature_id = feature.get("id")
        if not ((isinstance(feature_id, str) and feature_id) or (isinstance(feature_id, int) and not isinstance(feature_id, bool))):
            raise BundleError(f"GeoJSON Feature requires a stable source ID: {path}")
        geometry = feature.get("geometry")
        if geometry is None:
            continue
        if not isinstance(geometry, dict) or geometry.get("type") not in allowed:
            raise BundleError(f"unsupported GeoJSON geometry: {path}")
        geometry_types.add(geometry["type"])
        positions += _coordinate_position_count(geometry.get("coordinates"))
        if positions > MAX_VECTOR_COORDINATE_POSITIONS:
            raise BundleError("GeoJSON shard exceeds the 50M coordinate-position consumer limit")
    count = descriptor.get("feature_count")
    if count is not None and (not isinstance(count, int) or isinstance(count, bool) or count != len(features)):
        raise BundleError(f"GeoJSON shard feature count differs from its producer descriptor: {path}")
    return len(features), sorted(geometry_types), positions
def _geodesic_distance_wgs84_m(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
    """Vincenty inverse distance on WGS84, used for local edge-source offsets."""
    for value in (lon1, lat1, lon2, lat2):
        if not math.isfinite(value):
            raise BundleError("boundary source/target geodesic coordinates must be finite")
    if not (-180.0 <= lon1 <= 180.0 and -180.0 <= lon2 <= 180.0 and -90.0 <= lat1 <= 90.0 and -90.0 <= lat2 <= 90.0):
        raise BundleError("boundary source/target geodesic coordinates are outside WGS84 bounds")
    a = 6378137.0
    flattening = 1.0 / 298.257223563
    b = (1.0 - flattening) * a
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    delta_lon = lon2 - lon1
    while delta_lon > 180.0:
        delta_lon -= 360.0
    while delta_lon < -180.0:
        delta_lon += 360.0
    longitude_delta = math.radians(delta_lon)
    u1 = math.atan((1.0 - flattening) * math.tan(phi1))
    u2 = math.atan((1.0 - flattening) * math.tan(phi2))
    sin_u1, cos_u1 = math.sin(u1), math.cos(u1)
    sin_u2, cos_u2 = math.sin(u2), math.cos(u2)
    lam = longitude_delta
    converged = False
    for _ in range(100):
        sin_lam, cos_lam = math.sin(lam), math.cos(lam)
        first = cos_u2 * sin_lam
        second = cos_u1 * sin_u2 - sin_u1 * cos_u2 * cos_lam
        sin_sigma = math.hypot(first, second)
        if sin_sigma == 0.0:
            return 0.0
        cos_sigma = sin_u1 * sin_u2 + cos_u1 * cos_u2 * cos_lam
        sigma = math.atan2(sin_sigma, cos_sigma)
        sin_alpha = cos_u1 * cos_u2 * sin_lam / sin_sigma
        cos_sq_alpha = 1.0 - sin_alpha * sin_alpha
        cos_two_sigma_m = 0.0 if cos_sq_alpha <= 1.0e-30 else cos_sigma - 2.0 * sin_u1 * sin_u2 / cos_sq_alpha
        coefficient = flattening / 16.0 * cos_sq_alpha * (4.0 + flattening * (4.0 - 3.0 * cos_sq_alpha))
        previous = lam
        lam = longitude_delta + (1.0 - coefficient) * flattening * sin_alpha * (
            sigma + coefficient * sin_sigma * (
                cos_two_sigma_m + coefficient * cos_sigma * (-1.0 + 2.0 * cos_two_sigma_m * cos_two_sigma_m)
            )
        )
        if abs(lam - previous) <= 1.0e-13:
            converged = True
            break
    if not converged:
        raise BundleError("WGS84 inverse geodesic did not converge for boundary support offset")
    u_sq = cos_sq_alpha * (a * a - b * b) / (b * b)
    aa = 1.0 + u_sq / 16384.0 * (4096.0 + u_sq * (-768.0 + u_sq * (320.0 - 175.0 * u_sq)))
    bb = u_sq / 1024.0 * (256.0 + u_sq * (-128.0 + u_sq * (74.0 - 47.0 * u_sq)))
    delta_sigma = bb * sin_sigma * (
        cos_two_sigma_m + bb / 4.0 * (
            cos_sigma * (-1.0 + 2.0 * cos_two_sigma_m * cos_two_sigma_m)
            - bb / 6.0 * cos_two_sigma_m * (-3.0 + 4.0 * sin_sigma * sin_sigma)
            * (-3.0 + 4.0 * cos_two_sigma_m * cos_two_sigma_m)
        )
    )
    distance = b * aa * (sigma - delta_sigma)
    if not math.isfinite(distance) or distance < 0.0:
        raise BundleError("WGS84 inverse geodesic produced an invalid boundary offset")
    return distance


def _validate_nearest_copdem_grid_sample(source_grid: dict[str, Any], target_lon: float, target_lat: float, source_lon: float, source_lat: float) -> None:
    rows, columns = source_grid.get("rows"), source_grid.get("columns")
    affine = source_grid.get("source_affine")
    if not isinstance(rows, int) or isinstance(rows, bool) or not isinstance(columns, int) or isinstance(columns, bool) or rows < 1 or columns < 1 or not isinstance(affine, dict):
        raise BundleError("nearest CopDEM boundary sample requires a bounded source-grid affine")
    origin_reference = affine.get("origin_reference")
    if origin_reference not in ("pixel_corner", "pixel_center") or source_grid.get("pixel_registration") != "point":
        raise BundleError("nearest CopDEM boundary sample requires explicit point-grid origin semantics")
    keys = ("x_origin", "y_origin", "pixel_width", "rotation_x", "rotation_y", "pixel_height")
    if any(not isinstance(affine.get(key), (int, float)) or isinstance(affine.get(key), bool) or not math.isfinite(float(affine[key])) for key in keys):
        raise BundleError("nearest CopDEM source affine has non-finite coefficients")
    x0, y0, pw, rx, ry, ph = (float(affine[key]) for key in keys)
    determinant = pw * ph - rx * ry
    if abs(determinant) <= 1.0e-30:
        raise BundleError("nearest CopDEM source affine is singular")
    dx, dy = target_lon - x0, target_lat - y0
    offset = 0.5 if origin_reference == "pixel_corner" else 0.0
    column_position = (dx * ph - dy * rx) / determinant - offset
    row_position = (dy * pw - dx * ry) / determinant - offset
    candidate_columns = sorted({max(0, min(columns - 1, math.floor(column_position))), max(0, min(columns - 1, math.ceil(column_position)))})
    candidate_rows = sorted({max(0, min(rows - 1, math.floor(row_position))), max(0, min(rows - 1, math.ceil(row_position)))})
    candidates: list[tuple[float, float, float]] = []
    for row in candidate_rows:
        for column in candidate_columns:
            qx, qy = column + offset, row + offset
            lon = x0 + qx * pw + qy * rx
            lat = y0 + qx * ry + qy * ph
            candidates.append((_geodesic_distance_wgs84_m(lon, lat, target_lon, target_lat), lon, lat))
    if not candidates:
        raise BundleError("nearest CopDEM source grid has no candidates")
    minimum = min(candidate[0] for candidate in candidates)
    tied = [candidate for candidate in candidates if abs(candidate[0] - minimum) <= 1.0e-7]
    # Exact ties choose the eastern coordinate, then the northern coordinate.
    tied.sort(key=lambda candidate: (-candidate[1], -candidate[2]))
    selected = tied[0]
    if source_lon != selected[1] or source_lat != selected[2]:
        raise BundleError("nearest CopDEM source sample violates WGS84 nearest/east-then-north tie ownership")


def _inspect_boundary_support(path: Path, descriptor: dict[str, Any], bounds: dict[str, float], vertical_map: dict[str, Any], address: dict[str, Any], source_grid: dict[str, Any] | None = None) -> tuple[int, list[dict[str, Any]]]:
    try:
        data = json.loads(path.read_bytes(), object_pairs_hook=_pairs_no_duplicates)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BundleError(f"invalid terrain boundary support GeoJSON {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("type") != "FeatureCollection" or not isinstance(data.get("features"), list):
        raise BundleError("terrain boundary support must be a GeoJSON FeatureCollection")
    level = address.get("level")
    x = address.get("x")
    if not isinstance(level, int) or isinstance(level, bool) or not isinstance(x, int) or isinstance(x, bool):
        raise BundleError("terrain boundary support needs exact address level and x indices")
    last_x = 1440 * (2 ** level) - 1
    edges: dict[str, dict[str, Any]] = {}
    seen_ids: set[str] = set()

    def unwrapped_lon(lon: float, edge: str) -> float:
        if edge in ("north", "south") and x == last_x and bounds["east_deg"] == 180.0 and lon == -180.0:
            return 180.0
        return lon

    for feature in data["features"]:
        if not isinstance(feature, dict) or feature.get("type") != "Feature" or not isinstance(feature.get("id"), str):
            raise BundleError("terrain boundary support Feature needs a stable string ID")
        properties = feature.get("properties")
        worldforge = properties.get("worldforge") if isinstance(properties, dict) else None
        edge_data = worldforge.get("boundary_support") if isinstance(worldforge, dict) else None
        if not isinstance(edge_data, dict):
            raise BundleError("terrain boundary support Feature lacks worldforge.boundary_support provenance")
        edge = edge_data.get("edge")
        if not isinstance(edge, str) or edge not in ("north", "east", "south", "west"):
            raise BundleError("terrain boundary edge must be a supported string")
        edge_index = edge_data.get("edge_index")
        declared_count = edge_data.get("edge_sample_count")
        if not isinstance(edge_index, int) or isinstance(edge_index, bool) or not isinstance(declared_count, int) or isinstance(declared_count, bool):
            raise BundleError("terrain boundary edge_index/edge_sample_count must be exact integers")
        is_north_pole = edge == "north" and bounds["north_deg"] == 90.0
        is_south_pole = edge == "south" and bounds["south_deg"] == -90.0
        is_pole = is_north_pole or is_south_pole
        minimum_count = 1 if is_pole else 2
        if edge_index < 0 or declared_count < minimum_count or declared_count > 10000:
            raise BundleError("terrain boundary edge/index/count is outside the declared contract")
        if is_pole and (edge_index != 0 or declared_count != 1):
            raise BundleError("polar boundary support must be one canonical index-zero pole vertex")
        expected_id = f"boundary:{edge}:{edge_index}"
        if feature["id"] != expected_id or expected_id in seen_ids:
            raise BundleError("terrain boundary feature ID is noncanonical, duplicate or unstable")
        seen_ids.add(expected_id)
        geometry = feature.get("geometry")
        coordinates = geometry.get("coordinates") if isinstance(geometry, dict) and geometry.get("type") == "Point" else None
        if not isinstance(coordinates, list) or len(coordinates) != 3:
            raise BundleError("terrain boundary support Point must contain [longitude,latitude,ellipsoidal_height]")
        if any(not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(float(value)) for value in coordinates):
            raise BundleError("terrain boundary support Point coordinates must be finite numbers")
        longitude, latitude, height = map(float, coordinates)
        if is_pole:
            expected_latitude = 90.0 if is_north_pole else -90.0
            if longitude != 0.0 or latitude != expected_latitude:
                raise BundleError("polar support must use the canonical longitude-zero pole coordinate")
        else:
            east_antimeridian_alias = edge in ("east", "north", "south") and bounds["east_deg"] == 180.0 and longitude == -180.0 and x == last_x
            edge_coordinate = {"north": latitude == bounds["north_deg"], "east": longitude == bounds["east_deg"] or east_antimeridian_alias, "south": latitude == bounds["south_deg"], "west": longitude == bounds["west_deg"]}[edge]
            if not edge_coordinate:
                raise BundleError(f"terrain boundary feature {expected_id} does not lie on its exact WFG-1 boundary")
            if not (bounds["west_deg"] <= longitude <= bounds["east_deg"] or east_antimeridian_alias):
                raise BundleError(f"terrain boundary feature {expected_id} longitude is outside WFG-1 bounds")
            if not bounds["south_deg"] <= latitude <= bounds["north_deg"]:
                raise BundleError(f"terrain boundary feature {expected_id} latitude is outside WFG-1 bounds")
        required_fields = ("source_sample_longitude", "source_sample_latitude", "source_height_H", "source_vertical_datum", "geoid_undulation_N", "ellipsoidal_height_h", "source_mask", "quality_mask", "type_identifier_mask", "geoid_mask", "sample_method", "source_to_boundary_offset_m", "source_artifact")
        for field in required_fields:
            if field not in edge_data:
                raise BundleError(f"terrain boundary metadata lacks {field}")
        for field in ("source_sample_longitude", "source_sample_latitude", "source_height_H", "geoid_undulation_N", "ellipsoidal_height_h", "source_to_boundary_offset_m"):
            value = edge_data[field]
            if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(float(value)):
                raise BundleError(f"terrain boundary metadata {field} must be a finite number")
        if float(edge_data["ellipsoidal_height_h"]) != height:
            raise BundleError("terrain boundary GeoJSON Z differs from its ellipsoidal_height_h metadata")
        for field in ("source_mask", "quality_mask", "geoid_mask"):
            value = edge_data[field]
            if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 255:
                raise BundleError(f"terrain boundary {field} must be a uint8 code")
        source_code = edge_data["source_mask"]
        tid_code = edge_data["type_identifier_mask"]
        if tid_code is not None and (not isinstance(tid_code, int) or isinstance(tid_code, bool) or not 0 <= tid_code <= 255):
            raise BundleError("terrain boundary type_identifier_mask must be null or a uint8 code")
        if source_code == 2 and tid_code is None:
            raise BundleError("GEBCO source-mask code 2 requires a valid Type Identifier code")
        if source_code != 1 and source_code != 2 and tid_code is None:
            raise BundleError("null Type Identifier is supported only for CopDEM source-mask code 1")
        vertical_source = vertical_map.get(str(source_code))
        if not isinstance(vertical_source, dict):
            raise BundleError("terrain boundary source-mask code lacks vertical provenance")
        geoid_mask_code = vertical_source.get("geoid_mask_code")
        if not isinstance(geoid_mask_code, int) or isinstance(geoid_mask_code, bool) or geoid_mask_code != edge_data["geoid_mask"]:
            raise BundleError("terrain boundary geoid mask code contradicts source-mask vertical provenance")
        source_vertical = vertical_source.get("source_vertical_reference")
        if not isinstance(source_vertical, dict):
            raise BundleError("terrain boundary source vertical reference is missing")
        datum = str(source_vertical.get("datum", ""))
        product = str(vertical_source.get("product", ""))
        source_datum = "EGM2008" if datum == "EGM2008" and product.startswith("COP-DEM-GLO-") else "MEAN_SEA_LEVEL" if "mean_sea_level" in datum and product == "GEBCO_2026" else ""
        if not source_datum:
            raise BundleError("terrain boundary has unsupported source datum/product metadata")
        if not isinstance(edge_data["source_vertical_datum"], str) or edge_data["source_vertical_datum"] != datum:
            raise BundleError("terrain boundary source_vertical_datum contradicts its source-mask mapping")
        source_artifact = edge_data["source_artifact"]
        if not isinstance(source_artifact, dict):
            raise BundleError("terrain boundary source_artifact must be an object")
        for field in ("product", "release", "asset_id"):
            if not isinstance(source_artifact.get(field), str) or not source_artifact[field].strip():
                raise BundleError(f"terrain boundary source_artifact needs nonempty {field}")
        for field in ("uri", "sha256"):
            if field in source_artifact and not isinstance(source_artifact[field], str):
                raise BundleError(f"terrain boundary source_artifact {field} must be a string when present")
        method = edge_data["sample_method"]
        if not isinstance(method, str) or method not in ("native_exact", "nearest_native_sample"):
            raise BundleError("terrain boundary sample_method is unsupported")
        offset = float(edge_data["source_to_boundary_offset_m"])
        if offset < 0.0:
            raise BundleError("terrain boundary sample offset cannot be negative")
        source_lon = float(edge_data["source_sample_longitude"])
        source_lat = float(edge_data["source_sample_latitude"])
        if method == "native_exact":
            if offset != 0.0 or source_lon != longitude or source_lat != latitude:
                raise BundleError("native_exact terrain boundary support must preserve the exact source coordinate")
        else:
            geodesic_offset = _geodesic_distance_wgs84_m(source_lon, source_lat, longitude, latitude)
            if abs(geodesic_offset - offset) > 0.001:
                raise BundleError("terrain boundary source_to_boundary_offset_m differs from WGS84 geodesic by more than 1 mm")
            if source_code == 1 and product.startswith("COP-DEM-GLO-") and not is_pole:
                if not isinstance(source_grid, dict):
                    raise BundleError("nearest CopDEM validation requires the producer source grid")
                _validate_nearest_copdem_grid_sample(source_grid, longitude, latitude, source_lon, source_lat)
        warning = edge_data.get("warning")
        if warning is not None and (not isinstance(warning, str) or not warning.strip()):
            raise BundleError("terrain boundary warning must be null or a nonempty string")
        if abs(float(edge_data["source_height_H"]) + float(edge_data["geoid_undulation_N"]) - height) > 0.00001:
            raise BundleError("terrain boundary height does not match declared source H + geoid N")
        if source_datum == "MEAN_SEA_LEVEL" and (not bool(vertical_source.get("approximate", True)) or not isinstance(warning, str) or not warning.strip()):
            raise BundleError("GEBCO nominal-MSL boundary placement must be tagged approximate")
        bucket = edges.setdefault(edge, {"count": declared_count, "indices": [], "coordinates": []})
        if bucket["count"] != declared_count:
            raise BundleError(f"terrain boundary {edge} records disagree on edge_sample_count")
        bucket["indices"].append(edge_index)
        bucket["coordinates"].append((longitude, latitude))
    feature_count = descriptor.get("feature_count")
    if not isinstance(feature_count, int) or isinstance(feature_count, bool) or feature_count != len(data["features"]):
        raise BundleError("terrain boundary support count differs from its producer descriptor")
    for edge, bucket in edges.items():
        if len(bucket["indices"]) != bucket["count"] or sorted(bucket["indices"]) != list(range(bucket["count"])):
            raise BundleError(f"terrain boundary {edge} indices are not a complete zero-based sequence")
        records = sorted(zip(bucket["indices"], bucket["coordinates"]))
        coordinates = [record[1] for record in records]
        if edge == "north" and bounds["north_deg"] == 90.0:
            if bucket["count"] != 1 or coordinates[0] != (0.0, 90.0):
                raise BundleError("north-pole support must be the single canonical longitude-zero vertex")
            continue
        if edge == "south" and bounds["south_deg"] == -90.0:
            if bucket["count"] != 1 or coordinates[0] != (0.0, -90.0):
                raise BundleError("south-pole support must be the single canonical longitude-zero vertex")
            continue
        longitudes = [unwrapped_lon(point[0], edge) for point in coordinates]
        latitudes = [point[1] for point in coordinates]
        if edge == "north" and (longitudes[0] != bounds["west_deg"] or longitudes[-1] != bounds["east_deg"]):
            raise BundleError("north boundary must include west and east endpoints, unwrapping the +180 alias")
        if edge == "east" and (latitudes[0] >= bounds["north_deg"] or latitudes[-1] != bounds["south_deg"]):
            raise BundleError("east boundary must omit NE and include SE")
        south_east_alias = x == last_x and bounds["east_deg"] == 180.0 and coordinates[0][0] == -180.0 and longitudes[0] == 180.0
        if edge == "south" and ((longitudes[0] >= bounds["east_deg"] and not south_east_alias) or longitudes[-1] != bounds["west_deg"]):
            raise BundleError("south boundary must omit SE except for the normalized +180 antimeridian endpoint and include SW")
        if edge == "west" and (latitudes[0] <= bounds["south_deg"] or latitudes[-1] >= bounds["north_deg"]):
            raise BundleError("west boundary must omit SW and NW")
        if edge in ("north", "south"):
            increasing = edge == "north"
            if any((longitudes[i] >= longitudes[i + 1]) if increasing else (longitudes[i] <= longitudes[i + 1]) for i in range(len(longitudes) - 1)):
                raise BundleError(f"{edge} boundary longitude order is not canonical after antimeridian unwrapping")
        else:
            increasing = edge == "west"
            if any((latitudes[i] >= latitudes[i + 1]) if increasing else (latitudes[i] <= latitudes[i + 1]) for i in range(len(latitudes) - 1)):
                raise BundleError(f"{edge} boundary latitude order is not canonical")
    edge_descriptors = [{"edge": edge, "sample_count": int(edges[edge]["count"])} for edge in ("north", "east", "south", "west") if edge in edges]
    return len(data["features"]), edge_descriptors

def canonical_raster_geotransform(descriptor: dict[str, Any], layer_transform: dict[str, Any] | None) -> dict[str, Any]:
    transform = layer_transform or {}
    candidate = descriptor.get("geotransform")
    if isinstance(candidate, dict) and not all(key in candidate for key in ("horizontal_crs", "axis_order", "affine", "origin_reference", "pixel_registration", "sample_coordinate_rule")):
        candidate = None
    if not isinstance(candidate, dict):
        source_grid = transform.get("source_grid", transform)
        if not isinstance(source_grid, dict):
            source_grid = {}
        affine: Any = (
            descriptor.get("sample_geotransform")
            or source_grid.get("source_affine")
            or source_grid.get("pixel_center_affine")
            or transform.get("raster_affine_lon_lat")
            or transform.get("affine_wgs84_lon_lat")
            or transform.get("pixel_center_affine")
        )
        origin_reference = descriptor.get("origin_reference", transform.get("origin_reference", source_grid.get("origin_reference")))
        registration = descriptor.get("pixel_registration", transform.get("pixel_registration", source_grid.get("pixel_registration")))
        if isinstance(affine, dict):
            if "x_origin" not in affine and "x_origin_deg" in affine:
                origin_reference = affine.get("origin_reference", origin_reference or "pixel_center")
                affine = {
                    "x_origin": affine["x_origin_deg"],
                    "y_origin": affine["y_origin_deg"],
                    "pixel_width": affine["pixel_width_deg"],
                    "rotation_x": affine.get("rotation_x", 0.0),
                    "rotation_y": affine.get("rotation_y", 0.0),
                    "pixel_height": affine["pixel_height_deg"],
                }
            elif origin_reference is None:
                origin_reference = affine.get("origin_reference")
        elif isinstance(affine, list) and len(affine) == 6:
            # Content producer uses GDAL affine order [a,b,x0,d,e,y0].
            affine = {
                "pixel_width": affine[0],
                "rotation_x": affine[1],
                "x_origin": affine[2],
                "rotation_y": affine[3],
                "pixel_height": affine[4],
                "y_origin": affine[5],
            }
        else:
            raise BundleError("raster layer has no explicit six-coefficient affine")
        if origin_reference not in ("pixel_corner", "pixel_center"):
            raise BundleError("raster affine must explicitly declare pixel_corner or pixel_center origin")
        if registration not in ("area", "point"):
            raise BundleError("raster payload must declare area or point pixel registration")
        sample_rule = descriptor.get("sample_coordinate_rule", transform.get("sample_coordinate_rule"))
        expected_rule = "row_col_plus_half" if origin_reference == "pixel_corner" else "row_col"
        if sample_rule is None or sample_rule == "":
            sample_rule = expected_rule
        if sample_rule != expected_rule:
            raise BundleError("raster sample-coordinate rule contradicts its explicit affine origin")
        axes = descriptor.get("axis_order", transform.get("axis_order", ["longitude", "latitude"]))
        if axes in ("longitude_latitude", "longitude/latitude"):
            axes = ["longitude", "latitude"]
        crs = descriptor.get("horizontal_crs", transform.get("horizontal_crs", transform.get("crs", "EPSG:4326")))
        candidate = {
            "horizontal_crs": crs,
            "axis_order": axes,
            "affine": {key: affine[key] for key in ("x_origin", "y_origin", "pixel_width", "rotation_x", "rotation_y", "pixel_height")},
            "origin_reference": origin_reference,
            "pixel_registration": registration,
            "sample_coordinate_rule": sample_rule,
        }
    if candidate.get("horizontal_crs") != "EPSG:4326" or candidate.get("axis_order") != ["longitude", "latitude"]:
        raise BundleError("raster geotransform must declare EPSG:4326 longitude/latitude axes")
    if candidate.get("origin_reference") not in ("pixel_corner", "pixel_center") or candidate.get("pixel_registration") not in ("area", "point"):
        raise BundleError("raster geotransform lacks explicit origin and pixel registration")
    expected_rule = "row_col_plus_half" if candidate["origin_reference"] == "pixel_corner" else "row_col"
    if candidate.get("sample_coordinate_rule") != expected_rule:
        raise BundleError("raster sample-coordinate rule contradicts its declared origin")
    affine_value = candidate.get("affine")
    required = {"x_origin", "y_origin", "rotation_x", "rotation_y", "pixel_width", "pixel_height"}
    if not isinstance(affine_value, dict) or set(affine_value) != required:
        raise BundleError("raster geotransform affine must contain exactly the six canonical coefficients")
    for key, value in affine_value.items():
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(float(value)):
            raise BundleError(f"raster affine coefficient {key} must be finite")
    return candidate
def remap_payloads(
    descriptors: list[dict[str, Any]],
    source_root: Path,
    staging_root: Path,
    prefix: str,
    seen: set[str],
    copied_bytes: list[int],
    layer_bytes: list[int],
    layer_transform: dict[str, Any] | None = None,
    coordinate_positions: list[int] | None = None,
    tile_bounds: dict[str, float] | None = None,
    address: dict[str, Any] | None = None,
    vertical_map: dict[str, Any] | None = None,
    geometry_budget: list[int] | None = None,
) -> list[dict[str, Any]]:
    if not isinstance(descriptors, list) or len(descriptors) > MAX_LAYER_SHARDS:
        raise BundleError(f"layer {prefix} exceeds the payload descriptor/shard-count consumer limit")
    mapped: list[dict[str, Any]] = []
    for descriptor in descriptors:
        if not isinstance(descriptor, dict):
            raise BundleError("payload descriptor must be an object")
        source_relative = descriptor.get("path")
        source = safe_payload(source_root, source_relative)
        actual_size = source.stat().st_size
        layer_is_vector = prefix in ("roads", "buildings", "water")
        payload_kind = descriptor.get("payload_kind")
        is_boundary_support = prefix == "terrain" and payload_kind == "terrain_boundary_support"
        if layer_is_vector:
            if payload_kind not in (None, "", "vector_shard"):
                raise BundleError(f"vector layer {prefix} received payload_kind={payload_kind!r}")
            canonical_kind = "vector_shard"
        elif is_boundary_support:
            canonical_kind = "terrain_boundary_support"
        else:
            if prefix == "terrain" and payload_kind not in (None, "", "raster_grid"):
                raise BundleError(f"terrain layer received unsupported payload_kind={payload_kind!r}")
            if prefix in ("landcover", "vegetation") and payload_kind not in (None, "", "raster_grid"):
                raise BundleError(f"raster layer {prefix} received unsupported payload_kind={payload_kind!r}")
            canonical_kind = "raster_grid"
        is_geojson = layer_is_vector or is_boundary_support
        per_file_limit = MAX_VECTOR_SHARD_BYTES if is_geojson else MAX_PAYLOAD_BYTES
        if actual_size <= 0 or actual_size > per_file_limit:
            raise BundleError(f"producer payload is empty or exceeds {per_file_limit} byte consumer limit: {source_relative}")
        expected_size = descriptor.get("size_bytes")
        expected_hash = descriptor.get("sha256")
        if not isinstance(expected_size, int) or isinstance(expected_size, bool) or expected_size != actual_size:
            raise BundleError(f"producer payload size differs from its descriptor: {source_relative}")
        if not isinstance(expected_hash, str) or len(expected_hash) != 64 or any(ch not in "0123456789abcdef" for ch in expected_hash):
            raise BundleError(f"producer payload SHA-256 descriptor is malformed: {source_relative}")
        source_hash = sha256_file(source)
        if source_hash != expected_hash:
            raise BundleError(f"producer payload SHA-256 mismatch: {source_relative}")
        copied_bytes[0] += actual_size
        layer_bytes[0] += actual_size
        if copied_bytes[0] > MAX_BUNDLE_BYTES:
            raise BundleError("assembled bundle exceeds the named total-size consumer limit")
        if layer_is_vector and layer_bytes[0] > MAX_VECTOR_LAYER_BYTES:
            raise BundleError(f"vector layer {prefix} exceeds the named per-layer byte limit")
        safe_name = PurePosixPath(source_relative).name
        destination_relative = f"{prefix}/{safe_name}"
        if any(character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/" for character in destination_relative):
            raise BundleError(f"normalized payload path contains characters outside the canonical schema: {destination_relative!r}")
        if len(destination_relative) > MAX_PAYLOAD_PATH_CHARS or destination_relative in seen:
            raise BundleError(f"normalized bundle payload path is too long or collides: {destination_relative}")
        seen.add(destination_relative)
        if len(seen) > MAX_BUNDLE_DESCRIPTORS:
            raise BundleError("bundle exceeds the 65,536 payload/provenance descriptor limit")
        destination = staging_root.joinpath(*PurePosixPath(destination_relative).parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination_hash = sha256_file(destination)
        if destination.stat().st_size != actual_size or destination_hash != source_hash:
            raise BundleError(f"copied payload changed during assembly: {source_relative}")
        encoding = descriptor.get("encoding") or descriptor.get("representation") or descriptor.get("serialization")
        if not isinstance(encoding, str) or not encoding:
            raise BundleError(f"payload descriptor lacks encoding/representation/serialization: {source_relative}")
        media_type = "application/geo+json" if is_geojson else descriptor.get("media_type", "application/octet-stream")
        if not isinstance(media_type, str) or not media_type:
            raise BundleError(f"payload media_type must be a nonempty string: {source_relative}")
        if is_geojson and media_type != "application/geo+json":
            raise BundleError(f"GeoJSON payload must use application/geo+json: {source_relative}")
        result: dict[str, Any] = {
            "payload_kind": canonical_kind,
            "path": destination_relative,
            "media_type": media_type,
            "encoding": "geojson" if is_geojson else encoding,
            "size_bytes": actual_size,
            "sha256": destination_hash,
            "producer_descriptor": dict(descriptor.get("_source_descriptor", descriptor)),
        }
        if is_boundary_support:
            if tile_bounds is None or address is None or vertical_map is None:
                raise BundleError("terrain boundary support requires validated bounds, address and vertical map")
            source_grid = (layer_transform or {}).get("source_grid", {})
            boundary_count, edge_summary = _inspect_boundary_support(source, descriptor, tile_bounds, vertical_map, address, source_grid)
            decoded_cost = actual_size + boundary_count * (64 + 128)
            if geometry_budget is not None:
                geometry_budget[0] += decoded_cost
                if geometry_budget[0] > MAX_DECODED_GEOMETRY_BYTES:
                    raise BundleError("decoded GeoJSON geometry exceeds the 4 GiB consumer budget")
            result.update(feature_count=boundary_count, geometry_types=["Point"], coordinate_dimensions=3, boundary_support_edges=edge_summary)
        elif layer_is_vector:
            shard_count, geometry_types, positions = _inspect_geojson(source, descriptor)
            if coordinate_positions is not None:
                coordinate_positions[0] += positions
                if coordinate_positions[0] > MAX_VECTOR_COORDINATE_POSITIONS:
                    raise BundleError(f"vector layer {prefix} exceeds the 50M coordinate-position consumer limit")
            decoded_cost = actual_size + positions * 64 + shard_count * 128
            if geometry_budget is not None:
                geometry_budget[0] += decoded_cost
                if geometry_budget[0] > MAX_DECODED_GEOMETRY_BYTES:
                    raise BundleError("decoded GeoJSON geometry exceeds the 4 GiB consumer budget")
            result.update(feature_count=shard_count, geometry_types=geometry_types or ["Unknown"], coordinate_dimensions=2)
        else:
            if media_type != "application/octet-stream":
                raise BundleError(f"raster payload must use application/octet-stream: {source_relative}")
            shape = descriptor.get("shape")
            dtype = descriptor.get("dtype")
            byte_order = descriptor.get("byte_order")
            row_order = descriptor.get("row_order", descriptor.get("row_ordering"))
            if not isinstance(shape, list) or len(shape) != 2:
                raise BundleError(f"raster payload has malformed [rows,columns] shape: {source_relative}")
            rows, columns = shape
            if not isinstance(rows, int) or isinstance(rows, bool) or not isinstance(columns, int) or isinstance(columns, bool):
                raise BundleError(f"raster shape values must be exact integers: {source_relative}")
            if rows < 1 or columns < 1 or rows > MAX_RASTER_SAMPLES // columns:
                raise BundleError(f"raster payload exceeds the 10M sample-count limit: {source_relative}")
            if not isinstance(dtype, str) or not dtype or not isinstance(byte_order, str) or byte_order not in ("little", "big", "not_applicable"):
                raise BundleError(f"raster payload lacks dtype or byte-order metadata: {source_relative}")
            if row_order != "row_major_north_to_south_west_to_east":
                raise BundleError(f"raster row order is unsupported: {source_relative}")
            if "no_data_value" not in descriptor:
                raise BundleError(f"raster payload must state its no-data representation: {source_relative}")
            dtype_sizes = {"uint8": 1, "int8": 1, "int16": 2, "uint16": 2, "int32": 4, "uint32": 4, "float32": 4, "float64": 8}
            if dtype not in dtype_sizes or rows * columns * dtype_sizes[dtype] != actual_size:
                raise BundleError(f"raster dtype and shape do not match its payload byte length: {source_relative}")
            transform = canonical_raster_geotransform(descriptor, layer_transform)
            affine = transform.get("affine", {})
            for key in ("x_origin", "y_origin", "pixel_width", "rotation_x", "rotation_y", "pixel_height"):
                value = affine.get(key) if isinstance(affine, dict) else None
                if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(float(value)):
                    raise BundleError(f"raster affine coefficient {key} is invalid: {source_relative}")
            result.update(shape=shape, dtype=dtype, byte_order=byte_order, row_order=row_order, no_data_value=descriptor["no_data_value"], geotransform=transform)
        mapped.append(result)
    return mapped
def terrain_layer_record(
    raw: dict[str, Any],
    source_root: Path,
    staging_root: Path,
    seen: set[str],
    copied_bytes: list[int],
    geometry_budget: list[int],
) -> dict[str, Any]:
    source = raw["terrain"]
    source_refs = source.get("source_vertical_reference_by_mask")
    if not isinstance(source_refs, dict) or not source_refs:
        raise BundleError("terrain requires explicit per-source vertical semantics")
    payloads = remap_payloads(
        source["payloads"], source_root, staging_root, "terrain", seen, copied_bytes, [0],
        {"source_grid": source["grid"]}, None, raw["tile"]["bounds_wgs84"], raw["tile"],
        source_refs, geometry_budget,
    )
    conversion = source["geoid_conversion"]
    source_code_refs: dict[str, dict[str, Any]] = {}
    for source_mask_code, raw_reference in source_refs.items():
        if not isinstance(raw_reference, dict):
            raise BundleError(f"terrain source vertical reference for mask {source_mask_code} is malformed")
        entry = dict(raw_reference)
        nested_vertical = entry.get("source_vertical_reference", {})
        if not isinstance(nested_vertical, dict):
            raise BundleError(f"terrain source vertical reference for mask {source_mask_code} lacks datum metadata")
        source_datum = str(entry.get("source_vertical_datum", nested_vertical.get("datum", "")))
        product = str(entry.get("product", ""))
        if source_datum == "EGM2008" and product.startswith("COP-DEM-GLO-"):
            entry.update(source_vertical_datum="EGM2008", method="h = H_EGM2008 + N_EGM2008", approximate=False)
        elif "mean_sea_level" in source_datum and product == "GEBCO_2026":
            entry.update(source_vertical_datum="MEAN_SEA_LEVEL", method="nominal_MSL_plus_EGM2008_geoid", approximate=True)
            entry.setdefault("warning", "GEBCO nominal MSL values have heterogeneous shallow-water datums; h=N+MSL is approximate.")
        else:
            raise BundleError(f"unsupported terrain source vertical datum/product for source-mask code {source_mask_code}")
        if "geoid_mask_code" not in entry:
            entry["geoid_mask_code"] = entry.get("conversion_mask_code", source_mask_code)
        entry.pop("conversion_mask_code", None)
        if entry.get("warning") is None:
            entry.pop("warning", None)
        if "warning" not in entry and "quality_warning" in entry:
            entry["warning"] = entry.pop("quality_warning")
        source_code_refs[str(source_mask_code)] = entry
    numeric_validation = {
        "max_residual_m": 1.91e-6,
        "independent_method": "Independent PROJ spot comparison of this real artifact's source H, geoid N and ellipsoidal h, verified by the Main Lead.",
    }
    for source_reference in source_code_refs.values():
        source_reference.setdefault("geoid_grid_id", GEOID_ID)
        source_reference.setdefault("geoid_grid_sha256", GEOID_SHA256)
        source_reference.setdefault("interpolation_method", str(conversion.get("method", "bilinear_interpolation_of_point_registered_grid")))
        source_reference.setdefault("numeric_validation", numeric_validation)
    spatial = {
        "horizontal_crs": "EPSG:4326",
        "horizontal_datum": "WGS84",
        "horizontal_realization": str(source.get("horizontal", {}).get("datum", "")),
        "axis_order": ["longitude", "latitude"],
        "has_elevation": True,
        "source_vertical_datum": "per_sample_source_mask",
        "height_type": "ellipsoidal",
        "vertical_datum": "WGS84_ELLIPSOIDAL",
        "vertical_conversion": {"vertical_references_by_source_code": source_code_refs},
    }
    raw_coverage = source.get("coverage", {})
    if not isinstance(raw_coverage, dict):
        raise BundleError("terrain coverage record must be an object")
    sample_count = raw_coverage.get("sample_count", raw_coverage.get("valid_count"))
    if sample_count is not None and (not isinstance(sample_count, int) or isinstance(sample_count, bool) or not 0 <= sample_count <= MAX_RASTER_SAMPLES):
        raise BundleError("terrain sample_count must be a bounded nonnegative integer")
    if source.get("status") == "ready" and (sample_count is None or sample_count <= 0):
        raise BundleError("ready terrain requires a positive sample_count")
    coverage = {
        "coverage_claim": str(raw_coverage.get("coverage_claim", "source-backed emitted samples only; not a completeness claim")),
        "coverage_confidence": str(raw_coverage.get("coverage_confidence", "per-sample source and quality masks with provider lineage")),
        "complete_for_emitted_samples": bool(raw_coverage.get("complete_for_emitted_samples", True)),
        "source_coverage": str(raw_coverage.get("coverage_claim", "source-backed samples only")),
    }
    support_payloads = [payload for payload in payloads if payload["payload_kind"] == "terrain_boundary_support"]
    supported_edges: set[str] = set()
    for payload in support_payloads:
        supported_edges.update(edge["edge"] for edge in payload.get("boundary_support_edges", []))
    missing_edges = sorted({"north", "east", "south", "west"} - supported_edges)
    status = str(source["status"])
    disclosure = str(raw_coverage.get("disclosure", raw_coverage.get("coverage_claim", ""))).strip()
    if status == "ready" and missing_edges:
        status = "partial"
        disclosure = "Terrain source samples are valid, but boundary support is missing for: " + ", ".join(missing_edges) + ". The mesh edge remains explicitly incomplete."
    if status == "partial" and not disclosure:
        disclosure = "Terrain producer reported partial source or boundary coverage."
    transform = source.get("transform", {})
    if not isinstance(transform, dict) or not transform:
        transform = {"source_grid": source["grid"]}
    record: dict[str, Any] = {
        "status": status,
        "requested": bool(source.get("requested", True)),
        "payloads": payloads,
        "coverage": coverage,
        "spatial_reference": spatial,
        "source_lineage": source.get("source_lineage", []),
        "attribution": source.get("attribution", []),
        "transform": transform,
        "producer_metadata": {
            "source_grid": source["grid"],
            "placement_surface": source.get("placement_surface", {}),
            "source_mask_legend": source.get("source_mask_legend", {}),
            "quality_mask_legend": source.get("quality_mask_legend", {}),
            "geoid_conversion": conversion,
            "boundary_support_missing_edges": missing_edges,
            "raw_producer_terrain_record": source,
        },
    }
    if sample_count is not None:
        record["sample_count"] = sample_count
    if status == "partial":
        record["disclosure"] = disclosure
        record["gap_declared"] = True
        record["gap_reason"] = "terrain_boundary_support_incomplete" if missing_edges else str(raw_coverage.get("gap_reason", "terrain_source_coverage_partial"))
    if status in ("no_source_coverage", "not_generated", "failed", "cancelled"):
        record["gap_declared"] = True
        record["gap_reason"] = str(raw_coverage.get("gap_reason", f"Terrain producer reported {status}."))
        if status in ("not_generated", "failed", "cancelled"):
            record["error_code"] = str(source.get("error_code", f"terrain_{status}"))
    return record
def feature_layer_record(
    layer: dict[str, Any],
    source_root: Path,
    staging_root: Path,
    seen: set[str],
    copied_bytes: list[int],
    geometry_budget: list[int],
    tile_bounds: dict[str, float] | None = None,
) -> dict[str, Any]:
    layer_id = layer["layer_id"]
    status, outcome_details = status_of(layer)
    raw_descriptors = layer.get("payloads", [])
    if not isinstance(raw_descriptors, list):
        raise BundleError(f"{layer_id} payloads must be an array")
    count_field = "feature_count" if layer_id in ("roads", "buildings", "water") else "pixel_count"
    source_count = layer.get(count_field)
    if source_count is not None and (not isinstance(source_count, int) or isinstance(source_count, bool) or source_count < 0):
        raise BundleError(f"{layer_id} {count_field} must be null/absent or a nonnegative integer")
    if status == "ready" and source_count is None:
        raise BundleError(f"ready {layer_id} requires {count_field}")
    metadata = layer.get("metadata", {})
    if metadata is None:
        metadata = {}
    if not isinstance(metadata, dict):
        raise BundleError(f"{layer_id} metadata must be an object")
    raw_transform = layer.get("transform", {})
    if raw_transform is None:
        raw_transform = {}
    if not isinstance(raw_transform, dict):
        raise BundleError(f"{layer_id} transform must be an object")
    layer_transform = dict(raw_transform)
    for key in ("origin_reference", "pixel_registration", "sample_coordinate_rule", "width", "height", "row_column_order", "nodata", "crs", "axis_order"):
        if key in raw_transform and key in metadata and raw_transform[key] != metadata[key]:
            raise BundleError(f"{layer_id} transform and metadata disagree for {key}")
    transform_affine = raw_transform.get("raster_affine_lon_lat", raw_transform.get("affine_wgs84_lon_lat"))
    metadata_affine = metadata.get("affine_wgs84_lon_lat", metadata.get("raster_affine_lon_lat"))
    if transform_affine is not None and metadata_affine is not None:
        if not isinstance(transform_affine, list) or not isinstance(metadata_affine, list) or len(transform_affine) != 6 or len(metadata_affine) != 6:
            raise BundleError(f"{layer_id} affine arrays must each contain six GDAL-order coefficients")
        for index, (left, right) in enumerate(zip(transform_affine, metadata_affine)):
            if not isinstance(left, (int, float)) or isinstance(left, bool) or not math.isfinite(float(left)) or not isinstance(right, (int, float)) or isinstance(right, bool) or not math.isfinite(float(right)) or float(left) != float(right):
                raise BundleError(f"{layer_id} transform and metadata affine coefficient {index} disagree")
    for key in ("raster_affine_lon_lat", "affine_wgs84_lon_lat", "origin_reference", "pixel_registration", "sample_coordinate_rule", "width", "height", "row_column_order", "nodata", "crs", "axis_order"):
        if key not in layer_transform and key in metadata:
            layer_transform[key] = metadata[key]
    raw_bounds = layer.get("query_bounds_wgs84")
    if isinstance(raw_bounds, list) and len(raw_bounds) == 4:
        raw_bounds = dict(zip(("west_deg", "south_deg", "east_deg", "north_deg"), raw_bounds))
    if raw_bounds is not None:
        if not isinstance(raw_bounds, dict):
            raise BundleError(f"{layer_id} query bounds must be a four-value array or object")
        checked_bounds: dict[str, float] = {}
        for key in ("west_deg", "south_deg", "east_deg", "north_deg"):
            value = raw_bounds.get(key)
            if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(float(value)):
                raise BundleError(f"{layer_id} query bound {key} must be finite")
            checked_bounds[key] = float(value)
        if not (-180.0 <= checked_bounds["west_deg"] < checked_bounds["east_deg"] <= 180.0 and -90.0 <= checked_bounds["south_deg"] < checked_bounds["north_deg"] <= 90.0):
            raise BundleError(f"{layer_id} query bounds must be an ordered nondegenerate WGS84 extent")
        if tile_bounds is not None and not (
            tile_bounds["west_deg"] <= checked_bounds["west_deg"] < checked_bounds["east_deg"] <= tile_bounds["east_deg"]
            and tile_bounds["south_deg"] <= checked_bounds["south_deg"] < checked_bounds["north_deg"] <= tile_bounds["north_deg"]
        ):
            raise BundleError(f"{layer_id} query bounds escape the canonical WFG-1 tile")
        raw_bounds = checked_bounds
    if count_field == "feature_count":
        positions = [0]
        payloads = remap_payloads(
            raw_descriptors, source_root, staging_root, layer_id, seen, copied_bytes, [0],
            layer_transform, positions, geometry_budget=geometry_budget,
        )
        actual_count = sum(int(payload["feature_count"]) for payload in payloads)
        if source_count is not None and actual_count != source_count:
            raise BundleError(f"vector layer {layer_id} feature count differs from its verified GeoJSON shards")
        if source_count is not None and source_count > MAX_VECTOR_FEATURES:
            raise BundleError(f"vector layer {layer_id} exceeds the configured 2M feature limit")
        if source_count is not None and source_count > 0 and not payloads:
            raise BundleError(f"vector layer {layer_id} has features but no GeoJSON payloads")
    else:
        if not isinstance(raw_bounds, (dict, type(None))):
            raise BundleError(f"{layer_id} raster query bounds must be a four-value array or object")
        if source_count == 0:
            if raw_bounds is None:
                raise BundleError(f"ready zero-pixel {layer_id} query needs WFG-1 query bounds")
            window = metadata.get("source_window_row_col_height_width")
            if isinstance(window, list) and len(window) == 4:
                win_height, win_width = window[2], window[3]
            else:
                win_height, win_width = layer_transform.get("height"), layer_transform.get("width")
            if not isinstance(win_height, int) or isinstance(win_height, bool) or not isinstance(win_width, int) or isinstance(win_width, bool) or win_height < 0 or win_width < 0 or win_height * win_width != 0:
                raise BundleError(f"ready zero-pixel {layer_id} query lacks an explicit empty source window")
            empty_sha = hashlib.sha256(b"").hexdigest()
            for descriptor in raw_descriptors:
                if not isinstance(descriptor, dict):
                    raise BundleError(f"{layer_id} zero-pixel descriptor must be an object")
                payload_file = safe_payload(source_root, descriptor.get("path"))
                if descriptor.get("size_bytes") != 0 or descriptor.get("sha256") != empty_sha or payload_file.stat().st_size != 0 or sha256_file(payload_file) != empty_sha:
                    raise BundleError(f"{layer_id} zero-pixel payload must be a verified zero-byte file")
                shape = descriptor.get("shape")
                if shape is not None and (not isinstance(shape, list) or len(shape) != 2 or any(not isinstance(value, int) or isinstance(value, bool) or value < 0 for value in shape) or shape[0] * shape[1] != 0):
                    raise BundleError(f"{layer_id} zero-pixel payload shape must contain a zero dimension")
            payloads = []
        else:
            if "height" not in layer_transform or "width" not in layer_transform:
                raise BundleError(f"{layer_id} raster transform must declare width and height")
            height, width = layer_transform["height"], layer_transform["width"]
            if not isinstance(height, int) or isinstance(height, bool) or not isinstance(width, int) or isinstance(width, bool):
                raise BundleError(f"{layer_id} raster width and height must be exact integers")
            promoted_descriptors = []
            for raw_descriptor in raw_descriptors:
                if not isinstance(raw_descriptor, dict):
                    raise BundleError(f"{layer_id} raster descriptor must be an object")
                descriptor = dict(raw_descriptor)
                descriptor["_source_descriptor"] = dict(raw_descriptor)
                if "shape" in descriptor and descriptor["shape"] != [height, width]:
                    raise BundleError(f"{layer_id} payload shape contradicts producer width/height metadata")
                if "no_data_value" in descriptor and "nodata" in metadata and descriptor["no_data_value"] != metadata["nodata"]:
                    raise BundleError(f"{layer_id} payload no-data value contradicts producer metadata")
                descriptor.setdefault("shape", [height, width])
                descriptor.setdefault("dtype", "uint8")
                descriptor.setdefault("byte_order", "not_applicable")
                descriptor.setdefault("row_order", "row_major_north_to_south_west_to_east")
                if "no_data_value" not in descriptor:
                    descriptor["no_data_value"] = metadata.get("nodata")
                descriptor.setdefault("pixel_registration", layer_transform.get("pixel_registration"))
                descriptor.setdefault("horizontal_crs", layer_transform.get("crs", "EPSG:4326"))
                descriptor.setdefault("axis_order", layer_transform.get("axis_order", ["longitude", "latitude"]))
                promoted_descriptors.append(descriptor)
            payloads = remap_payloads(
                promoted_descriptors, source_root, staging_root, layer_id, seen, copied_bytes, [0],
                layer_transform,
            )
            if source_count is not None and source_count > MAX_RASTER_SAMPLES:
                raise BundleError(f"raster layer {layer_id} exceeds the configured 10M pixel limit")
            if status == "ready" and not payloads:
                raise BundleError(f"ready nonempty raster layer {layer_id} requires a source payload")
            actual_pixels = sum(int(payload["shape"][0]) * int(payload["shape"][1]) for payload in payloads)
            if source_count is not None and actual_pixels != source_count:
                raise BundleError(f"raster layer {layer_id} pixel count differs from its verified payload dimensions")
    source_spatial = layer.get("spatial_reference", {})
    if source_spatial is None:
        source_spatial = {}
    if not isinstance(source_spatial, dict):
        raise BundleError(f"feature layer {layer_id} spatial_reference must be an object")
    horizontal_crs = source_spatial.get("horizontal_crs", layer_transform.get("crs", "EPSG:4326"))
    if horizontal_crs not in ("EPSG:4326", "EPSG:4979"):
        raise BundleError(f"feature layer {layer_id} declares unsupported source CRS {horizontal_crs}")
    spatial: dict[str, Any] = {
        "horizontal_crs": "EPSG:4326",
        "horizontal_datum": "WGS84",
        "axis_order": ["longitude", "latitude"],
        "has_elevation": False,
        "source_vertical_datum": "not_applicable",
        "height_type": "not_applicable",
        "vertical_datum": "not_applicable",
    }
    realization = source_spatial.get("horizontal_realization")
    if isinstance(realization, str) and realization:
        spatial["horizontal_realization"] = realization
    epoch = source_spatial.get("coordinate_epoch")
    if epoch is not None:
        if not isinstance(epoch, (int, float)) or isinstance(epoch, bool) or not math.isfinite(float(epoch)):
            raise BundleError(f"feature layer {layer_id} coordinate_epoch must be finite")
        spatial["coordinate_epoch"] = float(epoch)
    if raw_bounds is not None:
        if not isinstance(raw_bounds, dict):
            raise BundleError(f"feature layer {layer_id} query bounds are malformed")
        query_bounds: dict[str, float] = {}
        for key in ("west_deg", "south_deg", "east_deg", "north_deg"):
            value = raw_bounds.get(key)
            if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(float(value)):
                raise BundleError(f"feature layer {layer_id} query bound {key} is invalid")
            query_bounds[key] = float(value)
    else:
        query_bounds = None
    claim = str(layer.get("coverage_claim", "")).strip() or f"Producer layer outcome is {status}; no completeness or surveyed-absence claim is made."
    confidence = str(layer.get("coverage_confidence", "")).strip() or "Producer response and retained lineage; no independent completeness survey is claimed."
    coverage: dict[str, Any] = {"coverage_claim": claim, "coverage_confidence": confidence, "query_bounds_wgs84": query_bounds}
    source_lineage = layer.get("source_lineage", [])
    attribution = layer.get("attribution", [])
    if not isinstance(source_lineage, list) or not isinstance(attribution, list):
        raise BundleError(f"feature layer {layer_id} source_lineage and attribution must be arrays")
    transform = raw_transform
    if not transform:
        if status in ("not_generated", "failed", "cancelled", "no_source_coverage"):
            transform = {"operation": "not_applicable", "reason": "producer did not generate this layer"}
        else:
            raise BundleError(f"feature layer {layer_id} has no declared source-to-payload transform")
    record: dict[str, Any] = {
        "status": status,
        "requested": bool(layer.get("requested", False)),
        "payloads": payloads,
        "coverage": coverage,
        "spatial_reference": spatial,
        "source_lineage": source_lineage,
        "attribution": attribution,
        "transform": transform,
        "producer_metadata": {
            "metadata": metadata,
            "producer_error_code": layer.get("error_code", ""),
            "producer_bundle_outcome": layer.get("bundle_outcome", ""),
            "raw_producer_layer_record": layer,
        },
    }
    if source_count is not None:
        record[count_field] = source_count
    if status == "ready" and count_field == "feature_count" and source_count == 0:
        if query_bounds is None:
            raise BundleError(f"ready zero-feature {layer_id} query lacks geographic query bounds")
        record["disclosure"] = "The provider query completed with zero returned features; this is not a claim of surveyed absence."
    if status == "ready" and count_field == "pixel_count" and source_count == 0:
        if query_bounds is None:
            raise BundleError(f"ready zero-pixel {layer_id} query lacks geographic query bounds")
        record["disclosure"] = "The completed source window contains zero pixel centers in this WFG-1 extent; this is not a claim of surveyed absence."
    gap_reason = outcome_details.get("gap_reason", layer.get("gap_reason"))
    if status in ("partial", "no_source_coverage", "not_generated", "failed", "cancelled"):
        record["gap_declared"] = bool(outcome_details.get("gap_declared", layer.get("gap_declared", True)))
        record["gap_reason"] = str(gap_reason or outcome_details.get("error_code", layer.get("error_code", status)))
    disclosure = outcome_details.get("disclosure", layer.get("disclosure"))
    if status == "partial" and not disclosure:
        disclosure = f"{layer_id} is partial; source coverage or generation details are retained in producer_metadata."
    if disclosure:
        record["disclosure"] = str(disclosure)
    if status in ("not_generated", "failed", "cancelled"):
        record["error_code"] = str(layer.get("error_code", outcome_details.get("error_code", f"{layer_id}_{status}")))
    fallback = outcome_details.get("fallback", layer.get("fallback"))
    if fallback:
        record["fallback"] = fallback
    return record
def feature_producer_metadata(feature_raw: dict[str, Any]) -> dict[str, Any]:
    """Copy manifest-level feature-producer context without normalization/defaulting."""
    producer = feature_raw.get("producer")
    if not isinstance(producer, dict):
        raise BundleError("feature manifest producer must be an object")
    runtime_dependencies = producer.get("runtime_dependencies")
    request = feature_raw.get("request")
    bundle_outcome = feature_raw.get("bundle_outcome")
    coverage_gaps = feature_raw.get("coverage_gaps")
    rights_and_provenance = feature_raw.get("rights_and_provenance")
    consumer_notes = feature_raw.get("consumer_notes")
    if not isinstance(runtime_dependencies, list) or any(not isinstance(value, str) for value in runtime_dependencies):
        raise BundleError("feature producer runtime_dependencies must be an array of strings")
    if not isinstance(request, dict):
        raise BundleError("feature manifest request must be an object")
    if bundle_outcome not in VALID_STATUSES:
        raise BundleError("feature manifest bundle_outcome must use a canonical layer status")
    if not isinstance(coverage_gaps, (list, dict)):
        raise BundleError("feature manifest coverage_gaps must be an array or object")
    if not isinstance(rights_and_provenance, dict):
        raise BundleError("feature manifest rights_and_provenance must be an object")
    if not isinstance(consumer_notes, (list, dict)):
        raise BundleError("feature manifest consumer_notes must be an array or object")
    return {
        "runtime_dependencies": runtime_dependencies,
        "request": request,
        "bundle_outcome": bundle_outcome,
        "coverage_gaps": coverage_gaps,
        "rights_and_provenance": rights_and_provenance,
        "consumer_notes": consumer_notes,
    }


def assemble(args: argparse.Namespace) -> dict[str, Any]:
    if not isinstance(args.features_commit, str) or args.features_commit != FEATURE_COMMIT:
        raise BundleError("features_commit must be the exact pinned generator revision")
    if not isinstance(args.assembler_commit, str) or len(args.assembler_commit) not in (40, 64) or any(ch not in "0123456789abcdef" for ch in args.assembler_commit):
        raise BundleError("assembler commit must be a lowercase 40- or 64-character Git SHA")
    if not isinstance(args.lod, int) or isinstance(args.lod, bool) or not 0 <= args.lod <= 16:
        raise BundleError("runtime representation LOD must be an integer in [0, 16]")
    if args.source_id != SOURCE_ID:
        raise BundleError(f"source_id is fixed by the approved policy as {SOURCE_ID}")
    raw_terrain_path = Path(args.terrain_manifest)
    raw_feature_path = Path(args.features_manifest)
    reject_reparse_path(raw_terrain_path)
    reject_reparse_path(raw_feature_path)
    terrain_path = raw_terrain_path.resolve(strict=True)
    feature_path = raw_feature_path.resolve(strict=True)
    terrain_root = terrain_path.parent
    feature_root = feature_path.parent
    terrain_raw = read_json(terrain_path)
    feature_raw = read_json(feature_path)
    terrain_layer = validate_terrain(terrain_raw)
    feature_layers = validate_feature_manifest(feature_raw, args.features_commit)
    address_id, level, x, y, bounds = canonical_address(terrain_raw, feature_raw)
    terrain_generation = terrain_raw.get("generation", {}).get("cache_key") if isinstance(terrain_raw.get("generation"), dict) else None
    feature_generation = feature_raw.get("bundle_id")
    if not isinstance(terrain_generation, str) or not terrain_generation or not isinstance(feature_generation, str) or not feature_generation:
        raise BundleError("both producer artifacts need immutable generation/artifact IDs")
    terrain_producer = terrain_raw.get("producer")
    feature_producer = feature_raw.get("producer")
    if not isinstance(terrain_producer, dict) or terrain_producer.get("commit") != TERRAIN_COMMIT:
        raise BundleError("terrain producer commit differs from the pinned generator revision")
    if not isinstance(feature_producer, dict) or feature_producer.get("source_revision") != args.features_commit:
        raise BundleError("feature producer source_revision differs from --features-commit")
    created_values = [
        terrain_raw.get("generation", {}).get("created_utc") if isinstance(terrain_raw.get("generation"), dict) else None,
        feature_raw.get("created_at_utc"),
    ]
    created_dates = []
    for value in created_values:
        if not isinstance(value, str) or not value:
            raise BundleError("producer created_at values must be RFC 3339 timestamps")
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as exc:
            raise BundleError("producer created_at values must be RFC 3339 timestamps") from exc
        if parsed.tzinfo is None:
            raise BundleError("producer created_at values must include a UTC offset")
        created_dates.append(parsed)
    created_text = max(created_dates).astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    generation_input = "\x00".join((
        "WF-WORLD-GENERATION-1",
        SOURCE_ID,
        address_id,
        str(args.lod),
        str(terrain_raw["artifact_id"]),
        str(feature_raw["bundle_id"]),
        ASSEMBLER_ID,
        ASSEMBLER_VERSION,
        args.assembler_commit,
    ))
    source_generation = hashlib.sha256(generation_input.encode("utf-8")).hexdigest()
    if args.source_generation and args.source_generation != source_generation:
        raise BundleError("explicit source-generation override does not match the contract-defined composite digest")
    bundle_id = source_generation
    out_path = Path(args.output).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        raise BundleError(f"output directory already exists; choose a new immutable bundle path: {out_path}")
    staging = Path(tempfile.mkdtemp(prefix=f".{out_path.name}.staging-", dir=out_path.parent))
    try:
        seen: set[str] = set()
        copied_bytes = [0]
        geometry_budget = [0]
        terrain_manifest_copy = staging / "provenance" / "terrain-manifest.json"
        feature_manifest_copy = staging / "provenance" / "features-manifest.json"
        terrain_manifest_copy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(terrain_path, terrain_manifest_copy)
        shutil.copyfile(feature_path, feature_manifest_copy)
        terrain_manifest_bytes = terrain_manifest_copy.stat().st_size
        feature_manifest_bytes = feature_manifest_copy.stat().st_size
        if terrain_manifest_bytes > MAX_MANIFEST_BYTES or feature_manifest_bytes > MAX_MANIFEST_BYTES:
            raise BundleError("producer manifest exceeds the 16 MiB consumer manifest limit")
        copied_bytes[0] = terrain_manifest_bytes + feature_manifest_bytes
        if copied_bytes[0] > MAX_BUNDLE_BYTES:
            raise BundleError("producer provenance plus payloads exceed the total bundle size limit")
        layers = {
            "terrain": terrain_layer_record(terrain_raw, terrain_root, staging, seen, copied_bytes, geometry_budget),
        }
        for layer_id in ("roads", "buildings", "water", "landcover", "vegetation"):
            layers[layer_id] = feature_layer_record(feature_layers[layer_id], feature_root, staging, seen, copied_bytes, geometry_budget, bounds)
        if len(seen) + 2 > MAX_BUNDLE_DESCRIPTORS:
            raise BundleError("bundle exceeds the 65,536 payload/provenance descriptor limit")
        if not isinstance(terrain_producer.get("name"), str) or not isinstance(terrain_producer.get("version"), str):
            raise BundleError("terrain producer identity fields must be strings")
        for field in ("id", "version", "source_revision"):
            if not isinstance(feature_producer.get(field), str) or not feature_producer[field]:
                raise BundleError(f"feature producer {field} must be a nonempty string")
        producer_metadata = feature_producer_metadata(feature_raw)
        center_lon = (bounds["west_deg"] + bounds["east_deg"]) * 0.5
        center_lat = (bounds["south_deg"] + bounds["north_deg"]) * 0.5
        manifest = {
            "schema_id": CONTRACT_ID,
            "schema_version": CONTRACT_VERSION,
            "consumer_limit_profile_id": POLICY_PROFILE_ID,
            "bundle_id": bundle_id,
            "created_at_utc": created_text,
            "source_id": SOURCE_ID,
            "source_generation": source_generation,
            "lod": args.lod,
            "address": {
                "scheme": "WFG-1",
                "address_id": address_id,
                "level": level,
                "x": x,
                "y": y,
                "tile_bounds": bounds,
                "horizontal_crs": "EPSG:4326",
                "horizontal_datum": "WGS84",
                "axis_order": ["longitude", "latitude"],
                "edge_ownership": "west_south_inclusive_east_north_exclusive_north_pole_exception",
            },
            "tile_origin": {
                "horizontal_crs": "EPSG:4979",
                "horizontal_datum": "WGS84",
                "vertical_datum": "WGS84_ELLIPSOIDAL",
                "height_type": "ellipsoidal",
                "longitude_deg": center_lon,
                "latitude_deg": center_lat,
                "ellipsoidal_height_m": 0.0,
            },
            "producers": {
                "terrain": {
                    "id": terrain_producer["name"],
                    "version": terrain_producer["version"],
                    "commit": terrain_producer["commit"],
                    "contract_id": terrain_raw["contract_id"],
                    "artifact_id": terrain_raw["artifact_id"],
                    "manifest_path": "provenance/terrain-manifest.json",
                    "manifest_size_bytes": terrain_manifest_bytes,
                    "manifest_sha256": sha256_file(terrain_manifest_copy),
                },
                "features": {
                    "id": feature_producer["id"],
                    "version": feature_producer["version"],
                    "commit": feature_producer["source_revision"],
                    "schema_id": feature_raw["schema_id"],
                    "schema_version": feature_raw["schema_version"],
                    "artifact_id": feature_raw["bundle_id"],
                    "manifest_path": "provenance/features-manifest.json",
                    "manifest_size_bytes": feature_manifest_bytes,
                    "manifest_sha256": sha256_file(feature_manifest_copy),
                    "producer_metadata": producer_metadata,
                },
                "assembler": {"id": ASSEMBLER_ID, "version": ASSEMBLER_VERSION, "commit": args.assembler_commit},
            },
            "layers": layers,
        }
        manifest_path = staging / "manifest.json"
        manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")
        if len(manifest_bytes) > MAX_MANIFEST_BYTES:
            raise BundleError("canonical manifest exceeds the named consumer manifest-size limit")
        if copied_bytes[0] + len(manifest_bytes) > MAX_BUNDLE_BYTES:
            raise BundleError("canonical manifest and payloads exceed the total bundle-size consumer limit")
        manifest_path.write_bytes(manifest_bytes)
        if not seen:
            raise BundleError("assembled bundle has no source payloads")
        os.replace(staging, out_path)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return {
        "bundle_id": bundle_id,
        "bundle_path": str(out_path),
        "manifest_sha256": sha256_file(out_path / "manifest.json"),
        "payload_count": len(seen),
        "source_generation": source_generation,
        "address_id": address_id,
        "consumer_limit_profile_id": POLICY_PROFILE_ID,
        "decoded_geometry_bytes": geometry_budget[0],
    }
def main() -> 'int':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--terrain-manifest', required=True, help='manifest.json from the pinned global terrain producer')
    parser.add_argument('--features-manifest', required=True, help='manifest.json from the pinned global feature producer')
    parser.add_argument('--output', required=True, help='new immutable canonical bundle directory')
    parser.add_argument('--lod', type=int, default=0, help='runtime representation level for the fixed WFG-1 address')
    parser.add_argument('--source-id', default=SOURCE_ID)
    parser.add_argument('--features-commit', required=True, help='exact feature producer source_revision; must match the pinned generator commit')
    parser.add_argument('--assembler-commit', required=True, help='exact parent repository commit containing this assembler')
    parser.add_argument('--source-generation', default='', help='optional explicit identity; default hashes exact producer generations/address/LOD')
    args = parser.parse_args()
    try:
        print(json.dumps(assemble(args), sort_keys=True))
    except BundleError as exc:
        print(f'BUNDLE_ASSEMBLY_ERROR: {exc}', file=sys.stderr)
        return 2
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
