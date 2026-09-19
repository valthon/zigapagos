#!/usr/bin/env bun
// Runnable rehearsal fixture, not a production server or host-config emulator.
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { cspHeaderValue, scanInlineScriptHashes } from "../../runtime/scripts/emit-host-config.ts";

export function fixture(prefix = "", broken = "") {
  const site = mkdtempSync(join(tmpdir(), "zigapagos-deploy-"));
  const files: Record<string, string> = {
    "index.html": '<!doctype html><title>Home</title><script>console.log("home")</script>',
    "app/index.html": "<!doctype html><title>Application fallback</title>",
    "app/item/_shell.html": "<!doctype html><title>Item shell</title>",
    "docs/index.html": "<!doctype html><title>Documentation</title>",
    "app.js": "console.log('stable entry');",
    "theme.abcdef12.css": "body{color:red}",
    "spa/lazy-XYZ123.js": "export const lazy=true;",
    "space # % ?.css": "body{margin:0}",
  };
  for (const [file, body] of Object.entries(files)) {
    mkdirSync(dirname(join(site, file)), { recursive: true });
    writeFileSync(join(site, file), body);
  }
  writeFileSync(join(site, "app/routing-manifest.json"), JSON.stringify({
    base: "/app", deploy_target: "nginx", url_path_prefix: prefix,
    static: ["/app/"], dynamic: [{ pattern: "/app/item/:id", shell: "/app/item/_shell.html" }],
    fallback: "/app/index.html", bundle: prefix + "/app.js",
    immutableAssets: [prefix + "/spa/lazy-XYZ123.js"],
  }));
  const csp = cspHeaderValue(scanInlineScriptHashes(Object.entries(files).filter(([f]) => f.endsWith(".html")).map(([, b]) => b)));
  const received: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1", port: 0,
    async fetch(request) {
      const encoded = new URL(request.url).pathname;
      received.push(encoded);
      if (broken === "timeout") await Bun.sleep(100);
      if (!encoded.startsWith(prefix + "/")) return new Response("wrong mount", { status: 404 });
      const path = decodeURIComponent(encoded.slice(prefix.length));
      if (broken === "redirect") return new Response(null, { status: 302, headers: { location: "https://example.invalid/" } });
      let file = path.slice(1);
      if (!file || file.endsWith("/")) file += "index.html";
      if (!Object.hasOwn(files, file)) {
        if (broken === "deep-link") return new Response("missing fallback", { status: 404 });
        if (/^\/app\/item\/[^/]+\/?$/.test(path)) file = "app/item/_shell.html";
        else if (path.startsWith("/app/")) file = "app/index.html";
        else return new Response("missing", { status: 404 });
      }
      if (broken === "asset-fallback" && file === "app.js") file = "index.html";
      const html = file.endsWith(".html");
      const headers: Record<string, string> = {
        "Content-Type": html ? "text/html" : file.endsWith(".css") ? "text/css" : "text/javascript",
        "Cache-Control": /abcdef12|lazy-XYZ123/.test(file) ? "public, max-age=31536000, immutable" : "no-cache",
      };
      if (html && broken !== "csp") headers["Content-Security-Policy"] = csp;
      if (html && broken === "csp-invalid") headers["Content-Security-Policy"] = csp.split(";").map((d) => {
        const [name, ...tokens] = d.trim().split(/\s+/);
        return [...tokens, name].join(" ");
      }).join(";");
      if (html && broken === "csp-duplicate") headers["Content-Security-Policy"] = csp + "; script-src 'none'";
      if (broken === "body-timeout") return new Response(new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array()); } }), { headers });
      if (broken === "cache") headers["Cache-Control"] = "public, max-age=3600";
      return new Response(broken === "stale" ? "old release" : readFileSync(join(site, file)), { headers });
    },
  });
  return {
    site, url: `http://127.0.0.1:${server.port}${prefix}/`, received,
    close() { server.stop(true); rmSync(site, { recursive: true, force: true }); },
  };
}

if (import.meta.main) {
  const prefix = process.argv.find((a) => a.startsWith("--prefix="))?.slice(9) ?? "";
  const broken = process.argv.find((a) => a.startsWith("--broken="))?.slice(9) ?? "";
  if (prefix && !/^\/[A-Za-z0-9_-]+$/.test(prefix)) throw new Error("fixture prefix must be one safe segment, e.g. /preview");
  const f = fixture(prefix, broken);
  console.log(`bun runtime/scripts/check-static-deploy.ts --site '${f.site}' --url '${f.url}' --json`);
  for (const signal of ["SIGINT", "SIGTERM"] as const) process.on(signal, () => { f.close(); process.exit(0); });
}
