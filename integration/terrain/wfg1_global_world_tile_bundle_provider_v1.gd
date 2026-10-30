class_name Wfg1GlobalWorldTileBundleProviderV1
extends WorldTileProvider

const Address := preload("res://terrain/wfg1_tile_address.gd")
const LocalFrame := preload("res://terrain/wfg1_local_frame.gd")
const RasterTransform := preload("res://terrain/wfg1_raster_geotransform_v1.gd")
const StrictJson := preload("res://terrain/strict_json_v1.gd")
const TerrainDecoder := preload("res://terrain/wfg1_global_terrain_artifact_provider_v1.gd")
const TerrainGridHashV1 := preload("res://terrain/hash_v1.gd")
const SCHEMA_ID := "urn:worldforge:global-world-tile-bundle:1.0.0"
const SCHEMA_VERSION := "1.0.0"
const SOURCE_ID := "worldforge-global-world-v1"
const PROFILE_ID := "worldforge.global-world.v1.default"
const PINNED_GENERATOR_COMMIT := "6d4cf589a278b5e2eea668c25bc43469f4d45791"
const ASSEMBLER_ID := "WorldForge Global World Bundle Assembler"
const ASSEMBLER_VERSION := "0.1.0"
const GEOID_ID := "OSGeo-PROJ-data/us_nga_egm08_25.tif"
const MAX_MANIFEST_BYTES := 16 * 1024 * 1024
const MAX_TOTAL_BYTES := 4 * 1024 * 1024 * 1024
const MAX_PAYLOAD_BYTES := 1024 * 1024 * 1024
const MAX_VECTOR_LAYER_BYTES := 2 * 1024 * 1024 * 1024
const MAX_VECTOR_SHARD_BYTES := 16 * 1024 * 1024
const MAX_RASTER_SAMPLES := 10_000_000
const MAX_VECTOR_FEATURES := 2_000_000
const MAX_DECODED_GEOMETRY_BYTES := 4 * 1024 * 1024 * 1024
const MAX_DESCRIPTORS := 65_536
const MAX_PATH_CHARS := 1024
const CHUNK_BYTES := 4 * 1024 * 1024
const LAYERS := ["terrain", "roads", "buildings", "water", "landcover", "vegetation"]
const STATUSES := ["ready", "partial", "no_source_coverage", "not_generated", "failed", "cancelled"]
const WC_NAMES := {10:"tree_cover",20:"shrubland",30:"grassland",40:"cropland",60:"bare_sparse_vegetation",90:"herbaceous_wetland",95:"mangroves",100:"moss_lichen"}
const WC_EXCLUDED := [0,50,70,80]
var bundle_directory := ""

func configure_bundle_directory(path: String) -> Dictionary:
	var normalized := path.simplify_path()
	if not normalized.is_absolute_path() or not DirAccess.dir_exists_absolute(normalized):
		return _failure("bundle directory must be an existing absolute directory")
	bundle_directory = normalized
	return {"ok":true,"error":""}

func configure_bundle_root(path: String) -> Dictionary:
	return configure_bundle_directory(path)

func load_tile(request: Dictionary, cancellation: WorldTileCancellationToken) -> Dictionary:
	if bundle_directory.is_empty():
		return _failure("bundle provider is not configured")
	if cancellation == null or cancellation.is_cancelled():
		return {"ok":false,"status":"cancelled","error":"cancelled before bundle read"}
	if not _reject_reparse_points(bundle_directory):
		return _failure("bundle reparse-point check failed")
	var manifest_read := _read_bytes(bundle_directory.path_join("manifest.json"), MAX_MANIFEST_BYTES, false)
	if not manifest_read.get("ok", false):
		return _failure(String(manifest_read.get("error","manifest read failed")))
	var strict := StrictJson.new().parse_bytes(manifest_read["bytes"], MAX_MANIFEST_BYTES)
	if not strict.get("ok", false) or typeof(strict.get("value")) != TYPE_DICTIONARY:
		return _failure("bundle manifest is invalid JSON")
	var raw: Dictionary = strict["value"]
	var address_check := Address.validate_address(request.get("address", {}))
	if not address_check.get("ok", false):
		return _failure("request WFG-1 address is invalid")
	var address: Dictionary = address_check["address"]
	var address_id := Address.format_id(address)
	if String(request.get("address_id", address_id)) != address_id:
		return _failure("request address ID contradicts WFG-1 address")
	var identity_error := _validate_identity(raw, request, address, address_id)
	if not identity_error.is_empty():
		return _failure(identity_error)
	var provenance := _read_provenance(raw, address_id, cancellation)
	if not provenance.get("ok", false):
		return provenance
	var verified: Dictionary = {}
	var source_grid: Dictionary = provenance["terrain"].get("terrain", {}).get("grid", {})
	var payload_result := _verify_payloads(raw, address, cancellation, verified, source_grid)
	if not payload_result.get("ok", false):
		return payload_result
	var file_set_error := _check_file_set(verified)
	if not file_set_error.is_empty():
		return _failure(file_set_error)
	var decoded_result := _decode_layers(raw, provenance["terrain"], verified, address, cancellation, int(payload_result.get("boundary_geometry_bytes", 0)))
	if not decoded_result.get("ok", false):
		return decoded_result
	var normalized := _normalize_manifest(raw)
	var decoded: Dictionary = decoded_result["decoded"]
	decoded["raw_external_manifest"] = raw.duplicate(true)
	decoded["raw_terrain_manifest"] = provenance["terrain"].duplicate(true)
	decoded["raw_feature_manifest"] = provenance["features"].duplicate(true)
	decoded["raw_external_manifest_sha256"] = TerrainGridHashV1.sha256_bytes(manifest_read["bytes"])
	decoded["bundle_artifact_label"] = "REAL_GENERATOR_GLOBAL_WORLD_TILE_BUNDLE"
	return {"ok":true,"manifest":normalized,"decoded":decoded}

func _validate_identity(raw: Dictionary, request: Dictionary, address: Dictionary, address_id: String) -> String:
	if not _exact(raw, ["schema_id","schema_version","bundle_id","created_at_utc","source_id","source_generation","consumer_limit_profile_id","lod","address","tile_origin","producers","layers"]):
		return "bundle has missing or unknown top-level fields"
	if String(raw["schema_id"]) != SCHEMA_ID or String(raw["schema_version"]) != SCHEMA_VERSION or String(raw["consumer_limit_profile_id"]) != PROFILE_ID:
		return "bundle schema/profile is unsupported"
	if String(raw["source_id"]) != SOURCE_ID or String(raw["source_id"]) != String(request.get("source_id","")):
		return "bundle source ID differs from request"
	if String(raw["source_generation"]) != String(request.get("source_generation","")) or String(raw["bundle_id"]) != String(raw["source_generation"]) or not _sha(String(raw["bundle_id"])):
		return "bundle generation identity differs from request or is malformed"
	if not _int(raw.get("lod")) or int(raw["lod"]) != int(request.get("lod",-1)):
		return "bundle runtime LOD differs from request"
	var a: Variant = raw.get("address")
	if not _exact(a, ["scheme","address_id","level","x","y","tile_bounds","horizontal_crs","horizontal_datum","axis_order","edge_ownership"]):
		return "bundle address record is malformed"
	if String(a["scheme"]) != "WFG-1" or String(a["address_id"]) != address_id or String(a["horizontal_crs"]) != "EPSG:4326" or String(a["horizontal_datum"]) != "WGS84" or a["axis_order"] != ["longitude","latitude"] or String(a["edge_ownership"]) != "west_south_inclusive_east_north_exclusive_north_pole_exception":
		return "bundle WFG-1 address semantics are unsupported"
	for key in ["level","x","y"]:
		if not _int(a.get(key)) or int(a[key]) != int(address[key]):
			return "bundle numeric address differs from canonical address ID"
	var bounds: Variant = a.get("tile_bounds")
	var expected := Address.bounds_for_address(address)
	if not _exact(bounds, ["west_deg","south_deg","east_deg","north_deg"]) or not expected.get("ok",false):
		return "bundle WFG-1 bounds are malformed"
	for key in ["west_deg","south_deg","east_deg","north_deg"]:
		if not _finite(bounds.get(key)) or float(bounds[key]) != float(expected[key]):
			return "bundle bounds contradict WFG-1 address"
	var origin_error := _origin_error(raw.get("tile_origin"),address,bounds)
	if not origin_error.is_empty():
		return origin_error
	var producer_error := _producer_error(raw.get("producers"))
	if not producer_error.is_empty():
		return producer_error
	var layers: Variant = raw.get("layers")
	if typeof(layers) != TYPE_DICTIONARY or layers.size() != LAYERS.size():
		return "bundle must have exactly six layers"
	for id in LAYERS:
		if not layers.has(id):
			return "bundle is missing layer %s" % id
	return _generation_error(raw)

