# Planetary spatial and LOD design

**Status:** Pre-production design proposal, bounded by the source data and tests below. It does not claim a production global CRS bridge, tile index, origin manager or worldwide LOD policy.
**Scope:** WF-EXIT-05 and the geography-related constraints for WF-EXIT-06. This document records Main Lead design decisions and measured prototype limits; it is not a performance plan.

## 1. Coordinate and datum decisions

### ADR-GEO-01 — Preserve each source frame as data

Every terrain or feature coordinate remains attached to an immutable, versioned spatial-reference record that specifies CRS, axes, units, horizontal datum, realization/epoch status, vertical reference, source identity and the operation used to derive any other frame. A bare local Vector3, longitude/latitude pair, or projected easting/northing is not a durable world position.

The current USGS terrain contract preserves EPSG:4269 longitude/latitude, NAD83 on GRS80 with unspecified realization and epoch, NAVD88 orthometric height, and an anchor-centered AEQD regional frame. Godot mesh up uses only the regional expression H−H0. These per-region charts are not interchangeable global coordinates. No terrain operation silently converts NAVD88 to ellipsoidal height or uses GEOID18 without the required input realization and epoch.

### ADR-GEO-02 — Gate global placement on a verified operation

The separate EPSG:4979/EPSG:4978 WGS 84 geodetic/ECEF utility is a tested equation and reference-vector fixture, not the USGS terrain path. The world-state proposal stores positions with a spatial-reference ID and operation-record references. Production may convert a source position to an Earth-centered frame only after the source realization/epoch and a compatible horizontal and vertical operation are identified and independently tested. Until then, a conversion request must report unavailable rather than guess.

This avoids selecting an unjustified realization for the two USGS products. A production frame registry must support multiple named realizations and coordinate epochs; this prototype does not choose one canonical production realization.

### ADR-GEO-03 — Separate durable positions from render origins

Global positions remain double-precision, frame-tagged records. A Godot runtime receives a nearby origin-relative local transform and an origin generation. Rebasing subtracts the selected origin and updates runtime bindings without changing the durable world position or object ID. The current tests validate WGS 84 numeric conversion and two-origin subtract/add reconstruction only. They do not implement an engine-wide origin manager or convert the regional NAVD83/NAVD88 terrain to ECEF.

## 2. Tile identity, seams, LOD and collision

### ADR-LOD-01 — Tile identity is independent of content and LOD

A world tile key must be stable across LOD, asset revisions and runtime node creation. A tile content revision and a frame/source identity are separate fields. Current source windows remain explicitly cataloged; the adjacent Golden pair shares one source-sample column in the same frame and retains one source identity. The world-state stream-binding contract keeps object ID, tile membership, content revision, request generation and Godot resource handles separate.

No world-wide tile address is selected yet. Production must choose a wrap-safe scheme that defines antimeridian and polar behavior, neighbor identity, coverage gaps and revision updates after surveying intended source products. The local two-window catalog is not a global index.

### ADR-LOD-02 — Preserve exact seams for source-sample LOD

LOD0 uses the full source sample set and the corresponding source-sampled collision. The Golden LOD1 prototype takes every other row and column, preserves the outermost row/column and the shared boundary sample, and changes both neighbors together. Shared XY and height bytes are equal before mesh construction; the measured installed shared-vertex delta is exactly 0 m.

The observed maximum omitted-sample deviation is 13.497314453 m for this Golden crop, measured against its coarse triangles. It is not a source-accuracy estimate or a permissible ground-contact error. LOD1 collision is disabled on the shapes and physics layers, and tests verify it cannot be hit. LOD0 remains the only contact-eligible level in this prototype. A production selector must use source-supported geometric error and scenario-specific contact requirements, not this crop's observed number as a global threshold.

### ADR-LOD-03 — Keep coordinate fidelity separate from source accuracy

For the two bounded AEQD crops, Main Lead's horizontal projection checks use crop-specific curvature bounds plus an independent numerical allowance: 0.00103 m for Baltimore and 0.0011 m for Golden. The independent GRS80 sample checks fall below those limits. They test the coordinate operation and numeric implementation only. USGS does not provide a tile-specific accuracy bound in these source records, so no terrain elevation/source accuracy number is inferred from those projection or floating-point results.

## 3. Evidence mapped to the design

- **Separated real regions:** Baltimore and Golden use the same producer/consumer code and different anchors/source products. Their charts remain region-local. Their sampled GRS80 checks are recorded in the generator and vertical-slice evidence.
- **Global coordinate edge cases:** independent WGS 84 vectors and inverse tests cover the equator, antimeridian, both poles, high and southern latitudes, negative height, large ECEF radius, bounds and singularity rejection. The two-origin reconstruction maximum is 0.000000000276 m against a 1 mm arithmetic threshold. These are synthetic WGS 84 calculation fixtures, not transformed USGS terrain points.
- **Tile seam and LOD:** Golden west/east outputs share source column 8430 with byte-identical XY and Float32 height. Godot tests exercise atomic install/unload, seam ownership, LOD0→LOD1→LOD0, exact boundary samples, disabled coarse collision and LOD0 contact rays. Engineering reports 232/232 full and 137/137 adjacent checks on the current local integration; the exact combined head still needs independent QA.
- **Source/frame limits:** Terrain Grid v1 and the parent catalog reject implicit frame conversion. Source identities, acquisition basis and payload hashes are pinned; the current local Gate E branch regenerates all four manifests at generator 325cd2c and updates the catalog to that producer and recorded receipt.

## 4. Unresolved production work

1. Establish the supported Earth reference-frame registry, realization/epoch policy and vertical datum operations for each chosen global dataset. Validate every operation with independent geodetic references and uncertainty bounds before global placement.
2. Select a coverage-aware, wrap-safe global tile index after source coverage and rights are known. Define cell neighbors at the antimeridian and poles, stable tile keys, content revisions, cache invalidation and multi-neighbor ownership.
3. Implement an origin-rebase service in the actual Godot runtime and test repeated long-distance travel, precision, stale asynchronous completions, physics readiness and resource release.
4. Replace the crop-specific two-level demonstration with a production LOD policy grounded in provider resolution/error data. Test seams across multiple neighbors and regions. Do not enable coarse collision unless its measured scenario-specific error supports contact.
5. Establish source accuracy and vertical uncertainty separately from transform precision. If a source lacks a defensible accuracy bound, retain that as a data suitability limit and do not claim ground fidelity.

The roadmap prioritizes these packages after the pre-production evidence and review gates. No performance target, full-Earth dataset, final gameplay feature, or production release-rights claim is part of this design decision.
