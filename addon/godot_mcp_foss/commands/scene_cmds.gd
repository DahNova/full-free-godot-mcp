@tool
extends RefCounted
## Scene commands: inspect the edited scene, start/stop the game.

const J := preload("res://addons/godot_mcp_foss/utils/jsonify.gd")

var _plugin: EditorPlugin


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin


func register(router: RefCounted) -> void:
	router.register("scene_tree", _scene_tree,
		"Dump the EDITED scene's node tree (name/type/children), depth-capped.")
	router.register("run_scene", _run_scene,
		"Play a scene by res:// path. Running the MAIN scene requires force_main=true (booting every autoload floods buffers — prefer a light scene).")
	router.register("stop_scene", _stop_scene,
		"Stop the currently playing scene.")


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


func _scene_tree(params: Dictionary):
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return {"__error": "scene_tree: no scene is being edited"}
	var max_depth := int(params.get("max_depth", 6))
	return {"scene": String(root.scene_file_path), "tree": _walk(root, 0, max_depth)}


func _run_scene(params: Dictionary):
	var path := String(params.get("path", ""))
	var force_main := bool(params.get("force_main", false))
	if EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	if path != "":
		if not ResourceLoader.exists(path):
			return {"__error": "run_scene: scene not found: %s" % path}
		EditorInterface.play_custom_scene(path)
		return {"playing": path}
	if force_main:
		EditorInterface.play_main_scene()
		return {"playing": "<main scene>"}
	return {"__error": "run_scene: pass a scene 'path', or force_main=true to boot the full main scene (heavy: every autoload starts and output buffers fill fast)"}


func _stop_scene(_params: Dictionary) -> Dictionary:
	var was := EditorInterface.is_playing_scene()
	if was:
		EditorInterface.stop_playing_scene()
	return {"stopped": was}
