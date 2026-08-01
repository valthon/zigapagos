// The five `client:` directives, pinned at the scheduler.
//
// Issue #35: `docs/islands.md` documented `client:load` and `client:only` and
// said nothing about `idle`, `visible` or `media` — the parser
// (`src/islands/pass.zig`'s `validateClientDirective`) was a more reliable
// reference than the prose. Writing that prose meant reading
// `runtime/src/islands.ts`'s `schedule()` and asserting what it does, and until
// now NOTHING in the suite exercised that switch: the existing island tests
// drive `bootIsland` directly and `initIslands`/`schedule` not at all, so every
// sentence the docs page now makes about *when* an island mounts rested on a
// code read.
//
// These are characterization tests, not regression tests — they do not fail
// without a fix, because there is no defect in `schedule()` to fix. What they
// pin is the docs page: if someone swaps `requestIdleCallback` for a plain
// `setTimeout`, drops the `IntersectionObserver.disconnect()` on first
// intersection, or stops `client:media` unsubscribing once it has mounted, this
// file goes red and points at the paragraph that has become a lie.
//
// The DOM harness is happy-dom (`test/setup-dom.ts`). It provides `matchMedia`
// but neither `requestIdleCallback` nor `IntersectionObserver`, which is
// convenient: both branches of the `idle` fallback are reachable by defining or
// deleting the global, and `visible` has to be driven through an explicit
// double so the test controls when "intersecting" happens.
import { test, expect, beforeEach, afterEach } from "bun:test";
import { h } from "@z/runtime/core";
import { initIslands, __setIslandImporter } from "@z/runtime/islands";

const MODULE_URL = "/islands/Probe.island.js";

// Every mount records the module URL it asked for, so "did this island mount
// yet?" is a question about a list rather than about the DOM.
let imported: string[] = [];

// happy-dom DOES provide `matchMedia`, so the media tests below shadow a real
// implementation rather than adding a missing one -- `delete` would not put it
// back. It is captured once here and reassigned after every test. Leaking one
// of these fakes is not hypothetical: one of them answers `matches: true` to
// every query, and every test file sharing this realm would inherit it.
const realMatchMedia = window.matchMedia;

beforeEach(() => {
  imported = [];
  document.body.innerHTML = "";
  __setIslandImporter(async (url) => {
    imported.push(url);
    return { default: () => h("p", null, "probe") };
  });
});

afterEach(() => {
  __setIslandImporter(undefined);
  delete (window as any).requestIdleCallback;
  delete (window as any).IntersectionObserver;
  delete (globalThis as any).IntersectionObserver;
  (window as any).matchMedia = realMatchMedia;
});

/** An SSR'd island root exactly as `src/islands/pass.zig` emits one: the
 *  wrapper div carries `data-z-island`, `data-z-client` and `data-z-module`,
 *  and the props ride in a sibling `<script data-z-props>`. `client` is written
 *  verbatim, so passing "" reproduces an `<island>` with no `client:` attribute
 *  at all — pass.zig defaults `Client.name` to the empty string and formats it
 *  into the same attribute. */
function island(client: string, media?: string): HTMLElement {
  const root = document.createElement("div");
  root.setAttribute("data-z-island", "");
  root.id = "z-island-0";
  root.dataset.zModule = MODULE_URL;
  root.dataset.zClient = client;
  if (media !== undefined) root.dataset.zMedia = media;
  const props = document.createElement("script");
  props.type = "application/json";
  props.setAttribute("data-z-props", "z-island-0");
  props.textContent = "{}";
  document.body.append(root, props);
  return root;
}

test("client:load mounts immediately — the module is requested synchronously", () => {
  island("load");
  initIslands();
  // Deliberately not awaited: `bootIsland` reaches `importModule` before its
  // first `await`, so "immediately" is observable as a synchronous call. A
  // scheduler that deferred `load` to a microtask would fail here.
  expect(imported).toEqual([MODULE_URL]);
});

test("client:only mounts immediately, like load", () => {
  island("only");
  initIslands();
  expect(imported).toEqual([MODULE_URL]);
});

test("an island with NO client: directive still hydrates immediately", () => {
  // pass.zig emits `data-z-client=""` for an island with no directive, and
  // `[data-z-client]` matches on attribute PRESENCE, so the root is selected
  // and falls into `schedule()`'s `default:` branch. Omitting the directive is
  // therefore not a way to opt out of hydration — stated on the islands page so
  // nobody infers "no directive = server-only" from its absence.
  island("");
  initIslands();
  expect(imported).toEqual([MODULE_URL]);
});

