# Prototype Geographic Data Policy

**Owner:** WorldForge Main Lead  
**Status:** Adopted for pre-production elevation experiments  
**Scope:** Two or more United States demonstrator regions; this policy does not clear worldwide production data.

## Approved source and fallback

Use the USGS 3D Elevation Program (3DEP) bare-earth seamless digital elevation model (DEM) as the prototype terrain source. Prefer the 1/3 arc-second product for the selected regions. If it is unavailable for a required tile, the 1 arc-second seamless product from the same 3DEP program is an approved fallback. The USGS describes 1/3 arc-second coverage across the conterminous United States and 1 arc-second coverage across the conterminous United States, and identifies 3DEP products as public domain and available without use restrictions ([3DEP products and services](https://www.usgs.gov/3d-elevation-program/about-3dep-products-services), [USGS elevation product coverage and reference systems](https://www.usgs.gov/faqs/what-projection-horizontal-datum-vertical-datum-and-resolution-a-usgs-digital-elevation-model)).

Acquire raster files and their source metadata through The National Map download service/API or USGS's direct staged product links. If one delivery path is unavailable, try the other official USGS path for the same identified product. Do not substitute an unverified mirror. If neither resolution is available, another source may be selected only after its provider, version, region coverage, CRS/datum, units, uncertainty, acquisition method, prototype-use terms, attribution and redistribution terms are recorded and independently checked. Do not use synthetic terrain as a replacement for real source data.

The inherited generator's Mapterhorn/Copernicus/AWS terrain path is not the selected source for this pilot. Reuse its parsing or sampling code only after tracing its inputs, transformations and output semantics against the actual USGS tile; a visually plausible result or shared tile shape does not establish source or datum equivalence.

## Required provenance for every acquired region

Preserve a local immutable source snapshot for each experiment and record:

- provider and program, product/resolution, source page or download URL, acquisition date, file size and SHA-256;
- original source metadata and tile footprint, including any source lineage/collection date available;
- horizontal CRS/datum and axis order, vertical datum, units, no-data convention and grid spacing;
- region coordinates and any crop/resampling/reprojection performed by the generator;
- source accuracy or uncertainty statement and its geographic scope;
- applicable public-domain/usage statement and attribution, even where not legally required.

3DEP products are updated as new source data arrive, so a product name alone is not a reproducible version. The acquired file hash and its archived metadata define the exact prototype input. Do not commit downloaded rasters to the public repositories unless the repository change explicitly intends to redistribute the files and preserves the provenance record.

## Coordinate and elevation handling

Do not infer CRS or vertical datum from a filename. Read and retain the downloaded file's metadata. USGS documents 1/3-, 1-, and 2-arc-second DEMs as geographic latitude/longitude data horizontally referenced to NAD83; vertical reference is typically NAVD88 but can vary by area. For the conterminous United States, common seamless DEM products use NAVD88 elevations in metres. Verify the exact tile metadata before applying those assumptions ([USGS datum and resolution FAQ](https://www.usgs.gov/faqs/what-projection-horizontal-datum-vertical-datum-and-resolution-a-usgs-digital-elevation-model)).

The 1/3 arc-second seamless DEM is approximately 10 m ground spacing north-south, with east-west spacing varying by latitude. USGS reports approximately 0.82 m RMSE for that seamless product across the conterminous United States based on nearly 25,000 NOAA NGS OPUS control points; local accuracy varies with source, relief and land cover. Treat this as collection-level context, not a per-tile guarantee, survey accuracy claim or WorldForge transform tolerance ([USGS 3DEP DEM accuracy FAQ](https://www.usgs.gov/faqs/what-vertical-accuracy-3d-elevation-program-3dep-dems)).

Keep source elevation semantics distinct from ellipsoidal height and engine-local height. In particular, passing a NAVD88 orthometric DEM value as the ellipsoidal height argument of a geodetic-to-ECEF conversion is not an approved conversion. Any transformation, resampling or local-frame conversion must declare its input/output CRS, vertical datum, units, axis order and numerical error, and must be checked against an independent reference. No single planet-wide error threshold is adopted by this policy.

## Rights and release boundary

USGS identifies 3DEP products as public domain and without use restrictions. Retain source/provider attribution and metadata for reproducibility. This policy permits local prototype use and a later specifically documented public-domain data inclusion, but does not clear third-party software used to acquire/process data, nor any non-USGS imagery, roads, structures or other features. Production global coverage, coverage outside the selected demonstrators and any non-USGS source require separate provenance and rights review.

## Data quality and test limits

The two demonstrator regions must be geographically separated and each must use a real downloaded DEM source. Record tile edges and source uncertainty before setting terrain seam and reference-point tolerances. Derive precision/transform tolerances from the exact input grid, datum pipeline, independent reference coordinates and intended ground-scale scenario; document the calculation and independent QA result before treating it as an acceptance threshold. Performance and efficiency measures are outside this mission.