func _producer_error(value: Variant) -> String:
	if not _exact(value,["terrain","features","assembler"]):
		return "producer identities are malformed"
	var p: Dictionary = value
	var t: Variant = p["terrain"]
	var f: Variant = p["features"]
	var a: Variant = p["assembler"]
	if not _only(t,["id","version","commit","contract_id","artifact_id","manifest_path","manifest_size_bytes","manifest_sha256"]):
		return "terrain producer descriptor has unknown fields"
	if not _only(f,["id","version","commit","schema_id","schema_version","artifact_id","manifest_path","manifest_size_bytes","manifest_sha256","producer_metadata"]):
		return "feature producer descriptor has unknown fields"
	if not _exact(f.get("producer_metadata"), ["runtime_dependencies", "request", "bundle_outcome", "coverage_gaps", "rights_and_provenance", "consumer_notes"]):
		return "feature producer_metadata is missing declared raw producer context"
	if not _exact(a,["id","version","commit"]):
		return "assembler identity is malformed"
	if String(t["commit"]) != PINNED_GENERATOR_COMMIT or String(f["commit"]) != PINNED_GENERATOR_COMMIT:
		return "producer commits differ from pinned generator revision"
	if String(t["contract_id"]) != "urn:worldforge:contract:global-terrain-tile:1.0.0" or String(f["schema_id"]) != "urn:worldforge:global-feature-bundle:1.0.0" or String(f["schema_version"]) != "1.0.0":
		return "producer contract/schema is unsupported"
	if not _sha(String(t["artifact_id"])) or not _sha(String(f["artifact_id"])) or String(a["id"]) != ASSEMBLER_ID or String(a["version"]) != ASSEMBLER_VERSION or not _sha(String(a["commit"])):
		return "producer/assembler artifact identities are malformed"
	for producer in [t,f]:
		if not _path(String(producer["manifest_path"])) or not _int(producer["manifest_size_bytes"]) or int(producer["manifest_size_bytes"]) <= 0 or int(producer["manifest_size_bytes"]) > MAX_MANIFEST_BYTES or not _sha(String(producer["manifest_sha256"])):
			return "raw producer manifest descriptor exceeds finite integrity policy"
	return ""

func _generation_error(raw: Dictionary) -> String:
	var p: Dictionary = raw["producers"]
	var a: Dictionary = raw["address"]
	var values := ["WF-WORLD-GENERATION-1",String(raw["source_id"]),String(a["address_id"]),str(int(raw["lod"])),String(p["terrain"]["artifact_id"]),String(p["features"]["artifact_id"]),ASSEMBLER_ID,ASSEMBLER_VERSION,String(p["assembler"]["commit"])]
	var bytes := PackedByteArray()
	for i in range(values.size()):
		if i > 0: bytes.append(0)
		bytes.append_array(values[i].to_utf8_buffer())
	var digest := TerrainGridHashV1.sha256_bytes(bytes)
	if digest != String(raw["bundle_id"]) or digest != String(raw["source_generation"]):
		return "bundle digest does not match exact producer/address/LOD/assembler inputs"
	return ""

func _origin_error(value: Variant, address: Dictionary, bounds: Dictionary) -> String:
	if not _only(value,["horizontal_crs","horizontal_datum","vertical_datum","height_type","longitude_deg","latitude_deg","ellipsoidal_height_m","ecef_m"]):
		return "tile_origin is malformed"
	var o: Dictionary = value
	if String(o.get("horizontal_crs","")) not in ["EPSG:4979","EPSG:4326"] or String(o.get("horizontal_datum","")) != "WGS84" or String(o.get("vertical_datum","")) != LocalFrame.ELLIPSOIDAL_DATUM or String(o.get("height_type","")) != "ellipsoidal":
		return "tile_origin requires WGS84 ellipsoidal semantics"
	for key in ["longitude_deg","latitude_deg","ellipsoidal_height_m"]:
		if not _finite(o.get(key)): return "tile_origin is missing finite %s" % key
	var lon := (float(bounds["west_deg"])+float(bounds["east_deg"]))*0.5
	var lat := (float(bounds["south_deg"])+float(bounds["north_deg"]))*0.5
	if float(o["longitude_deg"]) != lon or float(o["latitude_deg"]) != lat or float(o["ellipsoidal_height_m"]) != 0.0:
		return "tile_origin must be the exact WFG-1 bounds center at h=0"
	if o.has("ecef_m"):
		var e: Variant = o["ecef_m"]
		if typeof(e) != TYPE_ARRAY or e.size()!=3: return "tile_origin ecef_m must contain three values"
		var c := LocalFrame.geodetic_to_ecef_components(lat,lon,0.0,LocalFrame.CRS_GEOGRAPHIC_2D,LocalFrame.ELLIPSOIDAL_DATUM,"ellipsoidal")
		if not c.get("ok",false): return "tile_origin cannot be converted to WGS84 ECEF"
		for i in range(3):
			if not _finite(e[i]) or absf(float(e[i])-float(c["ecef_m"][i])) > LocalFrame.FRAME_COMPONENT_CONSISTENCY_M:
				return "tile_origin ECEF contradicts its geodetic coordinates"
	return ""

