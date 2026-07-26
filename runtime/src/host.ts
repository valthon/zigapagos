import { isServer, currentPathname, currentSearch, currentHash } from "./ssr-env.ts";

// ---------------------------------------------------------------------------
// Store — page-global cross-island reactive key/value store.
// ---------------------------------------------------------------------------

type StoreEntry = {
  value: string | bigint;
  subs: Set<() => void>;
  fetchStarted?: boolean;
  fetchUrl?: string;
};
let STORES: Record<string, StoreEntry> = {};
function entry(name: string): StoreEntry {
  return (STORES[name] ??= { value: "", subs: new Set() });
}
function notify(e: StoreEntry) {
  for (const cb of e.subs) queueMicrotask(cb);
}
// Test-only: reset page-global state between cases.
export function __resetStoresForTest() { STORES = {}; }

// ---------------------------------------------------------------------------
// Types (mirror engine/src/host.zig)
// ---------------------------------------------------------------------------

export type CookieOptions = {
  path?: string; max_age?: number | null; expires?: string;
  same_site?: "" | "Strict" | "Lax" | "None"; secure?: boolean;
};
export type Header = { name: string; value: string };
export type FetchRequest = { url: string; method?: string; headers?: Header[]; body?: string };
export type FetchEnvelope = { status: number; headers: Record<string, string>; body: string };
export type DateParts = {
  year: number; month: number; day: number; weekday: number;
  hour: number; minute: number; second: number;
};

// ---------------------------------------------------------------------------
// store object
// ---------------------------------------------------------------------------

export const store = {
  getStr(name: string): string {
    const v = entry(name).value;
    return typeof v === "string" ? v : "";
  },
  setStr(name: string, value: string): void {
    const e = entry(name); e.value = value; notify(e);
  },
  getNum(name: string): bigint {
    const v = entry(name).value;
    return typeof v === "bigint" ? v : 0n;
  },
  setNum(name: string, value: bigint): void {
    const e = entry(name); e.value = value; notify(e);
  },
  subscribe(name: string, cb: () => void, signal?: AbortSignal): void {
    const e = entry(name);
    e.subs.add(cb);
    signal?.addEventListener("abort", () => e.subs.delete(cb), { once: true });
  },
  // LOUD-FAIL: throws on missing/empty/malformed; never returns a default.
  getJson<T>(name: string): T {
    const raw = store.getStr(name);
    if (!raw) throw new Error(`z.store.getJson("${name}"): store is empty`);
    try {
      return JSON.parse(raw) as T;
    } catch (err) {
      throw new Error(`z.store.getJson("${name}"): malformed JSON: ${(err as Error).message}`);
    }
  },
};

// ---------------------------------------------------------------------------
// reportError — forward to window.zigapagosOnError or console.error.
// ---------------------------------------------------------------------------

export function reportError(value: unknown): void {
  if (isServer()) return;
  const msg = value instanceof Error ? (value.stack ?? value.message) : String(value);
  const hook = (window as any).zigapagosOnError;
  if (typeof hook === "function") hook(msg);
  else console.error("[zigapagos island]", msg);
}

// ---------------------------------------------------------------------------
// fetchShared — one fetch per store, shared across all islands.
// ---------------------------------------------------------------------------

export function fetchShared(url: string, storeName: string): void {
  if (isServer()) return;
  const e = entry(storeName);
  if (e.fetchStarted) {
    if (e.fetchUrl !== url) {
      console.warn(`zigapagos: fetchShared store ${JSON.stringify(storeName)} already loading ${JSON.stringify(e.fetchUrl)}; ignoring ${JSON.stringify(url)}`);
    }
    return; // one request per store
  }
  e.fetchStarted = true;
  e.fetchUrl = url;
  fetch(url)
    .then((r) => {
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.text();
    })
    .then((text) => store.setStr(storeName, text))
    .catch((err) => {
      // Loud-fail: surface it; do NOT write a default value into the store.
      // fetchShared is void — callers cannot catch; re-throwing would only
      // produce an unhandled rejection. reportError is the error surface.
      reportError(`fetchShared(${url}) failed: ${(err as Error).message}`);
    });
}

// ---------------------------------------------------------------------------
// cookies
// ---------------------------------------------------------------------------

