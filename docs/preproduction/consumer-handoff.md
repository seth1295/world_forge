# Gate B/C Godot consumer handoff

**Review state:** Gate C parent PR #2 was QA-approved at head `ac41e39…` and merged into parent main as `bc11b65f90688161e77f69eea7ee37c1186a6b46`. Gate D source-identity work is local on `codex/wf-gate-d-source-allowlist` based on that main revision; independent Gate D review is pending. Publication remains pending direct owner authorization. No Gate D push or PR has been made. No performance tests or profiling were run.

## Revision pins

| Component | Exact revision / identity |
|---|---|
| Parent integration base | `75ff6fd382c8470d57117c76654073352e114077`; feature branch `codex/wf-vs01-integration` is rebased onto this exact SHA. |
| Godot submodule gitlink | `d7339113911696eac113d77df633c6a2571f1ec0` |
| Godot executable | `4.8.beta.double.custom_build.d73391139`; executable SHA-256 `FEE4AE8EA772111CE72F2B20F21DC2258C97926B989AA8E2092D337CE28E246B` |
| Current merged generator and feature gitlink | `6d4cf589a278b5e2eea668c25bc43469f4d45791`; this is the updated `worldgen/beamng-earth` pin. Main Lead reports a 9/9 hardening run against the two real output bundles and identical replay of the outputs. |
| Producer commit encoded by these manifests | `635c250cc251d72724edeb4d338240f1344a8c91` |
| Previous parent-base generator gitlink | `06ea781f3d721a11a0ee8ecc4ccfd95b4c32b556`; it predates generator hardening. The feature branch now pins `6d4cf589a278b5e2eea668c25bc43469f4d45791`. |
| Terrain schema | `urn:worldforge:contract:terrain-grid:1.0.0`; Git blob `87b1423220043d19de9585bae770812f104e3715`; file SHA-256 `EFAA9F53E3EF7FEB1C5B3259730EF82E440540050D7A6E7EDDD5569D9E53EA7A` |

The generator submodule working directory is intentionally uninitialized in this parent worktree. The parent commit records the exact gitlink above, and Main Lead's read-only remote check confirmed that SHA is generator `main`; no generator submodule source files were changed here. The parent repo's raw source tiles are local-only and are not included here. For a source rebuild, set `WF_USGS_SOURCE_ROOT` to the local snapshot directory; do not put a personal path into public documentation. The product URLs, original raster/metadata/product-record hashes, crop windows, and source caveats are in [`vertical-slice.md`](vertical-slice.md). The consumer test/capture runs below use the checked-in bundle artifacts and do not read the original GeoTIFFs.

## Bundles used by the consumer

Both generated bundles are under `integration/assets/terrain/`. Producer-output manifest hashes below describe the generator's original JSON bytes. Windows autocrlf changes the manifest line endings in the runtime checkout, so the exact checkout size and SHA-256 are shown separately. The conversion preserves JSON semantics and canonical artifact IDs. XY and height payloads remain byte-identical to producer output; their listed lengths and SHA-256 hashes are the exact payload files read and verified by the consumer.

| Site | Source product | EPSG:4269 anchor | Grid | Producer-output manifest | Windows runtime manifest | XY payload | Height payload |
|---|---|---|---:|---|---|---|---|---|
| Baltimore, Maryland | `USGS 1/3 Arc Second n40w077 20260512` | `39.28995370377841 N, 76.60995370372139 W` | `216 × 216` | 6,710 bytes; producer SHA-256 `83DABD1A31BD4442C8DF961BAF1B41179727B43B33E32CBBC793037F7827A76B` | 6,861 bytes; runtime-checkout SHA-256 `EAA96351560B8E84E7DF80A64C4100287AE102E4BA4A9067EB9DF9500735F70D` | 746,496 bytes; `56D5970D3DA90E5297C216619C5F202FAAA91EC59F2853ED62D5BEAB011C0C87` | 186,624 bytes; `F06C34B1A57D1C6705DEB2BBBF7D848AFABD1728CF0A31911EAC375FFF90E03B` |
| Golden / Front Range, Colorado | `USGS 1/3 Arc Second n40w106 20260630` | `39.754953704278655 N, 105.21995370310027 W` | `216 × 432` | 6,723 bytes; producer SHA-256 `A1958FDF9291C0C2782B03DA3E65DC761588786824D884BD5FA245836F45E1E6` | 6,874 bytes; runtime-checkout SHA-256 `7E7A413A2446DC5464DBDDBB215143105F009111FCF155B0A79DF6CFE8C014A9` | 1,492,992 bytes; `8C39785B6C4FE91CF1497FF134DD3A00E6A45F504FA0B8BAEDDCC8C4C4B5B52D6` | 373,248 bytes; `249A1218475D7191C0D3A3484C5C50BBE6C09C3C39CBEA23903C1FFE3DC85616` |

