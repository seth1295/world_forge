class_name TerrainSiteCatalogV1
extends RefCounted

const PRODUCER_NAME := "WorldForge Terrain Grid Producer"
const PRODUCER_VERSION := "1.0.0"
const PRODUCER_COMMIT := "635c250cc251d72724edeb4d338240f1344a8c91"

const SITES := {
    "baltimore": {
        "site_id": "baltimore",
        "display_name": "Baltimore, Maryland",
        "bundle_directory": "baltimore",
        "region_id": "wf-vs01:baltimore",
        "frame_id": "wf-vs01:baltimore-grs80-aeqd",
        "artifact_id": "517b4b97207ecde635ef5adb52303d4b3590ff3641254d18123406bfabd129f7",
        "frame_definition_sha256": "4edb7c5ddcb889c8617622c43a31faecbd0ecc567acfd70f721af4ee86456e54",
        "rows": 216,
        "columns": 216,
        "producer": {"name": "WorldForge Terrain Grid Producer", "version": "1.0.0", "commit": "635c250cc251d72724edeb4d338240f1344a8c91"},
        "camera_position_local_m": Vector3(-503.20670857749536, 28.0, -699.0378389103332),
        "camera_target_local_m": Vector3(-846.6239912655444, 32.63882255554199, -1079.4178551042073),
        "source": {
            "provider": "U.S. Geological Survey (USGS)",
            "dataset": "3D Elevation Program (3DEP), 1/3 arc-second bare-earth elevation",
            "product_id": "USGS 1/3 Arc Second n40w077 20260512",
            "product_title": "USGS 1/3 Arc Second n40w077 20260512",
            "product_date": "2026-05-12",
            "source_uri": "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/historical/n40w077/USGS_13_n40w077_20260512.tif",
            "acquired_at_utc": "2026-10-29T13:34:02Z",
            "acquisition_time_basis": "filesystem_creation_time",
            "snapshot_verified_date": "2026-10-29",
            "rights_statement": "USGS 3DEP source elevation data are public-domain U.S. Government data. Attribution: U.S. Geological Survey (USGS), USGS 1/3 Arc Second n40w077 20260512. This statement applies only to the identified source product and does not clear other datasets or assets.",
            "uncertainty_statement": "The source XML disclaims an accuracy warranty and gives no tile-specific accuracy bound. The product is a 1/3 arc-second DEM with NAVD88 orthometric metres; source product dates are not per-pixel survey dates. The source metadata does not identify a NAD83 realization or epoch.",
            "raster": {
                "sha256": "628fd3bd2b2de7e36d37f7a28050db9f34bc73a7b9a8f77f54a488ec8ce757d0",
                "byte_length": 457416349,
                "width": 10812,
                "height": 10812
            },
            "metadata": {
                "uri": "https://thor-f5.er.usgs.gov/ngtoc/metadata/waf/elevation/1-3_arc-second/MD_4County_D24/USGS_13_n40w077_20260512.xml",
                "byte_length": 12960,
                "sha256": "f8e8fda7359a2d8d66cdd6cd328482c622eb0ed32275c02e29465c3a00a8ec7e"
            },
            "product_record": {
                "uri": "https://www.sciencebase.gov/catalog/item/6a03dd85b66b01cc610dd98b",
                "byte_length": 2705,
                "sha256": "d87ee62c21834147f197828aa5319f4965c79a63506f2deb8914a9370c0e1af3"
            }
        },
        "anchor_row": 7674,
        "anchor_column": 4218,
        "anchor_longitude_deg": -76.60995370372139,
        "anchor_latitude_deg": 39.28995370377841,
        "anchor_height_navd88_m": 5.849248886108398
    },
    "golden": {
        "site_id": "golden",
        "display_name": "Golden / Front Range, Colorado",
        "bundle_directory": "golden",
        "region_id": "wf-vs01:golden-front-range",
        "frame_id": "wf-vs01:golden-grs80-aeqd",
        "artifact_id": "d4b1bb11e84402136f50edf265a66991d8014326378edbeeaa67c4b169e31d98",
        "frame_definition_sha256": "3059daecf5eba37d0e4f2b12dc4468cf45d9d122b42db44cff7059357d0e94f7",
        "rows": 216,
        "columns": 432,
        "producer": {"name": "WorldForge Terrain Grid Producer", "version": "1.0.0", "commit": "635c250cc251d72724edeb4d338240f1344a8c91"},
        "camera_position_local_m": Vector3(-1198.3306255951975, 118.5, 904.5941632146123),
        "camera_target_local_m": Vector3(-1714.2119027677074, 364.36767578125, 1099.8264649481891),
        "source": {
            "provider": "U.S. Geological Survey (USGS)",
            "dataset": "3D Elevation Program (3DEP), 1/3 arc-second bare-earth elevation",
            "product_id": "USGS 1/3 Arc Second n40w106 20260630",
            "product_title": "USGS 1/3 Arc Second n40w106 20260630",
            "product_date": "2026-07-01",
            "source_uri": "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/historical/n40w106/USGS_13_n40w106_20260630.tif",
            "acquired_at_utc": "2026-10-29T13:41:19Z",
            "acquisition_time_basis": "filesystem_creation_time",
            "snapshot_verified_date": "2026-10-29",
            "rights_statement": "USGS 3DEP source elevation data are public-domain U.S. Government data. Attribution: U.S. Geological Survey (USGS), USGS 1/3 Arc Second n40w106 20260630. This statement applies only to the identified source product and does not clear other datasets or assets.",
            "uncertainty_statement": "The source XML disclaims an accuracy warranty and gives no tile-specific accuracy bound. The product is a 1/3 arc-second DEM with NAVD88 orthometric metres; source product dates are not per-pixel survey dates. The source metadata does not identify a NAD83 realization or epoch.",
            "raster": {
                "sha256": "2a2ac1c4e0e571e5734bafff2b47f0b5cd864ddcb45b69085f0fbad86d44b4ba",
                "byte_length": 413480184,
                "width": 10812,
                "height": 10812
            },
            "metadata": {
                "uri": "https://thor-f5.er.usgs.gov/ngtoc/metadata/waf/elevation/1-3_arc-second/UT_COUTAML_D24/USGS_13_n40w106_20260630.xml",
                "byte_length": 12962,
                "sha256": "a43163a50c480a0ac50573a9fe4b9d50e6469ed317edf5399d4bf04ea2de28c7"
            },
            "product_record": {
                "uri": "https://www.sciencebase.gov/catalog/item/6a471a0d1ba49bcdf785e0fa",
                "byte_length": 2707,
                "sha256": "9cbbb36df1333b8636521eefdab35b2e8040bff216ae774dd0e2627a5e92195f"
            }
        },
        "anchor_row": 2652,
        "anchor_column": 8430,
        "anchor_longitude_deg": -105.21995370310027,
        "anchor_latitude_deg": 39.754953704278655,
        "anchor_height_navd88_m": 1729.523193359375
    }
}

static func site_ids() -> Array[String]:
    return ["baltimore", "golden"]

static func get_site(site_id: String) -> Dictionary:
    if not SITES.has(site_id):
        return {}
    return SITES[site_id].duplicate(true)

static func repository_root() -> String:
    var project_root := ProjectSettings.globalize_path("res://")
    while project_root.ends_with("/") or project_root.ends_with("\\"):
        project_root = project_root.substr(0, project_root.length() - 1)
    return project_root.get_base_dir().simplify_path()