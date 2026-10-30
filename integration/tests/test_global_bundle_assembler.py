"""Synthetic structural tests for the global bundle assembler; never source data."""
import importlib.util
import json
import pathlib
import sys
import uuid
import unittest
import hashlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
ASSEMBLER = ROOT / "tools" / "assemble_global_world_tile_bundle.py"
spec = importlib.util.spec_from_file_location("worldforge_assembler_tested", ASSEMBLER)
assembler = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = assembler
spec.loader.exec_module(assembler)

BOUNDS_PARIS = {"west_deg": 2.25, "south_deg": 48.75, "east_deg": 2.5, "north_deg": 49.0}
VERTICAL = {
    "1": {
        "product": "COP-DEM-GLO-90-F",
        "geoid_mask_code": 1,
        "source_vertical_reference": {"datum": "EGM2008"},
    }
}


def support_feature(edge, index, count, lon, lat, height=120.0):
    support = {
        "edge": edge,
        "edge_index": index,
        "edge_sample_count": count,
        "source_sample_longitude": lon,
        "source_sample_latitude": lat,
        "source_height_H": height - 20.0,
        "source_vertical_datum": "EGM2008",
        "geoid_undulation_N": 20.0,
        "ellipsoidal_height_h": height,
        "source_mask": 1,
        "quality_mask": 1,
        "type_identifier_mask": None,
        "geoid_mask": 1,
        "sample_method": "native_exact",
        "source_to_boundary_offset_m": 0.0,
        "source_artifact": {"product": "COP-DEM-GLO-90-F", "release": "synthetic-test", "asset_id": "fixture"},
        "warning": None,
    }
    return {
        "type": "Feature",
        "id": f"boundary:{edge}:{index}",
        "geometry": {"type": "Point", "coordinates": [lon, lat, height]},
        "properties": {"worldforge": {"boundary_support": support}},
    }


