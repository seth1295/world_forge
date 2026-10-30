# Road and terrain interoperability proof v1

**Status:** completed local feasibility slice against parent base **bc11b65f90688161e77f69eea7ee37c1186a6b46**.
**Scope:** one bounded Census road-centerline excerpt projected into the checked-in Golden NAD83 / GRS80 AEQD frame and drawn over the real Golden USGS terrain support.
**Data distribution:** the county archive remains in task-local temporary storage. Only three clipped, derived centerlines are checked into integration/features/golden_roads_v1.json.

> **TIGER/Line® is a registered trademark of the U.S. Census Bureau. Use of the TIGER/Line® mark is limited to referring to the nature of this data. The Census Bureau makes no warranty, express or implied, as to positional or attribute accuracy of this data.**

The feature file uses the Census name only to identify its source. It does not use the mark as a proprietary product name.

## Source, vintage, and rights

The source is the U.S. Census Bureau’s 2026 TIGER/Line **All Roads** county shapefile for Jefferson County, Colorado (county FIPS 08059). The official TIGER/Line 2026 page records a release date of October 14, 2026; the official 2026 technical documentation says the feature files include updates through July 2026. The county Roads layer is listed in the Census FTP archive at approximately 2.7 MB. The acquired ZIP was **2,842,936 bytes**.

The bundled ISO metadata title is **TIGER/Line Shapefile, 2026, County, Jefferson County, CO, All Roads**.

