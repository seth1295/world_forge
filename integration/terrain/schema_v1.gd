class_name TerrainSchemaV1
extends RefCounted

static func validate(instance: Variant, root_schema: Dictionary) -> String:
    return _validate(instance, root_schema, root_schema, "manifest")

static func _validate(instance: Variant, schema: Dictionary, root_schema: Dictionary, location: String) -> String:
    if schema.has("$ref"):
        var reference: String = schema["$ref"]
        const PREFIX := "#/$defs/"
        if not reference.begins_with(PREFIX):
            return "%s has unsupported schema reference %s" % [location, reference]
        var definition_name := reference.substr(PREFIX.length())
        var definitions: Dictionary = root_schema.get("$defs", {})
        if not definitions.has(definition_name):
            return "%s references missing definition %s" % [location, definition_name]
        return _validate(instance, definitions[definition_name], root_schema, location)

    var expected_type: String = schema.get("type", "")
    if not expected_type.is_empty() and not _matches_type(instance, expected_type):
        return "%s must be %s" % [location, expected_type]
    if schema.has("const") and instance != schema["const"]:
        return "%s must equal %s" % [location, str(schema["const"])]
    if schema.has("enum") and not schema["enum"].has(instance):
        return "%s is not an allowed value" % location

    if typeof(instance) == TYPE_DICTIONARY:
        var required: Array = schema.get("required", [])
        for key in required:
            if not instance.has(key):
                return "%s is missing required property %s" % [location, key]
        var properties: Dictionary = schema.get("properties", {})
        if schema.get("additionalProperties", true) == false:
            for key in instance.keys():
                if not properties.has(key):
                    return "%s has unknown property %s" % [location, key]
        for key in instance.keys():
            if properties.has(key):
                var error := _validate(instance[key], properties[key], root_schema, "%s.%s" % [location, key])
                if not error.is_empty():
                    return error

    if typeof(instance) == TYPE_STRING:
        var text: String = instance
        if schema.has("minLength") and text.length() < int(schema["minLength"]):
            return "%s is shorter than minLength" % location
        if schema.has("maxLength") and text.length() > int(schema["maxLength"]):
            return "%s exceeds maxLength" % location
        if schema.has("pattern"):
            var expression := RegEx.new()
            if expression.compile(str(schema["pattern"])) != OK or expression.search(text) == null:
                return "%s does not match required pattern" % location
        if schema.has("format") and not _matches_format(text, str(schema["format"])):
            return "%s does not match format %s" % [location, schema["format"]]

    if typeof(instance) == TYPE_INT or typeof(instance) == TYPE_FLOAT:
        var number := float(instance)
        if not is_finite(number):
            return "%s must be finite" % location
        if schema.has("minimum") and number < float(schema["minimum"]):
            return "%s is below minimum" % location
        if schema.has("maximum") and number > float(schema["maximum"]):
            return "%s exceeds maximum" % location
        if schema.has("exclusiveMinimum") and number <= float(schema["exclusiveMinimum"]):
            return "%s is at or below exclusiveMinimum" % location
        if schema.has("exclusiveMaximum") and number >= float(schema["exclusiveMaximum"]):
            return "%s is at or above exclusiveMaximum" % location

    return ""

static func _matches_type(value: Variant, expected_type: String) -> bool:
    match expected_type:
        "object":
            return typeof(value) == TYPE_DICTIONARY
        "string":
            return typeof(value) == TYPE_STRING
        "integer":
            if typeof(value) == TYPE_INT:
                return true
            return typeof(value) == TYPE_FLOAT and is_finite(float(value)) and floor(float(value)) == float(value)
        "number":
            return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
        "boolean":
            return typeof(value) == TYPE_BOOL
        "array":
            return typeof(value) == TYPE_ARRAY
        "null":
            return typeof(value) == TYPE_NIL
        _:
            return false

static func _matches_format(value: String, format: String) -> bool:
    var expression := RegEx.new()
    match format:
        "uri":
            if expression.compile("^[A-Za-z][A-Za-z0-9+.-]*://[^\\s]+$") != OK:
                return false
            return expression.search(value) != null
        "date":
            if expression.compile("^\\d{4}-\\d{2}-\\d{2}$") != OK:
                return false
            if expression.search(value) == null:
                return false
            var parts := value.split("-")
            var year := int(parts[0])
            var month := int(parts[1])
            var day := int(parts[2])
            if month < 1 or month > 12:
                return false
            var month_days := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            var leap := (year % 4 == 0 and year % 100 != 0) or year % 400 == 0
            if leap:
                month_days[1] = 29
            return day >= 1 and day <= month_days[month - 1]
        "date-time":
            if expression.compile("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})$") != OK:
                return false
            return expression.search(value) != null
        _:
            return false