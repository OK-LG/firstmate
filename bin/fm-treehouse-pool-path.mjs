import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { parse } from "./vendor/smol-toml/parse.js";

function stat(file) {
  try {
    return fs.lstatSync(file);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function git(dir, ...args) {
  return execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

function config(file) {
  if (!stat(file)) return null;
  const parsed = parse(fs.readFileSync(file, "utf8"));
  const result = {};
  for (const [key, value] of Object.entries(parsed)) {
    const name = key.toLowerCase();
    if (!["root", "max_trees", "hooks"].includes(name)) continue;
    if (Object.prototype.hasOwnProperty.call(result, name)) throw new Error("ambiguous Treehouse configuration");
    result[name] = value;
  }
  if (result.root !== undefined && typeof result.root !== "string") throw new Error("invalid root");
  if (result.max_trees !== undefined && !Number.isSafeInteger(result.max_trees)) throw new Error("invalid max_trees");
  if (result.hooks !== undefined) {
    if (!result.hooks || typeof result.hooks !== "object" || Array.isArray(result.hooks)) throw new Error("invalid hooks");
    for (const [key, value] of Object.entries(result.hooks)) {
      if (["post_create", "pre_destroy"].includes(key.toLowerCase()) &&
          (!Array.isArray(value) || value.some(item => typeof item !== "string"))) throw new Error("invalid hook");
    }
  }
  return result;
}

function resolvePool(project) {
  const top = git(project, "rev-parse", "--show-toplevel");
  const local = config(path.join(top, "treehouse.toml"));
  const global = config(path.join(os.homedir(), ".config", "treehouse", "config.toml"));
  const root = (local ?? global)?.root ?? "";
  let poolRoot = path.join(os.homedir(), ".treehouse");
  if (root) {
    const expanded = root.replace(/\$(?:\{([^}]*)\}|([*#$@!?0-9-])|([A-Za-z_][A-Za-z0-9_]*)|(\{))/g,
      (_, braced, special, name, invalid) => invalid ? "" : (process.env[braced ?? special ?? name] ?? ""));
    poolRoot = path.resolve(top, expanded, ".treehouse");
  }
  let identity;
  try { identity = git(top, "remote", "get-url", "origin"); }
  catch { identity = top; }
  const hash = createHash("sha256").update(identity).digest("hex").slice(0, 6);
  return path.join(poolRoot, `${path.basename(top)}-${hash}`);
}

try {
  const [project, worktree] = process.argv.slice(2);
  if (!worktree || !stat(worktree)) process.exit(1);
  const real = fs.realpathSync(worktree);
  const claim = stat(path.join(path.dirname(real), ".fm-slot-owner"));
  if (!stat(path.join(real, ".git"))) process.exit(claim ? 2 : 1);
  git(real, "rev-parse", "--git-dir");
  const statePath = path.join(resolvePool(project), "treehouse-state.json");
  const stateStat = stat(statePath);
  const matches = [];
  if (stateStat) {
    if (!stateStat.isFile()) process.exit(2);
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
    if (!state || typeof state !== "object" || Array.isArray(state)) process.exit(2);
    const entries = state.worktrees ?? [];
    if (!Array.isArray(entries)) process.exit(2);
    for (const entry of entries) {
      if (!entry || typeof entry.name !== "string" || typeof entry.path !== "string" ||
          !path.isAbsolute(entry.path) || /[\r\n\0]/.test(entry.path)) process.exit(2);
      let candidate;
      try { candidate = fs.realpathSync(entry.path); }
      catch (error) {
        if (error.code === "ENOENT") continue;
        throw error;
      }
      if (candidate !== real) continue;
      if (entry.destroying) process.exit(2);
      matches.push(entry.path);
    }
  }
  if (matches.length > 1) process.exit(2);
  if (!matches.length) process.exit(claim ? 2 : 1);
  process.stdout.write(matches[0] + "\n");
} catch {
  process.exit(2);
}
