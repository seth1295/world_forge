# WorldForge Terrain Grid Contract v1

**Contract ID:** `urn:worldforge:contract:terrain-grid:1.0.0`  
**Status:** Selected for WF-VS-01; schema is drafted and consumer implementation is pending.  
**Owner:** WorldForge Main Lead.  
**Schema:** `contracts/terrain_grid_v1.schema.json` (JSON Schema Draft 2020-12).

## Purpose and spatial boundary

The contract carries a small, source-traceable elevation grid from an independent WorldForge producer to an engine consumer. It is engine-neutral. Godot nodes, meshes, collision and renderer resources are created by the consumer.

Version 1 describes one complete rectangular source window in a **regional projected elevation chart**. The horizontal frame is an anchor-centred ellipsoidal Azimuthal Equidistant projection on GRS80, applied to coordinates that retain the source NAD83 identity. Vertical samples retain NAVD88 orthometric metres. The consumer computes local up as `H - H0`. This is not ENU, ellipsoidal height, WGS84, ECEF or a planetary frame. V1 must reject global placement requests explicitly.

The two WF-VS-01 regions have different frame IDs. Their local coordinates cannot be combined. Every artifact reusing a frame ID must have an exactly equal `frame` object, including projection, source anchor and `H0`; reject any mismatch. A tile does not need to contain the regional anchor, but it must reference the same origin definition. The origin record names the source product ID and SHA-256 as well as the source row and column, longitude, latitude and anchor NAVD88 height.

V1 carries one full-resolution window and does not split oversized windows or encode LOD. It requires every source pixel in the window (stride 1, no resampling). Reject windows exceeding the bounds below. A future tiled contract must define one-sample shared boundaries and disjoint cell ownership before it can split a grid.

## Bundle and binary layout

One bundle contains exactly:

```text
manifest.json
horizontal_xy.f64le
height_samples.f32le
```

V1 payload names are fixed as shown; they are not user-controlled paths. Resolve them relative to the manifest directory, reject a symlink/reparse point, and verify the resolved files remain direct children of that directory. The manifest records each payload's exact byte length and lowercase SHA-256. Payload hashes cover the exact payload bytes; the manifest does not hash itself.

`horizontal_xy.f64le` contains two IEEE-754 binary64 little-endian values per sample: projected easting metres, then projected northing metres. Records are row-major: rows north-to-south, columns west-to-east. Each pair locates the source pixel centre in the regional frame. Required length is `rows * columns * 16` bytes.

`height_samples.f32le` contains the original, unresampled IEEE-754 binary32 source elevation in metres for the same row-major samples. Required length is `rows * columns * 4` bytes. Each value retains its source NAVD88 orthometric meaning. The source no-data value is recorded in the manifest, and V1 rejects a window containing any no-data sample; it never turns a sentinel into terrain or substitutes or interpolates a value. NaN, infinity, a no-data anchor or non-finite `H - H0` is invalid. The producer must verify the anchor sample in the source raster. The consumer verifies that every bundled sample is valid and the frame definition remains consistent.

The consumer computes `H - H0` in binary64, checks all coordinates and converted engine values for finiteness and the limits below, then creates geometry. The render mesh and collision must use the same vertices and cell diagonal. For a cell with `NW=(r,c)`, `NE=(r,c+1)`, `SW=(r+1,c)`, `SE=(r+1,c+1)`, V1 splits on the `NW-SE` diagonal into `(NW,SE,SW)` and `(NW,NE,SE)`. This is the clockwise front-face order required by the pinned Godot `ArrayMesh` convention for `E→X`, `H-H0→Y`, `N→-Z`. Tests must check upward-facing normals, visibility from above and collision queries from above.

## Manifest semantics

The schema defines field names, types, required properties and size limits. All objects reject unknown properties. Duplicate JSON object keys are invalid and must be rejected before values are used. The UTF-8 manifest is limited to 64 KiB; schema strings and arrays have explicit maximum lengths. The consumer validates byte size before parsing, validates schema and semantic constraints before allocating arrays or creating engine resources, and hashes payload files in bounded chunks before loading them into memory.

Semantic size and numeric limits are mandatory:

