# Global World Tile Bundle v1

**Contract ID:** `urn:worldforge:global-world-tile-bundle:1.0.0`
**Status:** Main Lead contract draft for the global terrain and geographic-content integration.
**Owner:** WorldForge parent repository.
**Scope:** Engine-neutral package consumed by the Godot global-world stream provider.

This contract combines the independent terrain and geographic-feature producer outputs for one WFG-1 address. The producer manifests remain authoritative for their own artifacts; a bundler/provider adapter validates them and emits this normalized package. A regional `terrain_grid_v1` bundle is not a substitute for this global contract.

## 1. Bundle layout

A published bundle is an immutable directory containing `manifest.json` and only the payload files named by that manifest. Payload paths are relative POSIX paths beneath the bundle root. Reject absolute paths, `.`/`..` components, symlinks, duplicate normalized paths, missing files, unlisted payload files when strict mode is enabled, size-limit violations, and SHA-256 mismatches before returning decoded data to the runtime.

The manifest is UTF-8 JSON. Binary payload descriptors declare media type, encoding, dimensions, data type, byte order, and array/geometry layout when applicable. A raster transform states whether its affine origin refers to a pixel corner or center, its axis order, row order, coordinate units, and no-data representation. A vector payload declares its encoding, geometry types, coordinate axis order/dimensions, and stable source feature IDs. The consumer must not infer these details from filenames.

Example directory:

```text
manifest.json
provenance/terrain-manifest.json
provenance/features-manifest.json
terrain/height_samples.f32le
terrain/source_mask.u8
terrain/quality_mask.u8
terrain/geoid_undulation.f32le       # when source conversion is available
terrain/geoid_mask.u8                 # validity of the geoid conversion per sample
terrain/ellipsoidal_height_samples.f64le # when source conversion is available
terrain/boundary_support.geojson        # when explicit mesh-edge samples are provided
roads/000000.geojson
roads/000001.geojson
buildings/000000.geojson
water/000000.geojson
landcover/classes.u8
vegetation/placement_support.u8
```

Only payloads listed for a layer may be consumed. `terrain` may contain `raster_grid` and `terrain_boundary_support`; `landcover` and `vegetation` may contain only `raster_grid`; `roads`, `buildings`, and `water` may contain only `vector_shard`. A ready terrain layer must contain at least one raster grid; boundary support alone is not a terrain surface. The two raw producer manifests are the only additional files and their relative paths, byte lengths, and SHA-256 values are listed under `producers`; they are retained byte-for-byte for audit. Optional layer payloads must be omitted from that layer's `payloads` array when not available. Temporary staging data is never a published bundle.

## 2. Canonical manifest

The machine-readable shape, field types, required properties, enums, and numeric bounds are normative in [`global_world_tile_bundle_v1.schema.json`](global_world_tile_bundle_v1.schema.json), Draft 2020-12. The prose below defines semantic constraints that also require runtime validation (for example address/bounds agreement, source-manifest mapping, payload hashes, and vertical conversions). The provider validates the schema and these semantic constraints before decoding; normalization must preserve the full manifest and every layer's source, quality, status, and spatial metadata.

The canonical manifest contains a schema ID/version, a 64-character lowercase SHA-256 `bundle_id` and `source_generation`, the fixed `source_id` profile, timestamp, `consumer_limit_profile_id`, `lod`, canonical `address`, centered `tile_origin`, producer/assembler identities and raw-manifest hashes, and a keyed `layers` object for the six required layer names. A successful zero-feature vector query may have no geometry payload, but it must include `feature_count: 0`, the completed query extent, its source/release, and a coverage statement that makes no claim of surveyed absence. The JSON Schema is strict about required field types and domain bounds; runtime validation additionally checks address/bounds equality, hashes, paths, sample dimensions, and geodetic/vertical consistency.

`source_id` identifies the configured combined source profile; `source_generation` identifies the immutable producer/data configuration for a request. They do not replace per-layer provenance. `lod` is a runtime representation level and is independent of WFG-1 address `level`. One source-native payload may be used to derive multiple render representations, but every derived level must identify its decimation/generalization method and preserve source data/provenance. Do not claim LOD transitions until distinct representations for the same address are actually produced and loaded, the transition is exercised, and shared-edge/collision behavior is verified.

