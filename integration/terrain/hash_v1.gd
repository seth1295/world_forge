class_name TerrainGridHashV1
extends RefCounted

static func sha256_bytes(bytes: PackedByteArray) -> String:
    var context := HashingContext.new()
    if context.start(HashingContext.HASH_SHA256) != OK:
        return ""
    if context.update(bytes) != OK:
        return ""
    return context.finish().hex_encode()

static func compute_frame_hash(frame: Dictionary) -> String:
    var stream := _new_hash_stream("WF-TERRAIN-FRAME-1")
    var horizontal: Dictionary = frame["horizontal"]
    var vertical: Dictionary = frame["vertical"]
    var origin: Dictionary = frame["origin"]
    var ordered_strings: Array[String] = [
        frame["frame_id"],
        horizontal["source_crs"], horizontal["source_axis_order"], horizontal["datum"],
        horizontal["ellipsoid"], horizontal["realization_epoch"], horizontal["projection_method"],
        horizontal["projection_wkt2"], horizontal["operation_proj_pipeline"],
        horizontal["projected_axis_order"], horizontal["unit"],
        vertical["datum"], vertical["height_type"], vertical["unit"], vertical["local_up_expression"],
        origin["source_product_id"]
    ]
    for value in ordered_strings:
        _put_string(stream, value)
    _put_raw_sha(stream, origin["source_raster_sha256"])
    stream.put_u32(int(origin["source_row"]))
    stream.put_u32(int(origin["source_column"]))
    stream.put_double(float(origin["longitude_deg"]))
    stream.put_double(float(origin["latitude_deg"]))
    stream.put_double(float(origin["height_navd88_m"]))
    return sha256_bytes(stream.data_array)

static func compute_artifact_id(manifest: Dictionary, frame_hash: String) -> String:
    var stream := _new_hash_stream("WF-TERRAIN-ARTIFACT-1")
    _put_string(stream, manifest["contract_id"])
    var source: Dictionary = manifest["source"]
    var payloads: Dictionary = manifest["payloads"]
    var ordered_hashes: Array[String] = [
        frame_hash, source["raster"]["sha256"], source["metadata"]["sha256"],
        source["product_record"]["sha256"], payloads["horizontal_xy"]["sha256"],
        payloads["height_samples"]["sha256"]
    ]
    for value in ordered_hashes:
        _put_raw_sha(stream, value)
    var grid: Dictionary = manifest["grid"]
    var window: Dictionary = grid["source_window"]
    stream.put_u32(int(window["row_offset"]))
    stream.put_u32(int(window["column_offset"]))
    stream.put_u32(int(grid["rows"]))
    stream.put_u32(int(grid["columns"]))
    return sha256_bytes(stream.data_array)

static func _new_hash_stream(domain: String) -> StreamPeerBuffer:
    var stream := StreamPeerBuffer.new()
    stream.big_endian = false
    stream.put_data(domain.to_utf8_buffer())
    stream.put_8(0)
    return stream

static func _put_string(stream: StreamPeerBuffer, value: String) -> void:
    var bytes := value.to_utf8_buffer()
    stream.put_u32(bytes.size())
    stream.put_data(bytes)

static func _put_raw_sha(stream: StreamPeerBuffer, value: String) -> void:
    stream.put_data(hex_to_bytes(value))

static func hex_to_bytes(value: String) -> PackedByteArray:
    var out := PackedByteArray()
    if value.length() != 64:
        return out
    for i in range(0, value.length(), 2):
        out.append(value.substr(i, 2).hex_to_int())
    return out