extends Node
## Godot MCP FOSS — game-side agent (autoload injected by the editor plugin).
##
## Answers the editor's relayed runtime commands: it polls user:// for
## mcp_foss_req_<id>.json files, executes the command (possibly across frames —
## handlers may await), and writes mcp_foss_res_<id>.json ATOMICALLY
## (tmp + rename) so the editor never reads a half-written file.
## In an exported release build the agent goes inert.

const J := preload("res://addons/godot_mcp_foss/utils/jsonify.gd")

const POLL_S := 0.05
const REQ_PREFIX := "mcp_foss_req_"

var _accum := 0.0
var _busy := false


func _ready() -> void:
	if not OS.has_feature("editor"):
		set_process(false)   # never active in exported builds
		return
	_cleanup_stale()


func _process(delta: float) -> void:
	if _busy:
		return
	_accum += delta
	if _accum < POLL_S:
		return
	_accum = 0.0
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.begins_with(REQ_PREFIX) and fname.ends_with(".json"):
			dir.list_dir_end()
			_busy = true
			_handle("user://" + fname)   # fire-and-forget coroutine
			return
		fname = dir.get_next()
	dir.list_dir_end()


func _handle(req_path: String) -> void:
	var f := FileAccess.open(req_path, FileAccess.READ)
	if f == null:
		_busy = false
		return
	var text := f.get_as_text()
	f.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(req_path))
	var msg = JSON.parse_string(text)
	if not (msg is Dictionary) or not msg.has("id"):
		_busy = false
		return
	var id := String(msg["id"])
	var method := String(msg.get("method", ""))
	var params: Dictionary = msg.get("params", {}) if msg.get("params") is Dictionary else {}
	var out: Dictionary
	match method:
		"exec": out = await _exec(params)
		"screenshot": out = await _screenshot(params)
		"tree": out = _tree(params)
		"node_get": out = _node_get(params)
		"node_set": out = _node_set(params)
		"click": out = _click(params)
		"input": out = await _input_event(params)
		"wait": out = await _wait(params)
		"perf": out = _perf(params)
		"perf_series": out = await _perf_series(params)
		"capture": out = await _capture(params)
		"run_script": out = await _run_script(params)
		_: out = {"__error": "unknown runtime method '%s'" % method}
	var payload: Dictionary
	if out.has("__error"):
		payload = {"id": id, "error": String(out["__error"])}
	else:
		payload = {"id": id, "result": out}
	_write_atomic("user://mcp_foss_res_%s.json" % id, JSON.stringify(payload))
	_busy = false


func _write_atomic(path: String, text: String) -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path))


func _cleanup_stale() -> void:
	# Sweep leftovers from dead sessions — but NOT fresh requests: the editor
	# may legitimately have queued a command while this game was still booting
	# (e.g. game_wait right after run_scene), and eating it would strand the
	# editor's relay until its timeout.
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	var now := int(Time.get_unix_time_from_system())
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.begins_with("mcp_foss_"):
			var age := now - int(FileAccess.get_modified_time("user://" + fname))
			if not fname.begins_with(REQ_PREFIX) or age > 10:
				dir.remove(fname)
		fname = dir.get_next()
	dir.list_dir_end()


# --- commands ---------------------------------------------------------------

func _exec(params: Dictionary) -> Dictionary:
	var code := String(params.get("code", ""))
	if code.strip_edges() == "":
		return {"__error": "exec: 'code' is required"}
	var src := "\n".join([
		"extends RefCounted",
		"var prints := []",
		"var scene_tree: SceneTree",
		"func say(v) -> void:",
		"\tprints.append(str(v))",
		"func run():",
		J.embed_body(code, 1),
	])
	var scr := GDScript.new()
	scr.source_code = src
	var err := scr.reload()
	if err != OK:
		return {"__error": "exec: code failed to parse (err %d)" % err}
	var inst = scr.new()
	inst.scene_tree = get_tree()   # handed in so user code can reach the live tree
	var value = await inst.run()
	return {"value": J.jsonify(value), "prints": inst.prints.duplicate()}


func _screenshot(params: Dictionary) -> Dictionary:
	var save_path := String(params.get("save_path", ""))
	if save_path == "":
		return {"__error": "screenshot: 'save_path' is required"}
	await RenderingServer.frame_post_draw   # guarantee a fully rendered frame
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return {"__error": "screenshot: no viewport image"}
	var err := img.save_png(save_path)
	if err != OK:
		return {"__error": "screenshot: save_png failed (err %d) for %s" % [err, save_path]}
	return {"saved_path": save_path, "width": img.get_width(), "height": img.get_height()}


func _walk(node: Node, depth: int, max_depth: int) -> Dictionary:
	var out := {"name": String(node.name), "type": node.get_class()}
	if node.get_script() != null:
		out["script"] = String(node.get_script().resource_path)
	if depth < max_depth and node.get_child_count() > 0:
		var kids := []
		for c in node.get_children():
			kids.append(_walk(c, depth + 1, max_depth))
		out["children"] = kids
	elif node.get_child_count() > 0:
		out["children_omitted"] = node.get_child_count()
	return out