The manifest's artifact IDs are `517b4b97207ecde635ef5adb52303d4b3590ff3641254d18123406bfabd129f7` (Baltimore) and `d4b1bb11e84402136f50edf265a66991d8014326378edbeeaa67c4b169e31d98` (Golden). The viewer uses one approved frame per site. It does not mix site-local coordinates.

## Viewer and camera configuration

The actual runtime was started from the pinned Godot executable in a 1280 × 720 window, 16:9 aspect, Forward+ renderer, Vulkan 1.4.341, on NVIDIA GeForce RTX 2080. Both images were captured after the asynchronous bundle load completed and at least two rendered frames had elapsed. `Camera3D` uses a 58° vertical field of view, 0.5 m near plane, and 8,000 m far plane. Its orientation is completely specified by `look_at(target, Vector3.UP)`.

Camera positions and targets are in each site's local terrain frame, in metres. They are not global coordinates.

| Site | Geographic anchor (EPSG:4269) | Camera position (E, up, -N) m | Look-at target (E, up, -N) m | Up |
|---|---|---|---|---|
| Baltimore | `39.28995370377841 N, 76.60995370372139 W` | `(-503.20670857749536, 28.0, -699.0378389103332)` | `(-846.6239912655444, 32.63882255554199, -1079.4178551042073)` | `(0, 1, 0)` |
| Golden / Front Range | `39.754953704278655 N, 105.21995370310027 W` | `(-1198.3306255951975, 118.5, 904.5941632146123)` | `(-1714.2119027677074, 364.36767578125, 1099.8264649481891)` | `(0, 1, 0)` |

The screen shows the technical overlay, selected site, sample dimensions, geographic anchor, frame ID and artifact prefix. The Golden terrain relief is visible in the overview. The Baltimore source is low-relief and subtle at this ground-level overview; a closer camera attempt did not show clearer shape and is not included as evidence. No terrain exaggeration or image texture was used.

## Reproduction on Windows

Replace the angle-bracket placeholders with the local checkout, verified Godot executable, and installed Agent Vision skill paths. These paths are local environment inputs and must not be committed. Each Godot process gets isolated task-local `APPDATA`, `LOCALAPPDATA`, `TEMP`, and `TMP` paths.

```powershell
$RepoRoot = '<PARENT_REPO_ROOT>'
$GodotExe = '<PINNED_GODOT_EDITOR_EXECUTABLE>'
$Integration = Join-Path $RepoRoot 'integration'
$TaskTemp = Join-Path $env:TEMP 'wf-vs01-godot-consumer'
$env:APPDATA = Join-Path $TaskTemp 'appdata'
$env:LOCALAPPDATA = Join-Path $TaskTemp 'localappdata'
$env:TEMP = $TaskTemp
$env:TMP = $TaskTemp
New-Item -ItemType Directory -Force -Path $TaskTemp,$env:APPDATA,$env:LOCALAPPDATA | Out-Null

$TestLog = Join-Path $TaskTemp 'terrain-consumer-tests.log'
$TestRun = Start-Process -FilePath $GodotExe -ArgumentList @(
    '--headless','--path',$Integration,'--log-file',$TestLog,'--','--test','all'
) -PassThru -Wait -WindowStyle Hidden
if ($TestRun.ExitCode -ne 0) { throw "Godot consumer tests failed with exit $($TestRun.ExitCode)" }
Select-String -LiteralPath $TestLog -Pattern 'WF_REBASE_MAX_ECEF_ERROR_M|WF_TERRAIN_TEST_RESULT'

$CaptureDir = Join-Path $TaskTemp 'captures'
$BaltimorePng = Join-Path $CaptureDir 'baltimore-final.png'
$GoldenPng = Join-Path $CaptureDir 'golden-final.png'
$BaltimoreLog = Join-Path $TaskTemp 'capture-baltimore-final.log'
$GoldenLog = Join-Path $TaskTemp 'capture-golden-final.log'
$BaltimoreRun = Start-Process -FilePath $GodotExe -ArgumentList @(
    '--path',$Integration,'--resolution','1280x720','--windowed','--log-file',$BaltimoreLog,
    '--','--site','baltimore','--capture',$BaltimorePng
) -PassThru -Wait -WindowStyle Normal
$GoldenRun = Start-Process -FilePath $GodotExe -ArgumentList @(
    '--path',$Integration,'--resolution','1280x720','--windowed','--log-file',$GoldenLog,
    '--','--site','golden','--capture',$GoldenPng
) -PassThru -Wait -WindowStyle Normal
if ($BaltimoreRun.ExitCode -ne 0 -or $GoldenRun.ExitCode -ne 0) { throw 'A runtime capture process failed' }
```