- Archive: [tl_2026_08059_roads.zip](https://www2.census.gov/geo/tiger/TIGER2026/ROADS/tl_2026_08059_roads.zip)
- Official 2026 layer selector: [TIGER/Line Roads selector](https://www.census.gov/cgi-bin/geo/shapefiles/index.php?layergroup=Roads&year=2026)
- Official archive index: [2026 Roads directory](https://www2.census.gov/geo/tiger/TIGER2026/ROADS/)
- Vintage and release date: [2026 TIGER/Line page](https://www.census.gov/geographies/mapping-files/2026/geo/tiger-line-file.html)
- CRS, file structure, metadata, and source limitations: [2026 Technical Documentation, Chapter 3](https://www2.census.gov/geo/pdfs/maps-data/data/tiger/tgrshp2026/TGRSHP2026_TechDoc_Ch3.pdf)
- Legal disclaimer and citation request: [2026 Technical Documentation, Chapter 1](https://www2.census.gov/geo/pdfs/maps-data/data/tiger/tgrshp2026/TGRSHP2026_TechDoc_Ch1.pdf)
- MTFCC definitions: [2026 Technical Documentation, Appendix E](https://www2.census.gov/geo/pdfs/maps-data/data/tiger/tgrshp2026/TGRSHP2026_TechDoc_E.pdf)

The Census Bureau states that copyright protection is unavailable for U.S. Government works under 17 U.S.C. § 105 and asks users to cite the Bureau. This excerpt cites the U.S. Census Bureau and includes the requested conspicuous TIGER/Line trademark and accuracy disclaimer above. These statements describe this identified source; they do not clear rights for any other dataset or asset.

The selected archive SHA-256 is:

~~~text
d0063402ae35789546fbfc3041320aeb139d3b82845d8ca9ab1869dd55df4001
~~~

The archived component sizes and SHA-256 values are:

| Component | Bytes | SHA-256 |
| --- | ---: | --- |
| tl_2026_08059_roads.cpg | 5 | 3ad3031f5503a4404af825262ee8232cc04d4ea6683d42c5dd0a2f2a27ac9824 |
| tl_2026_08059_roads.dbf | 1,934,775 | d8a1b9e5ce8f1884dad974b05b14253662cbefafa07a0e0a52ec31ad9df36902 |
| tl_2026_08059_roads.prj | 165 | 0b9041e921d9ebb43247d314608fe9e38a0b008ee793067fc1806199ea1fb9dd |
| tl_2026_08059_roads.shp | 4,365,708 | f72b4eafa002de37aa365a181d9a19d723780d86e5ad8d8b65ed9720da58fe62 |
| tl_2026_08059_roads.shp.ea.iso.xml | 21,866 | 02c6ff600b5e42e49ea5e58c4b4c12de63effb58026b90c3c1ca6c5e5dec270c |
| tl_2026_08059_roads.shp.iso.xml | 50,147 | 71d81812c5db052859d2bfb8d9f832983184f39dad02a40f84ab05394f678f5a |
| tl_2026_08059_roads.shx | 120,076 | af4f1884be658f3d56b54a62a19ffc3c5428f30d82f3a453a3b35e4e6fa15946 |

The .prj identifies the layer as geographic NAD83 on GRS80 with degree units:

~~~text
GEOGCS["GCS_North_American_1983",
DATUM["D_North_American_1983",
SPHEROID["GRS_1980",6378137,298.257222101]],
PRIMEM["Greenwich",0],
UNIT["Degree",0.017453292519943295]]
~~~

The .cpg is UTF-8. The county All Roads shapefile contains 14,997 records and is a 2D PolyLine layer. Its checked DBF layout is:

| Field | DBF type and width | Meaning used here |
| --- | --- | --- |
| LINEARID | Character 22 | Stable source feature identifier |
| FULLNAME | Character 100 | Census expanded display name, possibly blank |
| RTTYP | Character 1 | Route type code, possibly blank |
| MTFCC | Character 5 | Census feature class code |

The source file contains no Z coordinate, road width, surface precision, or per-feature positional-accuracy guarantee for the selected roads. Census cautions that six decimal places do not imply six-decimal positional accuracy and does not warrant positional or attribute accuracy. Accuracy varies with the source material and its translation. This proof therefore makes no surveyed-ground-truth claim and sets no road-fit accuracy threshold.

## Selected features and crop

The producer parses the official county archive, clips in source geographic coordinates to the exact Golden crop, then projects the clipped line vertices. It preserves the Census LINEARID, FULLNAME, RTTYP, and MTFCC.

The committed excerpt contains three selected source lines:

| LINEARID | FULLNAME | RTTYP | MTFCC | Census feature class |
| --- | --- | --- | --- | --- |
| 11012811999747 | S Golden Rd | M | S1400 | Local neighborhood road, rural road, or city street |
| 1106092818987 | Lookout Mountain Rd | M | S1400 | Local neighborhood road, rural road, or city street |
| 110713405478 | US Hwy 6 | U | S1200 | Secondary road |

The clip bounds are inclusive and declared in source longitude/latitude order:

~~~text
longitude [-105.24, -105.20]
latitude  [ 39.745,  39.765]
~~~

The complete county ZIP is not stored in the repository. The source-to-feature converter checks archive size before allocation, reads it once into a bounded immutable byte snapshot, hashes that exact buffer, and passes it to the ZIP reader without reopening the path. It checks each component hash, validates the .prj, parses only the needed PolyLine/DBF data, clips to the crop, and emits the three selected features. The pinned Golden manifest and terrain payloads are also read through bounded snapshots and verified against their recorded hashes before parsing or sampling; projection identity checks use those same verified buffers. The converter pins the 6,724-byte Gate E Golden manifest produced by generator head 325cd2c at SHA-256 `a590c84e2be9a0ccfe0297031f777e5d6e5da3a1d1508554a15a123d30a06948`; `.gitattributes` preserves pinned JSON bytes on Windows; its 1,492,992-byte horizontal XY and 373,248-byte height payloads are checked against the manifest hashes before use.

## Versioned feature interchange

The engine-neutral contract is [roads_feature_collection_v1.schema.json](../../contracts/roads_feature_collection_v1.schema.json), with derived data at [golden_roads_v1.json](../../integration/features/golden_roads_v1.json). It is a small custom JSON interchange with a versioned schema. Projected local coordinates are not mislabeled as RFC 7946 GeoJSON longitude/latitude.

Contract identity:

~~~text
urn:worldforge:contract:road-centerlines:1.0.0
~~~

Each point includes:

- source longitude/latitude after crop clipping and deterministic source-segment interpolation;
- projected local easting/northing in metres;
- fractional terrain-grid row/column hints to locate the supporting DEM cell.

The collection carries its source ZIP hash, all seven component sizes/hashes, source field identities, crop, source CRS, exact Golden frame object, frame_definition_sha256, and the referenced Golden terrain artifact and source raster identities. Stable IDs are Census LINEARID; the recorded source record index is only a reproducibility aid.

The clipped three-feature bundle is **70,668 bytes**, SHA-256 **c92a254d1e92727fa325fd1ede7fdc5186b86e1ff4ccf0550f0f8eddbe087d96**. The test-only DEM sample vector is 594 bytes, SHA-256 **d2556ad8ad7a8cddf4b17cf9c9f9c60656839f6b848d567f9b6ef6c6b0e3bd39**. The schema is 17,440 bytes, SHA-256 **6363e98df7e093f94221ce122816a2f41eca669488294cd79a9366c2dea4d477**.

The CRS operation reuses the exact Golden terrain frame from Terrain Grid v1: NAD83 EPSG:4269, longitude/latitude input, GRS80 ellipsoid, ellipsoidal azimuthal equidistant projection, easting/northing output, metres. The recorded operation is:

~~~text
+proj=pipeline +step +proj=unitconvert +xy_in=deg +xy_out=rad +step +proj=aeqd +lat_0=39.754953704278655 +lon_0=-105.21995370310027 +ellps=GRS80 +x_0=0 +y_0=0
~~~

The converter uses Rasterio 1.5.2, GDAL 3.12.2, and PROJ 9.7.1 to transform from the source NAD83 geographic CRS to the exact WKT2 frame in the Golden terrain manifest. It applies no WGS 84, Helmert, grid, ballpark, epoch, or other unverified datum transformation. The source realization and epoch remain unspecified.

The interchange is strictly 2D. It contains no source height and no width field. It references NAVD88 orthometric terrain support for display only. The consumer samples the same Golden terrain triangles and computes local up as H-H0; that inferred drape is not a measured road elevation. The viewer adds a **3.0 m display-only vertical offset** after sampling to keep the line visible over the terrain. Test reports preserve the sampled NAVD88 H, terrain local H-H0, display offset, and display Y as separate values.

The producer resamples each source segment at no more than 10 m of projected chord length for deterministic line rendering. The viewer subdivides those projected chords at no more than 2 m while sampling the terrain triangles, so line segments follow the actual piecewise planar support surface. Both steps are display tessellation only; neither claims additional Census positional detail.

## Golden DEM sample and observed drape values

The fixture [golden_dem_sample_vector_v1.json](../../integration/features/fixtures/golden_dem_sample_vector_v1.json) is explicitly test-only and is **not** represented as a Census road. It starts from an exact Golden DEM pixel-centre coordinate at local grid row 75, column 150:

| Value | Result |
| --- | ---: |
| Source lon / lat | -105.22606481422345, 39.75800925983749 |
| Projected easting / northing | -523.6888073482423 m, 339.27606143183147 m |
| DEM NAVD88 orthometric height H | 1733.6090087890625 m |
| Golden anchor height H0 | 1729.523193359375 m |
| Local up H-H0 | 4.0858154296875 m |

The producer’s direct projection equals the exact checked-in horizontal_xy.f64le sample. The Godot test maps the fixture coordinate to the same terrain vertex and checks its exact H-H0. A second test uses the midpoint on a terrain triangle edge and checks the exact linear interpolation formula against that triangle.

The runtime sample reports are terrain-drape values at projected Census centerline locations, not road-survey residuals:

| Source feature | Source lon / lat | Projected E / N (m) | Terrain H NAVD88 (m) | Terrain H-H0 (m) |
| --- | --- | ---: | ---: | ---: |
| S Golden Rd (11012811999747, S1400) | -105.207111, 39.745753 | 1100.744483, -1021.473827 | 1754.658543 | 25.135349 |
| Lookout Mountain Rd (1106092818987, S1400) | -105.237618, 39.747384 | -1513.966232, -840.313927 | 1936.622141 | 207.098947 |
| US Hwy 6 (110713405478, S1200) | -105.225260, 39.747278 | -454.791194, -852.218855 | 1787.430827 | 57.907633 |

These values demonstrate that centerline coordinates use the same local chart and can sample the real terrain support. They do not show that Census road positions match surveyed pavement. No arbitrary XY shift was applied.

A source-clipped coordinate may lie in the outer half-pixel footprint beyond the terrain mesh’s pixel-centre hull. In this fixture, **13 of 364** resampled Census points fall outside the Golden support hull. The consumer leaves those points undraped; it neither extrapolates terrain height nor moves the line inward. The viewer’s additional 2 m display samples include 35 edge samples outside the same support and also leave them undraped. The source feature itself remains clipped to the exact requested crop.

## Runtime capture

The actual windowed Godot capture is [roads-golden-runtime.png](evidence/roads-golden-runtime.png), **1920 × 1080**, SHA-256:

~~~text
a3a80cf32d8c72ba4fa6a13d2b5cdc71c94c1bc66de337ef11250fe00dc2043c
~~~

The success HUD visibly states that Census positional accuracy is unspecified and that no survey-fit claim is made.

Capture context:

- Region: Golden / Front Range, Colorado; crop as above.
- Geographic anchor: longitude **-105.21995370310027**, latitude **39.754953704278655**.
- Local camera position (0, 2200, 1600) m; target (0, 80, 0) m.
- Terrain frame: wf-vs01:golden-grs80-aeqd.
- Frame definition SHA-256: 3059daecf5eba37d0e4f2b12dc4468cf45d9d122b42db44cff7059357d0e94f7.
- Golden terrain artifact: d4b1bb11e84402136f50edf265a66991d8014326378edbeeaa67c4b169e31d98.
- Golden terrain source raster SHA-256: 2a2ac1c4e0e571e5734bafff2b47f0b5cd864ddcb45b69085f0fbad86d44b4ba.
- Engine source revision: d7339113911696eac113d77df633c6a2571f1ec0.
- Runtime: Godot Engine v4.8.beta.double.custom_build.d73391139, double precision, Windows.
- Renderer: Vulkan 1.4.341, Forward+, NVIDIA GeForce RTX 2080.
- Runtime result: 3 Census centerlines, 351 of 364 source-resampled points sampled on terrain, 13 source points outside the DEM sample-centre hull, 1,641 rendered display vertices, 35 additional display samples outside terrain support, 5 rendered line strips, 3.0 m display offset.

The capture came from the running pinned Godot window, not a static or synthetic scene. Example PowerShell invocation from the parent repository root, with the project and output locations supplied by the caller:

~~~powershell
$RepoRoot = (Resolve-Path .).Path
$GodotExe = Join-Path $RepoRoot 'engine/godot/bin/godot.windows.editor.double.x86_64.exe'
$Capture = Join-Path $RepoRoot 'docs/preproduction/evidence/roads-golden-runtime.png'
$env:APPDATA = Join-Path $env:TEMP 'worldforge-godot-userdata'
& $GodotExe --resolution 1920x1080 --windowed --path (Join-Path $RepoRoot 'integration') --scene res://scenes/roads_interoperability_viewer.tscn -- --capture $Capture
~~~

The viewer logs its frame, terrain artifact, Census source ZIP hash, source IDs, drape counts, camera pose, and sampled road/terrain values. This demonstrates one local interoperability route only.

## Reproduction and verification

The parent repository pins Godot d7339113911696eac113d77df633c6a2571f1ec0 and generator 6d4cf589a278b5e2eea668c25bc43469f4d45791; this change makes no submodule changes. The actual Windows run used the pinned Godot executable and Python 3.12.10 / Rasterio 1.5.2 / GDAL 3.12.2 / PROJ 9.7.1.

Download the official archive into a task-local temporary folder, then set the variable without placing the full source archive in the repository:

~~~powershell
$env:WF_CENSUS_ROADS_ZIP = '<task-local path to tl_2026_08059_roads.zip>'
$env:WF_ROADS_BUILD_TEST_DIR = Join-Path $env:TEMP 'worldforge-roads-source/rebuild-verify'
~~~

The converter validates the exact archive and components before producing the excerpt:

~~~powershell
python integration/features/build_roads_feature_v1.py --source-zip $env:WF_CENSUS_ROADS_ZIP
~~~

The Godot consumer reads the feature collection once under its 4,000,000-byte cap, hashes the resulting `PackedByteArray`, and parses that same buffer only after its digest matches the pinned fixture hash. Its regression test changes one byte in the contract identity while keeping valid JSON and confirms the altered buffer is rejected by the digest check.

Python contract/source tests:

~~~powershell
python -m unittest discover -s integration/features -p 'test_roads_feature_v1.py' -v
~~~

Before running Godot scripts in a fresh checkout, build the project class cache and then execute the road suite:

~~~powershell
$env:APPDATA = Join-Path $env:TEMP 'worldforge-godot-userdata'
& $GodotExe --headless --editor --path (Join-Path $RepoRoot 'integration') --import --quit
& $GodotExe --headless --path (Join-Path $RepoRoot 'integration') --scene res://scenes/roads_interoperability_viewer.tscn -- --test roads
~~~

The observed Python test run completed **17 tests**: 16 passed and the symlink-alias case was skipped because this Windows environment did not grant symlink privilege (WinError 1314). The suite includes input/output alias rejection for all four inputs as either destination, normalized and hardlink aliases, source ZIP and component SHA-256 verification, rejection of oversized and mutated inputs before use, and byte-for-byte deterministic rebuild. The pinned Godot headless suite passed source ID/properties, frame identity, same-length changed-buffer digest rejection, malformed/non-finite/Z/width/duplicate rejection, exact DEM pixel-centre mapping, exact intermediate triangle interpolation, drape counts, and terrain/road scene placement.

The first Godot invocation before --editor --import --quit did not have the project global class cache and failed to resolve existing class_name scripts. After the import step, the pinned runtime test passed. The headless import logged an editor-help cache write failure outside the repository but completed its project scan and class registration. Godot also reports that it cannot read the Windows root certificate store in this environment; the local decode, draw, capture, and contract tests succeed without network access. These are environment warnings, not evidence of a data or projection failure.

## Limits and next integration work

- Census road positional accuracy is unspecified at the feature level, and no independent surveyed road reference was used. The observed terrain samples are not positional-fit metrics.
- No road width, physical surface, pavement elevation, intersection topology, bridges, tunnels, vertical clearance, or network routing is supplied by this proof.
- The 3 m display offset is a viewer overlay offset, not a measured road elevation. The 10 m source resampling and 2 m view subdivision do not add source detail.
- The exchange is bound to one Golden regional frame and one terrain artifact. It has no global datum bridge, cross-region transform, tile/LOD ownership, seam deduplication, streaming, or cancellation contract.
- Tile/LOD integration should retain each Census LINEARID across clipping, attach fragments to the same frame/artifact identity, deduplicate shared boundary ownership, and preserve the same DEM surface interpolation under unload, reload, and origin changes.
- Production road source selection, positional-quality policy, alignment tolerances, road widths/surfaces, grade separation, and network semantics remain open.

This is a feasibility slice for one local data path. It is not a production road model or an accuracy claim.

## Gate E combined Windows verification

Main Lead reran the 17-test Python suite after the Golden manifest and site catalog were aligned to generator 325cd2c. Sixteen tests passed against the official Census archive and current 6,724-byte Golden manifest; the symlink-alias case was skipped because Windows returned WinError 1314 (symlink privilege unavailable). The generated feature JSON remained byte-identical at 70,668 bytes and SHA-256 c92a254d1e92727fa325fd1ede7fdc5186b86e1ff4ccf0550f0f8eddbe087d96. The pinned Godot roads suite also passed on the combined local parent branch, which retains the accuracy/no-survey-fit success HUD. Raw outputs: [Python suite](evidence/roads-feature-python-tests.log), 3,357 bytes, SHA-256 `D992C93CA2A8DB0D7EF1315185D3CC14E4673994D3951C4DAA1CBA2FE2E00D19`; [pinned Godot suite](evidence/roads-feature-godot-tests.log), 9,047 bytes, SHA-256 `5A4D9CA43C63F7C32CEC257953FAD0F974DE84A4418734B0D531E83412F699E6`.

Main Lead captured the actual 1920x1080 windowed scene again from that combined branch with the pinned Godot executable and current producer-325 terrain manifest. The image was byte-identical to the earlier capture: 473,140 bytes, SHA-256 a3a80cf32d8c72ba4fa6a13d2b5cdc71c94c1bc66de337ef11250fe00dc2043c. Runtime logs identify the Golden frame and artifact, the Census archive digest, all three feature IDs, 351 supported / 13 unsupported terrain samples, 1,641 display vertices, 35 intermediate support misses and the 3 m display offset. The root-certificate-store diagnostic still appeared; this run used only local data.

These are Main Lead reproduction results, not independent QA approval. The exact combined parent head and road integration still await an independent review after QA capacity is available.
