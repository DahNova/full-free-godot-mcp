# full-free-godot-mcp

**Open-source MCP stack for Godot 4.x** (project codename `godot-mcp-foss`) — an editor addon (GDScript) plus an
MCP stdio server (Node) that let an AI assistant (or any JSON-RPC client)
inspect and drive the Godot editor **and the running game**. MIT licensed,
written **from scratch** (clean-room: no code, names or schemas from any
commercial addon).

> Stato: **v0.3.0 — funzionante.** 28/28 smoke checks live su Godot 4.4.1.

## Layout

```
addon/godot_mcp_foss/    Godot editor plugin (copy into <project>/addons/)
  plugin.gd              bootstrap: WS server + runtime agent autoload
  ws_server.gd           WebSocket JSON-RPC 2.0 server (listen 127.0.0.1:6520)
  router.gd              method registry + introspection
  commands/              editor_cmds / scene_cmds / runtime_cmds (game relay)
  runtime/game_agent.gd  game-side agent (file-IPC with correlation ids)
  utils/jsonify.gd       value serialization / coercion / code re-indent
server/                  MCP stdio bridge (Node, deps: ws + MCP SDK)
  src/index.js           MCP server, hand-written tool schemas (tools.js)
  src/client.js          WS client: reconnect, heartbeat, id correlation, timeouts
  smoke.mjs              live smoke test against a running editor
docs/PROTOCOL.md         wire protocol + method reference
```

## Setup

1. Copy `addon/godot_mcp_foss/` into your project's `addons/` and enable the
   **Godot MCP FOSS** plugin (Project → Plugins). It starts listening on
   `ws://127.0.0.1:6520` and injects the runtime agent autoload.
2. `cd server && npm install`
3. Register in your MCP client, e.g. `.mcp.json`:

```json
{
  "mcpServers": {
    "godot-foss": {
      "command": "node",
      "args": ["<path>/godot-mcp-foss/server/src/index.js"]
    }
  }
}
```

Port override on both sides: `GODOT_MCP_FOSS_PORT`.

## The 26 tools

`editor_status` · `editor_exec` · `editor_log` · `editor_errors` ·
`editor_screenshot` · `rescan_files` · `validate_scripts` · `run_tests` ·
`run_task` · `compare_shots` · `scene_tree` · `run_scene` · `stop_scene` ·
`game_exec` · `game_run_script` · `game_screenshot` · `game_tree` ·
`game_node` · `game_set` · `game_click` · `game_input` · `game_wait` ·
`game_perf` · `game_perf_series` · `game_capture` · `foss_call` (escape hatch)

The v0.3 additions make the stack *project-aware*:

- **`run_task`** — the host project declares its own automation surface in
  `res://mcp_tasks.json` (each task = a versioned script with `run(args)`);
  the AI invokes rituals by name: parity re-certs, content lints, balance
  smokes. Nothing project-specific ever leaks into the addon.
- **`game_run_script`** — run a versioned res:// driver file inside the
  running game: repeatable e2e scenarios live in the repo, not in chat.
- **`compare_shots`** — PNG diff (identical fast path + downsampled
  percentage): visual-regression checks for UI work.
- **`game_perf_series`** — sampled fps/memory/orphans over a window: catch
  leaks and hitches during real gameplay, not just at a single instant.

The v0.2 additions target the whole edit-test-observe loop, not just remote
control:

- **`run_tests`** — the addon spawns a headless Godot child process, runs the
  project's GUT suite and returns the parsed summary. CI-grade feedback
  without leaving the conversation.
- **`validate_scripts`** — proactive parse check of every `.gd` from disk,
  in project context. Catch the typo before booting anything.
- **`game_wait`** — wait for a node / clickable button / property value:
  replaces "sleep and hope" around fades and async transitions.
- **`game_input`** — synthetic key/mouse/action events for flows a
  button-click can't reach.
- **`game_perf`** — fps, frame times, memory, orphan nodes, draw calls in one
  snapshot: leak and runaway detection while you play.
- **`game_capture`** — a burst of sequential frames for reviewing animations
  and VFX timing.

Design choices that differ from prior art on purpose:

- **`await` works** inside `editor_exec`/`game_exec` — handlers are
  coroutines end-to-end (`await inst.run()` handles sync and async code with
  one line).
- **Screenshots never return base64**: `save_path` is required; you get back
  a path + dimensions.
- **`run_scene` refuses the blind main-scene boot** unless `force_main=true`
  (booting every autoload floods output buffers) — play a light scene by path.
- **Runtime file-IPC carries the correlation id in the filename** and writes
  responses atomically (tmp+rename): concurrent commands can't clobber each
  other, and half-written replies can't be read.
- **Log access reads the log file** (`user://logs/godot.log`) instead of
  scraping editor UI internals that break across Godot versions.
- The addon binds **127.0.0.1 only**; the game agent is **inert in exported
  builds**.

## Smoke test

With the editor open and the plugin enabled:

```
cd server && node smoke.mjs
```

Editor-side checks always run. To also exercise the game-side tools, point it
at a light scene of your project (and optionally a button label it shows):

```
SMOKE_SCENE=res://main_menu.tscn SMOKE_BUTTON=PLAY node smoke.mjs
```

## License

MIT — see [LICENSE](LICENSE).
