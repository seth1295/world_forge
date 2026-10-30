# Planetary spatial, tile address, origin, and LOD design

**Status:** Selected, executable pre-production address and LOD policy; live scene-origin and collision proof exercised with real Golden terrain. Source-to-global placement, a production tile geometry/index, and worldwide coverage remain unimplemented.
**Scope:** WF-EXIT-05 and the geography-related constraints for WF-EXIT-06. This is functional design evidence, not a performance plan.

## 1. Coordinate and datum boundary

### ADR-GEO-01 — Preserve each source frame as data

Terrain and feature positions remain attached to an immutable, versioned spatial-reference record. The record defines CRS, axis order, units, horizontal datum, realization/epoch status, vertical reference, source identity, and any operation used to derive another frame. A bare `Vector3`, longitude/latitude pair, or projected easting/northing is not a durable position.

The current USGS terrain bundles preserve EPSG:4269 longitude/latitude, NAD83 on GRS80 with **unspecified realization and epoch**, NAVD88 orthometric metres, and a site-specific GRS80 AEQD chart. The consumer expresses a sample to Godot as `(E, H-H0, -N)`. Baltimore and Golden charts are distinct and cannot be combined as one global coordinate frame. No terrain operation treats NAVD88 as ellipsoidal height, or applies GEOID18 without a compatible input realization and epoch.

### ADR-GEO-02 — Global conversion fails closed

`Wgs84GeodeticEcefV1` implements WGS 84 EPSG:4979/EPSG:4978 ellipsoid equations and independent synthetic reference vectors. It is not called by the terrain consumer and does not identify a WGS 84 realization or epoch. `GlobalPositionBridgeV1.terrain_local_to_wgs84_ecef()` returns `status="unavailable"` for both approved USGS sites, with no operation ID. The WGS 84 address utility and ECEF equations must not be fed the terrain's NAD83/NAVD88 values.

Global placement can be added only after source realization/epoch and compatible horizontal and vertical operations are identified and independently validated. The production spatial-reference registry must preserve multiple realizations and coordinate epochs; this prototype chooses no canonical production datum.

### ADR-GEO-03 — Distinguish durable coordinates from runtime origin

`TerrainOriginRebaseV1` is a Godot `Node3D` scene root for one already-declared regional Cartesian chart. Child transforms keep their durable positions in that chart. Rebasing sets the root translation to the negative selected chart origin and increments an origin generation; it does not alter child positions, window IDs, frame IDs, source identities, content revisions, or resource objects. The service performs no conversion between regional, geodetic, ECEF, or height datums.

The earlier WGS 84 ECEF subtract/add test remains a separate synthetic arithmetic fixture. Its 1 mm limit applies only to coordinate arithmetic and rebase round-trip checks, never to real terrain accuracy.

## 2. Global tile address decision

### ADR-TILE-01 — `wf-cube-quad-v1`

The prototype selects a dependency-free, six-face cubed-sphere quadtree address. A WGS 84 geographic 2D input is mapped to an angular unit direction `(cos φ cos λ, cos φ sin λ, sin φ)`. This is a spherical address parameterization only: it is not WGS 84 ECEF, an ellipsoid conversion, or a transformation from the current NAD83 terrain frames.

The face is selected by the largest absolute direction component, with exact ties resolved X, then Y, then Z. Faces have fixed IDs and local coordinates:

| Face | Cube direction `(X,Y,Z)` from face coordinates `(u,v)` |
| --- | --- |
| 0, +X | `(1, u, v)` |
| 1, −X | `(-1, -u, v)` |
| 2, +Y | `(-u, 1, v)` |
| 3, −Y | `(u, -1, v)` |
| 4, +Z / north | `(u, v, 1)` |
| 5, −Z / south | `(u, -v, -1)` |

For cell level `c` in `[0, 30]`, `N = 2^c`; `x = floor((u+1)N/2)` and `y = floor((1-v)N/2)`, clamped to `[0,N-1]`. The canonical key is `wf-cube-quad-v1/f{face}/l{cell-level}/x{x}/y{y}`. In this key, `l` is **geographic cell level**, not visual mesh LOD. Parent and child addresses are deterministic (`floor(x/2), floor(y/2)` and four child quadrants).

Longitude is normalized to `[-180°, 180°)`, so `-180°` and `+180°` share a key. At exactly either pole the direction is canonicalized to `(0,0,+1)` or `(0,0,-1)`, making the key independent of longitude. Dominant-axis tie handling assigns a unique owner to cube-face edges. Cardinal cross-face neighbors use an explicit face/edge mapping; the neighbor result includes its reciprocal local edge direction because compass orientation can rotate across a cube face. This prototype defines cardinal neighbors, not a diagonal-neighbor query.

