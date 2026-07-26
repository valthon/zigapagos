import { setSystemTime } from "bun:test";
import { host, __resetStoresForTest, __resetScriptsForTest, type FetchEnvelope } from "../host.ts";
import { setSsrPathname, __setServerForTest } from "../ssr-env.ts";
import { flush } from "./flush.ts";

type FetchResult = string | object | Response | FetchEnvelope;

export interface MockHostConfig {
  flags?: Record<string, boolean>;
  experiments?: Record<string, string>;
  shared?: Record<string, string | object>;
  cookies?: Record<string, string>;
  fetch?: (url: string, init?: RequestInit) => FetchResult | Promise<FetchResult>;
  now?: number | Date;
  scrollY?: number;
  viewport?: { width: number; height: number };
  media?: Record<string, boolean>;
  scripts?: Record<string, boolean> | boolean;
  recaptchaToken?: string;
  server?: boolean;
}

export interface MockHost {
  setFlags(flags: Record<string, boolean>, experiments?: Record<string, string>): Promise<void>;
  resolveShared(store: string, body: string | object): Promise<void>;
  setCookie(name: string, value: string): void;
  setScroll(y: number): Promise<void>;
  setViewport(w: number, h: number): Promise<void>;
  setMedia(query: string, matches: boolean): Promise<void>;
  advanceClock(ms: number): void;
  setRecaptchaToken(token: string): void;
  readonly errors: string[];
  readonly fetches: Array<{ url: string; init?: RequestInit }>;
  readonly cookies: Record<string, string>;
  readonly scriptsLoaded: string[];
  install(): void;
  restore(): void;
}

function toResponse(out: FetchResult): Response {
  if (out instanceof Response) return out;
  if (typeof out === "string") return new Response(out, { status: 200 });
  if (out && typeof out === "object" && "status" in out && "body" in out && "headers" in out) {
    const env = out as FetchEnvelope;
    return new Response(env.body, { status: env.status, headers: env.headers });
  }
  return new Response(JSON.stringify(out), { status: 200, headers: { "content-type": "application/json" } });
}

