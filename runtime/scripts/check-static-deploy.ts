#!/usr/bin/env bun
/** Read-only HTTP rehearsal against an already running static host.
 * No server configuration is applied, and no browser/backend behavior is tested. */
import { readdirSync, readFileSync, realpathSync } from "node:fs";
import { join, sep, extname, resolve } from "node:path";
import {
  assertSafeManifest, collectChunkPaths, cspHeaderValue,
  scanInlineScriptHashes, scanInlineStyleHashes, scanExternalLinkOrigins,
  hasInlineSpeculationRules, FINGERPRINT_SUFFIX_PATTERN,
  IMMUTABLE_CACHE_CONTROL, REVALIDATE_CACHE_CONTROL,
  type Manifest,
} from "./emit-host-config.ts";

export type Finding = { code: string; path: string; message: string };
export type Probe = { path: string; file: string; mime: string; cache: string; html: boolean };
export type Plan = { site: string; base: URL; csp: string; probes: Probe[] };
export type Report = { ok: boolean; checked: number; findings: Finding[] };
const MIME: Record<string, string[]> = {
  ".html": ["text/html"], ".css": ["text/css"],
  ".js": ["text/javascript", "application/javascript"],
  ".mjs": ["text/javascript", "application/javascript"],
};

function filesUnder(root: string): string[] {
  const files: string[] = [];
  function visit(dir: string): void {
    for (const entry of readdirSync(join(root, dir), { withFileTypes: true })) {
      const name = join(dir, entry.name);
      if (entry.isSymbolicLink()) throw new Error(`symlink is unsupported: ${name}; use a release tree of regular files`);
      if (entry.isDirectory()) visit(name);
      else if (entry.isFile()) files.push(name.split(sep).join("/"));
    }
  }
  visit("");
  return files.sort();
}

function fileFromRoute(route: string): string {
  if (!route.startsWith("/") || route.split("/").some((p) => p === "." || p === "..")) {
    throw new Error(`unsafe manifest file path: ${route}`);
  }
  return route.slice(1);
}

/** Build a plan without contacting the host. Manifest paths are tree-relative;
 * the URL argument supplies the mount and must agree with every SPA manifest. */
