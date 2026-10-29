# WorldForge Pre-production Baseline Ledger

**Status (initial baseline snapshot, 2026-10-29):** Gate A evidence was assembled; independent QA review was then pending. No WF-EXIT criterion was marked PASS in this baseline assessment. Current Gate C and Gate D status is in the later review and integration record.
**Purpose:** Trace the initial baseline, unresolved checks and subsequent gate evidence.
**Last updated:** 2026-10-30.  
**Performance:** Excluded from pre-production QA and exit criteria.

## Initial repository snapshot

Snapshot checked 2026-10-29 on the Windows development workstation.

| Repository | Parent pin / observed head | Branch state | Initial finding |
|---|---|---|---|
| `world_forge` | `045a56b0c10b45e5babd7b49ce0e6444571561b6` | `main`, matching `origin/main` | `contracts/`, `integration/`, `tools/`, and `docs/` had only placeholder files. No integration project or WorldForge consumer was present. |
| `world_forge_godot` | `d7339113911696eac113d77df633c6a2571f1ec0` | `master`, one local fork commit beyond upstream | The only change relative to the upstream base is archiving the upstream README as `LEGACY_Readme.md`; no WorldForge engine feature has been verified. |
| `world_forge_generator` | `06ea781f3d721a11a0ee8ecc4ccfd95b4c32b556` | `main`, one local fork commit beyond upstream | The only change relative to the upstream base is archiving the upstream README as `LEGACY_Readme.md`; the checkout remains BeamNG.Earth-derived code pending capability and dependency audit. |

The exact parent gitlinks were checked with `git ls-tree HEAD engine/godot worldgen/beamng-earth` and matched each child checkout's `git rev-parse HEAD`. `git submodule status` was attempted but Git for Windows' `sh` failed to create a signal pipe (`Win32 error 5`); the direct gitlink/head comparison is the current pin evidence. Re-run submodule status in a clean process when the environment permits.

## Initial workstation and tool evidence

- Windows 10.0.26200; Python 3.12.10; Cargo 1.99.0; CMake 4.4.3.
- `git`, `cmake`, `python`, `py`, `cargo`, `rustc`, `dotnet`, and `gh` are available.
- `scons`, `ninja`, `godot`, `godot4`, `cl`, `clang`, `clang-cl`, `gdalinfo`, `ogrinfo`, and `projinfo` are not on `PATH`.
- Python can import `numpy`, `rasterio`, and `pytest`; `SCons`, `osgeo`, `pyproj`, and `tifffile` are not installed globally. The pinned Godot build used a separate task-local Python environment; no build dependency was added to the repository or generator runtime.
- Godot source reconnaissance and the successful Windows build verified Visual Studio Build Tools 2022 17.14.37710.0, MSVC 14.44.35207 and Windows SDK 10.0.26100.0, although `cl` is not on `PATH` and `vswhere` did not list the nonstandard installation. The engine source and tracked files remain unchanged.
- The pinned engine identifies as Godot 4.8.0 beta and supports `precision=single|double`. Its GDExtension `ResourceFormatLoader`, Resource, `ArrayMesh` and `HeightMapShape3D` APIs appear sufficient for a small consumer; no core engine change is currently justified. This is a source-level finding, not a tested runtime result.
- No matching Godot executable was found at the configured Godot MCP path. A direct Godot MCP version query failed with `ENOENT`; a reproducible source-built editor is now available under the pinned engine checkout. At this baseline, `integration/` still has no completed consumer project.
- Initial snapshot only: the connected GitHub integration could read branches and exact commits for all three owned repositories, and QA Lead confirmed there were no open PRs at that time. Write, PR creation and platform review permissions were unverified at baseline; these observations are not current. See the later review and integration record for Gate C and Gate D status.

## Pinned Godot Windows build and native tests

The exact engine commit `d7339113911696eac113d77df633c6a2571f1ec0` built as a Windows x86_64 editor with double precision and tests enabled. The working tree is clean; generated files and binaries are ignored build outputs.