func _read_provenance(raw: Dictionary, address_id: String, cancellation: WorldTileCancellationToken) -> Dictionary:
	var parsed: Dictionary = {}
	for name in ["terrain","features"]:
		if cancellation.is_cancelled(): return {"ok":false,"status":"cancelled","error":"cancelled while reading producer manifests"}
		var d: Dictionary = raw["producers"][name]
		var path_result := _resolve(String(d["manifest_path"]),String(d["manifest_sha256"]),int(d["manifest_size_bytes"]),MAX_MANIFEST_BYTES,cancellation)
		if not path_result.get("ok",false): return path_result
		var bytes := _read_bytes(String(path_result["path"]),MAX_MANIFEST_BYTES,false)
		if not bytes.get("ok",false): return _failure(String(bytes.get("error","raw manifest read failed")))
		var p := StrictJson.new().parse_bytes(bytes["bytes"],MAX_MANIFEST_BYTES)
		if not p.get("ok",false) or typeof(p.get("value")) != TYPE_DICTIONARY: return _failure("raw producer manifest is invalid JSON")
		var m: Dictionary = p["value"]
		if name=="terrain":
			if String(m.get("contract_id","")) != String(d["contract_id"]) or String(m.get("artifact_id","")) != String(d["artifact_id"]) or String(m.get("producer",{}).get("commit","")) != PINNED_GENERATOR_COMMIT or String(m.get("tile",{}).get("id","")) != address_id:
				return _failure("raw terrain manifest identity/address differs")
			var raw_bounds: Variant = m.get("tile", {}).get("bounds_wgs84")
			if typeof(raw_bounds) != TYPE_DICTIONARY:
				return _failure("raw terrain manifest WFG bounds are missing")
			var expected_bounds: Dictionary = raw["address"]["tile_bounds"]
			for key in ["west_deg", "south_deg", "east_deg", "north_deg"]:
				if not _finite(raw_bounds.get(key)) or float(raw_bounds[key]) != float(expected_bounds[key]):
					return _failure("raw terrain manifest bounds differ from canonical bundle address")
		else:
			if String(m.get("schema_id","")) != String(d["schema_id"]) or String(m.get("schema_version","")) != String(d["schema_version"]) or String(m.get("bundle_id","")) != String(d["artifact_id"]) or String(m.get("producer",{}).get("source_revision","")) != PINNED_GENERATOR_COMMIT or String(m.get("address",{}).get("tile_id","")) != address_id:
				return _failure("raw feature manifest identity/address differs")
			var source_bounds: Variant = m.get("address", {}).get("bounds_wgs84")
			var canonical_bounds: Dictionary = raw["address"]["tile_bounds"]
			if typeof(source_bounds) != TYPE_ARRAY or source_bounds.size() != 4:
				return _failure("raw feature manifest bounds must be [west,south,east,north]")
			for index in range(4):
				var bound_key: String = ["west_deg", "south_deg", "east_deg", "north_deg"][index]
				if not _finite(source_bounds[index]) or float(source_bounds[index]) != float(canonical_bounds[bound_key]):
					return _failure("raw feature manifest bounds differ from canonical bounds")
			var raw_context := {
				"runtime_dependencies": m["producer"].get("runtime_dependencies", []),
				"request": m.get("request", {}),
				"bundle_outcome": m.get("bundle_outcome", ""),
				"coverage_gaps": m.get("coverage_gaps", []),
				"rights_and_provenance": m.get("rights_and_provenance", {}),
				"consumer_notes": m.get("consumer_notes", [])
			}
			if raw_context != d.get("producer_metadata", {}):
				return _failure("canonical feature producer_metadata differs from byte-exact producer manifest fields")
		parsed[name]=m
	return {"ok":true,"error":"","terrain":parsed["terrain"],"features":parsed["features"]}

func _verify_payloads(raw: Dictionary, address: Dictionary, cancellation: WorldTileCancellationToken, verified: Dictionary, source_grid: Dictionary) -> Dictionary:
	var total := 0
	var geometry_bytes := 0
	var boundary_geometry_bytes := 0
	var descriptor_count := 0
	for layer_id in LAYERS:
		if cancellation.is_cancelled(): return {"ok":false,"status":"cancelled","error":"cancelled between layers"}
		var layer: Dictionary = raw["layers"][layer_id]
		var layer_error := _layer_error(layer_id,layer,raw["address"]["tile_bounds"])
		if not layer_error.is_empty(): return _failure(layer_error)
		var layer_bytes := 0
		var layer_count := 0
		for dval in layer["payloads"]:
			if typeof(dval) != TYPE_DICTIONARY: return _failure("payload descriptor must be an object")
			var d: Dictionary = dval
			var error := _payload_error(layer_id,d)
			if not error.is_empty(): return _failure(error)
			var relative := String(d["path"])
			if verified.has(relative): return _failure("duplicate bundle payload path")
			var vector := String(d["payload_kind"])=="vector_shard"
			var boundary := String(d["payload_kind"])=="terrain_boundary_support"
			var limit := MAX_VECTOR_SHARD_BYTES if vector or boundary else MAX_PAYLOAD_BYTES
			var resolved := _resolve(relative,String(d["sha256"]),int(d["size_bytes"]),limit,cancellation)
			if not resolved.get("ok",false): return resolved
			var size := int(d["size_bytes"])
			total += size
			layer_bytes += size
			descriptor_count += 1
			if layer_id in ["roads","buildings","water"] and layer_bytes>MAX_VECTOR_LAYER_BYTES: return _failure("vector layer exceeds 2 GiB serialized limit")
			if vector or boundary:
				geometry_bytes += size
				if geometry_bytes>MAX_DECODED_GEOMETRY_BYTES: return _failure("GeoJSON bytes exceed the 4 GiB finite geometry profile")
			if total>MAX_TOTAL_BYTES or descriptor_count>MAX_DESCRIPTORS: return _failure("bundle exceeds finite total size or descriptor count")
			verified[relative]={"absolute_path":String(resolved["path"]),"descriptor":d.duplicate(true)}
			if vector: layer_count += int(d["feature_count"])
			elif boundary:
				var features := _boundary(String(resolved["path"]),d,raw["address"]["tile_bounds"],address,layer["spatial_reference"],source_grid)
				if not features.get("ok",false): return features
				verified[relative]["boundary_features"]=features["features"]
				boundary_geometry_bytes += size + features["features"].size() * 192
				if boundary_geometry_bytes > MAX_DECODED_GEOMETRY_BYTES: return _failure("boundary support exceeds 4 GiB decoded geometry budget")
			else:
				layer_count += int(d["shape"][0])*int(d["shape"][1])
		if layer_id in ["roads","buildings","water"]:
			if layer.has("feature_count") and layer_count!=int(layer["feature_count"]): return _failure("vector layer count differs from payload descriptors")
			if layer_count>MAX_VECTOR_FEATURES: return _failure("vector layer exceeds 2M feature cap")
		elif layer_id in ["landcover","vegetation"]:
			var pixels := int(layer.get("pixel_count",0))
			if pixels==0:
				if not layer["payloads"].is_empty(): return _failure("ready zero-pixel raster must omit zero-byte payload descriptors")
			elif layer_count!=pixels: return _failure("raster pixel count differs from descriptor shapes")
	var bundle_size:=total
	for name in ["terrain","features"]: bundle_size+=int(raw["producers"][name]["manifest_size_bytes"])
	var manifest_bytes:=FileAccess.get_file_as_string(bundle_directory.path_join("manifest.json")).to_utf8_buffer()
	bundle_size+=manifest_bytes.size()
	if bundle_size>MAX_TOTAL_BYTES: return _failure("bundle exceeds the 4 GiB limit including manifests")
	return {"ok":true,"error":"","total_bytes":bundle_size,"boundary_geometry_bytes":boundary_geometry_bytes}