`tile_origin` is the WGS84 geodetic center of the WFG-1 bounds at ellipsoidal height 0 m. It is a stable geometric tangent-frame anchor, not the local terrain elevation or a claim that the surface at the center is sea level. If an `ecef_m` value is included, it must use binary64 values and equal the independently recomputed WGS84 ECEF coordinates from the declared longitude, latitude, and ellipsoidal height within the documented arithmetic tolerance. The runtime may recompute this value rather than trusting it.

## 3. WFG-1 address and coordinates

WFG-1 addresses identify a hierarchy of geographic **extents**. Level 0 cells are 0.25 degrees wide and high, with `x` increasing east from longitude -180 and `y` increasing north from latitude -90. Each next address level halves both angular dimensions. Coordinates use normalized longitude in `[-180, 180)`; positive 180 maps to negative 180. Cells own their west and south edges and exclude east and north edges, except the global north pole belongs to the last northern row. Longitude is undefined at either exact pole, so the unique point owner at latitude +90 or -90 uses canonical longitude 0 (the midpoint x column at the requested level), regardless of the input longitude. A degenerate point request at a pole returns this one owner; non-degenerate extents touching a pole still enumerate all intersecting longitude columns because the area immediately below the pole spans those meridians. This rule changes point ownership only; it does not change tile bounds.

The supported address level is an integer `L` from 0 through 16. At level `L`, `x_count = 1440 × 2^L`, `y_count = 720 × 2^L`, and valid indices are `0 ≤ x < x_count`, `0 ≤ y < y_count`. Canonical IDs match `wfg1:<L>:<x>:<y>` with decimal integers and no leading zeros. Producers and consumers reject any other scheme, level, index, or noncanonical ID. The bounds are computed as `west = -180 + x × (0.25 / 2^L)`, `south = -90 + y × (0.25 / 2^L)`, `east = west + 0.25 / 2^L`, `north = south + 0.25 / 2^L`. The provider recomputes these values and requires exact finite-number equality with the manifest bounds before decoding.

The address's normalized lookup coordinates are EPSG:4326 longitude/latitude on the WGS 84 datum. This does not relabel or erase a source dataset's realization, epoch, axis order, or datum. Preserve those in `source_lineage` and record any operation used to transform source coordinates into the bundle's normalized address coordinates. `lod` describes a rendering/collision representation of one fixed WFG-1 extent; never use it as an alternate geographic address. A runtime may derive coarser mesh levels from the same source-native raster, provided the decimation, edge ownership, topology, and collision readiness are explicit. This does not change the original data's source resolution or create new source detail.

## 4. Producer-to-canonical mapping

The bundled producers keep their own source-native contracts. The assembler must validate each one before mapping it to the parent contract; it must retain the raw producer manifest files at `provenance/terrain-manifest.json` and `provenance/features-manifest.json`, record their exact byte lengths and SHA-256 values under `producers`, and copy or normalize data without discarding source lineage, masks, limits, rights notices, warnings, or transformation metadata.

