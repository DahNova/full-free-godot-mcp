# godot-mcp-foss — wire protocol

## Transport

- The **addon is the WebSocket server**: it listens on `ws://127.0.0.1:6520`
  (override with the `GODOT_MCP_FOSS_PORT` env var, read by both sides).
  Local-only by design — the bind address is hardcoded to `127.0.0.1`.
- The **MCP bridge is the client** and redials with backoff, so editor
  restarts heal on their own. Single port, single peer expected (multiple
  peers are tolerated).

## Messages — JSON-RPC 2.0 over text frames

```
request   {"jsonrpc":"2.0","id":1,"method":"editor_status","params":{}}
response  {"jsonrpc":"2.0","id":1,"result":{...}}
error     {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"...","data":{...}}}
ping      {"jsonrpc":"2.0","method":"ping"}     (notification, no id)
pong      {"jsonrpc":"2.0","method":"pong"}
```

Error codes: `-32700` parse, `-32600` invalid request, `-32601` unknown method
(with `data.available_methods`), `-32603` command failure. Client-side codes:
`-32001..-32004` (stopped / connection lost / not connected / timeout).

Handlers are coroutines: a slow command (or one that awaits signals/timers)
never blocks the socket loop; responses are correlated by `id` and sent when
the handler completes.

## Methods (15)

| method | params | notes |
|---|---|---|
| `editor_status` | — | engine/project/playing + full method map (introspection) |
| `editor_exec` | `code` | runs in the editor process; `await` supported; `say(v)` collects lines; `return <v>` for a value |
| `editor_log` | `max_lines?`, `filter?` | tail of `user://logs/godot.log` |
| `editor_errors` | `max_lines?` | ERROR/WARNING lines from the log |
| `editor_screenshot` | `save_path` | **required** — never returns base64 |
| `rescan_files` | — | resource-filesystem scan |
| `scene_tree` | `max_depth?` | EDITED scene dump |
| `run_scene` | `path?`, `force_main?` | no-arg main-scene boot is refused unless `force_main` (autoload/log flood guard) |
| `stop_scene` | — | |
| `game_exec` | `code` | runs in the game; a `scene_tree` var exposes the live `SceneTree`; `await` supported |
| `game_screenshot` | `save_path` | waits `RenderingServer.frame_post_draw` first |
| `game_tree` | `from?`, `max_depth?` | live tree dump |
| `game_node` | `path`, `props?` | property read |
| `game_set` | `path`, `property`, `value` | JSON value coerced onto the property's current type |
| `game_click` | `text` | presses the first visible enabled Button whose text contains `text` |

## Runtime channel (editor ⇄ game)

The played game opens **no sockets**. Editor and game share the project's
`user://` directory, so runtime commands travel as JSON files **with the
correlation id in the filename**:

```
user://mcp_foss_req_<id>.json    editor → game   {"id","method","params"}
user://mcp_foss_res_<id>.json    game → editor   {"id","result"|"error"}
```

The game agent (autoload injected by the plugin) polls at 20 Hz, deletes the
request once read, and writes the response **atomically** (tmp file + rename)
so the editor can never read a half-written reply. Id-in-filename means
concurrent commands cannot clobber each other. Stale `mcp_foss_*` files are
swept at game start. The agent is inert in exported builds
(`OS.has_feature("editor")` gate).
