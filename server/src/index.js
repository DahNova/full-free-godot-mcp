#!/usr/bin/env node
// godot-mcp-foss — MCP stdio server in front of the godot-mcp-foss editor addon.
// One MCP tool per bridge method, schemas hand-written in tools.js.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { FossClient, RpcError } from "./client.js";
import { launchEditor } from "./launcher.js";
import { TOOLS, TIMEOUTS } from "./tools.js";

const log = (...a) => process.stderr.write(`[mcp-foss] ${a.join(" ")}\n`);

const toContent = (v) => ({
  content: [{ type: "text", text: typeof v === "string" ? v : JSON.stringify(v, null, 2) }],
});
const toError = (m) => ({ content: [{ type: "text", text: m }], isError: true });

async function main() {
  if (process.argv.includes("--list-tools")) {
    for (const t of TOOLS) {
      const req = t.inputSchema.required ?? [];
      process.stdout.write(`${t.name}${req.length ? `  (required: ${req.join(",")})` : ""}\n`);
    }
    process.stdout.write(`\nTOTAL: ${TOOLS.length} tools\n`);
    return;
  }

  const client = new FossClient({
    port: process.env.GODOT_MCP_FOSS_PORT ? Number(process.env.GODOT_MCP_FOSS_PORT) : 6520,
  });
  client.start();

  const server = new Server(
    { name: "godot-mcp-foss", version: "0.4.0" },
    { capabilities: { tools: {} } }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

  const known = new Set(TOOLS.map((t) => t.name));
  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const { name, arguments: args = {} } = req.params;
    try {
      if (name === "editor_launch") {
        if (client.connected) return toContent({ already_running: true, connected: true });
        let info;
        try {
          info = launchEditor({ godotBin: args.godot_bin, project: args.project });
        } catch (e) {
          return toError(e.message);
        }
        const waitMs = args.wait_ms ?? 60000;
        const t0 = Date.now();
        while (!client.connected && Date.now() - t0 < waitMs) {
          await new Promise((r) => setTimeout(r, 500));
        }
        return toContent({ launched: true, ...info, connected: client.connected });
      }
      if (name === "foss_call") {
        if (!args.method) return toError("foss_call requires 'method'.");
        return toContent(await client.call(args.method, args.params ?? {}));
      }
      if (!known.has(name)) return toError(`Unknown tool: ${name}`);
      // timeout_ms is deliberately passed THROUGH to the addon too: the
      // game-relay commands budget their file-IPC wait from it.
      const timeout = args.timeout_ms ?? TIMEOUTS[name] ?? null;
      return toContent(await client.call(name, args, timeout));
    } catch (e) {
      if (e instanceof RpcError) return toError(`Godot bridge error ${e.code}: ${e.message}`);
      return toError(e.message);
    }
  });

  await server.connect(new StdioServerTransport());
  log("MCP server ready (stdio).");

  const shutdown = () => {
    client.stop();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((e) => {
  log(`fatal: ${e.stack || e.message}`);
  process.exit(1);
});