func _tree(params: Dictionary) -> Dictionary:
	var from := String(params.get("from", "/root"))
	var max_depth := int(params.get("max_depth", 5))
	var node := get_node_or_null(from)
	if node == null:
		return {"__error": "tree: node not found: %s" % from}
	return {"from": from, "tree": _walk(node, 0, max_depth)}


func _node_get(params: Dictionary) -> Dictionary:
	var path := String(params.get("path", ""))
	var node := get_node_or_null(path)
	if node == null:
		return {"__error": "node_get: node not found: %s" % path}
	var wanted: Array = params.get("props", [])
	var props := {}
	if not wanted.is_empty():
		for p in wanted:
			props[String(p)] = J.jsonify(node.get(String(p)))
	else:
		var count := 0
		for info in node.get_property_list():
			if count >= 120:
				props["<capped>"] = true
				break
			var usage := int(info.get("usage", 0))
			if usage & (PROPERTY_USAGE_SCRIPT_VARIABLE | PROPERTY_USAGE_EDITOR):
				props[String(info["name"])] = J.jsonify(node.get(info["name"]))
				count += 1
	return {"path": path, "type": node.get_class(), "properties": props}


func _node_set(params: Dictionary) -> Dictionary:
	var path := String(params.get("path", ""))
	var prop := String(params.get("property", ""))
	if path == "" or prop == "":
		return {"__error": "node_set: 'path' and 'property' are required"}
	var node := get_node_or_null(path)
	if node == null:
		return {"__error": "node_set: node not found: %s" % path}
	var coerced = J.coerce(params.get("value"), node.get(prop))
	node.set(prop, coerced)
	return {"path": path, "property": prop, "value": J.jsonify(node.get(prop))}


## Run a res:// script FILE inside the game. Contract: extends RefCounted with
## `func run(args: Dictionary)` (may await). A `scene_tree` property, when
## declared, is injected with the live SceneTree. Keeps repeatable e2e drivers
## versioned in the repo instead of retyped inline.
func _run_script(params: Dictionary) -> Dictionary:
	var path := String(params.get("path", ""))
	if path == "" or not FileAccess.file_exists(path):
		return {"__error": "run_script: script not found: %s" % path}
	var scr = ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_REPLACE)
	if scr == null:
		return {"__error": "run_script: failed to load/parse %s" % path}
	var inst = scr.new()
	if not inst.has_method("run"):
		return {"__error": "run_script: %s must implement `func run(args: Dictionary)`" % path}
	if "scene_tree" in inst:
		inst.scene_tree = get_tree()
	var args: Dictionary = params.get("args", {}) if params.get("args") is Dictionary else {}
	var value = await inst.run(args)
	return {"script": path, "value": J.jsonify(value)}


## Sample the performance monitors over a window; series capped at 100 points.
func _perf_series(params: Dictionary) -> Dictionary:
	var duration_ms := clampi(int(params.get("duration_ms", 5000)), 250, 60000)
	var interval_ms := clampi(int(params.get("interval_ms", 250)), 50, 5000)
	var samples: Array = []
	var elapsed := 0
	while elapsed <= duration_ms and samples.size() < 100:
		samples.append(_perf({}))
		if elapsed + interval_ms > duration_ms:
			break
		await get_tree().create_timer(float(interval_ms) / 1000.0).timeout
		elapsed += interval_ms
	var fps_min := 1e9
	var fps_max := 0.0
	var fps_sum := 0.0
	var orphans_max := 0
	for s in samples:
		var f := float(s["fps"])
		fps_min = minf(fps_min, f)
		fps_max = maxf(fps_max, f)
		fps_sum += f
		orphans_max = maxi(orphans_max, int(s["orphan_nodes"]))
	var first: Dictionary = samples[0]
	var last: Dictionary = samples[samples.size() - 1]
	return {
		"samples": samples.size(),
		"duration_ms": elapsed,
		"fps": {"min": fps_min, "avg": fps_sum / samples.size(), "max": fps_max},
		"memory_mb": {"start": first["static_memory_mb"], "end": last["static_memory_mb"],
			"delta": float(last["static_memory_mb"]) - float(first["static_memory_mb"])},
		"nodes": {"start": first["nodes"], "end": last["nodes"]},
		"orphan_nodes_peak": orphans_max,
		"draw_calls_last": last["draw_calls"],
	}


func _find_button(node: Node, needle: String) -> Button:
	if node is Button:
		var b := node as Button
		if not b.disabled and b.is_visible_in_tree() and needle in b.text.to_lower():
			return b
	for c in node.get_children():
		var hit := _find_button(c, needle)
		if hit != null:
			return hit
	return null


