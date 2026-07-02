@tool
extends EditorPlugin
## Godot MCP FOSS — editor bootstrap.
##
## Starts the embedded WebSocket JSON-RPC server (see ws_server.gd), registers
## the command modules on the router, and injects the runtime game agent as an
## autoload so a played scene can answer runtime commands over the shared
## user:// file channel. Everything is cleaned up on plugin disable.

const AGENT_AUTOLOAD_NAME := "GodotMcpFossAgent"
const AGENT_PATH := "res://addons/godot_mcp_foss/runtime/game_agent.gd"

const WsServer := preload("res://addons/godot_mcp_foss/ws_server.gd")
const Router := preload("res://addons/godot_mcp_foss/router.gd")
const EditorCmds := preload("res://addons/godot_mcp_foss/commands/editor_cmds.gd")
const SceneCmds := preload("res://addons/godot_mcp_foss/commands/scene_cmds.gd")
const RuntimeCmds := preload("res://addons/godot_mcp_foss/commands/runtime_cmds.gd")

var _server: Node = null
# Command modules are RefCounted and Callables hold only weak object ids —
# keep them referenced here or the router would dispatch into freed objects.
var _modules: Array = []


func _enter_tree() -> void:
	var router := Router.new()
	_modules = [EditorCmds.new(self), SceneCmds.new(self), RuntimeCmds.new(self)]
	for m in _modules:
		m.register(router)

	_server = WsServer.new()
	_server.name = "GodotMcpFossServer"
	_server.router = router
	add_child(_server)

	add_autoload_singleton(AGENT_AUTOLOAD_NAME, AGENT_PATH)
	print("[mcp-foss] plugin enabled — listening on ws://127.0.0.1:%d" % _server.port)


func _exit_tree() -> void:
	remove_autoload_singleton(AGENT_AUTOLOAD_NAME)
	if _server != null:
		_server.queue_free()
		_server = null
	_modules.clear()
	print("[mcp-foss] plugin disabled")
