let seq = 0;

export function makeIslandRoot(
  ssrHtml: string,
  props: unknown,
  moduleUrl: string,
  opts: { id?: string; zClient?: string } = {},
): { root: HTMLElement; propsScript: HTMLScriptElement; cleanup(): void } {
  const id = opts.id ?? `z-island-parity-${seq++}`;
  const root = document.createElement("div");
  root.setAttribute("data-z-island", "");
  root.id = id;
  root.dataset.zClient = opts.zClient ?? "load";
  root.dataset.zModule = moduleUrl;
  root.innerHTML = ssrHtml;

  const propsScript = document.createElement("script");
  propsScript.type = "application/json";
  propsScript.setAttribute("data-z-props", id);
  propsScript.textContent = JSON.stringify(props ?? {});

  document.body.append(root, propsScript);
  return {
    root,
    propsScript,
    cleanup() { root.remove(); propsScript.remove(); },
  };
}

// Make host.pathname()'s client branch (window.location.pathname) agree with the SSR pathname.
// Tries three mechanisms in order; the first that actually updates window.location.pathname wins.
export function setLocationPathname(pathname: string): void {
  const p = pathname.startsWith("/") ? pathname : `/${pathname}`;
  const w = window as any;
  if (w.happyDOM?.setURL) { w.happyDOM.setURL(`http://localhost${p}`); return; }
  try { window.history.replaceState({}, "", p); return; } catch { /* fall through */ }
  try { (window as any).location.href = `http://localhost${p}`; } catch { /* read-only env */ }
}