| Producer input | Canonical mapping | Rejection/retention rule |
| --- | --- | --- |
| Global terrain `contract_id = urn:worldforge:contract:global-terrain-tile:1.0.0` | `tile.id`/`tile.level`/`tile.x`/`tile.y`/`tile.bounds_wgs84` → `address`; `terrain.status`/`requested` → `layers.terrain.status`/`requested`; `terrain.payloads[]` → terrain payload descriptors; `terrain.coverage`, `terrain.source_lineage`, `terrain.attribution`, `terrain.transform`, `terrain.grid`, `terrain.placement_surface`, `terrain.geoid_conversion`, masks and source legends → the corresponding terrain `coverage`, `source_lineage`, `attribution`, `transform`, `spatial_reference`, `metadata`, and `vertical_conversion` fields. Map raw `terrain.source_vertical_reference_by_mask` to canonical `vertical_conversion.vertical_references_by_source_code`, retaining each exact source and geoid mask code. `producer` and `generation` → `producers.terrain` and generation identity inputs. | Require canonical WFG-1 ID and exact recomputed bounds. Use `ellipsoidal_height_samples.f64le` only when the placement surface and conversion masks validate. For a mosaic, map each `source_mask` code to its own vertical reference. A missing/invalid conversion cannot become ready ellipsoidal terrain. Preserve source-native H and all masks. |
| Global geographic features `schema_id = urn:worldforge:global-feature-bundle:1.0.0` | `address.tile_id`/`level`/`x`/`y`/`bounds_wgs84` → the same canonical `address`; index each `layers[]` item by `layer_id` → `layers.<layer_id>`; `outcome` → `status`; `requested`, `payloads`, feature/pixel counts, query bounds, coverage claims/confidence, `source_lineage`, `attribution`, `transform`, `metadata`, and `error_code` → same-named canonical fields, with `query_bounds_wgs84` nested under `coverage`. Map producer payload `representation` to canonical `encoding` and preserve the original descriptor under `producer_metadata`. `producer`, release/rights catalogs and generation limits remain under `producers.features` and `layers.<id>.metadata`. | Require matching WFG-1 address and bounds. Duplicate/missing layer IDs, malformed/invalid geometry or incomplete shard sets fail the layer; the assembler never emits a truncated layer as complete. Completed zero-feature queries remain `ready` with count zero and query disclosure. Keep Overture per-feature `sources[]`, source license and stable source/fragment IDs in the GeoJSON. |
| Regional `terrain_grid_v1` (`EPSG:4269`, region-specific AEQD, NAVD88) | None by default. | It is not a WGS84/ECEF global terrain input. Reject it as a ready global terrain layer unless an explicit supported horizontal/vertical operation is independently documented and its result is validated. Never relabel its local coordinates or NAVD88 heights as WGS84/ellipsoidal. |

The canonical `layers` object has exactly one keyed record for each of `terrain`, `roads`, `buildings`, `water`, `landcover`, and `vegetation`; unsupported or unrequested content remains an explicit layer status rather than disappearing. Canonical `spatial_reference.axis_order` is an array, e.g. `["longitude", "latitude"]`; the current Godot internal enum string `longitude_latitude` is a derived adapter value and must be produced by the mapping, not copied as if it were the canonical representation. Canonical `tile_bounds` are nested under `address`; a Godot adapter may expose its internal flat `tile_bounds` dictionary by copying the four exact values, without changing them.

`source_id` is the profile string `worldforge-global-world-v1` for the selected source policy. The canonical `source_generation` and `bundle_id` are the same lowercase SHA-256 digest in v1. Construct the UTF-8 bytes in this exact order, using a single zero byte between components and no trailing delimiter: `WF-WORLD-GENERATION-1`, `source_id`, canonical `address_id`, base-10 `lod`, terrain producer `artifact_id`, feature producer `artifact_id` (copied from its `bundle_id`), assembler ID, assembler version, and assembler Git commit. SHA-256 those bytes. A different source policy, producer artifact, runtime LOD, assembler version/commit, or tile address therefore has a different generation identity. The exact source manifests and their source hashes remain available for independent reproduction.

The Godot adapter derives `layer_outcomes` from canonical `layers`, copying `status`, `requested`, coverage disclosure, fallback/gap, error code, payload descriptors, and producer metadata. It derives `layer_spatial_references` by copying the typed `spatial_reference` record and converting the canonical axis-order array to the internal enum. It must not turn `no_source_coverage`, `not_generated`, `failed`, or `cancelled` into an empty ready layer. It derives the internal flat `tile_bounds` from `address.tile_bounds`, verifies the requested source ID/generation/LOD, and retains the untouched canonical manifest alongside decoded arrays.

Terrain, vector features, water, land-cover samples and derived vegetation positions must be positioned from their own declared source coordinates and height semantics. All installed layers use the shared bundle tile origin and the runtime's local tangent frame. Source geometry is not placed at world-scale single-precision coordinates. A derived road or vegetation mesh may use procedural style parameters, but its metadata must distinguish those derived values from observed source attributes.

