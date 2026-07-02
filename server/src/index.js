#!/usr/bin/env node
// godot-mcp-foss — MCP stdio server in front of the godot-mcp-foss editor addon.
// One MCP tool per bridge method, schemas hand-written in tools.js.

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { FossClient, RpcError } from "./client.js";
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
    { name: "godot-mcp-foss", version: "0.1.0" },
    { capabilities: { tools: {} } }
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

  const known = new Set(TOOLS.map((t) => t.name));
  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const { name, arguments: args = {} } = req.params;
    try {
      if (name === "foss_call") {
        if (!args.method) return toError("foss_call requires 'method'.");
        return toContent(await client.call(args.method, args.params ?? {}));
      }
      if (!known.has(name)) return toError(`Unknown tool: ${name}`);
      const { timeout_ms, ...params } = args;
      const timeout = timeout_ms ?? TIMEOUTS[name] ?? null;
      return toContent(await client.call(name, params, timeout));
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