- Isolated tools: SCons 4.11.1, official wheel 4,123,659 bytes, SHA-256 `454CEF364348053422696E3D2ECB4FA593C96A624F955842EAAEA64F95C8D11D`; Python `zstandard` 0.25.0, BSD-3-Clause Windows/Python 3.12 wheel 506,276 bytes, SHA-256 `FFEF5A74088F1E09947AECF91011136665152E0B4B359C42BE3373897FB39B01`. Both wheels were verified from PyPI metadata and installed only in a task-local temporary virtual environment. SCons required `zstandard` for the GDExtension interface-header generator. Optional AccessKit and Direct3D 12 integrations were disabled; their installers were not run.
- Build command: `scons platform=windows target=editor tests=yes precision=double accesskit=no d3d12=no`, executed with the isolated SCons 4.11.1 environment. A clean full build linked editor and console binaries in 1:00:22.92; an incremental rerun of the same command reported the target up to date.
- Executable: `godot.windows.editor.double.x86_64.exe`, 165,886,464 bytes, SHA-256 `FEE4AE8EA772111CE72F2B20F21DC2258C97926B989AA8E2092D337CE28E246B`; console build, 301,056 bytes, SHA-256 `2AFB9FD1A8DDAC30F453857673F64391189557360391E8E7E3BFC8B8BDEFCB32`. `--version` reports `4.8.beta.double.custom_build.d73391139`.
- Native suite command: `godot.windows.editor.double.x86_64.console.exe --headless --test`. The corrected run redirected `APPDATA`, `LOCALAPPDATA`, `TEMP` and `TMP` to task-local temporary directories. Result: **1,433 passed, 0 failed, 3 skipped; 425,398 assertions passed; exit 0**. Captured log SHA-256 is `3C1B19621000355BAC578A2D6102CC1650B7E1F6C1D54ACCB52F18B56DD23CB3`. The harness summary does not name the three skipped cases; the captured output also includes three non-fatal `CanvasItem::draw_*` diagnostics before the successful doctest summary.
- One initial run redirected only `LOCALAPPDATA`; Godot still used the protected default `APPDATA` for its log and editor directories, so its logger test crashed. That run is excluded. Redirecting both Windows data roots and temp variables resolved the filesystem error without touching the user profile. No profiling, benchmarking or performance tests were run.

This build verifies the pinned Windows engine and its native unit suite. It does not verify the WorldForge producer, project import, terrain consumer, rendering or collision integration.

## Main Lead source-policy decision

`prototype-data-policy.md` adopts USGS 3DEP bare-earth DEMs for two geographically separated U.S. prototype regions. The primary raster is the 1/3 arc-second seamless DEM; the same program's 1 arc-second seamless DEM is the fallback. This policy is restricted to prototype elevation experiments and does not clear global production data or non-elevation sources. Both selected tiles are acquired to local-only snapshots, with source, XML and TNM JSON file hashes and independent Rasterio header/window results recorded in `vertical-slice.md`. Both GeoTIFFs are 10,812 × 10,812 Float32, EPSG:4269, with ~9.25926e-05° grid spacing and `-999999` no-data; metadata identifies NAD83, NAVD88 metres and 1/3 arc-second. The Baltimore window contains valid elevations −0.23–38.488 m; Golden contains 1708.022–2093.891 m. Both tile sidecars disclaim accuracy warranty and provide no tile-specific accuracy bound. The inherited Mapterhorn/AWS/Copernicus terrain path is not approved for this pilot.

## Inherited generator capability and provenance findings

At the pinned generator revision, the elevation path in `worldgen/beamng-earth/server/dem.py:107-120,472,954` fetches Mapterhorn Terrarium WebP tiles, falls back to AWS Terrarium PNGs, and has separate polar Copernicus, Canada HRDEM and British Columbia LidarBC paths. It does not currently read the acquired 3DEP GeoTIFFs. `earthd.Server` constructs that `Dem` (`server/earthd.py:617`); the heightmap worker reaches it through `make_heightmap` and `blockworker.build` (`earthd.py:1664`, `blockworker.py:266`). `heightmap.generate` writes a 16-bit PNG on the inherited 2 m lattice and can emit Torque `.ter` output; the legacy Lua mod consumes these through BeamNG `TerrainBlock` interfaces. `earthd.py` also uses a localhost mod-message protocol and produces BeamNG scene/terrain conventions. The server is a separate process but the current end-to-end product path is not demonstrated without BeamNG. No WorldForge-native independent producer or output contract existed at this baseline.

