import { test, expect, afterEach } from "bun:test";
import { renderIsland, flush, type RenderResult } from "@z/runtime/testing";
import { ReCAPTCHA, useRecaptcha, type RecaptchaHandle } from "@z/runtime/compat";

const API = "https://www.google.com/recaptcha/api.js";
let captured: any;
let resetWith: number | null = null;
function installGrecaptcha() {
  captured = undefined; resetWith = null;
  (window as any).grecaptcha = {
    render: (el: Element, opts: any) => { captured = opts; return 42; },
    reset: (id?: number) => { resetWith = id ?? null; },
  };
}
let r: RenderResult<any> | undefined;
afterEach(() => { r?.unmount(); delete (window as any).grecaptcha; });

test("renders an empty container server-side then explicit-renders on mount with the siteKey", async () => {
  installGrecaptcha();
  const ref: { current: RecaptchaHandle | null } = { current: null };
  r = renderIsland(ReCAPTCHA, { siteKey: "KEY", ref } as any, { host: { scripts: { [API]: true } } });
  expect(r.html()).toContain("g-recaptcha-container");   // static SSR placeholder
  await flush();                                         // flush loadScript().then + effects
  expect(captured?.sitekey).toBe("KEY");
  expect(Object.keys(captured).sort()).toEqual([
    "callback", "error-callback", "expired-callback", "sitekey",
  ]);
});

test("passes size, theme and lowercase tabindex to the widget", async () => {
  installGrecaptcha();
  r = renderIsland(ReCAPTCHA, { siteKey: "KEY", size: "compact", theme: "dark", tabindex: 0 },
    { host: { scripts: { [API]: true } } });
  await flush();
  expect(captured.size).toBe("compact");
  expect(captured.theme).toBe("dark");
  expect(captured.tabindex).toBe(0);
});

for (const [option, prop] of [["expired-callback", "onExpired"], ["error-callback", "onErrored"]] as const) {
  test(`${option} clears a solved token before notifying callers`, async () => {
    installGrecaptcha();
    const ref: { current: RecaptchaHandle | null } = { current: null };
    const tokens: string[] = [];
    let calls = 0;
    r = renderIsland(ReCAPTCHA, {
      siteKey: "KEY", ref,
      onChange: (token: string) => {
        expect(ref.current?.getValue()).toBe(token);
        tokens.push(token);
      },
      [prop]: () => {
        expect(ref.current?.getValue()).toBe("");
        calls++;
      },
    }, { host: { scripts: { [API]: true } } });
    await flush();
    captured.callback("SOLVED");
    expect(typeof captured[option]).toBe("function");
    captured[option]();
    expect(ref.current?.getValue()).toBe("");
    expect(tokens).toEqual(["SOLVED", ""]);
    expect(calls).toBe(1);
  });
}

for (const option of ["callback", "expired-callback", "error-callback"] as const) {
  for (const update of ["replace", "add", "remove"] as const) {
    test(`${option} uses current callbacks after same-siteKey rerender (${update})`, async () => {
      installGrecaptcha();
      const ref: { current: RecaptchaHandle | null } = { current: null };
      const oldCalls: string[] = [];
      const newCalls: string[] = [];
      const handlers = (calls: string[]) => ({
        onChange: (token: string) => {
          expect(ref.current?.getValue()).toBe(token);
          calls.push(`change:${token}`);
        },
        onExpired: () => {
          expect(ref.current?.getValue()).toBe("");
          calls.push("expired");
        },
        onErrored: () => {
          expect(ref.current?.getValue()).toBe("");
          calls.push("errored");
        },
      });
      r = renderIsland(ReCAPTCHA, {
        siteKey: "KEY", ref, ...(update === "add" ? {} : handlers(oldCalls)),
      }, { host: { scripts: { [API]: true } } });
      await flush();
      const widgetCallbacks = captured;
      captured.callback("INITIAL");
      oldCalls.length = 0;
      await r.rerender({
        siteKey: "KEY", ref, ...(update === "remove" ? {} : handlers(newCalls)),
      });
      expect(captured).toBe(widgetCallbacks);
      widgetCallbacks[option]("LATEST");
      expect(ref.current?.getValue()).toBe(option === "callback" ? "LATEST" : "");
      expect(oldCalls).toEqual([]);
      expect(newCalls).toEqual(update === "remove" ? [] : option === "callback"
        ? ["change:LATEST"]
        : ["change:", option === "expired-callback" ? "expired" : "errored"]);
    });
  }
}

test("useRecaptcha clears solved tokens on expiry and error after rerender", async () => {
  installGrecaptcha();
  let api: ReturnType<typeof useRecaptcha> | undefined;
  function Fixture() { api = useRecaptcha("HOOK_KEY"); return null; }
  r = renderIsland(Fixture, {}, { host: { scripts: { [API]: true } } });
  await flush();
  api!.render(document.createElement("div"));
  expect(Object.keys(captured).sort()).toEqual([
    "callback", "error-callback", "expired-callback", "sitekey",
  ]);
  expect(captured.sitekey).toBe("HOOK_KEY");
  await r.rerender({});
  for (const option of ["expired-callback", "error-callback"]) {
    captured.callback("SOLVED");
    expect(api!.getToken()).toBe("SOLVED");
    captured[option]();
    expect(api!.getToken()).toBe("");
  }
});

test("the callback delivers the token to the handle + onChange; reset() resets the widget", async () => {
  installGrecaptcha();
  const tokens: string[] = [];
  const ref: { current: RecaptchaHandle | null } = { current: null };
  r = renderIsland(ReCAPTCHA, { siteKey: "KEY", ref, onChange: (t: string) => tokens.push(t) } as any,
    { host: { scripts: { [API]: true } } });
  await flush();
  captured.callback("TOKEN123");
  expect(ref.current?.getValue()).toBe("TOKEN123");
  expect(tokens).toContain("TOKEN123");
  ref.current?.reset();
  expect(resetWith).toBe(42);
  expect(ref.current?.getValue()).toBe("");
});
