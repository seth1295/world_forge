"""Build a bounded, deterministic Golden road-centerline interchange excerpt.

This converter reads only the official Census county archive and the checked-in
Golden terrain manifest/payloads. It writes a small derived feature fixture; it
never retains the raw county archive in the repository.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import struct
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Callable

ARCHIVE_URL = (
    "https://www2.census.gov/geo/tiger/TIGER2026/ROADS/"
    "tl_2026_08059_roads.zip"
)
ARCHIVE_SHA256 = "D0063402AE35789546FBFC3041320AEB139D3B82845D8CA9AB1869DD55DF4001".lower()
ARCHIVE_BYTES = 2_842_936
SOURCE_STEM = "tl_2026_08059_roads"
EXPECTED_MEMBERS = {
    f"{SOURCE_STEM}.cpg",
    f"{SOURCE_STEM}.dbf",
    f"{SOURCE_STEM}.prj",
    f"{SOURCE_STEM}.shp",
    f"{SOURCE_STEM}.shx",
    f"{SOURCE_STEM}.shp.iso.xml",
    f"{SOURCE_STEM}.shp.ea.iso.xml",
}
EXPECTED_FIELDS = [
    ("LINEARID", "C", 22),
    ("FULLNAME", "C", 100),
    ("RTTYP", "C", 1),
    ("MTFCC", "C", 5),
]
SELECTED_ROUTES = {
    "11012811999747": {"FULLNAME": "S Golden Rd", "RTTYP": "M", "MTFCC": "S1400"},
    "1106092818987": {"FULLNAME": "Lookout Mountain Rd", "RTTYP": "M", "MTFCC": "S1400"},
    "110713405478": {"FULLNAME": "US Hwy 6", "RTTYP": "U", "MTFCC": "S1200"},
}
CROP = (-105.24, 39.745, -105.20, 39.765)
MAX_PROJECTED_SEGMENT_M = 10.0
MAX_ARCHIVE_BYTES = 8_000_000
MAX_TERRAIN_MANIFEST_BYTES = 65_536
MAX_TERRAIN_HORIZONTAL_BYTES = 67_108_864
MAX_TERRAIN_HEIGHT_BYTES = 16_777_216
GOLDEN_MANIFEST_BYTES = 6_874
GOLDEN_MANIFEST_SHA256 = "7e7a413a2446dc5464dbddbb215143105f009111fcf155b0a79df6cfe8c014a9"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_bounded_file(
    path: Path,
    max_bytes: int,
    expected_bytes: int | None = None,
) -> bytes:
    """Read one file snapshot after a pre-allocation size check."""
    if max_bytes < 0:
        raise ValueError("file size cap must be nonnegative")
    file_size = path.stat().st_size
    if file_size < 0 or file_size > max_bytes:
        raise ValueError(f"file exceeds its {max_bytes}-byte read cap: {path.name}")
    if expected_bytes is not None and file_size != expected_bytes:
        raise ValueError(f"file size differs from its pinned length: {path.name}")
    with path.open("rb") as source_file:
        buffer = source_file.read(file_size + 1)
    if len(buffer) != file_size:
        raise ValueError(f"file changed size or was truncated during its bounded read: {path.name}")
    return buffer


def require_distinct_output_paths(output_path: Path, vector_path: Path) -> None:
    """Reject destinations that refer to the same normalized or existing file."""
    try:
        resolved_output = output_path.expanduser().resolve(strict=False)
        resolved_vector = vector_path.expanduser().resolve(strict=False)
    except (OSError, RuntimeError) as error:
        raise ValueError("feature output paths cannot be resolved safely") from error

    normalized_output = os.path.normcase(os.path.normpath(os.fspath(resolved_output)))
    normalized_vector = os.path.normcase(os.path.normpath(os.fspath(resolved_vector)))
    if normalized_output == normalized_vector:
        raise ValueError("feature collection and test-vector output paths must resolve to different files")

    try:
        if resolved_output.exists() and resolved_vector.exists() and os.path.samefile(
            resolved_output,
            resolved_vector,
        ):
            raise ValueError("feature collection and test-vector output paths must resolve to different files")
    except OSError as error:
        raise ValueError("feature output paths could not be verified as distinct files") from error


def read_dbf(data: bytes) -> tuple[list[tuple[str, str, int]], list[dict[str, str]]]:
    if len(data) < 33:
        raise ValueError("DBF is shorter than its header")
    record_count = struct.unpack_from("<I", data, 4)[0]
    header_length, record_length = struct.unpack_from("<HH", data, 8)
    if record_count > 250_000 or header_length < 33 or record_length <= 1:
        raise ValueError("DBF header exceeds supported bounds")
    fields: list[tuple[str, str, int]] = []
    offset = 32
    while offset < header_length and data[offset] != 0x0D:
        if offset + 32 > len(data):
            raise ValueError("DBF field descriptor is truncated")
        descriptor = data[offset : offset + 32]
        name = descriptor[:11].split(b"\0", 1)[0].decode("ascii")
        field_type = chr(descriptor[11])
        field_length = descriptor[16]
        fields.append((name, field_type, field_length))
        offset += 32
    if offset >= len(data) or data[offset] != 0x0D or offset + 1 != header_length:
        raise ValueError("DBF field descriptor terminator is invalid")
    if fields != EXPECTED_FIELDS:
        raise ValueError(f"DBF field schema differs from Census 2026 record layout: {fields}")
    if sum(length for _, _, length in fields) + 1 != record_length:
        raise ValueError("DBF record length differs from its field layout")
    minimum_length = header_length + record_count * record_length
    if len(data) not in (minimum_length, minimum_length + 1):
        raise ValueError("DBF byte length does not match its declared records")
    if len(data) == minimum_length + 1 and data[-1] != 0x1A:
        raise ValueError("DBF optional end marker is invalid")

    rows: list[dict[str, str]] = []
    cursor = header_length
    for record_index in range(record_count):
        record = data[cursor : cursor + record_length]
        if len(record) != record_length:
            raise ValueError(f"DBF record {record_index} is truncated")
        cursor += record_length
        if record[0] == 0x2A:
            rows.append({})
            continue
        if record[0] != 0x20:
            raise ValueError(f"DBF record {record_index} has an invalid deletion flag")
        row: dict[str, str] = {}
        field_cursor = 1
        for name, _, field_length in fields:
            raw = record[field_cursor : field_cursor + field_length]
            row[name] = raw.decode("utf-8").strip()
            field_cursor += field_length
        rows.append(row)
    return fields, rows


def read_polyline_shp(data: bytes) -> list[list[list[tuple[float, float]]]]:
    if len(data) < 100:
        raise ValueError("SHP is shorter than its header")
    if struct.unpack_from(">i", data, 0)[0] != 9994:
        raise ValueError("SHP file code is invalid")
    declared_words = struct.unpack_from(">i", data, 24)[0]
    if declared_words * 2 != len(data):
        raise ValueError("SHP file length does not match its header")
    if struct.unpack_from("<i", data, 32)[0] != 3:
        raise ValueError("Census All Roads source is not a 2D PolyLine layer")

    records: list[list[list[tuple[float, float]]]] = []
    cursor = 100
    expected_record_number = 1
    while cursor < len(data):
        if cursor + 8 > len(data):
            raise ValueError("SHP record header is truncated")
        record_number, content_words = struct.unpack_from(">ii", data, cursor)
        cursor += 8
        content_length = content_words * 2
        if record_number != expected_record_number or content_length < 4:
            raise ValueError("SHP record sequence or length is invalid")
        content_end = cursor + content_length
        if content_end > len(data):
            raise ValueError("SHP record content is truncated")
        content = data[cursor:content_end]
        cursor = content_end
        shape_type = struct.unpack_from("<i", content, 0)[0]
        expected_record_number += 1
        if shape_type == 0:
            records.append([])
            continue
        if shape_type != 3 or len(content) < 44:
            raise ValueError("SHP record is not a supported 2D PolyLine")
        part_count, point_count = struct.unpack_from("<ii", content, 36)
        if part_count < 1 or point_count < 2 or part_count > point_count:
            raise ValueError("SHP PolyLine part/point counts are invalid")
        parts_offset = 44
        points_offset = parts_offset + part_count * 4
        expected_length = points_offset + point_count * 16
        if expected_length != len(content):
            raise ValueError("SHP PolyLine content length disagrees with its counts")
        starts = list(struct.unpack_from("<" + "i" * part_count, content, parts_offset))
        if starts[0] != 0 or starts != sorted(starts) or starts[-1] >= point_count:
            raise ValueError("SHP PolyLine part indexes are invalid")
        starts.append(point_count)
        points = [
            struct.unpack_from("<dd", content, points_offset + index * 16)
            for index in range(point_count)
        ]
        parts: list[list[tuple[float, float]]] = []
        for part_index in range(part_count):
            part = points[starts[part_index] : starts[part_index + 1]]
            if len(part) < 2:
                raise ValueError("SHP PolyLine part has fewer than two points")
            parts.append(part)
        records.append(parts)
    if cursor != len(data):
        raise ValueError("SHP has trailing bytes")
    return records


def clip_segment(
    start: tuple[float, float],
    end: tuple[float, float],
    bounds: tuple[float, float, float, float] = CROP,
) -> tuple[tuple[float, float], tuple[float, float]] | None:
    west, south, east, north = bounds
    x0, y0 = start
    x1, y1 = end
    dx = x1 - x0
    dy = y1 - y0
    t_enter = 0.0
    t_exit = 1.0
    for p, q in (
        (-dx, x0 - west),
        (dx, east - x0),
        (-dy, y0 - south),
        (dy, north - y0),
    ):
        if p == 0.0:
            if q < 0.0:
                return None
            continue
        ratio = q / p
        if p < 0.0:
            if ratio > t_exit:
                return None
            t_enter = max(t_enter, ratio)
        else:
            if ratio < t_enter:
                return None
            t_exit = min(t_exit, ratio)
    if t_enter > t_exit:
        return None

    def point_at(t: float) -> tuple[float, float]:
        if t == 0.0:
            return start
        if t == 1.0:
            return end
        return (x0 + t * dx, y0 + t * dy)

    clipped_start = point_at(t_enter)
    clipped_end = point_at(t_exit)
    if clipped_start == clipped_end:
        return None
    return clipped_start, clipped_end


def clip_polyline(
    parts: list[list[tuple[float, float]]],
) -> list[list[tuple[float, float]]]:
    clipped_parts: list[list[tuple[float, float]]] = []
    for part in parts:
        current: list[tuple[float, float]] = []
        for start, end in zip(part, part[1:]):
            clipped = clip_segment(start, end)
            if clipped is None:
                if len(current) >= 2:
                    clipped_parts.append(current)
                current = []
                continue
            clipped_start, clipped_end = clipped
            if current and current[-1] != clipped_start:
                if len(current) >= 2:
                    clipped_parts.append(current)
                current = []
            if not current:
                current = [clipped_start]
            if current[-1] != clipped_end:
                current.append(clipped_end)
        if len(current) >= 2:
            clipped_parts.append(current)
    return clipped_parts


def load_projection_tools() -> tuple[Callable[..., Any], dict[str, str]]:
    try:
        import rasterio
        from rasterio.warp import transform
    except ImportError as error:
        raise RuntimeError(
            "Rasterio 1.5.2 is required for the exact Golden-frame projection"
        ) from error
    expected_versions = {
        "python": "3.12.10",
        "rasterio": "1.5.2",
        "gdal": "3.12.2",
        "proj": "9.7.1",
    }
    versions = {
        "python": ".".join(str(part) for part in sys.version_info[:3]),
        "rasterio": rasterio.__version__,
        "gdal": rasterio.__gdal_version__,
        "proj": rasterio.__proj_version__,
    }
    if versions != expected_versions:
        raise RuntimeError(f"projection tool versions differ from the recorded fixture: {versions}")
    return transform, versions


def project_points(
    source_points: list[tuple[float, float]],
    projection_wkt2: str,
    transform: Callable[..., Any],
) -> list[tuple[float, float]]:
    if not source_points:
        return []
    eastings, northings = transform(
        "EPSG:4269",
        projection_wkt2,
        [point[0] for point in source_points],
        [point[1] for point in source_points],
    )
    result = list(zip((float(value) for value in eastings), (float(value) for value in northings)))
    if any(not math.isfinite(easting) or not math.isfinite(northing) for easting, northing in result):
        raise ValueError("PROJ returned a non-finite feature coordinate")
    return result


def resample_projected_source_line(
    source_line: list[tuple[float, float]],
    projection_wkt2: str,
    transform: Callable[..., Any],
    max_segment_m: float = MAX_PROJECTED_SEGMENT_M,
) -> list[dict[str, Any]]:
    if len(source_line) < 2 or not math.isfinite(max_segment_m) or max_segment_m <= 0.0:
        raise ValueError("resampling requires a line and a positive finite interval")
    projected_original = project_points(source_line, projection_wkt2, transform)
    resampled_source: list[tuple[float, float]] = []
    for index, (source_start, source_end) in enumerate(zip(source_line, source_line[1:])):
        projected_start = projected_original[index]
        projected_end = projected_original[index + 1]
        distance = math.hypot(
            projected_end[0] - projected_start[0],
            projected_end[1] - projected_start[1],
        )
        if distance == 0.0:
            if not resampled_source:
                resampled_source.append(source_start)
            continue
        interval_count = max(1, math.ceil(distance / max_segment_m))
        for step in range(interval_count):
            ratio = step / interval_count
            resampled_source.append(
                (
                    source_start[0] + (source_end[0] - source_start[0]) * ratio,
                    source_start[1] + (source_end[1] - source_start[1]) * ratio,
                )
            )
    if not resampled_source or resampled_source[-1] != source_line[-1]:
        resampled_source.append(source_line[-1])
    projected_resampled = project_points(resampled_source, projection_wkt2, transform)
    return [
        {
            "source_lon_lat_deg": [source_lon, source_lat],
            "local_xy_m": [easting, northing],
        }
        for (source_lon, source_lat), (easting, northing) in zip(
            resampled_source, projected_resampled
        )
    ]


def validate_projection_identity(
    terrain_manifest: dict[str, Any],
    terrain_horizontal_xy: bytes,
    terrain_heights: bytes,
    transform: Callable[..., Any],
) -> dict[str, Any]:
    frame = terrain_manifest["frame"]
    origin = frame["origin"]
    affine = terrain_manifest["source"]["raster"]["affine"]
    window = terrain_manifest["grid"]["source_window"]
    columns = int(terrain_manifest["grid"]["columns"])
    row = 75
    column = 150
    if not (0 <= row < int(terrain_manifest["grid"]["rows"]) and 0 <= column < columns):
        raise ValueError("Golden test sample is not inside the checked-in terrain window")
    source_row = int(window["row_offset"]) + row
    source_column = int(window["column_offset"]) + column
    source_lon = float(affine["x_origin"]) + (source_column + 0.5) * float(affine["pixel_width"])
    source_lat = float(affine["y_origin"]) + (source_row + 0.5) * float(affine["pixel_height"])
    projected = project_points(
        [(source_lon, source_lat)],
        str(frame["horizontal"]["projection_wkt2"]),
        transform,
    )[0]
    sample_index = row * columns + column
    sample_easting, sample_northing = struct.unpack_from(
        "<dd", terrain_horizontal_xy, sample_index * 16
    )
    sample_height = struct.unpack_from("<f", terrain_heights, sample_index * 4)[0]
    if projected != (sample_easting, sample_northing):
        raise ValueError(
            "EPSG:4269 projection at the Golden test sample does not exactly match its bundled XY sample"
        )
    anchor_row = int(origin["source_row"]) - int(window["row_offset"])
    anchor_column = int(origin["source_column"]) - int(window["column_offset"])
    anchor_index = anchor_row * columns + anchor_column
    anchor_height = struct.unpack_from("<f", terrain_heights, anchor_index * 4)[0]
    if anchor_height != float(origin["height_navd88_m"]):
        raise ValueError("Golden H0 differs from its source DEM anchor sample")
    return {
        "fixture_id": "golden-terrain-grid-sample-v1",
        "fixture_only": True,
        "notice": "A test road-coordinate pair, not a Census road feature.",
        "frame_id": frame["frame_id"],
        "source_crs": "EPSG:4269",
        "source_lon_lat_deg": [source_lon, source_lat],
        "local_xy_m": [sample_easting, sample_northing],
        "terrain_grid_row": row,
        "terrain_grid_column": column,
        "source_raster_row": source_row,
        "source_raster_column": source_column,
        "height_navd88_m": float(sample_height),
        "h0_navd88_m": float(origin["height_navd88_m"]),
        "local_up_m": float(sample_height) - float(origin["height_navd88_m"]),
    }


def metadata_title(metadata_xml: bytes) -> str:
    root = ET.fromstring(metadata_xml)
    for element in root.iter():
        if element.tag.endswith("CharacterString") and element.text:
            value = element.text.strip()
            if value == "TIGER/Line Shapefile, 2026, County, Jefferson County, CO, All Roads":
                return value
    raise ValueError("Official ISO metadata title was not found")


def build_output(
    archive_path: Path,
    terrain_manifest_path: Path,
    horizontal_path: Path,
    heights_path: Path,
    output_path: Path,
    vector_path: Path,
) -> dict[str, Any]:
    require_distinct_output_paths(output_path, vector_path)
    archive_bytes = read_bounded_file(archive_path, MAX_ARCHIVE_BYTES, ARCHIVE_BYTES)
    if len(archive_bytes) != ARCHIVE_BYTES or sha256(archive_bytes) != ARCHIVE_SHA256:
        raise ValueError("source ZIP size or SHA-256 does not match the selected 2026 Census archive")

    with zipfile.ZipFile(io.BytesIO(archive_bytes), "r") as archive:
        names = set(archive.namelist())
        if names != EXPECTED_MEMBERS:
            raise ValueError(f"archive component set differs from the official 2026 layer: {sorted(names)}")
        components: dict[str, bytes] = {}
        for name in sorted(names):
            info = archive.getinfo(name)
            if info.file_size > MAX_ARCHIVE_BYTES or info.is_dir():
                raise ValueError("archive component is a directory or exceeds its bounded size")
            components[name] = archive.read(name)
            if len(components[name]) != info.file_size:
                raise ValueError(f"archive component {name} was truncated")

    prj_text = components[f"{SOURCE_STEM}.prj"].decode("ascii").strip()
    if (
        "GEOGCS[\"GCS_North_American_1983\"" not in prj_text
        or "DATUM[\"D_North_American_1983\"" not in prj_text
        or "SPHEROID[\"GRS_1980\",6378137,298.257222101]" not in prj_text
        or "UNIT[\"Degree\"" not in prj_text
    ):
        raise ValueError("Census .prj does not identify GCS NAD83 / GRS80 geographic coordinates")
    if components[f"{SOURCE_STEM}.cpg"].decode("ascii").strip().upper() != "UTF-8":
        raise ValueError("Census .cpg is not UTF-8")

    fields, rows = read_dbf(components[f"{SOURCE_STEM}.dbf"])
    shape_records = read_polyline_shp(components[f"{SOURCE_STEM}.shp"])
    if len(rows) != len(shape_records):
        raise ValueError("SHP and DBF record counts do not match")
    shx = components[f"{SOURCE_STEM}.shx"]
    if len(shx) != 100 + len(rows) * 8 or struct.unpack_from("<i", shx, 32)[0] != 3:
        raise ValueError("SHX record count or shape type is invalid")

    terrain_manifest_bytes = read_bounded_file(
        terrain_manifest_path,
        MAX_TERRAIN_MANIFEST_BYTES,
        GOLDEN_MANIFEST_BYTES,
    )
    if sha256(terrain_manifest_bytes) != GOLDEN_MANIFEST_SHA256:
        raise ValueError("Golden terrain manifest SHA-256 differs from the pinned support manifest")
    terrain_manifest = json.loads(terrain_manifest_bytes.decode("utf-8"))
    frame = terrain_manifest["frame"]
    horizontal = frame["horizontal"]
    if (
        horizontal["source_crs"] != "EPSG:4269"
        or horizontal["source_axis_order"] != "longitude_latitude"
        or horizontal["datum"] != "NAD83"
        or horizontal["ellipsoid"] != "GRS80"
        or horizontal["realization_epoch"] != "unspecified_by_source_metadata"
    ):
        raise ValueError("Golden terrain frame is not the approved NAD83 / GRS80 local chart")
    pipeline = str(horizontal["operation_proj_pipeline"]).lower()
    if any(token in pipeline for token in ("wgs84", "wgs 84", "towgs84", "hgridshift", "vgridshift", "helmert", "ballpark")):
        raise ValueError("Golden projection pipeline contains an unapproved datum bridge")
    transform, library_versions = load_projection_tools()
    terrain_payloads = terrain_manifest["payloads"]
    terrain_xy = read_bounded_file(
        horizontal_path,
        MAX_TERRAIN_HORIZONTAL_BYTES,
        int(terrain_payloads["horizontal_xy"]["byte_length"]),
    )
    terrain_heights = read_bounded_file(
        heights_path,
        MAX_TERRAIN_HEIGHT_BYTES,
        int(terrain_payloads["height_samples"]["byte_length"]),
    )
    expected_samples = int(terrain_manifest["grid"]["rows"]) * int(terrain_manifest["grid"]["columns"])
    if len(terrain_xy) != expected_samples * 16 or len(terrain_heights) != expected_samples * 4:
        raise ValueError("checked-in Golden terrain payload lengths do not match its grid")
    if sha256(terrain_xy) != terrain_payloads["horizontal_xy"]["sha256"] or sha256(terrain_heights) != terrain_payloads["height_samples"]["sha256"]:
        raise ValueError("checked-in Golden terrain payload hash differs from its manifest")
    sample_fixture = validate_projection_identity(
        terrain_manifest, terrain_xy, terrain_heights, transform
    )

    affine = terrain_manifest["source"]["raster"]["affine"]
    window = terrain_manifest["grid"]["source_window"]
    source_row_offset = int(window["row_offset"])
    source_column_offset = int(window["column_offset"])
    rows_count = int(terrain_manifest["grid"]["rows"])
    columns_count = int(terrain_manifest["grid"]["columns"])
    projection_wkt2 = str(horizontal["projection_wkt2"])
    features: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    source_id_counts: dict[str, int] = {}
    for row in rows:
        if row:
            source_id_counts[row["LINEARID"]] = source_id_counts.get(row["LINEARID"], 0) + 1
    for source_id, expected in SELECTED_ROUTES.items():
        if source_id_counts.get(source_id) != 1:
            raise ValueError(f"selected Census LINEARID is absent or duplicated: {source_id}")
        row = rows[next(index for index, candidate in enumerate(rows) if candidate and candidate["LINEARID"] == source_id)]
        if row["FULLNAME"] != expected["FULLNAME"] or row["RTTYP"] != expected["RTTYP"] or row["MTFCC"] != expected["MTFCC"]:
            raise ValueError(f"selected Census route identity changed for LINEARID {source_id}")
    source_records_with_clip = 0
    source_points_clipped = 0
    for record_index, (row, parts) in enumerate(zip(rows, shape_records)):
        if not row:
            continue
        if row["LINEARID"] not in SELECTED_ROUTES:
            continue
        clipped_parts = clip_polyline(parts)
        if not clipped_parts:
            continue
        source_records_with_clip += 1
        source_id = row["LINEARID"]
        if not source_id or source_id in seen_ids:
            raise ValueError(f"clipped Census LINEARID is empty or duplicated: {source_id!r}")
        seen_ids.add(source_id)
        if len(row["MTFCC"]) != 5:
            raise ValueError(f"clipped Census record {record_index} has no five-character MTFCC")
        path_records: list[dict[str, Any]] = []
        for clipped_part in clipped_parts:
            point_records = resample_projected_source_line(
                clipped_part, projection_wkt2, transform
            )
            if len(point_records) < 2:
                continue
            for point in point_records:
                lon, lat = point["source_lon_lat_deg"]
                if not (CROP[0] <= lon <= CROP[2] and CROP[1] <= lat <= CROP[3]):
                    raise ValueError("clipping produced a source coordinate outside the requested Golden crop")
                point["terrain_grid_rc_hint"] = [
                    (lat - float(affine["y_origin"])) / float(affine["pixel_height"])
                    - 0.5
                    - source_row_offset,
                    (lon - float(affine["x_origin"])) / float(affine["pixel_width"])
                    - 0.5
                    - source_column_offset,
                ]
                easting, northing = point["local_xy_m"]
                if not math.isfinite(easting) or not math.isfinite(northing):
                    raise ValueError("feature projection produced a non-finite coordinate")
                source_points_clipped += 1
            path_records.append({"points": point_records})
        if path_records:
            features.append(
                {
                    "id": source_id,
                    "source_record_index": record_index,
                    "feature_type": "road_path_centerline",
                    "properties": {
                        "LINEARID": source_id,
                        "FULLNAME": row["FULLNAME"],
                        "RTTYP": row["RTTYP"],
                        "MTFCC": row["MTFCC"],
                    },
                    "geometry": {"type": "MultiLineString2D", "paths": path_records},
                }
            )
    if not features or len(features) != source_records_with_clip or seen_ids != set(SELECTED_ROUTES):
        raise ValueError("selected clipped features did not retain all source LINEARID identities")

    archive_components = {
        name: {"byte_length": len(data), "sha256": sha256(data)}
        for name, data in sorted(components.items())
    }
    contract: dict[str, Any] = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "contract_id": "urn:worldforge:contract:road-centerlines:1.0.0",
        "schema_version": 1,
        "feature_type": "road_path_centerline",
        "coordinate_space": {
            "kind": "regional_projected",
            "frame_id": frame["frame_id"],
            "source_crs": "EPSG:4269",
            "source_axis_order": "longitude_latitude",
            "horizontal_datum": "NAD83",
            "ellipsoid": "GRS80",
            "realization_epoch": "unspecified_by_source_metadata",
            "projection_method": horizontal["projection_method"],
            "projection_wkt2": horizontal["projection_wkt2"],
            "operation_proj_pipeline": horizontal["operation_proj_pipeline"],
            "projected_axis_order": "easting_northing",
            "units": "metre",
            "dimensions": 2,
        },
        "frame": frame,
        "frame_definition_sha256": terrain_manifest["frame_definition_sha256"],
        "terrain_support": {
            "contract_id": terrain_manifest["contract_id"],
            "artifact_id": terrain_manifest["artifact_id"],
            "frame_definition_sha256": terrain_manifest["frame_definition_sha256"],
            "frame_id": frame["frame_id"],
            "source_product_id": terrain_manifest["source"]["product_id"],
            "source_raster_sha256": terrain_manifest["source"]["raster"]["sha256"],
            "sample_grid_rows": rows_count,
            "sample_grid_columns": columns_count,
            "row_column_hint_semantics": "fractional indices relative to pixel-centre sample grid, row then column",
            "surface_interpolation": "Terrain Grid v1 triangle mesh using the NW-SE cell diagonal",
            "height_datum": "NAVD88",
            "height_type": "orthometric",
            "height_units": "metre",
            "local_up_expression": "H-H0",
        },
        "source": {
            "provider": "U.S. Census Bureau",
            "dataset": "TIGER/Line 2026 All Roads, county-based shapefile",
            "title": metadata_title(components[f"{SOURCE_STEM}.shp.iso.xml"]),
            "geography": "Jefferson County, Colorado",
            "geography_fips": "08059",
            "vintage": 2026,
            "release_date": "2026-10-14",
            "feature_updates_through": "2026-07",
            "source_uri": ARCHIVE_URL,
            "archive_byte_length": len(archive_bytes),
            "archive_sha256": sha256(archive_bytes),
            "component_hashes": archive_components,
            "source_crs_wkt": prj_text,
            "source_coordinates": {
                "crs": "EPSG:4269",
                "axis_order": "longitude_latitude",
                "horizontal_datum": "NAD83",
                "ellipsoid": "GRS80",
                "realization_epoch": "unspecified_by_source_metadata",
                "dimensions": 2,
                "vertical_datum": "none",
                "has_z": False,
                "road_width_attribute": "absent",
            },
            "accuracy_statement": (
                "Census provides no general positional or attribute accuracy warranty; "
                "six decimal places do not imply positional accuracy. The source metadata "
                "provides no per-feature positional accuracy guarantee for this All Roads layer."
            ),
            "rights_and_attribution": (
                "U.S. Government work; copyright protection is not available under 17 U.S.C. "
                "Section 105. Cite the U.S. Census Bureau. TIGER/Line is a registered Census "
                "Bureau trademark and is not used as a proprietary product name."
            ),
            "conspicuous_trademark_disclaimer": (
                "TIGER/Line® is a registered trademark of the U.S. Census Bureau. "
                "Use of the TIGER/Line® mark is limited to referring to the nature of this data. "
                "The Census Bureau makes no warranty, express or implied, as to positional or "
                "attribute accuracy of this data."
            ),
        },
        "clip_extent": {
            "crs": "EPSG:4269",
            "axis_order": "longitude_latitude",
            "units": "degree",
            "west": CROP[0],
            "south": CROP[1],
            "east": CROP[2],
            "north": CROP[3],
            "meaning": "inclusive clip rectangle in source geographic coordinates",
        },
        "geometry_semantics": {
            "shape": "MultiLineString2D",
            "coordinate_values": ["easting_m", "northing_m"],
            "source_height": "absent",
            "source_width": "absent",
            "drape_height": "sampled from the referenced Golden Terrain Grid v1 support surface",
            "drape_is_measured_road_elevation": False,
            "display_offset": "applied by the diagnostic viewer after terrain sampling; not part of the feature coordinates",
        },
        "resampling": {
            "method": "linear interpolation along source segment in EPSG:4269, then direct projection to the Golden frame",
            "maximum_projected_chord_length_m": MAX_PROJECTED_SEGMENT_M,
            "purpose": "deterministic display tessellation only; adds no source positional detail or road width",
            "library_versions": library_versions,
        },
        "generation": {
            "producer": "WorldForge Roads Feature Producer",
            "version": "1.0.0",
            "source_record_count": len(rows),
            "clipped_feature_count": len(features),
            "resampled_point_count": source_points_clipped,
            "source_record_index_semantics": "zero-based DBF/SHP record order in the official county archive",
            "deterministic_output": True,
        },
        "features": features,
        "selection": [
            {"LINEARID": source_id, **SELECTED_ROUTES[source_id]}
            for source_id in sorted(SELECTED_ROUTES)
        ],
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(
        contract,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8") + b"\n"
    output_path.write_bytes(encoded)
    vector_path.parent.mkdir(parents=True, exist_ok=True)
    vector_path.write_bytes(
        (json.dumps(sample_fixture, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    )
    return {
        "feature_count": len(features),
        "resampled_point_count": source_points_clipped,
        "archive_sha256": sha256(archive_bytes),
        "feature_file_sha256": sha256(encoded),
        "feature_file_byte_length": len(encoded),
        "known_sample_vector": sample_fixture,
        "component_hashes": archive_components,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-zip", required=True, type=Path)
    parser.add_argument(
        "--terrain-manifest",
        type=Path,
        default=Path("integration/assets/terrain/golden/manifest.json"),
    )
    parser.add_argument(
        "--terrain-horizontal-xy",
        type=Path,
        default=Path("integration/assets/terrain/golden/horizontal_xy.f64le"),
    )
    parser.add_argument(
        "--terrain-heights",
        type=Path,
        default=Path("integration/assets/terrain/golden/height_samples.f32le"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("integration/features/golden_roads_v1.json"),
    )
    parser.add_argument(
        "--test-vector",
        type=Path,
        default=Path("integration/features/fixtures/golden_dem_sample_vector_v1.json"),
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        result = build_output(
            arguments.source_zip,
            arguments.terrain_manifest,
            arguments.terrain_horizontal_xy,
            arguments.terrain_heights,
            arguments.output,
            arguments.test_vector,
        )
    except (OSError, ValueError, zipfile.BadZipFile, ET.ParseError, RuntimeError) as error:
        print(f"roads feature build failed: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
