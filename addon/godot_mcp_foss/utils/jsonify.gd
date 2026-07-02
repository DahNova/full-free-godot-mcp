@tool
extends RefCounted
## JSON-safe conversion of arbitrary Godot values (shared by editor + game side).

static func jsonify(v, depth: int = 0):
	if depth > 8:
		return "<depth capped>"
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return v
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return String(v)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return {"x": v.x, "y": v.y}
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return {"x": v.x, "y": v.y, "z": v.z}
		TYPE_COLOR:
			return {"r": v.r, "g": v.g, "b": v.b, "a": v.a}
		TYPE_RECT2, TYPE_RECT2I:
			return {"x": v.position.x, "y": v.position.y, "w": v.size.x, "h": v.size.y}
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[str(k)] = jsonify(v[k], depth + 1)
			return out
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, \
		TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			var arr := []
			for item in v:
				arr.append(jsonify(item, depth + 1))
			return arr
		TYPE_OBJECT:
			if v == null:
				return null
			if v is Node:
				return "<Node %s (%s)>" % [v.get_path(), v.get_class()]
			return "<%s>" % v.get_class()
		_:
			return str(v)


## Coerce a JSON value onto the TYPE of an existing value (for property sets).
static func coerce(json_value, current):
	match typeof(current):
		TYPE_BOOL:
			return bool(json_value)
		TYPE_INT:
			return int(json_value)
		TYPE_FLOAT:
			return float(json_value)
		TYPE_STRING:
			return String(str(json_value))
		TYPE_STRING_NAME:
			return StringName(str(json_value))
		TYPE_VECTOR2:
			if json_value is Dictionary:
				return Vector2(float(json_value.get("x", 0)), float(json_value.get("y", 0)))
			if json_value is Array and json_value.size() >= 2:
				return Vector2(float(json_value[0]), float(json_value[1]))
		TYPE_VECTOR2I:
			if json_value is Dictionary:
				return Vector2i(int(json_value.get("x", 0)), int(json_value.get("y", 0)))
			if json_value is Array and json_value.size() >= 2:
				return Vector2i(int(json_value[0]), int(json_value[1]))
		TYPE_COLOR:
			if json_value is Dictionary:
				return Color(float(json_value.get("r", 0)), float(json_value.get("g", 0)),
					float(json_value.get("b", 0)), float(json_value.get("a", 1)))
			if json_value is String:
				return Color(json_value)
	return json_value


## Reindent user code so it can live inside a generated `func run():` body.
## GDScript forbids mixed tab/space indentation, so leading spaces are folded
## into tab levels (unit auto-detected: 4 if any line indents by 4+, else 2).
static func embed_body(code: String, base_tabs: int = 1) -> String:
	var lines := code.split("\n")
	var unit := 0
	for line in lines:
		if line.strip_edges() == "" or line.begins_with("\t"):
			continue
		var n := 0
		while n < line.length() and line[n] == " ":
			n += 1
		if n > 0:
			unit = 4 if (unit == 0 and n % 4 == 0) or unit == 4 else 2
	if unit == 0:
		unit = 4
	var out: Array[String] = []
	var prefix := "\t".repeat(base_tabs)
	for line in lines:
		if line.strip_edges() == "":
			out.append("")
			continue
		if line.begins_with("\t"):
			out.append(prefix + line)
			continue
		var n := 0
		while n < line.length() and line[n] == " ":
			n += 1
		var levels := n / unit
		out.append(prefix + "\t".repeat(levels) + line.substr(n))
	if out.is_empty():
		out.append(prefix + "pass")
	return "\n".join(out)