## 5. Consumer resource-limit profile

Every consumer uses a named, versioned, finite limit profile that is part of the executable/configuration and is reported in verification evidence. The profile is never taken from an untrusted manifest; the provider compares `consumer_limit_profile_id` with its configured profile and rejects an unknown or unsupported ID. Before allocation or parsing it bounds manifest bytes, total bundle bytes, each payload's bytes, payload descriptor count, raster width/height/pixel count, vector shard and feature counts, feature geometry coordinate count, relative path length, and decoded geometry bytes. The reference runtime profile is `worldforge.global-world.v1.default`; it caps a manifest at 16 MiB, a bundle at 4 GiB, one payload file at 1 GiB, one vector layer at 2 GiB serialized, one raster layer at 10 million samples, one vector layer at 2 million features and 50 million coordinate positions, decoded geometry at 4 GiB, payload descriptors at 65,536, one GeoJSON shard at 16 MiB, and a relative payload path at 1,024 bytes. Implementations may use a stricter profile; any override must use a new profile ID, be finite, appear in reproduction instructions, and be tested at its boundary. A limit violation rejects the whole affected layer or bundle before installation; no consumer or producer may silently truncate it. These are memory/integrity bounds, not performance targets.

## 6. Layer records and status semantics

Every layer in the bundle has a record with these required fields:

- `status`: one of `ready`, `partial`, `no_source_coverage`, `not_generated`, `failed`, or `cancelled`.
- `requested`: whether this request asked the producer for the layer.
- `payloads`: zero or more integrity-checked payload descriptors.
- `coverage`: query extent, counts where applicable, coverage claim, and confidence/limitations.
- `spatial_reference`: `horizontal_crs`, `horizontal_datum`, `axis_order` (an array), `has_elevation` (boolean), `source_vertical_datum`, `height_type`, and `vertical_datum`. A no-elevation layer sets the three vertical fields to `not_applicable`; an elevation-bearing layer declares the source and output vertical semantics and provides `vertical_conversion` when conversion or terrain-derived placement is used.
- `source_lineage`: one or more source records for source-derived output; empty only when no source was used.
- `attribution`: required attribution notices and license identifiers/URLs.
- `transform`: source-to-payload mapping, resampling/clip/generalization and geometry ownership details.

`ready` means the requested provider query or source window completed and payload validation passed. A completed vector query with zero returned features is `ready`; it is not proof that the real world contains no such feature. `partial` is installable only when the caller explicitly permits partial layers and the record discloses missing coverage, source/fallback identity and quality limitations. `no_source_coverage` must name a gap or an explicit fallback. `not_generated`, `failed` and `cancelled` are distinct and cannot be treated as empty-but-ready data. A stale or cancelled asynchronous result is never installed.

When applicable, `gap_declared` is boolean and `gap_reason` is a nonempty explanation. `disclosure` states any limitations visible to downstream rendering/inspection. A fallback is an object with at least `status: "ready"`, a nonempty `source_id`, and nonempty `provenance`; fallback quality/source identity must remain visible. Failed/cancelled records include a stable `error_code`, not a stack trace or secret.

`coverage` is evidence about the actual query and source response, not a completeness assertion by default. Include `feature_count` for vectors and `pixel_count`/`sample_count` for rasters. `coverage_claim` and `coverage_confidence` must be explicit and conservative. An empty Overture result or absent WorldCover/terrain asset cannot be converted into a claim of geographic absence.

## 7. Payload descriptors and layer content