Agent Vision converts the actual viewport PNGs to budgeted WebP; the `asset` mode uses a 512-pixel short edge and does not access the screen or terminal window. The raw PNGs stay in task temp.

```powershell
$AgentVisionSkillRoot = '<AGENT_VISION_SKILL_ROOT>'
$CaptureScript = Join-Path $AgentVisionSkillRoot 'scripts/capture.py'
$VisionDir = Join-Path $TaskTemp 'vision'
python $CaptureScript asset --project-root $Integration --paths $BaltimorePng --out $VisionDir --label baltimore-overview
python $CaptureScript asset --project-root $Integration --paths $GoldenPng --out $VisionDir --label golden-overview
```

For this handoff, Agent Vision produced `20261030-054854-asset-baltimore-overview.webp` and `20261030-054854-asset-golden-overview.webp` at `short-edge:512`. The retained evidence files are `docs/preproduction/evidence/terrain-baltimore.webp` (9,474 bytes; SHA-256 `07F7E68628A3590C48B34925A4091B876787A440FFA1A679959765FDF9206A65`), `docs/preproduction/evidence/terrain-golden.webp` (11,200 bytes; SHA-256 `F9E1E0AFBB9665EB366851DDF3B0012000470C8E134E4AC2A2F016D7CDC6B748`), and `docs/preproduction/evidence/terrain-consumer-tests.log` (10176 bytes; SHA-256 `5B598CDCE81F97D5F51689747BACABAB9AA208B1B5F2A272C33F5E62F286EF0D`). The bad earlier desktop window capture was discarded; no terminal or editor UI is present in these retained frames.

An interactive viewer launch, without the one-shot capture option, is:

```powershell
& $GodotExe --path $Integration --windowed --resolution 1280x720 -- --site baltimore
```

The overlay's site selector requests either approved site and its `Unload` button releases the active render and collision node. Lifecycle automated tests exercise the same manager load/switch/unload paths.

## Results and limits

- Final parent Godot run: process exit 0; `WF_TERRAIN_TEST_RESULT=PASS checks=137 failures=0`. The test log includes duplicate-key, strict manifest, path traversal, bounds, bounded payload reads, source/frame/artifact identity, payload hashes, geodetic reference, origin-rebase, actual mesh/collision, ray and async lifecycle checks.
- During the isolated Windows test and capture runs, Godot logged `ERROR: Failed to read the root certificate store.` The local bundle paths still succeeded and every test/capture process exited 0. The root cause and behavior outside these local-file runs are unverified; this diagnostic is not considered resolved or generally harmless.
- Actual site bundles passed contract and hash validation; the consumer rejects invalid payloads before geometry allocation. Payload reads use an opened file handle, compare its length to the expected/cap, read exactly that many bytes, then verify exact length and SHA-256.
- Both actual renderer meshes and static collision faces derive from the same validated vertices and index order. Upward ray tests hit the same-index terrain sample at each site. Maximum observed engine vertex deviation was `0.000066998796 m` at Baltimore and `0.000084075472 m` at Golden.
- The manager's finite demand policy is one worker task plus one replaceable latest-site slot. Tests cover rapid toggles, stale-result rejection, unload while decoding, queue clear, reload, active-resource release and scene shutdown.
- The separate WGS 84 ECEF utility matches independent Rasterio 1.5.2 / GDAL 3.12.2 / PROJ 9.7.1 vectors within 0.1 mm. It allows 1 mm for local-origin reconstruction at Earth-radius magnitudes; the observed maximum was `0.000000000276 m`, a numerical representation result only.
- The Gate C viewer demonstrates two-site selection, load, render, collision and unload. Gate C did not demonstrate adjacent-tile continuity, seam handling, LOD transitions, or engine-wide floating-origin management. The regional terrain path performs no NAD83-to-WGS 84 operation and no NAVD88-to-ellipsoidal-height/geoid conversion. No source accuracy bound or source/geographic accuracy is inferred from floating-point tolerances.
- The test viewer allowlists the two original sites and is not a general open-data browser. It uses no imagery and does not implement gameplay, entity/state/persistence foundations or production streaming policy. Gate C QA is complete and merged; Gate D source-identity review remains pending, and publication is pending direct owner authorization.