- `rows` and `columns` are integers from 2 through 4096.
- Before multiplication or allocation, require `rows <= 4,194,304 / columns`. This prevents overflow and caps samples at 4,194,304. Consequently horizontal payloads cannot exceed 67,108,864 bytes and height payloads cannot exceed 16,777,216 bytes.
- Source raster width/height, source offsets and anchor row/column are integers no greater than 100,000; offsets and anchor indices are nonnegative. Checked arithmetic must prove the window lies within the declared source raster dimensions. Window rows and columns must equal the grid dimensions. These limits remain well below the exact-integer range of Godot's JSON number parser.
- V1 requires one Float32 source band in metres, scale 1, offset 0, pixel-area semantics, a north-up affine transform (`rotation_x = rotation_y = 0`, positive pixel width and negative pixel height), and a finite source no-data value. Other raster layouts or encodings are rejected rather than implicitly converted.
- Source pixel-centre coordinates use absolute source indices: `source_row = row_offset + output_row`, `source_column = column_offset + output_column`; `longitude = x_origin + (source_column + 0.5) * pixel_width`; `latitude = y_origin + (source_row + 0.5) * pixel_height`. The producer checks first, last and anchor samples against the original raster. V1 rejects rotated or south-up transforms.
- `source_pixel_footprint_bounds` describes the outer pixel edges in the source CRS. `projected_sample_bounds_m` describes the min/max of pixel-centre coordinates in the regional projection. The CRS and bounds meaning are named explicitly.
- All horizontal samples must be finite and `abs(easting), abs(northing) <= 100,000 m`. Source height samples and `H0` must be finite and have absolute value at most 12,000 m; computed relative heights `H-H0` must be finite and have absolute value at most 24,000 m. Validate after conversion to the engine's `real_t` and before resource creation.
- Verify payload lengths and hashes before allocation. Reject unsupported versions, missing semantics, path changes, corrupt/truncated/oversized data, invalid hash text, bad source identity, stale request identity, invalid frame operations and any V1 no-data sample.

The manifest has a `frame_definition_sha256` and an `artifact_id`, both lowercase SHA-256 values. Hash inputs use explicit bytes so different JSON serializers produce identical results. For `frame_definition_sha256`, start with UTF-8 bytes `WF-TERRAIN-FRAME-1` followed by a zero byte. Append each frame string below in this exact order as a 4-byte unsigned little-endian UTF-8 byte length followed by the UTF-8 bytes: `frame_id`; horizontal `source_crs`, `source_axis_order`, `datum`, `ellipsoid`, `realization_epoch`, `projection_method`, `projection_wkt2`, `operation_proj_pipeline`, `projected_axis_order`, `unit`; vertical `datum`, `height_type`, `unit`, `local_up_expression`; origin `source_product_id`. Then append origin `source_raster_sha256` as 32 raw bytes, `source_row` and `source_column` as unsigned 32-bit little-endian integers, and `longitude_deg`, `latitude_deg`, `height_navd88_m` as IEEE-754 binary64 little-endian values. SHA-256 the resulting byte sequence.

For `artifact_id`, start with UTF-8 bytes `WF-TERRAIN-ARTIFACT-1` followed by a zero byte. Append `contract_id` as a 4-byte unsigned little-endian UTF-8 byte length and UTF-8 bytes, followed by raw 32-byte values for `frame_definition_sha256`, source raster SHA-256, source metadata SHA-256, product-record SHA-256, horizontal payload SHA-256 and height payload SHA-256. Append `row_offset`, `column_offset`, `rows` and `columns` as unsigned 32-bit little-endian integers. SHA-256 the resulting byte sequence. This content identity excludes `created_utc` and other execution timestamps. It is stable for identical content and is the cache/request identity for stale-result rejection. Publish one cross-language test vector with the example bundle and require the producer, validator and Godot consumer to reproduce both hashes. A consumer also tags each asynchronous request with its own unique request ID and discards a completion if either request ID or expected `artifact_id` no longer matches.

## Coordinate and height fields

The `source` object records provider, dataset/product ID and title, source URI, `acquired_at_utc`, `acquisition_time_basis`, product date, byte count and SHA-256 for the acquired raster, metadata sidecar and saved product record, plus source width/height/band, dtype, scale, offset, affine transform, pixel interpretation, no-data, CRS, horizontal datum, vertical datum, units, rights and attribution, and an explicit uncertainty statement. `acquired_at_utc` is the UTC timestamp when this local source snapshot was received; its basis is explicit (`filesystem_creation_time` or `recorded_download_receipt`). It is not the source product date, collection interval, per-pixel survey date or an accuracy bound. `snapshot_verified_date` records when the snapshot bytes and metadata were checked.