The inherited `server/geodesy.py:80-88` passes an elevation as geodetic `h`; `native/earthfast/src/lib.rs:789-810` uses that value as ellipsoidal height in a WGS84 ECEF conversion. Reusing it unchanged with the approved USGS tiles would conflate NAVD88 orthometric height with ellipsoidal height. The tile metadata gives EPSG:4269/NAD83 but not a specific NAD83 realization/epoch. The selected contract and local-frame behavior must preserve those semantics; any use of a geoid operation or global ECEF placement must establish compatible reference-frame metadata first. NGS limits GEOID18 to NAD83(2011) epoch 2010.0 ellipsoidal heights ([GEOID18 technical details](https://www.ngs.noaa.gov/GEOID/GEOID18/geoid18_tech_details.shtml), [NGS datums and frames](https://nweb.ngs.noaa.gov/datums/)).

The generator root `LICENSE` and `native/earthfast/Cargo.toml` declare MIT. That does not clear bundled data, binaries, imagery or service terms. Its `CREDITS.md` lists Mapterhorn under per-source terms, AWS elevation under source-specific attribution, Copernicus DEM under its attribution licence, and HRDEM/LidarBC under Canadian provincial/federal open-government licences. It also lists in-use EOX cloudless imagery as CC BY-NC-SA 4.0, ODbL/Open Data Commons content, many feature-source licences and BeamNG proprietary runtime/assets. These are not used by WF-VS-01; restricted or mixed-source data must not be included in the standalone pilot. `server/earthfast.pyd` and `.so` were not executed, and the COG TIFF test fixtures have no verified file-level source record in the project credits.

## Gate A status

| Gate A requirement | Status | Evidence or next check |
|---|---|---|
| Inspect parent and pinned child revisions | Complete for Gate A baseline | Exact heads and parent gitlinks are captured above; Godot source/API and generator source/data-path audits are recorded. |
| Audit inherited capabilities and BeamNG coupling | Complete for Gate A baseline | The pinned server fetches legacy Terrarium/Mapterhorn sources and emits BeamNG-specific `.ter`/TerrainBlock outputs over its mod protocol; no standalone 3DEP producer exists. Source locations and the unresolved height-datum hazard are recorded above. No inherited README claim counts as proof. |
| Verify Windows build/test tooling and baseline outcomes | Complete with disclosed limits | Pinned Windows Godot double-precision editor/test build and 1,433-case native test suite passed; isolated tool hashes, commands, executable hashes and skipped cases are recorded above. Thirteen selected inherited generator tests passed in two default-sandbox runs (details below). No full generator suite or WorldForge terrain runtime test has run yet. |
| Map code and data licences/provenance | Initial map complete; production audit remains | Generator root license is MIT; existing non-USGS data/runtime terms and unresolved production rights are identified above and in `risk-register.md`. Both USGS 3DEP source snapshots and metadata are hash-verified; the approved prototype source path is public domain. |
| Establish prioritized high-risk register | Initial register complete | `risk-register.md` ranks independent generation, real source/datum handling, Godot build/consumption, spatial precision, streaming/lifecycle and rights, with mitigation evidence required. |
| Select first vertical-slice experiment | Selected | WF-VS-01 is recorded in `vertical-slice.md`: actual USGS 3DEP grids from Baltimore and a separated Front Range region into a versioned WorldForge terrain grid and a ground-level view in the pinned Windows Godot build. Acceptance is not yet met. |

Gate A exit is **not yet declared**. These records are ready for the QA Lead to review as an exact-revision integration milestone. The Main Lead will record the Gate A exit only after that independent review.

### Selected generator baseline tests

The inherited test runner `tools/run_tests.py` was inspected and deliberately not used: it writes `build/test-logs/` and `build/test_times.json`, and broad discovery collects unrelated tests. The following selected functional tests ran on Windows with Python 3.12.10 under the default managed workspace sandbox. All runs set `sys.modules["earthfast"] = None` before importing the test modules, so the checked-in native `.pyd` did not load. No network, BeamNG runtime, dependency installation, profiling or performance measurement occurred.

1. From `worldgen/beamng-earth/server/tests`, command `python -B -` with `CoverageTest.test_index` and all six `heightmap.GeometryTest` methods (`test_constants`, `test_sample_positions_on_lattice`, `test_block_size_parameter`, `test_grids`, `test_snap`, `test_choose_q_and_block_params`): **7 passed, 0 failed**.
2. From the same directory, command `python -B -` with `test_dem.DemCacheTest.test_failed_fetch_is_retried`, `CoverageTest.test_unlisted_tiles_are_not_asked`, and all four `DemPrefetchTest` methods (`test_downloads_missing_tiles_at_prefetch_priority`, `test_stops_when_refused`, `test_has_is_a_cheap_exists_check`, `test_keys_around`). The harness replaced only `tempfile.TemporaryDirectory` with a simple context manager that created six distinct case directories under `<workspace>/.gate_a_fs_tests_20261029`; generated artifacts were inspected and removed after process exit. **6 passed, 0 failed**.

Both exact inline runners used `unittest.TextTestRunner(verbosity=2)`, called `sys.exit(not result.wasSuccessful())`, and set `sys.modules["earthfast"] = None` before importing test modules to prevent loading the checked-in `.pyd`. They ran at generator revision `06ea781f3d721a11a0ee8ecc4ccfd95b4c32b556`, Windows PowerShell, Python 3.12.10, NumPy 2.5.3 and Pillow 12.3.0. The heightmap geometry methods use synthetic inputs; DEM cache/prefetch tests use fake fetchers. Run 2 created `<workspace>/.gate_a_fs_tests_20261029` before execution and set process-local `WF_TEST_TEMP_ROOT` to that path.

Run 1's exact PowerShell here-string command (working directory `worldgen/beamng-earth/server/tests`) was:

```python
import sys
import unittest

sys.modules["earthfast"] = None
import test_dem
import test_heightmap
loader = unittest.TestLoader()
suite = unittest.TestSuite([
    test_dem.CoverageTest("test_index"),
    loader.loadTestsFromTestCase(test_heightmap.GeometryTest),
])
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(not result.wasSuccessful())
```

Run 2 piped this complete Python body to `python -B -` from the same working directory:

```python
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.modules["earthfast"] = None
import test_dem

class WorkspaceTemporaryDirectory:
    _counter = 0
    def __enter__(self):
        type(self)._counter += 1
        self.path = Path(os.environ["WF_TEST_TEMP_ROOT"]) / f"case-{type(self)._counter:02d}"
        self.path.mkdir()
        return str(self.path)
    def __exit__(self, exc_type, exc, tb):
        return False

tempfile.TemporaryDirectory = WorkspaceTemporaryDirectory
loader = unittest.TestLoader()
suite = unittest.TestSuite()
suite.addTests(loader.loadTestsFromTestCase(test_dem.DemCacheTest))
suite.addTests([test_dem.CoverageTest("test_unlisted_tiles_are_not_asked")])
suite.addTests(loader.loadTestsFromTestCase(test_dem.DemPrefetchTest))
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(not result.wasSuccessful())
```

Together, these are 13 selected checks of inherited coverage-index parsing, cache retry, fake-fetcher prefetch/file behavior, and synthetic heightmap geometry. They do not verify the new USGS acquisition path, source/datum conversion, independent WorldForge output, Godot integration or real-data terrain rendering. A standard-library-only Python create/write/read/delete probe also passed under the default sandbox using a normal-permission workspace directory.

An earlier 13-test attempt using Python's default `TemporaryDirectory` inside the managed sandbox failed six filesystem-backed cases with `WinError 5` while writing to or cleaning up dynamically created temporary directories; the exact cause of that behavior is unresolved. Six pure tests passed in that attempt. A subsequent successful 13-test attempt used `require_escalated`; it is **excluded** from the accepted verification record. The standard-library directory probe, selected reruns and custom workspace temp adapter above succeeded under the default sandbox. No broad test suite ran.

## Initial baseline mission exit-criteria assessment (2026-10-29)

These rows capture the initial baseline only; they are not the current Gate C or Gate D status. `IN PROGRESS` describes the baseline work state, not completion. Current integration state is recorded below.

| Criterion | Baseline status | Required evidence |
|---|---|---|
| WF-EXIT-01 — Correct scope | NOT VERIFIED | Integrated architecture and code audit show standalone WorldForge separation and no BeamNG runtime dependency. |
| WF-EXIT-02 — Inherited baseline | IN PROGRESS | Source-level capability, gaps, dependency, build/test and licence evidence for exact pinned commits. |
| WF-EXIT-03 — Real independent producer | NOT VERIFIED | Executed standalone generator produces genuine source-derived terrain through a versioned WorldForge interface without BeamNG. |
| WF-EXIT-04 — Real Godot consumer | NOT VERIFIED | Reproducible supported Windows build loads and displays actual generator output at independently checked coordinates; ground-level runtime and capture record. |
| WF-EXIT-05 — Planetary feasibility | NOT VERIFIED | Tested coordinate/precision/LOD design across separated regions and applicable latitude, wrap, polar and datum edge cases with justified tolerances. |
| WF-EXIT-06 — Streaming feasibility | NOT VERIFIED | Functional async load/unload, transition, cancellation, recovery, origin handling, collision readiness where applicable and lifecycle evidence. |
| WF-EXIT-07 — Future game foundations | NOT VERIFIED | Specified and validated geographic-position, streamed-object lifecycle and state/simulation interfaces without gameplay. |
| WF-EXIT-08 — Windows reproducibility | NOT VERIFIED | Exact setup, build, launch, data acquisition and integration commands rerun on the actual Windows workstation; failures disclosed. |
| WF-EXIT-09 — Rights/provenance | IN PROGRESS | Auditable selected-code/data terms and attribution; any unresolved production rights recorded as gates. |
| WF-EXIT-10 — Independent QA | NOT VERIFIED | QA Lead's exact-revision independent review and final evidence report with no unresolved P0/P1 defects affecting exit claims. |
| WF-EXIT-11 — Production readiness | NOT VERIFIED | Reviewed architecture decisions, risk register, unresolved assumptions and prioritized executable production roadmap. |

## Review and integration record

At the initial baseline snapshot, the Gate A baseline/contract change was tracked in PR #1 on `codex/preproduction-records`; at that time it remained open and unmerged, and a fresh Luna-only independent review and merge approval were pending. This is historical baseline status.

Current state as of 2026-10-30: parent PR #2 head `ac41e39…` was QA-approved and merged into parent main as `bc11b65f90688161e77f69eea7ee37c1186a6b46`. Gate D source-identity work is committed locally on `codex/wf-gate-d-source-allowlist` at `5ad6487d7fc78f3b8972544d998e8b81731da3cd`. The adjacent Golden consumer and synchronized LOD follow-up are committed locally on `codex/wf-gate-d-adjacent-consumer` at `41cb237d0aa75d86386cdc7595d7bad5037cabb3`, based on the source-identity commit. They include the two-tile pair, LOD 0→1→0 transition tests and a disabled-physics policy for coarse LOD1 collision. Gate D independent QA review is pending. Publication is pending direct owner authorization; neither Gate D branch has been pushed or opened as a PR. The default managed command sandbox restricts writes and networking but permits reads outside an individual test directory; QA permits only source-inspected, explicitly scoped test commands under it. Every review record must identify the exact PR/artifact and component SHAs and use the fixed reviewer template.
