# Simulation foundations interface v1 (production-planning proposal)

**Status:** Proposed interface boundary and validation fixture; no game simulation, entity runtime, global datum bridge, or persistence service is implemented by this change.
**Evidence base:** Parent repository commit `4a23601a4cacb20db1eb752cb03574dd6c76803c` (`codex/wf-gate-d-adjacent-consumer`).
**Scope:** WF-EXIT-07 only. No player, controller, vehicle, AI, mission, combat, or gameplay behavior.

## Existing evidence and gap

| Existing evidence at the base | What it establishes | What it does not establish |
| --- | --- | --- |
| `integration/terrain/terrain_stream_manager_v1.gd` request IDs and `_complete_task` | The terrain prototype rejects stale request IDs, validates requested frame/artifact identities, installs one/two windows atomically, unloads render/collision nodes, and drains accepted workers at shutdown. | Persistent object IDs, object registry ownership, tile-independent state, or object save/restore. |
| `integration/terrain/geodetic_ecef_wgs84_v1.gd` and `global-position-utility-v1.md` | A bounded WGS 84 ellipsoid equation utility has independent numeric reference tests. | NAD83 realization/epoch or NAVD88 conversion, an authoritative world CRS choice, a geodetic operation pipeline, or an engine-wide floating-origin service. |
| `terrain-grid-contract.md`, `terrain-grid_v1.schema.json`, and `gate-d-source-identity.md` | Terrain Grid v1 is a strict, source-linked, regional chart. Its local frames keep EPSG:4269 / GRS80 horizontal semantics and NAVD88 heights; incompatible frames are rejected. | Global placement, region-to-region transforms, entity positioning, or a durable game-state schema. |
| `risk-register.md` R8 | The parent project has a terrain viewer and tile lifecycle only; entity, save, persistence, and gameplay-state interfaces remain open. | Any existing simulation or persistence implementation. |

This proposal keeps Earth-wide positioning and future travel as requirements. A pair of regional crops is not a product boundary.

## Proposed subsystem boundaries

| Interface | Authority and lifetime | Contract |
| --- | --- | --- |
| `GlobalPosition` value | World state registry; durable | A typed triple of binary64 values plus an immutable spatial-reference ID. The referenced frame declares CRS, axis order, units, horizontal datum, realization/epoch status, and vertical reference. A coordinate is never a bare `Vector3`, latitude/longitude pair, or tile-local value. |
| Spatial-reference registry | World configuration; durable and versioned | Stores the complete frame definition. Reusing an ID with changed axes, datum, units, epoch, or vertical meaning is invalid; a change creates a new ID. |
| Object registry record | World state registry; durable | Immutable namespaced `object_id`, monotonically increasing object revision, `GlobalPosition`, component records keyed by versioned component schema IDs, and optional source-provenance reference. |
| Stream binding | Stream manager; volatile | Maps an `object_id` and object revision to a tile membership, request generation, frame ID, and live Godot node/resource handles. Node instance IDs, mesh/collision resources, local transforms, and tile membership are not saved as object identity or durable state. |
| Simulation clock | World simulation service; session/runtime plus durable tick | Integer simulation tick and rational tick rate define authoritative time. Godot's existing scene/physics timing remains the scheduler; this proposal does not justify a custom ECS or engine service. |
| Snapshot store | Persistence adapter; durable | Serializes registry records, spatial-reference definitions, tombstones, and the committed simulation tick. It does not serialize scene nodes, render/physics resources, decoder tasks, caches, or origin-relative transforms. |

A streamed object may have more than one tile membership for coverage, but it remains one registry record and one persistent ID. A representation change, tile move, LOD transition, or origin rebase does not mint a new object identity. Source-derived object IDs include a stable source namespace and immutable source feature key; runtime-created IDs use a stable WorldForge namespace plus a collision-resistant generated identifier. Never use array index, tile-local index, Node instance ID, or the current LOD as durable identity.

## Geographic-position contract

The machine-readable shape is in `contracts/world_state_v1.schema.json`. A position stores `spatial_reference_id`, three finite numeric coordinates in that frame's declared axis order and units, and ordered `operation_record_ids` for any CRS/datum conversions used to produce them. The saved frame record's `definition_sha256` is the SHA-256 of the exact UTF-8 `definition_text`; numeric axis-domain bounds remain frame-specific and must be checked by its registered validator. The saved frame record explicitly states:

- scope (`earth_global` for durable world-object positions);
- CRS identifier / definition reference, axis names and directions, and per-axis units;
- horizontal datum, realization status/name, and coordinate-epoch status/value;
- vertical reference status, datum, height type, and unit.

All stored coordinates are binary64 numeric values at serialization boundaries. Godot local `Node3D` transforms are derived presentation/physics coordinates and may be regenerated after an origin shift. A conversion between frames is allowed only through a named, versioned operation with explicit source/target CRS, axis order, horizontal and vertical semantics, epoch applicability, provenance, and scenario-specific uncertainty. Store references to its immutable operation record(s) in `operation_record_ids`; those records include parameters, implementation/version, reference sources, and uncertainty. Missing or unresolved operations fail closed.

**No canonical production CRS or datum operation is selected here.** The test fixture deliberately declares generic EPSG:4978/WGS 84 realization and epoch as unresolved and is marked synthetic; it is only a structure/identity test. The current terrain bundles are NAD83/GRS80 regional charts with NAVD88 heights. They cannot be inserted into this global frame by copying coordinates or passing NAVD88 values to the WGS 84 ellipsoid utility. A source-to-global bridge remains a production gate and must be independently verified against suitable reference data.

## Streamed-object identity and lifecycle

The normative state table is `contracts/stream_binding_lifecycle_v1.json`.

