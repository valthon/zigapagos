import { isAbsolute } from "node:path";
import { h, render, type ComponentType } from "../../core.ts";
import { bootIsland } from "../../islands.ts";
import { ssrIsland } from "../render.ts";
import { mockHost, type MockHostConfig } from "../mock-host.ts";
import {
  serializeDom, diffDom, checkPropSerialization,
  type Mismatch, type SerializeOpts,
} from "./serialize.ts";
import { makeIslandRoot, setLocationPathname } from "./root.ts";

export * from "./serialize.ts";
export { makeIslandRoot, setLocationPathname } from "./root.ts";

export type SsrSource = "in-process" | "sidecar";

export interface ParityOptions extends SerializeOpts {
  props?: Record<string, unknown>;
  pathname?: string;
  zClient?: "load" | "idle" | "visible" | "media" | "only";
  ssr?: SsrSource;
  host?: MockHostConfig;
}

export interface ParityResult {
  ok: boolean;
  ssrHtml: string;
  hydratedHtml: string;
  clientHtml: string;
  mismatches: Mismatch[];
}

function intoContainer(html: string): HTMLElement {
  const d = document.createElement("div");
  d.innerHTML = html;
  return d;
}

export async function checkParity(islandPath: string, opts: ParityOptions = {}): Promise<ParityResult> {
  if (typeof islandPath !== "string" || !isAbsolute(islandPath)) {
    throw new Error(`checkParity: island must be an ABSOLUTE path to a .island.tsx (got ${JSON.stringify(islandPath)})`);
  }
  if (opts.ssr === "sidecar") {
    throw new Error("checkParity: the sidecar SSR source is v2; use the default in-process source (ssr: \"in-process\").");
  }
  const pathname = opts.pathname ?? "/";
  const props = opts.props ?? {};
  const serOpts: SerializeOpts = {
    ignoreAttributes: opts.ignoreAttributes,
    ignoreSelectors: opts.ignoreSelectors,
    normalizeWhitespace: opts.normalizeWhitespace,
  };

  const mh = opts.host ? mockHost(opts.host) : undefined;
  mh?.install();
  setLocationPathname(pathname);

  let made: ReturnType<typeof makeIslandRoot> | undefined;
  try {
    const mod = await import(islandPath);
    const C = mod.default as ComponentType<any>;
    if (typeof C !== "function") throw new Error(`checkParity: ${islandPath} has no default-exported component`);

    // Model the data-z-props JSON round-trip the loader performs.
    const propsRT = JSON.parse(JSON.stringify(props));
    const mismatches: Mismatch[] = checkPropSerialization(props);

    // 1) SSR (server host branch, in-process via ssrIsland's __setServerForTest toggle).
    const ssrHtml = ssrIsland(C, propsRT, { pathname });
    const ssrSnap = serializeDom(intoContainer(ssrHtml), serOpts);

    // 2) Drive the REAL bootIsland over the SSR markup.
    made = makeIslandRoot(ssrHtml, props, islandPath, { zClient: opts.zClient ?? "load" });
    await bootIsland(made.root);
    const hydratedHtml = made.root.innerHTML;
    // Re-parse innerHTML so text-node boundaries are normalized identically to the SSR parse.
    const hydratedSnap = serializeDom(intoContainer(hydratedHtml), serOpts);
    mismatches.push(...diffDom(ssrSnap, hydratedSnap, "hydrate-snapshot"));
    // 3) Double-render: clean CLIENT render (no server toggle) vs the SSR snapshot.
    const dc = document.createElement("div");
    render(h(C as any, propsRT as any), dc);
    const clientHtml = dc.innerHTML;
    // Re-parse innerHTML so text-node boundaries are normalized identically to the SSR parse.
    const clientSnap = serializeDom(intoContainer(clientHtml), serOpts);
    render(null as any, dc);
    mismatches.push(...diffDom(ssrSnap, clientSnap, "double-render"));

    // dedupe identical (path,kind,source)
    const seen = new Set<string>();
    const deduped = mismatches.filter((m) => {
      const k = `${m.path}|${m.kind}|${m.source}|${m.ssr}|${m.client}`;
      if (seen.has(k)) return false; seen.add(k); return true;
    });

    return { ok: deduped.length === 0, ssrHtml, hydratedHtml, clientHtml, mismatches: deduped };
  } finally {
    setLocationPathname("/");
    mh?.restore();
    made?.cleanup();
  }
}

export class ParityError extends Error {}

function hintFor(m: Mismatch): string | undefined {
  if ((m.kind === "text" || m.kind === "structure") && /\d/.test(m.client) && m.ssr !== m.client) {
    return "host.now()/localDateParts() differ server↔client — render this client-only after an effect, pass host:{now:…}, or ignoreSelectors.";
  }
  if (m.kind === "prop-serialization") {
    return "a prop is lost in the data-z-props JSON round-trip (Date/function/bigint/undefined) — pass a JSON-serializable value.";
  }
  return undefined;
}

function format(islandPath: string, mismatches: Mismatch[]): string {
  const name = islandPath.split("/").pop() ?? islandPath;
  const lines = [`SSR↔hydration mismatch in ${name} (${mismatches.length} mismatch${mismatches.length === 1 ? "" : "es"})`];
  for (const m of mismatches) {
    lines.push(`  ${m.path} : ${m.kind}  (source: ${m.source})`);
    lines.push(`    ssr     ${JSON.stringify(m.ssr)}`);
    lines.push(`    client  ${JSON.stringify(m.client)}`);
    const hint = hintFor(m);
    if (hint) lines.push(`    hint: ${hint}`);
  }
  return lines.join("\n");
}

export async function expectParity(islandPath: string, opts?: ParityOptions): Promise<void> {
  const r = await checkParity(islandPath, opts);
  if (!r.ok) throw new ParityError(format(islandPath, r.mismatches));
}
