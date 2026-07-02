@tool
extends RefCounted
## Editor-process commands: status/introspection, GDScript execution (with
## coroutine support), log access, screenshot, filesystem rescan.

const J := preload("res://addons/godot_mcp_foss/utils/jsonify.gd")

var _plugin: EditorPlugin
var _router: RefCounted


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin


func register(router: RefCounted) -> void:
	_router = router
	router.register("editor_status", _status,
		"Editor/addon liveness: versions, project, play state, available methods.")
	router.register("editor_exec", _exec,
		"Run GDScript in the EDITOR process. Coroutines supported (await works). Use say(v) to collect output lines; end with `return <value>` for a result.")
	router.register("editor_log", _log,
		"Tail the project log file (user://logs/godot.log). Reflects the most recent run.")
	router.register("editor_errors", _errors,
		"Error/warning lines from the project log file.")
	router.register("editor_screenshot", _screenshot,
		"Save a PNG of the whole editor window to save_path (required). Returns metadata only.")
	router.register("rescan_files", _rescan,
		"Trigger a resource-filesystem scan (picks up files changed outside the editor).")


func _status(_params: Dictionary) -> Dictionary:
	return {
		"engine": Engine.get_version_info()["string"],
		"addon": "godot-mcp-foss 0.1.0",
		"project": String(ProjectSettings.get_setting("application/config/name", "")),
		"playing": EditorInterface.is_playing_scene(),
		"methods": _router.describe() if _router != null else {},
	}


func _exec(params: Dictionary):
	var code := String(params.get("code", ""))
	if code.strip_edges() == "":
		return {"__error": "editor_exec: 'code' is required"}
	var src := "\n".join([
		"@tool",
		"extends RefCounted",
		"var prints := []",
		"func say(v) -> void:",
		"\tprints.append(str(v))",
		"func run():",
		J.embed_body(code, 1),
	])
	var scr := GDScript.new()
	scr.source_code = src
	var err := scr.reload()
	if err != OK:
		return {"__error": "editor_exec: code failed to parse (err %d). Check indentation and syntax." % err}
	var inst = scr.new()
	# `await` on a plain value returns it immediately, so this one line serves
	# both sync code and code that awaits signals/timers.
	var value = await inst.run()
	return {"value": J.jsonify(value), "prints": inst.prints.duplicate()}


func _read_log_tail(max_lines: int) -> Array:
	var path := "user://logs/godot.log"
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var lines := f.get_as_text().split("\n")
	var start: int = maxi(0, lines.size() - max_lines)
	return Array(lines.slice(start, lines.size()))


func _log(params: Dictionary) -> Dictionary:
	var max_lines := int(params.get("max_lines", 120))
	var filter := String(params.get("filter", ""))
	var lines := _read_log_tail(max_lines * 4 if filter != "" else max_lines)
	if filter != "":
		var kept := []
		for l in lines:
			if filter in String(l):
				kept.append(l)
		lines = kept.slice(maxi(0, kept.size() - max_lines), kept.size())
	return {"lines": lines, "source": "user://logs/godot.log"}


func _errors(params: Dictionary) -> Dictionary:
	var max_lines := int(params.get("max_lines", 60))
	var lines := _read_log_tail(2000)
	var kept := []
	for l in lines:
		var s := String(l)
		if "ERROR" in s or "WARNING" in s or "SCRIPT ERROR" in s or "Parse Error" in s:
			kept.append(s)
	kept = kept.slice(maxi(0, kept.size() - max_lines), kept.size())
	return {"errors": kept, "count": kept.size(), "source": "user://logs/godot.log"}


func _screenshot(params: Dictionary):
	var save_path := String(params.get("save_path", ""))
	if save_path == "":
		return {"__error": "editor_screenshot: 'save_path' is required (this addon never returns base64 blobs)"}
	var img := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	if img == null:
		return {"__error": "editor_screenshot: no viewport image available"}
	var err := img.save_png(save_path)
	if err != OK:
		return {"__error": "editor_screenshot: save_png failed (err %d) for %s" % [err, save_path]}
	return {"saved_path": save_path, "width": img.get_width(), "height": img.get_height()}


func _rescan(_params: Dictionary) -> Dictionary:
	EditorInterface.get_resource_filesystem().scan()
	return {"scanning": true}