A production `TileKey` must identify a geographic cell by a versioned planetary tiling-scheme ID plus its cell coordinates. It excludes LOD and engine-local origin. Keep the source/artifact content revision separate from the geographic cell key; the content revision identifies the exact source, generator, contract, parameters, and provenance snapshot. The final global tiling scheme remains open.

- The world registry owns object identity, authoritative position, component state, revision, and deletion tombstones.
- The streamer owns pending jobs and temporary scene/render/physics bindings. Godot creates and frees its own resources on permitted threads.
- Each completion carries `(object_id, object_revision, request_generation, tile_key, tile_content_revision, spatial_reference_id)`; each attached binding also has a new transient `instance_generation` so stale node/physics callbacks cannot affect a replacement. Attach only if all values still match the registry, current demand, tile contents, and exact target frame; otherwise discard without changing durable state.
- A successful batch is validated and constructed before an atomic main-thread attach. Seam-coupled neighbor sets transition together. Readiness (including collision eligibility) is explicit; a coarse visual LOD is not presumed ready for ground contact.
- Unload/cancel removes runtime bindings and releases resources, then returns the stream binding to `unloaded`; it preserves the registry record and its identity/state. Unload is not destruction.
- Destruction is an explicit registry operation that writes a revisioned tombstone. Tombstones suppress stale tile/cache/load completions and are retained until a separately specified world-wide deletion/replication policy can safely retire them.
- Shutdown invalidates generations, cancels/discards late work, waits for accepted jobs according to the selected Godot API's contract, and releases every binding/resource exactly once.

The current terrain request-generation and atomic two-window behavior are useful patterns, but they are not an object lifecycle implementation. Production must test object creation, multi-tile membership, move/rebase, cancel/failure/retry, unload/reload, explicit destroy/tombstone, stale completion, repeated travel, and shutdown in the actual pinned Godot build.

## Simulation and persistence contract

Simulation state changes are committed at integer tick boundaries. The proposed clock fields are `tick_index` plus `tick_rate_numerator / tick_rate_denominator` ticks per second; no authoritative state update is driven directly from render-frame `delta`. The snapshot also records `last_committed_command_sequence`. At a tick boundary the production scheduler must define a stable order: drain accepted commands in sequence order, apply them, update registered systems, then publish one committed state revision. Rendering may interpolate between committed states but cannot write authoritative coordinates or components.

Recommended pause/resume semantics for the first production implementation are explicit and testable: pausing freezes simulation ticks while streaming and safe presentation work may continue; resuming begins at the next tick without unbounded catch-up. The pause flag is session control, not durable world state. The exact command/replay policy remains a production decision.

Snapshot v1 is an envelope, not an implementation of a save service. The schema fixes the contract ID and version, world/snapshot identity, simulation tick/rate, frame table, active records, and tombstones. Object component payloads have their own schema ID and version and must validate against that component schema. The snapshot reader validates size, strict JSON, schema, duplicate IDs, frame references, component identity, and object/tombstone overlap before publishing any state.

For schema evolution, each released snapshot version has an explicit deterministic `vN -> vN+1` migration; no silent defaults or in-place writes. Migrations preserve object IDs, revisions unless a documented transformation increments them, tick order, frame identity, source provenance, and tombstones. A coordinate migration must name and validate its geodetic operation separately; a schema migration is not authority to alter datum. Unknown optional components may be preserved as opaque, versioned payloads; missing required components and unsupported future snapshot versions fail closed. Write a migrated snapshot atomically only after validation; preserve the prior snapshot for recovery.

The first artifact is intentionally v1 only. It tests version rejection and required identity/frame fields; no migration implementation or crash-safe store exists yet.

## Data, provenance, and rights boundary

The state contract may preserve a provenance reference for source-derived objects (provider, dataset/product/version, stable source feature key, source snapshot hash, and a rights/provenance record ID). That reference records lineage; it is not a rights clearance. Code licences and data/database/image rights remain separate. The adopted USGS 3DEP policy covers local prototype elevation experiments in the selected US regions only; it does not clear worldwide terrain or non-USGS roads, buildings, imagery, land cover, or other features. Any production source and every source-derived persistent object need auditable provenance and an applicable rights review. No data source was downloaded or changed for this interface proposal.

## Validation artifact and limits

- `contracts/world_state_v1.schema.json` defines the v1 snapshot envelope and rejects unknown top-level/object/frame fields.
- `contracts/examples/world_state_v1_minimal.json` is synthetic, contains an unresolved WGS 84 geocentric frame declaration, one identity-only fixture record, and one tombstone; it is not terrain or a global datum validation.
- `contracts/stream_binding_lifecycle_v1.json` states the volatile binding transitions and unload/destroy distinction.
- `tools/tests/test_simulation_foundations_contract.py` checks the JSON Schema, accepted/rejected snapshot cases, cross-record identity/frame invariants, and lifecycle-table invariants with Python's JSON Schema Draft 2020-12 validator. Main Lead ran it on Python 3.12.10 with `jsonschema` 4.26.0; that test-only package is present in the checked workstation environment but is not added as a project dependency. Raw output is [simulation-foundations-tests.log](evidence/simulation-foundations-tests.log), 2,067 bytes, SHA-256 `D575A2210A856987CC316FA70A4686366260A8310D3F2EACCA9BEAE1BB691469`.

Run the focused contract check from the parent repository root with:

```powershell
python -m unittest discover -s tools/tests -p "test_simulation_foundations_contract.py" -v
```

These checks validate the proposed data contract and state table only. They do not instantiate Godot objects, execute async lifecycle operations, prove transform accuracy, implement simulation time or migrations, validate persistence/recovery, or close WF-EXIT-07. QA still needs to review the exact proposed head and production needs runtime tests for the behaviors above. This deliverable is **design evidence**, not a Gate D exit PASS.
