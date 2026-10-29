class_name TerrainSiteCatalogV1
extends RefCounted

const PRODUCER_NAME := "WorldForge Terrain Grid Producer"
const PRODUCER_VERSION := "1.0.0"
const PRODUCER_COMMIT := "635c250cc251d72724edeb4d338240f1344a8c91"

# Each site owns one source-raster identity and one regional frame. Its keyed windows
# can grow to adjacent source windows while reusing those identities; each window has
# its own direct-child bundle directory, source window, dimensions, artifact, and camera.
const SITES := {
    "baltimore": {
        "site_id": "baltimore",
        "display_name": "Baltimore, Maryland",
        "region_id": "wf-vs01:baltimore",
        "frame_id": "wf-vs01:baltimore-grs80-aeqd",
        "frame_definition_sha256": "4edb7c5ddcb889c8617622c43a31faecbd0ecc567acfd70f721af4ee86456e54",
        "producer": {
            "commit": "635c250cc251d72724edeb4d338240f1344a8c91",
            "name": "WorldForge Terrain Grid Producer",
            "version": "1.0.0",
        },
        "source": {
            "acquired_at_utc": "2026-10-29T13:34:02Z",
            "acquisition_time_basis": "filesystem_creation_time",
            "dataset": "3D Elevation Program (3DEP), 1/3 arc-second bare-earth elevation",
            "metadata": {
                "byte_length": 12960,
                "sha256": "f8e8fda7359a2d8d66cdd6cd328482c622eb0ed32275c02e29465c3a00a8ec7e",
                "uri": "https://thor-f5.er.usgs.gov/ngtoc/metadata/waf/elevation/1-3_arc-second/MD_4County_D24/USGS_13_n40w077_20260512.xml",
            },
            "product_date": "2026-05-12",
            "product_id": "USGS 1/3 Arc Second n40w077 20260512",
            "product_record": {
                "byte_length": 2705,
                "sha256": "d87ee62c21834147f197828aa5319f4965c79a63506f2deb8914a9370c0e1af3",
                "uri": "https://www.sciencebase.gov/catalog/item/6a03dd85b66b01cc610dd98b",
            },
            "product_title": "USGS 1/3 Arc Second n40w077 20260512",
            "provider": "U.S. Geological Survey (USGS)",
            "raster": {
                "affine": {
                    "pixel_height": -9.259259269220167e-05,
                    "pixel_width": 9.259259269220298e-05,
                    "rotation_x": 0.0,
                    "rotation_y": 0.0,
                    "x_origin": -77.00055555599346,
                    "y_origin": 40.00055555639471,
                },
                "band": 1,
                "byte_length": 457416349,
                "dtype": "float32",
                "ellipsoid": "GRS80",
                "height": 10812,
                "horizontal_crs": "EPSG:4269",
                "horizontal_datum": "NAD83",
                "nodata_value": -999999.0,
                "offset": 0,
                "pixel_interpretation": "area",
                "realization_epoch": "unspecified_by_source_metadata",
                "scale": 1,
                "sha256": "628fd3bd2b2de7e36d37f7a28050db9f34bc73a7b9a8f77f54a488ec8ce757d0",
                "vertical_datum": "NAVD88",
                "vertical_height_type": "orthometric",
                "vertical_unit": "metre",
                "width": 10812,
            },
            "rights_statement": "USGS 3DEP source elevation data are public-domain U.S. Government data. Attribution: U.S. Geological Survey (USGS), USGS 1/3 Arc Second n40w077 20260512. This statement applies only to the identified source product and does not clear other datasets or assets.",
            "snapshot_verified_date": "2026-10-29",
            "source_uri": "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/historical/n40w077/USGS_13_n40w077_20260512.tif",
            "uncertainty_statement": "The source XML disclaims an accuracy warranty and gives no tile-specific accuracy bound. The product is a 1/3 arc-second DEM with NAVD88 orthometric metres; source product dates are not per-pixel survey dates. The source metadata does not identify a NAD83 realization or epoch.",
        },
        "anchor_row": 7674,
        "anchor_column": 4218,
        "anchor_longitude_deg": -76.60995370372139,
        "anchor_latitude_deg": 39.28995370377841,
        "anchor_height_navd88_m": 5.849248886108398,
        "default_window_id": "window-0",
        "windows": {
            "window-0": {
                "bundle_directory": "baltimore",
                "artifact_id": "517b4b97207ecde635ef5adb52303d4b3590ff3641254d18123406bfabd129f7",
                "rows": 216,
                "columns": 216,
                "source_window": {
                    "column_offset": 4110,
                    "columns": 216,
                    "row_offset": 7566,
                    "rows": 216,
                },
                "camera_position_local_m": Vector3(-503.20670857749536, 28.0, -699.0378389103332),
                "camera_target_local_m": Vector3(-846.6239912655444, 32.63882255554199, -1079.4178551042073),
            },
        },
    },
    "golden": {
        "site_id": "golden",
        "display_name": "Golden / Front Range, Colorado",
        "region_id": "wf-vs01:golden-front-range",
        "frame_id": "wf-vs01:golden-grs80-aeqd",
        "frame_definition_sha256": "3059daecf5eba37d0e4f2b12dc4468cf45d9d122b42db44cff7059357d0e94f7",
        "producer": {
            "commit": "635c250cc251d72724edeb4d338240f1344a8c91",
            "name": "WorldForge Terrain Grid Producer",
            "version": "1.0.0",
        },
        "source": {
            "acquired_at_utc": "2026-10-29T13:41:19Z",
            "acquisition_time_basis": "filesystem_creation_time",
            "dataset": "3D Elevation Program (3DEP), 1/3 arc-second bare-earth elevation",
            "metadata": {
                "byte_length": 12962,
                "sha256": "a43163a50c480a0ac50573a9fe4b9d50e6469ed317edf5399d4bf04ea2de28c7",
                "uri": "https://thor-f5.er.usgs.gov/ngtoc/metadata/waf/elevation/1-3_arc-second/UT_COUTAML_D24/USGS_13_n40w106_20260630.xml",
            },
            "product_date": "2026-07-01",
            "product_id": "USGS 1/3 Arc Second n40w106 20260630",
            "product_record": {
                "byte_length": 2707,
                "sha256": "9cbbb36df1333b8636521eefdab35b2e8040bff216ae774dd0e2627a5e92195f",
                "uri": "https://www.sciencebase.gov/catalog/item/6a471a0d1ba49bcdf785e0fa",
            },
            "product_title": "USGS 1/3 Arc Second n40w106 20260630",
            "provider": "U.S. Geological Survey (USGS)",
            "raster": {
                "affine": {
                    "pixel_height": -9.259259269220167e-05,
                    "pixel_width": 9.25925927753796e-05,
                    "rotation_x": 0.0,
                    "rotation_y": 0.0,
                    "x_origin": -106.00055555649311,
                    "y_origin": 40.000555556394715,
                },
                "band": 1,
                "byte_length": 413480184,
                "dtype": "float32",
                "ellipsoid": "GRS80",
                "height": 10812,
                "horizontal_crs": "EPSG:4269",
                "horizontal_datum": "NAD83",
                "nodata_value": -999999.0,
                "offset": 0,
                "pixel_interpretation": "area",
                "realization_epoch": "unspecified_by_source_metadata",
                "scale": 1,
                "sha256": "2a2ac1c4e0e571e5734bafff2b47f0b5cd864ddcb45b69085f0fbad86d44b4ba",
                "vertical_datum": "NAVD88",
                "vertical_height_type": "orthometric",
                "vertical_unit": "metre",
                "width": 10812,
            },
            "rights_statement": "USGS 3DEP source elevation data are public-domain U.S. Government data. Attribution: U.S. Geological Survey (USGS), USGS 1/3 Arc Second n40w106 20260630. This statement applies only to the identified source product and does not clear other datasets or assets.",
            "snapshot_verified_date": "2026-10-29",
            "source_uri": "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/historical/n40w106/USGS_13_n40w106_20260630.tif",
            "uncertainty_statement": "The source XML disclaims an accuracy warranty and gives no tile-specific accuracy bound. The product is a 1/3 arc-second DEM with NAVD88 orthometric metres; source product dates are not per-pixel survey dates. The source metadata does not identify a NAD83 realization or epoch.",
        },
        "anchor_row": 2652,
        "anchor_column": 8430,
        "anchor_longitude_deg": -105.21995370310027,
        "anchor_latitude_deg": 39.754953704278655,
        "anchor_height_navd88_m": 1729.523193359375,
        "default_window_id": "window-0",
        "windows": {
            "window-0": {
                "bundle_directory": "golden",
                "artifact_id": "d4b1bb11e84402136f50edf265a66991d8014326378edbeeaa67c4b169e31d98",
                "rows": 216,
                "columns": 432,
                "source_window": {
                    "column_offset": 8214,
                    "columns": 432,
                    "row_offset": 2544,
                    "rows": 216,
                },
                "camera_position_local_m": Vector3(-1198.3306255951975, 118.5, 904.5941632146123),
                "camera_target_local_m": Vector3(-1714.2119027677074, 364.36767578125, 1099.8264649481891),
            },
        },
    },
}

