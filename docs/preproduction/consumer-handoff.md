# Gate B/C and Gate D Godot consumer handoff

**Review state:** Gate C was QA-approved and merged at bc11b65f90688161e77f69eea7ee37c1186a6b46. A local Gate E integration branch based on consumer head 4a23601 now combines source identity (5ad6487), adjacent Golden pair/LOD (41cb237), Census roads proof (4f8cdd8), simulation foundations contracts, and a draft production roadmap. Its generator gitlink candidate is 325cd2c. The exact combined head has not received independent QA. The QA Lead hit its Luna usage limit before final review; previous verdicts apply only to their exact reviewed SHAs. No new parent PR/push was made; public publication remains held by the automatic-review direct-authorization requirement.

## Revision pins

| Component | Exact revision / identity |
|---|---|
| Gate C feature-branch base before merge | `75ff6fd382c8470d57117c76654073352e114077`; this is the pre-merge base used by `codex/wf-vs01-integration`, not current parent main. Gate C PR #2 was QA-approved at head `ac41e39…` and merged into parent main as `bc11b65f90688161e77f69eea7ee37c1186a6b46`. |
| Current parent main for Gate D | `bc11b65f90688161e77f69eea7ee37c1186a6b46` |
| Local Gate D source-identity commit | `5ad6487d7fc78f3b8972544d998e8b81731da3cd` on `codex/wf-gate-d-source-allowlist` |
| Local Gate D adjacent-consumer commits | Pair install `5304c625e78d42043c59d3dc9263e2aae0366a7c`; synchronized LOD and final evidence `41cb237d0aa75d86386cdc7595d7bad5037cabb3` on `codex/wf-gate-d-adjacent-consumer` |
| Godot submodule gitlink | `d7339113911696eac113d77df633c6a2571f1ec0` |
| Godot executable | `4.8.beta.double.custom_build.d73391139`; executable SHA-256 `FEE4AE8EA772111CE72F2B20F21DC2258C97926B989AA8E2092D337CE28E246B` |
| Current merged generator and parent gitlink | `6d4cf589a278b5e2eea668c25bc43469f4d45791`; this is the merged `worldgen/beamng-earth` pin on parent main. Main Lead reports a 9/9 hardening run against the two original real output bundles and identical replay of those outputs. |
| Producer commit encoded by the current four manifests | `325cd2c4048bc9cf19a2287afc4de51c145f4490` |
| Candidate parent generator gitlink for current Gate E integration | `325cd2c4048bc9cf19a2287afc4de51c145f4490`; it is local and not yet on parent main. |
| Previous parent-base generator gitlink | `06ea781f3d721a11a0ee8ecc4ccfd95b4c32b556`; it predates generator hardening. The feature branch now pins `6d4cf589a278b5e2eea668c25bc43469f4d45791`. |
| Terrain schema | `urn:worldforge:contract:terrain-grid:1.0.0`; Git blob `87b1423220043d19de9585bae770812f104e3715`; file SHA-256 `EFAA9F53E3EF7FEB1C5B3259730EF82E440540050D7A6E7EDDD5569D9E53EA7A` |

The generator submodule working directory is intentionally uninitialized in this parent worktree. The parent commit records the exact gitlink above, and Main Lead's read-only remote check confirmed that SHA is generator `main`; no generator submodule source files were changed here. The parent repo's raw source tiles are local-only and are not included here. For a source rebuild, set `WF_USGS_SOURCE_ROOT` to the local snapshot directory; do not put a personal path into public documentation. The product URLs, original raster/metadata/product-record hashes, crop windows, and source caveats are in [`vertical-slice.md`](vertical-slice.md). The consumer test/capture runs below use the checked-in bundle artifacts and do not read the original GeoTIFFs.

## Bundles used by the consumer

The four checked-in terrain manifests and bundles are under `integration/assets/terrain/{baltimore,golden,golden-west,golden-east}`. They were regenerated from the verified USGS snapshots with generator head `325cd2c4048bc9cf19a2287afc4de51c145f4490`; artifact IDs and binary payload hashes match the prior bundles. Per-file `.gitattributes` rules preserve the byte-pinned manifest and feature JSON files on Windows. The producer-output and runtime-checkout manifest hashes below are therefore equal in this Gate E candidate. XY and height payloads remain byte-identical to producer output and are verified by the consumer.

