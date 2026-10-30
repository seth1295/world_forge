class_name WorldTileCancellationToken
extends RefCounted

## Thread-safe cancellation flag shared by the main-thread manager and its
## provider worker. Provider I/O/decoders should poll this between bounded steps.
var _mutex := Mutex.new()
var _cancelled := false

func cancel() -> void:
	_mutex.lock()
	_cancelled = true
	_mutex.unlock()

func is_cancelled() -> bool:
	_mutex.lock()
	var value := _cancelled
	_mutex.unlock()
	return value
