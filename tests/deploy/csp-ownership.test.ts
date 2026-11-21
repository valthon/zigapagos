import { test, expect } from "bun:test";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { cspHeaderValue, emitAllCsp, readCspSources, serializeCspSources } from "../../runtime/scripts/emit-host-config.ts";
import { checkDeployment, planChecks } from "../../runtime/scripts/check-static-deploy.ts";

const repo = resolve(import.meta.dir, "../..");
const extras = [{ directive: "connect-src", sources: ["https://api.example"] }];
const emitter = join(repo, "runtime/scripts/emit-host-config.ts");
function project() {
  const work = mkdtempSync(join(tmpdir(), "csp-ownership-"));
  for (const name of ["content", "layouts"]) cpSync(join(repo, "tests/rendering/simple", name), join(work, name), { recursive: true });
  const base = readFileSync(join(repo, "tests/rendering/simple/zigapagos.ziggy"), "utf8").trimEnd().slice(0, -2);
  const site = join(work, "public");
  mkdirSync(site);
  return {
    work, site,
    config(fields = "") { writeFileSync(join(work, "zigapagos.ziggy"), base + fields + "})"); },
    release() {
      const result = Bun.spawnSync([join(repo, "zig-out/bin/zigapagos"), "release", "--force"], {
        cwd: work, env: { ...process.env, ZIGAPAGOS_RUNTIME_DIR: join(repo, "runtime") },
      });
      expect(result.stderr.toString()).not.toContain("emitting host config failed");
      expect(result.exitCode).toBe(0);
    },
    close() { rmSync(work, { recursive: true, force: true }); },
  };
}
async function checkTree(site: string) {
  const policy = readFileSync(join(site, "csp.zigbase.txt"), "utf8").split("\n").find(line => line.startsWith("Content-Security-Policy: "))!.slice(25);
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    let path = decodeURIComponent(new URL(request.url).pathname).slice(1);
    if (!path || path.endsWith("/")) path += "index.html";
    return new Response(Bun.file(join(site, path)), { headers: {
      "Content-Security-Policy": policy, "Cache-Control": "no-cache",
      "Content-Type": path.endsWith(".html") ? "text/html" : path.endsWith(".css") ? "text/css" : "text/javascript",
    } });
  } });
  try { expect((await checkDeployment(planChecks(site, `http://127.0.0.1:${server.port}/`))).ok).toBe(true); }
  finally { server.stop(true); }
}

test("legacy bare-array metadata is read and upgraded in an existing output tree", async () => {
  const p = project();
  try {
    const metadata = join(p.site, "csp-sources.json");
    writeFileSync(metadata, JSON.stringify(extras));
    expect(readCspSources(p.site)).toEqual(extras);
    writeFileSync(join(p.site, "index.html"), "<title>Old release</title>");
    expect(planChecks(p.site, "http://127.0.0.1/").csp).toContain("connect-src 'self' https://api.example");
    p.config('\n.csp_extra_sources = [.{ .directive = "connect-src", .sources = ["https://api.example"] }],\n');
    p.release();
    expect(readFileSync(metadata, "utf8")).toBe(serializeCspSources(extras));
    await checkTree(p.site);
    p.config();
    p.release();
    expect(existsSync(metadata)).toBe(false);
    writeFileSync(metadata, JSON.stringify(extras));
    p.release();
    expect(existsSync(metadata)).toBe(false);
  } finally { p.close(); }
});

for (const [shape, asset] of [["marker", serializeCspSources(extras)], ["legacy", JSON.stringify(extras)]] as const) {
  test(`installed ${shape}-shaped user metadata stays an asset across checker and standalone emitter`, async () => {
    const p = project();
    try {
      writeFileSync(join(p.work, "content/csp-sources.json"), asset);
      p.config('\n.static_assets = ["csp-sources.json"],\n');
      p.release();
      const metadata = join(p.site, "csp-sources.json");
      const policy = readFileSync(join(p.site, "csp.zigbase.txt"), "utf8");
      expect(policy).toContain(`Content-Security-Policy: ${cspHeaderValue([])}\n`);
      for (const file of emitAllCsp([])) expect(readFileSync(join(p.site, file.name), "utf8")).toBe(file.content);
      await checkTree(p.site);
      const result = Bun.spawnSync([process.execPath, emitter, "--site", p.site]);
      expect(result.exitCode).toBe(0);
      expect(readFileSync(metadata, "utf8")).toBe(asset);
      expect(readFileSync(join(p.site, "csp.zigbase.txt"), "utf8")).toBe(policy);
      await checkTree(p.site);
      // Even after deselection, the recorded user file must not be claimed.
      rmSync(join(p.work, "content/csp-sources.json"));
      p.config('\n.csp_extra_sources = [.{ .directive = "connect-src", .sources = ["https://api.example"] }],\n');
      const collision = Bun.spawnSync([join(repo, "zig-out/bin/zigapagos"), "release", "--force"], {
        cwd: p.work, env: { ...process.env, ZIGAPAGOS_RUNTIME_DIR: join(repo, "runtime") },
      });
      expect(collision.exitCode).not.toBe(0);
      expect(readFileSync(metadata, "utf8")).toBe(asset);
      rmSync(metadata);
      p.release();
      expect(readCspSources(p.site)).toEqual(extras);
    } finally { p.close(); }
  });
}

test("an installed asset at the ownership filename is preserved and blocks emission", () => {
  const p = project();
  try {
    const name = ".zigapagos-csp-ownership.json";
    const asset = '{"generated_by":"emit-host-config.ts","csp_sources_asset":false}\n';
    writeFileSync(join(p.work, "content", name), asset);
    // The CSP asset ensures the emitter would otherwise run on this static tree.
    writeFileSync(join(p.work, "content/csp-sources.json"), serializeCspSources(extras));
    p.config('\n.static_assets = ["**"],\n');
    const result = Bun.spawnSync([join(repo, "zig-out/bin/zigapagos"), "release", "--force"], {
      cwd: p.work, env: { ...process.env, ZIGAPAGOS_RUNTIME_DIR: join(repo, "runtime") },
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr.toString()).toContain("collides with reserved .zigapagos-csp-ownership.json");
    expect(readFileSync(join(p.site, name), "utf8")).toBe(asset);
  } finally { p.close(); }
});