func _layer_error(id: String, value: Variant, bounds: Dictionary) -> String:
	var allowed:=["status","requested","payloads","coverage","spatial_reference","source_lineage","attribution","transform","producer_metadata","feature_count","pixel_count","sample_count","gap_declared","gap_reason","disclosure","fallback","error_code"]
	if not _only(value,allowed) or typeof(value)!=TYPE_DICTIONARY: return "layer %s is malformed or has unknown fields" % id
	var l:Dictionary=value
	if typeof(l.get("status"))!=TYPE_STRING or String(l["status"]) not in STATUSES or typeof(l.get("requested"))!=TYPE_BOOL or typeof(l.get("payloads"))!=TYPE_ARRAY: return "layer %s has invalid status/requested/payloads" % id
	var c:Variant=l.get("coverage")
	if typeof(c)!=TYPE_DICTIONARY or String(c.get("coverage_claim","")).is_empty() or String(c.get("coverage_confidence","")).is_empty(): return "layer %s needs coverage claim/confidence" % id
	if not _only(c,["coverage_claim","coverage_confidence","query_bounds_wgs84","complete_for_emitted_samples","source_coverage"]): return "layer %s coverage has unknown fields" % id
	if c.has("query_bounds_wgs84") and c["query_bounds_wgs84"]!=null:
		var q:Variant=c["query_bounds_wgs84"]
		if not _exact(q,["west_deg","south_deg","east_deg","north_deg"]): return "layer %s query bounds malformed" % id
		for k in ["west_deg","south_deg","east_deg","north_deg"]:
			if not _finite(q.get(k)): return "layer %s query bounds non-finite" % id
		if not (-180.0<=float(q["west_deg"]) and float(q["west_deg"])<float(q["east_deg"]) and float(q["east_deg"])<=180.0 and -90.0<=float(q["south_deg"]) and float(q["south_deg"])<float(q["north_deg"]) and float(q["north_deg"])<=90.0): return "layer %s query bounds invalid" % id
		if float(q["west_deg"])<float(bounds["west_deg"]) or float(q["east_deg"])>float(bounds["east_deg"]) or float(q["south_deg"])<float(bounds["south_deg"]) or float(q["north_deg"])>float(bounds["north_deg"]): return "layer %s query extent escapes tile" % id
	var status:=String(l["status"])
	if status=="ready":
		if id=="terrain" and (not _int(l.get("sample_count")) or int(l["sample_count"])<=0 or l["payloads"].is_empty()): return "ready terrain needs sample_count and raster payload"
		if id in ["roads","buildings","water"]:
			if not _int(l.get("feature_count")) or int(l["feature_count"])>MAX_VECTOR_FEATURES: return "ready vector layer needs bounded feature_count"
			if int(l["feature_count"])>0 and l["payloads"].is_empty(): return "ready nonempty vector layer lacks payload"
			if int(l["feature_count"])==0 and (not c.has("query_bounds_wgs84") or c["query_bounds_wgs84"]==null): return "ready empty vector query lacks bounds"
		if id in ["landcover","vegetation"]:
			if not _int(l.get("pixel_count")) or int(l["pixel_count"])<0 or int(l["pixel_count"])>MAX_RASTER_SAMPLES: return "ready raster layer needs bounded pixel_count"
			if int(l["pixel_count"])>0 and l["payloads"].is_empty(): return "ready nonempty raster has no payload"
			if int(l["pixel_count"])==0 and (not c.has("query_bounds_wgs84") or c["query_bounds_wgs84"]==null or String(l.get("disclosure","")).is_empty()): return "ready empty raster lacks bounds/disclosure"
	if status=="partial" and (not bool(l.get("gap_declared",false)) or String(l.get("gap_reason","")).is_empty() or String(l.get("disclosure","")).is_empty()): return "partial layer lacks gap/disclosure"
	if status=="no_source_coverage" and (not bool(l.get("gap_declared",false)) or String(l.get("gap_reason","")).is_empty()): return "no_source_coverage lacks gap"
	if status in ["not_generated","failed","cancelled"] and (String(l.get("error_code","")).is_empty() or not bool(l.get("gap_declared",false)) or String(l.get("gap_reason","")).is_empty()): return "unavailable layer lacks error/gap"
	if typeof(l.get("spatial_reference"))!=TYPE_DICTIONARY or typeof(l.get("source_lineage"))!=TYPE_ARRAY or typeof(l.get("attribution"))!=TYPE_ARRAY or typeof(l.get("transform"))!=TYPE_DICTIONARY or typeof(l.get("producer_metadata"))!=TYPE_DICTIONARY: return "layer lacks spatial/provenance/transform metadata"
	return _spatial_error(id,l["spatial_reference"])

func _spatial_error(id: String, value: Dictionary) -> String:
	if not _only(value,["horizontal_crs","horizontal_datum","axis_order","has_elevation","source_vertical_datum","height_type","vertical_datum","vertical_conversion","horizontal_realization","coordinate_epoch"]): return "layer %s spatial reference has unknown fields" % id
	if String(value.get("horizontal_crs",""))!="EPSG:4326" or String(value.get("horizontal_datum",""))!="WGS84" or value.get("axis_order")!=["longitude","latitude"] or typeof(value.get("has_elevation"))!=TYPE_BOOL: return "layer %s requires typed WGS84 lon/lat spatial reference" % id
	if not bool(value["has_elevation"]):
		if String(value.get("source_vertical_datum",""))!="not_applicable" or String(value.get("height_type",""))!="not_applicable" or String(value.get("vertical_datum",""))!="not_applicable": return "non-elevation layer %s requires not_applicable vertical fields" % id
		return ""
	if id!="terrain" or String(value.get("source_vertical_datum",""))!="per_sample_source_mask" or String(value.get("height_type",""))!="ellipsoidal" or String(value.get("vertical_datum",""))!=LocalFrame.ELLIPSOIDAL_DATUM: return "terrain must use per-sample WGS84 ellipsoidal placement semantics"
	var conversion:Variant=value.get("vertical_conversion")
	if typeof(conversion)!=TYPE_DICTIONARY or typeof(conversion.get("vertical_references_by_source_code"))!=TYPE_DICTIONARY: return "terrain vertical conversion map is missing"
	for key in conversion["vertical_references_by_source_code"]:
		var row:Variant=conversion["vertical_references_by_source_code"][key]
		if typeof(row)!=TYPE_DICTIONARY or not _int(row.get("geoid_mask_code")) or String(row.get("source_vertical_datum","")) not in ["EGM2008","MEAN_SEA_LEVEL"] or String(row.get("geoid_grid_id",""))!=GEOID_ID or not _sha(String(row.get("geoid_grid_sha256",""))) or String(row.get("interpolation_method","")).is_empty(): return "terrain source vertical map entry is invalid"
	return ""

func _payload_error(layer_id:String,d:Dictionary)->String:
	var kind:=String(d.get("payload_kind",""))
	var allowed:=["payload_kind","path","media_type","encoding","size_bytes","sha256","producer_descriptor"]
	match kind:
		"raster_grid": allowed.append_array(["shape","dtype","byte_order","row_order","no_data_value","geotransform"])
		"vector_shard": allowed.append_array(["feature_count","geometry_types","coordinate_dimensions"])
		"terrain_boundary_support": allowed.append_array(["feature_count","geometry_types","coordinate_dimensions","boundary_support_edges"])
		_: return "unknown payload_kind"
	if not _only(d,allowed) or not _path(String(d.get("path",""))) or not _int(d.get("size_bytes")) or int(d["size_bytes"])<1 or int(d["size_bytes"])>MAX_PAYLOAD_BYTES or not _sha(String(d.get("sha256",""))) or typeof(d.get("media_type"))!=TYPE_STRING or typeof(d.get("encoding"))!=TYPE_STRING: return "payload descriptor fields are invalid"
	if layer_id in ["roads","buildings","water"] and kind!="vector_shard": return "vector layer has non-vector payload"
	if layer_id in ["landcover","vegetation"] and kind!="raster_grid": return "raster layer has non-raster payload"
	if layer_id=="terrain" and kind not in ["raster_grid","terrain_boundary_support"]: return "terrain has unsupported payload"
	if kind=="raster_grid":
		if String(d["media_type"])!="application/octet-stream": return "raster media_type must be application/octet-stream"
		var sh:Variant=d.get("shape")
		if typeof(sh)!=TYPE_ARRAY or sh.size()!=2 or not _int(sh[0]) or not _int(sh[1]): return "raster shape must be integer [rows,columns]"
		var r:=int(sh[0]); var c:=int(sh[1])
		if r<1 or c<1 or r>10_000 or c>10_000 or r>MAX_RASTER_SAMPLES/c: return "raster shape exceeds profile"
		if typeof(d.get("dtype"))!=TYPE_STRING or String(d.get("dtype","")).is_empty() or String(d.get("byte_order","")) not in ["little","big","not_applicable"] or String(d.get("row_order",""))!="row_major_north_to_south_west_to_east" or not d.has("no_data_value"): return "raster descriptor lacks typed order/no-data fields"
		if not RasterTransform.validate_transform(d.get("geotransform"),r,c).get("ok",false): return "raster descriptor geotransform is invalid"
	if kind=="vector_shard":
		if String(d.get("media_type",""))!="application/geo+json" or not _int(d.get("feature_count")) or int(d["feature_count"])>MAX_VECTOR_FEATURES or int(d.get("coordinate_dimensions",0))!=2 or typeof(d.get("geometry_types"))!=TYPE_ARRAY: return "vector descriptor must be bounded 2D GeoJSON"
	if kind=="terrain_boundary_support":
		if layer_id!="terrain" or String(d.get("media_type",""))!="application/geo+json" or String(d.get("encoding",""))!="geojson" or not _int(d.get("feature_count")) or int(d["feature_count"])<1 or int(d.get("coordinate_dimensions",0))!=3 or d.get("geometry_types")!=["Point"] or typeof(d.get("boundary_support_edges"))!=TYPE_ARRAY: return "boundary support descriptor must declare 3D Points/edges"
	return ""