export function planChecks(site: string, url: string): Plan {
  const base = new URL(url);
  if (!["http:", "https:"].includes(base.protocol) || base.username || base.password || base.search || base.hash) {
    throw new Error("--url must be an HTTP(S) mount URL without credentials, query, or fragment");
  }
  if (!base.pathname.endsWith("/")) base.pathname += "/";
  const prefix = decodeURIComponent(base.pathname).replace(/\/$/, "");
  site = realpathSync(site);
  const files = filesUnder(site);
  const fileSet = new Set(files);
  const htmls = files.filter((f) => extname(f) === ".html").map((f) => readFileSync(join(site, f), "utf8"));
  if (!htmls.length) throw new Error("release tree contains no HTML to verify");
  const manifests: Manifest[] = files.filter((f) => f.endsWith("/routing-manifest.json") || f === "routing-manifest.json").map((f) => {
    const m = JSON.parse(readFileSync(join(site, f), "utf8")) as Manifest;
    assertSafeManifest(m);
    if ((m.url_path_prefix ?? "") !== prefix) throw new Error(`mount ${JSON.stringify(prefix)} disagrees with ${f} prefix ${JSON.stringify(m.url_path_prefix ?? "")}`);
    return m;
  });
  const immutable = new Set(collectChunkPaths(manifests));
  const csp = cspHeaderValue(scanInlineScriptHashes(htmls), scanExternalLinkOrigins(htmls), scanInlineStyleHashes(htmls), hasInlineSpeculationRules(htmls));
  const probes = new Map<string, Probe>();
  function add(path: string, file: string): void {
    if (!fileSet.has(file)) throw new Error(`manifest references missing release file: ${file}`);
    const html = extname(file) === ".html";
    const requestPath = prefix + path;
    const cache = !html && (immutable.has(requestPath) || new RegExp(FINGERPRINT_SUFFIX_PATTERN).test(file))
      ? IMMUTABLE_CACHE_CONTROL : REVALIDATE_CACHE_CONTROL;
    const probe = { path, file, mime: MIME[extname(file)]?.[0] ?? "", cache, html };
    const prior = probes.get(path);
    if (prior && prior.file !== file) throw new Error(`ambiguous probe ${path}: ${prior.file} versus ${file}`);
    probes.set(path, probe);
  }
  for (const file of files) {
    if (!MIME[extname(file)]) continue;
    // Directory-index URLs exercise the same path a visitor opens.
    const path = "/" + file.replace(/(^|\/)index\.html$/, "$1");
    add(path, file);
  }
  for (const m of manifests) {
    for (const asset of [m.bundle, ...Object.values(m.chunks ?? {}), ...(m.immutableAssets ?? [])]) {
      if (!asset.startsWith(prefix + "/")) throw new Error(`manifest asset outside mount: ${asset}`);
      const file = fileFromRoute(asset.slice(prefix.length));
      if (!fileSet.has(file)) throw new Error(`manifest references missing release file: ${file}`);
    }
    for (const route of m.dynamic) {
      const path = route.pattern.split("/").map((p) => p.startsWith(":") || p === "*" ? "__zigapagos_probe__" : p).join("/");
      add(path, fileFromRoute(route.shell));
    }
    // Probe the namespace fallback only if it cannot select a dynamic route.
    const path = m.base.replace(/\/$/, "") + "/__zigapagos_fallback__/";
    const matchesDynamic = m.dynamic.some((route) => {
      const pattern = route.pattern.split("/").map((p) => p === "*" ? ".*" : p.startsWith(":") ? "[^/]+" : p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("/");
      return new RegExp("^" + pattern.replace(/\/$/, "") + "/?$").test(path);
    });
    if (!matchesDynamic) add(path, fileFromRoute(m.fallback));
  }
  return { site, base, csp, probes: [...probes.values()].sort((a, b) => a.path.localeCompare(b.path)) };
}

// Compare directive/token sets so harmless whitespace and ordering don't fail.
// Deliberately reject custom/stricter policies: this checks the generated policy,
// not whether an arbitrary alternative is secure or browser-compatible.
function normalizedCsp(value: string): string | null {
  const directives = new Map<string, string>();
  for (const part of value.split(";")) {
    const [name, ...tokens] = part.trim().split(/\s+/);
    if (!name) continue;
    // Browsers use the first occurrence of a directive, so duplicates cannot
    // be normalized as an unordered set. Keep the name in the first position.
    if (directives.has(name)) return null;
    directives.set(name, [name, ...tokens.sort()].join(" "));
  }
  return [...directives.values()].sort().join(";");
}
function normalizedCache(value: string): string {
  return value.toLowerCase().split(",").map((d) => d.trim()).sort().join(",");
}

export async function checkDeployment(plan: Plan, timeoutMs = 10000): Promise<Report> {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120000) throw new Error("timeout must be between 1 and 120000 ms");
  const findings: Finding[] = [];
  for (const probe of plan.probes) {
    const add = (code: string, message: string) => findings.push({ code, path: probe.path, message });
    // Encode each filesystem segment, never let ?, #, %, or backslashes become
    // URL syntax. URL resolution must stay under the specified mount.
    const url = new URL(probe.path.slice(1).split("/").map(encodeURIComponent).join("/"), plan.base);
    if (url.origin !== plan.base.origin || !url.pathname.startsWith(plan.base.pathname)) throw new Error(`probe escapes mount: ${probe.path}`);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let response: Response | undefined;
    try {
      response = await fetch(url, { redirect: "manual", signal: controller.signal, headers: { "Cache-Control": "no-cache" } });
      if (response.status !== 200) {
        add("status", `expected 200, received ${response.status}${response.headers.has("location") ? ` (redirect to ${response.headers.get("location")}; redirects are not followed)` : ""}`);
        continue;
      }
      const mime = response.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase() ?? "";
      if (!MIME[extname(probe.file)]?.includes(mime)) add("mime", `expected ${probe.mime}, received ${mime || "no Content-Type"}`);
      const cache = response.headers.get("cache-control") ?? "";
      if (normalizedCache(cache) !== normalizedCache(probe.cache)) add("cache", `expected ${probe.cache}, received ${cache || "no Cache-Control"}`);
      if (probe.html && normalizedCsp(response.headers.get("content-security-policy") ?? "") !== normalizedCsp(plan.csp)) {
        add("csp", "Content-Security-Policy differs from the generated site-wide policy (custom/stricter policies require separate review)");
      }
      const expected = readFileSync(join(plan.site, probe.file));
      const reader = response.body?.getReader();
      let offset = 0;
      let equal = !!reader;
      if (reader) {
        try {
          while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            if (offset + value.length > expected.length || !expected.subarray(offset, offset + value.length).equals(value)) {
              equal = false;
              break;
            }
            offset += value.length;
          }
        } finally {
          await reader.cancel();
        }
      }
      if (!equal || offset !== expected.length) add("bytes", `served bytes differ from ${probe.file}; possible stale deploy or wrong fallback`);
    } catch (error) {
      add("request", controller.signal.aborted ? `request exceeded ${timeoutMs} ms` : String(error));
    } finally {
      if (response?.body && !response.body.locked) await response.body.cancel();
      clearTimeout(timer);
    }
  }
  return { ok: findings.length === 0, checked: plan.probes.length, findings };
}

if (import.meta.main) {
  try {
    const args = process.argv.slice(2);
    let site = "", url = "", json = false, timeout = 10000;
    for (let i = 0; i < args.length; i++) {
      if (args[i] === "--site") site = args[++i] ?? "";
      else if (args[i] === "--url") url = args[++i] ?? "";
      else if (args[i] === "--json") json = true;
      else if (args[i] === "--timeout-ms") timeout = Number(args[++i]);
      else throw new Error(`unknown argument ${args[i]}`);
    }
    if (!site || !url || !Number.isSafeInteger(timeout) || timeout < 1 || timeout > 120000) throw new Error("usage: check-static-deploy.ts --site <release-tree> --url <http(s)://host/mount/> [--json] [--timeout-ms 10000]");
    const result = await checkDeployment(planChecks(resolve(site), url), timeout);
    if (json) console.log(JSON.stringify(result, null, 2));
    else {
      for (const finding of result.findings) console.error(`${finding.code}: ${finding.path}: ${finding.message}`);
      console.log(`${result.ok ? "PASS" : "FAIL"}: checked ${result.checked} HTTP paths against the release tree and generated header policy`);
    }
    process.exitCode = result.ok ? 0 : 1;
  } catch (error) {
    console.error(String(error));
    process.exitCode = 2;
  }
}