class GlobalBundleAssemblerTests(unittest.TestCase):
    def _inspect(self, name, features, bounds, address, vertical=VERTICAL):
        directory = pathlib.Path(__file__).resolve().parent / (".assembler-fixture-" + uuid.uuid4().hex)
        directory.mkdir()
        path = directory / f"{name}.geojson"
        try:
            path.write_text(json.dumps({"type": "FeatureCollection", "features": features}), encoding="utf-8")
            return assembler._inspect_boundary_support(path, {"feature_count": len(features)}, bounds, vertical, address)
        finally:
            if path.exists():
                path.unlink()
            directory.rmdir()

    def test_wfg_bounds_accept_content_producer_array(self):
        terrain = {"tile": {"id": "wfg1:0:729:555", "level": 0, "x": 729, "y": 555, "bounds_wgs84": BOUNDS_PARIS}}
        features = {"address": {"tile_id": "wfg1:0:729:555", "scheme": "WFG-1", "level": 0, "x": 729, "y": 555, "bounds_wgs84": [2.25, 48.75, 2.5, 49.0]}}
        result = assembler.canonical_address(terrain, features)
        self.assertEqual(result[0], "wfg1:0:729:555")
        bad = json.loads(json.dumps(features))
        bad["address"]["bounds_wgs84"] = [2.5, 48.75, 2.25, 49.0]
        with self.assertRaises(assembler.BundleError):
            assembler.canonical_address(terrain, bad)

    def test_geodesic_reference_and_tie_order(self):
        distance = assembler._geodesic_distance_wgs84_m(0.0, 0.0, 1.0, 0.0)
        self.assertLessEqual(abs(distance - 111319.49079327357), 0.001)
        grid = {
            "rows": 2,
            "columns": 1,
            "pixel_registration": "point",
            "source_affine": {
                "origin_reference": "pixel_corner",
                "x_origin": -0.125,
                "y_origin": 0.125,
                "pixel_width": 0.25,
                "rotation_x": 0.0,
                "rotation_y": 0.0,
                "pixel_height": -0.125,
            },
        }
        assembler._validate_nearest_copdem_grid_sample(grid, 0.0, 0.0, 0.0, 0.0625)
        with self.assertRaises(assembler.BundleError):
            assembler._validate_nearest_copdem_grid_sample(grid, 0.0, 0.0, 0.0, -0.0625)

    def test_regular_antimeridian_and_pole_edge_support(self):
        regular = []
        positions = {
            "north": [(2.25, 49.0), (2.5, 49.0)],
            "east": [(2.5, 48.95), (2.5, 48.75)],
            "south": [(2.49, 48.75), (2.25, 48.75)],
            "west": [(2.25, 48.76), (2.25, 48.99)],
        }
        for edge, points in positions.items():
            regular.extend(support_feature(edge, i, len(points), lon, lat) for i, (lon, lat) in enumerate(points))
        count, edges = self._inspect("regular", regular, BOUNDS_PARIS, {"level": 0, "x": 729, "y": 555})
        self.assertEqual(count, 8)
        self.assertEqual({edge["edge"] for edge in edges}, {"north", "east", "south", "west"})
        antimeridian = []
        positions = {
            "north": [(179.75, 10.25), (-180.0, 10.25)],
            "east": [(-180.0, 10.20), (-180.0, 10.0)],
            "south": [(-180.0, 10.0), (179.75, 10.0)],
            "west": [(179.75, 10.02), (179.75, 10.23)],
        }
        for edge, points in positions.items():
            antimeridian.extend(support_feature(edge, i, len(points), lon, lat) for i, (lon, lat) in enumerate(points))
        count, _ = self._inspect("antimeridian", antimeridian, {"west_deg":179.75,"south_deg":10.0,"east_deg":180.0,"north_deg":10.25}, {"level":0,"x":1439,"y":400})
        self.assertEqual(count, 8)
        pole = support_feature("north", 0, 1, 0.0, 90.0)
        count, edge = self._inspect("pole", [pole], {"west_deg":2.25,"south_deg":89.75,"east_deg":2.5,"north_deg":90.0}, {"level":0,"x":729,"y":719})
        self.assertEqual(count, 1)
        self.assertEqual(edge, [{"edge":"north","sample_count":1}])
        pole["geometry"]["coordinates"][0] = 17.0
        with self.assertRaises(assembler.BundleError):
            self._inspect("bad-pole", [pole], {"west_deg":2.25,"south_deg":89.75,"east_deg":2.5,"north_deg":90.0}, {"level":0,"x":729,"y":719})

    def test_ready_empty_raster_is_verified_then_omitted(self):
        fixture = pathlib.Path(__file__).resolve().parent / (".zero-window-fixture-" + uuid.uuid4().hex)
        output = pathlib.Path(__file__).resolve().parent / (".zero-window-output-" + uuid.uuid4().hex)
        fixture.mkdir()
        output.mkdir()
        payload = fixture / "empty.u8"
        try:
            payload.write_bytes(b"")
            layer = {
                "layer_id": "landcover", "outcome": "ready", "requested": True, "pixel_count": 0,
                "payloads": [{"path":"empty.u8","size_bytes":0,"sha256":hashlib.sha256(b"").hexdigest(),"media_type":"application/octet-stream","representation":"uint8 categorical samples"}],
                "query_bounds_wgs84": [2.25,48.75,2.5,49.0],
                "coverage_claim": "Completed source window contains zero pixel centers.",
                "coverage_confidence": "Synthetic structural fixture.",
                "source_lineage": [], "attribution": ["Synthetic fixture; not source geography."],
                "transform": {"width":0,"height":3000,"origin_reference":"pixel_corner","pixel_registration":"area"},
                "metadata": {"width":0,"height":3000,"nodata":0,"source_window_row_col_height_width":[24000,27000,0,3000]},
            }
            record = assembler.feature_layer_record(layer,fixture,output,set(),[0],[0],BOUNDS_PARIS)
            self.assertEqual(record["status"],"ready")
            self.assertEqual(record["pixel_count"],0)
            self.assertEqual(record["payloads"],[])
            self.assertIn("zero pixel centers",record["disclosure"])
            self.assertEqual(record["producer_metadata"]["metadata"],layer["metadata"])
            self.assertNotIn("metadata",record)
        finally:
            if payload.exists():
                payload.unlink()
            fixture.rmdir()
            output.rmdir()

    def test_producer_revision_gate(self):
        feature_manifest = {
            "schema_id":"urn:worldforge:global-feature-bundle:1.0.0","schema_version":"1.0.0",
            "producer":{"id":"fixture","version":"1","source_revision":"79fd795472ef03cb11a64a87dfe0ce764276a98d"},
        }
        with self.assertRaises(assembler.BundleError):
            assembler.validate_feature_manifest(feature_manifest,assembler.FEATURE_COMMIT)

    def test_producer_and_layer_metadata_are_projected_to_distinct_contract_fields(self):
        raw = {
            "producer": {"runtime_dependencies": ["fixture-runtime"]},
            "request": {"query": "synthetic fixture"},
            "bundle_outcome": "partial",
            "coverage_gaps": [{"reason": "synthetic fixture gap"}],
            "rights_and_provenance": {"fixture": "synthetic only"},
            "consumer_notes": {"fixture": "not source geography"},
        }
        mapped = assembler.feature_producer_metadata(raw)
        self.assertEqual(mapped, {
            "runtime_dependencies": raw["producer"]["runtime_dependencies"],
            "request": raw["request"],
            "bundle_outcome": raw["bundle_outcome"],
            "coverage_gaps": raw["coverage_gaps"],
            "rights_and_provenance": raw["rights_and_provenance"],
            "consumer_notes": raw["consumer_notes"],
        })
        del raw["consumer_notes"]
        with self.assertRaises(assembler.BundleError):
            assembler.feature_producer_metadata(raw)


if __name__ == "__main__":
    unittest.main()