func _boundary(path:String,d:Dictionary,bounds:Dictionary,address:Dictionary,spatial:Dictionary,source_grid:Dictionary)->Dictionary:
	var read:=_read_bytes(path,MAX_VECTOR_SHARD_BYTES,false)
	if not read.get("ok",false): return _failure(String(read.get("error","boundary read failed")))
	var parsed:=StrictJson.new().parse_bytes(read["bytes"],MAX_VECTOR_SHARD_BYTES)
	if not parsed.get("ok",false) or typeof(parsed.get("value"))!=TYPE_DICTIONARY: return _failure("boundary GeoJSON invalid")
	var collection:Dictionary=parsed["value"]
	var items:Variant=collection.get("features")
	if String(collection.get("type",""))!="FeatureCollection" or typeof(items)!=TYPE_ARRAY or items.size()!=int(d["feature_count"]) or items.size()>40_000: return _failure("boundary FeatureCollection/count invalid")
	var vertical:Dictionary=spatial.get("vertical_conversion",{}).get("vertical_references_by_source_code",{})
	var groups:Dictionary={}
	var ids:Dictionary={}
	var result:Array[Dictionary]=[]
	for item in items:
		if typeof(item)!=TYPE_DICTIONARY: return _failure("boundary feature is not an object")
		var f:Dictionary=item
		var props:Variant=f.get("properties")
		var wf:Variant=props.get("worldforge") if typeof(props)==TYPE_DICTIONARY else null
		var support:Variant=wf.get("boundary_support") if typeof(wf)==TYPE_DICTIONARY else null
		var geom:Variant=f.get("geometry")
		var id:=String(f.get("id",""))
		if typeof(support)!=TYPE_DICTIONARY or typeof(geom)!=TYPE_DICTIONARY or String(geom.get("type",""))!="Point" or ids.has(id): return _failure("boundary feature lacks unique ID/Point/provenance")
		var point:Variant=geom.get("coordinates")
		if typeof(point)!=TYPE_ARRAY or point.size()!=3: return _failure("boundary Point must be [lon,lat,h]")
		for v in point:
			if not _finite(v): return _failure("boundary Point contains non-finite coordinate")
		var edge:=String(support.get("edge",""))
		if edge not in ["north","east","south","west"] or not _int(support.get("edge_index")) or not _int(support.get("edge_sample_count")): return _failure("boundary edge/index/count invalid")
		var ix:=int(support["edge_index"]); var count:=int(support["edge_sample_count"])
		var np:=edge=="north" and float(bounds["north_deg"])==90.0
		var sp:=edge=="south" and float(bounds["south_deg"])==-90.0
		var polar:=np or sp
		if ix<0 or ix>=count or count>(10000) or count<(1 if polar else 2) or id!="boundary:%s:%d"%[edge,ix]: return _failure("boundary edge support ID/count noncanonical")
		if polar and (count!=1 or ix!=0): return _failure("pole edge must have one index-zero point")
		var lon:=float(point[0]); var lat:=float(point[1]); var height:=float(point[2])
		var alias:=edge in ["east","north","south"] and float(bounds["east_deg"])==180.0 and lon==-180.0 and int(address["x"])==1440*(1<<int(address["level"]))-1
		if polar:
			if lon!=0.0 or lat!=(90.0 if np else -90.0): return _failure("pole point must be canonical longitude zero")
		else:
			var on_edge:=edge=="north" and lat==float(bounds["north_deg"]) or edge=="east" and (lon==float(bounds["east_deg"]) or alias) or edge=="south" and lat==float(bounds["south_deg"]) or edge=="west" and lon==float(bounds["west_deg"])
			if not on_edge or lat<float(bounds["south_deg"]) or lat>float(bounds["north_deg"]) or lon<float(bounds["west_deg"]) and not alias or lon>float(bounds["east_deg"]) and not alias: return _failure("boundary target is outside exact WFG edge")
		for key in ["source_sample_longitude","source_sample_latitude","source_height_H","geoid_undulation_N","ellipsoidal_height_h","source_to_boundary_offset_m"]:
			if not _finite(support.get(key)): return _failure("boundary metadata %s is non-finite"%key)
		for key in ["source_mask","quality_mask","geoid_mask"]:
			if not _int(support.get(key)) or int(support[key])<0 or int(support[key])>255: return _failure("boundary mask %s must be uint8"%key)
		var code:=int(support["source_mask"]); var tid:Variant=support.get("type_identifier_mask")
		if tid==null and code!=1: return _failure("null TID is allowed only for CopDEM source mask")
		if tid!=null and (not _int(tid) or int(tid)<0 or int(tid)>255): return _failure("boundary TID is not null/uint8")
		if code==2 and tid==null: return _failure("GEBCO requires Type Identifier")
		if not vertical.has(str(code)) or typeof(vertical[str(code)])!=TYPE_DICTIONARY: return _failure("boundary source mask has no vertical mapping")
		var vr:Dictionary=vertical[str(code)]
		if not _int(vr.get("geoid_mask_code")) or int(vr["geoid_mask_code"])!=int(support["geoid_mask"]): return _failure("boundary geoid mask contradicts source map")
		var datum:=String(vr.get("source_vertical_datum",""))
		if datum!=String(support.get("source_vertical_datum","")) or datum not in ["EGM2008","MEAN_SEA_LEVEL"]: return _failure("boundary vertical datum contradicts source map")
		var artifact:Variant=support.get("source_artifact")
		if typeof(artifact)!=TYPE_DICTIONARY: return _failure("boundary source_artifact must be object")
		for key in ["product","release","asset_id"]:
			if typeof(artifact.get(key))!=TYPE_STRING or String(artifact[key]).strip_edges().is_empty(): return _failure("boundary source artifact lacks "+key)
		var warning:Variant=support.get("warning")
		if warning!=null and (typeof(warning)!=TYPE_STRING or String(warning).strip_edges().is_empty()): return _failure("boundary warning must be null/nonempty")
		var method:=String(support.get("sample_method","")); var sx:=float(support["source_sample_longitude"]); var sy:=float(support["source_sample_latitude"]); var offset:=float(support["source_to_boundary_offset_m"])
		if method=="native_exact":
			if sx!=lon or sy!=lat or offset!=0.0: return _failure("native_exact support changes source point/offset")
		elif method=="nearest_native_sample":
			var dist:=LocalFrame.geodesic_distance_wgs84_m(sy,sx,lat,lon)
			if not dist.get("ok",false) or absf(float(dist["distance_m"])-offset)>0.001: return _failure("nearest support offset differs from WGS84 geodesic")
			if code==1 and not polar:
				var nearest_error := _nearest_copdem_sample_error(source_grid,lon,lat,sx,sy)
				if not nearest_error.is_empty(): return _failure(nearest_error)
		else: return _failure("unsupported boundary sample method")
		if absf(float(support["ellipsoidal_height_h"])-height)>0.000001 or absf(float(support["source_height_H"])+float(support["geoid_undulation_N"])-height)>0.00001: return _failure("boundary h differs from H+N provenance")
		if datum=="MEAN_SEA_LEVEL" and (not bool(vr.get("approximate",false)) or typeof(warning)!=TYPE_STRING or String(warning).strip_edges().is_empty()): return _failure("nominal MSL requires approximate warning")
		var bucket:Dictionary=groups.get(edge,{"count":count,"indices":{}})
		if int(bucket["count"])!=count or bucket["indices"].has(ix): return _failure("boundary edge count/index duplicate")
		bucket["indices"][ix]=true; groups[edge]=bucket; ids[id]=true
		result.append({"id":id,"edge":edge,"edge_index":ix,"edge_sample_count":count,"longitude_deg":lon,"latitude_deg":lat,"ellipsoidal_height_m":height,"support":support.duplicate(true)})
	var summaries:Variant=d.get("boundary_support_edges")
	if typeof(summaries)!=TYPE_ARRAY or summaries.size()!=groups.size(): return _failure("boundary edge summaries differ from GeoJSON")
	for item in summaries:
		if typeof(item)!=TYPE_DICTIONARY: return _failure("boundary edge summary malformed")
		var edge:=String(item.get("edge","")); var polar:bool=(edge=="north" and float(bounds["north_deg"])==90.0) or (edge=="south" and float(bounds["south_deg"])==-90.0)
		if not groups.has(edge) or not _int(item.get("sample_count")) or int(item["sample_count"])!=int(groups[edge]["count"]) or groups[edge]["indices"].size()!=int(item["sample_count"]) or int(item["sample_count"])<(1 if polar else 2): return _failure("boundary summary does not cover all edge indices")
	for edge_value in groups:
		var edge:=String(edge_value); var samples:Array[Dictionary]=[]
		for f in result:
			if String(f["edge"])==edge: samples.append(f)
		samples.sort_custom(func(a:Dictionary,b:Dictionary)->bool:return int(a["edge_index"])<int(b["edge_index"]))
		var first:Dictionary=samples[0]; var last:Dictionary=samples[-1]
		if edge=="north" and float(bounds["north_deg"])==90.0:
			if samples.size()!=1 or float(first["longitude_deg"])!=0.0: return _failure("north pole requires one shared lon-zero point")
			continue
		if edge=="south" and float(bounds["south_deg"]) == -90.0:
			if samples.size()!=1 or float(first["longitude_deg"])!=0.0: return _failure("south pole requires one shared lon-zero point")
			continue
		var lons:Array[float]=[]; var lats:Array[float]=[]
		for f in samples:
			var slon:=float(f["longitude_deg"])
			if float(bounds["east_deg"])==180.0 and slon==-180.0 and edge in ["north","south"] and int(address["x"])==1440*(1<<int(address["level"]))-1: slon=180.0
			lons.append(slon); lats.append(float(f["latitude_deg"]))
		if edge=="north" and (lons[0]!=float(bounds["west_deg"]) or lons[-1]!=float(bounds["east_deg"]) and not (float(bounds["east_deg"])==180.0 and float(last["longitude_deg"])==-180.0)): return _failure("north edge endpoints are invalid")
		if edge=="east" and (lats[0]>=float(bounds["north_deg"]) or lats[-1]!=float(bounds["south_deg"])): return _failure("east edge ownership invalid")
		var south_alias:=edge=="south" and float(bounds["east_deg"])==180.0 and float(first["longitude_deg"])==-180.0 and lons[0]==180.0
		if edge=="south" and (lons[0]>=float(bounds["east_deg"]) and not south_alias or lons[-1]!=float(bounds["west_deg"])): return _failure("south edge ownership invalid")
		if edge=="west" and (lats[0]<=float(bounds["south_deg"]) or lats[-1]>=float(bounds["north_deg"])): return _failure("west edge ownership invalid")
		for i in range(samples.size()-1):
			if edge=="north" and lons[i]>=lons[i+1]: return _failure("north edge order invalid")
			if edge=="south" and lons[i]<=lons[i+1]: return _failure("south edge order invalid")
			if edge=="east" and lats[i]<=lats[i+1]: return _failure("east edge order invalid")
			if edge=="west" and lats[i]>=lats[i+1]: return _failure("west edge order invalid")
	return {"ok":true,"error":"","features":result}

