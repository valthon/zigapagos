import { test, expect, afterEach } from "bun:test";
import { renderIsland, flush, type RenderResult } from "@z/runtime/testing";
import { ReCAPTCHA, type RecaptchaHandle } from "@z/runtime/compat";

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
