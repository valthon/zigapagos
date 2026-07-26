import { h, renderToString } from "../src/core.ts";
import { setSsrPathname } from "../src/ssr-env.ts";
import { buildSlots } from "../src/slots.ts";
import { store } from "../src/host.ts";
import { registerSsrModuleOverrides } from "./ssr-resolve.ts";

import { describeRoutes } from "../src/router.ts";

// Build-time SSR of an island/SPA that imports an allowlisted npm React component
// needs `react` to resolve to the shared @z/runtime/compat (one Preact, same
// instance as preact-render-to-string). Bun runtime plugins can't intercept bare
// specifiers via onResolve, so the mapping is registered as process-global
// module overrides (ssr-resolve.ts, `build.module`) from z-runtime.config.json's
// `resolve` map — react/react-dom/jsx-runtime -> the compat surface by DEFAULT
// whenever firstParty/npmCompat is non-empty, before any island is imported
// below. The client bundle keeps `react` external (react-alias.ts plugin) and the
// import-map resolves it to the same shared runtime — so both sides are ONE
// Preact. (tsconfig `paths` is now only needed to point tsc at the compat TYPES.)
// The sidecar's cwd is the website root (sidecar.zig spawns it there), so the
// config is discovered by walking up from cwd.
registerSsrModuleOverrides(process.cwd());

// One persistent process per build; module cache stays warm across requests.
const cache = new Map<string, any>();
async function load(src: string) {
  let mod = cache.get(src);
  if (!mod) { mod = await import(src); cache.set(src, mod); }
  return mod;
}

// --- Baked flag defaults ----------------------------------------------------

/** Loud-fail validation of a module's `spa.flags` export: build-time flag
 * defaults must be a plain Record<string, boolean>. Anything else is a config
 * error the SSG should surface, not serialize. */
function validateSpaFlags(flags: unknown): asserts flags is Record<string, boolean> | undefined {
  if (flags === undefined) return;
  if (flags === null || typeof flags !== "object" || Array.isArray(flags)) {
    throw new Error("spa.flags must be an object mapping flag names to boolean defaults");
  }
  for (const [name, value] of Object.entries(flags)) {
    if (typeof value !== "boolean") {
      throw new Error(
        `spa.flags[${JSON.stringify(name)}] must be a boolean default (got ${typeof value})`,
      );
    }
  }
}

/** Seed (or CLEAR) the sidecar's page-global flags store from the module's
 * declared `spa.flags` defaults, per render request. Seeding makes the SSR'd
 * skeleton render with the same defaults the shell's `data-z-flags` snapshot
 * seeds on the client, so both hydration passes agree; clearing (the "" write
 * when a module declares no flags) keeps one persistent sidecar process from
 * bleeding a previous module's defaults into the next render. */
function seedSsrFlags(spaExport: unknown): void {
  const flags = (spaExport as { flags?: unknown } | undefined)?.flags;
  validateSpaFlags(flags);
  store.setStr("flags", flags ? JSON.stringify({ flags, experiments: {} }) : "");
}

async function handle(line: string): Promise<string> {
  let req: { id: number; src: string; props: unknown; pathname?: string; slots?: Record<string, string>; describe?: boolean };
  try {
    req = JSON.parse(line);
  } catch {
    return JSON.stringify({ id: -1, error: `invalid request line: ${line}` });
  }
  try {
    if (req.describe) {
      const mod = await load(req.src);
      const spa = mod.spa ?? {};
      validateSpaFlags((spa as { flags?: unknown }).flags); // loud build failure on bad defaults
      const routes = await describeRoutes(mod.routes ?? []);
      return JSON.stringify({ id: req.id, spa, routes });
    }
    setSsrPathname(req.pathname ?? "/");
    const mod = await load(req.src);
    seedSsrFlags(mod.spa); // SSR sees the module's baked flag defaults
    const { children, slots } = buildSlots(req.slots);
    const props = slots ? { ...(req.props as object), slots } : req.props;
    const html = renderToString(h(mod.default, props as any, children));
    return JSON.stringify({ id: req.id, html });
  } catch (err) {
    // Loud-fail: the SSG must see the error, not a blank island. Carry the
    // stack alongside the message — Bun source-maps it when a map
    // is available, so the build's diagnostics point at source lines rather
    // than collapsing to a bare message across the NDJSON boundary.
    return JSON.stringify({
      id: req.id,
      error: err instanceof Error ? err.message : String(err),
      stack: err instanceof Error ? err.stack : undefined,
    });
  }
}

// ONE streaming decoder for the whole of stdin. `Bun.stdin.stream()` chunks on
// BYTE counts, not codepoints, so a multi-byte UTF-8 sequence routinely straddles
// a chunk boundary; a fresh (non-streaming) TextDecoder per chunk turns each half
// into U+FFFD, silently corrupting the prerendered HTML (an em-dash/emoji in a
// large props/slots payload) or breaking JSON.parse on a request that was valid.
// `{ stream: true }` holds the partial sequence back until its continuation
// arrives.
const decoder = new TextDecoder();

// A request line is large (props + slots for a whole page section) but bounded.
// Without a cap, a peer that never terminates a line grows `buf` until the
// process dies of OOM with no diagnostic; instead reject THAT line loudly and
// resynchronize on the next newline.
const MAX_LINE_CHARS = 64 * 1024 * 1024;

let buf = "";
let discarding = false; // dropping the tail of an over-long line
for await (const chunk of Bun.stdin.stream()) {
  buf += decoder.decode(chunk, { stream: true });
  let nl: number;
  while ((nl = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (discarding) { discarding = false; continue; } // tail of a rejected line
    if (line) await Bun.write(Bun.stdout, (await handle(line)) + "\n");
  }
  if (!discarding && buf.length > MAX_LINE_CHARS) {
    discarding = true;
    await Bun.write(
      Bun.stdout,
      JSON.stringify({
        id: -1,
        error: `request line exceeds ${MAX_LINE_CHARS} chars without a newline; discarded`,
      }) + "\n",
    );
  }
  // Whatever remains after the loop holds no newline, so once we are discarding
  // it all belongs to the rejected line and must not be retained.
  if (discarding) buf = "";
}
