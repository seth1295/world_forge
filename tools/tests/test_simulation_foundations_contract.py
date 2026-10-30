"""Structural conformance tests for the proposed simulation-foundations contracts.

These tests validate schemas and declarative lifecycle rules only. They do not
exercise Godot runtime behavior or claim that a simulation/persistence service
has been implemented.
"""

from __future__ import annotations

import copy
import hashlib
import json
import unittest
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPOSITORY_ROOT / "contracts" / "world_state_v1.schema.json"
EXAMPLE_PATH = (
    REPOSITORY_ROOT
    / "contracts"
    / "examples"
    / "world_state_v1_minimal.json"
)
LIFECYCLE_PATH = (
    REPOSITORY_ROOT / "contracts" / "stream_binding_lifecycle_v1.json"
)
MAX_BINARY64 = 1.7976931348623157e308


def _reject_non_json_constant(value: str) -> None:
    raise ValueError(f"invalid JSON numeric constant: {value}")


def _read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as source:
        return json.load(source, parse_constant=_reject_non_json_constant)


def _clone_synthetic_frame(snapshot: dict[str, Any], suffix: str) -> str:
    """Add a distinct, synthetic frame while keeping its definition digest valid."""
    frame = copy.deepcopy(snapshot["spatial_references"][0])
    frame["frame_id"] = f"{frame['frame_id']}:{suffix}"
    frame["crs"]["definition_text"] += f"; synthetic test frame {suffix}"
    frame["crs"]["definition_sha256"] = hashlib.sha256(
        frame["crs"]["definition_text"].encode("utf-8")
    ).hexdigest()
    snapshot["spatial_references"].append(frame)
    return frame["frame_id"]


def _operation_record(
    record_id: str,
    source_frame_id: str,
    target_frame_id: str,
) -> dict[str, Any]:
    """Create metadata-only fixture; this does not define an executable transform."""
    return {
        "record_id": f"urn:worldforge:operation:{record_id}",
        "schema_version": 1,
        "operation_method_id": "urn:worldforge:operation-method:unavailable-fixture",
        "operation_version": "unavailable-fixture-v1",
        "source_frame_id": source_frame_id,
        "target_frame_id": target_frame_id,
    }