| Site | Source product | EPSG:4269 anchor | Grid | Producer-output manifest | Windows runtime manifest | XY payload | Height payload |
|---|---|---|---:|---|---|---|---|---|
| Baltimore, Maryland | `USGS 1/3 Arc Second n40w077 20260512` | `39.28995370377841 N, 76.60995370372139 W` | `216 × 216` | 6,711 bytes; producer/runtime SHA-256 `98AC1D138A2354548709AABC5C73C59878BFFE144F885CDDE47365637E815CC8` | 6,711 bytes; SHA-256 `98AC1D138A2354548709AABC5C73C59878BFFE144F885CDDE47365637E815CC8` | 746,496 bytes; `56D5970D3DA90E5297C216619C5F202FAAA91EC59F2853ED62D5BEAB011C0C87` | 186,624 bytes; `F06C34B1A57D1C6705DEB2BBBF7D848AFABD1728CF0A31911EAC375FFF90E03B` |
| Golden / Front Range, Colorado | `USGS 1/3 Arc Second n40w106 20260630` | `39.754953704278655 N, 105.21995370310027 W` | `216 × 432` | 6,724 bytes; producer/runtime SHA-256 `A590C84E2BE9A0CCFE0297031F777E5D6E5DA3A1D1508554A15A123D30A06948` | 6,724 bytes; SHA-256 `A590C84E2BE9A0CCFE0297031F777E5D6E5DA3A1D1508554A15A123D30A06948` | 1,492,992 bytes; `8C39785B6C4FE91CF1497FF134DD3A00E6A45F504FA0B8BAEDDCC8C4C4B5B52D6` | 373,248 bytes; `249A1218475D7191C0D3A3484C5C50BBE6C09C3C39CBEA23903C1FFE3DC85616` |

The manifest's artifact IDs are `517b4b97207ecde635ef5adb52303d4b3590ff3641254d18123406bfabd129f7` (Baltimore) and `d4b1bb11e84402136f50edf265a66991d8014326378edbeeaa67c4b169e31d98` (Golden default window). The viewer uses one approved frame per site. It does not mix site-local coordinates.

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
- The test viewer allowlists the original sites plus the two explicitly cataloged adjacent Golden windows; it is not a general open-data browser. It uses no imagery and does not implement gameplay, entity/state/persistence foundations or production streaming policy. Gate C QA is complete and merged; Gate D independent review of source identity and adjacent LOD work remains pending, and publication awaits direct owner authorization.

## Gate D adjacent Golden tiles and LOD proof

**State (initial Gate D source-identity and adjacent-pair branches):** Source identity was committed at 5ad6487d7fc78f3b8972544d998e8b81731da3cd. The adjacent Golden pair install is at 5304c625e78d42043c59d3dc9263e2aae0366a7c; the LOD/evidence head was 41cb237d0aa75d86386cdc7595d7bad5037cabb3. That initial branch used parent generator pin 6d4cf589a278b5e2eea668c25bc43469f4d45791 and manifests produced at fc9ff8a. This paragraph records those original Gate D SHAs; the current combined local Gate E branch regenerates all four manifests and proposes generator gitlink 325cd2c, as detailed below.

The adjacent manifests share `region_id=wf-vs01:golden-front-range`, `frame_id=wf-vs01:golden-grs80-aeqd`, full frame-definition SHA-256 `3059daecf5eba37d0e4f2b12dc4468cf45d9d122b42db44cff7059357d0e94f7`, source TIFF SHA-256 `2a2ac1c4e0e571e5734bafff2b47f0b5cd864ddcb45b69085f0fbad86d44b4ba`, and acquisition receipt `2026-10-29T13:41:19Z`. The catalog keeps the full source identity per window; the adjacent manifests state the receipt-based acquisition time basis.