test("client:idle defers to requestIdleCallback when the browser has one", () => {
  let idleCb: (() => void) | undefined;
  (window as any).requestIdleCallback = (cb: () => void) => {
    idleCb = cb;
  };
  island("idle");
  initIslands();
  expect(imported).toEqual([]); // nothing yet — the browser is still busy
  expect(idleCb).toBeDefined();
  idleCb!();
  expect(imported).toEqual([MODULE_URL]);
});

test("client:idle falls back to a timer where requestIdleCallback is missing", async () => {
  // Safari shipped no requestIdleCallback for years; the fallback is
  // `setTimeout(run, 1)`, i.e. "after the current task", not "when idle".
  expect("requestIdleCallback" in window).toBe(false);
  island("idle");
  initIslands();
  expect(imported).toEqual([]); // still the same task
  await new Promise((r) => setTimeout(r, 20));
  expect(imported).toEqual([MODULE_URL]);
});

test("client:visible waits for an intersection, then disconnects the observer", () => {
  let fire: ((entries: { isIntersecting: boolean }[]) => void) | undefined;
  let observed: Element | undefined;
  let disconnects = 0;
  class FakeIO {
    constructor(cb: (entries: { isIntersecting: boolean }[], obs: FakeIO) => void) {
      fire = (entries) => cb(entries, this);
    }
    observe(el: Element) {
      observed = el;
    }
    disconnect() {
      disconnects += 1;
    }
  }
  (window as any).IntersectionObserver = FakeIO;
  (globalThis as any).IntersectionObserver = FakeIO;

  const root = island("visible");
  initIslands();
  expect(observed).toBe(root); // the island root itself is the observed target
  expect(imported).toEqual([]);

  // Observers fire once on observe(); a non-intersecting entry must not mount.
  fire!([{ isIntersecting: false }]);
  expect(imported).toEqual([]);

  fire!([{ isIntersecting: true }]);
  expect(imported).toEqual([MODULE_URL]);
  // One-shot: the observer is disconnected on the first intersection, so
  // scrolling the island out and back never re-enters the mount path.
  expect(disconnects).toBe(1);
});

test("client:media mounts immediately when the query already matches", () => {
  let queried = "";
  (window as any).matchMedia = (q: string) => {
    queried = q;
    return { matches: true, addEventListener() {}, removeEventListener() {} };
  };
  island("media", "(min-width: 600px)");
  initIslands();
  expect(queried).toBe("(min-width: 600px)"); // read from data-z-media
  expect(imported).toEqual([MODULE_URL]);
});

test("client:media waits for a change event, and unsubscribes when it mounts", () => {
  let onChange: (() => void) | undefined;
  let removed = 0;
  const mql = {
    matches: false,
    addEventListener(_: string, cb: () => void) {
      onChange = cb;
    },
    removeEventListener() {
      removed += 1;
    },
  };
  (window as any).matchMedia = () => mql;
  island("media", "(min-width: 600px)");
  initIslands();
  expect(imported).toEqual([]);

  // A change event that leaves the query unmatched is ignored and the listener
  // stays subscribed — the island is still waiting.
  onChange!();
  expect(imported).toEqual([]);
  expect(removed).toBe(0);

  mql.matches = true;
  onChange!();
  expect(imported).toEqual([MODULE_URL]);
  expect(removed).toBe(1);
});

test("client:media with no data-z-media falls back to the `all` query", () => {
  // Unreachable from a real build — pass.zig rejects `client:media` with no
  // value (error.MissingMediaQuery) — but the runtime's own default decides
  // what a hand-written or third-party-emitted root does: `all` matches
  // everything, so such a root mounts rather than hanging forever.
  let queried = "";
  (window as any).matchMedia = (q: string) => {
    queried = q;
    return { matches: true, addEventListener() {}, removeEventListener() {} };
  };
  island("media");
  initIslands();
  expect(queried).toBe("all");
  expect(imported).toEqual([MODULE_URL]);
});

// Runs last on purpose: the three tests above replace `window.matchMedia`, one
// of them with a fake that reports `matches: true` for EVERY query. Bun shares
// one happy-dom realm across the suite, so a fake that survives this file
// decides what an unrelated test sees. This asserts the teardown actually put
// the real implementation back, which `delete` cannot do for a method the DOM
// harness supplies.
test("the media fakes do not outlive their tests", () => {
  expect(window.matchMedia).toBe(realMatchMedia);
});
