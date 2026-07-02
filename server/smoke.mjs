// Smoke test for the godot-mcp-foss addon over raw WebSocket JSON-RPC.
import WebSocket from "ws";

const SHOTS = process.env.SHOT_DIR;
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

  if (!wasPlaying) {
    await check("run_scene title", () => call("run_scene", { path: "res://game/flow/game_root.tscn" }));
    await new Promise((r) => setTimeout(r, 4000)); // let the game boot
    await check("game_tree", async () => {
      const r = await call("game_tree", { max_depth: 2 });
      return { from: r.from, root: r.tree?.name };
    });
    await check("game_exec await", () =>
      call("game_exec", {
        code: "await scene_tree.create_timer(0.2).timeout\nsay('game says hi')\nreturn scene_tree.root.get_child_count()",
      })
    );
    await check("game_click PLAY", () => call("game_click", { text: "PLAY" }));
    await new Promise((r) => setTimeout(r, 1200));
    await check("game_screenshot", () => call("game_screenshot", { save_path: `${SHOTS}/foss_game.png` }));
    await check("game_node", async () => {
      const r = await call("game_node", { path: "/root/GameRoot", props: ["name"] });
      return r;
    });
    await check("stop_scene", () => call("stop_scene"));
  } else {
    results.push("SKIP game_* tests: a scene is already playing (not mine to stop)");
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