| Window | Source window (row offset, column offset, rows, columns) | Artifact ID | Producer-output manifest | Windows runtime manifest tested by Godot | XY payload tested | Height payload tested |
|---|---|---|---|---|---|---|
| `golden-west` | `(2544, 8214, 216, 217)` | `f9ac01b194d487e6cfd69ac5b095af5fb6c268b76aaab873a51d515be7953132` | 6,708 bytes; SHA-256 `1417A825E0CF455A03E67767F9BA25632891810B0E776CE3F78CB4598A76494E` | 6,708 bytes; SHA-256 `1417A825E0CF455A03E67767F9BA25632891810B0E776CE3F78CB4598A76494E` | 749,952 bytes; SHA-256 `88D8AD5E760D604AA058461259FF15CE05633FD78611DAF831D28B33802CC8FC` | 187,488 bytes; SHA-256 `D362AC74ACBF8480E8E4CE59722B7C55ED6D0C80D3DB4EF03C88F253C61E1744` |
| `golden-east` | `(2544, 8430, 216, 216)` | `cbda8c91369c60315a0caff753583ac05df8d1aa25a91208b75fc9df4a7e62c8` | 6,726 bytes; SHA-256 `942824DA2C370545BBBDAD0964FEF771BA891259BF45DBB99302CF5D38D17A34` | 6,726 bytes; SHA-256 `942824DA2C370545BBBDAD0964FEF771BA891259BF45DBB99302CF5D38D17A34` | 746,496 bytes; SHA-256 `C8FC55A19D0C5A29A2E4DEFACCE1127D42C60A69FC0C0FF97864B4B47790EB77` | 186,624 bytes; SHA-256 `9F42DA47F3B4059079DA2AF5BF8B686DD28300013E2BD8C5076A041C789FDD26` |

The `.gitattributes` rules set `-text` for byte-pinned feature and terrain manifest JSON. The runtime-checkout manifest bytes therefore match the generated bytes on Windows. The checked-in XY and Float32 height payloads are unchanged and verified directly by the consumer.

## Pair adjacency and collision

The west source samples span absolute source columns 8214–8430; east spans 8430–8645. They share only column 8430: west local column 216 and east local column 0. The two windows have the same 216 rows at source row offset 2544. The decoder requires that relation, the exact same frame and source identity, full-resolution/no-resampling source windows, different artifact IDs, byte-identical Float64 XY and Float32 height records at the shared column, and matching local geometry. The cell strips meet at the shared sample center and do not overlap in area. The manifest footprints use AREA outer pixel edges and overlap by one source-pixel width; this expected metadata overlap is not treated as a mesh seam.

The asynchronous manager decodes and validates one or two windows in its single bounded worker policy. It constructs both candidate render/collision roots before attaching either one, so the pair installs and unloads as a unit. At LOD 0 every source sample is present. At LOD 1 the local row indices are `[0, 2, …, 214, 215]`; west columns are `[0, 2, …, 216]`; east columns are `[0, 2, …, 214, 215]`. These are exact source sample selections: no averaging or height resampling occurs. The final row and outer columns persist, and both coarse meshes retain global source column 8430 exactly.

The viewer's LOD control swaps both neighboring mesh roots in one main-thread operation. Both are always constructed and validated as a pair. The pair's policy is specific to these Golden windows; it is not a global LOD selector or a general tile-streaming policy. LOD 1 has a measured maximum source-index-aligned omitted-sample deviation of **13.497314453 m** for this crop. For every omitted source vertex, the test finds the corresponding coarse cell, uses the mesh's NW–SE diagonal, barycentrically interpolates the aligned point on that coarse triangle in `(E, H−H0, −N)`, and measures Euclidean distance to the omitted vertex. The maximum covers both tiles. This is an observed structural deviation, not an accepted ground-contact threshold, source accuracy, or geographic accuracy.

The level 1 collision shape is created from the same coarse faces as its render mesh, then disabled in Godot physics: `CollisionShape3D.disabled=true`, collision layer `0`, collision mask `0`. Tests verify same-index upward rays cannot hit it. The viewer labels it as disabled, and the manager marks it ineligible for ground contact. **LOD 1 is visual structural data only and must not be used for ground contact.** LOD 0 restores the full source-sampled collision shape and passes same-index upward rays at both interiors and the shared boundary. No player/character grounding is implemented.

## Gate D verification and reproduction

On the current local Gate E branch, the focused `--test adjacent` suite passed `137/137` and the full suite passed `232/232`, both with exit 0 after the checked-in manifests and site catalog were aligned to producer head `325cd2c`. The full suite covers the original Baltimore and full Golden bundles, source descriptor mutation rejection, strict v1 validation, WGS 84 geodetic and origin-rebase references, mesh/collision, async lifecycle, adjacent seam, LOD 0→1→0, disabled LOD1 collision, and LOD0 collision readiness. Shared vertex delta was `0.000000000000 m`; maximum crop-specific omitted-sample deviation was `13.497314453 m`. The retained logs are [full terrain checks](evidence/terrain-consumer-gate-d-tests.log), 18,080 bytes, SHA-256 `E45A32E74F8E354371AA1EE38A98FEB2741D9A9ED88D325CBCBA50F9B990B42D`, and [focused adjacent checks](evidence/terrain-consumer-gate-d-adjacent-tests.log), 10,768 bytes, SHA-256 `65A89FB05FE8177BE5F877C5576F0442FAB8101FB9C01B217549A0137D80A5BD`. The full and focused tests were rerun after the manifest/site-catalog update; root-certificate-store errors remain in each log.