func _nearest_copdem_sample_error(source_grid: Dictionary, target_lon: float, target_lat: float, source_lon: float, source_lat: float) -> String:
	var rows_value: Variant = source_grid.get("rows")
	var columns_value: Variant = source_grid.get("columns")
	var affine: Variant = source_grid.get("source_affine")
	if not _int(rows_value) or not _int(columns_value) or int(rows_value) < 1 or int(columns_value) < 1 or typeof(affine) != TYPE_DICTIONARY:
		return "nearest CopDEM validation requires source grid dimensions and affine"
	if String(affine.get("origin_reference", "")) not in ["pixel_corner", "pixel_center"] or String(source_grid.get("pixel_registration", "")) != "point":
		return "nearest CopDEM validation requires explicit point-grid origin semantics"
	for key in ["x_origin", "y_origin", "pixel_width", "rotation_x", "rotation_y", "pixel_height"]:
		if not _finite(affine.get(key)):
			return "nearest CopDEM affine coefficient %s is non-finite" % key
	var x0 := float(affine["x_origin"])
	var y0 := float(affine["y_origin"])
	var pw := float(affine["pixel_width"])
	var rx := float(affine["rotation_x"])
	var ry := float(affine["rotation_y"])
	var ph := float(affine["pixel_height"])
	var determinant := pw * ph - rx * ry
	if absf(determinant) <= 1.0e-30:
		return "nearest CopDEM affine is singular"
	var offset := 0.5 if String(affine["origin_reference"]) == "pixel_corner" else 0.0
	var dx := target_lon - x0
	var dy := target_lat - y0
	var column_position := (dx * ph - dy * rx) / determinant - offset
	var row_position := (dy * pw - dx * ry) / determinant - offset
	if not is_finite(column_position) or not is_finite(row_position):
		return "nearest CopDEM inverse affine is non-finite"
	var rows := int(rows_value)
	var columns := int(columns_value)
	var candidate_rows: Array[int] = []
	var candidate_columns: Array[int] = []
	for raw_index in [int(floor(row_position)), int(ceil(row_position))]:
		var candidate := clampi(raw_index, 0, rows - 1)
		if not candidate_rows.has(candidate):
			candidate_rows.append(candidate)
	for raw_index in [int(floor(column_position)), int(ceil(column_position))]:
		var candidate := clampi(raw_index, 0, columns - 1)
		if not candidate_columns.has(candidate):
			candidate_columns.append(candidate)
	var best_distance := INF
	var best_lon := -INF
	var best_lat := -INF
	for row in candidate_rows:
		for column in candidate_columns:
			var qx := float(column) + offset
			var qy := float(row) + offset
			var candidate_lon := x0 + qx * pw + qy * rx
			var candidate_lat := y0 + qx * ry + qy * ph
			var distance := LocalFrame.geodesic_distance_wgs84_m(candidate_lat, candidate_lon, target_lat, target_lon)
			if not distance.get("ok", false):
				return String(distance.get("error", "nearest CopDEM inverse geodesic failed"))
			var candidate_distance := float(distance["distance_m"])
			if candidate_distance < best_distance - 0.0000001 or (absf(candidate_distance - best_distance) <= 0.0000001 and (candidate_lon > best_lon or (candidate_lon == best_lon and candidate_lat > best_lat))):
				best_distance = candidate_distance
				best_lon = candidate_lon
				best_lat = candidate_lat
	if source_lon != best_lon or source_lat != best_lat:
		return "nearest CopDEM source coordinate violates geodesic nearest/east-then-north tie ownership"
	return ""