export function mockHost(config: MockHostConfig = {}): MockHost {
  const errors: string[] = [];
  const fetches: Array<{ url: string; init?: RequestInit }> = [];
  const scriptsLoaded: string[] = [];
  const mediaState: Record<string, boolean> = { ...(config.media ?? {}) };
  const mqlListeners: Record<string, Set<(e: { matches: boolean }) => void>> = {};

  let installed = false;
  let origFetch: typeof globalThis.fetch | undefined;
  let origMatchMedia: typeof window.matchMedia | undefined;
  let origScrollDesc: PropertyDescriptor | undefined;
  let origHeadAppendChild: typeof document.head.appendChild | undefined;
  let hadOwnHeadAppendChild = false;
  let scripts: Record<string, boolean> = {};
  let scriptsDefault = true;
  let origDateNow: (() => number) | undefined;
  let frozenTime: number | undefined;

  function parseCookies(): Record<string, string> {
    const out: Record<string, string> = {};
    if (typeof document === "undefined" || !document.cookie) return out;
    for (const part of document.cookie.split("; ")) {
      const eq = part.indexOf("=");
      if (eq !== -1) out[part.slice(0, eq)] = part.slice(eq + 1);
    }
    return out;
  }
  function defineScroll(y: number) {
    Object.defineProperty(window, "scrollY", { value: y, configurable: true, writable: true });
  }
  function setInnerSize(w: number, h: number) {
    Object.defineProperty(window, "innerWidth", { value: w, configurable: true, writable: true });
    Object.defineProperty(window, "innerHeight", { value: h, configurable: true, writable: true });
  }
  function makeMql(query: string) {
    const listeners = (mqlListeners[query] ??= new Set());
    return {
      media: query,
      get matches() { return mediaState[query] ?? false; },
      addEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.add(cb),
      removeEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.delete(cb),
      addListener: (cb: (e: { matches: boolean }) => void) => listeners.add(cb),
      removeListener: (cb: (e: { matches: boolean }) => void) => listeners.delete(cb),
      dispatchEvent: () => true,
      onchange: null,
    };
  }
  function setRecaptchaTextarea(token: string) {
    let ta = document.getElementById("g-recaptcha-response") as HTMLTextAreaElement | null;
    if (!ta) {
      ta = document.createElement("textarea");
      ta.id = "g-recaptcha-response";
      document.body.appendChild(ta);
    }
    ta.value = token;
  }

  function install() {
    if (installed) return;
    installed = true;

    if (config.server !== undefined) __setServerForTest(config.server);
    if (config.now !== undefined) {
      frozenTime = typeof config.now === "number" ? config.now : (config.now as Date).getTime();
      origDateNow = Date.now;
      Date.now = () => frozenTime!;
      // setSystemTime freezes BOTH Date.now() and new Date(); but setSystemTime(new Date(0))
      // is a no-op in this Bun, so the Date.now override above covers now:0, and this freezes
      // new Date() (→ host.localDateParts()) for any non-zero frozen time.
      if (frozenTime !== 0) setSystemTime(new Date(frozenTime));
    }
    if (config.flags || config.experiments) {
      host.store.setStr("flags", JSON.stringify({ flags: config.flags ?? {}, experiments: config.experiments ?? {} }));
    }
    for (const [name, body] of Object.entries(config.shared ?? {})) {
      host.store.setStr(name, typeof body === "string" ? body : JSON.stringify(body));
    }
    for (const [k, v] of Object.entries(config.cookies ?? {})) document.cookie = `${k}=${v}`;
    if (config.recaptchaToken !== undefined) setRecaptchaTextarea(config.recaptchaToken);

    origFetch = globalThis.fetch;
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : (input as Request).url ?? String(input);
      fetches.push({ url, init });
      if (!config.fetch) return new Response("", { status: 404 });
      return toResponse(await config.fetch(url, init));
    }) as typeof globalThis.fetch;

    origScrollDesc = Object.getOwnPropertyDescriptor(window, "scrollY");
    if (config.scrollY !== undefined) defineScroll(config.scrollY);
    if (config.viewport) setInnerSize(config.viewport.width, config.viewport.height);

    origMatchMedia = window.matchMedia;
    window.matchMedia = ((q: string) => makeMql(q)) as unknown as typeof window.matchMedia;

    scripts = typeof config.scripts === "object" ? { ...config.scripts } : {};
    scriptsDefault = typeof config.scripts === "boolean" ? config.scripts : true;
    // Patch document.head.appendChild to intercept <script> injections.
    // happy-dom fires el.onerror synchronously during appendChild (JS file loading
    // is disabled), which would settle the loadScript promise to false before our
    // queued microtask can dispatch the correct load/error event. We null out
    // onload/onerror temporarily so happy-dom's synchronous error is a no-op,
    // restore them after the real appendChild returns, then dispatch the correct
    // event on a microtask (which fires el.onload / el.onerror as the host expects).
    origHeadAppendChild = document.head.appendChild.bind(document.head);
    hadOwnHeadAppendChild = Object.prototype.hasOwnProperty.call(document.head, "appendChild");
    const _origHeadAppendChild = origHeadAppendChild;
    (document.head as any).appendChild = function <T extends Node>(node: T): T {
      if (node instanceof HTMLScriptElement) {
        const url = node.getAttribute("src") ?? "";
        if (url) {
          const savedOnload = node.onload;
          const savedOnerror = node.onerror;
          node.onload = null;
          node.onerror = null;
          try { _origHeadAppendChild(node as unknown as ChildNode); } catch { /* happy-dom load error; handled below */ }
          node.onload = savedOnload;
          node.onerror = savedOnerror;
          const ok = url in scripts ? scripts[url] : scriptsDefault;
          scriptsLoaded.push(url);
          queueMicrotask(() => node.dispatchEvent(new Event(ok ? "load" : "error")));
          return node;
        }
      }
      return _origHeadAppendChild(node as unknown as ChildNode) as unknown as T;
    };

    (window as any).zigapagosOnError = (msg: string) => errors.push(msg);
  }

  function restore() {
    if (!installed) return;
    installed = false;
    if (origFetch) globalThis.fetch = origFetch;
    if (origMatchMedia) window.matchMedia = origMatchMedia;
    if (origScrollDesc) {
      Object.defineProperty(window, "scrollY", origScrollDesc);
    } else {
      try { delete (window as any).scrollY; } catch { /* read-only host env */ }
    }
    if (origHeadAppendChild) {
      if (hadOwnHeadAppendChild) (document.head as any).appendChild = origHeadAppendChild;
      else delete (document.head as any).appendChild;
    }
    if (origDateNow) { Date.now = origDateNow; origDateNow = undefined; frozenTime = undefined; }
    document.getElementById("g-recaptcha-response")?.remove();
    for (const k of Object.keys(parseCookies())) document.cookie = `${k}=; Max-Age=0`;
    delete (window as any).zigapagosOnError;
    for (const q of Object.keys(mqlListeners)) mqlListeners[q].clear();
    __resetStoresForTest();
    __resetScriptsForTest();
    __setServerForTest(undefined);
    setSsrPathname("/");
    errors.length = 0; fetches.length = 0; scriptsLoaded.length = 0;
    setSystemTime(); // always reset Bun's global clock — covers both frozen and advanceClock paths
  }

  return {
    async setFlags(flags, experiments) {
      host.store.setStr("flags", JSON.stringify({ flags, experiments: experiments ?? {} }));
      await flush();
    },
    async resolveShared(store, body) {
      host.store.setStr(store, typeof body === "string" ? body : JSON.stringify(body));
      await flush();
    },
    setCookie(name, value) { document.cookie = `${name}=${value}`; },
    async setScroll(y) { defineScroll(y); window.dispatchEvent(new Event("scroll")); await flush(); },
    async setViewport(w, h) { setInnerSize(w, h); window.dispatchEvent(new Event("resize")); await flush(); },
    async setMedia(query, matches) {
      mediaState[query] = matches;
      for (const cb of mqlListeners[query] ?? []) cb({ matches });
      await flush();
    },
    advanceClock(ms) {
      if (frozenTime !== undefined) { frozenTime += ms; }
      else { setSystemTime(new Date(Date.now() + ms)); }
    },
    setRecaptchaToken(token) { setRecaptchaTextarea(token); },
    get errors() { return errors; },
    get fetches() { return fetches; },
    get cookies() { return parseCookies(); },
    get scriptsLoaded() { return scriptsLoaded; },
    install,
    restore,
  };
}