static func site_ids() -> Array[String]:
    return ["baltimore", "golden"]

static func window_ids(site_id: String) -> Array[String]:
    if not SITES.has(site_id):
        return []
    var windows: Dictionary = SITES[site_id].get("windows", {})
    var ids: Array[String] = []
    for window_id in windows.keys():
        ids.append(String(window_id))
    ids.sort()
    return ids

static func get_site(site_id: String) -> Dictionary:
    if not SITES.has(site_id):
        return {}
    return get_window(site_id, String(SITES[site_id].get("default_window_id", "")))

static func get_window(site_id: String, window_id: String) -> Dictionary:
    if not SITES.has(site_id):
        return {}
    return make_window_record(SITES[site_id], window_id)

static func make_window_record(site_definition: Dictionary, window_id: String) -> Dictionary:
    var windows_value: Variant = site_definition.get("windows", {})
    if typeof(windows_value) != TYPE_DICTIONARY:
        return {}
    var windows: Dictionary = windows_value
    if not windows.has(window_id) or typeof(windows[window_id]) != TYPE_DICTIONARY:
        return {}
    var record: Dictionary = site_definition.duplicate(true)
    var window: Dictionary = windows[window_id].duplicate(true)
    for key in window:
        record[key] = window[key]
    record["window_id"] = window_id
    return record

static func repository_root() -> String:
    var project_root := ProjectSettings.globalize_path("res://")
    while project_root.ends_with("/") or project_root.ends_with("\\"):
        project_root = project_root.substr(0, project_root.length() - 1)
    return project_root.get_base_dir().simplify_path()
