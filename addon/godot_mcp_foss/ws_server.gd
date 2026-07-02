@tool
extends Node
## Embedded WebSocket JSON-RPC 2.0 server (editor side).
##
## DESIGN: the ADDON is the listening side, on ONE local port; the MCP bridge
## (or any client) dials in. This is deliberately the opposite of broadcast
## multi-port schemes: a single peer, a single port, trivial reconnection
## (the client just redials).
##
## Message shapes (JSON-RPC 2.0 over text frames):
##   request  : {"jsonrpc":"2.0","id":N,"method":"...","params":{...}}
##   response : {"jsonrpc":"2.0","id":N,"result":{...}}
##            | {"jsonrpc":"2.0","id":N,"error":{"code":C,"message":"..."}}
##   ping     : {"jsonrpc":"2.0","method":"ping"}   (no id — notification)
##   pong     : {"jsonrpc":"2.0","method":"pong"}
##
## Handlers may be coroutines (they can await); responses are correlated by id
## and sent whenever the handler completes, so a slow command never blocks the
## socket loop.

const DEFAULT_PORT := 6520
const BIND_ADDRESS := "127.0.0.1"   # local-only by design; no remote control

# JSON-RPC error codes.
const E_PARSE := -32700
const E_INVALID := -32600
const E_METHOD := -32601
const E_INTERNAL := -32603

var port: int = DEFAULT_PORT
var router: RefCounted = null   # router.gd instance

var _tcp := TCPServer.new()
var _peers: Array[WebSocketPeer] = []
var _ctrl_re: RegEx = null


func _ready() -> void:
	var env_port := OS.get_environment("GODOT_MCP_FOSS_PORT")
	if env_port != "" and env_port.is_valid_int():
		port = int(env_port)
	var err := _tcp.listen(port, BIND_ADDRESS)
	if err != OK:
		push_error("[mcp-foss] cannot listen on %s:%d (err %d)" % [BIND_ADDRESS, port, err])
	set_process(true)


func _exit_tree() -> void:
	for p in _peers:
		p.close()
	_tcp.stop()


func _process(_delta: float) -> void:
	while _tcp.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 8 * 1024 * 1024
		ws.outbound_buffer_size = 8 * 1024 * 1024
		if ws.accept_stream(_tcp.take_connection()) == OK:
			_peers.append(ws)

	for i in range(_peers.size() - 1, -1, -1):
		var ws: WebSocketPeer = _peers[i]
		ws.poll()
		match ws.get_ready_state():
			WebSocketPeer.STATE_OPEN, WebSocketPeer.STATE_CONNECTING:
				while ws.get_available_packet_count() > 0:
					_on_packet(ws, ws.get_packet())
			WebSocketPeer.STATE_CLOSED:
				_peers.remove_at(i)


func _on_packet(ws: WebSocketPeer, packet: PackedByteArray) -> void:
	var text := packet.get_string_from_utf8()
	var msg = JSON.parse_string(text)
	if msg == null or not (msg is Dictionary):
		_send(ws, {"jsonrpc": "2.0", "id": null,
			"error": {"code": E_PARSE, "message": "unparseable JSON"}})
		return
	var method := String(msg.get("method", ""))
	if method == "ping":
		_send(ws, {"jsonrpc": "2.0", "method": "pong"})
		return
	if method == "pong":
		return
	if not msg.has("id"):
		return   # unknown notification: ignore
	var id = msg["id"]
	if method == "":
		_send(ws, {"jsonrpc": "2.0", "id": id,
			"error": {"code": E_INVALID, "message": "missing method"}})
		return
	# Fire-and-forget coroutine: the handler may await freely; the response is
	# written whenever it finishes.
	_dispatch(ws, id, method, msg.get("params", {}))


func _dispatch(ws: WebSocketPeer, id, method: String, params) -> void:
	if router == null or not router.has_method_named(method):
		_send(ws, {"jsonrpc": "2.0", "id": id, "error": {
			"code": E_METHOD, "message": "unknown method '%s'" % method,
			"data": {"available_methods": [] if router == null else router.method_names()}}})
		return
	var p: Dictionary = params if params is Dictionary else {}
	# `await` tolerates non-coroutine handlers too: awaiting a plain value
	# returns it immediately, so sync and async handlers share one code path.
	var out = await router.invoke(method, p)
	if out is Dictionary and out.has("__error"):
		_send(ws, {"jsonrpc": "2.0", "id": id, "error": {
			"code": int(out.get("code", E_INTERNAL)), "message": String(out["__error"])}})
	else:
		_send(ws, {"jsonrpc": "2.0", "id": id, "result": out})


func _send(ws: WebSocketPeer, msg: Dictionary) -> void:
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	var text := JSON.stringify(msg)
	# Godot's JSON.stringify escapes \n and \" but LEAKS other raw control
	# bytes (CR, ANSI ESC, ...) straight through string values — strict JSON
	# parsers on the other end reject those. After stringify every legitimate
	# control char is already escaped, so any raw one left IS a leak: strip.
	if _ctrl_re == null:
		_ctrl_re = RegEx.new()
		_ctrl_re.compile("[\\x{00}-\\x{1F}]")
	ws.send_text(_ctrl_re.sub(text, "", true))
