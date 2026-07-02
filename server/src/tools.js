// Hand-written MCP tool schemas — the whole point of the clean-room rewrite:
// every schema here is authored, typed, and documented by us; nothing is
// derived from any third-party addon.

const CODE_NOTE =
  " Coroutines are supported (await works). Plain print() goes to the Godot log, not here: use say(v) to collect lines, and end with `return <value>` for a result.";

export const TOOLS = [
  {
    name: "editor_status",
    description:
      "[editor] Liveness + introspection: engine version, project name, whether a scene is playing, and every available bridge method.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "editor_exec",
    description: "[editor] Run GDScript in the EDITOR process (EditorInterface is available)." + CODE_NOTE,
    inputSchema: {
      type: "object",
      properties: {
        code: { type: "string", description: "GDScript statements (the body of a function)." },
        timeout_ms: { type: "number", description: "Override the 30s default timeout." },
      },
      required: ["code"],
      additionalProperties: false,
    },
  },
  {
    name: "editor_log",
    description: "[editor] Tail the project log (user://logs/godot.log) — reflects the most recent run session.",
    inputSchema: {
      type: "object",
      properties: {
        max_lines: { type: "number", description: "Lines to return (default 120)." },
        filter: { type: "string", description: "Only lines containing this substring." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "editor_errors",
    description: "[editor] Error/warning lines from the project log.",
    inputSchema: {
      type: "object",
      properties: { max_lines: { type: "number", description: "Max error lines (default 60)." } },
      additionalProperties: false,
    },
  },
  {
    name: "editor_screenshot",
    description:
      "[editor] Save a PNG of the editor window and return its path + size. save_path is required by design — this bridge never returns base64 image blobs.",
    inputSchema: {
      type: "object",
      properties: { save_path: { type: "string", description: "Absolute (or user://) PNG destination." } },
      required: ["save_path"],
      additionalProperties: false,
    },
  },
  {
    name: "rescan_files",
    description: "[editor] Trigger a resource-filesystem rescan (after files changed outside the editor).",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "scene_tree",
    description: "[editor] Dump the EDITED scene's node tree (names, types, scripts), depth-capped.",
    inputSchema: {
      type: "object",
      properties: { max_depth: { type: "number", description: "Depth cap (default 6)." } },
      additionalProperties: false,
    },
  },
  {
    name: "run_scene",
    description:
      "[editor] Play a scene by res:// path. Deliberately refuses the no-arg main-scene boot unless force_main=true (booting every autoload floods output buffers; prefer a light scene path).",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "res:// path of the scene to play." },
        force_main: { type: "boolean", description: "Explicitly boot the full main scene." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "stop_scene",
    description: "[editor] Stop the playing scene.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "game_exec",
    description: "[game] Run GDScript inside the RUNNING game (a `scene_tree` var gives the live SceneTree)." + CODE_NOTE,
    inputSchema: {
      type: "object",
      properties: {
        code: { type: "string", description: "GDScript statements (the body of a function)." },
        timeout_ms: { type: "number", description: "Override the 10s default timeout." },
      },
      required: ["code"],
      additionalProperties: false,
    },
  },
  {
    name: "game_screenshot",
    description:
      "[game] Save a PNG of the running game's viewport (waits for a fully rendered frame). save_path required — never base64.",
    inputSchema: {
      type: "object",
      properties: { save_path: { type: "string", description: "Absolute (or user://) PNG destination." } },
      required: ["save_path"],
      additionalProperties: false,
    },
  },
  {
    name: "game_tree",
    description: "[game] Dump the LIVE scene tree from a node path (default /root), depth-capped.",
    inputSchema: {
      type: "object",
      properties: {
        from: { type: "string", description: "Starting node path (default /root)." },
        max_depth: { type: "number", description: "Depth cap (default 5)." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "game_node",
    description: "[game] Read a live node's properties (all script/editor props, or just props[]).",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute node path, e.g. /root/Main/Player." },
        props: { type: "array", items: { type: "string" }, description: "Specific property names." },
      },
      required: ["path"],
      additionalProperties: false,
    },
  },
  {
    name: "game_set",
    description:
      "[game] Set one property on a live node. The JSON value is coerced onto the property's current type (Vector2 accepts {x,y} or [x,y]; Color accepts {r,g,b,a} or a name).",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Absolute node path." },
        property: { type: "string", description: "Property name." },
        value: { description: "New value (JSON)." },
      },
      required: ["path", "property", "value"],
      additionalProperties: false,
    },
  },
  {
    name: "game_click",
    description: "[game] Press the first visible, enabled Button whose text contains `text` (case-insensitive).",
    inputSchema: {
      type: "object",
      properties: { text: { type: "string", description: "Substring of the button label." } },
      required: ["text"],
      additionalProperties: false,
    },
  },
  {
    name: "validate_scripts",
    description:
      "[editor] Compile-check GDScript files WITHOUT running anything — proactive parse-error detection. Defaults to every .gd under res:// (addons excluded); or pass paths[].",
    inputSchema: {
      type: "object",
      properties: {
        paths: { type: "array", items: { type: "string" }, description: "Specific res:// script paths." },
        include_addons: { type: "boolean", description: "Also check addons/ (default false)." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "run_tests",
    description:
      "[editor] Run the project's GUT test suite headless in a separate Godot process and return {all_passed, tests, passing, failing, tail}. Requires the GUT addon in the host project.",
    inputSchema: {
      type: "object",
      properties: {
        dir: { type: "string", description: "Test directory (default res://test/unit)." },
        timeout_ms: { type: "number", description: "Kill-wait budget (default 180000)." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "game_input",
    description:
      "[game] Send a synthetic input event: kind='key' (Godot key name, e.g. Enter/Escape/A), kind='mouse' (x,y + button), or kind='action' (input-map action). tap=true (default) sends press+release.",
    inputSchema: {
      type: "object",
      properties: {
        kind: { type: "string", enum: ["key", "mouse", "action"], description: "Event family." },
        key: { type: "string", description: "Key name for kind=key." },
        x: { type: "number", description: "Mouse x for kind=mouse." },
        y: { type: "number", description: "Mouse y for kind=mouse." },
        button: { type: "number", description: "Mouse button index (default 1 = left)." },
        action: { type: "string", description: "Input-map action for kind=action." },
        tap: { type: "boolean", description: "Press+release (default true); false = press only." },
      },
      required: ["kind"],
      additionalProperties: false,
    },
  },
  {
    name: "game_wait",
    description:
      "[game] Block until a condition holds or wait_ms elapses: a node exists, a visible enabled button matching button_text exists, or property {path,name,equals} matches. The clean way to ride out fades/async transitions before acting.",
    inputSchema: {
      type: "object",
      properties: {
        node: { type: "string", description: "Absolute node path that must exist." },
        button_text: { type: "string", description: "Button label substring that must be clickable." },
        property: {
          type: "object",
          properties: {
            path: { type: "string" },
            name: { type: "string" },
            equals: { description: "Stringified comparison value." },
          },
          description: "Property equality condition.",
        },
        wait_ms: { type: "number", description: "Max wait (default 5000)." },
        poll_ms: { type: "number", description: "Poll interval (default 100)." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "game_perf",
    description:
      "[game] Snapshot performance monitors: fps, process/physics ms, static memory MB, object/node/orphan-node/resource counts, draw calls, video memory MB. Catch leaks and runaways early.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "game_capture",
    description:
      "[game] Capture a burst of sequential frames as PNGs into save_dir (animation/juice review). Returns the frame paths.",
    inputSchema: {
      type: "object",
      properties: {
        save_dir: { type: "string", description: "Destination directory (absolute or user://)." },
        count: { type: "number", description: "Frames to capture, 1-60 (default 8)." },
        interval_ms: { type: "number", description: "Delay between frames, 16-2000 (default 200)." },
        prefix: { type: "string", description: "Filename prefix (default 'frame')." },
      },
      required: ["save_dir"],
      additionalProperties: false,
    },
  },
  {
    name: "run_task",
    description:
      "[editor] Run a PROJECT-DEFINED task from res://mcp_tasks.json (each task = a script implementing run(args), may await). Call with no name to list the project's tasks. This is the per-project automation surface: parity re-certs, content lints, balance smokes…",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Task name (omit to list available tasks)." },
        args: { type: "object", description: "Free-form args handed to the task.", additionalProperties: true },
        timeout_ms: { type: "number", description: "Override the 120s default." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "compare_shots",
    description:
      "[editor] Compare two PNG screenshots: exact-identical fast path, else downsampled pixel-diff ({changed_px_pct, diff_pct}). Visual-regression checks for UI work.",
    inputSchema: {
      type: "object",
      properties: {
        a: { type: "string", description: "First PNG path." },
        b: { type: "string", description: "Second PNG path." },
      },
      required: ["a", "b"],
      additionalProperties: false,
    },
  },
  {
    name: "game_run_script",
    description:
      "[game] Run a res:// GDScript FILE inside the running game (contract: extends RefCounted, func run(args) — may await; scene_tree injected if declared). Keep repeatable e2e drivers versioned in the repo.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "res:// path of the driver script." },
        args: { type: "object", description: "Free-form args handed to run().", additionalProperties: true },
        timeout_ms: { type: "number", description: "Override the 30s default." },
      },
      required: ["path"],
      additionalProperties: false,
    },
  },
  {
    name: "game_perf_series",
    description:
      "[game] Sample the performance monitors for duration_ms (interval_ms apart, max 100 samples) and return fps min/avg/max, memory start/end/delta, peak orphan nodes — catch leaks and hitches during real gameplay.",
    inputSchema: {
      type: "object",
      properties: {
        duration_ms: { type: "number", description: "Sampling window, 250-60000 (default 5000)." },
        interval_ms: { type: "number", description: "Sample spacing, 50-5000 (default 250)." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "foss_call",
    description:
      "[bridge] Escape hatch: invoke any bridge method by name with free-form params (see editor_status.methods).",
    inputSchema: {
      type: "object",
      properties: {
        method: { type: "string", description: "Bridge method name." },
        params: { type: "object", description: "Free-form parameters.", additionalProperties: true },
      },
      required: ["method"],
      additionalProperties: false,
    },
  },
];

// Per-tool default timeouts (ms) where the 30s default is wrong.
export const TIMEOUTS = {
  game_exec: 15000,
  game_screenshot: 8000,
  game_tree: 8000,
  game_node: 8000,
  game_set: 8000,
  game_click: 8000,
  game_input: 8000,
  game_wait: 70000,     // the addon relay already budgets wait_ms + 3s
  game_perf: 8000,
  game_capture: 130000, // the addon relay budgets count*interval + 8s
  run_tests: 200000,
  validate_scripts: 60000,
  run_task: 120000,
  game_run_script: 35000,
  game_perf_series: 70000, // the addon relay already budgets duration_ms + 5s
};
