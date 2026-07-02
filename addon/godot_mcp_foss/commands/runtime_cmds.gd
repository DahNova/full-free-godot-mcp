@tool
extends RefCounted
## Runtime commands: relay to the RUNNING game via the shared user:// dir.
##
## The played game opens no sockets. The editor and the game share the same
## user:// directory, so requests travel as small JSON files, each with its own
## correlation id in the FILENAME — concurrent commands cannot clobber each
## other (a defect of single-request-file designs). The game agent autoload
## (runtime/game_agent.gd, injected by the plugin) answers by writing the
## matching response file atomically (tmp + rename).

var _plugin: EditorPlugin


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin


func register(router: RefCounted) -> void:
	router.register("game_exec", func(p): return await _relay("exec", p, p.get("timeout_ms", 10000)),
		"Run GDScript inside the RUNNING game. Coroutines supported (await works). say(v) collects output; `return <value>` for a result.")
	router.register("game_screenshot", func(p): return await _relay("screenshot", p, p.get("timeout_ms", 5000)),
		"Save a PNG of the running game's viewport to save_path (required).")
	router.register("game_tree", func(p): return await _relay("tree", p, p.get("timeout_ms", 5000)),
		"Dump the LIVE game scene tree from an optional node path, depth-capped.")
	router.register("game_node", func(p): return await _relay("node_get", p, p.get("timeout_ms", 5000)),
		"Read a live node's properties (all script/editor properties, or just the names passed in props[]).")
	router.register("game_set", func(p): return await _relay("node_set", p, p.get("timeout_ms", 5000)),
		"Set one property on a live node; the JSON value is coerced onto the property's current type.")
	router.register("game_click", func(p): return await _relay("click", p, p.get("timeout_ms", 5000)),
		"Press the first visible, enabled Button whose text contains `text` (case-insensitive).")
	router.register("game_input", func(p): return await _relay("input", p, p.get("timeout_ms", 5000)),
		"Send a synthetic input event: key tap, mouse click at coordinates, or input-map action.")
	router.register("game_wait", func(p): return await _relay("wait", p, int(p.get("wait_ms", 5000)) + 3000),
		"Block until a node exists / a button with text is visible / a property equals a value, or wait_ms elapses.")
	router.register("game_perf", func(p): return await _relay("perf", p, p.get("timeout_ms", 5000)),
		"Snapshot the game's performance monitors: FPS, frame times, memory, node/orphan counts, draw calls.")
	router.register("game_capture", func(p): return await _relay("capture", p,
			int(p.get("count", 8)) * int(p.get("interval_ms", 200)) + 8000),
		"Capture a burst of sequential frames as PNGs into save_dir (for reviewing animations).")


func _relay(method: String, params: Dictionary, timeout_ms) -> Dictionary:
	if not EditorInterface.is_playing_scene():
		return {"__error": "%s: no scene is playing" % method}
	var id := "%d_%d" % [Time.get_ticks_usec(), randi() % 1000000]
	var req_path := "user://mcp_foss_req_%s.json" % id
	var res_path := "user://mcp_foss_res_%s.json" % id
	var f := FileAccess.open(req_path, FileAccess.WRITE)
	if f == null:
		return {"__error": "%s: cannot write request file" % method}
	var clean := params.duplicate()
	clean.erase("timeout_ms")
	f.store_string(JSON.stringify({"id": id, "method": method, "params": clean}))
	f.close()

	var waited_ms := 0
	var step_ms := 50
	while waited_ms < int(timeout_ms):
		await _plugin.get_tree().create_timer(float(step_ms) / 1000.0).timeout
		waited_ms += step_ms
		if FileAccess.file_exists(res_path):
			var rf := FileAccess.open(res_path, FileAccess.READ)
			var text := rf.get_as_text()
			rf.close()
			DirAccess.remove_absolute(ProjectSettings.globalize_path(res_path))
			var msg = JSON.parse_string(text)
			if msg is Dictionary:
				if msg.has("error"):
					return {"__error": String(msg["error"])}
				return msg.get("result", {})
			return {"__error": "%s: unparseable game response" % method}
		if not EditorInterface.is_playing_scene():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(req_path))
			return {"__error": "%s: game stopped before answering" % method}
	DirAccess.remove_absolute(ProjectSettings.globalize_path(req_path))
	return {"__error": "%s: game did not answer within %d ms (is the mcp-foss agent autoload present? was the game started AFTER enabling the plugin?)" % [method, int(timeout_ms)]}
