import { test, expect } from "bun:test";
import { symlinkSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { planChecks, checkDeployment } from "../../runtime/scripts/check-static-deploy.ts";
import { fixture } from "./fixture.ts";

for (const prefix of ["", "/preview"]) {
  test(`HTTP release rehearsal passes for ${prefix || "root"} mount`, async () => {
    const f = fixture(prefix);
    try {
      const plan = planChecks(f.site, f.url);
      const report = await checkDeployment(plan);
      expect(report).toEqual({ ok: true, checked: 10, findings: [] });
      expect(f.received).toContain(prefix + "/app/item/__zigapagos_probe__");
      expect(f.received).toContain(prefix + "/app/__zigapagos_fallback__/");
      expect(f.received).toContain(prefix + "/space%20%23%20%25%20%3F.css");
      expect(plan.probes.find((p) => p.path === "/spa/lazy-XYZ123.js")?.cache).toContain("immutable");
      expect(plan.probes.find((p) => p.path === "/app.js")?.cache).toBe("no-cache");
    } finally { f.close(); }
  });
}

for (const [broken, code] of [["deep-link", "status"], ["asset-fallback", "bytes"], ["cache", "cache"], ["csp", "csp"], ["stale", "bytes"], ["redirect", "status"], ["timeout", "request"], ["body-timeout", "request"], ["csp-invalid", "csp"], ["csp-duplicate", "csp"]]) {
  test(`detects ${broken} host misconfiguration`, async () => {
    const f = fixture("/preview", broken);
    try {
      const report = await checkDeployment(planChecks(f.site, f.url), broken?.includes("timeout") ? 10 : 10000);
      expect(report.ok).toBe(false);
      expect(report.findings.some((finding) => finding.code === code)).toBe(true);
      if (broken === "asset-fallback") expect(report.findings.some((v) => v.path === "/app.js" && v.code === "mime")).toBe(true);
      if (broken === "redirect") expect(report.findings[0]!.message).toContain("redirects are not followed");
      if (broken?.includes("timeout")) expect(report.findings[0]!.message).toContain("exceeded 10 ms");
    } finally { f.close(); }
  });
}

test("rejects wrong mount and symlinks before contacting the server", () => {
  const f = fixture("/preview");
  try {
    expect(() => planChecks(f.site, f.url.replace("/preview/", "/wrong/"))).toThrow("disagrees");
    symlinkSync(join(f.site, "index.html"), join(f.site, "linked.html"));
    expect(() => planChecks(f.site, f.url)).toThrow("symlink is unsupported");
    expect(f.received.length).toBe(0);
  } finally { f.close(); }
});

test("supports static-only trees; refuses absent and escaping manifest shell paths", async () => {
  const f = fixture();
  try {
    const manifestPath = join(f.site, "app/routing-manifest.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    for (const shell of ["/absent.html", "/../outside.html"]) {
      writeFileSync(manifestPath, JSON.stringify({ ...manifest, dynamic: [{ pattern: "/app/item/:id", shell }] }));
      expect(() => planChecks(f.site, f.url)).toThrow();
    }
    rmSync(manifestPath);
    rmSync(join(f.site, "spa/lazy-XYZ123.js"));
    const report = await checkDeployment(planChecks(f.site, f.url));
    expect(report.ok).toBe(true);
    expect(report.checked).toBe(7);
  } finally { f.close(); }
});

test("CLI JSON has deterministic findings and fails on served-byte mismatches", async () => {
  for (const broken of ["", "stale"]) {
    const f = fixture("/preview", broken);
    try {
      const child = Bun.spawn([process.execPath, join(import.meta.dir, "../../runtime/scripts/check-static-deploy.ts"), "--site", f.site, "--url", f.url, "--json"], { stdout: "pipe", stderr: "pipe" });
      const [stdout, stderr, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
      expect(stderr).toBe("");
      expect(exit).toBe(broken ? 1 : 0);
      const report = JSON.parse(stdout);
      expect(report.ok).toBe(!broken);
      expect(report.checked).toBe(10);
    } finally { f.close(); }
  }
});

test("missing manifest bundle cannot produce a passing plan", () => {
  const f = fixture();
  try {
    rmSync(join(f.site, "app.js"));
    expect(() => planChecks(f.site, f.url)).toThrow("missing release file: app.js");
  } finally { f.close(); }
});
