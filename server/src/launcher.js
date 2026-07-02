// Editor launcher — the one capability that cannot live in the addon: when
// the Godot editor is closed (or crashed), something OUTSIDE it must be able
// to bring it back. Spawns the editor detached on the project and lets the
// WS client's redial loop pick the addon up when it's listening.

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";

// Resolve the Godot binary: explicit arg > GODOT_BIN env > PATH lookup names.
export function resolveGodotBin(explicit) {
  const candidates = [explicit, process.env.GODOT_BIN, "godot", "godot4"].filter(Boolean);
  for (const c of candidates) {
    if (c.includes("/") || c.includes("\\")) {
      if (existsSync(c)) return c;
    } else {
      return c; // bare name: let the OS PATH resolve it at spawn time
    }
  }
  return null;
}

// Resolve the project root (dir with project.godot): explicit arg >
// GODOT_PROJECT_ROOT env > walk up from cwd.
export function resolveProjectRoot(explicit) {
  const seeds = [explicit, process.env.GODOT_PROJECT_ROOT, process.cwd()].filter(Boolean);
  for (const seed of seeds) {
    let dir = seed;
    for (let i = 0; i < 12; i++) {
      if (existsSync(join(dir, "project.godot"))) return dir;
      const parent = dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  }
  return null;
}

// Spawn the editor detached. Returns {bin, project} or throws with a clear
// message about what to configure.
export function launchEditor({ godotBin, project } = {}) {
  const bin = resolveGodotBin(godotBin);
  if (!bin) {
    throw new Error(
      "Godot binary not found. Pass godot_bin, or set GODOT_BIN in the MCP server env."
    );
  }
  const root = resolveProjectRoot(project);
  if (!root) {
    throw new Error(
      "project.godot not found. Pass project, or set GODOT_PROJECT_ROOT in the MCP server env."
    );
  }
  const child = spawn(bin, ["--editor", "--path", root], {
    detached: true,
    stdio: "ignore",
  });
  child.unref();
  return { bin, project: root, pid: child.pid };
}