Every payload descriptor includes `payload_kind`, `path`, `media_type`, `encoding`, `size_bytes`, and lowercase SHA-256 `sha256`. `payload_kind` is exactly `raster_grid`, `vector_shard`, or `terrain_boundary_support`; it determines the required descriptor fields and how the bytes are decoded. Raster descriptors also include `shape` (`[rows, columns]`), `dtype`, `byte_order`, row order, no-data handling, and a typed geotransform containing horizontal CRS, axis order, the six affine coefficients, `origin_reference` (`pixel_corner` or `pixel_center`), `pixel_registration` (`area` or `point`), and an explicit sample-coordinate rule. For zero-based column `c` and row `r`, compute `q=(c+0.5,r+0.5)` for a corner-referenced affine or `q=(c,r)` for a center-referenced affine, then `longitude=x_origin+q.x×pixel_width+q.y×rotation_x` and `latitude=y_origin+q.x×rotation_y+q.y×pixel_height`. Apply the complete affine in the declared axis order. Raster geotransforms may not omit whether their origin names a pixel corner or a sample center. Vector shard descriptors include geometry types, coordinate dimensions/axis order, and stable feature IDs retained in the payload. Boundary support uses a GeoJSON `FeatureCollection` of 3D `Point` features with IDs `boundary:<edge>:<index>` and declares the supported edges and sample counts in its descriptor. Payload paths are unique within a bundle.

### Terrain

The terrain record preserves its source-native height values and per-sample `source_mask`/`quality_mask`. If a verified EGM2008 grid is available, also preserve `N_EGM2008` and the converted ellipsoidal height `h = H_EGM2008 + N_EGM2008`. The layer's normalized placement surface uses `h` and declares `height_type: "ellipsoidal"` and `vertical_datum: "WGS84_ELLIPSOIDAL"`, with geoid grid identity, checksum, interpolation method and independent numerical validation in `vertical_conversion`.

Where only GEBCO nominal mean-sea-level height exists, retain its native height and Type Identifier. If an EGM2008 undulation is used to make a placement height, declare `source_vertical_datum: "MEAN_SEA_LEVEL"`, `approximate: true`, the method and a visible warning about heterogeneous shallow-water datums. Never label that conversion as surveyed ellipsoidal truth. If one tile's source mosaic has more than one vertical datum, declare `source_vertical_datum: "per_sample_source_mask"` and provide a `vertical_references_by_source_code` map in `vertical_conversion`, keyed by the exact `source_mask` values. Each entry identifies its source vertical datum, conversion method, approximation flag/warning, and corresponding geoid/conversion-mask code. Preserve `H`, `N`, `h`, source mask, quality mask and conversion mask as aligned arrays; the consumer validates their dimensions and code mappings before placement. A single-source tile may use a direct source-datum value. If the conversion grid is absent or invalid, emit the supported source-native layer with explicit unavailable vertical conversion or a visible geographic gap; the Godot provider must not silently invent or infer an ECEF height.

Raster sample coordinate semantics are explicit (pixel-center vs pixel-corner, grid origin, spacing/affine, row direction, coordinate axis order). Preserve native source spacing and avoid resampling unless the method, output transform and seam result are recorded. A source window with half-open ownership may omit the east/north outer mesh edge. Close that edge with a separate `terrain_boundary_support` payload; it is geometry support and does not change the half-open core raster ownership. Each feature is a GeoJSON 3D `Point` at `[target_longitude,target_latitude,h]`, with ID `boundary:<edge>:<index>` and `properties.worldforge.boundary_support` containing `edge`, zero-based `edge_index`, `edge_sample_count`, `source_sample_longitude`, `source_sample_latitude`, `source_height_H`, `source_vertical_datum`, `geoid_undulation_N`, `ellipsoidal_height_h`, `source_mask`, `quality_mask`, `type_identifier_mask`, `geoid_mask`, `sample_method` (`native_exact` or `nearest_native_sample`), `source_to_boundary_offset_m`, and any warning/source-artifact identity needed to explain the value. Edge ordering is deterministic: north west-to-east including both corners; east north-to-south excluding the northeast corner; south east-to-west excluding the southeast corner; west south-to-north excluding the southwest and northwest corners. An implementation may omit an edge only when the adjacent source samples needed to build it are unavailable and the corresponding geographic gap is disclosed. The provider requires every present edge sample to land at its exact declared target coordinate; it validates sample-method and source-offset disclosure before accepting the support geometry. Adjacent same-level tile bundles must expose exactly the same target boundary coordinates and ellipsoidal `h` values along every shared edge. Renderer and terrain collision use the same validated vertex positions and triangle topology. The support ring is excluded from interior raster sample counts and source-grid spacing claims.