func _click(params: Dictionary) -> Dictionary:
	var text := String(params.get("text", "")).to_lower()
	if text == "":
		return {"__error": "click: 'text' is required"}
	var btn := _find_button(get_tree().root, text)
	if btn == null:
		return {"__error": "click: no visible enabled Button matching '%s'" % text}
	var path := String(btn.get_path())
	btn.pressed.emit()
	return {"clicked": true, "button_path": path, "button_text": btn.text}


func _input_event(params: Dictionary) -> Dictionary:
	var kind := String(params.get("kind", ""))
	var tap := bool(params.get("tap", true))
	match kind:
		"key":
			var key_name := String(params.get("key", ""))
			var code := OS.find_keycode_from_string(key_name)
			if code == KEY_NONE:
				return {"__error": "input: unknown key '%s' (use Godot key names, e.g. Enter, Escape, A)" % key_name}
			var ev := InputEventKey.new()
			ev.keycode = code
			ev.physical_keycode = code
			ev.pressed = true
			Input.parse_input_event(ev)
			if tap:
				await get_tree().process_frame
				var up := InputEventKey.new()
				up.keycode = code
				up.physical_keycode = code
				up.pressed = false
				Input.parse_input_event(up)
			return {"sent": "key", "key": key_name, "tap": tap}
		"mouse":
			var pos := Vector2(float(params.get("x", 0)), float(params.get("y", 0)))
			var btn_idx := int(params.get("button", MOUSE_BUTTON_LEFT))
			var down := InputEventMouseButton.new()
			down.position = pos
			down.global_position = pos
			down.button_index = btn_idx
			down.pressed = true
			Input.parse_input_event(down)
			if tap:
				await get_tree().process_frame
				var up := InputEventMouseButton.new()
				up.position = pos
				up.global_position = pos
				up.button_index = btn_idx
				up.pressed = false
				Input.parse_input_event(up)
			return {"sent": "mouse", "x": pos.x, "y": pos.y, "button": btn_idx, "tap": tap}
		"action":
			var action := String(params.get("action", ""))
			if not InputMap.has_action(action):
				return {"__error": "input: unknown action '%s'" % action}
			Input.action_press(action)
			if tap:
				await get_tree().process_frame
				Input.action_release(action)
			return {"sent": "action", "action": action, "tap": tap}
		_:
			return {"__error": "input: 'kind' must be key | mouse | action"}


## Poll until a condition holds: node exists (`node`), a visible enabled button
## matching `button_text` exists, or `property` {path,name,equals} matches.
func _wait(params: Dictionary) -> Dictionary:
	if not (params.has("node") or params.has("button_text") or params.has("property")):
		return {"__error": "wait: pass one of node | button_text | property{path,name,equals}"}
	var wait_ms := int(params.get("wait_ms", 5000))
	var poll_ms := maxi(25, int(params.get("poll_ms", 100)))
	var waited := 0
	var ok := _wait_condition(params)
	while not ok and waited < wait_ms:
		await get_tree().create_timer(float(poll_ms) / 1000.0).timeout
		waited += poll_ms
		ok = _wait_condition(params)
	return {"satisfied": ok, "waited_ms": waited}


func _wait_condition(params: Dictionary) -> bool:
	if params.has("node"):
		return get_node_or_null(String(params["node"])) != null
	if params.has("button_text"):
		return _find_button(get_tree().root, String(params["button_text"]).to_lower()) != null
	if params.has("property"):
		var p: Dictionary = params["property"]
		var n := get_node_or_null(String(p.get("path", "")))
		return n != null and str(n.get(String(p.get("name", "")))) == str(p.get("equals"))
	return false


func _perf(_params: Dictionary) -> Dictionary:
	return {
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"static_memory_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphan_nodes": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"video_memory_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
	}


func _capture(params: Dictionary) -> Dictionary:
	var save_dir := String(params.get("save_dir", ""))
	if save_dir == "":
		return {"__error": "capture: 'save_dir' is required"}
	var count := clampi(int(params.get("count", 8)), 1, 60)
	var interval_ms := clampi(int(params.get("interval_ms", 200)), 16, 2000)
	var prefix := String(params.get("prefix", "frame"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_dir) if save_dir.begins_with("user://") or save_dir.begins_with("res://") else save_dir)
	var paths: Array = []
	for i in count:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if img == null:
			return {"__error": "capture: no viewport image at frame %d" % i}
		var path := "%s/%s_%03d.png" % [save_dir.trim_suffix("/"), prefix, i]
		var err := img.save_png(path)
		if err != OK:
			return {"__error": "capture: save_png failed (err %d) for %s" % [err, path]}
		paths.append(path)
		if i < count - 1:
			await get_tree().create_timer(float(interval_ms) / 1000.0).timeout
	return {"frames": paths, "count": paths.size(), "interval_ms": interval_ms}
