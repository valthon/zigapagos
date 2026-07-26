// Consumer preload for `bun test` — one line in a consumer bunfig.toml:
//   [test]  preload = ["@z/runtime/testing/preload"]
// Sets up:
//  1. happy-dom as the global DOM (renderIsland / hydration helpers);
//  2. the site's z-runtime.config.json `resolve` map as process-global module
//     overrides — the SAME registration the SSR sidecar applies — so a view
//     reached through an out-of-tree workspace symlink (bun test realpaths
//     those files outside the project root, where tsconfig `paths` and the
//     package's own node_modules can't resolve react/@z/runtime) still lands
//     on the ONE shared Preact/@z/runtime;
//  3. @z/site-data — fed from the config's `data` map exactly like the
//     sidecar, and swappable per test via mockSiteData() from
//     "@z/runtime/testing".
// The config is discovered by walking up from process.cwd(), matching the
// sidecar (run `bun test` from the website root or below). No config → no
// overrides (base behavior) + a mock-only @z/site-data.
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { registerResolveOverrides } from "../../sidecar/ssr-resolve.ts";
import { registerTestSiteData } from "./site-data.ts";

GlobalRegistrator.register();
const { config, baseDir } = registerResolveOverrides(process.cwd());
registerTestSiteData(config.data ?? {}, baseDir);
