// WebSocket JSON-RPC 2.0 client toward the godot-mcp-foss editor addon.
//
// The ADDON listens (one local port); we dial in and keep redialing with a
// gentle backoff, so editor restarts heal on their own. Requests are
// correlated by id; a ping notification every few seconds doubles as a
// liveness probe (the addon answers pong).

import WebSocket from "ws";

const log = (...a) => process.stderr.write(`[mcp-foss] ${a.join(" ")}\n`);

export class RpcError extends Error {
  constructor(code, message, data) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

export class FossClient {
  constructor({ port = 6520, host = "127.0.0.1", defaultTimeoutMs = 30000 } = {}) {
    this.url = `ws://${host}:${port}`;
    this.defaultTimeoutMs = defaultTimeoutMs;
    this.ws = null;
    this.connected = false;
    this.nextId = 1;
    this.pending = new Map(); // id -> {resolve, reject, timer}
    this.backoffMs = 500;
    this.pingTimer = null;
    this.stopped = false;
  }

  start() {
    this._dial();
    this.pingTimer = setInterval(() => {
      if (this.connected) this._notify("ping");
    }, 5000);
  }

  stop() {
    this.stopped = true;
    clearInterval(this.pingTimer);
    if (this.ws) this.ws.close();
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(new RpcError(-32001, "client stopped"));
    }
    this.pending.clear();
  }

  _dial() {
    if (this.stopped) return;
    const ws = new WebSocket(this.url);
    this.ws = ws;
    ws.on("open", () => {
      this.connected = true;
      this.backoffMs = 500;
      log(`connected to ${this.url}`);
    });
    ws.on("message", (data) => this._onMessage(String(data)));
    ws.on("error", () => {});
    ws.on("close", () => {
      const was = this.connected;
      this.connected = false;
      if (was) log("connection lost; will keep retrying");
      for (const [, p] of this.pending) {
        clearTimeout(p.timer);
        p.reject(new RpcError(-32002, "connection to the Godot editor was lost mid-call"));
      }
      this.pending.clear();
      if (!this.stopped) {
        setTimeout(() => this._dial(), this.backoffMs);
        this.backoffMs = Math.min(this.backoffMs * 2, 8000);
      }
    });
  }

  _onMessage(text) {
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    if (msg.method === "ping") return this._notify("pong");
    if (msg.method === "pong") return;
    if (msg.id == null || !this.pending.has(msg.id)) return;
    const p = this.pending.get(msg.id);
    this.pending.delete(msg.id);
    clearTimeout(p.timer);
    if (msg.error) {
      p.reject(new RpcError(msg.error.code ?? -32603, msg.error.message ?? "error", msg.error.data));
    } else {
      p.resolve(msg.result);
    }
  }

  _notify(method) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", method }));
    }
  }

  call(method, params = {}, timeoutMs = null) {
    if (!this.connected) {
      return Promise.reject(
        new RpcError(
          -32003,
          `not connected to the Godot editor (${this.url}). Is the editor open with the godot-mcp-foss plugin enabled?`
        )
      );
    }
    const id = this.nextId++;
    const deadline = timeoutMs ?? this.defaultTimeoutMs;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new RpcError(-32004, `'${method}' timed out after ${deadline} ms`));
      }, deadline);
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }
}