func _decode_layers(raw:Dictionary,terrain_manifest:Dictionary,verified:Dictionary,address:Dictionary,cancellation:WorldTileCancellationToken,boundary_geometry_bytes:int)->Dictionary:
	var raster:Array[Dictionary]=[]
	var boundary:Array[Dictionary]=[]
	for d in raw["layers"]["terrain"]["payloads"]:
		if String(d["payload_kind"])=="raster_grid": raster.append(d)
		elif String(d["payload_kind"])=="terrain_boundary_support": boundary.append_array(verified[d["path"]].get("boundary_features",[]))
	if raster.is_empty(): return _failure("ready terrain has no raster grids")
	var raw_copy:Dictionary=terrain_manifest.duplicate(true)
	var record:Dictionary=raw_copy["terrain"].duplicate(true)
	record["payloads"]=raster
	raw_copy["terrain"]=record
	var decoder:=TerrainDecoder.new()
	var terrain_result:Dictionary=decoder._decode_terrain_payloads(bundle_directory,raw_copy,cancellation)
	if not terrain_result.get("ok",false): return terrain_result
	var terrain:Dictionary=terrain_result["terrain"]
	terrain["tile_bounds_wgs84"]=raw["address"]["tile_bounds"].duplicate(true)
	terrain["boundary_support_features"]=boundary
	terrain["canonical_layer_outcome"]=raw["layers"]["terrain"].duplicate(true)
	var content:=_decode_content(raw,verified,cancellation)
	if not content.get("ok",false): return content
	var decoded:Dictionary={"terrain":terrain,"landcover":content["landcover"],"vegetation":content["vegetation"],"exclusion_masks":content["exclusion_masks"],"exclusion_mask_disclosure":content["exclusion_mask_disclosure"]}
	var vectors:Dictionary={"roads":[],"buildings":[],"water":[]}
	for id in ["roads","buildings","water"]:
		for d in raw["layers"][id]["payloads"]:
			var file:Dictionary=verified[d["path"]]
			vectors[id].append({"path":file["absolute_path"],"relative_path":String(d["path"]),"descriptor":d.duplicate(true)})
	decoded["vector_payloads_by_layer"]=vectors
	decoded["initial_decoded_geometry_bytes"]=boundary_geometry_bytes
	return {"ok":true,"error":"","decoded":decoded}

func _decode_content(raw:Dictionary,verified:Dictionary,cancellation:WorldTileCancellationToken)->Dictionary:
	var land:=_load_byte_raster(raw["layers"]["landcover"],verified,"landcover")
	if not land.get("ok",false): return land
	var veg:=_load_byte_raster(raw["layers"]["vegetation"],verified,"vegetation")
	if not veg.get("ok",false): return veg
	var classes:PackedByteArray=land["values"]; var support:PackedByteArray=veg["values"]
	var rows:=int(land["rows"]); var columns:=int(land["columns"])
	if rows!=int(veg["rows"]) or columns!=int(veg["columns"]) or land["geotransform"]!=veg["geotransform"] or classes.size()!=support.size():
		return _failure("WorldCover and vegetation support shape/affine differ")
	var layer:Dictionary=raw["layers"]["vegetation"]
	var meta:Dictionary=layer["producer_metadata"].get("metadata",{})
	var land_meta:Dictionary=raw["layers"]["landcover"]["producer_metadata"].get("metadata",{})
	var mapping:Variant=meta.get("class_to_placement_value",{})
	if typeof(mapping)!=TYPE_DICTIONARY: return _failure("vegetation support-class map is missing")
	var table:Array[Dictionary]=[]
	var keys:Array=mapping.keys(); keys.sort()
	for key in keys:
		var code:=int(String(key))
		if not _int(mapping[key]) or int(mapping[key])!=code or not WC_NAMES.has(code): return _failure("vegetation support-class mapping is unsupported")
		table.append({"support_code":code,"worldcover_class_value":code,"class_name":String(WC_NAMES[code])})
	var land_mask:=PackedByteArray(); land_mask.resize(classes.size())
	for i in range(classes.size()):
		if i%262_144==0 and cancellation.is_cancelled(): return {"ok":false,"status":"cancelled","error":"WorldCover decode cancelled"}
		var cls:=int(classes[i]); var code:=int(support[i])
		if code!=0 and (code!=cls or not WC_NAMES.has(code)): return _failure("vegetation support code differs from WorldCover class")
		land_mask[i]=0 if cls in WC_EXCLUDED else 1
	var land_desc:Array=raw["layers"]["landcover"]["payloads"]; var veg_desc:Array=raw["layers"]["vegetation"]["payloads"]
	var source_sha:=String(meta.get("source_sha256",land_meta.get("source_sha256","")))
	if not _sha(source_sha): return _failure("WorldCover source COG SHA-256 is absent")
	var provenance:Dictionary={"provider":"ESA","product":"WorldCover","release":"2021","algorithm_version":"v200","license":"CC-BY-4.0","support_payload_sha256":String(veg_desc[0]["sha256"]) if not veg_desc.is_empty() else TerrainGridHashV1.sha256_bytes(PackedByteArray()),"class_payload_sha256":String(land_desc[0]["sha256"]) if not land_desc.is_empty() else TerrainGridHashV1.sha256_bytes(PackedByteArray()),"source_cog_sha256":source_sha}
	var affine:Dictionary=land["pixel_center_affine"]
	var landcover:Dictionary={"classes_u8":classes,"rows":rows,"columns":columns,"pixel_center_affine":affine,"source_class_table":land_meta.get("class_labels",{}),"provenance":raw["layers"]["landcover"]["source_lineage"].duplicate(true)}
	var vegetation:Dictionary={"placement_support_u8":support,"classes_u8":classes,"rows":rows,"columns":columns,"pixel_center_affine":affine,"support_class_table":table,"provenance":provenance,"source_lineage":layer["source_lineage"].duplicate(true),"algorithm_id":String(meta.get("algorithm_id","")),"placement_spacing_m":100.0}
	return {"ok":true,"error":"","landcover":landcover,"vegetation":vegetation,"exclusion_masks":{"land":land_mask},"exclusion_mask_disclosure":"WorldCover land exclusion is applied. Overture water/road/building masks are not rasterized; those exclusions are unavailable and are not claimed."}

