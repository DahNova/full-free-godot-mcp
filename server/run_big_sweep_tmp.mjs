import WebSocket from "ws";
const ws = new WebSocket("ws://127.0.0.1:6520");
let id = 0;
const pending = new Map();
const call = (m, p, t = 30000) =>
  new Promise((res, rej) => {
    const i = ++id;
    const tm = setTimeout(() => rej(new Error(m + " timeout")), t);
    pending.set(i, { res, rej, tm });
    ws.send(JSON.stringify({ jsonrpc: "2.0", id: i, method: m, params: p }));
  });
ws.on("message", (d) => {
  const m = JSON.parse(String(d));
  if (m.method === "ping") return ws.send(JSON.stringify({ jsonrpc: "2.0", method: "pong" }));
  if (!pending.has(m.id)) return;
  const p = pending.get(m.id);
  pending.delete(m.id);
  clearTimeout(p.tm);
  m.error ? p.rej(new Error(m.error.message)) : p.res(m.result);
});
ws.on("open", async () => {
  try {
    const r = await call(
      "run_task",
      {
        name: "difficulty_sweep",
        args: {
          heroes: ["warden", "ravager", "trickster", "channeler", "beastspeaker"],
          seeds: [1337, 4242, 90210],
          strategies: ["safe", "greedy"],
        },
      },
      2700000
    );
    console.log(JSON.stringify(r.value, null, 1));
  } catch (e) {
    console.error("ERROR:", e.message);
  }
  ws.close();
  process.exit(0);
});
ws.on("error", (e) => {
  console.error("cannot connect:", e.message);
  process.exit(2);
});