export const cookies = {
  get(name: string): string {
    if (isServer()) return "";
    let value = "";
    for (const part of document.cookie.split("; ")) {
      const eq = part.indexOf("=");
      if (eq !== -1 && part.slice(0, eq) === name) {
        value = part.slice(eq + 1);
        break;
      }
    }
    return value;
  },
  set(name: string, value: string, opts?: CookieOptions): void {
    if (isServer()) return;
    let c = `${name}=${value}`;
    if (opts?.path) c += `; Path=${opts.path}`;
    if (opts?.max_age !== null && opts?.max_age !== undefined) c += `; Max-Age=${opts.max_age}`;
    if (opts?.expires) c += `; Expires=${opts.expires}`;
    if (opts?.same_site) c += `; SameSite=${opts.same_site}`;
    if (opts?.secure) c += "; Secure";
    document.cookie = c;
  },
};

// ---------------------------------------------------------------------------
// Clock — SSR returns deterministic baseline (0 / all-zero DateParts).
// ---------------------------------------------------------------------------

export function now(): number {
  if (isServer()) return 0;
  return Date.now();
}

export function localDateParts(): DateParts {
  if (isServer()) {
    return { year: 0, month: 0, day: 0, weekday: 0, hour: 0, minute: 0, second: 0 };
  }
  const d = new Date();
  return {
    year: d.getFullYear(),
    month: d.getMonth() + 1, // JS months are 0-based
    day: d.getDate(),
    weekday: d.getDay(), // 0=Sunday
    hour: d.getHours(),
    minute: d.getMinutes(),
    second: d.getSeconds(),
  };
}

// ---------------------------------------------------------------------------
// Global event subscriptions — onScroll / onResize / matchMedia.
// Each delivers the CURRENT value once (via queueMicrotask), then on change.
// All no-op on the server; signal is used for auto-removal on unmount.
// ---------------------------------------------------------------------------

export function onScroll(cb: (y: number) => void, signal?: AbortSignal): void {
  if (isServer()) return;
  const deliver = () => cb(window.scrollY);
  window.addEventListener("scroll", deliver as EventListener, { signal, passive: true });
  queueMicrotask(() => { if (!signal?.aborted) deliver(); });
}

export function onResize(cb: (w: number, h: number) => void, signal?: AbortSignal): void {
  if (isServer()) return;
  const deliver = () => cb(window.innerWidth, window.innerHeight);
  window.addEventListener("resize", deliver as EventListener, { signal });
  queueMicrotask(() => { if (!signal?.aborted) deliver(); });
}

export function matchMedia(query: string, cb: (matches: boolean) => void, signal?: AbortSignal): void {
  if (isServer()) return;
  const mql = window.matchMedia(query);
  const deliver = () => cb(mql.matches);
  mql.addEventListener("change", deliver as EventListener, { signal });
  queueMicrotask(() => { if (!signal?.aborted) deliver(); });
}

// ---------------------------------------------------------------------------
// Scoped sibling enhancers — one-way write into pre-existing elements by id.
// All no-op on the server (SSR keeps the static node).
// ---------------------------------------------------------------------------

export const enhance = {
  setText(id: string, text: string): void {
    if (isServer()) return;
    const el = document.getElementById(id);
    if (el) el.textContent = text;
  },
  setHtml(id: string, html: string): void {
    if (isServer()) return;
    const el = document.getElementById(id);
    if (el) el.innerHTML = html;
  },
  setStyle(id: string, prop: string, value: string): void {
    if (isServer()) return;
    const el = document.getElementById(id);
    if (el) el.style.setProperty(prop, value);
  },
  addClass(id: string, c: string): void {
    if (isServer()) return;
    const el = document.getElementById(id);
    if (el) el.classList.add(c);
  },
  removeClass(id: string, c: string): void {
    if (isServer()) return;
    const el = document.getElementById(id);
    if (el) el.classList.remove(c);
  },
  toggleClass(id: string, c: string): void {
    if (isServer()) return;
    const el = document.getElementById(id);
    if (el) el.classList.toggle(c);
  },
};

// ---------------------------------------------------------------------------
// loadScript — injects <script src=url async> once per url (deduped).
// Returns Promise<boolean> (true = loaded, false = error). No-op on server.
// ---------------------------------------------------------------------------

type ScriptEntry = { state: "loading" | "loaded" | "error"; waiters: Array<(ok: boolean) => void> };
const Z_SCRIPTS: Record<string, ScriptEntry> = {};

