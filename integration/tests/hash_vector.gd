extends SceneTree

const StrictJson = preload("res://terrain/strict_json_v1.gd")
const SchemaV1 = preload("res://terrain/schema_v1.gd")
const HashV1 = preload("res://terrain/hash_v1.gd")

func _initialize() -> void:
    var args := OS.get_cmdline_user_args()
    if args.size() != 2:
        push_error("usage: hash_vector.gd -- <manifest-path> <schema-path>")
        quit(2)
        return
    var manifest_bytes := FileAccess.get_file_as_bytes(args[0])
    var strict_parser = StrictJson.new()
    var parsed: Dictionary = strict_parser.parse_bytes(manifest_bytes)
    if not parsed.get("ok", false):
        push_error("strict JSON failed: %s" % parsed.get("error", "unknown"))
        quit(3)
        return
    var schema_parser := JSON.new()
    var schema_bytes := FileAccess.get_file_as_bytes(args[1])
    var schema_error := schema_parser.parse(schema_bytes.get_string_from_utf8())
    if schema_error != OK:
        push_error("schema JSON failed: %s" % schema_parser.get_error_message())
        quit(4)
        return
    var manifest: Dictionary = parsed["value"]
    var schema: Dictionary = schema_parser.data
    var semantic_error: String = SchemaV1.validate(manifest, schema)
    if not semantic_error.is_empty():
        push_error("schema validation failed: %s" % semantic_error)
        quit(5)
        return
    var frame_hash := HashV1.compute_frame_hash(manifest["frame"])
    var artifact_id := HashV1.compute_artifact_id(manifest, frame_hash)
    if frame_hash != manifest["frame_definition_sha256"]:
        push_error("frame hash mismatch: %s" % frame_hash)
        quit(6)
        return
    if artifact_id != manifest["artifact_id"]:
        push_error("artifact ID mismatch: %s" % artifact_id)
        quit(7)
        return
    print("FRAME_HASH=%s" % frame_hash)
    print("ARTIFACT_ID=%s" % artifact_id)
    quit(0)