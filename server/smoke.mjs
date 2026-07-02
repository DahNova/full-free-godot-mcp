// Smoke test for the godot-mcp-foss addon over raw WebSocket JSON-RPC.
//
// Env (all optional):
//   SHOT_DIR     where screenshots/captures are written (default: os tmpdir)
//   SMOKE_SCENE  res:// scene to play for the game-side checks (skipped if unset)
//   SMOKE_BUTTON label substring of a button that scene shows (wait+click checks)
import WebSocket from "ws";
import { tmpdir } from "node:os";

const SHOTS = (process.env.SHOT_DIR ?? tmpdir()).replaceAll("\\", "/");
const SCENE = process.env.SMOKE_SCENE ?? "";
const BUTTON = process.env.SMOKE_BUTTON ?? "";
const GAME_SCRIPT = process.env.SMOKE_GAME_SCRIPT ?? ""; // res:// driver for game_run_script
const ws = new WebSocket("ws://127.0.0.1:6520");
let id = 0;
const pending = new Map();

function call(method, params = {}, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const myId = ++id;
    const timer = setTimeout(() => {
      pending.delete(myId);
      reject(new Error(`${method} timed out`));
    }, timeoutMs);
    pending.set(myId, { resolve, reject, timer });
    ws.send(JSON.stringify({ jsonrpc: "2.0", id: myId, method, params }));
  });
}

ws.on("message", (d) => {
  const m = JSON.parse(String(d));
  if (m.method === "ping") return ws.send(JSON.stringify({ jsonrpc: "2.0", method: "pong" }));
  if (m.id == null || !pending.has(m.id)) return;
  const p = pending.get(m.id);
  pending.delete(m.id);
  clearTimeout(p.timer);
  m.error ? p.reject(new Error(`[${m.error.code}] ${m.error.message}`)) : p.resolve(m.result);
});

const results = [];
const check = async (label, fn, expectError = false) => {
  try {
    const r = await fn();
    results.push(`${expectError ? "FAIL(no-error)" : "PASS"} ${label}: ${JSON.stringify(r).slice(0, 200)}`);
  } catch (e) {
    results.push(`${expectError ? "PASS(expected-error)" : "FAIL"} ${label}: ${e.message.slice(0, 200)}`);
  }
};

ws.on("open", async () => {
  const status = await call("editor_status");
  results.push(`PASS editor_status: engine=${status.engine} playing=${status.playing} methods=${Object.keys(status.methods).length}`);
  const wasPlaying = status.playing;

  await check("editor_exec sync", () => call("editor_exec", { code: "say('hello')\nreturn 2 + 40" }));
  await check("editor_exec await", () =>
    call("editor_exec", {
      code: "await Engine.get_main_loop().create_timer(0.3).timeout\nreturn 'awaited-ok'",
    })
  );
  await check("editor_exec parse error", () => call("editor_exec", { code: "this is not gdscript (" }), true);
  await check("editor_errors", async () => {
    const r = await call("editor_errors", { max_lines: 5 });
    return { count: r.count };
  });
  await check("scene_tree", async () => {
    const r = await call("scene_tree", { max_depth: 1 });
    return { scene: r.scene ?? "none" };
  });
  await check("run_scene guard", () => call("run_scene", {}), true);
  await check("editor_screenshot", () => call("editor_screenshot", { save_path: `${SHOTS}/foss_editor.png` }));
  await check("unknown method", () => call("no_such_method"), true);
  await check("validate_scripts", async () => {
    const r = await call("validate_scripts", {}, 60000);
    return { checked: r.checked, ok: r.ok, failed: r.failed };
  });
  await check("run_tests", async () => {
    const r = await call("run_tests", {}, 200000);
    return { all_passed: r.all_passed, tests: r.tests, passing: r.passing };
  });
  await check("compare_shots identical", async () => {
    const r = await call("compare_shots", { a: `${SHOTS}/foss_editor.png`, b: `${SHOTS}/foss_editor.png` });
    if (!r.identical) throw new Error("same file must be identical");
    return r;
  });
  if (status.has_task_manifest) {
    await check("run_task list", async () => {
      const r = await call("run_task", {});
      return { tasks: Object.keys(r.tasks) };
    });
  } else {
    await check("run_task no manifest", () => call("run_task", {}), true);
  }

  if (!wasPlaying && SCENE) {
    await check("run_scene", () => call("run_scene", { path: SCENE }));
    await check("game_wait", async () => {
      const cond = BUTTON ? { button_text: BUTTON } : { node: "/root" };
      const r = await call("game_wait", { ...cond, wait_ms: 15000 }, 20000);
      if (!r.satisfied) throw new Error("wait condition never satisfied");
      return r;
    });
    await check("game_tree", async () => {
      const r = await call("game_tree", { max_depth: 2 });
      return { from: r.from, root: r.tree?.name };
    });
    await check("game_perf", async () => {
      const r = await call("game_perf");
      if (typeof r.fps !== "number") throw new Error("no fps in perf snapshot");
      return { fps: r.fps, nodes: r.nodes, orphans: r.orphan_nodes, mem_mb: Math.round(r.static_memory_mb) };
    });
    await check("game_input key", () => call("game_input", { kind: "key", key: "F" }));
    await check("game_input action", () => call("game_input", { kind: "action", action: "ui_accept" }));
    await check("game_input bad key", () => call("game_input", { kind: "key", key: "NotAKey" }), true);
    await check("game_capture", async () => {
      const r = await call("game_capture", { save_dir: SHOTS, count: 4, interval_ms: 150, prefix: "burst" }, 30000);
      return { count: r.count, first: r.frames?.[0] };
    });
    await check("game_exec await", () =>
      call("game_exec", {
        code: "await scene_tree.create_timer(0.2).timeout\nsay('game says hi')\nreturn scene_tree.root.get_child_count()",
      })
    );
    await check("game_perf_series", async () => {
      const r = await call("game_perf_series", { duration_ms: 1500, interval_ms: 250 }, 10000);
      return { samples: r.samples, fps_avg: Math.round(r.fps.avg), mem_delta: r.memory_mb.delta.toFixed(2) };
    });
    if (GAME_SCRIPT) {
      await check("game_run_script", async () => {
        const r = await call("game_run_script", { path: GAME_SCRIPT });
        return r.value;
      });
    }
    if (BUTTON) {
      await check("game_click", () => call("game_click", { text: BUTTON }));
      await new Promise((r) => setTimeout(r, 1200));
    }
    await check("game_screenshot", () => call("game_screenshot", { save_path: `${SHOTS}/foss_game.png` }));
    await check("game_node", async () => {
      const r = await call("game_node", { path: "/root", props: ["name"] });
      return r;
    });
    await check("stop_scene", () => call("stop_scene"));
  } else {
    results.push(
      wasPlaying
        ? "SKIP game_* tests: a scene is already playing (not mine to stop)"
        : "SKIP game_* tests: set SMOKE_SCENE (and optionally SMOKE_BUTTON) to enable them"
    );
  }

  console.log(results.join("\n"));
  const fails = results.filter((r) => r.startsWith("FAIL")).length;
  console.log(`\n${results.length} checks, ${fails} FAIL`);
  ws.close();
  process.exit(fails ? 1 : 0);
});

ws.on("error", (e) => {
  console.error("cannot connect:", e.message);
  process.exit(2);
});
