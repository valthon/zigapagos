import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { loadConfig, routeToFile, type ParityConfig } from "./parity/config.ts";
import { canonicalize, renderNodes, type NormalizeOptions } from "./parity/normalize.ts";
import { diffNodes, diffProps, lineDiff, type RouteResult } from "./parity/diff.ts";
import type { SNode } from "../src/testing/parity/serialize.ts";
import type { IslandProps } from "./parity/normalize.ts";

function slug(route: string): string { return route === "/" ? "index" : route.replace(/^\/+|\/+$/g, "").replace(/\//g, "_"); }
function opts(cfg: ParityConfig): NormalizeOptions {
  return cfg.classHashPattern ? { classHashPattern: new RegExp(cfg.classHashPattern) } : {};
}
function readRoute(baseDir: string, dir: string, route: string): string {
  return readFileSync(join(baseDir, dir, routeToFile(route)), "utf8");
}

export function runCapture(cfg: ParityConfig, baseDir: string): void {
  const goldenDir = join(baseDir, "parity", "golden");
  mkdirSync(goldenDir, { recursive: true });
  for (const r of cfg.routes) {
    const c = canonicalize(readRoute(baseDir, cfg.reference.path, r.path), opts(cfg));
    // Store the canonical NODES (so `check` can do a full structured diffNodes) + props.
    writeFileSync(join(goldenDir, `${slug(r.path)}.nodes.json`), JSON.stringify(c.nodes));
    writeFileSync(join(goldenDir, `${slug(r.path)}.props.json`), JSON.stringify(c.props, null, 2));
  }
}

export function runCheck(cfg: ParityConfig, baseDir: string): { ok: boolean; routes: RouteResult[] } {
  const goldenDir = join(baseDir, "parity", "golden");
  const reportDir = join(baseDir, "parity", "report");
  const results: RouteResult[] = [];
  for (const r of cfg.routes) {
    const goldenNodesFile = join(goldenDir, `${slug(r.path)}.nodes.json`);
    if (!existsSync(goldenNodesFile)) throw new Error(`parity: no golden for ${r.path} — run \`parity capture\` first`);
    const goldenNodes = JSON.parse(readFileSync(goldenNodesFile, "utf8")) as SNode[];
    const goldenProps = JSON.parse(readFileSync(join(goldenDir, `${slug(r.path)}.props.json`), "utf8")) as IslandProps[];
    const build = canonicalize(readRoute(baseDir, cfg.build.outDir, r.path), opts(cfg));
    const structural = diffNodes(goldenNodes, build.nodes);   // full node-level structured diff
    const props = diffProps(goldenProps, build.props);
    const ok = structural.length === 0 && props.length === 0;
    const res: RouteResult = {
      route: r.path, ok, structural, props,
      domDiff: ok ? "" : lineDiff(renderNodes(goldenNodes), renderNodes(build.nodes)),
    };
    results.push(res);
    const rd = join(reportDir, slug(r.path));
    mkdirSync(rd, { recursive: true });
    writeFileSync(join(rd, "result.json"), JSON.stringify(res, null, 2));
    if (res.domDiff) writeFileSync(join(rd, "dom.diff"), res.domDiff);
  }
  const ok = results.every((r) => r.ok);
  mkdirSync(reportDir, { recursive: true });
  writeFileSync(join(reportDir, "summary.json"), JSON.stringify({ ok, routes: results.map((r) => ({ route: r.route, ok: r.ok })) }, null, 2));
  return { ok, routes: results };
}

// CLI entry
if (import.meta.main) {
  const [cmd, ...rest] = process.argv.slice(2);
  // Validate cmd BEFORE loadConfig — prevents an ENOENT crash on a bad or missing command.
  if (cmd !== "capture" && cmd !== "check") {
    console.error("usage: parity <capture|check> [--config parity.config.json]");
    process.exit(2);
  }
  // Fix: when --config is absent indexOf returns -1, so -1+1=0 would wrongly grab rest[0].
  const ci = rest.indexOf("--config");
  const cfgPath = (ci !== -1 ? rest[ci + 1] : undefined) || "parity.config.json";
  const cfg = loadConfig(cfgPath);
  const baseDir = dirname(cfgPath) || ".";
  if (cmd === "capture") { runCapture(cfg, baseDir); console.log("parity: goldens captured"); }
  else {
    const { ok, routes } = runCheck(cfg, baseDir);
    for (const r of routes) console.log(`${r.ok ? "✓" : "✗"} ${r.route}${r.ok ? "" : ` — ${r.structural.length} structural / ${r.props.length} prop mismatches`}`);
    if (!ok) { console.error("parity: FAIL — see parity/report/"); process.exit(1); }
    console.log("parity: PASS");
  }
}
