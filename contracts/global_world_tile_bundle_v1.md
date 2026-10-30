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
terrain/height_samples.f32le
terrain/source_mask.u8
terrain/quality_mask.u8
terrain/geoid_undulation.f32le       # when source conversion is available
terrain/geoid_mask.u8                 # validity of the geoid conversion per sample
terrain/ellipsoidal_height_samples.f64le # when source conversion is available
roads/000000.geojson
roads/000001.geojson
buildings/000000.geojson
water/000000.geojson
landcover/classes.u8
vegetation/placement_support.u8
```

Only payloads listed for a layer may be consumed. Optional files must be omitted from that layer's `payloads` array when not available. Temporary staging data is never a published bundle.

## 2. Canonical manifest

The following fields are required. The provider validates this external form, verifies each payload, and can normalize it into an engine-facing envelope; normalization must preserve the full manifest and every layer's source, quality, status, and spatial metadata.

```json
{
  "schema_id": "urn:worldforge:global-world-tile-bundle:1.0.0",
  "schema_version": "1.0.0",
  "bundle_id": "stable producer bundle identity",
  "created_at_utc": "RFC 3339 UTC timestamp",
  "source_id": "worldforge-global-world",
  "source_generation": "immutable generation/configuration identity",
  "lod": 0,
  "address": {
    "scheme": "WFG-1",
    "address_id": "wfg1:0:729:555",
    "level": 0,
    "x": 729,
    "y": 555,
    "tile_bounds": {
      "west_deg": 2.25,
      "south_deg": 48.75,
      "east_deg": 2.5,
      "north_deg": 49.0
    },
    "horizontal_crs": "EPSG:4326",
    "horizontal_datum": "WGS84",
    "axis_order": ["longitude", "latitude"],
    "edge_ownership": "west_south_inclusive_east_north_exclusive"
  },
  "tile_origin": {
    "horizontal_crs": "EPSG:4979",
    "horizontal_datum": "WGS84",
    "vertical_datum": "WGS84_ELLIPSOIDAL",
    "height_type": "ellipsoidal",
    "longitude_deg": 2.375,
    "latitude_deg": 48.875,
    "ellipsoidal_height_m": 0.0
  },
  "producers": {
    "terrain": {"id": "producer id", "version": "version", "commit": "revision"},
    "features": {"id": "producer id", "version": "version", "commit": "revision"}
  },
  "layers": {
    "terrain": {
      "status": "ready",
      "requested": true,
      "payloads": [],
      "coverage": {},
      "spatial_reference": {},
      "source_lineage": [],
      "attribution": [],
      "transform": {}
    },
    "roads": {"status": "ready", "requested": true, "payloads": [], "coverage": {}, "spatial_reference": {}, "source_lineage": [], "attribution": [], "transform": {}},
    "buildings": {"status": "ready", "requested": true, "payloads": [], "coverage": {}, "spatial_reference": {}, "source_lineage": [], "attribution": [], "transform": {}},
    "water": {"status": "ready", "requested": true, "payloads": [], "coverage": {}, "spatial_reference": {}, "source_lineage": [], "attribution": [], "transform": {}},
    "landcover": {"status": "ready", "requested": true, "payloads": [], "coverage": {}, "spatial_reference": {}, "source_lineage": [], "attribution": [], "transform": {}},
    "vegetation": {"status": "ready", "requested": true, "payloads": [], "coverage": {}, "spatial_reference": {}, "source_lineage": [], "attribution": [], "transform": {}}
  }
}
```

The values in `layers` above illustrate required structure only; an empty payload list is not a valid successful terrain or raster layer. A successful zero-feature vector query may have no geometry payload, but it must include `feature_count: 0`, the completed query extent, its source/release, and a coverage statement that makes no claim of surveyed absence.

`source_id` identifies the configured combined source profile; `source_generation` identifies the immutable producer/data configuration for a request. They do not replace per-layer provenance. `lod` is a runtime representation level and is independent of WFG-1 address `level`. One source-native payload may be used to derive multiple render representations, but every derived level must identify its decimation/generalization method and preserve source data/provenance. Do not claim LOD transitions until distinct representations for the same address are actually produced and loaded, the transition is exercised, and shared-edge/collision behavior is verified.

`tile_origin` is the WGS84 geodetic center of the WFG-1 bounds at ellipsoidal height 0 m. It is a stable geometric tangent-frame anchor, not the local terrain elevation or a claim that the surface at the center is sea level. If an `ecef_m` value is included, it must use binary64 values and equal the independently recomputed WGS84 ECEF coordinates from the declared longitude, latitude, and ellipsoidal height within the documented arithmetic tolerance. The runtime may recompute this value rather than trusting it.

## 3. WFG-1 address and coordinates

WFG-1 addresses identify a hierarchy of geographic **extents**. Level 0 cells are 0.25 degrees wide and high, with `x` increasing east from longitude -180 and `y` increasing north from latitude -90. Each next address level halves both angular dimensions. Coordinates use normalized longitude in `[-180, 180)`; positive 180 maps to negative 180. Cells own their west and south edges and exclude east and north edges, except the global north pole belongs to the last northern row. Longitude is undefined at either exact pole, so the unique point owner at latitude +90 or -90 uses canonical longitude 0 (the midpoint x column at the requested level), regardless of the input longitude. A degenerate point request at a pole returns this one owner; non-degenerate extents touching a pole still enumerate all intersecting longitude columns because the area immediately below the pole spans those meridians. This rule changes point ownership only; it does not change tile bounds.

The address's normalized lookup coordinates are EPSG:4326 longitude/latitude on the WGS 84 datum. This does not relabel or erase a source dataset's realization, epoch, axis order, or datum. Preserve those in `source_lineage` and record any operation used to transform source coordinates into the bundle's normalized address coordinates. `lod` describes a rendering/collision representation of one fixed WFG-1 extent; never use it as an alternate geographic address. A runtime may derive coarser mesh levels from the same source-native raster, provided the decimation, edge ownership, topology, and collision readiness are explicit. This does not change the original data's source resolution or create new source detail.

Terrain, vector features, water, land-cover samples and derived vegetation positions must be positioned from their own declared source coordinates and height semantics. All installed layers use the shared bundle tile origin and the runtime's local tangent frame. Source geometry is not placed at world-scale single-precision coordinates. A derived road or vegetation mesh may use procedural style parameters, but its metadata must distinguish those derived values from observed source attributes.

## 4. Layer records and status semantics

Every layer in the bundle has a record with these required fields:

- `status`: one of `ready`, `partial`, `no_source_coverage`, `not_generated`, `failed`, or `cancelled`.
- `requested`: whether this request asked the producer for the layer.
- `payloads`: zero or more integrity-checked payload descriptors.
- `coverage`: query extent, counts where applicable, coverage claim, and confidence/limitations.
- `spatial_reference`: horizontal CRS/datum/axis order and explicit vertical semantics.
- `source_lineage`: one or more source records for source-derived output; empty only when no source was used.
- `attribution`: required attribution notices and license identifiers/URLs.
- `transform`: source-to-payload mapping, resampling/clip/generalization and geometry ownership details.

`ready` means the requested provider query or source window completed and payload validation passed. A completed vector query with zero returned features is `ready`; it is not proof that the real world contains no such feature. `partial` is installable only when the caller explicitly permits partial layers and the record discloses missing coverage, source/fallback identity and quality limitations. `no_source_coverage` must name a gap or an explicit fallback. `not_generated`, `failed` and `cancelled` are distinct and cannot be treated as empty-but-ready data. A stale or cancelled asynchronous result is never installed.

When applicable, `gap_declared` is boolean and `gap_reason` is a nonempty explanation. `disclosure` states any limitations visible to downstream rendering/inspection. A fallback is an object with at least `status: "ready"`, a nonempty `source_id`, and nonempty `provenance`; fallback quality/source identity must remain visible. Failed/cancelled records include a stable `error_code`, not a stack trace or secret.

`coverage` is evidence about the actual query and source response, not a completeness assertion by default. Include `feature_count` for vectors and `pixel_count`/`sample_count` for rasters. `coverage_claim` and `coverage_confidence` must be explicit and conservative. An empty Overture result or absent WorldCover/terrain asset cannot be converted into a claim of geographic absence.

## 5. Payload descriptors and layer content

Every payload descriptor includes `path`, `media_type`, `encoding`, `size_bytes`, and lowercase SHA-256 `sha256`. Raster descriptors also include `shape` (`[rows, columns]`), `dtype`, `byte_order`, row order, no-data handling, and the exact geotransform. Vector shard descriptors include geometry types, coordinate dimensions/axis order, and stable feature IDs retained in the payload. Payload paths are unique within a bundle.

### Terrain

The terrain record preserves its source-native height values and per-sample `source_mask`/`quality_mask`. If a verified EGM2008 grid is available, also preserve `N_EGM2008` and the converted ellipsoidal height `h = H_EGM2008 + N_EGM2008`. The layer's normalized placement surface uses `h` and declares `height_type: "ellipsoidal"` and `vertical_datum: "WGS84_ELLIPSOIDAL"`, with geoid grid identity, checksum, interpolation method and independent numerical validation in `vertical_conversion`.

Where only GEBCO nominal mean-sea-level height exists, retain its native height and Type Identifier. If an EGM2008 undulation is used to make a placement height, declare `source_vertical_datum: "MEAN_SEA_LEVEL"`, `approximate: true`, the method and a visible warning about heterogeneous shallow-water datums. Never label that conversion as surveyed ellipsoidal truth. If one tile's source mosaic has more than one vertical datum, declare `source_vertical_datum: "per_sample_source_mask"` and provide a `vertical_references_by_source_code` map in `vertical_conversion`, keyed by the exact `source_mask` values. Each entry identifies its source vertical datum, conversion method, approximation flag/warning, and corresponding geoid/conversion-mask code. Preserve `H`, `N`, `h`, source mask, quality mask and conversion mask as aligned arrays; the consumer validates their dimensions and code mappings before placement. A single-source tile may use a direct source-datum value. If the conversion grid is absent or invalid, emit the supported source-native layer with explicit unavailable vertical conversion or a visible geographic gap; the Godot provider must not silently invent or infer an ECEF height.

Raster sample coordinate semantics are explicit (pixel-center vs pixel-corner, grid origin, spacing/affine, row direction, coordinate axis order). Preserve native source spacing and avoid resampling unless the method, output transform and seam result are recorded. Same-source, same-datum, same-grid shared-edge samples must be exactly equal. Renderer and terrain collision use the same validated vertex positions and triangle topology.

### Roads, buildings and water

Vector geometries use WGS 84 longitude/latitude coordinates after a declared transformation, retain stable source IDs, feature-level source records and license data, and are clipped to the WFG-1 extent with deterministic half-open boundary ownership. Fragment identifiers must be stable when source geometry and clipping inputs are unchanged. Use bounded multiple shards for dense tiles; never truncate features to meet an arbitrary feature cap. Preserve bridges, tunnels, road class, and other source attributes when available. Do not invent a surveyed road width, elevation, building height, or water surface; any procedural rendering width/height is a disclosed style parameter and is kept separate from source facts.

### Land cover and vegetation

Land-cover rasters preserve original category codes, source no-data, native grid transform, source product/version and pixel counts. WorldCover classes are categorical classes, not continuous values. A derived vegetation-support layer retains its class mapping and exact relationship to its source pixels. It does not represent observed individual tree locations. Procedural plant/clump placement, mesh density, jitter or exclusions are separate derived metadata and must be reproducible, bounded per WFG-1 tile, and clearly labelled synthetic. Where a water, road, or building exclusion mask was not used, say so rather than implying such exclusions.

## 6. Provenance and rights

Each source lineage record identifies, when available: provider; dataset/product and release; source feature or asset ID; source URI; retrieval time or immutable snapshot; source-object size, ETag and checksum; original CRS/datum/realization/epoch and units; source quality/uncertainty; license/terms URL; attribution; and any conversion/clip operation. Preserve feature-level source attribution records from Overture. Keep ODbL-derived data separable and retain obligations. Preserve the ESA WorldCover CC BY 4.0 attribution and the Copernicus/GEBCO source notices. Do not package restricted sources or publish local prompt data, credentials, or raw datasets whose redistribution terms are not satisfied.

## 7. Runtime validation and compatibility

The Godot provider validates the exact schema ID/version before decoding; canonical address ID, numeric bounds and tile origin must agree with the requested WFG-1 extent. It checks every required layer status, spatial reference, payload size/path/hash, raster dimensions, supported encoding, and vertical conversion record. It rejects unknown status/CRS/datum, malformed or unbounded payloads, contradictory metadata, unlisted paths in strict mode, and unsupported future major versions. A provider may skip an optional layer only when the layer status explicitly says why.

The provider maps canonical `layers` into its internal `layer_outcomes`, `layer_spatial_references`, and decoded layer objects without dropping provenance or changing status. `source_id` and `source_generation` must match the request; `lod` must match the requested representation. The logical address stays fixed across source or LOD replacement.

Minor versions may add optional fields. Breaking field meaning, payload semantics or required fields requires a new major schema ID. Producers and consumers publish exact schema versions and commits in their test evidence. A producer output from a regional contract must be adapted explicitly; guessing or silently coercing fields is invalid.

## 8. Required acceptance evidence

Before this contract is approved for integration, producer and consumer evidence must include:

1. A schema-valid, genuine source-derived tile containing terrain plus actual geographic feature output, with payload hashes verified from a fresh cache/bundle directory.
2. Independent spot checks of selected terrain values, geographic coordinates, source masks and feature IDs against the authoritative producer inputs.
3. Address/bounds and payload tampering rejection; explicit empty-vector, partial, gap, fallback, failed and cancelled outcomes.
4. The same real tile loaded and displayed by the pinned Windows Godot build; terrain collision readiness uses matching validated mesh geometry.
5. At least geographically separated land, ocean/coast, high-latitude and antimeridian/polar test addresses through the actual acquisition and runtime path, with unsupported source coverage visible.
6. Repeated load, unload, cancellation, source/LOD replacement and rebase using real decoded data, not synthetic-provider-only evidence.

The schema and unit fixtures prove contract behavior only. They do not by themselves prove global data coverage, completed LOD behavior, visual correctness, source accuracy, or the full-world exit criteria.
