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


def _reject_non_json_constant(value: str) -> None:
    raise ValueError(f"invalid JSON numeric constant: {value}")


def _read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as source:
        return json.load(source, parse_constant=_reject_non_json_constant)


def _semantic_errors(snapshot: dict[str, Any]) -> list[str]:
    """Check cross-record invariants that JSON Schema cannot express."""
    errors: list[str] = []
    references = snapshot["spatial_references"]
    objects = snapshot["objects"]
    tombstones = snapshot["tombstones"]

    frame_ids = [reference["frame_id"] for reference in references]
    if len(frame_ids) != len(set(frame_ids)):
        errors.append("duplicate spatial reference ID")
    known_frame_ids = set(frame_ids)

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

    for record in objects:
        frame_id = record["position"]["spatial_reference_id"]
        if frame_id not in known_frame_ids:
            errors.append(
                f"unknown spatial reference {frame_id} for "
                f"{record['object_id']}"
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
