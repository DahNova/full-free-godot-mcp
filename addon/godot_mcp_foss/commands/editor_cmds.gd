@tool
extends RefCounted
## Editor-process commands: status/introspection, GDScript execution (with
## coroutine support), log access, screenshot, filesystem rescan.

const J := preload("res://addons/godot_mcp_foss/utils/jsonify.gd")

var _plugin: EditorPlugin
var _router: RefCounted
var _test_threads: Array = []   # keep timed-out test threads referenced


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
	router.register("validate_scripts", _validate_scripts,
		"Compile-check GDScript files (all of res:// or just paths[]) without running anything; returns the files that fail to parse.")
	router.register("run_tests", _run_tests,
		"Run the project's GUT test suite headless in a separate process and return the parsed summary.")


func _validate_scripts(params: Dictionary) -> Dictionary:
	var paths: Array = params.get("paths", [])
	var include_addons := bool(params.get("include_addons", false))
	if paths.is_empty():
		paths = _collect_scripts("res://", include_addons, [])
	var failed: Array = []
	var checked := 0
	for p in paths:
		var path := String(p)
		if not FileAccess.file_exists(path):
			failed.append({"path": path, "error": "file not found"})
			continue
		# Re-read + re-parse from disk INSIDE the project context (class_name
		# and cyclic preload chains resolve normally — a detached compile of
		# the raw source would false-positive on those). null = parse/load
		# failure; the details land in the editor log (see editor_errors).
		var scr = ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_REPLACE)
		checked += 1
		if scr == null:
			failed.append({"path": path, "error": "failed to load/parse (see editor_errors)"})
	return {"checked": checked, "failed": failed, "ok": failed.is_empty()}


func _collect_scripts(dir_path: String, include_addons: bool, acc: Array) -> Array:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return acc
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var full := dir_path.path_join(fname)
		if dir.current_is_dir():
			if not fname.begins_with(".") and (include_addons or fname != "addons"):
				_collect_scripts(full, include_addons, acc)
		elif fname.ends_with(".gd"):
			acc.append(full)
		fname = dir.get_next()
	dir.list_dir_end()
	return acc


func _run_tests(params: Dictionary):
	if not FileAccess.file_exists("res://addons/gut/gut_cmdln.gd"):
		return {"__error": "run_tests: GUT is not installed in this project (res://addons/gut missing)"}
	var dir := String(params.get("dir", "res://test/unit"))
	var timeout_ms := int(params.get("timeout_ms", 180000))
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "addons/gut/gut_cmdln.gd", "-gdir=%s" % dir, "-ginclude_subdirs", "-gexit"]
	# OS.execute blocks, so it runs on a worker thread while this coroutine
	# keeps the editor responsive by awaiting scene-tree timers.
	var result := {"output": [], "code": -1}
	var t := Thread.new()
	t.start(func() -> void:
		var out := []
		result["code"] = OS.execute(OS.get_executable_path(), args, out, true, false)
		result["output"] = out
	)
	var waited := 0
	while t.is_alive() and waited < timeout_ms:
		await _plugin.get_tree().create_timer(0.25).timeout
		waited += 250
	if t.is_alive():
		_test_threads.append(t)   # cannot kill OS.execute portably; detach
		return {"__error": "run_tests: timed out after %d ms (the test process may still be running)" % timeout_ms}
	t.wait_to_finish()
	var text := ""
	for chunk in result["output"]:
		text += String(chunk)
	# Readability: drop CRs and ANSI color sequences from the GUT output.
	text = text.replace("\r", "")
	var ansi := RegEx.new()
	ansi.compile("\\x{1B}\\[[0-9;]*m")
	text = ansi.sub(text, "", true)
	var lines := text.split("\n")
	var tail := lines.slice(maxi(0, lines.size() - 25), lines.size())
	return {
		"exit_code": int(result["code"]),
		"all_passed": "All tests passed" in text,
		"tests": _count_after(text, "Tests"),
		"passing": _count_after(text, "Passing"),
		"failing": _count_after(text, "Failing"),
		"tail": Array(tail),
		"seconds": float(waited) / 1000.0,
	}


func _count_after(text: String, label: String) -> int:
	var re := RegEx.new()
	re.compile(label + "\\s+(\\d+)")
	var m := re.search(text)
	return int(m.get_string(1)) if m != null else -1


func _status(_params: Dictionary) -> Dictionary:
	return {
		"engine": Engine.get_version_info()["string"],
		"addon": "godot-mcp-foss 0.2.0",
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
	var lines := f.get_as_text().replace("\r", "").split("\n")
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