For the pilot, source horizontal CRS is `EPSG:4269`, raster axis order is longitude then latitude, datum is NAD83 on GRS80, and realization/epoch are unspecified by the source metadata. Source height is NAVD88 orthometric metres. The horizontal operation must be the direct same-source-datum projection only. Record the exact destination WKT2, PROJ pipeline, East/North axes, metre units, PROJ/GDAL versions and anchor. The pipeline must not contain an unintended WGS84 intermediate, datum shift or ballpark operation. The anchor must project to `(0,0)` within the declared numerical tolerance.

Ellipsoidal AEQD preserves ellipsoidal geodesic distance radially from its anchor, not arbitrary pairwise distances. Record independent forward/inverse reference results, radial and non-radial distortion across each crop, and the measured numerical tolerances. Report sampled values separately from a justified bound. These are horizontal chart distances, not terrain-surface distances, slope distances or elevation-corrected ground distances. The source datum realization and ellipsoid heights are unknown, so the slice does not claim exact physical terrain distances.

The `frame` object contains a stable region-specific `frame_id`, source horizontal CRS/datum/ellipsoid and realization/epoch status, full projection WKT2 and operation pipeline, projection anchor source identity/row/column/longitude/latitude, NAVD88 `H0` and its anchor source sample identity, axis order and units, and the vertical expression `H - H0`. Reused frame IDs require exact equality of this object across loaded manifests. The consumer rejects mismatched frames; v1 contains no implicit cross-frame conversion.

## Producer, trust and provenance responsibilities

The producer verifies the acquired source raster, sidecar and product-record bytes against their recorded hashes before extraction. It verifies the source window, values, no-data, pixel centres, anchor and selected projection operation, and links source identity to the payload hashes in the manifest. The consumer normally does not possess the 400+ MB source raster, so it does not claim to recompute source hashes from the bundle. It validates payload bytes and compares source, frame and `artifact_id` against the expected request or an approved dataset record. Payload hashes alone prove only agreement with the manifest, not the truth of its source claim.

The `generation` object records producer name/version/commit, output creation time, source window, `resampling: none`, output hashes, and transformation library versions. Do not include private local paths, credentials or user-specific directories. The consumer validates bundle structure, schema, payloads, supported source/frame identity and request freshness before allocating geometry. If the identity is not approved or a global placement is requested, it fails explicitly.

For USGS 3DEP, retain the product title/date and public-domain rights statement with the source links. No production rights are implied for other sources or the global world dataset.

## Contract validation and acceptance

Schema and producer/consumer tests must cover:

- the synthetic minimal example and the two acquired pilot manifests, exact payload hashes/lengths, row/column counts, sample order, pixel centres, source first/last/anchor samples, `H0`, no-data rejection and source provenance;
- bounds, offset/window containment, multiplication and allocation checks; duplicate-key and unknown-field rejection; fixed paths; stale artifact and request IDs; frame ID mismatch; unsupported projection or global placement rejection;
- independent forward/inverse coordinates, radial geodesic distances, representative cross-crop pair distances and measured distortion in both regions;
- same-frame shared-edge coordinates and heights, the fixed cell triangulation rule, and equality of render/collision triangles;
- loading, cancellation/stale completion, replacement and unload lifecycle in the actual Windows Godot build.

The schema is a structural first check; code must enforce the semantic and cross-file rules above. The two producer output bundles and their manifests are the source-linked integration artifacts. Their original full source rasters remain local and are not embedded.

## Why this interface

Preserving source Float32 heights and preprojected Float64 coordinates keeps source semantics explicit and lets the Godot consumer avoid an unverified datum operation. Fixed payload names, bounded dimensions and pre-allocation checks make the first consumer small and auditable. The producer remains independent of Godot and BeamNG.

V1 intentionally does not establish a global spatial bridge. A production architecture still needs a compatible NAD83 realization and vertical/geoid operation, an independently tested global reference frame, cross-region conversion and vertical alignment before it can claim ECEF or planetary placement.
