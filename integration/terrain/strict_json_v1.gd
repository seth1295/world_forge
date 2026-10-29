class_name StrictJsonV1
extends RefCounted

const DEFAULT_BYTE_LIMIT := 65536
const MAX_NESTING := 64

var _text := ""
var _cursor := 0
var _error := ""

func parse_bytes(bytes: PackedByteArray, byte_limit: int = DEFAULT_BYTE_LIMIT) -> Dictionary:
    if bytes.size() > byte_limit:
        return _fail("manifest exceeds byte limit")
    var first_byte := 0
    if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF:
        first_byte = 3
    var normalized := PackedByteArray()
    normalized.resize(bytes.size() - first_byte)
    for i in range(first_byte, bytes.size()):
        normalized[i - first_byte] = bytes[i]
    _text = normalized.get_string_from_utf8()
    if _text.to_utf8_buffer() != normalized:
        return _fail("manifest is not valid UTF-8")
    _cursor = 0
    _error = ""
    if not _scan_value(0):
        return _fail(_error)
    _skip_whitespace()
    if _cursor != _text.length():
        return _fail("unexpected trailing JSON data")
    var parser := JSON.new()
    var parse_error := parser.parse(_text)
    if parse_error != OK:
        return _fail("JSON parse error at line %d: %s" % [parser.get_error_line(), parser.get_error_message()])
    if typeof(parser.data) != TYPE_DICTIONARY:
        return _fail("manifest root must be an object")
    return {"ok": true, "value": parser.data, "error": ""}

func _scan_value(depth: int) -> bool:
    if depth > MAX_NESTING:
        _error = "JSON nesting limit exceeded"
        return false
    _skip_whitespace()
    if _cursor >= _text.length():
        _error = "unexpected end of JSON"
        return false
    var character := _text.substr(_cursor, 1)
    if character == "{":
        return _scan_object(depth + 1)
    if character == "[":
        return _scan_array(depth + 1)
    if character == "\"":
        _scan_string()
        return _error.is_empty()
    return _scan_scalar()

func _scan_object(depth: int) -> bool:
    _cursor += 1
    _skip_whitespace()
    var seen: Dictionary = {}
    if _peek() == "}":
        _cursor += 1
        return true
    while _cursor < _text.length():
        _skip_whitespace()
        if _peek() != "\"":
            _error = "object key must be a string"
            return false
        var key := _scan_string()
        if not _error.is_empty():
            return false
        if seen.has(key):
            _error = "duplicate JSON object key: %s" % key
            return false
        seen[key] = true
        _skip_whitespace()
        if _peek() != ":":
            _error = "expected ':' after object key"
            return false
        _cursor += 1
        if not _scan_value(depth):
            return false
        _skip_whitespace()
        if _peek() == "}":
            _cursor += 1
            return true
        if _peek() != ",":
            _error = "expected ',' or '}' in object"
            return false
        _cursor += 1
    _error = "unterminated object"
    return false

func _scan_array(depth: int) -> bool:
    _cursor += 1
    _skip_whitespace()
    if _peek() == "]":
        _cursor += 1
        return true
    while _cursor < _text.length():
        if not _scan_value(depth):
            return false
        _skip_whitespace()
        if _peek() == "]":
            _cursor += 1
            return true
        if _peek() != ",":
            _error = "expected ',' or ']' in array"
            return false
        _cursor += 1
    _error = "unterminated array"
    return false

func _scan_string() -> String:
    var start := _cursor
    _cursor += 1
    var escaped := false
    while _cursor < _text.length():
        var character := _text.substr(_cursor, 1)
        if escaped:
            escaped = false
        elif character == "\\":
            escaped = true
        elif character == "\"":
            _cursor += 1
            var parsed: Variant = JSON.parse_string(_text.substr(start, _cursor - start))
            if typeof(parsed) != TYPE_STRING:
                _error = "invalid JSON string"
                return ""
            return parsed
        _cursor += 1
    _error = "unterminated string"
    return ""

func _scan_scalar() -> bool:
    var start := _cursor
    while _cursor < _text.length():
        var codepoint := _text.unicode_at(_cursor)
        if codepoint == 32 or codepoint == 9 or codepoint == 10 or codepoint == 13 or codepoint == 44 or codepoint == 93 or codepoint == 125:
            break
        _cursor += 1
    if _cursor == start:
        _error = "invalid JSON value"
        return false
    return true

func _skip_whitespace() -> void:
    while _cursor < _text.length():
        var codepoint := _text.unicode_at(_cursor)
        if codepoint != 32 and codepoint != 9 and codepoint != 10 and codepoint != 13:
            return
        _cursor += 1

func _peek() -> String:
    if _cursor >= _text.length():
        return ""
    return _text.substr(_cursor, 1)

func _fail(message: String) -> Dictionary:
    return {"ok": false, "value": null, "error": message}