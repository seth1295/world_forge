# Gate D: approved source-raster identity and window catalog

**Status:** Source identity is implemented at local commit 5ad6487d7fc78f3b8972544d998e8b81731da3cd and incorporated into the local Gate E handoff branch. Its focused contract suite reports 58/58 tests. The v1 schema is unchanged; existing Baltimore and Golden bundles remain valid. Final exact-head independent QA is still pending.

## Source descriptor allowlist

Each approved site record now includes the complete `source.raster` descriptor from its manifest: affine transform, band, byte length, dtype, ellipsoid, dimensions, horizontal CRS/datum, no-data value, offset, pixel interpretation, realization epoch, scale, SHA-256, vertical datum/height type/units. The source CRS and axis order are fixed in the regional frame and its canonical frame hash; the complete frame hash is still compared with the site record.

The contract recursively compares every expected source field and recursively compares each site's `grid.source_window` with its approved window record. It performs those checks during `validate_manifest`, before payload reads, payload sample validation, or geometry-array allocation. A manifest that changes `source.raster.affine.x_origin` and adjusts footprint west/east bounds consistently is rejected on the pinned affine field. Changing `nodata_value` is also rejected against the approved source descriptor. No schema or canonical hash format changed.

Deterministic tests run each mutation against both real manifests. They assert the returned mismatch path. A decoder-level fixture additionally writes the adjusted affine/footprint and no-data variants, verifies both failures happen before payload loading, and asserts no `vertices` are returned. The fixture path is limited to a named task user-data subdirectory and is removed after verification.

## Window catalog extension

A site record owns the shared source identity, regional frame, anchor and producer. Its keyed `windows` map holds window-specific bundle directory, source-window tuple, rows/columns, artifact ID and camera. `get_site(site_id)` remains the compatibility API for the site's default window; `get_window(site_id, window_id)` resolves another approved window record. The consumer still requests and displays one default window per site. A synthetic catalog fixture verifies that two window records can inherit the same raster/frame identity while keeping distinct artifact and source-window IDs. This does not implement adjacent streaming, seams, collision transitions, or LOD.

The schema `contracts/terrain_grid_v1.schema.json` is unchanged at Git blob `87b1423220043d19de9585bae770812f104e3715` (SHA-256 `EFAA9F53E3EF7FEB1C5B3259730EF82E440540050D7A6E7EDDD5569D9E53EA7A`). The unchanged real bundles are the inputs for this run; their producer and Windows checkout manifest hashes are listed in [`consumer-handoff.md`](consumer-handoff.md).

## Verification pins and command

- Parent base: `bc11b65f90688161e77f69eea7ee37c1186a6b46`.
- Godot source gitlink: `d7339113911696eac113d77df633c6a2571f1ec0`.
- Godot executable: `4.8.beta.double.custom_build.d73391139`, SHA-256 `FEE4AE8EA772111CE72F2B20F21DC2258C97926B989AA8E2092D337CE28E246B`.
- Generator gitlink: `6d4cf589a278b5e2eea668c25bc43469f4d45791`.
- Original Gate C full-window manifest producer commit: `635c250cc251d72724edeb4d338240f1344a8c91`; the current combined Gate E candidate regenerates its manifests at producer `325cd2c`.

The full focused suite used task-local `APPDATA`, `LOCALAPPDATA`, `TEMP`, and `TMP` below `%TEMP%`. With `$RepoRoot`, `$GodotExe`, and `$Integration` set to the local checkout/executable/project:

```powershell
$TaskTemp = Join-Path $env:TEMP 'wf-gate-d-source-allowlist'
$env:APPDATA = Join-Path $TaskTemp 'appdata'
$env:LOCALAPPDATA = Join-Path $TaskTemp 'localappdata'
$env:TEMP = $TaskTemp
$env:TMP = $TaskTemp
New-Item -ItemType Directory -Force -Path $TaskTemp,$env:APPDATA,$env:LOCALAPPDATA | Out-Null
$TestLog = Join-Path $TaskTemp 'all-final.log'
$TestRun = Start-Process -FilePath $GodotExe -ArgumentList @(
    '--headless','--path',$Integration,'--log-file',$TestLog,'--','--test','all'
) -PassThru -Wait -WindowStyle Hidden
```

The process exited `0` and reported `WF_TERRAIN_TEST_RESULT=PASS checks=153 failures=0`. The focused contract suite reported `PASS checks=58 failures=0`. The negative source/payload fixture directory was absent after the full run. Logs are [`terrain-consumer-gate-d-tests.log`](evidence/terrain-consumer-gate-d-tests.log) (11,494 bytes; SHA-256 `2B8C58C513DE513B3951636277D5E8842F12474BAB4F5C6D91F6E3C37FAB8785`) and [`terrain-consumer-gate-d-contracts.log`](evidence/terrain-consumer-gate-d-contracts.log) (4,182 bytes; SHA-256 `2001070ACBDD6EC276C61D3E84CB52A140E3C0F3F38EF82929B22FC4DC3D53E2`). No performance tests or profiling were run.

## Scenario-specific regional transform criteria

Main Lead independently compared each crop's AEQD distances with GRS80 Vincenty geodesic distances. For each raster dimension `d`, the sampled indices were `round(i*(d-1)/12)` for `i=0..12`, yielding a 13 × 13 grid per crop that includes the corners and 14,196 unique pairs per site. For the crop's maximum radius `R`, the conservative small locally convex disk bound uses GRS80 semi-major axis `a=6378137 m`, flattening `f=1/298.257222101`, eccentricity squared `e²=f(2-f)`, and maximum Gaussian curvature `Kmax=1/(a²(1-e²))`. With `k(R)=sqrt(Kmax)*R/sin(sqrt(Kmax)*R)`, the pair bound is `B=2*R*(k(R)-1)`. A separate 1 mm independent numerical allowance is added to `B` and the limit is rounded upward as shown. These crop-specific criteria apply to transform-scale/numerical comparison only:

| Crop | Maximum radius from anchor | Curvature-comparison AEQD/geodesic pair bound | Sampled pair maximum | Radial maximum | Accepted transform/numeric limit |
|---|---:|---:|---:|---:|---:|
| Golden / Front Range | 2,042.063294 m | 0.000070245 m | 0.000026635 m | 0.000000039985 m | ≤ 0.0011 m |
| Baltimore | 1,405.967334 m | 0.000022926 m | 0.000008701 m | 0.000000010886 m | ≤ 0.00103 m |

Each acceptance limit is the stated curvature-comparison bound plus a 1 mm independent numerical allowance. These are not DEM source error, survey accuracy, or a global spatial error budget. USGS provides no tile-specific accuracy bound; none is inferred here. A compatible NAD83/NAVD88 to WGS 84 global operation remains unimplemented.