func _load_byte_raster(layer:Dictionary,verified:Dictionary,id:String)->Dictionary:
	var count:=int(layer.get("pixel_count",0))
	if count==0 and layer["payloads"].is_empty(): return {"ok":true,"error":"","rows":0,"columns":0,"values":PackedByteArray(),"geotransform":{},"pixel_center_affine":{}}
	if layer["payloads"].size()!=1: return _failure("%s requires one source-preserving raster payload"%id)
	var d:Dictionary=layer["payloads"][0]
	if String(d.get("dtype",""))!="uint8": return _failure("%s raster must be uint8"%id)
	var rows:=int(d["shape"][0]); var columns:=int(d["shape"][1])
	if rows*columns!=count or rows*columns>MAX_RASTER_SAMPLES: return _failure("%s shape differs from pixel_count"%id)
	var item:Dictionary=verified[d["path"]]
	var read:=_read_bytes(String(item["absolute_path"]),MAX_PAYLOAD_BYTES,false)
	if not read.get("ok",false): return _failure(String(read.get("error","raster read failed")))
	var values:PackedByteArray=read["bytes"]
	if values.size()!=rows*columns: return _failure("%s uint8 byte length differs from shape"%id)
	var transform:=RasterTransform.validate_transform(d["geotransform"],rows,columns)
	if not transform.get("ok",false): return _failure("%s raster affine is invalid"%id)
	var center:=RasterTransform.axis_aligned_pixel_center_affine(transform)
	if not center.get("ok",false): return _failure("%s renderer requires axis-aligned affine"%id)
	return {"ok":true,"error":"","rows":rows,"columns":columns,"values":values,"geotransform":transform,"pixel_center_affine":center}

func _normalize_manifest(raw:Dictionary)->Dictionary:
	var outcomes:Dictionary={}; var refs:Dictionary={}
	for id in LAYERS:
		outcomes[id]=raw["layers"][id].duplicate(true)
		var ref:Dictionary=raw["layers"][id]["spatial_reference"].duplicate(true)
		ref["axis_order"]="longitude_latitude" if ref.get("axis_order")==["longitude","latitude"] else "unsupported"
		if ref.get("source_vertical_datum")=="per_sample_source_mask":
			var conv:Dictionary=ref.get("vertical_conversion",{}).duplicate(true)
			var mapping:Dictionary=conv.get("vertical_references_by_source_code",{}).duplicate(true)
			for code in mapping:
				var row:Dictionary=mapping[code]
				row["conversion_mask_code"]=int(row.get("geoid_mask_code",-1))
				if row.has("warning"): row["quality_warning"]=String(row["warning"])
				mapping[code]=row
			conv["vertical_references_by_source_code"]=mapping; ref["vertical_conversion"]=conv
		refs[id]=ref
	var a:Dictionary=raw["address"]
	return {"schema_id":String(raw["schema_id"]),"schema_version":String(raw["schema_version"]),"address_id":String(a["address_id"]),"tile_bounds":a["tile_bounds"].duplicate(true),"source_id":String(raw["source_id"]),"source_generation":String(raw["source_generation"]),"lod":int(raw["lod"]),"layer_outcomes":outcomes,"layer_spatial_references":refs,"tile_origin":raw["tile_origin"].duplicate(true),"raw_external_manifest":raw.duplicate(true),"consumer_limit_profile_id":PROFILE_ID}

func _check_file_set(verified:Dictionary)->String:
	var expected:Dictionary={"manifest.json":true,"provenance/terrain-manifest.json":true,"provenance/features-manifest.json":true}
	for path in verified: expected[path]=true
	var actual:=_collect(bundle_directory,bundle_directory)
	if actual.size()!=expected.size(): return "bundle has unlisted or missing files"
	for path in actual:
		if not expected.has(path): return "bundle has unlisted file "+path
	return ""

func _collect(root:String,directory:String)->Array[String]:
	var out:Array[String]=[]
	var dir:=DirAccess.open(directory)
	if dir==null:return out
	var root_norm:=root.replace("\\","/").trim_suffix("/")
	for file in dir.get_files():
		var full:=directory.path_join(file).simplify_path().replace("\\","/")
		out.append(full.trim_prefix(root_norm+"/"))
	for child in dir.get_directories():
		out.append_array(_collect(root,directory.path_join(child).simplify_path()))
	out.sort()
	return out

func _resolve(relative:String,sha:String,size:int,limit:int,cancellation:WorldTileCancellationToken=null)->Dictionary:
	if not _path(relative):return _failure("unsafe relative bundle path")
	if size<1 or size>mini(limit,MAX_PAYLOAD_BYTES) or not _sha(sha):return _failure("payload length/hash outside finite profile")
	var full:=bundle_directory.path_join(relative).simplify_path()
	if not _within(bundle_directory,full) or not FileAccess.file_exists(full):return _failure("payload is missing or escapes bundle root")
	var hashed:=_hash_file(full,size,sha,cancellation)
	if not hashed.get("ok",false):return hashed
	return {"ok":true,"error":"","path":full}

func _hash_file(path:String,expected:int,sha:String,cancellation:WorldTileCancellationToken=null)->Dictionary:
	var file:=FileAccess.open(path,FileAccess.READ)
	if file==null:return _failure("cannot open payload for hashing")
	if file.get_length()!=expected:file.close();return _failure("payload size differs from descriptor")
	var ctx:=HashingContext.new()
	if ctx.start(HashingContext.HASH_SHA256)!=OK:file.close();return _failure("cannot initialize SHA-256")
	var used:=0
	while used<expected:
		if cancellation != null and cancellation.is_cancelled():
			file.close()
			return {"ok":false,"status":"cancelled","error":"payload hashing cancelled"}
		var chunk:=file.get_buffer(mini(CHUNK_BYTES,expected-used))
		if chunk.is_empty() or ctx.update(chunk)!=OK:file.close();return _failure("payload hash read failed")
		used+=chunk.size()
	file.close()
	if ctx.finish().hex_encode()!=sha:return _failure("payload checksum mismatch")
	return {"ok":true,"error":""}

func _read_bytes(path:String,limit:int,allow_empty:bool)->Dictionary:
	var file:=FileAccess.open(path,FileAccess.READ)
	if file==null:return _failure("cannot open file "+path)
	var length:=file.get_length()
	if length<0 or length>limit or (length==0 and not allow_empty):file.close();return _failure("file exceeds bounded read size")
	var bytes:=file.get_buffer(length);file.close()
	if bytes.size()!=length:return _failure("incomplete file read")
	return {"ok":true,"error":"","bytes":bytes}

func _reject_reparse_points(root:String)->bool:
	if not OS.has_feature("windows"):return false
	var script:=ProjectSettings.globalize_path("res://tools/reject_reparse_points.ps1")
	if not FileAccess.file_exists(script):return false
	var output:Array=[]
	return OS.execute("powershell.exe",["-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",script,"-BundlePath",root],output,true)==0

func _path(value:String)->bool:
	if value.is_empty() or value.length()>MAX_PATH_CHARS or value.begins_with("/") or value.begins_with("\\") or value.contains("\\") or value.contains(":"):return false
	for c in value.split("/"):
		if c.is_empty() or c=="." or c==".." or c.length()>255:return false
	return true

func _within(root:String,path:String)->bool:
	var r:=root.replace("\\","/").trim_suffix("/").to_lower()
	return path.replace("\\","/").to_lower().begins_with(r+"/")

func _sha(value:String)->bool:
	if value.length()!=64:return false
	for c in value:
		if "0123456789abcdef".find(c)<0:return false
	return true

func _int(value:Variant)->bool:
	if typeof(value)==TYPE_INT:return true
	return typeof(value)==TYPE_FLOAT and is_finite(float(value)) and floor(float(value))==float(value)

func _finite(value:Variant)->bool:
	return typeof(value) in [TYPE_INT,TYPE_FLOAT] and is_finite(float(value))

func _exact(value:Variant,keys:Array)->bool:
	if typeof(value)!=TYPE_DICTIONARY or value.size()!=keys.size():return false
	for key in keys:
		if not value.has(key):return false
	return true

func _only(value:Variant,keys:Array)->bool:
	if typeof(value)!=TYPE_DICTIONARY:return false
	for key in value:
		if key not in keys:return false
	return true

func _failure(message:String)->Dictionary:
	return {"ok":false,"error":message}