The adjacent runtime camera uses anchor `39.754953704278655° N, 105.21995370310027° W` (manifest source frame EPSG:4269; local coordinates remain in the NAD83/GRS80 Golden AEQD frame), position `(-1198.3306255951975, 118.5, 904.5941632146123) m`, target `(-1714.2119027677074, 364.36767578125, 1099.8264649481891) m`, up `(0, 1, 0)`, FOV `58°`, near `0.5 m`, far `8,000 m`. `look_at(target, Vector3.UP)` sets orientation. Both captures use the 1280×720 window and the same camera.

Set `$RepoRoot`, `$GodotExe` and `$AgentVisionSkillRoot` to the local parent checkout, pinned editor executable, and installed Godot Agent Vision skill directory. These placeholders intentionally avoid personal workstation paths. Each Godot process uses task-local app-data/temp directories:

```powershell
$RepoRoot = '<PARENT_REPO_ROOT>'
$GodotExe = '<PINNED_GODOT_EDITOR_EXECUTABLE>'
$AgentVisionSkillRoot = '<AGENT_VISION_SKILL_ROOT>'
$Integration = Join-Path $RepoRoot 'integration'
$TaskTemp = Join-Path $env:TEMP 'wf-gate-d-adjacent'
$env:APPDATA = Join-Path $TaskTemp 'appdata'
$env:LOCALAPPDATA = Join-Path $TaskTemp 'localappdata'
$env:TEMP = Join-Path $TaskTemp 'temp'
$env:TMP = Join-Path $TaskTemp 'tmp'
New-Item -ItemType Directory -Force -Path $TaskTemp,$env:APPDATA,$env:LOCALAPPDATA,$env:TEMP,$env:TMP | Out-Null

$TestLog = Join-Path $TaskTemp 'terrain-gate-d-all.log'
$TestRun = Start-Process -FilePath $GodotExe -ArgumentList @(
    '--headless','--path',$Integration,'--log-file',$TestLog,'--','--test','all'
) -PassThru -Wait -WindowStyle Hidden
if ($TestRun.ExitCode -ne 0) { throw "Godot Gate D suite failed with exit $($TestRun.ExitCode)" }
Select-String -LiteralPath $TestLog -Pattern 'WF_GOLDEN_ADJACENT_MAX_SHARED_VERTEX_DELTA_M|WF_GOLDEN_ADJACENT_MAX_OMITTED_SAMPLE_DEVIATION_M|WF_TERRAIN_TEST_RESULT'

$CaptureDir = Join-Path $TaskTemp 'captures'
$Lod0Png = Join-Path $CaptureDir 'golden-adjacent-lod0.png'
$Lod1Png = Join-Path $CaptureDir 'golden-adjacent-lod1.png'
$Lod0Log = Join-Path $TaskTemp 'capture-lod0.log'
$Lod1Log = Join-Path $TaskTemp 'capture-lod1.log'
$Lod0Run = Start-Process -FilePath $GodotExe -ArgumentList @(
    '--path',$Integration,'--resolution','1280x720','--windowed','--log-file',$Lod0Log,
    '--','--tile-set','golden-adjacent','--lod-level','0','--capture',$Lod0Png
) -PassThru -Wait -WindowStyle Normal
$Lod1Run = Start-Process -FilePath $GodotExe -ArgumentList @(
    '--path',$Integration,'--resolution','1280x720','--windowed','--log-file',$Lod1Log,
    '--','--tile-set','golden-adjacent','--lod-level','1','--capture',$Lod1Png
) -PassThru -Wait -WindowStyle Normal
if ($Lod0Run.ExitCode -ne 0 -or $Lod1Run.ExitCode -ne 0) { throw 'A Golden adjacent runtime capture failed' }

$CaptureScript = Join-Path $AgentVisionSkillRoot 'scripts/capture.py'
$VisionDir = Join-Path $TaskTemp 'vision'
python $CaptureScript asset --project-root $Integration --paths $Lod0Png --out $VisionDir --short-edge 512 --quality 80 --label golden-adjacent-lod0
python $CaptureScript asset --project-root $Integration --paths $Lod1Png --out $VisionDir --short-edge 512 --quality 80 --label golden-adjacent-lod1
```

