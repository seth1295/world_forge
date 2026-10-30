class_name WorldTileLoadTask
extends RefCounted

## Small worker wrapper whose `result` is read only after Godot reports task
## completion and the manager has waited for that task ID.
var result: Dictionary = {}

func run(provider: WorldTileProvider, request: Dictionary, cancellation: WorldTileCancellationToken) -> void:
	if cancellation.is_cancelled():
		result = {"ok": false, "status": "cancelled", "error": "request cancelled before provider start"}
		return
	var provider_result: Variant = provider.load_tile(request, cancellation)
	if cancellation.is_cancelled():
		result = {"ok": false, "status": "cancelled", "error": "request cancelled during provider work"}
		return
	if typeof(provider_result) != TYPE_DICTIONARY:
		result = {"ok": false, "status": "failed", "error": "provider returned a non-dictionary result"}
		return
	result = {"ok": true, "provider_result": provider_result}