def _semantic_errors(snapshot: dict[str, Any]) -> list[str]:
    """Check cross-record identity, frame-domain, and operation-chain rules."""
    errors: list[str] = []
    references = snapshot["spatial_references"]
    objects = snapshot["objects"]
    operation_records = snapshot["operation_records"]
    tombstones = snapshot["tombstones"]

    frame_ids = [reference["frame_id"] for reference in references]
    if len(frame_ids) != len(set(frame_ids)):
        errors.append("duplicate spatial reference ID")
    known_frame_ids = set(frame_ids)
    frames_by_id = {reference["frame_id"]: reference for reference in references}

    operation_record_ids = [
        operation["record_id"] for operation in operation_records
    ]
    if len(operation_record_ids) != len(set(operation_record_ids)):
        errors.append("duplicate operation record ID")
    operations_by_id = {
        operation["record_id"]: operation for operation in operation_records
    }

    object_ids = [record["object_id"] for record in objects]
    if len(object_ids) != len(set(object_ids)):
        errors.append("duplicate active object ID")

    tombstone_ids = [record["object_id"] for record in tombstones]
    if len(tombstone_ids) != len(set(tombstone_ids)):
        errors.append("duplicate tombstone object ID")
    if set(object_ids).intersection(tombstone_ids):
        errors.append("object ID is both active and tombstoned")

    for reference in references:
        crs = reference["crs"]
        digest = hashlib.sha256(
            crs["definition_text"].encode("utf-8")
        ).hexdigest()
        if digest != crs["definition_sha256"]:
            errors.append(
                f"CRS definition digest differs for {reference['frame_id']}"
            )
        axes = [axis["name"] for axis in crs["axes"]]
        if len(axes) != len(set(axes)):
            errors.append(
                f"duplicate axis name in {reference['frame_id']}"
            )
        domains = reference.get("axis_domains")
        if domains is not None:
            domain_axes = [domain["axis_name"] for domain in domains]
            if domain_axes != axes:
                errors.append(
                    f"axis domains do not match declared axis order in "
                    f"{reference['frame_id']}"
                )
            for domain in domains:
                if domain["minimum"] > domain["maximum"]:
                    errors.append(
                        f"invalid axis domain for {domain['axis_name']} in "
                        f"{reference['frame_id']}"
                    )

    for operation in operation_records:
        for endpoint in ("source_frame_id", "target_frame_id"):
            frame_id = operation[endpoint]
            if frame_id not in known_frame_ids:
                errors.append(
                    f"unknown {endpoint.replace('_', ' ')} {frame_id} for "
                    f"{operation['record_id']}"
                )

    for record in objects:
        position = record["position"]
        frame_id = position["spatial_reference_id"]
        if frame_id not in known_frame_ids:
            errors.append(
                f"unknown spatial reference {frame_id} for "
                f"{record['object_id']}"
            )
        else:
            frame = frames_by_id[frame_id]
            domains = frame.get("axis_domains")
            if domains is not None:
                for axis_index, (coordinate, domain) in enumerate(
                    zip(position["coordinates"], domains)
                ):
                    if not domain["minimum"] <= coordinate <= domain["maximum"]:
                        errors.append(
                            f"coordinate outside {domain['axis_name']} domain "
                            f"for {record['object_id']} at index {axis_index}"
                        )

        previous_target_frame_id: str | None = None
        for operation_id in position["operation_record_ids"]:
            operation = operations_by_id.get(operation_id)
            if operation is None:
                errors.append(
                    f"unknown operation record {operation_id} for "
                    f"{record['object_id']}"
                )
                continue
            if (
                previous_target_frame_id is not None
                and operation["source_frame_id"] != previous_target_frame_id
            ):
                errors.append(
                    f"operation frame chain mismatch before {operation_id} "
                    f"for {record['object_id']}"
                )
            previous_target_frame_id = operation["target_frame_id"]
        if (
            previous_target_frame_id is not None
            and previous_target_frame_id != frame_id
        ):
            errors.append(
                f"operation target frame {previous_target_frame_id} differs "
                f"from position frame {frame_id} for {record['object_id']}"
            )
        component_ids = [
            (component["schema_id"], component["schema_version"])
            for component in record["components"]
        ]
        if len(component_ids) != len(set(component_ids)):
            errors.append(
                f"duplicate component schema for {record['object_id']}"
            )
    return errors


class SimulationFoundationsContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = _read_json(SCHEMA_PATH)
        cls.example = _read_json(EXAMPLE_PATH)
        cls.lifecycle = _read_json(LIFECYCLE_PATH)
        Draft202012Validator.check_schema(cls.schema)
        cls.validator = Draft202012Validator(cls.schema)

    def _schema_errors(self, value: dict[str, Any]) -> list[str]:
        return [
            error.message
            for error in sorted(
                self.validator.iter_errors(value),
                key=lambda item: list(item.absolute_path),
            )
        ]

    def test_synthetic_snapshot_matches_schema_and_cross_record_rules(self) -> None:
        self.assertEqual(self._schema_errors(self.example), [])
        self.assertEqual(_semantic_errors(self.example), [])

    def test_global_position_requires_complete_frame_declarations(self) -> None:
        snapshot = copy.deepcopy(self.example)
        reference = snapshot["spatial_references"][0]
        del reference["horizontal_reference"]["coordinate_epoch_status"]
        self.assertNotEqual(self._schema_errors(snapshot), [])

    def test_position_requires_an_explicit_operation_record_list(self) -> None:
        snapshot = copy.deepcopy(self.example)
        del snapshot["objects"][0]["position"]["operation_record_ids"]
        self.assertNotEqual(self._schema_errors(snapshot), [])

    def test_operation_record_collection_is_required(self) -> None:
        snapshot = copy.deepcopy(self.example)
        del snapshot["operation_records"]
        self.assertNotEqual(self._schema_errors(snapshot), [])

    def test_finite_binary64_coordinate_endpoints_are_accepted(self) -> None:
        snapshot = copy.deepcopy(self.example)
        snapshot["objects"][0]["position"]["coordinates"] = [
            MAX_BINARY64,
            -MAX_BINARY64,
            0.0,
        ]
        self.assertEqual(self._schema_errors(snapshot), [])
        self.assertEqual(_semantic_errors(snapshot), [])

    def test_positive_and_negative_exponent_overflow_are_rejected(self) -> None:
        snapshot = copy.deepcopy(self.example)
        snapshot["objects"][0]["position"]["coordinates"] = json.loads(
            "[1e999, -1e999, 0]"
        )
        self.assertEqual(
            snapshot["objects"][0]["position"]["coordinates"][0], float("inf")
        )
        self.assertEqual(
            snapshot["objects"][0]["position"]["coordinates"][1], -float("inf")
        )
        self.assertNotEqual(self._schema_errors(snapshot), [])

    def test_declared_frame_axis_domains_are_enforced(self) -> None:
        snapshot = copy.deepcopy(self.example)
        bounded_frame_id = _clone_synthetic_frame(
            snapshot, "bounded-domain-test"
        )
        reference = snapshot["spatial_references"][-1]
        reference["axis_domains"] = [
            {
                "axis_name": axis["name"],
                "minimum": -6378137.0,
                "maximum": 6378137.0,
            }
            for axis in reference["crs"]["axes"]
        ]
        snapshot["objects"][0]["position"]["coordinates"] = [
            6378137.0,
            -6378137.0,
            0.0,
        ]
        snapshot["objects"][0]["position"]["spatial_reference_id"] = (
            bounded_frame_id
        )
        self.assertEqual(self._schema_errors(snapshot), [])
        self.assertEqual(_semantic_errors(snapshot), [])

        reference["axis_domains"][0]["maximum"] = 6378136.0
        self.assertIn(
            "coordinate outside X domain",
            " ".join(_semantic_errors(snapshot)),
        )
        reference["axis_domains"][0]["maximum"] = 6378137.0
        reference["axis_domains"][0]["axis_name"] = "other-axis"
        self.assertIn(
            "axis domains do not match declared axis order",
            " ".join(_semantic_errors(snapshot)),
        )

    def test_regional_chart_cannot_be_serialized_as_global_object_frame(self) -> None:
        snapshot = copy.deepcopy(self.example)
        snapshot["spatial_references"][0]["scope"] = "regional_local"
        self.assertNotEqual(self._schema_errors(snapshot), [])

    def test_runtime_node_identity_is_rejected_from_durable_record(self) -> None:
        snapshot = copy.deepcopy(self.example)
        snapshot["objects"][0]["runtime_instance_id"] = 12345
        self.assertNotEqual(self._schema_errors(snapshot), [])

    def test_unknown_future_snapshot_version_fails_closed(self) -> None:
        snapshot = copy.deepcopy(self.example)
        snapshot["schema_version"] = 2
        self.assertNotEqual(self._schema_errors(snapshot), [])

    def test_duplicate_and_dangling_object_identity_is_rejected(self) -> None:
        duplicate = copy.deepcopy(self.example)
        duplicate["objects"].append(copy.deepcopy(duplicate["objects"][0]))
        self.assertIn("duplicate active object ID", _semantic_errors(duplicate))

        dangling = copy.deepcopy(self.example)
        dangling["objects"][0]["position"]["spatial_reference_id"] = (
            "urn:worldforge:spatial-frame:global:missing-v1"
        )
        self.assertTrue(
            any(
                "unknown spatial reference" in error
                for error in _semantic_errors(dangling)
            )
        )

    def test_versioned_operation_record_chain_resolves_to_position_frame(self) -> None:
        snapshot = copy.deepcopy(self.example)
        frame_a = snapshot["spatial_references"][0]["frame_id"]
        frame_b = _clone_synthetic_frame(snapshot, "operation-stage-b")
        frame_c = _clone_synthetic_frame(snapshot, "operation-stage-c")
        snapshot["operation_records"] = [
            _operation_record("fixture-first-v1", frame_a, frame_b),
            _operation_record("fixture-second-v1", frame_b, frame_c),
        ]
        snapshot["objects"][0]["position"]["spatial_reference_id"] = frame_c
        snapshot["objects"][0]["position"]["operation_record_ids"] = [
            "urn:worldforge:operation:fixture-first-v1",
            "urn:worldforge:operation:fixture-second-v1",
        ]
        self.assertEqual(self._schema_errors(snapshot), [])
        self.assertEqual(_semantic_errors(snapshot), [])

    def test_dangling_operation_record_id_is_rejected(self) -> None:
        snapshot = copy.deepcopy(self.example)
        snapshot["objects"][0]["position"]["operation_record_ids"] = [
            "urn:worldforge:operation:missing-v1"
        ]
        self.assertIn(
            "unknown operation record",
            " ".join(_semantic_errors(snapshot)),
        )

    def test_operation_record_frame_references_must_resolve(self) -> None:
        snapshot = copy.deepcopy(self.example)
        frame_id = snapshot["spatial_references"][0]["frame_id"]
        snapshot["operation_records"] = [
            _operation_record(
                "fixture-dangling-frame",
                "urn:worldforge:spatial-frame:missing-v1",
                frame_id,
            )
        ]
        self.assertIn(
            "unknown source frame",
            " ".join(_semantic_errors(snapshot)),
        )

    def test_mismatched_operation_frame_chain_is_rejected(self) -> None:
        snapshot = copy.deepcopy(self.example)
        frame_a = snapshot["spatial_references"][0]["frame_id"]
        frame_b = _clone_synthetic_frame(snapshot, "operation-stage-b")
        frame_c = _clone_synthetic_frame(snapshot, "operation-stage-c")
        snapshot["operation_records"] = [
            _operation_record("fixture-first-v1", frame_a, frame_b),
            _operation_record("fixture-second-v1", frame_c, frame_a),
        ]
        snapshot["objects"][0]["position"]["operation_record_ids"] = [
            "urn:worldforge:operation:fixture-first-v1",
            "urn:worldforge:operation:fixture-second-v1",
        ]
        self.assertIn(
            "operation frame chain mismatch",
            " ".join(_semantic_errors(snapshot)),
        )

    def test_unknown_operation_record_schema_version_is_rejected(self) -> None:
        snapshot = copy.deepcopy(self.example)
        frame_id = snapshot["spatial_references"][0]["frame_id"]
        snapshot["operation_records"] = [
            _operation_record("fixture-version-two", frame_id, frame_id)
        ]
        snapshot["operation_records"][0]["schema_version"] = 2
        snapshot["objects"][0]["position"]["operation_record_ids"] = [
            "urn:worldforge:operation:fixture-version-two"
        ]
        self.assertNotEqual(self._schema_errors(snapshot), [])

    def test_object_and_tombstone_cannot_share_identity(self) -> None:
        snapshot = copy.deepcopy(self.example)
        snapshot["tombstones"][0]["object_id"] = snapshot["objects"][0][
            "object_id"
        ]
        self.assertIn(
            "object ID is both active and tombstoned",
            _semantic_errors(snapshot),
        )

    def test_lifecycle_spec_separates_unload_from_explicit_destruction(self) -> None:
        states = set(self.lifecycle["states"])
        transitions = {
            (item["from"], item["event"], item["to"])
            for item in self.lifecycle["transitions"]
        }
        self.assertNotIn("destroyed", states)
        self.assertIn(("attached", "retire", "retiring"), transitions)
        self.assertIn(("retiring", "release_resources", "unloaded"), transitions)
        self.assertIn(
            ("decoding", "complete_stale_generation", "cancelled"),
            transitions,
        )
        self.assertIn("tile_content_revision", self.lifecycle["binding_identity"])
        self.assertIn("instance_generation", self.lifecycle["binding_identity"])
        self.assertIn(
            "tile_content_revision_is_current",
            self.lifecycle["completion_acceptance"],
        )
        self.assertIn("retain_object_id", self.lifecycle["unload_effect"])
        self.assertIn("tombstone", self.lifecycle["destroy_effect"])
        for source, _event, target in transitions:
            self.assertIn(source, states)
            self.assertIn(target, states)

    def test_frame_definition_hash_covers_exact_serialized_definition(self) -> None:
        snapshot = copy.deepcopy(self.example)
        snapshot["spatial_references"][0]["crs"]["definition_text"] += " "
        self.assertIn(
            "CRS definition digest differs",
            " ".join(_semantic_errors(snapshot)),
        )


if __name__ == "__main__":
    unittest.main()
