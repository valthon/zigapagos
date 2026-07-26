import type { ComponentChildren } from "@z/runtime";
export default function AppShell({ children }: { children?: ComponentChildren }) {
  return <div class="app-shell"><header data-app-header>pilot-site</header><main>{children}</main></div>;
}
