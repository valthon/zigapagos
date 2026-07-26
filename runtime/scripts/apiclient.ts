// apiclient.ts — the codegen dispatcher for ZigBase-native (`mode: "zigbase"`)
// codegen. Reads contract/codegen.config.json and, in zigbase mode, drives the
// backend's own `gen-client` output as the typed client:
//
//   api-gen   (gen):   run the backend gen-client, vendor its output into `out`.
//   api-check (check): re-generate + diff against the committed `out` (drift
//                      gate). If the backend project is absent, fall back to a
//                      LOUD presence/pin gate (committed client present +
//                      non-empty + its schema-hash logged) — never a silent pass.
//
// openapi mode is NOT handled here — build.zig keeps its existing apigen wiring
// for openapi (byte-identical to before). This script is only wired for zigbase mode.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, mkdirSync, statSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { loadCodegenConfig, type CodegenConfig, type ZigbaseCodegenConfig } from "./codegen-config.ts";

/** Extract the `// schema-hash: <hash>` value from a vendored zbase.gen.ts. */
export function extractSchemaHash(src: string): string | null {
  const m = src.match(/^\/\/\s*schema-hash:\s*(\S+)\s*$/m);
  return m ? m[1] : null;
}

/** A command runner — injectable so unit tests can stub the subprocess. */
export type Runner = (cmd: string[], cwd: string) => void;

const defaultRunner: Runner = (cmd, cwd) => {
  const [exe, ...args] = cmd;
  execFileSync(exe, args, { cwd, stdio: "inherit" });
};

export interface ClientDeps {
  /** Runs genClientCmd; defaults to execFileSync (stdio inherited). */
  runner?: Runner;
  /** Base dir that cwd-relative config paths resolve against (default process.cwd()). */
  baseDir?: string;
  /** Sink for human-facing log lines (default console.log). */
  log?: (msg: string) => void;
}

function resolvePaths(zb: ZigbaseCodegenConfig, baseDir: string) {
  const genClientCwd = resolve(baseDir, zb.genClientCwd);
  const out = resolve(baseDir, zb.out);
  // Where the command writes: producedPath (relative to genClientCwd) when set,
  // else the command is expected to write `out` directly.
  const produced = zb.producedPath ? join(genClientCwd, zb.producedPath) : out;
  return { genClientCwd, out, produced };
}

function backendPresent(genClientCwd: string): boolean {
  return existsSync(genClientCwd) && statSync(genClientCwd).isDirectory();
}

/**
 * api-gen (zigbase): run the backend gen-client and vendor its output into `out`.
 * Requires the backend project to be present (you cannot refresh from an absent
 * backend — that is a hard error, not the check-time fallback).
 */
export function apiGen(cfg: CodegenConfig, deps: ClientDeps = {}): void {
  const zb = requireZigbase(cfg);
  const runner = deps.runner ?? defaultRunner;
  const log = deps.log ?? ((m: string) => console.log(m));
  const baseDir = deps.baseDir ?? process.cwd();
  const { genClientCwd, out, produced } = resolvePaths(zb, baseDir);

  if (!backendPresent(genClientCwd)) {
    throw new Error(
      `api-gen (zigbase): backend project not found at ${genClientCwd} — cannot refresh the vendored client. ` +
        `Check out the backend or fix zigbase.genClientCwd in contract/codegen.config.json.`,
    );
  }

  log(`api-gen (zigbase): running ${zb.genClientCmd.join(" ")} in ${genClientCwd}`);
  runner(zb.genClientCmd, genClientCwd);

  if (produced !== out) {
    if (!existsSync(produced)) {
      throw new Error(
        `api-gen (zigbase): gen-client did not produce ${produced} (zigbase.producedPath); nothing to vendor.`,
      );
    }
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, readFileSync(produced));
    log(`api-gen (zigbase): vendored ${produced} -> ${out}`);
  } else {
    if (!existsSync(out)) {
      throw new Error(`api-gen (zigbase): gen-client did not produce ${out}.`);
    }
    log(`api-gen (zigbase): gen-client wrote ${out} directly`);
  }

  const hash = extractSchemaHash(readFileSync(out, "utf8"));
  log(`api-gen (zigbase): committed client schema-hash: ${hash ?? "(none found)"}`);
}

/**
 * api-check (zigbase): drift gate. Re-run gen-client and diff the fresh output
 * against the committed `out`. Divergence => throws (non-zero exit).
 *
 * Backend-absent fallback: assert the committed client is present + non-empty +
 * log its schema-hash. LOUD (the diff is skipped and said so) — never silent.
 *
 * Non-destructive: when the command writes `out` directly (no producedPath), the
 * committed content is saved and restored around the regeneration.
 */
