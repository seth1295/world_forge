"""Contract and source-provenance tests for the Golden road feature excerpt."""
from __future__ import annotations

import hashlib
import json
import math
import os
import struct
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from build_roads_feature_v1 import (
    ARCHIVE_BYTES,
    ARCHIVE_SHA256,
    ARCHIVE_URL,
    EXPECTED_MEMBERS,
    MAX_ARCHIVE_BYTES,
    MAX_PROJECTED_SEGMENT_M,
    SELECTED_ROUTES,
    build_output,
    clip_segment,
    read_bounded_file,
    resample_projected_source_line,
)

ROOT = Path(__file__).resolve().parents[2]
FEATURE_PATH = ROOT / "integration" / "features" / "golden_roads_v1.json"
VECTOR_PATH = ROOT / "integration" / "features" / "fixtures" / "golden_dem_sample_vector_v1.json"
TERRAIN_DIR = ROOT / "integration" / "assets" / "terrain" / "golden"
EXPECTED_FEATURE_SHA256 = "c92a254d1e92727fa325fd1ede7fdc5186b86e1ff4ccf0550f0f8eddbe087d96"
EXPECTED_COMPONENTS = {
    "tl_2026_08059_roads.cpg": (5, "3ad3031f5503a4404af825262ee8232cc04d4ea6683d42c5dd0a2f2a27ac9824"),
    "tl_2026_08059_roads.dbf": (1934775, "d8a1b9e5ce8f1884dad974b05b14253662cbefafa07a0e0a52ec31ad9df36902"),
    "tl_2026_08059_roads.prj": (165, "0b9041e921d9ebb43247d314608fe9e38a0b008ee793067fc1806199ea1fb9dd"),
    "tl_2026_08059_roads.shp": (4365708, "f72b4eafa002de37aa365a181d9a19d723780d86e5ad8d8b65ed9720da58fe62"),
    "tl_2026_08059_roads.shp.ea.iso.xml": (21866, "02c6ff600b5e42e49ea5e58c4b4c12de63effb58026b90c3c1ca6c5e5dec270c"),
    "tl_2026_08059_roads.shp.iso.xml": (50147, "71d81812c5db052859d2bfb8d9f832983184f39dad02a40f84ab05394f678f5a"),
    "tl_2026_08059_roads.shx": (120076, "af4f1884be658f3d56b54a62a19ffc3c5428f30d82f3a453a3b35e4e6fa15946"),
}


class RoadsFeatureContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.collection = json.loads(FEATURE_PATH.read_text(encoding="utf-8"))
        cls.fixture = json.loads(VECTOR_PATH.read_text(encoding="utf-8"))
        cls.terrain_manifest = json.loads((TERRAIN_DIR / "manifest.json").read_text(encoding="utf-8"))

    def test_versioned_contract_reuses_exact_golden_frame(self) -> None:
        self.assertEqual(self.collection["contract_id"], "urn:worldforge:contract:road-centerlines:1.0.0")
        self.assertEqual(self.collection["coordinate_space"]["frame_id"], "wf-vs01:golden-grs80-aeqd")
        self.assertEqual(self.collection["frame"], self.terrain_manifest["frame"])
        self.assertEqual(self.collection["frame_definition_sha256"], self.terrain_manifest["frame_definition_sha256"])
        self.assertEqual(self.collection["terrain_support"]["artifact_id"], self.terrain_manifest["artifact_id"])
        self.assertEqual(self.collection["terrain_support"]["source_raster_sha256"], self.terrain_manifest["source"]["raster"]["sha256"])

    def test_source_and_derived_bundle_hashes(self) -> None:
        feature_bytes = FEATURE_PATH.read_bytes()
        self.assertEqual(hashlib.sha256(feature_bytes).hexdigest(), EXPECTED_FEATURE_SHA256)
        source = self.collection["source"]
        self.assertEqual(source["source_uri"], ARCHIVE_URL)
        self.assertEqual(source["archive_byte_length"], ARCHIVE_BYTES)
        self.assertEqual(source["archive_sha256"], ARCHIVE_SHA256)
        self.assertEqual(set(source["component_hashes"]), EXPECTED_MEMBERS)
        for name, expected in EXPECTED_COMPONENTS.items():
            descriptor = source["component_hashes"][name]
            self.assertEqual((descriptor["byte_length"], descriptor["sha256"]), expected)

    def test_selected_route_ids_and_mtfcc_fields_are_preserved(self) -> None:
        actual = {
            feature["id"]: {
                "FULLNAME": feature["properties"]["FULLNAME"],
                "RTTYP": feature["properties"]["RTTYP"],
                "MTFCC": feature["properties"]["MTFCC"],
            }
            for feature in self.collection["features"]
        }
        self.assertEqual(
            actual,
            {
                source_id: {
                    "FULLNAME": identity["FULLNAME"],
                    "RTTYP": identity["RTTYP"],
                    "MTFCC": identity["MTFCC"],
                }
                for source_id, identity in SELECTED_ROUTES.items()
            },
        )
        for feature in self.collection["features"]:
            self.assertEqual(feature["id"], feature["properties"]["LINEARID"])
            self.assertEqual(feature["feature_type"], "road_path_centerline")

    def test_geometry_is_clipped_finite_two_dimensional_and_resampled(self) -> None:
        clip = self.collection["clip_extent"]
        west, south, east, north = clip["west"], clip["south"], clip["east"], clip["north"]
        point_count = 0
        for feature in self.collection["features"]:
            for path in feature["geometry"]["paths"]:
                points = path["points"]
                self.assertGreaterEqual(len(points), 2)
                for point in points:
                    self.assertNotIn("z", point)
                    self.assertNotIn("width_m", point)
                    self.assertEqual(len(point["source_lon_lat_deg"]), 2)
                    self.assertEqual(len(point["local_xy_m"]), 2)
                    self.assertEqual(len(point["terrain_grid_rc_hint"]), 2)
                    lon, lat = point["source_lon_lat_deg"]
                    easting, northing = point["local_xy_m"]
                    row, column = point["terrain_grid_rc_hint"]
                    self.assertTrue(west <= lon <= east)
                    self.assertTrue(south <= lat <= north)
                    self.assertTrue(all(math.isfinite(value) for value in (lon, lat, easting, northing, row, column)))
                for left, right in zip(points, points[1:]):
                    x0, y0 = left["local_xy_m"]
                    x1, y1 = right["local_xy_m"]
                    self.assertLessEqual(
                        math.hypot(x1 - x0, y1 - y0),
                        MAX_PROJECTED_SEGMENT_M + 1.0e-9,
                    )
                point_count += len(points)
        self.assertEqual(point_count, self.collection["generation"]["resampled_point_count"])
        self.assertEqual(point_count, 364)
        source_coordinates = self.collection["source"]["source_coordinates"]
        self.assertFalse(source_coordinates["has_z"])
        self.assertEqual(source_coordinates["road_width_attribute"], "absent")
        self.assertEqual(source_coordinates["vertical_datum"], "none")

    def test_known_terrain_sample_projection_and_height(self) -> None:
        import rasterio
        from rasterio.warp import transform

        sample = self.fixture
        frame = self.terrain_manifest["frame"]
        affine = self.terrain_manifest["source"]["raster"]["affine"]
        window = self.terrain_manifest["grid"]["source_window"]
        source_row = int(sample["source_raster_row"])
        source_column = int(sample["source_raster_column"])
        local_row = int(sample["terrain_grid_row"])
        local_column = int(sample["terrain_grid_column"])
        lon = float(affine["x_origin"]) + (source_column + 0.5) * float(affine["pixel_width"])
        lat = float(affine["y_origin"]) + (source_row + 0.5) * float(affine["pixel_height"])
        self.assertEqual(lon, sample["source_lon_lat_deg"][0])
        self.assertEqual(lat, sample["source_lon_lat_deg"][1])
        self.assertEqual(source_row - int(window["row_offset"]), local_row)
        self.assertEqual(source_column - int(window["column_offset"]), local_column)

        eastings, northings = transform(
            "EPSG:4269",
            frame["horizontal"]["projection_wkt2"],
            [lon],
            [lat],
        )
        self.assertEqual((eastings[0], northings[0]), tuple(sample["local_xy_m"]))

        index = local_row * int(self.terrain_manifest["grid"]["columns"]) + local_column
        horizontal_bytes = (TERRAIN_DIR / "horizontal_xy.f64le").read_bytes()
        height_bytes = (TERRAIN_DIR / "height_samples.f32le").read_bytes()
        dem_xy = struct.unpack_from("<dd", horizontal_bytes, index * 16)
        dem_height = struct.unpack_from("<f", height_bytes, index * 4)[0]
        h0 = float(frame["origin"]["height_navd88_m"])
        self.assertEqual(dem_xy, tuple(sample["local_xy_m"]))
        self.assertEqual(dem_height, sample["height_navd88_m"])
        self.assertEqual(dem_height - h0, sample["local_up_m"])
        self.assertEqual(rasterio.__version__, "1.5.2")

    def test_resampling_and_output_are_deterministic(self) -> None:
        import rasterio
        from rasterio.warp import transform

        feature = self.collection["features"][0]
        point_records = feature["geometry"]["paths"][0]["points"]
        source_line = [tuple(point["source_lon_lat_deg"]) for point in point_records[:3]]
        wkt = self.collection["coordinate_space"]["projection_wkt2"]
        first = resample_projected_source_line(source_line, wkt, transform)
        second = resample_projected_source_line(source_line, wkt, transform)
        self.assertEqual(first, second)

    def test_clipping_keeps_exact_crop_intersections(self) -> None:
        clipped = clip_segment((-105.25, 39.75), (-105.23, 39.75))
        self.assertIsNotNone(clipped)
        assert clipped is not None
        self.assertEqual(clipped[0][0], -105.24)
        self.assertEqual(clipped[1][0], -105.23)
        self.assertEqual(clipped[0][1], 39.75)
        self.assertEqual(clipped[1][1], 39.75)

    def test_source_zip_bytes_and_component_hashes_when_available(self) -> None:
        archive_path = os.environ.get("WF_CENSUS_ROADS_ZIP", "")
        if not archive_path:
            self.skipTest("Set WF_CENSUS_ROADS_ZIP to the official archive to recheck acquired source bytes")
        archive_bytes = Path(archive_path).read_bytes()
        self.assertEqual(len(archive_bytes), ARCHIVE_BYTES)
        self.assertEqual(hashlib.sha256(archive_bytes).hexdigest(), ARCHIVE_SHA256)
        with zipfile.ZipFile(archive_path, "r") as archive:
            self.assertEqual(set(archive.namelist()), EXPECTED_MEMBERS)
            for name, (expected_length, expected_hash) in EXPECTED_COMPONENTS.items():
                data = archive.read(name)
                self.assertEqual(len(data), expected_length, name)
                self.assertEqual(hashlib.sha256(data).hexdigest(), expected_hash, name)

    def test_oversized_file_is_rejected_before_open_or_read(self) -> None:
        output_directory = os.environ.get("WF_ROADS_BUILD_TEST_DIR", "")
        if not output_directory:
            self.skipTest("Set WF_ROADS_BUILD_TEST_DIR to a task-local temporary directory for bounded-input tests")
        directory = Path(output_directory)
        directory.mkdir(parents=True, exist_ok=True)
        oversized_path = directory / "oversized_input.bin"
        oversized_path.write_bytes(b"x" * (MAX_ARCHIVE_BYTES + 1))
        try:
            with patch.object(Path, "open", side_effect=AssertionError("oversized file was opened")):
                with self.assertRaisesRegex(ValueError, f"{MAX_ARCHIVE_BYTES}-byte read cap"):
                    read_bounded_file(oversized_path, MAX_ARCHIVE_BYTES)
        finally:
            oversized_path.unlink(missing_ok=True)

    def test_mutated_source_archive_is_rejected_from_the_hashed_snapshot(self) -> None:
        archive_path = os.environ.get("WF_CENSUS_ROADS_ZIP", "")
        output_directory = os.environ.get("WF_ROADS_BUILD_TEST_DIR", "")
        if not archive_path or not output_directory:
            self.skipTest("Set source ZIP and task-local output directory to exercise mutated-input rejection")
        directory = Path(output_directory)
        directory.mkdir(parents=True, exist_ok=True)
        mutated_archive = directory / "mutated_roads_source.zip"
        archive_bytes = bytearray(Path(archive_path).read_bytes())
        archive_bytes[0] ^= 1
        mutated_archive.write_bytes(archive_bytes)
        try:
            with self.assertRaisesRegex(ValueError, "source ZIP size or SHA-256"):
                build_output(
                    mutated_archive,
                    ROOT / "integration/assets/terrain/golden/manifest.json",
                    TERRAIN_DIR / "horizontal_xy.f64le",
                    TERRAIN_DIR / "height_samples.f32le",
                    directory / "mutated_archive_output.json",
                    directory / "mutated_archive_vector.json",
                )
        finally:
            mutated_archive.unlink(missing_ok=True)

    def test_mutated_pinned_terrain_manifest_is_rejected_before_parse(self) -> None:
        archive_path = os.environ.get("WF_CENSUS_ROADS_ZIP", "")
        output_directory = os.environ.get("WF_ROADS_BUILD_TEST_DIR", "")
        if not archive_path or not output_directory:
            self.skipTest("Set source ZIP and task-local output directory to exercise mutated-input rejection")
        directory = Path(output_directory)
        directory.mkdir(parents=True, exist_ok=True)
        original_manifest = (TERRAIN_DIR / "manifest.json").read_bytes()
        mutated_manifest = directory / "mutated_golden_manifest.json"
        manifest_bytes = bytearray(original_manifest)
        artifact_id = b"d4b1bb11e84402136f50edf265a66991d8014326378edbeeaa67c4b169e31d98"
        artifact_id_offset = original_manifest.find(artifact_id)
        self.assertGreaterEqual(artifact_id_offset, 0)
        manifest_bytes[artifact_id_offset] = ord("e")  # Keep valid JSON and the pinned byte length.
        mutated_manifest.write_bytes(manifest_bytes)
        try:
            with self.assertRaisesRegex(ValueError, "Golden terrain manifest SHA-256"):
                build_output(
                    Path(archive_path),
                    mutated_manifest,
                    TERRAIN_DIR / "horizontal_xy.f64le",
                    TERRAIN_DIR / "height_samples.f32le",
                    directory / "mutated_manifest_output.json",
                    directory / "mutated_manifest_vector.json",
                )
        finally:
            mutated_manifest.unlink(missing_ok=True)

    def test_mutated_pinned_terrain_payload_is_rejected_before_sampling(self) -> None:
        archive_path = os.environ.get("WF_CENSUS_ROADS_ZIP", "")
        output_directory = os.environ.get("WF_ROADS_BUILD_TEST_DIR", "")
        if not archive_path or not output_directory:
            self.skipTest("Set source ZIP and task-local output directory to exercise mutated-input rejection")
        directory = Path(output_directory)
        directory.mkdir(parents=True, exist_ok=True)
        for payload_name in ("horizontal_xy.f64le", "height_samples.f32le"):
            with self.subTest(payload=payload_name):
                original_payload = (TERRAIN_DIR / payload_name).read_bytes()
                mutated_payload = directory / f"mutated_golden_{payload_name}"
                payload_bytes = bytearray(original_payload)
                payload_bytes[0] ^= 1
                mutated_payload.write_bytes(payload_bytes)
                horizontal_path = mutated_payload if payload_name == "horizontal_xy.f64le" else TERRAIN_DIR / "horizontal_xy.f64le"
                heights_path = mutated_payload if payload_name == "height_samples.f32le" else TERRAIN_DIR / "height_samples.f32le"
                try:
                    with self.assertRaisesRegex(ValueError, "checked-in Golden terrain payload hash"):
                        build_output(
                            Path(archive_path),
                            TERRAIN_DIR / "manifest.json",
                            horizontal_path,
                            heights_path,
                            directory / f"mutated_{payload_name}_output.json",
                            directory / f"mutated_{payload_name}_vector.json",
                        )
                finally:
                    mutated_payload.unlink(missing_ok=True)

    def test_output_aliases_are_rejected_before_any_write(self) -> None:
        archive_path = os.environ.get("WF_CENSUS_ROADS_ZIP", "")
        output_directory = os.environ.get("WF_ROADS_BUILD_TEST_DIR", "")
        if not archive_path or not output_directory:
            self.skipTest("Set source ZIP and task-local output directory to exercise output-path rejection")
        directory = Path(output_directory)
        directory.mkdir(parents=True, exist_ok=True)
        alias_parent = directory / "output_alias_parent"
        alias_parent.mkdir(exist_ok=True)
        manifest = TERRAIN_DIR / "manifest.json"
        horizontal = TERRAIN_DIR / "horizontal_xy.f64le"
        heights = TERRAIN_DIR / "height_samples.f32le"
        sentinel = b"pre-existing output must remain unchanged\n"

        existing_output = directory / "aliased_existing_output.json"
        existing_output.write_bytes(sentinel)
        existing_vector_alias = alias_parent / ".." / existing_output.name
        missing_output = directory / "aliased_missing_output.json"
        missing_vector_alias = alias_parent / ".." / missing_output.name

        hardlink_source = directory / "hardlink_output_source.json"
        hardlink_alias = directory / "hardlink_output_alias.json"
        hardlink_source.write_bytes(sentinel)
        try:
            with self.subTest(alias="normalized-existing"):
                with self.assertRaisesRegex(ValueError, "must resolve to different files"):
                    build_output(
                        Path(archive_path), manifest, horizontal, heights,
                        existing_output, existing_vector_alias,
                    )
                self.assertEqual(existing_output.read_bytes(), sentinel)

            with self.subTest(alias="normalized-missing"):
                self.assertFalse(missing_output.exists())
                with self.assertRaisesRegex(ValueError, "must resolve to different files"):
                    build_output(
                        Path(archive_path), manifest, horizontal, heights,
                        missing_output, missing_vector_alias,
                    )
                self.assertFalse(missing_output.exists())

            with self.subTest(alias="hardlink-existing"):
                os.link(hardlink_source, hardlink_alias)
                with self.assertRaisesRegex(ValueError, "must resolve to different files"):
                    build_output(
                        Path(archive_path), manifest, horizontal, heights,
                        hardlink_source, hardlink_alias,
                    )
                self.assertEqual(hardlink_source.read_bytes(), sentinel)
                self.assertEqual(hardlink_alias.read_bytes(), sentinel)
        finally:
            existing_output.unlink(missing_ok=True)
            missing_output.unlink(missing_ok=True)
            hardlink_alias.unlink(missing_ok=True)
            hardlink_source.unlink(missing_ok=True)
            alias_parent.rmdir()

    def test_rebuilt_output_matches_committed_bytes_when_archive_available(self) -> None:
        archive_path = os.environ.get("WF_CENSUS_ROADS_ZIP", "")
        if not archive_path:
            self.skipTest("Set WF_CENSUS_ROADS_ZIP to reproduce the derived fixture from official source bytes")
        output_directory = os.environ.get("WF_ROADS_BUILD_TEST_DIR", "")
        if not output_directory:
            self.skipTest("Set WF_ROADS_BUILD_TEST_DIR to a task-local temporary directory for deterministic rebuild output")
        directory = Path(output_directory)
        directory.mkdir(parents=True, exist_ok=True)
        output = directory / "roads_rebuild_verify.json"
        vector = directory / "dem_sample_rebuild_verify.json"
        build_output(
            Path(archive_path),
            ROOT / "integration/assets/terrain/golden/manifest.json",
            TERRAIN_DIR / "horizontal_xy.f64le",
            TERRAIN_DIR / "height_samples.f32le",
            output,
            vector,
        )
        self.assertEqual(output.read_bytes(), FEATURE_PATH.read_bytes())
        self.assertEqual(vector.read_bytes(), VECTOR_PATH.read_bytes())


if __name__ == "__main__":
    unittest.main()
