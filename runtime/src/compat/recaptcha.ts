import { h, useEffect, useRef, forwardRef, useImperativeHandle, host, type VNode } from "@z/runtime";

const API_URL = "https://www.google.com/recaptcha/api.js";

export interface RecaptchaHandle { getValue(): string; reset(): void }

interface Grecaptcha {
  render(el: Element, opts: {
    sitekey: string;
    callback?: (t: string) => void;
    "expired-callback"?: () => void;
  }): number;
  reset(id?: number): void;
  ready?(cb: () => void): void;
}

function grecaptcha(): Grecaptcha | undefined {
  return typeof window === "undefined" ? undefined : (window as any).grecaptcha;
}

export const ReCAPTCHA = forwardRef<RecaptchaHandle, { siteKey: string; onChange?: (token: string) => void }>(
  (props, ref) => {
    const elRef = useRef<HTMLDivElement | null>(null);
    const widgetId = useRef<number | null>(null);
    const tokenRef = useRef<string>("");

    useImperativeHandle(ref, () => ({
      getValue: () => tokenRef.current,
      reset: () => {
        const g = grecaptcha();
        if (g && widgetId.current != null) g.reset(widgetId.current);
        tokenRef.current = "";
      },
    }), []);

    useEffect(() => {
      let cancelled = false;
      host.loadScript(API_URL).then((ok) => {
        if (!ok || cancelled || !elRef.current) return;
        const g = grecaptcha();
        if (!g?.render) return;
        const doRender = () => {
          if (cancelled || !elRef.current || widgetId.current != null) return;
          widgetId.current = g.render(elRef.current!, {
            sitekey: props.siteKey,
            callback: (t: string) => { tokenRef.current = t; props.onChange?.(t); },
            "expired-callback": () => { tokenRef.current = ""; props.onChange?.(""); },
          });
        };
        g.ready ? g.ready(doRender) : doRender();
      });
      return () => { cancelled = true; };
    }, [props.siteKey]);

    return h("div", { ref: elRef, class: "g-recaptcha-container" }) as VNode;
  },
);

// Hook variant for callers that own the container element.
export function useRecaptcha(siteKey: string): { getToken(): string; reset(): void; render(el: Element): void } {
  const widgetId = useRef<number | null>(null);
  const tokenRef = useRef<string>("");
  useEffect(() => { host.loadScript(API_URL); return () => {}; }, []);
  return {
    getToken: () => tokenRef.current,
    reset: () => {
      const g = grecaptcha();
      if (g && widgetId.current != null) g.reset(widgetId.current);
      tokenRef.current = "";
    },
    // Caller must ensure the grecaptcha script is fully loaded before calling render();
    // calling before the script resolves is a no-op (the widget will not appear).
    render: (el: Element) => {
      const g = grecaptcha();
      if (!g?.render || widgetId.current != null) return;
      widgetId.current = g.render(el, {
        sitekey: siteKey,
        callback: (t: string) => { tokenRef.current = t; },
      });
    },
  };
}