export function apiCheck(cfg: CodegenConfig, deps: ClientDeps = {}): void {
  const zb = requireZigbase(cfg);
  const runner = deps.runner ?? defaultRunner;
  const log = deps.log ?? ((m: string) => console.log(m));
  const baseDir = deps.baseDir ?? process.cwd();
  const { genClientCwd, out, produced } = resolvePaths(zb, baseDir);

  // ── Backend-absent fallback: weaker presence/pin gate, but LOUD ──────────────
  if (!backendPresent(genClientCwd)) {
    if (!existsSync(out)) {
      throw new Error(
        `api-check (zigbase): backend absent at ${genClientCwd} AND the committed client ${out} is missing. ` +
          `The vendored client must be committed so the repo builds without the backend. FAIL.`,
      );
    }
    const committed = readFileSync(out, "utf8");
    if (committed.trim().length === 0) {
      throw new Error(
        `api-check (zigbase): backend absent at ${genClientCwd} AND the committed client ${out} is empty. FAIL.`,
      );
    }
    const hash = extractSchemaHash(committed);
    log(
      `api-check (zigbase): WARNING backend project not found at ${genClientCwd}. ` +
        `Skipping the drift diff and falling back to a PRESENCE gate: committed client ${out} ` +
        `is present + non-empty (schema-hash: ${hash ?? "(none found)"}). ` +
        `Drift vs the backend was NOT verified — check the backend out and re-run for full coverage.`,
    );
    return;
  }

  // ── Backend present: full drift gate ────────────────────────────────────────
  const committed = existsSync(out) ? readFileSync(out) : null;

  log(`api-check (zigbase): running ${zb.genClientCmd.join(" ")} in ${genClientCwd}`);
  let fresh: Buffer | null = null;
  try {
    runner(zb.genClientCmd, genClientCwd);
    // Read the fresh output BEFORE the finally restores `out` (they are the same
    // file on the direct-write path).
    if (existsSync(produced)) fresh = readFileSync(produced);
  } finally {
    // Non-destructive on EVERY exit path — including a gen-client that WRITES
    // `out` and THEN exits non-zero, which makes `runner` throw. Restoring only
    // on the normal path would silently leave the developer's committed client
    // replaced by the backend's partial output: a dirty tree with no message.
    if (produced === out) {
      if (committed !== null) writeFileSync(out, committed);
      // Nothing was committed: a direct-write gen-client just CREATED `out`.
      // Remove it so a failed check leaves no untracked file behind.
      else if (existsSync(out)) rmSync(out);
    }
  }

  if (fresh === null) {
    throw new Error(`api-check (zigbase): gen-client did not produce ${produced}.`);
  }

  if (committed === null) {
    throw new Error(
      `api-check (zigbase): committed client ${out} is missing but the backend generated a client. ` +
        `Run api-gen to vendor it, then commit. FAIL.`,
    );
  }

  if (!fresh.equals(committed)) {
    // Render a human diff (best-effort) before failing.
    showDiff(out, produced, log);
    const freshHash = extractSchemaHash(fresh.toString("utf8"));
    const committedHash = extractSchemaHash(committed.toString("utf8"));
    throw new Error(
      `api-check (zigbase): DRIFT — the backend's gen-client output differs from the committed ${out}. ` +
        `committed schema-hash: ${committedHash ?? "(none)"}, backend schema-hash: ${freshHash ?? "(none)"}. ` +
        `Run api-gen and commit the refreshed client. FAIL.`,
    );
  }

  const hash = extractSchemaHash(committed.toString("utf8"));
  log(`api-check (zigbase): OK — committed client matches the backend (schema-hash: ${hash ?? "(none)"}).`);
}

function requireZigbase(cfg: CodegenConfig): ZigbaseCodegenConfig {
  if (cfg.mode !== "zigbase" || !cfg.zigbase) {
    throw new Error(`apiclient: expected zigbase mode config (got mode=${cfg.mode}).`);
  }
  return cfg.zigbase;
}

/** Best-effort human diff via `git diff --no-index`; never throws. */
function showDiff(committedPath: string, freshPath: string, log: (m: string) => void): void {
  try {
    execFileSync("git", ["diff", "--no-index", "--", committedPath, freshPath], { stdio: "inherit" });
  } catch {
    // git diff --no-index exits non-zero on differences; that is expected here.
    log("(diff rendered above)");
  }
}

// CLI: bun apiclient.ts <gen|check> [--config <path>]
if (import.meta.main) {
  const args = process.argv.slice(2);
  const sub = args[0];
  let configPath = "contract/codegen.config.json";
  for (let i = 1; i < args.length; i++) {
    if (args[i] === "--config") configPath = args[++i] ?? configPath;
  }
  if (sub !== "gen" && sub !== "check") {
    console.error("Usage: apiclient.ts <gen|check> [--config <path>]");
    process.exit(1);
  }
  const cfg = loadCodegenConfig(configPath);
  if (cfg.mode !== "zigbase") {
    console.error(`apiclient: mode is "${cfg.mode}", not "zigbase"; this dispatcher only handles zigbase mode.`);
    process.exit(1);
  }
  try {
    if (sub === "gen") apiGen(cfg);
    else apiCheck(cfg);
  } catch (e) {
    console.error(e instanceof Error ? e.message : String(e));
    process.exit(1);
  }
}
