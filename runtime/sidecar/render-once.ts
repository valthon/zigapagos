import { h, renderToString } from "../src/core.ts";
import { setSsrPathname } from "../src/ssr-env.ts";
import { registerSsrModuleOverrides } from "./ssr-resolve.ts";

// Same z-runtime.config.json `resolve` overrides as the NDJSON sidecar,
// registered before the island import below.
registerSsrModuleOverrides(process.cwd());

const [, , file, propsJSON = "{}", pathname = "/"] = process.argv;
if (!file) {
  console.error("usage: render-once <islandFile> <propsJSON> <pathname>");
  process.exit(1);
}
try {
  setSsrPathname(pathname);
  const mod = await import(file);
  const props = JSON.parse(propsJSON);
  process.stdout.write(renderToString(h(mod.default, props)));
  process.exit(0);
} catch (err) {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
}