Godot's one-shot capture waits for at least two process frames and `frame_post_draw`; the PNGs are actual main viewport images from the running project. The raw PNGs remain task-local: LOD 0, 114,238 bytes, SHA-256 `220B7718C9E35944D51A5D3CA00F1B4ABA5A8EA87966FD70CF26A8BAD2782285`; LOD 1, 102,163 bytes, SHA-256 `6804FA65AA4FEE1EFEAE8427E5EA6553959F8C4C23AF5BE2755DFEEB73923CBB`. Agent Vision encoded them at 512 px short edge and quality 80. Retained files are [`terrain-golden-adjacent.webp`](evidence/terrain-golden-adjacent.webp), 11,908 bytes, SHA-256 `9BFF692D12F3970FE3223A3282AD72E3FC560EB4D5885E7CF5BE380286FDC741`, and [`terrain-golden-adjacent-lod1.webp`](evidence/terrain-golden-adjacent-lod1.webp), 13,202 bytes, SHA-256 `CECC5E150B5C76FD80C1277B2FE9FA287B7DE55FC768A4EE58AE79063F9FF264`. The LOD 1 overlay states the collision policy and observed deviation. Taste Receptor Atlas v2 review is [`terrain-golden-adjacent-visual-review.md`](evidence/terrain-golden-adjacent-visual-review.md): 141/144 (97.9%), Grade A, no hard gates; the image does not serve as proof of the seam or physics behavior.

**Limits:** This prototype exercises one specific pair in one crop, two exact-sample levels, and atomic neighbor transitions. It has no distance/error-driven global LOD selector, more-than-two tile installation, world-scale LOD schedule, or player grounding. LOD 1 physics is disabled; use LOD 0 for ground contact. The 13.497314453 m observed sample-aligned coarse deviation is not source accuracy or a ground-contact acceptance threshold. The terrain path still has no NAD83/NAVD88 to WGS 84 or geoid bridge, no engine-wide origin manager, and no source/geographic accuracy claim. Gate C remains QA-approved and merged; Gate D QA review is pending and publication waits on direct owner authorization.

## Current Gate E handoff snapshot (2026-10-30)

This document's Gate C command, bundle and capture details remain the merged baseline evidence. The local Gate E branch adds the following candidate revisions:

| Component | Current local revision | Verification status |
|---|---|---|
| Godot | `d7339113911696eac113d77df633c6a2571f1ec0` | Existing pinned Windows build and Gate C runtime evidence. |
| Generator | `325cd2c4048bc9cf19a2287afc4de51c145f4490` | Main Lead reproduced real-data generation for both legacy regions and the Golden split; the focused suite passed 16/16, with bounded same-buffer payload checks and rollback tests. |
| Source identity | `5ad6487d7fc78f3b8972544d998e8b81731da3cd` | Engineering reports 58/58 focused contract checks. |
| Adjacent consumer | `4a23601a4cacb20db1eb752cb03574dd6c76803c` | Main Lead reran the combined full suite (232/232) and focused adjacent suite (137/137) after regenerating all four manifests at producer 325. |
| Roads feature | `4f8cdd8bbdaf5df11828f7e610d2bd2d74fb9f55` | Main Lead reran Python 14/14 and the pinned-Godot roads suite; an actual combined-branch capture is 1920x1080, 473,140 bytes, SHA-256 `a3a80cf32d8c72ba4fa6a13d2b5cdc71c94c1bc66de337ef11250fe00dc2043c`. |
| Foundations/roadmap | Added on the local Gate E branch | Main Lead ran 10/10 structural contract tests. No Godot runtime persistence implementation is claimed. |

The four manifests in the current local handoff identify generator head `325cd2c4048bc9cf19a2287afc4de51c145f4490`. The Golden west/east payload and artifact IDs are unchanged from the earlier `fc9ff8a` outputs; the new manifests now align the embedded producer revision and receipt provenance with the candidate parent generator gitlink. The Golden roads feature continues to reference the full Golden artifact ID.

The parent branch stages generator gitlink `325cd2c`, but none of these Gate D/E revisions has received final consolidated independent QA. The QA Lead hit its Luna usage limit before reviewing these exact heads. Earlier QA decisions apply only to their reported SHAs. The current combined branch is local; no new parent PR or push has been made. The automatic public-disclosure review still requires direct owner authorization before publication.
