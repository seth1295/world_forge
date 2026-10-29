# Global position utility boundary (v1)

**Status:** Implemented as a separate bounded utility for the Gate B Godot consumer. This note defines its current numeric interface; it does not connect regional terrain frames to a planetary frame.

## Regional terrain remains local

Terrain Grid v1 keeps the source horizontal identity as NAD83 geographic coordinates (`EPSG:4269`, longitude/latitude order) projected into a site-specific GRS80 ellipsoidal azimuthal-equidistant frame. Its payload positions are local Easting/Northing metres. Source heights remain NAVD88 orthometric metres, and the viewer computes local up as `H - H0`; Godot uses `(E, H-H0, -N)`.

Baltimore and Golden have distinct frame IDs and cannot be combined as if they shared a global origin. The consumer rejects an unapproved frame or artifact. It does not pass DEM heights to a WGS 84 ellipsoid conversion, and it performs no NAD83-to-WGS 84 transformation, no NAD83 realization/epoch transformation, and no NAVD88-to-ellipsoidal-height/geoid conversion. The 3DEP source is not the basis for any implied global bridge.

## Separate WGS 84 geodetic/ECEF utility

`integration/terrain/geodetic_ecef_wgs84_v1.gd` converts explicitly named WGS 84 geographic latitude, longitude, and **ellipsoidal height** to geocentric X/Y/Z metres and back. Its coordinate labels are `EPSG:4979` and `EPSG:4978`, respectively. The implementation uses the WGS 84 ellipsoid semi-major axis `a = 6,378,137.0 m` and inverse flattening `1/f = 298.257223563` published by the NGA Office of Geomatics ([WGS 84 definition and parameters](https://earth-info.nga.mil/index.php?action=wgs84&dir=wgs84)).

The API enforces these declared numeric input limits:

- Latitude: `[-90, 90]` degrees.
- Longitude: `[-180, 180]` degrees.
- Ellipsoidal height: `[-12,000, 100,000,000]` metres.
- Inverse ECEF radius: from `b - 12,000 m` through `a + 100,000,000 m`, where `b = a(1-f)`; the geocentric origin is rejected. At either pole the returned longitude is zero because longitude is indeterminate on the axis.

These bounds limit the API domain. They are not accuracy budgets, a data-coverage claim, or a claim that any project datum or height can be converted by this function. Callers must supply WGS 84 ellipsoidal height already; the function only evaluates the ellipsoid geometry and does not model a WGS 84 realization or epoch. It is not called by the terrain viewer.

## Independent reference vectors

The hard-coded test vectors were independently generated with `rasterio.warp.transform` from Rasterio 1.5.2, GDAL 3.12.2, and PROJ 9.7.1 using `EPSG:4979` to `EPSG:4978`. Inputs are longitude, latitude, and ellipsoidal height in metres, as accepted by Rasterio's `transform` API. The WGS 84 CRS and ellipsoid parameters are the NGA values above. The consumer test suite stores the returned XYZ values and does not depend on Rasterio at runtime.

| Latitude, longitude, ellipsoidal height (m) | Independent ECEF X, Y, Z (m) |
|---|---|
| `0, 0, 0` | `6378137, 0, 0` |
| `0, 180, 0` | `-6378137, 7.81e-10, 0` |
| `90, 0, 0` | `3.92e-10, 0, 6356752.314245179296` |
| `-90, 0, 0` | `3.92e-10, 0, -6356752.314245179296` |
| `45, 45, 0` | `3194419.145060574636, 3194419.145060574636, 4487348.408865920268` |
| `80, -179.5, 1200` | `-1111330.930935343495, -9698.438106053656, 6260724.730332305655` |
| `-60, 170, -4000` | `-3146563.768887572456, 554824.088974593556, -5497013.032323501073` |
| `0, 0, 100000000` | `106378137, 0, 0` |

Reproduce those references in a Python environment with the stated Rasterio/GDAL/PROJ versions:

```python
from rasterio.warp import transform

latitude, longitude, height_m = 80.0, -179.5, 1200.0
x, y, z = transform(
    "EPSG:4979", "EPSG:4978",
    [longitude], [latitude], [height_m],
)
print(x[0], y[0], z[0])
```

The tests also subtract each of two ECEF origins (nominal Baltimore-area and Golden-area WGS 84 test points) from Baltimore-area, Golden-area, and high-latitude test points, then add the selected origin back. The Baltimore/Golden numeric test inputs are explicitly treated as synthetic WGS 84 values for this arithmetic check; they are not read from or transformed out of the NAD83 manifests. ECEF reconstruction has a **1 mm maximum numerical error** criterion at Earth-radius magnitudes; the observed maximum was `0.000000000276 m`. Geodetic round trips are then checked against the original WGS 84 test coordinates. This observed value is numerical representation error only. This is a floating-point representation check for a possible future rebase design, not a source/geographic accuracy target and not an engine-wide origin manager.

## Verification scope

The Godot tests compare forward XYZ against the independent fixed references, check inverse results, cover the equator, antimeridian, both poles, high and southern latitudes, negative height, the configured height bound, and reject out-of-range inputs and the center singularity. The fixed-reference checks allow 0.1 mm for ECEF/height and `1e-9` degrees for latitude/longitude round trips. The origin reconstruction check allows 1 mm. These verify numerical conversion/reconstruction only; they do not estimate real-world datum or terrain error.

The regional consumer separately tests its NAD83/GRS80 and NAVD88 fields, projected sample bounds, source anchor and payload hashes. The current viewer demonstrates loading, site switching, collision, stale-result rejection and unload. It does not demonstrate adjacent-tile continuity or LOD transitions. Production world placement will require a separately specified and independently validated horizontal realization and vertical/geoid operation before any cross-frame conversion is introduced.