The address record contains only the scheme, face, cell level, x/y, and tile key. Source identity, spatial-reference ID, content revision, and runtime handles are separate binding fields. The actual NAD83/NAVD88 demo windows therefore retain a local `regional_tile_id` such as `wf-regional-window-v1/wf-vs01:golden-front-range/golden-west`; they do **not** receive an invented global key while the datum operation is unavailable. Their source identity, frame ID, artifact/content revision, and Godot node instance IDs are recorded separately by the tile factory.

### Alternatives considered

- [S2 Cells](https://s2geometry.io/devguide/s2cell_hierarchy) is the closest established fit: it also projects six cube faces to a sphere and recursively subdivides quadrilateral cells. Its production `S2CellId` adds a 64-bit face/Hilbert-curve encoding and an S2-specific projection. This prototype borrows neither the S2 cell ID encoding nor claims S2 conformance; it uses inspectable face/level/x/y strings and explicit face-edge maps, with no new C++ library dependency. A later migration to exact S2 IDs remains possible if interoperability and tested engine integration justify it.
- [H3](https://github.com/uber/h3/blob/master/website/docs/core-library/overview.md) provides hierarchical global cells on an icosahedron, including twelve pentagons. It is useful for spatial aggregation and flow, but its hexagon/pentagon topology is less direct for rectangular raster windows, shared terrain sample rows, and mesh edge stitching.
- The [OGC DGGS standard](https://www.ogc.org/standards/dggs/) defines a global hierarchical identifier framework, not one required cell geometry or one globally interoperable address implementation. A registered OGC DGGRS could become a production interoperability requirement; it does not select our exact runtime index by itself.

The prototype cube grid is not equal-area and does not claim uniform ground dimensions across faces. Its key is a location/resolution identity, not a claim about survey accuracy, physical cell area, source coverage, or mesh geometry. No external runtime dependency was added.

## 3. Visual LOD and collision decision

### ADR-LOD-01 — Error-bounded visual LOD with per-scenario budgets

For each candidate representation, retain the maximum geometric deviation from its source samples in metres. Given a scenario's camera scale in metres per pixel and its Main-Lead-owned visual error limit in pixels, compute `projected_error_px = max_geometric_error_m / metres_per_pixel`. Recommend the coarsest validated candidate whose projected source error is within that scenario's limit. For a coupled adjacent set, use the largest member error and keep seam-related transitions atomic. A multi-level production selector must keep adjacent cells within one level, then stitch or preserve their boundary samples before rendering.

The policy stores no planet-wide pixel or metre threshold. A candidate with missing, non-finite, or negative source error is not eligible; selection falls back to the finest known source reference. If no source-reference candidate is available, selection returns unavailable. LOD 0 has zero **representation error relative to its own retained samples**; this is not a terrain accuracy or source uncertainty claim. `SourceErrorLodPolicyV1` implements the selection rule, and `TerrainStreamManagerV1.select_adjacent_visual_lod()` recommends a level for a real paired tile set without mutating the active scene.

### ADR-LOD-02 — Keep contact collision independent

Visual LOD never grants collision readiness. The current LOD 0 mesh and static collision use the same source samples and are the only contact-eligible level. LOD 1 keeps every other source row/column plus the final outer rows/columns, and paired Golden windows change together. Its collision shapes and physics layers are disabled. The installed Golden shared sample remains bit-identical: measured shared-vertex delta is **0 m**.

The Golden crop's observed LOD 1 omitted-sample deviation is **13.497314453 m** for that crop and comparison surface. It is neither a global LOD threshold nor source accuracy or permitted ground-contact error. The actual Golden policy test feeds this measured crop error into two deliberately synthetic camera-scale scenarios solely to exercise the selection branch; those test inputs are not project budgets. Production collision remains highest-fidelity until a separate, scenario-specific contact representation is justified.

### ADR-LOD-03 — Keep transform fidelity separate from source accuracy

For the two regional AEQD crops, the Main Lead's horizontal projection checks use crop-specific curvature bounds plus numerical allowances of 0.00103 m for Baltimore and 0.0011 m for Golden. Independent GRS80 samples fall within them. These values assess projection arithmetic only. The selected USGS records provide no tile-specific terrain accuracy bound; no vertical or source-accuracy number is inferred from projection, mesh, or floating-point checks.

## 4. Live origin, streaming, and collision proof

`integration/tests/terrain_test_runner.gd` suite `origin-live` creates a `TerrainOriginRebaseV1` scene root and asynchronously loads the actual Golden `golden-west` and `golden-east` bundles through `TerrainStreamManagerV1`. The fixture places a camera, a named diagnostic static object, a ray probe, both generated meshes, and both source-sampled static collision bodies below the same origin root.

The test performs six root updates (starting at zero, shifting through `(1250,0,-750)`, `(-2400,0,1800)`, `(25000,0,-40000)`, `(-100000,0,100000)`, then returning to zero). Each update verifies the camera/object durable frame positions, regional tile IDs, source identities, frame IDs, content revisions, and unchanged node handles; it raycasts both interior samples and their shared seam and reconstructs each world hit into the durable source chart. The observed maximum camera/object arithmetic residual was `0.000000000007 m`, within the 1 mm arithmetic criterion only.

While the primary Golden pair remains installed, a second scene manager starts a Baltimore request and immediately replaces demand with the adjacent Golden set. Its stale Baltimore worker completion is rejected by request identity; the primary pair remains active. The test also transitions both Golden windows together to LOD 1, verifies the replacement resources have new runtime handles but unchanged regional tile/content identities, confirms coarse collision produces no hit, returns to LOD 0 and raycasts both tiles and the seam again. It then unloads the pair, checks no request remains, frees the manager, and shuts down the root.

A separate real viewer run uses the pinned double-precision Godot executable, actual Golden bundles, an actual render window, the same scene root and source-sampled collision checks. It performs five rebase generations and captures the final view at zero origin. The screenshot is [terrain-golden-origin-rebase.png](evidence/terrain-golden-origin-rebase.png); it is evidence of this technical run, not a terrain accuracy survey.

## 5. Reproducible evidence

### Address and LOD tests

`integration/tests/terrain_test_runner.gd` suite `tile-address` checks independent fixed cell keys for the equator, `±180°`, both poles, high and southern latitudes, and synthetic WGS 84 points near both demonstrator regions. It checks parent/child identity, invalid inputs, source/frame/revision/handle independence, cardinal neighbors inside a face, **24 fixed cross-face edge references**, and **192** reciprocal cube-edge traversals. These Baltimore (`39.29°, -76.61°`) and Golden (`39.755°, -105.22°`) coordinate values are synthetic WGS 84 address references, not read from or transformed out of the USGS manifests. The expected level-4 keys were independently recalculated with a separate Python standard-library reference implementation; Python is not a runtime dependency.

The same suite covers LOD selection at synthetic parameter boundaries, unknown-error fallback, unavailable source-reference behavior, and separation of visual LOD recommendations from collision eligibility. The existing `adjacent` suite applies the implemented policy to the real Golden adjacent source outputs and preserves the exact shared seam.

### Runtime identity and reproduction

| Item | Value |
| --- | --- |
| Parent base / assignment branch | `d4ef13b1568638e2138b05b69b584d4bffe42c77` / `codex/gate-e-spatial-origin-prototype` |
| Godot source commit | `d7339113911696eac113d77df633c6a2571f1ec0` |
| Godot executable | `4.8.beta.double.custom_build.d73391139`, Windows editor double build |
| Godot executable SHA-256 | `2AFB9FD1A8DDAC30F453857673F64391189557360391E8E7E3BFC8B8BDEFCB32` |
| Generator/content identity | This branch's runtime used bundle manifests naming producer `325cd2c4048bc9cf19a2287afc4de51c145f4490`. Main Lead reports latest producer head `ebfced70485dda28bf7893663cf744bc3de50dec`; the artifact IDs and XY/height payload hashes remain unchanged. The metadata-only new manifest hashes are listed below and are pending parent catalog integration. |
| Runtime data | USGS 3DEP 1/3 arc-second Golden / Front Range source bundles; approved windows `golden-west`, `golden-east`; shared source column 8430 |
| Source anchor | EPSG:4269 NAD83/GRS80, realization/epoch unspecified; `39.754953704278655° N, 105.21995370310027° W`; `1729.523193359375 m` NAVD88 orthometric |
| Viewer camera pose | Local chart position `(-1198.3306255951975, 118.5, 904.5941632146123) m`; look target `(-1714.2119027677074, 364.36767578125, 1099.8264649481891) m`; up `Vector3.UP`; position expression `(E,H-H0,-N)` |
| Test run | Focused: `PASS checks=124 failures=0` (`origin-live`), `PASS checks=140 failures=0` (`adjacent`), `PASS checks=64 failures=0` (`tile-address`). Combined `all`: `PASS checks=421 failures=0`; see [planetary-spatial-tests.log](evidence/planetary-spatial-tests.log), SHA-256 `98CEAE52E6E7EA914FA90DD31980AABE796DEA9217C734EDD82442D87D59A774`. |
| Runtime capture | `WF_ORIGIN_RUNTIME_RESULT=PASS generations=5 region=Golden/Front-Range windows=golden-west,golden-east`; 1600×900 PNG at [terrain-golden-origin-rebase.png](evidence/terrain-golden-origin-rebase.png), SHA-256 `8F580A379610292A02D80FA7909DD75A040ECE4BD2E565D51ED2E5B2FDD42E34`. Sanitized launch output is [planetary-spatial-origin-runtime.log](evidence/planetary-spatial-origin-runtime.log), SHA-256 `1E3C8E67693F94BD454801848C4F2928E50B63D2C930212514E82F0A605F055E`. |

The Main Lead's producer report (metadata update not consumed by this branch's tests) records new manifest SHA-256s: Baltimore `80ffdc8b3a151ff2cb965347aa4fe74a72694b201a70ebff74bfa4a48763eecf`; Golden `0fa942d3ff9344be8f76d1a5c72a09e30247b684c4ecec438673ae4b5f3bdd33`; Golden West `e05562acd5944f07864b92d108fed505a7b2cf52a3ba5c1fe460c3953c225b07`; Golden East `cf7dcc81856f2b8e4940518056f429c68a0a5df77054a222c814f29efef89e4a`. That report says producer metadata, run timestamp, and the corrected `filesystem_creation_time` basis changed; terrain artifact IDs and XY/height payload hashes did not. The parent integration worker owns those manifest/catalog edits.

From a Windows PowerShell session at the parent repository root with its pinned engine checkout initialized, run the focused scene checks with task-local Godot app directories:

```powershell
$repoRoot = (Get-Location).Path
$taskDataRoot = Join-Path $env:TEMP 'WorldForge-Spatial-Engineering-Run'
$env:APPDATA = Join-Path $taskDataRoot 'roaming'
$env:LOCALAPPDATA = Join-Path $taskDataRoot 'local'
$exe = Join-Path $repoRoot 'engine\godot\bin\godot.windows.editor.double.x86_64.console.exe'
$project = Join-Path $repoRoot 'integration'
& $exe --headless --editor --path $project --quit
& $exe --headless --path $project -- --test tile-address
& $exe --headless --path $project -- --test adjacent
& $exe --headless --path $project -- --test origin-live
& $exe --headless --path $project -- --test all
```

Reproduce the actual rendered fixture and capture with:

```powershell
$capture = Join-Path $repoRoot 'docs\preproduction\evidence\terrain-golden-origin-rebase.png'
& $exe --path $project --windowed --resolution 1600x900 -- --tile-set golden-adjacent --origin-rebase-demo --capture $capture
```

The run printed `ERROR: Failed to read the root certificate store.` from the custom Windows Godot build's system-certificate lookup. It did not need network access; project startup, terrain loads, physics raycasts, image capture, and test exit codes succeeded. No build or runtime API blocker was found. The test-only and runtime `APPDATA`/`LOCALAPPDATA` paths are task-local; project cache files stay in the worktree.

## 6. Limits and remaining production decisions

1. The cubed-sphere key scheme is a selected and tested prototype address model, not an OGC DGGRS registration, an S2 implementation, global coverage metadata, a production binary encoding, or a finalized earth-surface cell geometry.
2. The existing Baltimore and Golden source windows remain regional NAD83/GRS80 + NAVD88 charts. Their global WGS 84 address is intentionally unavailable until compatible horizontal and vertical operations are verified.
3. The LOD selector and real-pair tests validate an error-selection rule and two exact-sample levels, not a global camera-driven scheduler, all cube-face mesh seams, source accuracy, or every terrain provider's error metadata.
4. The live origin proof translates one active regional scene root. It does not demonstrate movement between regional frames, ECEF-scale scene coordinates, a player entity, long-distance travel, or worldwide physics.
5. Source accuracy/vertical uncertainty, globally compatible CRS operations, dataset rights/coverage, production tile storage and a measured per-scenario visual error budget remain production gates. Do not use the Golden omitted-sample deviation as a global limit or the 1 mm arithmetic criterion as terrain-source accuracy.

The current proof selects enough spatial identity, LOD, rebase, stale-completion, seam, collision and resource behavior to make a global design testable without claiming the Earth pipeline is complete. No performance threshold, benchmark, profiler run, or performance optimization is part of this evidence.