export function loadScript(url: string): Promise<boolean> {
  if (isServer()) return Promise.resolve(false);
  const existing = Z_SCRIPTS[url];
  if (existing) {
    if (existing.state === "loaded") return Promise.resolve(true);
    if (existing.state === "error") return Promise.resolve(false);
    return new Promise<boolean>((resolve) => existing.waiters.push(resolve));
  }
  const scriptEntry: ScriptEntry = { state: "loading", waiters: [] };
  Z_SCRIPTS[url] = scriptEntry;
  const settle = (ok: boolean) => {
    scriptEntry.state = ok ? "loaded" : "error";
    const ws = scriptEntry.waiters;
    scriptEntry.waiters = [];
    for (const w of ws) w(ok);
  };
  return new Promise<boolean>((resolve) => {
    scriptEntry.waiters.push(resolve);
    const el = document.createElement("script");
    el.src = url;
    el.async = true;
    el.onload = () => settle(true);
    el.onerror = () => settle(false);
    document.head.appendChild(el);
  });
}

// Test-only: clear the loadScript dedupe map between cases, so a URL loaded in
// one test does not stay "loaded" forever and short-circuit the next test.
export function __resetScriptsForTest(): void {
  for (const k in Z_SCRIPTS) delete Z_SCRIPTS[k];
}

// ---------------------------------------------------------------------------
// getValue — read a form control value or textContent by element id.
// Returns "" on server or when element is absent.
// ---------------------------------------------------------------------------

export function getValue(id: string): string {
  if (isServer()) return "";
  const el = document.getElementById(id) as HTMLInputElement | null;
  if (!el) return "";
  if (typeof (el as HTMLInputElement).value === "string") return (el as HTMLInputElement).value;
  return el.textContent || "";
}

// ---------------------------------------------------------------------------
// recaptchaToken — read the reCAPTCHA v2 response token from the hidden
// <textarea id="g-recaptcha-response"> injected by the reCAPTCHA script.
// The caller must load the reCAPTCHA script first, e.g.:
//   await host.loadScript("https://www.google.com/recaptcha/api.js")
// Returns "" on server or when the user has not yet completed the challenge.
// ---------------------------------------------------------------------------

export function recaptchaToken(): string {
  return getValue("g-recaptcha-response");
}

// ---------------------------------------------------------------------------
// fetchOpts — richer fetch with method/headers/body; returns FetchEnvelope.
// Returns the zero-envelope on server or network error.
// ---------------------------------------------------------------------------

export async function fetchOpts(req: FetchRequest): Promise<FetchEnvelope> {
  if (isServer()) return { status: 0, headers: {}, body: "" };
  const { url, method = "GET", headers: reqHeaders = [], body = "" } = req;
  const init: RequestInit = { method };
  if (reqHeaders.length > 0) {
    const hdrs: Record<string, string> = {};
    for (const h of reqHeaders) hdrs[h.name] = h.value;
    init.headers = hdrs;
  }
  if (body) init.body = body;
  try {
    const r = await fetch(url, init);
    const status = r.status;
    const headers: Record<string, string> = {};
    r.headers.forEach((v, k) => { headers[k] = v; });
    const responseBody = await r.text();
    return { status, headers, body: responseBody };
  } catch {
    return { status: 0, headers: {}, body: "" };
  }
}

// ---------------------------------------------------------------------------
// portal — resolve a CSS selector to an Element for portal mounting.
// Warns + returns null if not found. No-op (null) on server.
// ---------------------------------------------------------------------------

export function portal(selector: string): Element | null {
  if (isServer()) return null;
  const el = document.querySelector(selector);
  if (!el) {
    console.warn(`zigapagos: portal target ${JSON.stringify(selector)} not found; rendering nothing`);
    return null;
  }
  return el;
}

// ---------------------------------------------------------------------------
// host — assembled export
// ---------------------------------------------------------------------------

export const host = {
  store,
  fetchShared,
  reportError,
  pathname: currentPathname,
  search: currentSearch,
  hash: currentHash,
  cookies,
  now,
  localDateParts,
  onScroll,
  onResize,
  matchMedia,
  enhance,
  loadScript,
  getValue,
  recaptchaToken,
  fetchOpts,
  portal,
};