### Roads, buildings and water

Vector geometries use WGS 84 longitude/latitude coordinates after a declared transformation, retain stable source IDs, feature-level source records and license data, and are clipped to the WFG-1 extent with deterministic half-open boundary ownership. Fragment identifiers must be stable when source geometry and clipping inputs are unchanged. Use bounded multiple shards for dense tiles; never truncate features to meet an arbitrary feature cap. Preserve bridges, tunnels, road class, and other source attributes when available. Do not invent a surveyed road width, elevation, building height, or water surface; any procedural rendering width/height is a disclosed style parameter and is kept separate from source facts.

### Land cover and vegetation

Land-cover rasters preserve original category codes, source no-data, native grid transform, source product/version and pixel counts. WorldCover classes are categorical classes, not continuous values. A derived vegetation-support layer retains its class mapping and exact relationship to its source pixels. It does not represent observed individual tree locations. Procedural plant/clump placement, mesh density, jitter or exclusions are separate derived metadata and must be reproducible, bounded per WFG-1 tile, and clearly labelled synthetic. Where a water, road, or building exclusion mask was not used, say so rather than implying such exclusions.

## 8. Provenance and rights

Each source lineage record identifies, when available: provider; dataset/product and release; source feature or asset ID; source URI; retrieval time or immutable snapshot; source-object size, ETag and checksum; original CRS/datum/realization/epoch and units; source quality/uncertainty; license/terms URL; attribution; and any conversion/clip operation. Preserve feature-level source attribution records from Overture. Keep ODbL-derived data separable and retain obligations. Preserve the ESA WorldCover CC BY 4.0 attribution and the Copernicus/GEBCO source notices. Do not package restricted sources or publish local prompt data, credentials, or raw datasets whose redistribution terms are not satisfied.

## 9. Runtime validation and compatibility

The Godot provider validates the exact schema ID/version before decoding; canonical address ID, numeric bounds and tile origin must agree with the requested WFG-1 extent. It checks every required layer status, spatial reference, payload size/path/hash, raster dimensions, supported encoding, and vertical conversion record. It rejects unknown status/CRS/datum, malformed or unbounded payloads, contradictory metadata, unlisted paths in strict mode, and unsupported future major versions. A provider may skip an optional layer only when the layer status explicitly says why.

The provider maps canonical `layers` into its internal `layer_outcomes`, `layer_spatial_references`, and decoded layer objects without dropping provenance or changing status. `source_id` and `source_generation` must match the request; `lod` must match the requested representation. The logical address stays fixed across source or LOD replacement.

Minor versions may add optional fields. Breaking field meaning, payload semantics or required fields requires a new major schema ID. Producers and consumers publish exact schema versions and commits in their test evidence. A producer output from a regional contract must be adapted explicitly; guessing or silently coercing fields is invalid.

## 10. Required acceptance evidence

Before this contract is approved for integration, producer and consumer evidence must include:

1. A schema-valid, genuine source-derived tile containing terrain plus actual geographic feature output, with payload hashes verified from a fresh cache/bundle directory.
2. Independent spot checks of selected terrain values, geographic coordinates, source masks and feature IDs against the authoritative producer inputs.
3. Address/bounds and payload tampering rejection; explicit empty-vector, partial, gap, fallback, failed and cancelled outcomes.
4. The same real tile loaded and displayed by the pinned Windows Godot build; terrain collision readiness uses matching validated mesh geometry.
5. At least geographically separated land, ocean/coast, high-latitude and antimeridian/polar test addresses through the actual acquisition and runtime path, with unsupported source coverage visible.
6. Repeated load, unload, cancellation, source/LOD replacement and rebase using real decoded data, not synthetic-provider-only evidence.

The schema and unit fixtures prove contract behavior only. They do not by themselves prove global data coverage, completed LOD behavior, visual correctness, source accuracy, or the full-world exit criteria.
