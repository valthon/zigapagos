// STUB "zigbase" for tests/serve/e2e.sh + tests/serve/dev.sh — NOT the real
// ZigBase binary.
//
// Mirrors the REAL `zigbase serve` CLI semantics (zigbase src/cli.zig
// `parse()`, confirmed by `zigbase serve --help` of the release binary) so the
// harness can be exercised hermetically on machines/CI without a real
// zigbase, and so any drift between the harness's invocation and the real
// parser is caught here as a hard error rather than masked:
//
//   zigbase serve --http-host <H> --http-port <N> --data-dir <PATH>
//                 --serve-static <DIR>
//
//   - flags are SPACE-SEPARATED: exact-match flag name, value = NEXT argv
//     token (the real parser does NO '=' splitting — `--http-port=1234` is an
//     UnknownFlag there, and is one here too);
//   - a flag missing its value is an error (ParseError.MissingValue);
//   - any unknown token is an error (ParseError.UnknownFlag);
//   - defaults mirror the real binary: host 127.0.0.1, port 8090, data dir
//     ./zb_data; --serve-static defaults to OFF (the stub, which exists only
//     to serve a tree, hard-errors in that case instead of idling).
//
// Serving behavior mirrors the documented stock-server static semantics
// (docs/spa.md): real files win; a directory resolves to its index.html; on a
// miss, the nearest ancestor directory carrying a `.spa` marker serves its
// index.html (Tier 1 SPA fallback); otherwise 404. The data dir is created
// and touched like a real data dir so the harness's data-dir plumbing is
// observable.
import { existsSync, mkdirSync, statSync, writeFileSync } from "node:fs";
import { join, normalize } from "node:path";

const args = process.argv.slice(2);
if (args[0] !== "serve") {
  console.error(`stub-zigbase: UnknownCommand: expected 'serve', got: ${args.join(" ")}`);
  process.exit(2);
}
// Real defaults (`zigbase serve --help`): host 127.0.0.1, port 8090, ./zb_data.
let host = "127.0.0.1";
let port = 8090;
let dataDir = "./zb_data";
let staticDir: string | null = null;

for (let i = 1; i < args.length; i++) {
  const a = args[i];
  const next = (): string => {
    i++;
    if (i >= args.length) {
      console.error(`stub-zigbase: MissingValue for '${a}'`);
      process.exit(2);
    }
    return args[i];
  };
  if (a === "--http-host") host = next();
  else if (a === "--http-port") port = Number(next());
  else if (a === "--data-dir") dataDir = next();
  else if (a === "--serve-static") staticDir = next();
  else if (a === "--insecure-cookies") {
    // Boolean flag in the real CLI (plain-HTTP local dev; the `zigapagos dev`
    // default template appends it). Nothing to do in the stub.
  } else {
    // Exact-match names only, like the real parser: `--http-port=1234` lands
    // here too. Hard error so harness/parser contract drift is caught.
    console.error(`stub-zigbase: UnknownFlag '${a}'`);
    process.exit(2);
  }
}
if (!Number.isInteger(port) || port < 0 || port > 65535) {
  console.error("stub-zigbase: BadValue for --http-port");
  process.exit(2);
}
if (staticDir === null) {
  // Real default is static-off; a stub with nothing to serve is a test bug.
  console.error("stub-zigbase: --serve-static DIR is required for the stub (real default: off)");
  process.exit(2);
}
if (!existsSync(staticDir) || !statSync(staticDir).isDirectory()) {
  console.error(`stub-zigbase: --serve-static dir '${staticDir}' is missing or not a directory`);
  process.exit(2);
}

// Touch the data dir like a real server would, so tests can observe it.
mkdirSync(dataDir, { recursive: true });
writeFileSync(join(dataDir, "stub-zigbase.touch"), `${Date.now()}\n`);

function fileAt(p: string): string | null {
  try {
    const st = statSync(p);
    return st.isFile() ? p : null;
  } catch {
    return null;
  }
}

/** Resolve a URL pathname against the tree: file → dir index → .spa fallback. */
function resolve(pathname: string): string | null {
  // Normalize and refuse traversal out of the tree.
  const rel = normalize(decodeURIComponent(pathname)).replace(/^\/+/, "");
  if (rel.startsWith("..")) return null;
  const full = join(staticDir!, rel);
  // Tier 0: a real file wins.
  const direct = fileAt(full);
  if (direct) return direct;
  // Directory (or trailing slash): its index.html.
  const index = fileAt(join(full, "index.html"));
  if (index) return index;
  // Tier 1: nearest ancestor with a `.spa` marker serves its index.html.
  const segs = rel.split("/").filter(Boolean);
  for (let i = segs.length; i >= 0; i--) {
    const base = join(staticDir!, ...segs.slice(0, i));
    if (existsSync(join(base, ".spa"))) {
      const shell = fileAt(join(base, "index.html"));
      if (shell) return shell;
    }
  }
  return null;
}

Bun.serve({
  hostname: host,
  port,
  async fetch(req) {
    const resolved = resolve(new URL(req.url).pathname);
    if (!resolved) return new Response("stub-zigbase: not found\n", { status: 404 });
    return new Response(Bun.file(resolved));
  },
});
console.log(`stub-zigbase: serving ${staticDir} on http://${host}:${port} (data: ${dataDir})`);
