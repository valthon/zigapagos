import { expect, test, describe, beforeEach, afterEach } from "bun:test";
import { h, render } from "./core.ts";
import { useRestorableState, onBeforeReload } from "./dev-reload.ts";
import { __setServerForTest } from "./ssr-env.ts";
import { flush } from "./testing/flush.ts";

// --- harness ---------------------------------------------------------------
// Render a tiny controlled <input> driven by useRestorableState into a real
// (happy-dom) container. `setter` captures the hook's setter so a test can
// change the value the way a user's onInput would; `fireBeforeReload` fakes the
// dev client's synchronous pre-reload event; unmount+remount fakes a reload.

const KEY = "field";
const SKEY = "z-reload:field";

let container: HTMLElement | null = null;
let setter: ((v: string) => void) | null = null;

function Field({ initial }: { initial: string }) {
  const [value, setValue] = useRestorableState<string>(KEY, initial);
  setter = setValue;
  return h("input", { "data-f": "", value });
}

function mount(initial = ""): void {
  container = document.createElement("div");
  document.body.appendChild(container);
  render(h(Field, { initial }), container);
}
function unmount(): void {
  if (!container) return;
  render(null as any, container);
  container.remove();
  container = null;
}
function fieldValue(): string {
  return (container!.querySelector("[data-f]") as HTMLInputElement).value;
}
function fireBeforeReload(): void {
  window.dispatchEvent(new CustomEvent("zigapagos:beforereload"));
}

beforeEach(() => {
  window.sessionStorage.clear();
  setter = null;
});
afterEach(() => {
  try { unmount(); } catch { /* ignore */ }
  window.sessionStorage.clear();
  __setServerForTest(undefined);
});

describe("useRestorableState", () => {
  test("no persisted key → uses the initial value", async () => {
    mount("start");
    await flush();
    expect(fieldValue()).toBe("start");
  });

  test("beforereload writes the CURRENT value under z-reload:<key>", async () => {
    mount("");
    await flush();
    setter!("hello");
    await flush();
    expect(fieldValue()).toBe("hello");

    fireBeforeReload();
    expect(window.sessionStorage.getItem(SKEY)).toBe(JSON.stringify("hello"));
  });

  test("a fresh mount with the key present restores it AND clears it (one-shot)", async () => {
    window.sessionStorage.setItem(SKEY, JSON.stringify("restored"));
    mount(""); // initial is "", but the persisted value wins on first mount
    await flush();
    expect(fieldValue()).toBe("restored");
    expect(window.sessionStorage.getItem(SKEY)).toBeNull(); // consumed

    // A second mount (key already consumed) falls back to initial.
    unmount();
    mount("");
    await flush();
    expect(fieldValue()).toBe("");
  });

  test("round-trip: set → beforereload → remount restores; next remount → initial", async () => {
    mount("");
    await flush();
    setter!("wizard-2");
    await flush();

    fireBeforeReload(); // dev reload about to happen: value stashed
    unmount();          // the reload tears down the page

    // First mount after the "reload" restores the stashed value.
    mount("");
    await flush();
    expect(fieldValue()).toBe("wizard-2");

    // A SECOND reload WITHOUT a prior beforereload → back to initial (proves
    // one-shot restore + no stale persistence).
    unmount();
    mount("");
    await flush();
    expect(fieldValue()).toBe("");
  });

  test("the latest value is persisted (listener reads a live ref, not a stale closure)", async () => {
    mount("");
    await flush();
    setter!("first");
    await flush();
    setter!("second");
    await flush();

    fireBeforeReload();
    expect(window.sessionStorage.getItem(SKEY)).toBe(JSON.stringify("second"));
  });

  test("malformed JSON in sessionStorage → falls back to initial without throwing", async () => {
    window.sessionStorage.setItem(SKEY, "{not valid json");
    mount("fallback");
    await flush();
    expect(fieldValue()).toBe("fallback");
    // Consumed even though malformed, so a bad blob can't wedge future mounts.
    expect(window.sessionStorage.getItem(SKEY)).toBeNull();
  });

  test("unmount removes the listener (a later beforereload writes nothing)", async () => {
    mount("");
    await flush();
    setter!("live");
    await flush();
    unmount();

    window.sessionStorage.clear();
    fireBeforeReload();
    expect(window.sessionStorage.getItem(SKEY)).toBeNull();
  });

  test("SSR (isServer) → plain state, never touches window/sessionStorage", async () => {
    // A stray persisted value must be ignored on the server, and no listener
    // may be installed (beforereload writes nothing).
    window.sessionStorage.setItem(SKEY, JSON.stringify("should-not-restore"));
    __setServerForTest(true);

    mount("srv");
    await flush();
    expect(fieldValue()).toBe("srv"); // ignored the persisted value
    // The server path did not read/consume the key.
    expect(window.sessionStorage.getItem(SKEY)).toBe(JSON.stringify("should-not-restore"));

    setter!("changed");
    await flush();
    fireBeforeReload(); // no listener registered on the server
    expect(window.sessionStorage.getItem(SKEY)).toBe(JSON.stringify("should-not-restore"));
  });
});

describe("onBeforeReload", () => {
  test("fires the callback on zigapagos:beforereload and stops after unsubscribe", () => {
    let n = 0;
    const off = onBeforeReload(() => { n++; });
    fireBeforeReload();
    expect(n).toBe(1);
    off();
    fireBeforeReload();
    expect(n).toBe(1); // unsubscribed
  });

  test("isServer → installs no listener and returns a no-op unsubscribe", () => {
    __setServerForTest(true);
    let m = 0;
    const off = onBeforeReload(() => { m++; });
    fireBeforeReload();
    expect(m).toBe(0);
    expect(() => off()).not.toThrow();
  });
});
